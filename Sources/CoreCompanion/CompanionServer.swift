#if os(macOS)
import CryptoKit
import Foundation
import Network

public struct CompanionPreparedPage: Sendable {
    public var page: CompanionPage
    public var acknowledge: @Sendable () async throws -> CompanionPage
    /// Recheck the page's disclosure authority immediately before each send, including replay.
    public var validateDisclosure: @Sendable () async throws -> Void = { } {
        didSet { canValidateReplay = true }
    }
    public private(set) var canValidateReplay = false
    public init(page: CompanionPage, acknowledge: @escaping @Sendable () async throws -> CompanionPage) {
        self.page = page; self.acknowledge = acknowledge
    }
    public init(page: CompanionPage) { self.page = page; self.acknowledge = { page } }
}

public actor CompanionServer {
    public enum Status: String, Sendable {
        case ready = "Ready on Tailscale"
        case stopped = "Companion connection is off"
        case failed = "Could not bind the selected Tailscale address. Check Tailscale and try again."
    }
    private enum Exchange: Sendable {
        case prepared(CompanionPreparedPage)
        case acknowledged(CompanionAcknowledgement)
    }
    public typealias Progress = @Sendable (CompanionPage) async throws -> Void
    public typealias Handler = @Sendable (CompanionRequest, CompanionDevice, Progress) async throws -> CompanionPreparedPage
    private struct ReplayKey: Hashable { var device: UUID; var request: UUID }
    private struct Replay {
        var device: CompanionDevice
        var request: CompanionRequest
        var page: CompanionPage
        var delivery: CompanionDelivery
        var expires: Date
    }
    private struct ActiveExchange {
        var tokens: Set<UUID>
        var device: CompanionDevice
        var request: Data
    }
    private let authority: CompanionAuthority
    private let hostKey: P256.KeyAgreement.PrivateKey
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [UUID: (device: UUID?, grant: UUID?, pipe: any CompanionTransport)] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var replay: [ReplayKey: Replay] = [:]
    private var activeExchanges: [ReplayKey: ActiveExchange] = [:]
    public init(authority: CompanionAuthority, hostKey: P256.KeyAgreement.PrivateKey, handler: @escaping Handler) {
        self.authority = authority; self.hostKey = hostKey; self.handler = handler
    }
    public func start(host: String, port: UInt16 = 47821, status: @escaping @Sendable (Status) async -> Void) throws {
        guard CompanionEndpoint.isTailnetAddress(host) else { throw CompanionError.invalidInvitation }
        try bind(host: host, port: port, status: status)
    }
    /// Internal seam: `start` is the only production caller and admits only tailnet literals, while
    /// regressions bind loopback, because no fixture owns a tunnel address.
    func bind(host: String, port: UInt16, status: @escaping @Sendable (Status) async -> Void) throws {
        guard listener == nil, port > 0, let networkPort = NWEndpoint.Port(rawValue: port) else { throw CompanionError.invalidInvitation }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        tcp.maximumSegmentSize = 960 // Chosen below the brief's packet-loss threshold, including IP/TCP/tunnel overhead.
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: networkPort)
        parameters.allowLocalEndpointReuse = false
        // The required endpoint already names the port. Naming it again through `on:` makes this
        // initializer throw POSIX 22, which stopped every Enable before a pairing code could exist.
        let listener = try NWListener(using: parameters)
        let generation = generation
        listener.newConnectionHandler = { connection in Task { await self.accept(connection, generation: generation) } }
        listener.stateUpdateHandler = { state in
            Task { await self.listenerState(state, generation: generation, status: status) }
        }
        self.listener = listener
        listener.start(queue: DispatchQueue(label: "OpenCore.companion.listener"))
    }
    public func stop() async {
        generation = UUID(); listener?.cancel(); listener = nil
        replay.removeAll()
        activeExchanges.removeAll()
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        let peers = Array(connections.values); connections.removeAll()
        for value in peers { await value.pipe.close() }
        await authority.cancelInvitation()
    }
    public func revoke(_ id: UUID) async throws {
        guard let grant = try await authority.revoke(id) else { return }
        await invalidateGrant(id, grant: grant)
    }
    /// Invalidates only the grant displaced by the authority operation. A newer grant
    /// may already be active by the time this server actor resumes after that operation.
    func invalidateGrant(_ id: UUID, grant: UUID) async {
        replay = replay.filter { $0.key.device != id || $0.value.device.grantID != grant }
        activeExchanges = activeExchanges.filter { $0.key.device != id || $0.value.device.grantID != grant }
        let peers = connections.filter { $0.value.device == id && $0.value.grant == grant }
        for (connectionID, value) in peers {
            tasks[connectionID]?.cancel(); await value.pipe.close()
        }
    }
    private func listenerState(_ state: NWListener.State, generation: UUID, status: @escaping @Sendable (Status) async -> Void) async {
        guard generation == self.generation else { return }
        switch state {
        case .ready: await status(.ready)
        case .failed: await stop(); await status(.failed)
        case .cancelled: await status(.stopped)
        default: break
        }
    }
    private func expire(_ id: UUID) {
        tasks[id]?.cancel()
        if let pipe = connections[id]?.pipe { Task { await pipe.close() } }
    }
    private func validateSession(_ device: CompanionDevice, generation: UUID) async throws {
        try Task.checkCancellation()
        let current = try await authority.current(device.id)
        guard generation == self.generation, current == device else { throw CompanionError.unauthorized }
        try Task.checkCancellation()
    }
    private func accept(_ connection: NWConnection, generation: UUID) async {
        guard generation == self.generation, connections.count < 8 else { connection.cancel(); return } // Chosen bound.
        connection.start(queue: DispatchQueue(label: "OpenCore.companion.peer"))
        await acceptTransport(CompanionPipe(connection))
    }
    /// Internal transport seam: lifecycle regressions use in-memory peers, never a listener.
    func acceptTransport(_ pipe: any CompanionTransport) async {
        guard connections.count < 8 else { await pipe.close(); return }
        let id = UUID(), generation = generation
        connections[id] = (nil, nil, pipe)
        tasks[id] = Task { await serve(pipe, id: id, generation: generation) }
    }
    private func serve(_ pipe: any CompanionTransport, id: UUID, generation: UUID) async {
        let authenticationTimeout = Task { try await Task.sleep(for: .seconds(20)); self.expire(id) }
        defer {
            authenticationTimeout.cancel(); connections.removeValue(forKey: id); tasks.removeValue(forKey: id)
            Task { await pipe.close() }
        }
        do {
            let hello = try await pipe.receive(CompanionHello.self)
            guard hello.version == 1, hello.ephemeralKey.count == 65 else { throw CompanionError.unauthorized }
            let publicKey = hostKey.publicKey.x963Representation
            try await pipe.secure(CompanionSessionKeys(privateKey: hostKey, peer: hello.ephemeralKey, hostPublicKey: publicKey, isHost: true))
            let challenge = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
            let nonce = Data(challenge)
            try await pipe.send(nonce)
            let authentication = try await pipe.receive(CompanionAuthentication.self)
            try Task.checkCancellation()
            let transition = try await authority.authenticateWithTransition(hello, authentication: authentication, challenge: nonce, hostKey: publicKey)
            let device = transition.device
            // Register before the current-grant await. If a newer transition runs while
            // that await is suspended, its cleanup can now find and cancel this peer.
            if generation == self.generation, connections[id] != nil, !Task.isCancelled {
                connections[id] = (device.id, device.grantID, pipe)
            }
            if let replacedGrant = transition.replacedGrant { await invalidateGrant(device.id, grant: replacedGrant) }
            try Task.checkCancellation()
            let current = try await authority.current(device.id)
            try Task.checkCancellation()
            guard generation == self.generation, connections[id] != nil, current == device else { throw CompanionError.disconnected }
            try await pipe.send(true)
            authenticationTimeout.cancel()
            let deadline = Task { try await Task.sleep(for: .seconds(300)); self.expire(id) }
            defer { deadline.cancel() }
            while generation == self.generation {
                let request = try await pipe.receive(CompanionRequest.self)
                // A receive can complete after stop, revoke or a new grant for the same UUID.
                // Keep the authenticated grant, and fence it before reserving or starting work.
                try await validateSession(device, generation: generation)
                let current = device
                guard request.query.utf8.count <= 8192, (0...1_000_000).contains(request.offset),
                      (request.recordID?.utf8.count ?? 0) <= 256 else { throw CompanionError.invalidFrame }
                if let date = request.asOf {
                    guard date.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970) else { throw CompanionError.invalidFrame }
                }
                do {
                    replay = replay.filter { $0.value.expires > Date() }
                    let replayKey = ReplayKey(device: device.id, request: request.resumeID ?? request.id)
                    let previous = replay[replayKey]
                    if request.resumeID != nil {
                        guard let previous, previous.device == current else { throw CompanionError.resumeUnavailable }
                    }
                    if let previous {
                        guard previous.device == current else { throw CompanionError.invalidFrame }
                        if request.resumeID == nil {
                            let originalRequest = try JSONEncoder.companionCanonical.encode(previous.request)
                            let incomingRequest = try JSONEncoder.companionCanonical.encode(request)
                            guard originalRequest == incomingRequest else { throw CompanionError.invalidFrame }
                        }
                    }
                    // Track every active exchange, including a cached replay. The cache may
                    // evict its entry while an acknowledgement is still in flight.
                    let encoded = try JSONEncoder.companionCanonical.encode(previous?.request ?? request)
                    let exchangeToken = UUID()
                    if var active = activeExchanges[replayKey] {
                        guard active.device == current, active.request == encoded else { throw CompanionError.invalidFrame }
                        guard previous != nil else { throw CompanionError.busy }
                        active.tokens.insert(exchangeToken)
                        activeExchanges[replayKey] = active
                    } else {
                        activeExchanges[replayKey] = ActiveExchange(tokens: [exchangeToken], device: current, request: encoded)
                    }
                    defer {
                        if var active = activeExchanges[replayKey], active.tokens.remove(exchangeToken) != nil {
                            if active.tokens.isEmpty { activeExchanges.removeValue(forKey: replayKey) }
                            else { activeExchanges[replayKey] = active }
                        }
                    }
                    if let previous {
                        // Reserve before this await, so cache eviction cannot let another
                        // connection start the same request while validation is suspended.
                        // A denied replay can still be reported before starting ACK receive.
                        try await previous.delivery.validateReplay()
                        try await validateSession(current, generation: generation)
                    }
                    // Read the acknowledgement concurrently with preparation. EOF or a reset
                    // wins the group and cancels generation even while no model token arrives.
                    try await withThrowingTaskGroup(of: Exchange.self) { group in
                        let handler = handler
                        let progress: Progress = { page in
                            try await self.validateSession(current, generation: generation)
                            try await pipe.send(CompanionResponse(requestID: request.id, page: page, phase: .progress))
                        }
                        group.addTask {
                            try await self.validateSession(current, generation: generation)
                            if let previous { return .prepared(CompanionPreparedPage(page: previous.page)) }
                            return .prepared(try await handler(request, current, progress))
                        }
                        group.addTask { .acknowledged(try await pipe.receive(CompanionAcknowledgement.self)) }
                        defer { group.cancelAll() }
                        guard let first = try await group.next(), case .prepared(let prepared) = first else { throw CompanionError.invalidFrame }
                        try Task.checkCancellation()
                        try await validateSession(current, generation: generation)
                        let delivery: CompanionDelivery
                        var outgoing = prepared.page
                        var isReplay = false
                        if let previous { delivery = previous.delivery; outgoing = previous.page; isReplay = true }
                        else if let raced = replay[replayKey] {
                            let originalRequest = try JSONEncoder.companionCanonical.encode(raced.request)
                            let incomingRequest = try JSONEncoder.companionCanonical.encode(request)
                            guard raced.device == current, originalRequest == incomingRequest else { throw CompanionError.invalidFrame }
                            delivery = raced.delivery; outgoing = raced.page; isReplay = true
                        }
                        else {
                            delivery = CompanionDelivery(prepared)
                            if replay.count >= 8, let oldest = replay.min(by: { $0.value.expires < $1.value.expires })?.key { replay.removeValue(forKey: oldest) }
                            replay[replayKey] = Replay(device: current, request: request, page: prepared.page, delivery: delivery,
                                expires: Date().addingTimeInterval(300)) // Chosen five-minute, eight-reply volatile resume cache.
                        }
                        if request.resumeID != nil { outgoing.note = "Resumed result from \(outgoing.generatedAt.formatted()). " + outgoing.note }
                        if isReplay { try await delivery.validateReplay() }
                        else { try await delivery.validateDisclosure() }
                        try await validateSession(current, generation: generation)
                        try await pipe.send(CompanionResponse(requestID: request.id, page: outgoing))
                        guard let second = try await group.next(), case .acknowledged(let ack) = second, ack.requestID == request.id,
                              generation == self.generation else { throw CompanionError.invalidFrame }
                        try await validateSession(current, generation: generation)
                        var completed = try await delivery.acknowledge()
                        if request.resumeID != nil { completed.note = "Resumed result from \(completed.generatedAt.formatted()). " + completed.note }
                        try await delivery.validateDisclosure()
                        try await validateSession(current, generation: generation)
                        try await pipe.send(CompanionResponse(requestID: request.id, page: completed, phase: .committed))
                    }
                } catch {
                    let message = (error as? CompanionError)?.rawValue ?? "The Mac could not complete this read. Check OpenCore on the Mac."
                    try await pipe.send(CompanionResponse(requestID: request.id, error: message))
                    // No retry on the same stream after a failed acknowledgement or handler.
                    break
                }
            }
        } catch { /* Authentication failures disclose no data and write no stdout. */ }
    }
}
#endif
