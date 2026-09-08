//  GameStore.swift
//  OfficeAdminGame
//
//  Owns the connection, orchestrates fetches, runs WorldMapper, geocodes the
//  gaps, and performs in-world actions through the API then refetches —
//  no optimistic local truth (see ARCHITECTURE.md).
//
//  Fetch strategy per endpoint survey:
//    projects list (no addresses) -> fan out details for the live statuses,
//    bounded to 24 sites and 4 concurrent fetches so one slow row can't hang
//    the world; clock snapshot is crew-wide; shifts fetched for today local.

import CoreLocation
import Foundation
import Observation
import os

@MainActor
@Observable
final class GameStore {

    // MARK: State

    enum Phase: Equatable {
        case needsSetup
        case loading
        case ready
        case failed(String)
    }

    private static let log = Logger(subsystem: "com.officeadmin.game", category: "world")

    private(set) var phase: Phase = .needsSetup
    private(set) var world = WorldState(sites: [], crew: [], mail: [], money: .empty, whiteboard: [], playerName: nil)
    private(set) var lastLoadedAt: Date?

    private var client: OAClient?
    private let geocoder = AddressGeocoder()
    /// True while the delayed heal pass (retry detail fetches + geocodes) is
    /// pending.
    private var worldHealScheduled = false
    /// What the last load worked from, so the heal pass can fill gaps.
    private var lastInputs: WorldInputs?
    private var lastProjectIDs: [String] = []

    // MARK: Connection

    func restoreSession() {
        if let credentials = GameCredentials.fromEnvironment() {
            startSession(with: credentials)
            return
        }
        if let credentials = KeychainCredentialStore.load() {
            startSession(with: credentials)
            return
        }
        if let credentials = GameCredentials.fromBootstrapBundle() {
            startSession(with: credentials)
            return
        }
        phase = .needsSetup
    }

    private func startSession(with credentials: GameCredentials) {
        client = OAClient(credentials: credentials)
        phase = .loading
        Task { await loadWorld() }
    }

    /// First-launch (or re-enter) connection: validates against /me, saves
    /// to the Keychain only when the server accepts the key.
    func connect(baseURL: URL, apiKey: String) async -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return false }
        let candidate = OAClient(credentials: GameCredentials(baseURL: baseURL, apiKey: trimmedKey))
        do {
            _ = try await candidate.me()
            try KeychainCredentialStore.save(candidate.credentials)
            client = candidate
            phase = .loading
            Task { await loadWorld() }
            return true
        } catch {
            return false
        }
    }

    func disconnect() {
        KeychainCredentialStore.erase()
        client = nil
        world = WorldState(sites: [], crew: [], mail: [], money: .empty, whiteboard: [], playerName: nil)
        phase = .needsSetup
    }

    // MARK: World loading

    func loadWorld() async {
        guard let client else {
            phase = .needsSetup
            return
        }
        phase = .loading
        do {
            let list = try await client.projects()
            let interesting = Array(list.prefix(24))
            let details = await withTaskGroup(of: OAProjectDetail?.self) { group in
                var iterator = interesting.makeIterator()
                var active = 0
                func addNext() {
                    if let item = iterator.next(), active < 4 {
                        active += 1
                        group.addTask { try? await client.project(id: item.id) }
                        addNext()
                    }
                }
                addNext()
                var out: [OAProjectDetail] = []
                for await detail in group {
                    active -= 1
                    addNext()
                    if let detail { out.append(detail) }
                }
                return out
            }

            async let approvals = client.pendingApprovals()
            async let invoices = client.invoices()
            async let summary = try? await client.invoiceSummary()
            async let clock = try? await client.clockSnapshot()
            async let shifts = client.scheduledShifts(
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400))
            async let profile = try? await client.userProfile()

            var inputs = WorldInputs(
                projectDetails: details,
                shifts: try await shifts,
                clock: await clock,
                approvals: try await approvals,
                invoices: try await invoices,
                invoiceSummary: await summary,
                playerProfileName: await profile?.name,
                serverHost: client.credentials.baseURL.host,
                now: Date())

            var mapped = WorldMapper.map(inputs)

            // Fill in coordinates the API didn't have (geocode by address).
            for idx in mapped.sites.indices {
                if mapped.sites[idx].coordinate == nil,
                   let address = mapped.sites[idx].pendingGeocodeAddress {
                    mapped.sites[idx].coordinate = await geocoder.coordinate(for: address)
                }
            }
            logGeocodeSummary(mapped.sites)

            world = mapped
            lastLoadedAt = Date()
            phase = .ready
            scheduleGeocodeRetry()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Geocode follow-up

    /// Say where the board stands after a load: how many sites placed, and
    /// which addresses are still waiting (the geocoder logs each miss itself).
    private func logGeocodeSummary(_ sites: [WorldSite]) {
        let placed = sites.filter { $0.coordinate != nil }.count
        let misses = sites.filter { $0.coordinate == nil && $0.pendingGeocodeAddress != nil }
        let addressless = sites.count - placed - misses.count
        Self.log.info("world board: \(placed) sites placed, \(addressless) projects without an address, \(misses.count) geocode misses")
        if !misses.isEmpty {
            Self.log.warning("geocode still waiting on: \(misses.compactMap(\.pendingGeocodeAddress).joined(separator: " | "), privacy: .public)")
        }
    }

    /// One delayed second pass over geocode misses: Apple's geocoder often
    /// succeeds a beat later, and the board should heal itself without a
    /// manual refresh. The geocoder's own attempt cap bounds total retries.
    private func scheduleGeocodeRetry() {
        let pending = world.sites.filter { $0.coordinate == nil && $0.pendingGeocodeAddress != nil }
        guard !pending.isEmpty, !geocodeRetryScheduled else { return }
        geocodeRetryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.phase == .ready else { return }
            var updated = self.world
            var changed = false
            for idx in updated.sites.indices {
                if updated.sites[idx].coordinate == nil,
                   let address = updated.sites[idx].pendingGeocodeAddress,
                   let coordinate = await self.geocoder.coordinate(for: address) {
                    updated.sites[idx].coordinate = coordinate
                    changed = true
                }
            }
            if changed {
                self.world = updated
                Self.log.info("geocode retry pass placed more sites")
            }
            self.geocodeRetryScheduled = false
        }
    }

    // MARK: In-world actions (write through the API, then refetch)

    enum MailAction: String {
        case approve
        /// No dedicated delegate endpoint exists; a delegate is recorded as a
        /// comment naming the person, through the supported action route.
        case delegate
        /// An answer is a comment on the request.
        case answer
    }

    func perform(_ action: MailAction, on mail: WorldMailItem, note: String, delegateTo: String? = nil) async -> Bool {
        guard let client else { return false }
        let apiAction: String
        var comment: String? = nil
        switch action {
        case .approve:
            apiAction = "approve"
        case .delegate:
            apiAction = "comment"
            let who = delegateTo?.isEmpty == false ? delegateTo! : "the team"
            comment = "Delegated to \(who)" + (note.isEmpty ? "" : " — \(note)")
        case .answer:
            apiAction = "comment"
            comment = note
        }
        do {
            try await client.act(onApprovalID: mail.id, action: apiAction, comment: comment)
            await loadWorld()
            return true
        } catch {
            return false
        }
    }
}
