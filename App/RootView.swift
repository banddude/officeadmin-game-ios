//  RootView.swift
//  OfficeAdminGame
//
//  First launch: a sign-in that feels like a game title screen, not a login
//  form. After that, the world — with a door into the office.

import SwiftUI

struct RootView: View {
    @State private var store = GameStore()
    @State private var showingConnectionSetup = false

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            switch store.phase {
            case .needsSetup:
                SetupView(store: store)
            case .loading:
                LoadingView
            case .ready:
                WorldSceneView(store: store)
            case .failed(let message):
                FailureView(message: message, store: store)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if store.phase == .ready {
                Button {
                    showingConnectionSetup = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.72))
                        .padding(12)
                        .background(Circle().fill(Theme.parchment))
                }
                .accessibilityLabel("Connection settings")
                .padding(.trailing, 18)
                .padding(.bottom, 18)
            }
        }
        .fullScreenCover(isPresented: $showingConnectionSetup) {
            ZStack(alignment: .topTrailing) {
                Theme.paper.ignoresSafeArea()
                SetupView(store: store) {
                    showingConnectionSetup = false
                }
                Button {
                    showingConnectionSetup = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.65))
                        .padding(10)
                        .background(Circle().fill(Theme.parchment))
                }
                .accessibilityLabel("Close connection settings")
                .padding(18)
            }
        }
        .task { store.restoreSession() }
    }

    private var LoadingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.sage)
                .symbolEffect(.pulse)
            Text("Opening the world…")
                .font(Theme.rounded(20, .semibold))
                .foregroundStyle(Theme.ink)
        }
    }

    private func FailureView(message: String, store: GameStore) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "cloud.sun.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.honey)
            Text("The world couldn't load")
                .font(Theme.rounded(24, .bold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(Theme.rounded(15))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await store.loadWorld() }
            } label: {
                Text("Try again")
                    .font(Theme.rounded(17, .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Theme.clay))
                    .foregroundStyle(.white)
            }
            Button("Change connection") {
                store.disconnect()
            }
            .font(Theme.rounded(15))
            .foregroundStyle(Theme.ink.opacity(0.6))
        }
    }
}

// MARK: - First-launch setup

struct SetupView: View {
    let store: GameStore
    var onConnected: (() -> Void)? = nil

    @State private var baseURLText = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var rejected = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.sage)
                Text("Shaffer Construction")
                    .font(Theme.rounded(30, .bold))
                    .foregroundStyle(Theme.ink)
                Text("A world built from your company")
                    .font(Theme.rounded(16))
                    .foregroundStyle(Theme.ink.opacity(0.65))
            }

            VStack(alignment: .leading, spacing: 14) {
                field(title: "OfficeAdmin server", placeholder: "https://books.example.com",
                      text: $baseURLText, keyboard: .URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                SecureField("API key (dk_…)", text: $apiKey)
                    .font(Theme.rounded(16))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.12)))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if rejected {
                    Text("That key wasn't accepted by the server. Check the address and key.")
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.brick)
                }
            }
            .padding(.horizontal, 32)

            Button {
                connect()
            } label: {
                Group {
                    if checking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Enter the world")
                            .font(Theme.rounded(18, .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(canConnect ? Theme.clay : Theme.ink.opacity(0.2)))
                .foregroundStyle(.white)
            }
            .disabled(!canConnect || checking)
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private var canConnect: Bool {
        let trimmedURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count > 8
    }

    private func field(title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Theme.ink.opacity(0.6))
            TextField(placeholder, text: text)
                .font(Theme.rounded(16))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.12)))
        }
    }

    private func connect() {
        guard let url = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            rejected = true
            return
        }
        checking = true
        rejected = false
        Task {
            let ok = await store.connect(baseURL: url, apiKey: apiKey)
            checking = false
            if ok {
                onConnected?()
            } else {
                rejected = true
            }
        }
    }
}
