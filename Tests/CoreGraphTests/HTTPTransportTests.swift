import Foundation
import Synchronization
import Testing
@testable import CoreJSONRPC

private struct HTTPFixtureReply: Sendable {
    var status = 200
    var contentType = "application/json"
    var headers: [String: String] = [:]
    var body = Data()
    var finish = true
    var sendHeaders = true
    var trickle: UInt8?
    var finishGate: HTTPTestGate?
}

private final class HTTPFixture: Sendable {
    struct Record: Sendable { let message: JSONValue; let headers: [String: String] }
    static let registry = Mutex<[String: HTTPFixture]>([:])
    let id = UUID().uuidString
    let script: @Sendable (JSONValue) throws -> HTTPFixtureReply
    let records = Mutex<[Record]>([])
    let stops = Mutex(0)
    init(script: @escaping @Sendable (JSONValue) throws -> HTTPFixtureReply) {
        self.script = script
        Self.registry.withLock { $0[id] = self }
    }
    func transport(limits: HTTPReadLimits = .standard, session shared: URLSession? = nil) -> (HTTPTransport, URLSession) {
        let session: URLSession
        if let shared { session = shared }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HTTPFixtureProtocol.self]
            session = URLSession(configuration: config)
        }
        // Unsupported by normal URL loading: losing the injected protocol cannot dial a service.
        let endpoint = URL(string: "opencore-fixture://rpc/\(id)")!
        return (HTTPTransport(endpoint: endpoint, session: session, limits: limits), session)
    }
    func dispose(_ session: URLSession) {
        session.invalidateAndCancel()
        Self.registry.withLock { $0[id] = nil }
    }
}

private final class HTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    // Serialize stop and client notifications, including synchronous callback reentrancy.
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var finished = false
    private var fixture: HTTPFixture?
    private var pump: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "opencore-fixture" }
    override class func canInit(with task: URLSessionTask) -> Bool {
        (task.currentRequest ?? task.originalRequest).map { canInit(with: $0) } ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let fixture = HTTPFixture.registry.withLock({ $0[url.lastPathComponent] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        lock.lock(); self.fixture = fixture; lock.unlock()
        do {
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                    guard body.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
                }
                data = body
            } else { data = Data() }
            let message = try JSONDecoder().decode(JSONValue.self, from: data)
            fixture.records.withLock { $0.append(.init(message: message, headers: request.allHTTPHeaderFields ?? [:])) }
            let reply = try fixture.script(message)
            guard reply.sendHeaders else { return }
            var headers = reply.headers
            headers["Content-Type"] = reply.contentType
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw URLError(.badServerResponse)
            }
            send {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !reply.body.isEmpty, !stopped { client?.urlProtocol(self, didLoad: reply.body) }
                if reply.finish, reply.finishGate == nil, !stopped { finished = true; client?.urlProtocolDidFinishLoading(self) }
            }
            if let gate = reply.finishGate {
                let task = Task.detached { @Sendable [self, gate] in
                    await gate.wait()
                    self.finishLoading()
                }
                lock.lock()
                if stopped || finished { task.cancel() } else { pump = task }
                lock.unlock()
            }
            if let byte = reply.trickle {
                let task = Task.detached { @Sendable [self, byte] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                        guard self.sendByte(byte) else { return }
                    }
                }
                lock.lock()
                if stopped || finished { task.cancel() } else { pump = task }
                lock.unlock()
            }
        } catch { send { finished = true; client?.urlProtocol(self, didFailWithError: error) } }
    }

    @discardableResult private func send(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !finished else { return false }
        action()
        return true
    }
    private func sendByte(_ byte: UInt8) -> Bool {
        send { client?.urlProtocol(self, didLoad: Data([byte])) }
    }
    private func finishLoading() {
        send { finished = true; client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let task = pump, fixture = fixture
        pump = nil
        lock.unlock()
        task?.cancel()
        fixture?.stops.withLock { $0 += 1 }
    }
}

private func httpResponse(_ request: JSONValue, result: JSONValue = .string("fixture result")) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": request["id"] ?? .null, "result": result])
}
private func httpBytes(_ value: JSONValue, pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    if pretty { encoder.outputFormatting = .prettyPrinted }
    return try encoder.encode(value)
}
private func eventually(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3)) // Chosen fixture escape budget.
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    return predicate()
}
private func escapedHTTP<T: Sendable>(session: URLSession, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let work = Task { try await operation() }
    let escape = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        work.cancel()
        session.invalidateAndCancel() // Fixture session only; never production request cancellation.
    }
    defer { escape.cancel() }
    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
}

@Test("HTTP fixture sessions carry actual JSON and SSE replies without a listener", arguments: [false, true])
func httpFixtureRoundTrip(sse: Bool) async throws {
    let fixture = HTTPFixture { request in
        let value = httpResponse(request)
        if !sse { return HTTPFixtureReply(body: try httpBytes(value)) }
        let json = String(decoding: try httpBytes(value, pretty: true), as: UTF8.self)
        let stream = json.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)\n" }.joined() + "\n"
        return HTTPFixtureReply(contentType: "text/event-stream", body: Data(stream.utf8))
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    let value = try await escapedHTTP(session: session) { try await transport.request("fixture", timeout: 2) }
    #expect(value == .string("fixture result"))
    #expect(fixture.records.withLock { $0.count } == 1)
    await transport.shutdown()
}

// The old JSONValue matcher rounded raw1.0000000000000001 into request1's numeric ID.
@Test("HTTP and SSE cannot correlate a rounded fraction to an integer request", arguments: [false, true])
func httpExactWireIDCorrelation(sse: Bool) async throws {
    for token in ["1.0000000000000001", "1e0"] {
        let fixture = HTTPFixture { _ in
            let json = "{\"jsonrpc\":\"2.0\",\"id\":\(token),\"result\":\"fixture\"}"
            return HTTPFixtureReply(contentType: sse ? "text/event-stream" : "application/json",
                body: Data((sse ? "data: \(json)\n\n" : json).utf8))
        }
        let (transport, session) = fixture.transport()
        defer { fixture.dispose(session) }
        if token == "1e0" { #expect(try await transport.request("fixture", timeout: 2) == .string("fixture")) }
        else {
            let error = try #require(await httpFailure(transport, session))
            guard case HTTPTransportError.malformed = error else { Issue.record("invalid wire ID became a peer error"); return }
        }
        await transport.shutdown()
    }
}

private func httpFailure(_ transport: HTTPTransport, _ session: URLSession,
                         method: String = "fixture", timeout: TimeInterval = 2) async -> (any Error)? {
    do {
        _ = try await escapedHTTP(session: session) { try await transport.request(method, timeout: timeout) }
        Issue.record("expected the fixture request to fail")
        return nil
    } catch { return error }
}
private func httpError(_ request: JSONValue, data: JSONValue = .null, identified: Bool = true) -> JSONValue {
    var value: [String: JSONValue] = ["jsonrpc": .string("2.0"),
        "error": .object(["code": .int(-32022), "message": .string("fixture failure"), "data": data])]
    if identified { value["id"] = request["id"] ?? .null }
    return .object(value)
}
private func httpSSE(_ value: JSONValue) throws -> Data {
    Data("data: \(String(decoding: try httpBytes(value), as: UTF8.self))\n\n".utf8)
}

// The bug: non-2xx responses were reduced to status text, losing protocol error details.
@Test("HTTP JSON and SSE failures preserve structured details and status", arguments: [200, 400, 404], [false, true])
func httpRecognizedFailures(status: Int, sse: Bool) async throws {
    for detail: JSONValue in [.null, .string("fixture-private-detail"), .object(["supported": .array([.string("fixture-era")])])] {
        let fixture = HTTPFixture { request in
            let error = httpError(request, data: detail)
            return HTTPFixtureReply(status: status, contentType: sse ? "text/event-stream" : "application/json",
                body: try sse ? httpSSE(error) : httpBytes(error))
        }
        let (transport, session) = fixture.transport()
        defer { fixture.dispose(session) }
        let error = try #require(await httpFailure(transport, session))
        #expect(rpcErrorCode(error) == -32022)
        #expect(rpcError(error)?.data == detail)
        #expect((error as? HTTPTransportError)?.httpStatusCode == (status == 200 ? nil : status))
        #expect(!String(reflecting: error).contains("fixture-private-detail"))
        await transport.shutdown()
    }
}

@Test("authorization statuses cannot become protocol-era evidence", arguments: [401, 403])
func httpAuthorizationIsNotNegotiation(status: Int) async throws {
    let fixture = HTTPFixture { request in
        HTTPFixtureReply(status: status,
            headers: ["WWW-Authenticate": "Bearer resource_metadata=\"https://example.invalid/metadata\""],
            body: try httpBytes(httpError(request)))
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    let error = try #require(await httpFailure(transport, session))
    #expect((error as? HTTPTransportError)?.httpStatusCode == status)
    #expect(rpcErrorCode(error) == nil)
    if status == 401 {
        guard case HTTPTransportError.unauthorized(let url) = error else { Issue.record("lost authorization challenge"); return }
        #expect(url?.absoluteString == "https://example.invalid/metadata")
    }
    await transport.shutdown()
}

@Test("notification POST accepts only 202 and preserves unidentified failed RPC errors", arguments: [202, 200, 400])
func httpNotificationAcceptance(status: Int) async throws {
    let fixture = HTTPFixture { request in
        HTTPFixtureReply(status: status, body: status == 400 ? try httpBytes(httpError(request, identified: false)) : Data(),
            finish: status != 202) // Accepted headers must not wait for a rogue endless body.
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    do {
        try await escapedHTTP(session: session) { try await transport.notify("notifications/fixture") }
        #expect(status == 202)
    } catch {
        #expect(status != 202)
        if status == 400 { #expect(rpcErrorCode(error) == -32022) }
        else { #expect(error is HTTPTransportError) }
    }
    #expect(fixture.records.withLock { $0.first?.message["id"] } == nil)
    await transport.shutdown()
}

// A byte cap must stop the actual load, including endless no-newline SSE and error bodies.
@Test("HTTP reads stop at a configured byte budget", arguments: [200, 400], [false, true])
func httpBodyBudgetStopsLoad(status: Int, sse: Bool) async throws {
    let fixture = HTTPFixture { _ in
        HTTPFixtureReply(status: status, contentType: sse ? "text/event-stream" : "application/json",
            body: Data(repeating: 0x78, count: 33), finish: false)
    }
    let (transport, session) = fixture.transport(limits: .init(maximumBytes: 32, diagnosticBytes: 7))
    defer { fixture.dispose(session) }
    let error = try #require(await httpFailure(transport, session))
    guard case HTTPTransportError.responseTooLarge(let limit) = error else { Issue.record("did not enforce byte budget: \(error)"); return }
    #expect(limit == 32)
    #expect(await eventually { fixture.stops.withLock { $0 } > 0 })
    await transport.shutdown()
}

@Test("application deadline covers headers stalled bodies and trickling SSE", arguments: [0, 1, 2])
func httpWholeExchangeDeadline(mode: Int) async throws {
    let fixture = HTTPFixture { _ in
        HTTPFixtureReply(contentType: "text/event-stream", finish: false, sendHeaders: mode != 0,
            trickle: mode == 2 ? 0x78 : nil)
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    let start = ContinuousClock.now
    let error = try #require(await httpFailure(transport, session, timeout: 0.12))
    #expect(start.duration(to: .now) < .seconds(2)) // Chosen generous fixture escape bound.
    guard case HTTPTransportError.timedOut(let method, let seconds) = error else { Issue.record("lost deadline: \(error)"); return }
    #expect(method == "fixture")
    #expect(seconds == 0.12)
    #expect(String(describing: error).contains("0.12s"))
    // A scheduler may let the deadline win before URL loading starts. If it did start,
    // cancellation must stop it; caller-cancellation coverage separately waits for readiness.
    if fixture.records.withLock({ !$0.isEmpty }) {
        #expect(await eventually { fixture.stops.withLock { $0 } > 0 })
    }
    await transport.shutdown()
}

@Test("caller cancellation stops its owned HTTP load and leaves concurrent calls usable")
func httpCallerCancellationIsLocal() async throws {
    let fixture = HTTPFixture { request in
        request["method"] == .string("stall") ? HTTPFixtureReply(finish: false, sendHeaders: false) :
            HTTPFixtureReply(body: try httpBytes(httpResponse(request)))
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    let slow = Task { try await escapedHTTP(session: session) { try await transport.request("stall", timeout: 3) } }
    #expect(await eventually { fixture.records.withLock { $0.count } == 1 })
    #expect(try await transport.request("parallel", timeout: 2) == .string("fixture result"))
    let start = ContinuousClock.now
    slow.cancel()
    do { _ = try await slow.value; Issue.record("cancelled call succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(await eventually { fixture.stops.withLock { $0 } > 0 })
    #expect(try await transport.request("after-cancel", timeout: 2) == .string("fixture result"))
    let headers = try #require(fixture.records.withLock { $0.last?.headers })
    #expect(headers.first { $0.key.lowercased() == "accept" }?.value == "application/json, text/event-stream")
    await transport.shutdown()
}

@Test("shutdown cancels this transport without invalidating an injected shared session")
func httpSharedSessionOwnership() async throws {
    let stalled = HTTPFixture { _ in HTTPFixtureReply(finish: false, sendHeaders: false) }
    let fast = HTTPFixture { request in HTTPFixtureReply(body: try httpBytes(httpResponse(request))) }
    let (first, session) = stalled.transport()
    let (second, _) = fast.transport(session: session)
    defer { stalled.dispose(session); fast.dispose(session) }
    let work = Task { try await escapedHTTP(session: session) { try await first.request("stall", timeout: 3) } }
    #expect(await eventually { stalled.records.withLock { !$0.isEmpty } })
    await first.shutdown()
    do { _ = try await work.value; Issue.record("shutdown request succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(try await second.request("fixture", timeout: 2) == .string("fixture result"))
    let closed = try #require(await httpFailure(first, session))
    guard case HTTPTransportError.closed = closed else { Issue.record("transport reopened after shutdown"); return }
    await second.shutdown()
}

@Test("session header is published only by a completed successful initialize reply")
func httpSessionHeaderPublication() async throws {
    let fixture = HTTPFixture { request in
        let method = request["method"]?.stringValue
        return HTTPFixtureReply(status: method == "failed" ? 400 : 200,
            headers: ["Mcp-Session-Id": method == "initialize" ? "fixture-good-session" : "fixture-poison-session"],
            body: try httpBytes(method == "failed" ? httpError(request) : httpResponse(request)))
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    _ = try #require(await httpFailure(transport, session, method: "failed"))
    _ = try await transport.request("ordinary", timeout: 2)
    _ = try await transport.request("initialize", timeout: 2)
    _ = try await transport.request("ordinary", timeout: 2)
    _ = try await transport.request("ordinary", timeout: 2)
    let sessionHeaders = fixture.records.withLock { records in records.map {
        $0.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
    } }
    #expect(sessionHeaders == [nil, nil, nil, "fixture-good-session", "fixture-good-session"])
    await transport.shutdown()
}

@Test("cancelled initialize headers cannot poison a subsequent request")
func httpCancelledInitializeDoesNotPublishSession() async throws {
    let fixture = HTTPFixture { request in
        if request["method"] == .string("initialize") {
            return HTTPFixtureReply(headers: ["Mcp-Session-Id": "fixture-late-session"], finish: false)
        }
        return HTTPFixtureReply(body: try httpBytes(httpResponse(request)))
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    _ = try #require(await httpFailure(transport, session, method: "initialize", timeout: 0.1))
    _ = try await transport.request("after", timeout: 2)
    #expect(fixture.records.withLock { $0.last?.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value } == nil)
    await transport.shutdown()
}

@Test("failed or malformed initialize replies do not authorize a legacy session", arguments: [false, true])
func httpFailedInitializeDoesNotPublishSession(malformed: Bool) async throws {
    let fixture = HTTPFixture { request in
        if request["method"] == .string("initialize") {
            return HTTPFixtureReply(status: malformed ? 200 : 400, headers: ["Mcp-Session-Id": "fixture-refused-session"],
                body: malformed ? Data("{}".utf8) : try httpBytes(httpError(request)))
        }
        return HTTPFixtureReply(body: try httpBytes(httpResponse(request)))
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    _ = try #require(await httpFailure(transport, session, method: "initialize"))
    _ = try await transport.request("after", timeout: 2)
    #expect(fixture.records.withLock { $0.last?.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value } == nil)
    await transport.shutdown()
}

// The bug: reentrant initialize calls could finish out of order and replace a newer session ID.
@Test("overlapping initialize is refused before a second POST can replace session ownership")
func httpOverlappingInitializeIsRefused() async throws {
    let gate = HTTPTestGate()
    defer { gate.release() }
    let fixture = HTTPFixture { request in
        HTTPFixtureReply(headers: ["Mcp-Session-Id": "fixture-owned-session"],
            body: try httpBytes(httpResponse(request)), finishGate: request["method"] == .string("initialize") ? gate : nil)
    }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    let first = Task { try await escapedHTTP(session: session) { try await transport.request("initialize", timeout: 3) } }
    #expect(await eventually { fixture.records.withLock { $0.count } == 1 })
    let error = try #require(await httpFailure(transport, session, method: "initialize", timeout: 2))
    guard case HTTPTransportError.malformed = error else { Issue.record("overlapping initialize was not refused"); gate.release(); _ = try? await first.value; return }
    #expect(fixture.records.withLock { $0.count } == 1)
    gate.release()
    #expect(try await first.value == .string("fixture result"))
    #expect(try await transport.request("after", timeout: 2) == .string("fixture result"))
    #expect(fixture.records.withLock { $0.last?.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value } == "fixture-owned-session")
    await transport.shutdown()
}

@Test("invalid timeouts and pre-cancelled calls never issue a POST")
func httpInvalidAndPreCancelledCalls() async throws {
    let fixture = HTTPFixture { request in HTTPFixtureReply(body: try httpBytes(httpResponse(request))) }
    let (transport, session) = fixture.transport()
    defer { fixture.dispose(session) }
    for timeout in [0, -1, Double.nan, Double.infinity, 86_401] {
        let error = try #require(await httpFailure(transport, session, timeout: timeout))
        guard case HTTPTransportError.malformed = error else { Issue.record("accepted invalid timeout"); continue }
    }
    let gate = HTTPTestGate()
    let work = Task {
        await gate.wait()
        return try await transport.request("fixture", timeout: 2)
    }
    work.cancel(); gate.release()
    do { _ = try await work.value; Issue.record("pre-cancelled request succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(fixture.records.withLock { $0.isEmpty })
    await transport.shutdown()
}

private final class HTTPTestGate: Sendable {
    private struct State { var released = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { value in
                if value.released { return true }
                value.waiters.append(continuation); return false
            }
            if released { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { value in
            value.released = true; let waiters = value.waiters; value.waiters = []; return waiters
        }
        for continuation in waiters { continuation.resume() }
    }
}

// A task group would keep waiting for an uncooperative child after its timeout won.
@Test("HTTP deadline returns before an uncooperative worker and fences its late result")
func httpExecutionFencesLateWorker() async throws {
    let owner = try HTTPRequestExecution(method: "fixture", timeout: 0.08)
    let gate = HTTPTestGate()
    let escape = Task {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        gate.release() // Independent escape if a mutation removes the watchdog.
    }
    defer { escape.cancel(); gate.release() }
    let started = Mutex(false)
    let completed = Mutex(false)
    let start = ContinuousClock.now
    do {
        _ = try await owner.value { _ in
            started.withLock { $0 = true }
            await gate.wait() // Deliberately ignores cancellation, but the test always releases it.
            completed.withLock { $0 = true }
            return HTTPTransferResult(envelope: .object(["result": .string("late")]), statusCode: 200, sessionID: "late")
        }
        Issue.record("late worker won")
    } catch { guard case HTTPTransportError.timedOut = error else { Issue.record("wrong error: \(error)"); return } }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(!completed.withLock { $0 })
    let entered = started.withLock { $0 }
    gate.release()
    if entered { #expect(await eventually { completed.withLock { $0 } }) }
    // It is also legal for the deadline to win before the worker enters. The next test
    // establishes entry first and proves cancellation fencing without this scheduling race.
    // A late native task must also be cancelled before it can start loading.
    let fixture = HTTPFixture { request in HTTPFixtureReply(body: try httpBytes(httpResponse(request))) }
    let (_, session) = fixture.transport()
    defer { fixture.dispose(session) }
    let task = session.dataTask(with: URL(string: "opencore-fixture://rpc/\(fixture.id)")!)
    owner.register(task)
    #expect(task.state == .canceling || task.state == .completed)
    #expect(fixture.records.withLock { $0.isEmpty })
}

@Test("entered HTTP worker returns after cancellation without publishing its late success")
func httpExecutionCancellationFencesEnteredWorker() async throws {
    let owner = try HTTPRequestExecution(method: "fixture", timeout: 10)
    let gate = HTTPTestGate()
    let started = Mutex(false), completed = Mutex(false)
    let escape = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        owner.cancel(); gate.release()
    }
    defer { escape.cancel(); gate.release() }
    let work = Task {
        try await owner.value { _ in
            started.withLock { $0 = true }
            await gate.wait()
            completed.withLock { $0 = true }
            return HTTPTransferResult(envelope: .object(["result": .string("late")]), statusCode: 200, sessionID: "late")
        }
    }
    #expect(await eventually { started.withLock { $0 } })
    owner.cancel()
    do { _ = try await work.value; Issue.record("cancelled execution published success") }
    catch { #expect(error is CancellationError) }
    #expect(!completed.withLock { $0 })
    gate.release()
    #expect(await eventually { completed.withLock { $0 } })
    do {
        _ = try await owner.value { _ in Issue.record("late success reopened execution"); throw CancellationError() }
        Issue.record("used execution succeeded twice")
    } catch { guard case HTTPTransportError.malformed = error else { Issue.record("execution state was replaced"); return } }
}
