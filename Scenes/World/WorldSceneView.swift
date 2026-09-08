//  WorldSceneView.swift
//  OfficeAdminGame
//
//  The world the game opens into: a walkable RealityKit diorama of the real
//  job sites, with the HUD cards from the approved mockup floating over it.
//  The player walks with the thumbstick or by tapping the ground; walking up
//  to a site shows its card, walking into an attention pickup opens it, and
//  stepping through the office door goes inside.

import SwiftUI

struct WorldSceneView: View {
    @Bindable var store: GameStore
    var artProvider: any WorldArtProviding = WorldArt.provider

    @State private var moveInput = SIMD2<Float>.zero
    @State private var nearSiteID: String?
    @State private var showingOffice = false
    @State private var pickup: WorldPickup?
    @State private var actionError: String?
    @State private var showHint = true

    var body: some View {
        ZStack {
            WorldRealityView(
                world: store.world,
                moveInput: moveInput,
                onNearSite: { id in
                    withAnimation(.snappy(duration: 0.25)) { nearSiteID = id }
                },
                onPickup: { target in
                    withAnimation(.snappy(duration: 0.25)) { pickup = target }
                },
                onEnterOffice: {
                    moveInput = .zero
                    showingOffice = true
                },
                artProvider: artProvider)
                .ignoresSafeArea()

            chrome

            if let site = nearSite, pickup == nil {
                SiteCardView(site: site) {
                    withAnimation(.snappy(duration: 0.25)) { nearSiteID = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            pickupCard
        }
        .fullScreenCover(isPresented: $showingOffice) {
            OfficeSceneView(store: store) {
                showingOffice = false
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(9))
            withAnimation(.easeOut(duration: 1)) { showHint = false }
        }
    }

    private var nearSite: WorldSite? {
        guard let nearSiteID else { return nil }
        return store.world.sites.first { $0.id == nearSiteID }
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

            bottomControls
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    /// The thumbstick plus a fading first-time hint.
    private var bottomControls: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                JoystickView { moveInput = $0 }
                Spacer()
                if showHint {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.clay)
                        Text("Tap the ground to walk.\nVisit your sites — the door goes inside.")
                            .font(Theme.rounded(13, .semibold))
                            .foregroundStyle(Theme.ink.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.parchment.opacity(0.95))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    )
                    .padding(.trailing, 4)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
                }
            }
        }
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

    // MARK: Pickup cards

    /// The card for whatever the player just walked into, presented in the
    /// world: approvals reuse the office mail card (actions write through
    /// the real API); invoice notes show the money that needs chasing.
    @ViewBuilder
    private var pickupCard: some View {
        if let target = pickup {
            VStack(spacing: 8) {
                switch target {
                case .mail(let id):
                    if let mail = store.world.mail.first(where: { $0.id == id }) {
                        MailCardView(
                            mail: mail,
                            crewNames: store.world.crew.filter { !$0.isPlayer }.map(\.name),
                            isBusy: performingAction,
                            onDismiss: { dismissPickup() },
                            onAction: { kind, note, delegateTo in
                                Task {
                                    let ok = await store.perform(kind, on: mail, note: note, delegateTo: delegateTo)
                                    if ok { dismissPickup() } else {
                                        actionError = "The server wouldn't take it. Try again."
                                    }
                                }
                            })
                        if let actionError {
                            Text(actionError)
                                .font(Theme.rounded(13, .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Capsule().fill(Theme.brick))
                        }
                    }
                case .invoice(let id):
                    if let note = store.world.whiteboard.first(where: { $0.id == id }) {
                        InvoiceNoteCard(note: note, onDismiss: { dismissPickup() })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 132)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var performingAction: Bool {
        store.phase == .loading
    }

    private func dismissPickup() {
        actionError = nil
        withAnimation(.snappy(duration: 0.25)) { pickup = nil }
    }
}

// MARK: - Attention cards (top right)

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

// MARK: - Invoice note card (money as an in-world encounter)

private struct InvoiceNoteCard: View {
    let note: WorldWhiteboardNote
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(note.isUrgent ? Theme.brick : Theme.honey)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(note.invoiceNumber) — \(note.customerName)")
                        .font(Theme.rounded(18, .bold))
                        .foregroundStyle(Theme.ink)
                    Text(dueLine)
                        .font(Theme.rounded(14))
                        .foregroundStyle(Theme.ink.opacity(0.65))
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .padding(8)
                        .background(Circle().fill(Theme.paper))
                }
            }

            HStack(spacing: 10) {
                Text(note.amountDueCents.moneyString)
                    .font(Theme.rounded(24, .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("The money stack on the office desk follows this too.")
                    .font(Theme.rounded(12))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .multilineTextAlignment(.trailing)
            }
        }
        .worldCard()
    }

    private var dueLine: String {
        switch note.state {
        case .overdue(let days): return "Overdue by \(days) day\(days == 1 ? "" : "s")"
        case .comingDue(let days): return "Due in \(days) day\(days == 1 ? "" : "s")"
        case .current: return "Current"
        }
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
        .allowsHitTesting(true)
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
