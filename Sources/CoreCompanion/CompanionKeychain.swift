import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Only device identity and pairing configuration are persisted on the phone. No objects,
/// passages, answers, Hub credentials or database files enter its persistent storage.
public enum CompanionKeychain {
    private static let service = "com.gunndamental.OpenCore.companion.v1"
    public static func read(_ account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return data
    }
    public static func write(_ data: Data, account: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        let status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: account, kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    public static func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

#if os(iOS)
@MainActor
public final class CompanionPhoneIdentity {
    public let id: UUID
    public let publicKey: Data
    private let key: SecureEnclave.P256.Signing.PrivateKey
    private let context: LAContext
    private init(id: UUID, key: SecureEnclave.P256.Signing.PrivateKey, context: LAContext) {
        self.id = id; self.key = key; publicKey = key.publicKey.x963Representation; self.context = context
    }
    public static func unlock() async throws -> CompanionPhoneIdentity {
        guard SecureEnclave.isAvailable else { throw CompanionError.unauthorized }
        let context = LAContext()
        context.localizedCancelTitle = "Keep OpenCore locked"
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Connect to your Mac and read your OpenCore history") else { throw CompanionError.unauthorized }
        let key: SecureEnclave.P256.Signing.PrivateKey
        if let stored = try CompanionKeychain.read("phone.signing-key") {
            key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored, authenticationContext: context)
        } else {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .biometryCurrentSet], &error) else { throw CompanionError.unauthorized }
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
            try CompanionKeychain.write(key.dataRepresentation, account: "phone.signing-key")
        }
        let id: UUID
        if let data = try CompanionKeychain.read("phone.id"), let decoded = try? JSONDecoder().decode(UUID.self, from: data) { id = decoded }
        else { id = UUID(); try CompanionKeychain.write(try JSONEncoder().encode(id), account: "phone.id") }
        return CompanionPhoneIdentity(id: id, key: key, context: context)
    }
    /// Explicit recovery after biometric enrollment invalidates the protected key. A new
    /// identity must be paired in person; the Mac never silently trusts its replacement.
    public static func forgetIdentity() throws {
        try CompanionKeychain.delete("phone.signing-key")
        try CompanionKeychain.delete("phone.id")
    }
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
    public func invalidate() { context.invalidate() }
}
#endif
