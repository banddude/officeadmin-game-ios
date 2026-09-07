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
    var baseURL: URL
    var apiKey: String
    var organizationId: String?

    /// The base URL normalized to end with exactly one trailing slash-less
    /// form, so `baseURL.appending(path:...)` never double-slashes.
    var normalizedBase: URL {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? baseURL
    }
}
