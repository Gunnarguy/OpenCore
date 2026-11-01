import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Per-account system Keychain storage shared by the app and CLI. Background lookups never
/// request authentication UI. A user-initiated save or unlock may explicitly allow it.
///
/// The former `.credentials.vault` is a read-only recovery source. Its v1 key was derived from
/// public information, so encryption did not protect it from another process running as the
/// same user. Existing bytes are preserved, and new credentials are never written there.
public enum Keychain {
    public static let service = "com.gunndamental.OpenCore"

    public enum Account: String, Sendable, CaseIterable {
        case githubToken = "github.token"
    }

    public enum Authentication: Sendable, Equatable {
        case nonInteractive
        case allowInteraction
    }

    public enum StorageSource: Sendable, Equatable {
        case keychain
        case legacyVault
    }

    public enum ReadResult: Sendable {
        case found(String, source: StorageSource)
        case missing
        case authenticationRequired
        case failed(KeychainError)

        public var value: String? {
            if case .found(let value, _) = self { return value }
            return nil
        }
    }

    public static func mcpAccount(server: String, variable: String) -> String {
        "mcp.\(server).env.\(variable)"
    }

    public enum KeychainError: Error, Sendable, CustomStringConvertible, LocalizedError {
        case failed(OSStatus)
        case storageError(String)

        public var description: String {
            switch self {
            case .failed(let status):
                if Self.requiresAuthentication(status) {
                    return "Your saved credential needs Keychain access. Use an explicit sign-in or save action to authorize access."
                }
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            case .storageError(let reason):
                return "credential storage error: \(reason)"
            }
        }

        public var errorDescription: String? { description }

        static func requiresAuthentication(_ status: OSStatus) -> Bool {
            status == errSecInteractionNotAllowed || status == errSecInteractionRequired
                || status == errSecAuthFailed || status == errSecUserCanceled
        }
    }

    private static let storage = CredentialStorage(
        backend: SystemCredentialKeychain(),
        legacyVault: LegacyCredentialVault(url: legacyVaultURL, username: NSUserName())
    )

    public static func read(_ account: Account) -> String? {
        read(account: account.rawValue)
    }

    public static func read(account: String) -> String? {
        readResult(account: account).value
    }

    /// Use this result when displaying saved-credential status: inaccessible and corrupt
    /// credentials must not be rendered as though no credential had ever been saved.
    public static func readResult(
        _ account: Account, authentication: Authentication = .nonInteractive
    ) -> ReadResult {
        readResult(account: account.rawValue, authentication: authentication)
    }

    public static func readResult(
        account: String, authentication: Authentication = .nonInteractive
    ) -> ReadResult {
        storage.read(account: account, authentication: authentication)
    }

    public static func write(
        _ value: String, to account: Account, authentication: Authentication = .nonInteractive
    ) throws {
        try write(value, toAccount: account.rawValue, authentication: authentication)
    }

    public static func write(
        _ value: String, toAccount account: String, authentication: Authentication = .nonInteractive
    ) throws {
        try storage.write(value, account: account, authentication: authentication)
    }

    public static func delete(
        _ account: Account, authentication: Authentication = .nonInteractive
    ) throws {
        try delete(account: account.rawValue, authentication: authentication)
    }

    public static func delete(
        account: String, authentication: Authentication = .nonInteractive
    ) throws {
        try storage.delete(account: account, authentication: authentication)
    }

    private static var legacyVaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenCore/.credentials.vault")
    }
}

/// Internal boundaries permit regression tests to use an in-memory backend and temporary
/// files exclusively. No credential cache exists: independent app and CLI processes see the
/// latest successful per-account Keychain write on their next lookup.
protocol CredentialKeychainBackend: Sendable {
    func read(account: String, authentication: Keychain.Authentication) throws -> Data?
    func store(_ data: Data, account: String, authentication: Keychain.Authentication) throws
}

protocol LegacyCredentialReading: Sendable {
    func read(account: String) throws -> String?
}

struct CredentialStorage: Sendable {
    let backend: any CredentialKeychainBackend
    let legacyVault: any LegacyCredentialReading

    // The prefix disambiguates our envelope from original unwrapped Keychain passwords.
    // A deletion is a durable per-account tombstone in the same atomic Keychain update as
    // the value. It prevents the preserved recovery vault from reviving a cleared secret.
    private static let prefix = Data("OpenCoreCredential:2\0".utf8)
    private struct Envelope: Codable {
        let value: String?
        let deleted: Bool
    }

    func read(account: String, authentication: Keychain.Authentication = .nonInteractive) -> Keychain.ReadResult {
        do {
            if let data = try backend.read(account: account, authentication: authentication) {
                if data.starts(with: Self.prefix) {
                    let envelope = try JSONDecoder().decode(Envelope.self, from: data.dropFirst(Self.prefix.count))
                    if envelope.deleted { return .missing }
                    guard let value = envelope.value, !value.isEmpty else {
                        return .failed(.storageError("Saved Keychain data is incomplete. It has not been replaced or removed."))
                    }
                    return .found(value, source: .keychain)
                }
                guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                    return .failed(.storageError("Saved Keychain data could not be decoded. It has not been replaced or removed."))
                }
                return .found(value, source: .keychain)
            }
            // Only an actually absent item falls back. Authentication or decode failures
            // must not silently bypass Keychain access controls or substitute an old token.
            if let value = try legacyVault.read(account: account), !value.isEmpty {
                return .found(value, source: .legacyVault)
            }
            return .missing
        } catch Keychain.KeychainError.failed(let status) where Keychain.KeychainError.requiresAuthentication(status) {
            return .authenticationRequired
        } catch let error as Keychain.KeychainError {
            return .failed(error)
        } catch {
            return .failed(.storageError("Saved credential data could not be decoded. The original data has been preserved."))
        }
    }

    func write(
        _ value: String, account: String, authentication: Keychain.Authentication = .nonInteractive
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: account, authentication: authentication)
            return
        }
        try store(Envelope(value: trimmed, deleted: false), account: account, authentication: authentication)
    }

    func delete(account: String, authentication: Keychain.Authentication = .nonInteractive) throws {
        // Retain a protected marker instead of deleting and then separately recording the
        // deletion. A failed update leaves the old credential and fallback behavior intact.
        try store(Envelope(value: nil, deleted: true), account: account, authentication: authentication)
    }

    private func store(_ envelope: Envelope, account: String, authentication: Keychain.Authentication) throws {
        var data = Self.prefix
        data.append(try JSONEncoder().encode(envelope))
        try backend.store(data, account: account, authentication: authentication)
    }
}

struct SystemCredentialKeychain: CredentialKeychainBackend {
    private func query(account: String, authentication: Keychain.Authentication) -> [String: Any] {
        let context = LAContext()
        // Apple's current replacement for the deprecated kSecUseAuthenticationUIFail.
        // Verified 2026-10-23: developer.apple.com/documentation/security/ksecuseauthenticationuifail
        context.interactionNotAllowed = authentication == .nonInteractive
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    func read(account: String, authentication: Keychain.Authentication) throws -> Data? {
        var query = query(account: account, authentication: authentication)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Keychain.KeychainError.failed(status) }
        guard let data = result as? Data else {
            throw Keychain.KeychainError.storageError("The Keychain returned an unexpected value.")
        }
        return data
    }

    func store(_ data: Data, account: String, authentication: Keychain.Authentication) throws {
        let query = query(account: account, authentication: authentication)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            status = SecItemAdd(addition as CFDictionary, nil)
            // Another process may have inserted this account after the first update.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw Keychain.KeychainError.failed(status) }
    }
}

/// Compatibility only. Never writes, removes, chmods, or enumerates system Keychain entries.
struct LegacyCredentialVault: LegacyCredentialReading {
    let url: URL
    let username: String

    func read(account: String) throws -> String? {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw Keychain.KeychainError.storageError("The legacy recovery vault could not be read. Its original file has been preserved.")
        }
        guard !raw.isEmpty else {
            throw Keychain.KeychainError.storageError("The legacy recovery vault is empty. Its original file has been preserved.")
        }
        // The previous release also accepted plaintext JSON; preserve that read-only
        // compatibility, without silently rewriting or claiming it is secure storage.
        if let plain = try? JSONDecoder().decode([String: String].self, from: raw) {
            return plain[account]
        }
        do {
            let seed = "\(Keychain.service)::\(username)::macOS-OpenCore-Vault-v1"
            let key = SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
            let box = try AES.GCM.SealedBox(combined: raw)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode([String: String].self, from: plaintext)[account]
        } catch {
            throw Keychain.KeychainError.storageError("The legacy recovery vault could not be decoded. It has not been replaced or removed. Save a replacement credential explicitly to use system Keychain storage.")
        }
    }
}

/// Where a resolved credential actually came from. These labels intentionally do not call a
/// value recovered from the former file vault a Keychain credential.
public enum CredentialSource: String, Sendable {
    case explicit = "passed directly"
    case environment = "GITHUB_TOKEN in the environment"
    case keychain = "saved in your keychain"
    case legacyVault = "the legacy recovery vault; save again to protect it in Keychain"
    case authenticationRequired = "Keychain access needs authorization"
    case storageError = "saved credentials could not be read"
    case ghCLI = "the gh CLI"
    case none = "not found"
}
