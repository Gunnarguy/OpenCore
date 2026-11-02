import CryptoKit
import Foundation

public struct CompanionHello: Codable, Sendable {
    public var version: Int = 1
    public var deviceID: UUID
    public var deviceName: String
    public var signingKey: Data
    public var ephemeralKey: Data
    public init(deviceID: UUID, deviceName: String, signingKey: Data, ephemeralKey: Data) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.signingKey = signingKey; self.ephemeralKey = ephemeralKey
    }
    public func proof(challenge: Data, hostKey: Data) throws -> Data {
        var data = Data("OpenCore owner channel v1\0".utf8)
        data.append(try JSONEncoder.companionCanonical.encode(self)); data.append(challenge); data.append(hostKey)
        return data
    }
}

extension JSONEncoder {
    static var companionCanonical: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }
}

public struct CompanionAuthentication: Codable, Sendable {
    public var signature: Data
    public var pairingCode: String?
    public init(signature: Data, pairingCode: String?) { self.signature = signature; self.pairingCode = pairingCode }
}

public struct CompanionDevice: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var signingKey: Data
    public var domains: Set<String>
    public var pairedAt: Date
    public var grantID: UUID
    public init(id: UUID, name: String, signingKey: Data, domains: Set<String>, pairedAt: Date, grantID: UUID = UUID()) {
        self.id = id; self.name = name; self.signingKey = signingKey; self.domains = domains; self.pairedAt = pairedAt; self.grantID = grantID
    }
}

public struct CompanionSessionKeys: Sendable {
    public var sending: SymmetricKey
    public var receiving: SymmetricKey
    public init(privateKey: P256.KeyAgreement.PrivateKey, peer: Data, hostPublicKey: Data, isHost: Bool) throws {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer))
        func key(_ direction: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: hostPublicKey,
                sharedInfo: Data(("OpenCore companion v1 " + direction).utf8), outputByteCount: 32)
        }
        sending = key(isHost ? "host to phone" : "phone to host")
        receiving = key(isHost ? "phone to host" : "host to phone")
    }
}

/// Pure codec, shared by both peers. Direction keys and authenticated sequence numbers
/// prevent replay and reflection. The 600-byte fragment size is chosen below tailnet MTU;
/// response size is bounded independently. No home-grown cryptographic primitive is used.
public struct CompanionCipher: Sendable {
    private let key: SymmetricKey
    private var sequence: UInt64 = 0
    public init(key: SymmetricKey) { self.key = key }
    public mutating func seal(_ data: Data) throws -> Data {
        guard data.count <= 601, sequence < UInt64.max else { throw CompanionError.invalidFrame }
        let header = withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
        let box = try AES.GCM.seal(data, using: key, authenticating: header)
        guard let combined = box.combined else { throw CompanionError.invalidFrame }
        sequence += 1
        return header + combined
    }
    public mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 36, data.count <= 637, sequence < UInt64.max else { throw CompanionError.invalidFrame }
        let header = data.prefix(8)
        let expected = withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
        guard header == expected else { throw CompanionError.invalidFrame }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(8)), using: key, authenticating: header)
        sequence += 1
        return plaintext
    }
}

/// Pairing codes are one-use, expire, and are never a persistent credential. Devices
/// authenticate each connection with their own signing key and a fresh Mac challenge.
public actor CompanionAuthority {
    struct AuthenticationResult: Sendable {
        let device: CompanionDevice
        let replacedGrant: UUID?
    }
    private var devices: [UUID: CompanionDevice]
    private var invitation: (code: String, expires: Date, domains: Set<String>)?
    private let persist: @Sendable ([CompanionDevice]) throws -> Void
    public init(devices: [CompanionDevice] = [], persist: @escaping @Sendable ([CompanionDevice]) throws -> Void = { _ in }) {
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) }); self.persist = persist
    }
    public func pairedDevices() -> [CompanionDevice] { devices.values.sorted { $0.pairedAt < $1.pairedAt } }
    public func issue(domains: Set<String>, now: Date = Date()) -> (String, Date) {
        let code = (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
        let expiry = now.addingTimeInterval(120) // Chosen two-minute in-person pairing window.
        invitation = (code, expiry, domains)
        return (code, expiry)
    }
    public func authenticate(_ hello: CompanionHello, authentication: CompanionAuthentication, challenge: Data,
                             hostKey: Data, now: Date = Date()) throws -> CompanionDevice {
        try authenticateWithTransition(hello, authentication: authentication, challenge: challenge, hostKey: hostKey, now: now).device
    }
    /// Return the exact displaced grant in the same actor turn that installs its replacement.
    /// Server cleanup may run later, after another grant has already been issued.
    func authenticateWithTransition(_ hello: CompanionHello, authentication: CompanionAuthentication, challenge: Data,
                                    hostKey: Data, now: Date = Date()) throws -> AuthenticationResult {
        guard hello.version == 1, challenge.count == 32, hello.signingKey.count == 65,
              hello.ephemeralKey.count == 65, hello.deviceName.count <= 80 else { throw CompanionError.unauthorized }
        let key = try P256.Signing.PublicKey(x963Representation: hello.signingKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: authentication.signature)
        guard key.isValidSignature(signature, for: try hello.proof(challenge: challenge, hostKey: hostKey)) else { throw CompanionError.unauthorized }
        if let device = devices[hello.deviceID] {
            guard device.signingKey == hello.signingKey else { throw CompanionError.unauthorized }
            // A code means the owner is deliberately issuing a new grant. Only an ordinary
            // code-free reconnect may retain the existing grant and its domain ceiling.
            if authentication.pairingCode == nil { return AuthenticationResult(device: device, replacedGrant: nil) }
        }
        guard let invite = invitation, invite.expires > now, let supplied = authentication.pairingCode else { throw CompanionError.unauthorized }
        // Hash comparison avoids leaking prefix length of the one-time pairing code.
        guard SHA256.hash(data: Data(invite.code.utf8)) == SHA256.hash(data: Data(supplied.utf8)) else { throw CompanionError.unauthorized }
        let device = CompanionDevice(id: hello.deviceID, name: hello.deviceName, signingKey: hello.signingKey, domains: invite.domains, pairedAt: now)
        var updated = devices; let replacedGrant = updated.updateValue(device, forKey: device.id)?.grantID
        try persist(Array(updated.values))
        devices = updated; invitation = nil
        return AuthenticationResult(device: device, replacedGrant: replacedGrant)
    }
    public func current(_ id: UUID) throws -> CompanionDevice {
        guard let value = devices[id] else { throw CompanionError.unauthorized }; return value
    }
    @discardableResult public func revoke(_ id: UUID) throws -> UUID? {
        var updated = devices; let removedGrant = updated.removeValue(forKey: id)?.grantID
        try persist(Array(updated.values)); devices = updated
        return removedGrant
    }
    public func cancelInvitation() { invitation = nil }
}
