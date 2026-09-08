//  AddressGeocoder.swift
//  OfficeAdminGame
//
//  Turns a project's free-text siteAddress into a real coordinate via
//  CLGeocoder, for sites whose project record has no siteLat/siteLng. This is
//  the ONLY impure step between API records and world placement, so it lives
//  beside the pure WorldMapper, not inside it. Successful results are cached
//  by address string; misses are LOGGED and retried on later world loads
//  (Apple's geocoder fails transiently under rate limits) until an attempt
//  cap gives up on the address for the app run.

import CoreLocation
import Foundation
import os

actor AddressGeocoder {
    /// Placed addresses only — misses stay out of the cache so they retry.
    private var cache: [String: CLLocationCoordinate2D] = [:]
    /// Attempts per address across the app run, misses and errors both.
    private var attempts: [String: Int] = [:]
    private let geocoder = CLGeocoder()
    private static let maxAttemptsPerAddress = 6
    private static let log = Logger(subsystem: "com.officeadmin.game", category: "geocoder")

    /// Geocode one address; nil when Apple can't place it (yet). Transient
    /// errors get one immediate in-call retry; every miss also retries on the
    /// next `coordinate(for:)` call until the attempt cap.
    func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = cache[trimmed] { return cached }

        var tries = attempts[trimmed] ?? 0
        guard tries < Self.maxAttemptsPerAddress else { return nil }

        for tryNumber in 1...2 where tries < Self.maxAttemptsPerAddress {
            do {
                let placemarks = try await geocoder.geocodeAddressString(trimmed)
                guard let location = placemarks.first?.location,
                      WorldRules.isPlausible(location.coordinate) else {
                    // The address resolves to nothing — a real miss, not an
                    // error. Retry on the next world load.
                    tries += 1
                    attempts[trimmed] = tries
                    Self.log.warning("geocode miss: no placemark for \(trimmed, privacy: .public) (attempt \(tries))")
                    return nil
                }
                cache[trimmed] = location.coordinate
                attempts[trimmed] = nil
                Self.log.info("geocode placed \(trimmed, privacy: .public)")
                return location.coordinate
            } catch {
                tries += 1
                attempts[trimmed] = tries
                Self.log.warning("geocode failed for \(trimmed, privacy: .public): \(error.localizedDescription, privacy: .public) (attempt \(tries))")
                // Network/rate-limit errors usually clear in seconds.
                if tries < Self.maxAttemptsPerAddress, tryNumber < 2 {
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
        if tries >= Self.maxAttemptsPerAddress {
            Self.log.error("geocode exhausted \(Self.maxAttemptsPerAddress) attempts for \(trimmed, privacy: .public) — that project stays off the board until its address changes")
        }
        return nil
    }
}
