import CryptoKit
import Foundation
import Network

public struct CompanionAcknowledgement: Codable, Sendable {
    public var requestID: UUID
    public init(requestID: UUID) { self.requestID = requestID }
}

public actor CompanionClient {
    typealias TransportFactory = @Sendable (CompanionInvitation) throws -> any CompanionTransport
    private let makeTransport: TransportFactory
    private var pipe: (any CompanionTransport)?
    private var pending: (any CompanionTransport)?
    private var lifecycle = UUID()
    private var expires: Date?
    private var working = false
    public init() { makeTransport = Self.networkTransport }
    init(makeTransport: @escaping TransportFactory) { self.makeTransport = makeTransport }
    public var isConnected: Bool { pipe != nil && (expires.map { $0 > Date() } ?? false) }
    static func networkConnection(host: String, port: UInt16) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw CompanionError.invalidInvitation }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        tcp.maximumSegmentSize = 960 // Chosen below the brief's packet-loss threshold, including IP/TCP/tunnel overhead.
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
    }
    private static func networkTransport(_ invitation: CompanionInvitation) throws -> any CompanionTransport {
        let connection = try networkConnection(host: invitation.host, port: invitation.port)
        let pipe = CompanionPipe(connection)
        connection.start(queue: DispatchQueue(label: "OpenCore.companion.client"))
        return pipe
    }
    public func disconnect() async {
        lifecycle = UUID()
        let old = pipe, connecting = pending
        pipe = nil; pending = nil; expires = nil
        if let old { await old.close() }
        if let connecting { await connecting.close() }
    }
    public func connect(invitation: CompanionInvitation, deviceID: UUID, deviceName: String, publicKey: Data,
                        sign: @escaping @Sendable (Data) async throws -> Data) async throws {
        guard !working else { throw CompanionError.busy }
        working = true; defer { working = false }
        let token = UUID(); lifecycle = token
        let old = pipe, connecting = pending
        pipe = nil; pending = nil; expires = nil
        if let old { await old.close() }
        if let connecting { await connecting.close() }
        guard lifecycle == token, !Task.isCancelled else { throw CancellationError() }
        guard invitation.version == 1, invitation.port > 0, CompanionEndpoint.isTailnetAddress(invitation.host) else { throw CompanionError.invalidInvitation }
        let pipe = try makeTransport(invitation)
        pending = pipe
        let timeout = Task { try await Task.sleep(for: .seconds(30)); await pipe.close() }
        defer { timeout.cancel() }
        do {
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let hello = CompanionHello(deviceID: deviceID, deviceName: deviceName, signingKey: publicKey,
                ephemeralKey: ephemeral.publicKey.x963Representation)
            try await pipe.send(hello)
            try await pipe.secure(CompanionSessionKeys(privateKey: ephemeral, peer: invitation.hostPublicKey,
                hostPublicKey: invitation.hostPublicKey, isHost: false))
            let challenge = try await pipe.receive(Data.self)
            guard challenge.count == 32 else { throw CompanionError.invalidFrame }
            let signature = try await sign(hello.proof(challenge: challenge, hostKey: invitation.hostPublicKey))
            try await pipe.send(CompanionAuthentication(signature: signature, pairingCode: invitation.code.isEmpty ? nil : invitation.code))
            let accepted = try await pipe.receive(Bool.self)
            guard accepted else { throw CompanionError.unauthorized }
            guard lifecycle == token, !Task.isCancelled else { throw CancellationError() }
            self.pipe = pipe; pending = nil; expires = Date().addingTimeInterval(300) // Chosen five-minute session ceiling.
        } catch {
            if lifecycle == token { pending = nil }
            await pipe.close(); throw error
        }
    }
    public func request(_ request: CompanionRequest, progress: @escaping @Sendable (CompanionPage) async -> Void = { _ in }) async throws -> CompanionPage {
        guard !working else { throw CompanionError.busy }
        guard let pipe, let expires, expires > Date() else { await disconnect(); throw CompanionError.expired }
        working = true; defer { working = false }
        let token = lifecycle
        let timeout = Task { try await Task.sleep(for: .seconds(120)); await pipe.close() }
        defer { timeout.cancel() }
        do {
            try await pipe.send(request)
            var response = try await pipe.receive(CompanionResponse.self)
            while response.phase == .progress {
                guard response.requestID == request.id, lifecycle == token else { throw CompanionError.invalidFrame }
                if let page = response.page { await progress(page) }
                response = try await pipe.receive(CompanionResponse.self)
            }
            guard response.requestID == request.id else { throw CompanionError.invalidFrame }
            if let error = response.error { throw NSError(domain: "OpenCoreCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            guard response.phase == .prepared, response.page != nil else { throw CompanionError.invalidFrame }
            try await pipe.send(CompanionAcknowledgement(requestID: request.id))
            // Only the final response is shown: its receipt records acknowledged delivery.
            let final = try await pipe.receive(CompanionResponse.self)
            guard final.requestID == request.id, final.phase == .committed else { throw CompanionError.invalidFrame }
            if let error = final.error { throw NSError(domain: "OpenCoreCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            guard let page = final.page else { throw CompanionError.invalidFrame }
            guard lifecycle == token, !Task.isCancelled else { throw CancellationError() }
            return page
        } catch {
            if lifecycle == token { await disconnect() } else { await pipe.close() }
            throw error
        }
    }
}
