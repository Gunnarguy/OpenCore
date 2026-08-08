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
    private let reader: LineReader
    private let process: Process
    private let inputPipe: Pipe
    private var nextID = 1

    /// A single message larger than this is treated as a protocol violation rather than
    /// buffered. Without a cap, a server that never emits a newline consumes memory until
    /// the process dies, and the failure looks like a hang rather than a bad peer.
    public static let maximumLineBytes = 8 * 1024 * 1024

    public enum TransportError: Error, CustomStringConvertible {
        case launchFailed(String)
        case timedOut(method: String, seconds: TimeInterval)
        case closed(stderr: String)
        case oversizedMessage
        case malformed(String)
        case remote(code: Int, message: String)

        public var description: String {
            switch self {
            case .launchFailed(let detail): "could not launch server: \(detail)"
            case .timedOut(let method, let seconds): "'\(method)' did not respond within \(Int(seconds))s"
            case .closed(let stderr): "server exited\(stderr.isEmpty ? "" : ": \(stderr.prefix(400))")"
            case .oversizedMessage: "server sent a message over \(maximumLineBytes / 1_048_576)MB with no newline"
            case .malformed(let detail): "malformed response: \(detail)"
            case .remote(let code, let message): "server returned error \(code): \(message)"
            }
        }
    }

    /// Launch `command` with `arguments`.
    ///
    /// - Parameter environment: passed through verbatim. Callers resolve secrets from the
    ///   process environment themselves; nothing here reads or stores a credential.
    public init(command: String, arguments: [String], environment: [String: String]) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment

        inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        reader = LineReader(stdout: outputPipe.fileHandleForReading, stderr: errorPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            throw TransportError.launchFailed("\(command): \(error.localizedDescription)")
        }
    }

    /// Send a request and await its response.
    ///
    /// Responses are matched by id rather than by arrival order, because a server may
    /// interleave notifications and progress messages with the reply.
    @discardableResult
    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        let id = nextID
        nextID += 1

        var message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { message["params"] = params }
        try write(.object(message))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let line = try await reader.nextLine(before: deadline) else {
                throw process.isRunning
                    ? TransportError.timedOut(method: method, seconds: timeout)
                    : TransportError.closed(stderr: reader.collectedErrors())
            }

            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)
            else {
                // A line that is not JSON at all is almost always a server writing a log to
                // stdout in violation of the transport. Skip it rather than failing the call:
                // the response we want may well be on the next line.
                continue
            }

            // Not our reply: a notification, or a response to something else.
            guard envelope["id"]?.intValue == id else { continue }

            if let error = envelope["error"] {
                throw TransportError.remote(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? "unknown"
                )
            }
            return envelope["result"] ?? .null
        }
    }

    /// Send a notification. No id, and no response is ever expected.
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        try write(.object(message))
    }

    public func shutdown() {
        inputPipe.fileHandleForWriting.closeFile()
        // Closing stdin is the polite exit. Terminate anyway if the server ignores it: a
        // subprocess that outlives its sync is a leak the user cannot see.
        if process.isRunning {
            process.terminate()
        }
        reader.stop()
    }

    public func stderrOutput() -> String {
        reader.collectedErrors()
    }

    private func write(_ value: JSONValue) throws {
        guard let data = try? JSONEncoder().encode(value),
              var line = String(data: data, encoding: .utf8)
        else { throw TransportError.malformed("could not encode outgoing message") }

        // Defensive: an embedded newline would split one message into two invalid ones.
        line = line.replacingOccurrences(of: "\n", with: " ")
        guard let payload = (line + "\n").data(using: .utf8) else {
            throw TransportError.malformed("could not encode outgoing message")
        }
        inputPipe.fileHandleForWriting.write(payload)
    }
}

// MARK: - Line reading

/// Buffers subprocess output into whole lines, on its own queue.
///
/// Not `Sendable`; owned exclusively by the actor above. stderr is drained continuously and
/// concurrently rather than at exit, because a server that logs more than the 64KB pipe
/// buffer holds while nobody reads it deadlocks — a lesson already paid for once in the
/// Apple Notes connector.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var finished = false
    private var errorText = Data()

    private let queue = DispatchQueue(label: "opencore.mcp.stdio", qos: .userInitiated)

    init(stdout: FileHandle, stderr: FileHandle) {
        stdout.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                self.lock.withLock { self.finished = true }
                handle.readabilityHandler = nil
                return
            }
            self.append(chunk)
        }

        stderr.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                // Keep only the tail. Full stderr from a chatty server is unbounded and only
                // the most recent output is ever diagnostic.
                self.errorText.append(chunk)
                if self.errorText.count > 64 * 1024 {
                    self.errorText = self.errorText.suffix(32 * 1024)
                }
            }
        }
    }

    private func append(_ chunk: Data) {
        // `withLock` rather than lock()/unlock(): Swift 6 rejects the unscoped pair in any
        // context reachable from async code, because a suspension between them would hold
        // the lock across an await.
        lock.withLock {
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: lineData, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { lines.append(trimmed) }
                }
            }

            if buffer.count > StdioTransport.maximumLineBytes {
                buffer.removeAll()
                finished = true
            }
        }
    }

    /// Next buffered line, waiting until `deadline`. `nil` means the deadline passed or the
    /// stream closed.
    func nextLine(before deadline: Date) async throws -> String? {
        while Date() < deadline {
            let outcome: (line: String?, done: Bool) = lock.withLock {
                if !lines.isEmpty { return (lines.removeFirst(), false) }
                return (nil, finished)
            }
            if let line = outcome.line { return line }
            if outcome.done { return nil }

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
