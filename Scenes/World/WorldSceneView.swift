//  WorldSceneView.swift
//  OfficeAdminGame
//
//  The 3D world the game opens into: real geography, your job sites on it,
//  your crew standing where the data says they are. Tapping a site travels
//  there (the camera swoops in); the door button walks you into the office.

import SwiftUI

struct WorldSceneView: View {
    @Bindable var store: GameStore
    @State private var selectedSite: WorldSite?
    @State private var showingOffice = false

    var body: some View {
        ZStack {
            WorldMapView(
                sites: store.world.sites,
                selectedSiteID: store.traveledSiteID,
                onSelectSite: { site in
                    store.travel(to: site.id)
                    selectedSite = site
                })

            chrome

            if let site = selectedSite {
                SiteCardView(site: site) {
                    withAnimation(.snappy(duration: 0.25)) { selectedSite = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showingOffice) {
            OfficeSceneView(store: store) {
                showingOffice = false
            }
        }
    }

    // MARK: Chrome (the only UI over the world — no lists, no tables)

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { await store.loadWorld() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(12)
                        .background(Circle().fill(Theme.parchment))
                }
                .accessibilityLabel("Refresh the world")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Shaffer Construction")
                        .font(Theme.rounded(17, .bold))
                        .foregroundStyle(Theme.ink)
                    Text(worldSubtitle)
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.parchment))

                Spacer()

                if store.world.attentionCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                        Text("\(store.world.attentionCount)")
                    }
                    .font(Theme.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.brick))
                }

                Button {
                    showingOffice = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "door.left.hand.open")
                        Text("Office")
                    }
                    .font(Theme.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.clay))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
    }

    private var worldSubtitle: String {
        let placed = store.world.sites.filter { $0.coordinate != nil }.count
        let waiting = store.world.sites.filter { !$0.crewPresent.isEmpty }.count
        return "\(placed) sites · \(waiting) with crew on them"
    }
}

// MARK: - Site card (in-world, not a list)

struct SiteCardView: View {
    let site: WorldSite
    let onClose: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(site.name)
                            .font(Theme.rounded(20, .bold))
                            .foregroundStyle(Theme.ink)
                        if let customer = site.customerName {
                            Text(customer)
                                .font(Theme.rounded(14))
                                .foregroundStyle(Theme.ink.opacity(0.6))
                        }
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.6))
                            .padding(8)
                            .background(Circle().fill(Theme.paper))
                    }
                }

                HStack(spacing: 8) {
                    phaseChip
                    if let budget = site.budgetCents {
                        Label(budget.moneyString, systemImage: "banknote")
                            .font(Theme.rounded(13, .semibold))
                            .foregroundStyle(Theme.ink.opacity(0.75))
                    }
                    if site.waitingMailCount > 0 {
                        Label("\(site.waitingMailCount) waiting", systemImage: "envelope.fill")
                            .font(Theme.rounded(13, .bold))
                            .foregroundStyle(Theme.brick)
                    }
                }

                if !site.crewPresent.isEmpty {
                    crewRow(icon: "figure.stand", names: site.crewPresent,
                            tint: Theme.sage, caption: "On the job now")
                }
                if !site.crewScheduled.isEmpty {
                    crewRow(icon: "figure.walk.motion", names: site.crewScheduled,
                            tint: Theme.honey, caption: "Scheduled today")
                }
                if let address = site.pendingGeocodeAddress, site.coordinate == nil {
                    Text(address)
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                }
            }
            .worldCard()
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var phaseChip: some View {
        Text(site.phase.label)
            .font(Theme.rounded(12, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.phaseColor(site.phase)))
    }

    private func crewRow(icon: String, names: [String], tint: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(caption, systemImage: icon)
                .font(Theme.rounded(11, .semibold))
                .foregroundStyle(tint)
            Text(names.joined(separator: ", "))
                .font(Theme.rounded(14, .medium))
                .foregroundStyle(Theme.ink)
        }
    }
}
