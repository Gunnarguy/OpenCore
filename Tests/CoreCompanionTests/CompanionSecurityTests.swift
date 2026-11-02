import CryptoKit
import Foundation
import Testing
@testable import CoreCompanion

private actor SuspendedHandshake: CompanionTransport {
    private var gate: CheckedContinuation<Data, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var reachedChallenge = false
    private(set) var closed = false
    func secure(_ keys: CompanionSessionKeys) { }
    func close() { closed = true }
    func send<T: Encodable & Sendable>(_ value: T) { }
    func receive<T: Decodable & Sendable>(_ type: T.Type) async throws -> T {
        if type == Data.self {
            reachedChallenge = true; waiting?.resume(); waiting = nil
            let data = await withCheckedContinuation { gate = $0 }
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(data))
        }
        return try JSONDecoder().decode(T.self, from: Data("true".utf8))
    }
    func waitForChallenge() async {
        if !reachedChallenge { await withCheckedContinuation { waiting = $0 } }
    }
    func releaseChallenge() { gate?.resume(returning: Data(repeating: 3, count: 32)); gate = nil }
}

// A completed callback could previously publish a session after disconnect during Face ID/auth.
@Test("disconnect during authentication closes the pending transport and prevents publication")
func disconnectInvalidatesAnInFlightHandshake() async throws {
    let transport = SuspendedHandshake()
    let client = CompanionClient(makeTransport: { _ in transport })
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let signing = P256.Signing.PrivateKey()
    let invitation = CompanionInvitation(host: [100,64,0,2].map(String.init).joined(separator: "."), port: 12345,
        hostPublicKey: host, code: String(repeating: "a", count: 64), expiresAt: Date().addingTimeInterval(120))
    let connecting = Task {
        try await client.connect(invitation: invitation, deviceID: UUID(), deviceName: "Fixture phone", publicKey: signing.publicKey.x963Representation) {
            try signing.signature(for: $0).rawRepresentation
        }
    }
    await transport.waitForChallenge()
    await client.disconnect()
    #expect(await transport.closed)
    // Deliver already queued callbacks even after close, to prove the generation guard.
    await transport.releaseChallenge()
    await #expect(throws: (any Error).self) { try await connecting.value }
    #expect(await !client.isConnected)
}

@Test("companion traffic rejects tampering, replay and reflection")
func companionCipherAuthenticatesEveryFragment() throws {
    let host = P256.KeyAgreement.PrivateKey(), phone = P256.KeyAgreement.PrivateKey()
    let hostKeys = try CompanionSessionKeys(privateKey: host, peer: phone.publicKey.x963Representation,
        hostPublicKey: host.publicKey.x963Representation, isHost: true)
    let phoneKeys = try CompanionSessionKeys(privateKey: phone, peer: host.publicKey.x963Representation,
        hostPublicKey: host.publicKey.x963Representation, isHost: false)
    var sender = CompanionCipher(key: hostKeys.sending), receiver = CompanionCipher(key: phoneKeys.receiving)
    let frame = try sender.seal(Data("private fixture".utf8))
    #expect(try receiver.open(frame) == Data("private fixture".utf8))
    #expect(throws: (any Error).self) { try receiver.open(frame) }
    var reflected = CompanionCipher(key: hostKeys.receiving)
    #expect(throws: (any Error).self) { try reflected.open(frame) }
    var corrupt = frame; corrupt[corrupt.count - 1] ^= 1
    var clean = CompanionCipher(key: phoneKeys.receiving)
    #expect(throws: (any Error).self) { try clean.open(corrupt) }
    #expect(throws: (any Error).self) { try sender.seal(Data(repeating: 0, count: 602)) }
}

private func authentication(_ hello: CompanionHello, key: P256.Signing.PrivateKey, challenge: Data,
                            hostKey: Data, code: String?) throws -> CompanionAuthentication {
    CompanionAuthentication(signature: try key.signature(for: hello.proof(challenge: challenge, hostKey: hostKey)).rawRepresentation, pairingCode: code)
}

@Test("a stranger gets no device admission and a pairing code is one-use")
func strangerCannotUseTheOwnerChannel() async throws {
    let authority = CompanionAuthority()
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let key = P256.Signing.PrivateKey()
    let hello = CompanionHello(deviceID: UUID(), deviceName: "Fixture phone", signingKey: key.publicKey.x963Representation,
        ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    let nonce = Data(repeating: 7, count: 32), now = Date(timeIntervalSince1970: 1_800_000_000)
    let stranger = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: nil)
    await #expect(throws: (any Error).self) { try await authority.authenticate(hello, authentication: stranger, challenge: nonce, hostKey: host, now: now) }
    #expect(await authority.pairedDevices().isEmpty)
    let (code, _) = await authority.issue(domains: ["project","public"], now: now)
    let auth = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: code)
    let device = try await authority.authenticate(hello, authentication: auth, challenge: nonce, hostKey: host, now: now)
    #expect(device.id == hello.deviceID)
    let other = CompanionHello(deviceID: UUID(), deviceName: "Another fixture", signingKey: key.publicKey.x963Representation, ephemeralKey: hello.ephemeralKey)
    let reused = try authentication(other, key: key, challenge: nonce, hostKey: host, code: code)
    await #expect(throws: (any Error).self) { try await authority.authenticate(other, authentication: reused, challenge: nonce, hostKey: host, now: now) }
}

@Test("a new code replaces an existing phone grant and consumes the code")
func companionRePairReplacesExistingGrant() async throws {
    let authority = CompanionAuthority()
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation, key = P256.Signing.PrivateKey()
    let hello = CompanionHello(deviceID: UUID(), deviceName: "Fixture phone", signingKey: key.publicKey.x963Representation,
        ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    let nonce = Data(repeating: 5, count: 32), now = Date(timeIntervalSince1970: 1_800_000_000)
    let (firstCode, _) = await authority.issue(domains: ["project", "public", "medical"], now: now)
    let firstProof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: firstCode)
    let first = try await authority.authenticate(hello, authentication: firstProof, challenge: nonce, hostKey: host, now: now)
    let (secondCode, _) = await authority.issue(domains: ["project", "public"], now: now)
    let invalid = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: "invalid")
    await #expect(throws: (any Error).self) {
        try await authority.authenticate(hello, authentication: invalid, challenge: nonce, hostKey: host, now: now)
    }
    #expect(try await authority.current(hello.deviceID) == first)
    let secondProof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: secondCode)
    let second = try await authority.authenticate(hello, authentication: secondProof, challenge: nonce, hostKey: host, now: now)
    #expect(second.grantID != first.grantID)
    #expect(second.domains == ["project", "public"])
    #expect(try await authority.current(hello.deviceID) == second)
    let stranger = CompanionHello(deviceID: UUID(), deviceName: "Another fixture", signingKey: key.publicKey.x963Representation,
        ephemeralKey: hello.ephemeralKey)
    let reused = try authentication(stranger, key: key, challenge: nonce, hostKey: host, code: secondCode)
    await #expect(throws: (any Error).self) {
        try await authority.authenticate(stranger, authentication: reused, challenge: nonce, hostKey: host, now: now)
    }
    let reconnect = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: nil)
    #expect(try await authority.authenticate(hello, authentication: reconnect, challenge: nonce, hostKey: host, now: now) == second)
}

@Test("grant transitions identify only the grant they displaced")
func companionGrantTransitionIdentifiesDisplacedGrant() async throws {
    let authority = CompanionAuthority(), key = P256.Signing.PrivateKey()
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let hello = CompanionHello(deviceID: UUID(), deviceName: "Fixture phone", signingKey: key.publicKey.x963Representation,
        ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    let nonce = Data(repeating: 7, count: 32)
    let (firstCode, _) = await authority.issue(domains: ["project", "public", "medical"])
    let firstProof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: firstCode)
    let first = try await authority.authenticateWithTransition(hello, authentication: firstProof, challenge: nonce, hostKey: host)
    #expect(first.replacedGrant == nil)
    let (secondCode, _) = await authority.issue(domains: ["project", "public"])
    let secondProof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: secondCode)
    let second = try await authority.authenticateWithTransition(hello, authentication: secondProof, challenge: nonce, hostKey: host)
    #expect(second.replacedGrant == first.device.grantID)
    #expect(second.device.grantID != first.device.grantID)
    let reconnect = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: nil)
    let unchanged = try await authority.authenticateWithTransition(hello, authentication: reconnect, challenge: nonce, hostKey: host)
    #expect(unchanged.device == second.device)
    #expect(unchanged.replacedGrant == nil)
    #expect(try await authority.revoke(hello.deviceID) == second.device.grantID)
    #expect(try await authority.revoke(hello.deviceID) == nil)
}

@Test("failed re-pairing preserves the existing grant", arguments: ["expired", "wrong-key", "persistence"])
func companionRePairFailurePreservesExistingGrant(reason: String) async throws {
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation, key = P256.Signing.PrivateKey()
    let id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000), nonce = Data(repeating: 6, count: 32)
    let existing = CompanionDevice(id: id, name: "Fixture phone", signingKey: key.publicKey.x963Representation,
        domains: ["project", "public", "medical"], pairedAt: now)
    let authority = CompanionAuthority(devices: [existing], persist: { _ in
        if reason == "persistence" { throw CompanionError.disconnected }
    })
    let (code, expiry) = await authority.issue(domains: ["project", "public"], now: now)
    let suppliedKey = reason == "wrong-key" ? P256.Signing.PrivateKey() : key
    let hello = CompanionHello(deviceID: id, deviceName: "Fixture phone", signingKey: suppliedKey.publicKey.x963Representation,
        ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    let proof = try authentication(hello, key: suppliedKey, challenge: nonce, hostKey: host, code: code)
    await #expect(throws: (any Error).self) {
        try await authority.authenticate(hello, authentication: proof, challenge: nonce, hostKey: host,
                                         now: reason == "expired" ? expiry : now)
    }
    #expect(try await authority.current(id) == existing)
    let originalHello = CompanionHello(deviceID: id, deviceName: "Fixture phone", signingKey: key.publicKey.x963Representation,
        ephemeralKey: hello.ephemeralKey)
    let reconnect = try authentication(originalHello, key: key, challenge: nonce, hostKey: host, code: nil)
    #expect(try await authority.authenticate(originalHello, authentication: reconnect, challenge: nonce, hostKey: host, now: now) == existing)
}

@Test("revocation and fresh challenges invalidate a previously authorized phone")
func revokedPhoneAndReplayedProofAreRefused() async throws {
    let authority = CompanionAuthority()
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let key = P256.Signing.PrivateKey()
    let hello = CompanionHello(deviceID: UUID(), deviceName: "Fixture phone", signingKey: key.publicKey.x963Representation,
        ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    let nonce = Data(repeating: 9, count: 32), now = Date(timeIntervalSince1970: 1_800_000_000)
    let (code, _) = await authority.issue(domains: ["project"], now: now)
    let proof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: code)
    _ = try await authority.authenticate(hello, authentication: proof, challenge: nonce, hostKey: host, now: now)
    await #expect(throws: (any Error).self) { try await authority.authenticate(hello, authentication: proof, challenge: Data(repeating: 8, count: 32), hostKey: host, now: now) }
    try await authority.revoke(hello.deviceID)
    await #expect(throws: (any Error).self) { try await authority.current(hello.deviceID) }
    await #expect(throws: (any Error).self) { try await authority.authenticate(hello, authentication: proof, challenge: nonce, hostKey: host, now: now) }
}

@Test("expired pairing and failed persistence never authorize a phone")
func failedPairingStaysClosed() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let host = P256.KeyAgreement.PrivateKey().publicKey.x963Representation, key = P256.Signing.PrivateKey()
    let hello = CompanionHello(deviceID: UUID(), deviceName: "Fixture phone", signingKey: key.publicKey.x963Representation,
        ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    let nonce = Data(repeating: 4, count: 32)
    let authority = CompanionAuthority()
    let (code, expiry) = await authority.issue(domains: ["project"], now: now)
    let proof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: code)
    await #expect(throws: (any Error).self) { try await authority.authenticate(hello, authentication: proof, challenge: nonce, hostKey: host, now: expiry) }
    let failing = CompanionAuthority(persist: { _ in throw CompanionError.disconnected })
    let (otherCode, _) = await failing.issue(domains: ["project"], now: now)
    let otherProof = try authentication(hello, key: key, challenge: nonce, hostKey: host, code: otherCode)
    await #expect(throws: (any Error).self) { try await failing.authenticate(hello, authentication: otherProof, challenge: nonce, hostKey: host, now: now) }
    #expect(await failing.pairedDevices().isEmpty)
}

@Test("the listener accepts only literal tailnet addresses")
func ownerEndpointCannotBecomeAPublicOrLANListener() {
    for address in ["0.0.0.0","127.0.0.1","192.168.1.1","localhost","example.invalid","::","100.063.0.1"] {
        #expect(!CompanionEndpoint.isTailnetAddress(address))
    }
    let assignedRangeFixture = [100,64,0,2].map(String.init).joined(separator: ".")
    #expect(CompanionEndpoint.isTailnetAddress(assignedRangeFixture))
}
