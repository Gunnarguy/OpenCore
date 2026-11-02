import CryptoKit
import Foundation
import Network
import Testing
@testable import CoreCompanion

/// Every other companion test runs the session over an in-memory peer, which is how a listener that
/// could never start reached a phone: `NWListener(using:on:)` threw POSIX 22 (EINVAL) on every Enable
/// on a real Mac, so no pairing code was ever shown. These open real sockets, on loopback only.
private actor StatusLog {
    private var seen: [CompanionServer.Status] = []
    func record(_ status: CompanionServer.Status) { seen.append(status) }
    var ready: Bool { seen.contains(.ready) }
}

private func waitForReady(_ log: StatusLog) async throws {
    for _ in 0..<200 {
        if await log.ready { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The listener never reported ready")
    throw CompanionError.disconnected
}

/// The listener's parameters and the client's connection are the production ones. Only the address
/// differs: `bind` takes loopback here, and the invitation carries a tailnet literal the client admits.
private func openSession(server: CompanionServer, port: UInt16, hostKey: Data, code: String,
                         deviceID: UUID, signing: P256.Signing.PrivateKey) async throws -> CompanionClient {
    let client = CompanionClient { invitation in
        let connection = try CompanionClient.networkConnection(host: "127.0.0.1", port: invitation.port)
        let pipe = CompanionPipe(connection)
        connection.start(queue: DispatchQueue(label: "OpenCore.companion.test-client"))
        return pipe
    }
    let invitation = CompanionInvitation(host: "100.64.0.1", port: port, hostPublicKey: hostKey, code: code,
                                         expiresAt: Date().addingTimeInterval(120))
    try await client.connect(invitation: invitation, deviceID: deviceID, deviceName: "Fixture phone",
                             publicKey: signing.publicKey.x963Representation) { data in
        try signing.signature(for: data).rawRepresentation
    }
    return client
}

@Test("the listener binds its required address, which POSIX 22 used to stop on every real Mac")
func companionListenerBindsRequiredAddress() async throws {
    let log = StatusLog()
    let server = CompanionServer(authority: CompanionAuthority(), hostKey: P256.KeyAgreement.PrivateKey()) { _, _, _ in
        CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
    }
    try await server.bind(host: "127.0.0.1", port: UInt16.random(in: 49_152...55_000)) { await log.record($0) }
    try await waitForReady(log)
    await server.stop()
}

@Test("start still refuses anything but a tailnet literal", arguments: ["127.0.0.1", "0.0.0.0", "10.0.0.2", "mac.local"])
func companionStartRefusesOtherAddresses(host: String) async throws {
    let server = CompanionServer(authority: CompanionAuthority(), hostKey: P256.KeyAgreement.PrivateKey()) { _, _, _ in
        CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
    }
    await #expect(throws: CompanionError.invalidInvitation) {
        try await server.start(host: host, port: 49_151) { _ in }
    }
}

@Test("a phone pairs, reads a page larger than one frame, then reconnects with no code, over a real socket")
func companionPairsAndReadsOverSocket() async throws {
    let authority = CompanionAuthority(), log = StatusLog()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), deviceID = UUID()
    let hostKey = host.publicKey.x963Representation
    let port = UInt16.random(in: 55_001...60_000)
    // Far past the 600-byte fragment, so framing and the sealed chunks both run for real.
    let note = String(repeating: "evidence ", count: 20_000)
    let server = CompanionServer(authority: authority, hostKey: host) { request, device, _ in
        #expect(device.id == deviceID)
        return CompanionPreparedPage(page: CompanionPage(title: request.section.rawValue, note: note))
    }
    try await server.bind(host: "127.0.0.1", port: port) { await log.record($0) }
    try await waitForReady(log)

    let (code, _) = await authority.issue(domains: ["project", "public"])
    let paired = try await openSession(server: server, port: port, hostKey: hostKey, code: code,
                                       deviceID: deviceID, signing: signing)
    let first = try await paired.request(CompanionRequest(section: .home))
    #expect(first.title == "home")
    #expect(first.note == note)
    #expect(await authority.pairedDevices().map(\.id) == [deviceID])
    await paired.disconnect()

    // The phone keeps the invitation with its code removed, and reconnects on the device key alone.
    let reconnected = try await openSession(server: server, port: port, hostKey: hostKey, code: "",
                                            deviceID: deviceID, signing: signing)
    let second = try await reconnected.request(CompanionRequest(section: .claims))
    #expect(second.title == "claims")
    await reconnected.disconnect()
    await server.stop()
}

@Test("a Mac that is not listening reads as unreachable, never as a raw network error number")
func companionUnreachableMacIsNamed() async throws {
    // Nothing listens on this port. The phone showed a bare NWError before.
    let connection = try CompanionClient.networkConnection(host: "127.0.0.1", port: 49_150)
    let pipe = CompanionPipe(connection)
    connection.start(queue: DispatchQueue(label: "OpenCore.companion.test-refused"))
    let closer = Task { try await Task.sleep(for: .seconds(2)); await pipe.close() }
    defer { closer.cancel() }
    await #expect(throws: CompanionError.disconnected) { let _: Bool = try await pipe.receive(Bool.self) }
}
