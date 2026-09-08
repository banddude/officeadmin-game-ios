//  GameCredentials.swift
//  OfficeAdminGame
//
//  The one secret-ish thing this app owns: where the OfficeAdmin server lives
//  and the dk_ API key that opens it. Entered by hand at first launch, then
//  kept in the Keychain — never in source, plists, or UserDefaults.

import Foundation

/// Connection settings for the OfficeAdmin server backing the world.
///
/// `organizationId` is optional: when nil the server auto-resolves the org for
/// single-membership keys (lib/api/auth-context.ts), same as a bare web call.
struct GameCredentials: Codable, Equatable {
    static let baseURLEnvironmentKey = "OFFICEADMIN_BASE_URL"
    static let apiKeyEnvironmentKey = "OFFICEADMIN_API_KEY"
    static let organizationIDEnvironmentKey = "OFFICEADMIN_ORGANIZATION_ID"

    var baseURL: URL
    var apiKey: String
    var organizationId: String?

    /// Explicit runtime injection for simulator/dev launches. These values
    /// are used in memory only and are never saved to the app Keychain.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> GameCredentials? {
        guard let base = environment[baseURLEnvironmentKey],
              let baseURL = URL(string: base),
              let apiKey = environment[apiKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return nil }
        let organizationId = environment[organizationIDEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GameCredentials(
            baseURL: baseURL,
            apiKey: apiKey,
            organizationId: organizationId?.isEmpty == false ? organizationId : nil)
    }

    /// Build-time bootstrap credentials are generated into the app bundle on
    /// trusted build machines. The source file is ignored by git and the
    /// values are never copied into source code.
    static func fromBootstrapBundle(_ bundle: Bundle = .main) -> GameCredentials? {
        guard let plistURL = bundle.url(forResource: "BootstrapCredentials", withExtension: "plist"),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any],
              let base = values["baseURL"] as? String,
              let baseURL = URL(string: base),
              let apiKey = (values["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return nil }

        let organizationId = (values["organizationId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GameCredentials(
            baseURL: baseURL,
            apiKey: apiKey,
            organizationId: organizationId?.isEmpty == false ? organizationId : nil)
    }

    /// The base URL normalized to end with exactly one trailing slash-less
    /// form, so `baseURL.appending(path:...)` never double-slashes.
    var normalizedBase: URL {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? baseURL
    }
}
