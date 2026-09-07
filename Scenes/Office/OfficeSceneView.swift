//  OfficeSceneView.swift
//  OfficeAdminGame
//
//  The office from the inside: the walkable RealityKit room, a thumbstick to
//  move, and the mail pile that IS the pending approvals. Tapping an envelope
//  opens an in-world card with Approve / Delegate / Answer — each writes back
//  through the real API and the world refetches. Crew members with no site
//  assignment stand around the room (they're "in the office" per the data).

import SwiftUI

struct OfficeSceneView: View {
    @Bindable var store: GameStore
    let onExit: () -> Void

    @State private var moveInput = SIMD2<Float>.zero
    @State private var openMailID: String?
    @State private var actionError: String?

    var body: some View {
        ZStack {
            OfficeRealityView(
                world: store.world,
                onTapMail: { id in
                    withAnimation(.snappy(duration: 0.25)) { openMailID = id }
                })
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onExit) {
                        HStack(spacing: 6) {
                            Image(systemName: "door.right.hand.open")
                            Text("Back to world")
                        }
                        .font(Theme.rounded(15, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.ink.opacity(0.75)))
                    }
                    Spacer()
                    glanceChip
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if openMail == nil {
                    HStack {
                        JoystickView { moveInput = $0 }
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "envelope.fill")
                            Text("Tap the mail pile")
                        }
                        .font(Theme.rounded(13, .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.75))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.parchment.opacity(0.9)))
                        .padding(.trailing, 16)
                    }
                    .padding(.bottom, 24)
                }
            }

            if let mail = openMail {
                VStack {
                    Spacer()
                    MailCardView(
                        mail: mail,
                        crewNames: store.world.crew.filter { !$0.isPlayer }.map(\.name),
                        isBusy: performingAction,
                        onDismiss: {
                            withAnimation(.snappy(duration: 0.25)) { openMailID = nil }
                        },
                        onAction: { kind, note, delegateTo in
                            Task {
                                let ok = await store.perform(kind, on: mail, note: note, delegateTo: delegateTo)
                                if ok {
                                    withAnimation(.snappy(duration: 0.25)) { openMailID = nil }
                                } else {
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
                            .padding(.bottom, 6)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: openMailID) { _, _ in actionError = nil }
    }

    private var openMail: WorldMailItem? {
        guard let openMailID else { return nil }
        return store.world.mail.first { $0.id == openMailID }
    }

    private var performingAction: Bool {
        store.phase == .loading
    }

    /// A one-glance read of the world's money — the real display is the coin
    /// stack and the red letters on the desk; this just points your eye.
    private var glanceChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "banknote.fill")
                .foregroundStyle(Theme.honey)
            Text(store.world.money.outstandingCents.moneyString)
            if store.world.money.hasOverdue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.48))
                Text("\(store.world.money.overdueCount) late")
            }
        }
        .font(Theme.rounded(14, .bold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.parchment.opacity(0.95)))
    }
}

// MARK: - The mail card (in-world card, not a screen)

struct MailCardView: View {
    let mail: WorldMailItem
    let crewNames: [String]
    let isBusy: Bool
    let onDismiss: () -> Void
    let onAction: (GameStore.MailAction, String, String?) -> Void

    enum Mode: Hashable {
        case choose
        case approve
        case delegate
        case answer
    }

    @State private var mode: Mode = .choose
    @State private var note = ""
    @State private var delegateTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.clay)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mail.envelopeTitle)
                        .font(Theme.rounded(19, .bold))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 8) {
                        if let from = mail.fromName {
                            Text("from \(from)")
                        }
                        Text(mail.createdAt, style: .date)
                        Text("step \(mail.stepOrder)")
                    }
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.ink.opacity(0.6))
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

            switch mode {
            case .choose:
                VStack(spacing: 10) {
                    actionButton("checkmark.circle.fill", "Approve", tint: Theme.sage) {
                        mode = .approve
                    }
                    actionButton("person.wave.2.fill", "Delegate", tint: Theme.sky) {
                        mode = .delegate
                    }
                    actionButton("text.bubble.fill", "Answer", tint: Theme.honey) {
                        mode = .answer
                    }
                }
            case .approve:
                Text("Approve this \(mail.kind.label.lowercased())?")
                    .font(Theme.rounded(15))
                    .foregroundStyle(Theme.ink)
                noteField(placeholder: "A note with your approval (optional)")
                HStack(spacing: 10) {
                    backButton
                    commitButton("Approve it", tint: Theme.sage) {
                        onAction(.approve, note, nil)
                    }
                }
            case .delegate:
                Menu {
                    ForEach(crewNames, id: \.self) { name in
                        Button(name) { delegateTo = name }
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text(delegateTo.isEmpty ? "Hand it to…" : delegateTo)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
                }
                noteField(placeholder: "What should they do with it?")
                HStack(spacing: 10) {
                    backButton
                    commitButton("Hand it off", tint: Theme.sky) {
                        onAction(.delegate, note, delegateTo)
                    }
                }
            case .answer:
                noteField(placeholder: "Write your answer…")
                HStack(spacing: 10) {
                    backButton
                    commitButton("Send answer", tint: Theme.honey) {
                        onAction(.answer, note, nil)
                    }
                }
            }
        }
        .worldCard()
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
    }

    private var backButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { mode = .choose }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .padding(12)
                .background(Circle().fill(Theme.paper))
        }
        .accessibilityLabel("Back")
    }

    private func actionButton(_ icon: String, _ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .font(Theme.rounded(16, .semibold))
            .foregroundStyle(Theme.ink)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.paper))
        }
    }

    private func commitButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .font(Theme.rounded(16, .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(tint))
            .foregroundStyle(.white)
        }
    }

    private func noteField(placeholder: String) -> some View {
        TextField(placeholder, text: $note, axis: .vertical)
            .font(Theme.rounded(15))
            .lineLimit(1...4)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
    }
}
