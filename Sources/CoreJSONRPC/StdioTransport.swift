import Foundation

/// Speaks newline-delimited JSON-RPC to a subprocess over its stdin and stdout.
///
/// This is the client half of the same transport `CoreMCP` serves. The rules are symmetrical
/// and equally unforgiving: one message per line, no embedded newlines, and stderr is a
/// separate channel that carries logs rather than protocol.
///
/// The subprocess is untrusted. It can be slow, silent, chatty, or hostile, and every one of
/// those is handled here rather than left to explode in the caller: reads have a deadline,
/// stderr is drained continuously, and oversized lines are rejected instead of accumulating.
public actor StdioTransport {
    private let reader: StdioLineReader
    private let process: Process
    private let writer: StdioPipeWriter
    private let encodeFrame: @Sendable (RPCID?, [String: JSONValue]) throws -> Data
    private var nextID = 1
    private var closed = false
    private var shutdownTask: Task<Void, Never>?

    /// A single message larger than this is treated as a protocol violation rather than
    /// buffered. Without a cap, a server that never emits a newline consumes memory until
    /// the process dies, and the failure looks like a hang rather than a bad peer.
    public static let maximumLineBytes = 8 * 1024 * 1024

    public enum TransportError: Error, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
        case launchFailed(String)
        case timedOut(method: String, seconds: TimeInterval)
        case closed(stderr: String)
        case oversizedMessage
        case backlogLimit
        case tooManyRequests
        case writeFailed
        case writeQueueLimit
        case malformed(String)
        case remote(code: Int, message: String, data: JSONValue? = nil)

        public var debugDescription: String { description }
        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .launchFailed(let detail): "could not launch server: \(detail)"
            case .timedOut(let method, let seconds): "'\(method)' did not respond within \(seconds)s"
            case .closed(let stderr): "RPC transport is closed\(stderr.isEmpty ? "" : ": \(stderr.prefix(400))")"
            case .oversizedMessage: "server sent a message over \(maximumLineBytes / 1_048_576)MB"
            case .backlogLimit: "server exceeded the chosen buffered-message budget"
            case .tooManyRequests: "transport reached the chosen concurrent-request limit"
            case .writeFailed: "RPC stream write failed; transport is closed"
            case .writeQueueLimit: "outgoing RPC queue reached the chosen budget"
            case .malformed(let detail): "malformed response: \(detail)"
            case .remote(let code, let message, _): "server returned error \(code): \(message)"
            }
        }
    }

    /// Launch `command` with `arguments`.
    ///
    /// - Parameter environment: passed through verbatim. Callers resolve secrets from the
    ///   process environment themselves; nothing here reads or stores a credential.
    public init(command: String, arguments: [String], environment: [String: String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [command] + arguments
        child.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        let endpoint: StdioPipeEndpoint
        do { endpoint = try StdioPipeEndpoint(taking: input.fileHandleForWriting) }
        catch { try? input.fileHandleForWriting.close(); throw TransportError.launchFailed("could not configure owned stdin pipe") }
        do { try child.run() }
        catch { endpoint.close(); throw TransportError.launchFailed("\(command): \(error.localizedDescription)") }
        let reference = StdioWriterReference()
        let lineReader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading,
            replyRouting: true, onTerminal: {
                reference.closeSoon()
                if child.isRunning { child.terminate() }
            })
        let sender = StdioPipeWriter(endpoint: endpoint, onFailure: { lineReader.failOutbound() })
        reference.bind(sender)
        process = child; reader = lineReader; writer = sender
        encodeFrame = { try RPCWireObject.encode(id: $0, fields: $1) }
        // Startup output can fault before the weak writer reference was bound.
        do { try lineReader.requireHealthy() } catch { reference.closeSoon() }
    }

    /// Owned-pipe fixture seam; no process is launched and no live configuration is read.
    init(process: Process, input: Pipe, reader: StdioLineReader,
         encodeFrame: @escaping @Sendable (RPCID?, [String: JSONValue]) throws -> Data) throws {
        self.process = process; self.reader = reader; self.encodeFrame = encodeFrame
        writer = StdioPipeWriter(endpoint: try StdioPipeEndpoint(taking: input.fileHandleForWriting),
            onFailure: { reader.failOutbound() })
    }

    /// Send a request and await its response.
    ///
    /// Responses are matched by id rather than by arrival order, because a server may
    /// interleave notifications and progress messages with the reply.
    @discardableResult
    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw TransportError.closed(stderr: reader.collectedErrors()) }
        // Chosen one-day API ceiling keeps date conversion bounded, not a peer/protocol limit.
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw TransportError.malformed("invalid request timeout") }
        guard nextID < Int.max else { throw TransportError.malformed("request id space exhausted") }
        let writeDeadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let id = RPCID.int(nextID); nextID += 1
        let registration = try reader.registerReply(id: id, deadline: Date().addingTimeInterval(timeout))
        defer { reader.unregisterReply(registration) }
        try Task.checkCancellation()
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        try await write(.object(message), id: id, deadline: writeDeadline, timeoutError: .timedOut(method: method, seconds: timeout))
        guard let wire = try await reader.nextReply(registration) else {
            throw process.isRunning ? TransportError.timedOut(method: method, seconds: timeout)
                : TransportError.closed(stderr: reader.collectedErrors())
        }
        try Task.checkCancellation()
        guard !closed else { throw TransportError.closed(stderr: reader.collectedErrors()) }
        let envelope = wire.value
        let hasResult = envelope["result"] != nil, hasError = envelope["error"] != nil
        guard envelope["jsonrpc"] == .string("2.0"), envelope["method"] == nil, hasResult != hasError else {
            throw TransportError.malformed("expected one JSON-RPC response")
        }
        if hasError {
            guard envelope["error"]?.objectValue != nil,
                  envelope["error"]?["code"]?.intValue != nil, envelope["error"]?["message"]?.stringValue != nil,
                  let error = RPCError.remoteError(in: envelope) else {
                throw TransportError.malformed("response error was not a code/message object")
            }
            throw TransportError.remote(code: error.code, message: error.message, data: error.data)
        }
        return envelope["result"] ?? .null
    }

    /// Send a notification. No id, and no response is ever expected.
    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        try Task.checkCancellation()
        guard !closed else { throw TransportError.closed(stderr: reader.collectedErrors()) }
        try reader.requireHealthy()
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        // Chosen notification write budget; acceptance is not peer delivery acknowledgement.
        try await write(.object(message), deadline: .now.advanced(by: .seconds(15)), timeoutError: .timedOut(method: method, seconds: 15))
        try Task.checkCancellation()
        guard !closed else { throw TransportError.closed(stderr: reader.collectedErrors()) }
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; reader.stop()
        let sender = writer, child = process
        // Every caller awaits the same descriptor-close completion. TERM remains a request;
        // native Foundation supplies no public safe arbitrary-signal/forced-exit operation.
        let task = Task {
            await sender.close()
            if child.isRunning { child.terminate() }
        }
        shutdownTask = task
        await task.value
    }

    public func stderrOutput() -> String {
        reader.collectedErrors()
    }

    private func write(_ value: JSONValue, id: RPCID? = nil, deadline: ContinuousClock.Instant,
                       timeoutError: TransportError) async throws {
        guard let fields = value.objectValue, var payload = try? encodeFrame(id, fields) else {
            throw TransportError.malformed("could not encode outgoing message")
        }
        payload.append(0x0A)
        try reader.admitWrite()
        let receiver = reader
        do { try await writer.send(payload, deadline: deadline, timeoutError: timeoutError, admit: { try receiver.requireHealthy() }) }
        catch StdioPipeError.closed { throw TransportError.closed(stderr: reader.collectedErrors()) }
    }

}

/// Weak binding prevents reader→writer→reader lifetime cycles during terminal callbacks.
private final class StdioWriterReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var writer: StdioPipeWriter?
    func bind(_ writer: StdioPipeWriter) { lock.withLock { self.writer = writer } }
    func closeSoon() {
        if let writer = lock.withLock({ writer }) { Task { await writer.close() } }
    }
}

// MARK: - Line reading

/// Buffers whole lines from FileHandle callbacks. The lock protects callbacks and async readers.
/// stderr drains concurrently rather than waiting until exit, so a chatty peer cannot fill its
/// error pipe and deadlock while the caller waits for stdout.
final class StdioLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutReadLock = NSLock()
    private let stderrReadLock = NSLock()
    private var buffer = Data()
    private struct Line { let text: String; let receivedAt: Date; let byteCount: Int }
    private var lines: [Line] = []
    private var queuedBytes = 0
    private var nextReceipt = 0
    private var parsingReceipt: (number: Int, receivedAt: Date)?
    private var inbox = StdioReplyInbox()
    private let replyRouting: Bool
    private let parseFrame: @Sendable (Data) throws -> RPCWireObject
    private let onTerminal: @Sendable () -> Void
    private var terminalNotified = false
    private var fatal: StdioTransport.TransportError?
    // Chosen generic FIFO limits; routed replies separately cap active count/retained bytes.
    private static let maximumQueuedLines = 1024
    private static let maximumQueuedBytes = 16 * 1024 * 1024
    private let clock: @Sendable () -> Date
    private var finished = false
    private var errorText = Data()

    init(stdout: FileHandle, stderr: FileHandle, clock: @escaping @Sendable () -> Date = { Date() },
         replyRouting: Bool = false, parseFrame: @escaping @Sendable (Data) throws -> RPCWireObject = { try RPCWireObject.decode($0) }, inbox: StdioReplyInbox = .init(), onTerminal: @escaping @Sendable () -> Void = {}) {
        self.clock = clock; self.replyRouting = replyRouting; self.parseFrame = parseFrame; self.inbox = inbox; self.onTerminal = onTerminal
        stdout.readabilityHandler = { [weak self] handle in
            guard let self else { handle.readabilityHandler = nil; return }
            if self.consumeStdout(read: { handle.availableData }) { handle.readabilityHandler = nil }
        }

        stderr.readabilityHandler = { [weak self] handle in
            guard let self else { handle.readabilityHandler = nil; return }
            self.stderrReadLock.withLock {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
                self.lock.withLock {
                    // Keep only the tail; arbitrary server logging must not grow without bound.
                    self.errorText.append(chunk)
                    if self.errorText.count > 64 * 1024 { self.errorText = self.errorText.suffix(32 * 1024) }
                }
            }
        }
    }

    /// Reading bytes, publishing complete lines and marking EOF are one ordered operation.
    /// The separate state lock lets async readers/stop proceed even if a pipe read blocks.
    /// Returns true when no more stdout callbacks are needed.
    @discardableResult
    func consumeStdout(read: () -> Data) -> Bool {
        stdoutReadLock.withLock {
            let state = lock.withLock { (finished, fatal != nil) }
            if state.0, !state.1 { return true }
            let chunk = read()
            if chunk.isEmpty { lock.withLock { finished = true }; return true }
            if state.1 { return false } // Drain/discard after fatal faults until owned child exits.
            append(chunk)
            notifyTerminal()
            return false
        }
    }

    private struct Frame { let data: Data; let receivedAt: Date; let receipt: Int }
    private func append(_ chunk: Data) {
        let receivedAt = clock()
        let receipt: (offset: Int, number: Int)? = lock.withLock {
            guard !finished else { return nil }
            guard nextReceipt < Int.max else { failLocked(.backlogLimit); return nil }
            let number = nextReceipt; nextReceipt += 1
            // Stamp the entire appended chunk before parsing any frame. Frames later in the
            // chunk must not become eligible for a registration created while parsing earlier ones.
            parsingReceipt = (number, receivedAt)
            let offset = buffer.count; buffer.append(chunk); return (offset, number)
        }
        guard let receipt else { return }
        var searchOffset = receipt.offset
        var consumed = 0
        defer {
            // Compact once per chunk, not once per short line (which shifts a long tail).
            lock.withLock {
                if consumed > 0 { buffer.removeFirst(min(consumed, buffer.count)) }
                parsingReceipt = nil
            }
        }
        while true {
            let frame: Frame? = lock.withLock {
                guard !finished else { return nil }
                guard searchOffset < buffer.count,
                      let newline = buffer[buffer.index(buffer.startIndex, offsetBy: searchOffset)...].firstIndex(of: 0x0A) else {
                    if buffer.count - consumed > StdioTransport.maximumLineBytes { failLocked(.oversizedMessage) }
                    return nil
                }
                let end = buffer.distance(from: buffer.startIndex, to: newline)
                guard end - consumed <= StdioTransport.maximumLineBytes else { failLocked(.oversizedMessage); return nil }
                let frame = Frame(data: Data(buffer[buffer.index(buffer.startIndex, offsetBy: consumed)..<newline]),
                    receivedAt: receivedAt, receipt: receipt.number)
                consumed = end + 1; searchOffset = consumed
                return frame
            }
            guard let frame else { return }
            // Strict decoding never holds the state mutex. Stop/unregister/cancel can proceed;
            // publication checks current registration sequence/deadline after parsing completes.
            if replyRouting {
                let parsed = try? parseFrame(frame.data)
                lock.withLock {
                    guard !finished, let parsed else { return }
                    do { try inbox.receive(parsed, receipt: frame.receipt, receivedAt: frame.receivedAt, byteCount: frame.data.count) }
                    catch { failLocked(.backlogLimit) }
                }
            } else if let text = String(data: frame.data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lock.withLock {
                        guard !finished else { return }
                        guard lines.count < Self.maximumQueuedLines,
                              frame.data.count <= Self.maximumQueuedBytes - queuedBytes else { failLocked(.backlogLimit); return }
                        lines.append(Line(text: trimmed, receivedAt: receivedAt, byteCount: frame.data.count))
                        queuedBytes += frame.data.count
                    }
                }
            }
        }
    }

    // Called only under lock. Native cleanup is deliberately separate from state publication.
    private func failLocked(_ error: StdioTransport.TransportError) {
        guard fatal == nil else { return }
        fatal = error; finished = true
        buffer.removeAll(); lines.removeAll(); queuedBytes = 0; inbox.clear()
    }
    private func notifyTerminal() {
        let notify = lock.withLock {
            guard fatal != nil, !terminalNotified else { return false }
            terminalNotified = true; return true
        }
        if notify { onTerminal() }
    }

    func failOutbound() {
        lock.withLock { failLocked(.writeFailed) }
        notifyTerminal()
    }
    func requireHealthy() throws {
        try lock.withLock {
            if let fatal { throw fatal }
            if finished { throw StdioTransport.TransportError.closed(stderr: "") }
        }
    }
    func admitWrite() throws {
        try lock.withLock {
            if let fatal { throw fatal }
            if finished { throw StdioTransport.TransportError.closed(stderr: "") }
            try Task.checkCancellation()
        }
    }
    func registerReply(id: RPCID, deadline: Date) throws -> StdioReplyRegistration {
        try lock.withLock {
            if let fatal { throw fatal }
            guard !finished else { throw StdioTransport.TransportError.closed(stderr: "") }
            return try inbox.register(id: id, receiptFloor: nextReceipt, deadline: deadline)
        }
    }
    func unregisterReply(_ registration: StdioReplyRegistration) { lock.withLock { inbox.unregister(registration) } }

    func nextReply(_ registration: StdioReplyRegistration, onPending: @Sendable () -> Void = {}) async throws -> RPCWireObject? {
        while true {
            try Task.checkCancellation()
            let outcome: (RPCWireObject?, Bool, Bool) = try lock.withLock {
                if let fatal { throw fatal }
                guard inbox.isRegistered(registration) else { throw CancellationError() }
                if let reply = inbox.take(registration) { return (reply, false, false) }
                let eligibleParsing = parsingReceipt.map {
                    $0.number >= registration.receiptFloor && $0.receivedAt <= registration.deadline
                } ?? false
                return (nil, finished, eligibleParsing)
            }
            if let reply = outcome.0 { return reply }
            onPending() // Outside the mutex; fixture barrier observes actual waiter inspection.
            if outcome.1 { throw StdioTransport.TransportError.closed(stderr: collectedErrors()) }
            guard outcome.2 || clock() < registration.deadline else { return nil }
            try await Task.sleep(for: .milliseconds(10)) // Chosen polling interval, not measured latency.
        }
    }

    /// Return a line received by `deadline`, including a buffered reply when the waiter resumes
    /// late. Once that finite backlog is exhausted, expired waits and closed streams return nil.
    func nextLine(before deadline: Date) async throws -> String? {
        while true {
            try Task.checkCancellation()
            let outcome: (line: String?, done: Bool) = try lock.withLock {
                if let fatal { throw fatal }
                if let first = lines.first {
                    guard first.receivedAt <= deadline else { return (nil, true) }
                    let line = lines.removeFirst(); queuedBytes -= line.byteCount
                    return (line.text, false)
                }
                return (nil, finished)
            }
            if let line = outcome.line { return line }
            if outcome.done { return nil }
            // Only the finite backlog received on time remains eligible. A chatty peer's
            // later notifications/nonmatching replies cannot extend a request indefinitely.
            guard clock() < deadline else { return nil }

            // Polling at 10ms rather than using a condition variable: the wait is bounded, the
            // cost is negligible against subprocess latency, and it keeps this readable.
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func collectedErrors() -> String {
        lock.withLock {
            String(decoding: errorText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func stop() {
        lock.withLock { finished = true }
    }
}
