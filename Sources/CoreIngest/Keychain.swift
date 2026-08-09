import Foundation
import Security

/// Credential storage, in the system keychain.
///
/// This exists because the store must never hold a secret. `source.config` records the *names*
/// of environment variables; the actual values live here or in the environment, and the
/// database stays a thing you could hand someone.
///
/// Keychain rather than a config file for the ordinary reason: a file in Application Support is
/// readable by anything running as the user, survives in backups as plaintext, and shows up in
/// spotlight indexes. The keychain is encrypted at rest and access-controlled.
public enum Keychain {
    /// One keychain service for the whole app, with each credential distinguished by account.
    public static let service = "com.gunndamental.OpenCore"

    public enum Account: String, Sendable, CaseIterable {
        case githubToken = "github.token"
    }

    /// Account name for one environment variable belonging to one MCP server.
    ///
    /// Namespaced per server rather than per variable name, because two servers can both want
    /// `API_KEY` and they are not the same secret.
    public static func mcpAccount(server: String, variable: String) -> String {
        "mcp.\(server).env.\(variable)"
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case failed(OSStatus)

        public var description: String {
            // SecCopyErrorMessageString gives a human sentence instead of a bare number.
            switch self {
            case .failed(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            }
        }
    }

    public static func read(_ account: Account) -> String? {
        read(account: account.rawValue)
    }

    public static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Write, replacing any existing value. An empty string deletes instead, so "clear the
    /// field and save" does what a user expects rather than storing an empty credential that
    /// then fails authentication confusingly.
    public static func write(_ value: String, to account: Account) throws {
        try write(value, toAccount: account.rawValue)
    }

    public static func write(_ value: String, toAccount account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete(account: account) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            // Available after first unlock, not while locked. This is a background-sync
            // credential, not something needed at the login window.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.failed(updated) }

        let added = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.failed(added) }
    }

    public static func delete(_ account: Account) throws {
        try delete(account: account.rawValue)
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Deleting something that was never there is a success, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed(status)
        }
    }
}

/// Where a resolved credential actually came from.
///
/// Surfaced in the UI rather than kept internal, because "why is it still using the old token"
/// is otherwise unanswerable: four sources with a precedence order and no way to see which one
/// won is exactly the kind of invisible state this project exists to avoid.
public enum CredentialSource: String, Sendable {
    case explicit = "passed directly"
    case environment = "GITHUB_TOKEN in the environment"
    case keychain = "saved in your keychain"
    case ghCLI = "the gh CLI"
    case none = "not found"
}
