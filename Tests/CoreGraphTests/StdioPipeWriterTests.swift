import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoreJSONRPC

private func writeTimeout(_ seconds: Double = 2) -> StdioTransport.TransportError { .timedOut(method: "fixture", seconds: seconds) }
private func waitForWriteSignal(_ signal: DispatchSemaphore, then action: @escaping @Sendable () -> Void = {}) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let entered = signal.wait(timeout: .now() + 3) == .success
            action() // Fault and release on this queue even while Swift executor threads are occupied.
            continuation.resume(returning: entered)
        }
    }
}
private func writerState(_ writer: StdioPipeWriter, frames: Int) async -> Bool {
    let limit = ContinuousClock.now.advanced(by: .seconds(3)) // Chosen fixture escape budget.
    while ContinuousClock.now < limit {
        if await writer.snapshot().frames == frames { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// Fill only this fixture pipe until nonblocking I/O says it is full. No guessed pipe capacity.
private func fillWritePipe(_ endpoint: StdioPipeEndpoint) throws -> Int {
    let block = Data(repeating: 0x70, count: 65_536)
    var count = 0
    while count < 8 * 1024 * 1024 { // Chosen fixture ceiling; never a production capacity claim.
        switch try endpoint.attempt(block, offset: 0) {
        case .progress(let written): count += written
        case .wouldBlock: return count
        case .interrupted: continue
        }
    }
    Issue.record("fixture pipe did not reach backpressure within its escape budget")
    return count
}
private func drainWritePadding(_ handle: FileHandle, count: Int) throws {
    var remaining = count
    while remaining > 0 {
        let data = try #require(try handle.read(upToCount: min(65_536, remaining)))
        guard !data.isEmpty else { Issue.record("fixture padding ended early"); return }
        remaining -= data.count
    }
}

@Test("owned pipe configuration is nonblocking per-descriptor and close is final")
func stdioWriteEndpointConfiguration() throws {
    let pipe = Pipe()
    let descriptor = pipe.fileHandleForWriting.fileDescriptor
    let endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0)
    #expect(fcntl(descriptor, F_GETNOSIGPIPE) == 1)
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    endpoint.close(); endpoint.close()
    #expect(throws: StdioPipeError.self) { try endpoint.attempt(Data([1]), offset: 0) }
    try pipe.fileHandleForReading.close()
}

@Test("native chunked writes advance the actual borrowed buffer offset exactly")
func stdioWriteNativeChunkOffsets() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting, maximumChunkBytes: 2)
    let offsets = Mutex<[Int]>([])
    let writer = StdioPipeWriter(endpoint: endpoint, onProgress: { next in offsets.withLock { $0.append(next) } })
    try await writer.send(Data("abcdef\n".utf8), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {})
    await writer.close()
    #expect(pipe.fileHandleForReading.availableData == Data("abcdef\n".utf8))
    #expect(offsets.withLock { $0 } == [2, 4, 6, 7])
}

// The original blocking write delayed cancellation and a short timeout behind a full pipe.
@Test("a blocked head frame does not delay queued expiry or queued cancellation")
func stdioWriteQueuedExpiryAndCancellation() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let padding = try fillWritePipe(endpoint)
    let writer = StdioPipeWriter(endpoint: endpoint)
    let headData = Data("head\n".utf8)
    let head = Task { try await writer.send(headData, deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 1))
    let cancelled = Task { try await writer.send(Data("cancelled\n".utf8), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 2))
    let cancelledAt = ContinuousClock.now
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(cancelledAt.duration(to: .now) < .seconds(1))
    let start = ContinuousClock.now
    do {
        try await writer.send(Data("expired\n".utf8), deadline: .now.advanced(by: .milliseconds(80)), timeoutError: writeTimeout(0.08), admit: {})
        Issue.record("queued deadline succeeded")
    } catch { guard case StdioTransport.TransportError.timedOut = error else { Issue.record("wrong queue timeout"); await writer.close(); return } }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(await writer.snapshot().frames == 1)
    #expect(await writer.snapshot().bytes == headData.count)
    try drainWritePadding(pipe.fileHandleForReading, count: padding)
    try await head.value
    await writer.close()
    #expect(pipe.fileHandleForReading.availableData == headData)
}

@Test("local writer queue limits refuse only a new submission")
func stdioWriteQueueLimitIsLocal() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let padding = try fillWritePipe(endpoint)
    let data = Data("accepted\n".utf8)
    let writer = StdioPipeWriter(endpoint: endpoint, maximumFrames: 1, maximumBytes: 64)
    let first = Task { try await writer.send(data, deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 1))
    do { try await writer.send(Data([1]), deadline: .now.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: {}); Issue.record("queue overflow was admitted") }
    catch { guard case StdioTransport.TransportError.writeQueueLimit = error else { Issue.record("wrong local queue failure"); await writer.close(); return } }
    #expect(await writer.snapshot().closed == false)
    #expect(await writer.snapshot().bytes == data.count)
    try drainWritePadding(pipe.fileHandleForReading, count: padding)
    try await first.value
    await writer.close()
    #expect(pipe.fileHandleForReading.availableData == data)
}

@Test("writer byte budget is independent of its frame budget and is released on cancellation")
func stdioWriteByteBudgetAndZeroByteCancellation() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let padding = try fillWritePipe(endpoint)
    let writer = StdioPipeWriter(endpoint: endpoint, maximumFrames: 8, maximumBytes: 8)
    let first = Task { try await writer.send(Data(repeating: 0x41, count: 8), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 1))
    do { try await writer.send(Data([1]), deadline: .now.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: {}); Issue.record("byte budget overflow was admitted") }
    catch { guard case StdioTransport.TransportError.writeQueueLimit = error else { Issue.record("wrong byte budget failure"); await writer.close(); return } }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await writer.snapshot().bytes == 0)
    #expect(await writer.snapshot().closed == false)
    try drainWritePadding(pipe.fileHandleForReading, count: padding)
    try await writer.send(Data("reuse\n".utf8), deadline: .now.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: {})
    await writer.close()
    #expect(pipe.fileHandleForReading.availableData == Data("reuse\n".utf8))
}

@Test("an active frame deadline before any accepted byte leaves framing usable")
func stdioWriteZeroByteDeadlineIsLocal() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let padding = try fillWritePipe(endpoint)
    let writer = StdioPipeWriter(endpoint: endpoint)
    do { try await writer.send(Data("expired\n".utf8), deadline: .now.advanced(by: .milliseconds(60)), timeoutError: writeTimeout(0.06), admit: {}); Issue.record("blocked deadline succeeded") }
    catch { guard case StdioTransport.TransportError.timedOut = error else { Issue.record("wrong active timeout"); await writer.close(); return } }
    #expect(await writer.snapshot().closed == false)
    #expect(await writer.snapshot().bytes == 0)
    try drainWritePadding(pipe.fileHandleForReading, count: padding)
    try await writer.send(Data("next\n".utf8), deadline: .now.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: {})
    await writer.close()
    #expect(pipe.fileHandleForReading.availableData == Data("next\n".utf8))
}

@Test("a partial frame deadline closes framing and releases every queued owner")
func stdioWritePartialDeadlineClosesFraming() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let faults = Mutex(0), progressed = DispatchSemaphore(value: 0)
    let start = ContinuousClock.now, clock = Mutex(ContinuousClock.now)
    let writer = StdioPipeWriter(endpoint: endpoint, now: { clock.withLock { $0 } }, onProgress: { _ in progressed.signal() }, onFailure: { faults.withLock { $0 += 1 } })
    // Independent real-time escape: even a deliberately broken deadline check must resolve
    // this fixture's continuations, rather than hanging behind its frozen injected clock.
    let watchdog = Task {
        do { try await Task.sleep(for: .seconds(5)); await writer.close() } catch {}
    }
    defer { watchdog.cancel() }
    let first = Task { try await writer.send(Data(repeating: 0x41, count: 1024 * 1024), deadline: start.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: {}) }
    #expect(await waitForWriteSignal(progressed))
    let follower = Task { try await writer.send(Data("Z-follower\n".utf8), deadline: start.advanced(by: .seconds(10)), timeoutError: writeTimeout(10), admit: {}) }
    #expect(await writerState(writer, frames: 2))
    clock.withLock { $0 = start.advanced(by: .seconds(2)) }
    do { try await first.value; Issue.record("partial deadline succeeded") }
    catch { guard case StdioTransport.TransportError.timedOut = error else { Issue.record("wrong partial timeout"); await writer.close(); return } }
    clock.withLock { $0 = start.advanced(by: .seconds(20)) } // Lets a broken, still-open follower resolve too.
    await #expect(throws: StdioTransport.TransportError.self) { try await follower.value }
    #expect(await writer.snapshot().closed)
    #expect(await writer.snapshot().bytes == 0)
    #expect(faults.withLock { $0 } == 1)
    #expect(!pipe.fileHandleForReading.availableData.contains(0x5A))
}

// Once a prefix entered the pipe, appending the next frame would manufacture a corrupt message.
@Test("cancelling a partial stdio frame closes framing before its follower can write")
func stdioWritePartialCancellationClosesFraming() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    _ = try fillWritePipe(endpoint)
    let progressed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), faults = Mutex(0)
    let once = Mutex(false)
    let writer = StdioPipeWriter(endpoint: endpoint, onProgress: { _ in
        let first = once.withLock { value in if value { return false }; value = true; return true }
        if first { progressed.signal(); _ = release.wait(timeout: .now() + 5) }
    }, onFailure: { faults.withLock { $0 += 1 } })
    let first = Task { try await writer.send(Data(repeating: 0x41, count: 1024 * 1024), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 1))
    let follower = Task { try await writer.send(Data("Z-follower\n".utf8), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 2))
    _ = try pipe.fileHandleForReading.read(upToCount: 4096)
    #expect(await waitForWriteSignal(progressed, then: { first.cancel(); release.signal() }))
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: StdioTransport.TransportError.self) { try await follower.value }
    #expect(await writer.snapshot().closed)
    #expect(await writer.snapshot().bytes == 0)
    #expect(faults.withLock { $0 } == 1)
    let remaining = pipe.fileHandleForReading.availableData
    #expect(!remaining.contains(0x5A))
    await writer.close()
}

@Test("cancellation racing the final accepted byte does not poison the next frame")
func stdioWriteFinalByteCancellationIsLocal() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let progressed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), faults = Mutex(0)
    let once = Mutex(false)
    let writer = StdioPipeWriter(endpoint: endpoint, onProgress: { _ in
        let first = once.withLock { value in if value { return false }; value = true; return true }
        if first { progressed.signal(); _ = release.wait(timeout: .now() + 5) }
    }, onFailure: { faults.withLock { $0 += 1 } })
    let first = Task { try await writer.send(Data("first\n".utf8), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await waitForWriteSignal(progressed, then: { first.cancel(); release.signal() }))
    await #expect(throws: CancellationError.self) { try await first.value }
    try await writer.send(Data("second\n".utf8), deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {})
    #expect(faults.withLock { $0 } == 0)
    #expect(await writer.snapshot().closed == false)
    await writer.close()
    #expect(pipe.fileHandleForReading.availableData == Data("first\nsecond\n".utf8))
}

private final class ScriptedWriteSink: StdioPipeSink {
    private struct State { var calls = 0; var bytes = Data(); var closed = false }
    private let state = Mutex(State())
    func attempt(_ data: Data, offset: Int) throws -> StdioPipeEndpoint.Attempt {
        try state.withLock { value in
            guard !value.closed else { throw StdioPipeError.closed }
            value.calls += 1
            if value.calls == 1 { return .interrupted }
            if value.calls == 3 { return .wouldBlock }
            let count = min(2, data.count - offset)
            value.bytes.append(data[offset..<(offset + count)])
            return .progress(count)
        }
    }
    func close() { state.withLock { $0.closed = true } }
    var bytes: Data { state.withLock { $0.bytes } }
}

@Test("short writes EINTR and EAGAIN preserve offsets and FIFO framing")
func stdioWriteShortProgressAndRetries() async throws {
    let sink = ScriptedWriteSink(), writer = StdioPipeWriter(endpoint: sink)
    try await writer.send(Data("abcdef\n".utf8), deadline: .now.advanced(by: .seconds(2)), timeoutError: writeTimeout(), admit: {})
    try await writer.send(Data("ghij\n".utf8), deadline: .now.advanced(by: .seconds(2)), timeoutError: writeTimeout(), admit: {})
    await writer.close()
    #expect(sink.bytes == Data("abcdef\nghij\n".utf8))
    #expect(await writer.snapshot().bytes == 0)
}

@Test("concurrently queued large frames retain FIFO order without interleaving")
func stdioWriteConcurrentFramesStayWhole() async throws {
    let pipe = Pipe(), endpoint = try StdioPipeEndpoint(taking: pipe.fileHandleForWriting)
    let padding = try fillWritePipe(endpoint)
    let writer = StdioPipeWriter(endpoint: endpoint)
    let a = Data(repeating: 0x41, count: 96 * 1024) + Data([0x0A])
    let b = Data(repeating: 0x42, count: 96 * 1024) + Data([0x0A])
    let c = Data(repeating: 0x43, count: 96 * 1024) + Data([0x0A])
    let first = Task { try await writer.send(a, deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 1))
    let second = Task { try await writer.send(b, deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 2))
    let third = Task { try await writer.send(c, deadline: .now.advanced(by: .seconds(3)), timeoutError: writeTimeout(3), admit: {}) }
    #expect(await writerState(writer, frames: 3))
    let read = Task.detached { () throws -> Data in
        try drainWritePadding(pipe.fileHandleForReading, count: padding)
        return try pipe.fileHandleForReading.readToEnd() ?? Data()
    }
    try await first.value; try await second.value; try await third.value
    await writer.close()
    #expect(try await read.value == a + b + c)
}

@Test("pre-cancelled and already expired writes cannot enter the FIFO or touch its sink")
func stdioWriteAdmissionBeforeEnqueue() async throws {
    let sink = ScriptedWriteSink(), writer = StdioPipeWriter(endpoint: sink)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let cancelled = Task {
        entered.signal()
        _ = await waitForWriteSignal(release)
        try await writer.send(Data("forbidden\n".utf8), deadline: .now.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: {})
    }
    #expect(await waitForWriteSignal(entered))
    cancelled.cancel(); release.signal()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    do { try await writer.send(Data("expired\n".utf8), deadline: .now.advanced(by: .seconds(-1)), timeoutError: writeTimeout(1), admit: {}); Issue.record("already expired write succeeded") }
    catch { guard case StdioTransport.TransportError.timedOut = error else { Issue.record("wrong admission timeout"); await writer.close(); return } }
    #expect(await writer.snapshot().frames == 0)
    #expect(sink.bytes.isEmpty)
    await writer.close()
}

@Test("writer admission at natural EOF preserves a previously cached owner's reply")
func stdioWriteEOFDoesNotEraseCachedReply() async throws {
    let output = Pipe(), errors = Pipe()
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading, replyRouting: true)
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let owner = try reader.registerReply(id: .int(7), deadline: Date().addingTimeInterval(2))
    defer { reader.unregisterReply(owner) }
    let frame = try RPCWireObject.encode(id: .int(7), fields: ["jsonrpc": .string("2.0"), "result": .string("cached")]) + Data([0x0A])
    reader.consumeStdout { frame }; reader.consumeStdout { Data() }
    let sink = ScriptedWriteSink(), faults = Mutex(0)
    let writer = StdioPipeWriter(endpoint: sink, onFailure: { faults.withLock { $0 += 1 }; reader.failOutbound() })
    await #expect(throws: StdioTransport.TransportError.self) {
        try await writer.send(Data("blocked\n".utf8), deadline: .now.advanced(by: .seconds(1)), timeoutError: writeTimeout(1), admit: { try reader.requireHealthy() })
    }
    #expect(try await reader.nextReply(owner)?.fields["result"] == .string("cached"))
    #expect(sink.bytes.isEmpty)
    #expect(faults.withLock { $0 } == 0)
    #expect(await writer.snapshot().closed)
}

@Test("concurrent transport shutdowns all finish after closing its owned stdin")
func stdioWriteConcurrentShutdownJoinsClose() async throws {
    let input = Pipe(), output = Pipe(), errors = Pipe()
    let encoded = DispatchSemaphore(value: 0)
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading, replyRouting: true)
    let transport = try StdioTransport(process: Process(), input: input, reader: reader, encodeFrame: {
        let frame = try RPCWireObject.encode(id: $0, fields: $1); encoded.signal(); return frame
    })
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let pending = Task { try await transport.request("blocked", timeout: 3) }
    #expect(await waitForWriteSignal(encoded))
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { await transport.shutdown() } }
    }
    await #expect(throws: StdioTransport.TransportError.self) { try await pending.value }
    await #expect(throws: StdioTransport.TransportError.self) { try await transport.notify("after-close") }
    let bytes = try input.fileHandleForReading.readToEnd() ?? Data()
    #expect(bytes.isEmpty || bytes.last == 0x0A)
    #expect(input.fileHandleForReading.availableData.isEmpty)
}
