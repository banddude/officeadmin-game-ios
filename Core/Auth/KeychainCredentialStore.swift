//  KeychainCredentialStore.swift
//  OfficeAdminGame
//
//  Keychain-backed store for the OfficeAdmin connection settings. One
//  generic-password item holds the JSON-encoded GameCredentials; nothing is
//  ever written to UserDefaults, plists, or source. Device-only, available
//  after first unlock — this is a game about one company on one phone.

import Foundation
import Security

enum KeychainCredentialStore {
    private static let service = "com.officeadmin.game"
    private static let account = "world-connection"

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Keychain error (\(status))."
            }
        }
    }

    static func load() -> GameCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GameCredentials.self, from: data)
    }

    static func save(_ credentials: GameCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unhandled(update) }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unhandled(add) }
        } else {
            throw KeychainError.unhandled(status)
        }
    }

    static func erase() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
