import CryptoKit
import Foundation
import Testing
@testable import CoreCompanion

/// A typed in-memory peer runs the real server authentication/session state machine.
/// Encryption is tested separately by the cipher tests; no socket or Keychain is opened.
private actor MemoryOwnerPeer: CompanionTransport {
    private let hello: CompanionHello
    private let signing: P256.Signing.PrivateKey
    private let hostKey: Data
    private let code: String?
    private let request: CompanionRequest
    private let onFailure: @Sendable () -> Void
    private let onRequest: @Sendable () async -> Void
    private let onAcknowledgement: @Sendable () async -> Void
    private let onClose: @Sendable (Int) -> Void
    private let onClosedResponse: @Sendable () -> Void
    private var challenge = Data()
    private var sentRequest = false
    private var closed = false
    private var aborted = false
    private var closeCount = 0
    private var events: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var prepared: CompanionResponse?
    private(set) var final: CompanionResponse?
    private(set) var failure: String?
    init(id: UUID, signing: P256.Signing.PrivateKey, hostKey: Data, code: String?, request: CompanionRequest,
         onFailure: @escaping @Sendable () -> Void = {}, onRequest: @escaping @Sendable () async -> Void = {},
         onAcknowledgement: @escaping @Sendable () async -> Void = {},
         onClose: @escaping @Sendable (Int) -> Void = { _ in },
         onClosedResponse: @escaping @Sendable () -> Void = {}) {
        self.signing = signing; self.hostKey = hostKey; self.code = code; self.request = request
        self.onFailure = onFailure; self.onRequest = onRequest; self.onAcknowledgement = onAcknowledgement
        self.onClose = onClose; self.onClosedResponse = onClosedResponse
        hello = CompanionHello(deviceID: id, deviceName: "Fixture phone", signingKey: signing.publicKey.x963Representation,
            ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
    }
    func secure(_ keys: CompanionSessionKeys) { }
    func close() {
        closed = true
        closeCount += 1; onClose(closeCount)
        events.insert("closed")
        let pending = waiters; waiters.removeAll()
        for list in pending.values { for continuation in list { continuation.resume() } }
    }
    func abort() { aborted = true; close() }
    private func signal(_ event: String) {
        events.insert(event)
        for continuation in waiters.removeValue(forKey: event) ?? [] { continuation.resume() }
    }
    @discardableResult func wait(_ event: String) async -> Bool {
        if !closed && !events.contains(event) { await withCheckedContinuation { waiters[event, default: []].append($0) } }
        return events.contains(event) && !aborted
    }
    func send<T: Encodable & Sendable>(_ value: T) throws {
        if closed {
            if T.self == CompanionResponse.self { onClosedResponse() }
            throw CompanionError.disconnected
        }
        let data = try JSONEncoder().encode(value)
        if T.self == Data.self { challenge = try JSONDecoder().decode(Data.self, from: data) }
        if T.self == CompanionResponse.self {
            let response = try JSONDecoder().decode(CompanionResponse.self, from: data)
            if let error = response.error { failure = error; signal("error"); onFailure() }
            else if response.phase == .prepared { prepared = response; signal("prepared") }
            if response.phase == .committed { final = response; signal("committed") }
        }
    }
    func receive<T: Decodable & Sendable>(_ type: T.Type) async throws -> T {
        guard !closed else { throw CompanionError.disconnected }
        let data: Data
        if type == CompanionHello.self { data = try JSONEncoder().encode(hello) }
        else if type == CompanionAuthentication.self {
            let proof = try signing.signature(for: hello.proof(challenge: challenge, hostKey: hostKey)).rawRepresentation
            data = try JSONEncoder().encode(CompanionAuthentication(signature: proof, pairingCode: code))
        } else if type == CompanionRequest.self {
            if sentRequest { await wait("closed"); throw CompanionError.disconnected }
            sentRequest = true
            await onRequest()
            data = try JSONEncoder().encode(request)
        } else if type == CompanionAcknowledgement.self {
            // The real pipe cancels its connection when a pending receive is cancelled.
            await withTaskCancellationHandler {
                await wait("prepared")
            } onCancel: {
                Task { await self.close() }
            }
            await onAcknowledgement()
            guard !closed else { throw CompanionError.disconnected }
            data = try JSONEncoder().encode(CompanionAcknowledgement(requestID: request.id))
        } else { throw CompanionError.invalidFrame }
        return try JSONDecoder().decode(type, from: data)
    }
}

private actor HeldPreparation {
    private(set) var starts = 0
    private var firstWaiter: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let events: AsyncStream<String>.Continuation
    init(events: AsyncStream<String>.Continuation) { self.events = events }
    func enter() async {
        starts += 1
        if starts == 1 { firstWaiter?.resume(); firstWaiter = nil }
        else { events.yield("duplicate handler") }
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }
    func waitForFirst() async -> Bool {
        if starts == 0 && !released { await withCheckedContinuation { firstWaiter = $0 } }
        return starts > 0
    }
    func release() {
        released = true
        firstWaiter?.resume(); firstWaiter = nil
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

private actor HandlerProbe {
    var entered = false
    var result: String?
    private var entering: CheckedContinuation<Void, Never>?
    private var finishing: CheckedContinuation<Void, Never>?
    func start() { entered = true; entering?.resume(); entering = nil }
    func finish(_ result: String) { self.result = result; finishing?.resume(); finishing = nil }
    func waitForStart() async { if !entered { await withCheckedContinuation { entering = $0 } } }
    func waitForFinish() async { if result == nil { await withCheckedContinuation { finishing = $0 } } }
}

@Test("server stop, revocation and peer loss cancel a suspended read handler", arguments: ["stop","revoke","disconnect"])
func companionSessionLossCancelsWork(reason: String) async throws {
    let authority = CompanionAuthority(), probe = HandlerProbe()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project","public"])
    let peer = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation, code: code, request: CompanionRequest(section: .home))
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        await probe.start()
        do {
            try await Task.sleep(for: .seconds(10))
            await probe.finish("completed")
            return CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
        } catch { await probe.finish("cancelled"); throw error }
    }
    await server.acceptTransport(peer)
    await probe.waitForStart()
    switch reason {
    case "stop": await server.stop()
    case "revoke": try await server.revoke(id)
    default: await peer.close()
    }
    await probe.waitForFinish()
    #expect(await probe.result == "cancelled")
    #expect(await peer.final == nil)
    await server.stop()
}

@Test("re-pairing replaces the grant and cancels work on the old connection")
func companionRePairCancelsOldGrantWork() async throws {
    let authority = CompanionAuthority(), oldWork = HandlerProbe()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (firstCode, _) = await authority.issue(domains: ["project", "public", "medical"])
    let server = CompanionServer(authority: authority, hostKey: host) { _, device, _ in
        if device.domains.contains("medical") {
            await oldWork.start()
            do {
                try await Task.sleep(for: .seconds(10))
                await oldWork.finish("completed")
            } catch { await oldWork.finish("cancelled"); throw error }
        }
        return CompanionPreparedPage(page: CompanionPage(title: "New grant"))
    }
    let old = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: firstCode, request: CompanionRequest(section: .home))
    await server.acceptTransport(old)
    let entered = await bounded({ await oldWork.waitForStart(); return true }, onTimeout: { await old.abort() })
    #expect(entered)
    guard entered else { await server.stop(); return }
    let (newCode, _) = await authority.issue(domains: ["project", "public"])
    let replacement = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: newCode, request: CompanionRequest(section: .home))
    await server.acceptTransport(replacement)
    #expect(await peerObserved(replacement, "committed"))
    let canceled = await bounded({ await oldWork.waitForFinish(); return await oldWork.result == "cancelled" },
        onTimeout: { await old.abort() })
    #expect(canceled)
    #expect(await old.final == nil)
    #expect(try await authority.current(id).domains == ["project", "public"])
    await server.stop()
}

@Test("delayed cleanup of an old grant preserves a newer connection and its cached page")
func companionDelayedGrantCleanupPreservesNewGrant() async throws {
    let authority = CompanionAuthority(), counts = DeliveryCounts(), gate = RequestBarrier()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (oldCode, _) = await authority.issue(domains: ["project", "public", "medical"])
    let oldRequest = CompanionRequest(section: .home), newRequest = CompanionRequest(section: .home)
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        await counts.prepare()
        var prepared = CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
        prepared.validateDisclosure = { }
        return prepared
    }
    let old = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: oldCode, request: oldRequest)
    await server.acceptTransport(old)
    let oldCommitted = await peerObserved(old, "committed")
    #expect(oldCommitted)
    guard oldCommitted else { await server.stop(); return }
    let oldGrant = try await authority.current(id).grantID
    let (newCode, _) = await authority.issue(domains: ["project", "public"])
    let replacement = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: newCode, request: newRequest, onAcknowledgement: { await gate.hold() })
    await server.acceptTransport(replacement)
    let ready = await peerObserved(replacement, "prepared")
    #expect(ready)
    guard ready else { await gate.open(); await server.stop(); return }
    let held = await bounded({ await gate.waitForArrival() }, onTimeout: { await gate.open(); await replacement.abort() })
    #expect(held)
    guard held else { await server.stop(); return }

    // Model a delayed revoke or re-pair continuation after a newer grant is already active.
    await server.invalidateGrant(id, grant: oldGrant)
    await gate.open()
    #expect(await peerObserved(replacement, "committed"))
    let retry = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: newRequest)
    await server.acceptTransport(retry)
    #expect(await peerObserved(retry, "committed"))
    #expect(await counts.prepared == 2)
    let stale = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: CompanionRequest(section: .home, resumeID: oldRequest.id))
    await server.acceptTransport(stale)
    #expect(await peerObserved(stale, "error"))
    #expect(await stale.failure == CompanionError.resumeUnavailable.rawValue)
    #expect(await stale.prepared == nil)
    await server.stop()
}

private actor DeliveryCounts {
    var prepared = 0
    var acknowledged = 0
    func prepare() { prepared += 1 }
    func acknowledge() { acknowledged += 1 }
}

@Test("a resumed read reuses its exact response and acknowledges its receipt only once")
func companionReconnectResumesWithoutRepeatingWork() async throws {
    let authority = CompanionAuthority(), counts = DeliveryCounts()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project","public"])
    let original = CompanionRequest(section: .home)
    let expected = CompanionPage(title: "Fixture", records: [CompanionRecord(id: "fixture", title: "Exact response", body: "Fixture payload")], generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        await counts.prepare()
        var page = CompanionPreparedPage(page: expected) { await counts.acknowledge(); return expected }
        page.validateDisclosure = { }
        return page
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation, code: code, request: original)
    await server.acceptTransport(first); await first.wait("committed"); await first.close()
    let second = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation, code: nil,
        request: CompanionRequest(section: .home, resumeID: original.id))
    await server.acceptTransport(second); await second.wait("committed")
    let page = try #require(await second.final?.page)
    #expect(page.records == expected.records)
    #expect(page.generatedAt == expected.generatedAt)
    #expect(page.note.hasPrefix("Resumed result"))
    #expect(await counts.prepared == 1)
    #expect(await counts.acknowledged == 1)
    await server.stop()
}

@Test("simultaneous requests cannot run the same identity twice", arguments: [false, true])
func companionConcurrentRequestReservesWork(changedBody: Bool) async throws {
    let authority = CompanionAuthority()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let request = CompanionRequest(section: .home)
    let (events, continuation) = AsyncStream<String>.makeStream()
    let preparation = HeldPreparation(events: continuation)
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        await preparation.enter()
        return CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: request)
    await server.acceptTransport(first)
    let started = await bounded({ await preparation.waitForFirst() }, onTimeout: { await preparation.release(); await first.abort() })
    #expect(started)
    guard started else { await server.stop(); continuation.finish(); return }
    var repeated = request
    if changedBody { repeated.query = "a different request body" }
    let second = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: repeated, onFailure: { continuation.yield("rejected") })
    await server.acceptTransport(second)

    // Either the server refuses the duplicate, or a second handler enters. A watchdog prevents
    // a broken state machine from hanging the suite; no wall-clock delay decides correctness.
    let outcome = await withTaskGroup(of: String.self) { group in
        group.addTask { var iterator = events.makeAsyncIterator(); return await iterator.next() ?? "closed" }
        group.addTask { try? await Task.sleep(for: .seconds(3)); return "timed out" }
        let result = await group.next() ?? "closed"
        group.cancelAll()
        return result
    }
    await preparation.release()
    #expect(await peerObserved(first, "committed"))
    if outcome == "duplicate handler" { #expect(await peerObserved(second, "committed")) }
    #expect(outcome == "rejected")
    #expect(await preparation.starts == 1)
    #expect(await second.failure == (changedBody ? CompanionError.invalidFrame : CompanionError.busy).rawValue)
    await server.stop()
    continuation.finish()
}

private actor PreparationAttempts {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private actor RequestBarrier {
    private var arrived = false
    private var opened = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; arrival?.resume(); arrival = nil
        if !opened { await withCheckedContinuation { release = $0 } }
    }
    func waitForArrival() async -> Bool {
        if !arrived && !opened { await withCheckedContinuation { arrival = $0 } }
        return arrived
    }
    func open() { opened = true; arrival?.resume(); arrival = nil; release?.resume(); release = nil }
}

// A timeout aborts its own peer or gate, which releases the checked continuation. The timer
// is a watchdog only: the actual event, not elapsed time, determines a successful assertion.
private func bounded(_ operation: @escaping @Sendable () async -> Bool,
                     onTimeout: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation() }
        group.addTask {
            do { try await Task.sleep(for: .seconds(3)) } catch { return false }
            return false
        }
        let result = (await group.next() ?? false) && !Task.isCancelled
        // Parent cancellation also wakes the watchdog; always release the owned waiter
        // before the group waits for its children to finish.
        if !result { await onTimeout() }
        group.cancelAll()
        return result
    }
}

private func peerObserved(_ peer: MemoryOwnerPeer, _ event: String) async -> Bool {
    await bounded({ await peer.wait(event) }, onTimeout: { await peer.abort() })
}

private actor DisclosureProbe {
    private var allowed = true
    func restrict() { allowed = false }
    func validate() throws { if !allowed { throw CompanionError.unauthorized } }
}

private actor HeldDisclosure {
    private var armed = false
    private let gate: RequestBarrier
    init(gate: RequestBarrier) { self.gate = gate }
    func arm() { armed = true }
    func validate() async {
        if armed { armed = false; await gate.hold() }
    }
}

@Test("cached pages without a disclosure validator are not replayed", arguments: ["prepared", "committed"], ["retry", "resume"])
func companionReplayRequiresExplicitValidation(phase: String, method: String) async throws {
    let authority = CompanionAuthority(), counts = DeliveryCounts(), gate = RequestBarrier()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let original = CompanionRequest(section: .home)
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        await counts.prepare()
        return CompanionPreparedPage(page: CompanionPage(title: "Fixture", records: [
            CompanionRecord(id: "one", title: "Answer", body: "PRIVATE_FIXTURE")
        ]))
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation, code: code, request: original,
        onAcknowledgement: { if phase == "prepared" { await gate.hold() } })
    await server.acceptTransport(first)
    let started = await peerObserved(first, phase)
    #expect(started)
    if phase == "prepared", started {
        #expect(await bounded({ await gate.waitForArrival() }, onTimeout: { await gate.open(); await first.abort() }))
    }
    guard started else { await gate.open(); await server.stop(); return }
    let request = method == "retry" ? original : CompanionRequest(section: .home, resumeID: original.id)
    let second = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation, code: nil, request: request)
    await server.acceptTransport(second)
    #expect(await peerObserved(second, "error"))
    #expect(await second.failure == CompanionError.resumeUnavailable.rawValue)
    #expect(await second.prepared == nil)
    #expect(await second.final == nil)
    #expect(await counts.prepared == 1)
    await first.close(); await gate.open(); await server.stop()
}

@Test("cached pages recheck disclosure before retry and resume",
      arguments: ["prepared", "committed"], ["retry-allowed", "retry-restricted", "resume-allowed", "resume-restricted"])
func companionReplayRechecksDisclosure(phase: String, variant: String) async throws {
    let restricted = variant.hasSuffix("restricted"), method = variant.hasPrefix("retry") ? "retry" : "resume"
    let authority = CompanionAuthority(), counts = DeliveryCounts(), disclosure = DisclosureProbe(), gate = RequestBarrier()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let original = CompanionRequest(section: .chat, query: "Fixture?", chatThreadID: UUID())
    let expected = CompanionPage(title: "Fixture", records: [CompanionRecord(id: "one", title: "Answer", body: "PRIVATE_FIXTURE")])
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        await counts.prepare()
        var page = CompanionPreparedPage(page: expected) { await counts.acknowledge(); return expected }
        page.validateDisclosure = { try await disclosure.validate() }
        return page
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: original, onAcknowledgement: { if phase == "prepared" { await gate.hold() } })
    await server.acceptTransport(first)
    let started = await peerObserved(first, phase)
    #expect(started)
    if phase == "prepared", started {
        #expect(await bounded({ await gate.waitForArrival() }, onTimeout: { await gate.open(); await first.abort() }))
    }
    guard started else { await gate.open(); await server.stop(); return }
    if restricted { await disclosure.restrict() }
    let request = method == "retry" ? original : CompanionRequest(section: .chat, resumeID: original.id)
    let second = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation, code: nil, request: request)
    await server.acceptTransport(second)
    if restricted {
        #expect(await peerObserved(second, "error"))
        #expect(await second.failure == CompanionError.unauthorized.rawValue)
        #expect(await second.prepared == nil)
        #expect(await second.final == nil)
    } else {
        #expect(await peerObserved(second, "committed"))
        #expect(await second.final?.page?.records == expected.records)
        #expect(await counts.acknowledged == 1)
    }
    #expect(await counts.prepared == 1)
    await first.close(); await gate.open(); await second.close(); await server.stop()
}

@Test("cancelling a bounded fixture wait releases its held continuation")
func companionFixtureWaitReleasesOnCancellation() async {
    let barrier = RequestBarrier()
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let (finished, finishedContinuation) = AsyncStream<Bool>.makeStream()
    let waiter = Task {
        let result = await bounded({
            startedContinuation.yield()
            return await barrier.waitForArrival()
        }, onTimeout: { await barrier.open() })
        finishedContinuation.yield(result)
        finishedContinuation.finish()
    }
    let entered = await bounded({ var iterator = started.makeAsyncIterator(); return await iterator.next() != nil },
        onTimeout: { await barrier.open() })
    #expect(entered)
    waiter.cancel()
    let ended = await bounded({ var iterator = finished.makeAsyncIterator(); return await iterator.next() == false },
        onTimeout: { await barrier.open() })
    #expect(ended)
    await barrier.open()
    await waiter.value
    startedContinuation.finish()
}

@Test("a failed preparation releases its request identity for a retry")
func companionFailedPreparationCanRetry() async throws {
    let authority = CompanionAuthority(), attempts = PreparationAttempts()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let request = CompanionRequest(section: .home)
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        if await attempts.next() == 1 { throw CompanionError.disconnected }
        return CompanionPreparedPage(page: CompanionPage(title: "Recovered"))
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: request)
    await server.acceptTransport(first)
    #expect(await peerObserved(first, "closed"))
    let second = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: request)
    await server.acceptTransport(second)
    #expect(await peerObserved(second, "committed"))
    #expect(await attempts.count == 2)
    #expect(await second.final?.page?.title == "Recovered")
    await server.stop()
}

@Test("a request arriving after stop or re-pair cannot start work under the old grant",
      arguments: ["stop", "re-pair"])
func companionStaleRequestCannotStart(transition: String) async throws {
    let authority = CompanionAuthority(), attempts = PreparationAttempts()
    let oldRequest = RequestBarrier(), newRequest = RequestBarrier()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let request = CompanionRequest(section: .home)
    let (closed, closedContinuation) = AsyncStream<String>.makeStream()
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        _ = await attempts.next()
        return CompanionPreparedPage(page: CompanionPage(title: "Fresh"))
    }
    // The controlled peer models a receive callback that completes after cancellation.
    let old = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: request, onRequest: { await oldRequest.hold() },
        onClose: { if $0 >= 2 { closedContinuation.yield("finished") } })
    await server.acceptTransport(old)
    let oldArrived = await bounded({ await oldRequest.waitForArrival() }, onTimeout: { await oldRequest.open(); await old.abort() })
    #expect(oldArrived)
    guard oldArrived else { await server.stop(); closedContinuation.finish(); return }

    var replacement: MemoryOwnerPeer?
    if transition == "stop" {
        await server.stop()
    } else {
        try await server.revoke(id)
        let (newCode, _) = await authority.issue(domains: ["project", "public"])
        let next = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
            code: newCode, request: request, onRequest: { await newRequest.hold() })
        replacement = next
        await server.acceptTransport(next)
        // New grant is now authenticated, with its request held.
        let newArrived = await bounded({ await newRequest.waitForArrival() }, onTimeout: { await newRequest.open(); await next.abort() })
        #expect(newArrived)
        guard newArrived else { await oldRequest.open(); await server.stop(); closedContinuation.finish(); return }
    }
    await oldRequest.open()
    let outcome = await withTaskGroup(of: String.self) { group in
        group.addTask { var iterator = closed.makeAsyncIterator(); return await iterator.next() ?? "closed" }
        group.addTask { try? await Task.sleep(for: .seconds(3)); return "timed out" }
        let result = await group.next() ?? "closed"
        group.cancelAll()
        return result
    }
    #expect(outcome == "finished")
    #expect(await attempts.count == 0)

    let next: MemoryOwnerPeer
    if let replacement { next = replacement; await newRequest.open() }
    else {
        next = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
            code: nil, request: request)
        await server.acceptTransport(next)
    }
    #expect(await peerObserved(next, "committed"))
    #expect(await attempts.count == 1)
    #expect(await next.final?.page?.title == "Fresh")
    await server.stop()
    closedContinuation.finish()
}

@Test("eviction during a resumed acknowledgement cannot start the original work again")
func companionActiveReplaySurvivesEviction() async throws {
    let authority = CompanionAuthority(), originalAttempts = PreparationAttempts()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let request = CompanionRequest(section: .home), ackBarrier = RequestBarrier()
    let (events, continuation) = AsyncStream<String>.makeStream()
    let (firstClosed, firstClosedContinuation) = AsyncStream<String>.makeStream()
    let server = CompanionServer(authority: authority, hostKey: host) { incoming, _, _ in
        if incoming.id == request.id, await originalAttempts.next() > 1 { continuation.yield("duplicate handler") }
        var page = CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
        page.validateDisclosure = { }
        return page
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: request, onClose: { if $0 >= 2 { firstClosedContinuation.yield("finished") } })
    await server.acceptTransport(first)
    let firstCommitted = await peerObserved(first, "committed")
    #expect(firstCommitted)
    guard firstCommitted else { await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
    await first.close()
    let originalFinished = await bounded({ var iterator = firstClosed.makeAsyncIterator(); return await iterator.next() == "finished" }, onTimeout: {})
    #expect(originalFinished)
    guard originalFinished else { await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
    let resumed = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: CompanionRequest(section: .home, resumeID: request.id),
        onAcknowledgement: { await ackBarrier.hold() })
    await server.acceptTransport(resumed)
    let resumedArrived = await bounded({ await ackBarrier.waitForArrival() }, onTimeout: { await ackBarrier.open(); await resumed.abort() })
    #expect(resumedArrived)
    guard resumedArrived else { await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }

    // Eight newer completed responses evict the original five-minute cached response.
    for _ in 0..<8 {
        let filler = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
            code: nil, request: CompanionRequest(section: .home))
        await server.acceptTransport(filler)
        let filled = await peerObserved(filler, "committed")
        #expect(filled)
        guard filled else { await ackBarrier.open(); await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
        await filler.close()
    }
    let duplicate = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: request, onFailure: { continuation.yield("rejected") })
    await server.acceptTransport(duplicate)
    let outcome = await withTaskGroup(of: String.self) { group in
        group.addTask { var iterator = events.makeAsyncIterator(); return await iterator.next() ?? "closed" }
        group.addTask { try? await Task.sleep(for: .seconds(3)); return "timed out" }
        let result = await group.next() ?? "closed"
        group.cancelAll()
        return result
    }
    await ackBarrier.open()
    #expect(await peerObserved(resumed, "committed"))
    if outcome == "duplicate handler" { #expect(await peerObserved(duplicate, "committed")) }
    #expect(outcome == "rejected")
    #expect(await originalAttempts.count == 1)
    #expect(await duplicate.failure == CompanionError.busy.rawValue)
    await server.stop()
    continuation.finish()
    firstClosedContinuation.finish()
}

@Test("eviction during replay validation cannot start the same work again")
func companionReplayValidationReservesWork() async throws {
    let authority = CompanionAuthority(), attempts = PreparationAttempts(), gate = RequestBarrier()
    let disclosure = HeldDisclosure(gate: gate)
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let request = CompanionRequest(section: .home)
    let (events, continuation) = AsyncStream<String>.makeStream()
    let (firstClosed, firstClosedContinuation) = AsyncStream<String>.makeStream()
    let server = CompanionServer(authority: authority, hostKey: host) { incoming, _, _ in
        if incoming.id == request.id {
            if await attempts.next() > 1 { continuation.yield("duplicate handler") }
            var page = CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
            page.validateDisclosure = { await disclosure.validate() }
            return page
        }
        return CompanionPreparedPage(page: CompanionPage(title: "Filler"))
    }
    let first = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: request, onClose: { if $0 >= 2 { firstClosedContinuation.yield("finished") } })
    await server.acceptTransport(first)
    let committed = await peerObserved(first, "committed")
    #expect(committed)
    guard committed else { await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
    await first.close()
    let finished = await bounded({ var iterator = firstClosed.makeAsyncIterator(); return await iterator.next() == "finished" }, onTimeout: {})
    #expect(finished)
    guard finished else { await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
    await disclosure.arm()
    let replay = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: CompanionRequest(section: .home, resumeID: request.id))
    await server.acceptTransport(replay)
    let held = await bounded({ await gate.waitForArrival() }, onTimeout: { await gate.open(); await replay.abort() })
    #expect(held)
    guard held else { await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
    for _ in 0..<8 {
        let filler = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
            code: nil, request: CompanionRequest(section: .home))
        await server.acceptTransport(filler)
        let filled = await peerObserved(filler, "committed")
        #expect(filled)
        guard filled else { await gate.open(); await server.stop(); continuation.finish(); firstClosedContinuation.finish(); return }
        await filler.close()
    }
    let duplicate = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: request, onFailure: { continuation.yield("rejected") })
    await server.acceptTransport(duplicate)
    let outcome = await withTaskGroup(of: String.self) { group in
        group.addTask { var iterator = events.makeAsyncIterator(); return await iterator.next() ?? "closed" }
        group.addTask { try? await Task.sleep(for: .seconds(3)); return "timed out" }
        let result = await group.next() ?? "closed"
        group.cancelAll()
        return result
    }
    await gate.open()
    #expect(outcome == "rejected")
    #expect(await attempts.count == 1)
    #expect(await duplicate.failure == CompanionError.busy.rawValue)
    await server.stop(); continuation.finish(); firstClosedContinuation.finish()
}

@Test("old exchange cleanup cannot remove a newer reservation for the same request")
func companionStaleCleanupKeepsNewReservation() async throws {
    let authority = CompanionAuthority(), attempts = PreparationAttempts()
    let host = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey(), id = UUID()
    let (code, _) = await authority.issue(domains: ["project", "public"])
    let request = CompanionRequest(section: .home)
    let oldHandler = RequestBarrier(), newHandler = RequestBarrier()
    let (events, continuation) = AsyncStream<String>.makeStream()
    let (oldClosed, oldClosedContinuation) = AsyncStream<String>.makeStream()
    let server = CompanionServer(authority: authority, hostKey: host) { _, _, _ in
        let number = await attempts.next()
        if number == 1 { await oldHandler.hold() }
        else if number == 2 { await newHandler.hold() }
        else { continuation.yield("duplicate handler") }
        return CompanionPreparedPage(page: CompanionPage(title: "Fixture"))
    }
    let old = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: code, request: request, onClosedResponse: { oldClosedContinuation.yield("finished") })
    await server.acceptTransport(old)
    let oldEntered = await bounded({ await oldHandler.waitForArrival() }, onTimeout: { await oldHandler.open(); await old.abort() })
    #expect(oldEntered)
    guard oldEntered else { await server.stop(); continuation.finish(); oldClosedContinuation.finish(); return }
    await server.stop() // The old handler ignores cancellation until the test releases it.

    let fresh = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: request)
    await server.acceptTransport(fresh)
    let freshEntered = await bounded({ await newHandler.waitForArrival() }, onTimeout: { await newHandler.open(); await fresh.abort() })
    #expect(freshEntered)
    guard freshEntered else { await oldHandler.open(); await server.stop(); continuation.finish(); oldClosedContinuation.finish(); return }

    await oldHandler.open()
    let oldFinished = await bounded({ var iterator = oldClosed.makeAsyncIterator(); return await iterator.next() == "finished" }, onTimeout: {})
    #expect(oldFinished)
    guard oldFinished else { await newHandler.open(); await server.stop(); continuation.finish(); oldClosedContinuation.finish(); return }
    let duplicate = MemoryOwnerPeer(id: id, signing: signing, hostKey: host.publicKey.x963Representation,
        code: nil, request: request, onFailure: { continuation.yield("rejected") })
    await server.acceptTransport(duplicate)
    let outcome = await withTaskGroup(of: String.self) { group in
        group.addTask { var iterator = events.makeAsyncIterator(); return await iterator.next() ?? "closed" }
        group.addTask { try? await Task.sleep(for: .seconds(3)); return "timed out" }
        let result = await group.next() ?? "closed"
        group.cancelAll()
        return result
    }
    await newHandler.open()
    #expect(await peerObserved(fresh, "committed"))
    if outcome == "duplicate handler" { #expect(await peerObserved(duplicate, "committed")) }
    #expect(outcome == "rejected")
    #expect(await attempts.count == 2)
    #expect(await duplicate.failure == CompanionError.busy.rawValue)
    await server.stop()
    continuation.finish()
    oldClosedContinuation.finish()
}
