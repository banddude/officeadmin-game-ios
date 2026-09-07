//  WorldSceneView.swift
//  OfficeAdminGame
//
//  The 3D world the game opens into: real geography, your job sites on it,
//  your crew standing where the data says they are. Tapping a site travels
//  there (the camera swoops in); the door button walks you into the office.

import SwiftUI

struct WorldSceneView: View {
    @Bindable var store: GameStore
    var artProvider: any WorldArtProviding = WorldArt.provider
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
                },
                artProvider: artProvider)

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

    // MARK: Chrome

    private var chrome: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 10) {
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

                VStack(alignment: .leading, spacing: 3) {
                    Text("Shaffer Construction")
                        .font(Theme.rounded(22, .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Powering a Brighter L.A.")
                        .font(Theme.rounded(13, .medium))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.paper.opacity(0.94))
                        .shadow(color: .black.opacity(0.12), radius: 9, y: 3)
                )
            }

            VStack(spacing: 10) {
                WorldAttentionCard(
                    kind: .approval,
                    title: "Approval needed",
                    detail: approvalDetail,
                    count: store.world.mail.count,
                    artProvider: artProvider)
                WorldAttentionCard(
                    kind: .invoicePayment,
                    title: "Invoice due",
                    detail: invoiceDueDetail,
                    count: store.world.whiteboard.count,
                    artProvider: artProvider)
                WorldAttentionCard(
                    kind: .inspection,
                    title: "Inspection today",
                    detail: "Feed not connected",
                    count: nil,
                    artProvider: artProvider)
            }
            .frame(maxWidth: .infinity, alignment: .topTrailing)

            VStack {
                Spacer()
                HStack {
                    Button {
                        showingOffice = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 22, weight: .semibold))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Shaffer office")
                                    .font(Theme.rounded(14, .bold))
                                Text("Go inside")
                                    .font(Theme.rounded(11, .medium))
                                    .opacity(0.72)
                            }
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Theme.parchment.opacity(0.96))
                                .shadow(color: .black.opacity(0.14), radius: 9, y: 3)
                        )
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var approvalDetail: String {
        guard let item = store.world.mail.first else { return "Nothing waiting" }
        return item.envelopeTitle
    }

    private var invoiceDueDetail: String {
        guard let note = store.world.whiteboard.min(by: { $0.dueDate < $1.dueDate }) else {
            return "Nothing due soon"
        }
        return "\(note.customerName) · \(note.amountDueCents.moneyString)"
    }

}


private struct WorldAttentionCard: View {
    let kind: WorldArt.AttentionKind
    let title: String
    let detail: String
    let count: Int?
    let artProvider: any WorldArtProviding

    var body: some View {
        HStack(spacing: 11) {
            Image(uiImage: artProvider.attentionSprite(kind, side: 44))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.rounded(14, .bold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(Theme.rounded(11, .medium))
                    .foregroundStyle(Theme.ink.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let count {
                Text("\(count)")
                    .font(Theme.rounded(14, .bold))
                    .foregroundStyle(Theme.ink.opacity(count > 0 ? 0.88 : 0.42))
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.32))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.paper.opacity(0.95))
                .shadow(color: .black.opacity(0.13), radius: 9, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.ink.opacity(0.06), lineWidth: 1)
        )
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
