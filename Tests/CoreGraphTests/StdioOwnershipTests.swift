import Foundation
import Synchronization
import Testing
@testable import CoreJSONRPC

private func stdioPeerReady(_ transport: StdioTransport, marker: String) async -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(3)) // Chosen fixture readiness bound.
    while ContinuousClock.now < end {
        if await transport.stderrOutput().contains(marker) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

// The bug: independent reentrant waiters consume a shared FIFO and discard replies
// with another call's ID. This peer waits for both requests, then answers in reverse order.
@Test("concurrent stdio calls retain ownership when replies arrive in reverse order")
func stdioConcurrentRepliesKeepOwnership() async throws {
    let script = #"""
    IFS= read -r first
    printf 'first-read\n' >&2
    IFS= read -r second
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":"second"}' '{"jsonrpc":"2.0","id":1,"result":"first"}'
    IFS= read -r finish
    """#
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"])
    let first = Task { try await transport.request("first", timeout: 1) }
    #expect(await stdioPeerReady(transport, marker: "first-read"))
    let second = Task { try await transport.request("second", timeout: 1) }
    do { #expect(try await first.value == .string("first")) }
    catch { Issue.record("first call lost ownership: \(error)") }
    do { #expect(try await second.value == .string("second")) }
    catch { Issue.record("second call lost ownership: \(error)") }
    await transport.shutdown()
}

private func ownershipTime(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
private func ownershipWait(_ semaphore: DispatchSemaphore, then action: @escaping @Sendable () -> Void = {}) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let entered = semaphore.wait(timeout: .now() + 3) == .success
            action() // Fault and release on this queue even while Swift executor threads are occupied.
            continuation.resume(returning: entered)
        }
    }
}
private func ownershipConsume(_ reader: StdioLineReader, _ data: Data) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: reader.consumeStdout { data })
        }
    }
}
private func ownershipFrame(_ id: Int, _ value: String) throws -> (Data, RPCWireObject) {
    let data = try RPCWireObject.encode(id: .int(id), fields: ["jsonrpc": .string("2.0"), "result": .string(value)])
    return (data, try RPCWireObject.decode(data))
}

// A short waiter's expiry must never make it discard another owner's on-time reply.
@Test("stdio reply eligibility belongs to each registered owner")
func stdioInboxOwnerDeadlines() throws {
    var inbox = StdioReplyInbox()
    let a = try inbox.register(id: .int(1), receiptFloor: 0, deadline: ownershipTime(1))
    let b = try inbox.register(id: .int(2), receiptFloor: 0, deadline: ownershipTime(10))
    let first = try ownershipFrame(1, "late"), second = try ownershipFrame(2, "on-time")
    try inbox.receive(second.1, receipt: 0, receivedAt: ownershipTime(2), byteCount: second.0.count)
    try inbox.receive(first.1, receipt: 0, receivedAt: ownershipTime(2), byteCount: first.0.count)
    #expect(inbox.take(a) == nil)
    #expect(inbox.take(b)?.fields["result"] == .string("on-time"))
    #expect(inbox.bufferedBytes == 0)
}

@Test("stdio replies retain ownership until take and cannot be replaced by duplicates")
func stdioInboxFirstReplyAndAccounting() throws {
    var inbox = StdioReplyInbox()
    let registration = try inbox.register(id: .int(1), receiptFloor: 3, deadline: ownershipTime(10))
    let first = try ownershipFrame(1, "first"), duplicate = try ownershipFrame(1, "duplicate")
    try inbox.receive(first.1, receipt: 2, receivedAt: ownershipTime(1), byteCount: first.0.count)
    #expect(inbox.bufferedBytes == 0, "already-appended frames cannot preseed a new owner")
    try inbox.receive(first.1, receipt: 3, receivedAt: ownershipTime(1), byteCount: first.0.count)
    try inbox.receive(duplicate.1, receipt: 3, receivedAt: ownershipTime(1), byteCount: duplicate.0.count)
    #expect(inbox.bufferedBytes == first.0.count)
    #expect(inbox.take(registration)?.fields["result"] == .string("first"))
    try inbox.receive(duplicate.1, receipt: 4, receivedAt: ownershipTime(2), byteCount: duplicate.0.count)
    #expect(inbox.take(registration) == nil)
    #expect(inbox.bufferedBytes == 0)
}

@Test("withdrawn stdio registrations cannot consume or clear a later owner's reply")
func stdioInboxRegistrationIdentity() throws {
    var inbox = StdioReplyInbox()
    let old = try inbox.register(id: .int(1), receiptFloor: 0, deadline: ownershipTime(10))
    let frame = try ownershipFrame(1, "old")
    try inbox.receive(frame.1, receipt: 0, receivedAt: ownershipTime(1), byteCount: frame.0.count)
    inbox.unregister(old)
    #expect(inbox.bufferedBytes == 0)
    let current = try inbox.register(id: .int(1), receiptFloor: 1, deadline: ownershipTime(10))
    try inbox.receive(frame.1, receipt: 0, receivedAt: ownershipTime(1), byteCount: frame.0.count)
    #expect(inbox.take(current) == nil)
    let new = try ownershipFrame(1, "new")
    try inbox.receive(new.1, receipt: 1, receivedAt: ownershipTime(2), byteCount: new.0.count)
    inbox.unregister(old)
    #expect(inbox.take(old) == nil)
    #expect(inbox.take(current)?.fields["result"] == .string("new"))
}

@Test("stdio inbox limits bound retained reply bytes and registration metadata")
func stdioInboxBudgets() throws {
    let frame = try ownershipFrame(1, "fixture")
    var inbox = StdioReplyInbox(maximumRequests: 2, maximumBytes: frame.0.count - 1)
    let a = try inbox.register(id: .int(1), receiptFloor: 0, deadline: ownershipTime(10))
    _ = try inbox.register(id: .int(2), receiptFloor: 0, deadline: ownershipTime(10))
    #expect(throws: StdioTransport.TransportError.self) { try inbox.register(id: .int(3), receiptFloor: 0, deadline: ownershipTime(10)) }
    #expect(throws: StdioTransport.TransportError.self) { try inbox.receive(frame.1, receipt: 0, receivedAt: ownershipTime(1), byteCount: frame.0.count) }
    #expect(inbox.bufferedBytes == 0)
    inbox.unregister(a)
    let c = try inbox.register(id: .int(3), receiptFloor: 1, deadline: ownershipTime(10))
    let tiny = try ownershipFrame(3, "")
    try inbox.receive(tiny.1, receipt: 1, receivedAt: ownershipTime(1), byteCount: tiny.0.count)
    #expect(inbox.bufferedBytes > 0)
    inbox.clear()
    #expect(inbox.bufferedBytes == 0)
    #expect(!inbox.isRegistered(c))
}

private final class OwnershipClock: Sendable {
    let time = Mutex(ownershipTime(0))
    func now() -> Date { time.withLock { $0 } }
    func set(_ value: Double) { time.withLock { $0 = ownershipTime(value) } }
}

private func ownershipReader(clock: OwnershipClock, parse: @escaping @Sendable (Data) throws -> RPCWireObject = { try RPCWireObject.decode($0) }) -> (StdioLineReader, Pipe, Pipe) {
    let output = Pipe(), errors = Pipe()
    return (StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading,
        clock: { clock.now() }, replyRouting: true, parseFrame: parse), output, errors)
}

// Stamping B only after slow A parsing would accept a prebuffered future reply or drop an
// on-time response. One explicit consumeStdout call makes this exactly one received chunk.
@Test("a received stdio chunk keeps its timestamp and registration boundary across slow parsing", arguments: [false, true])
func stdioReceiptStampedBeforeParsing(registerBLater: Bool) async throws {
    let clock = OwnershipClock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let inspected = DispatchSemaphore(value: 0)
    let (reader, output, errors) = ownershipReader(clock: clock) { data in
        let wire = try RPCWireObject.decode(data)
        if wire.id == .int(1) { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return wire
    }
    defer { release.signal(); reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let a = try reader.registerReply(id: .int(1), deadline: ownershipTime(10))
    var b = registerBLater ? nil : try reader.registerReply(id: .int(2), deadline: ownershipTime(1))
    let chunk = try ownershipFrame(1, "a").0 + Data([0x0A]) + ownershipFrame(2, "b").0 + Data([0x0A])
    let callback = Task { await ownershipConsume(reader, chunk) }
    #expect(await ownershipWait(entered))
    if registerBLater {
        let start = ContinuousClock.now
        b = try reader.registerReply(id: .int(2), deadline: ownershipTime(10))
        #expect(start.duration(to: .now) < .seconds(2), "paused parsing must not hold the registry mutex")
    }
    let registration = try #require(b)
    clock.set(2)
    let waiting = Task { try await reader.nextReply(registration, onPending: { inspected.signal() }) }
    // Prove the waiter observed the pending on-time chunk with an expired clock before
    // releasing parsing; task creation or a scheduling delay alone cannot establish that.
    #expect(await ownershipWait(inspected))
    release.signal()
    _ = await callback.value
    if registerBLater { clock.set(11) } // End the new owner's wait only after old B was processed.
    let reply = try await waiting.value
    if registerBLater { #expect(reply == nil, "a later registration cannot claim the prebuffered B frame") }
    else { #expect(reply?.fields["result"] == .string("b"), "already-received data remains eligible after expiry") }
    #expect(try await reader.nextReply(a)?.fields["result"] == .string("a"))
}

@Test("cancelled stdio parsing cannot publish into a replacement registration")
func stdioCancelledParseCannotReviveOwner() async throws {
    let clock = OwnershipClock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let calls = Mutex(0)
    let (reader, output, errors) = ownershipReader(clock: clock) { data in
        let first = calls.withLock { value in value += 1; return value == 1 }
        if first { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return try RPCWireObject.decode(data)
    }
    defer { release.signal(); reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let old = try reader.registerReply(id: .int(1), deadline: ownershipTime(10))
    let oldBytes = try ownershipFrame(1, "old").0 + Data([0x0A])
    let callback = Task { await ownershipConsume(reader, oldBytes) }
    #expect(await ownershipWait(entered))
    reader.unregisterReply(old)
    let current = try reader.registerReply(id: .int(1), deadline: ownershipTime(10))
    release.signal(); _ = await callback.value
    let fresh = try ownershipFrame(1, "new").0 + Data([0x0A])
    reader.consumeStdout { fresh }
    #expect(try await reader.nextReply(current)?.fields["result"] == .string("new"))
    await #expect(throws: CancellationError.self) { _ = try await reader.nextReply(old) }
}

@Test("stdio stop cannot publish a frame that was still parsing")
func stdioStopFencesParsing() async throws {
    let clock = OwnershipClock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let (reader, output, errors) = ownershipReader(clock: clock) { data in
        entered.signal(); _ = release.wait(timeout: .now() + 5)
        return try RPCWireObject.decode(data)
    }
    defer { release.signal(); reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let owner = try reader.registerReply(id: .int(1), deadline: ownershipTime(10))
    let frame = try ownershipFrame(1, "late-after-stop").0 + Data([0x0A])
    let callback = Task { await ownershipConsume(reader, frame) }
    #expect(await ownershipWait(entered))
    reader.stop(); release.signal(); _ = await callback.value
    do { _ = try await reader.nextReply(owner); Issue.record("stop published a parsing frame") }
    catch { guard case StdioTransport.TransportError.closed = error else { Issue.record("wrong stop error"); return } }
}

@Test("routed stdio replies survive natural EOF and an expired waiter clock")
func stdioRoutedEOFKeepsEligibleReply() async throws {
    let clock = OwnershipClock(), (reader, output, errors) = ownershipReader(clock: clock)
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let owner = try reader.registerReply(id: .int(1), deadline: ownershipTime(1))
    let frame = try ownershipFrame(1, "on-time").0 + Data([0x0A])
    reader.consumeStdout { frame }; reader.consumeStdout { Data() }
    clock.set(2)
    #expect(try await reader.nextReply(owner)?.fields["result"] == .string("on-time"))
}

@Test("a precancelled routed stdio waiter leaves an eligible reply untouched")
func stdioCancelledRoutedWaiterLeavesReply() async throws {
    let clock = OwnershipClock(), (reader, output, errors) = ownershipReader(clock: clock)
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let owner = try reader.registerReply(id: .int(1), deadline: ownershipTime(1))
    let frame = try ownershipFrame(1, "on-time").0 + Data([0x0A])
    reader.consumeStdout { frame }
    let gate = AsyncStream<Void>.makeStream()
    let work = Task {
        for await _ in gate.stream { }
        return try await reader.nextReply(owner)
    }
    work.cancel(); gate.continuation.finish()
    await #expect(throws: CancellationError.self) { _ = try await work.value }
    clock.set(2)
    #expect(try await reader.nextReply(owner)?.fields["result"] == .string("on-time"))
}

@Test("stdio terminal backlog faults fail all owners and signal cleanup only once")
func stdioTerminalBacklogFailsAllOwners() async throws {
    let first = try ownershipFrame(1, "first"), second = try ownershipFrame(2, "second")
    let signals = Mutex(0), parses = Mutex(0)
    let output = Pipe(), errors = Pipe()
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading,
        clock: { ownershipTime(0) }, replyRouting: true,
        parseFrame: { data in parses.withLock { $0 += 1 }; return try RPCWireObject.decode(data) },
        inbox: .init(maximumBytes: first.0.count + second.0.count - 1),
        onTerminal: { signals.withLock { $0 += 1 } })
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let a = try reader.registerReply(id: .int(1), deadline: ownershipTime(10))
    let b = try reader.registerReply(id: .int(2), deadline: ownershipTime(10))
    let data = first.0 + Data([0x0A]) + second.0 + Data([0x0A])
    reader.consumeStdout { data }
    for owner in [a, b] {
        do { _ = try await reader.nextReply(owner); Issue.record("fatal backlog returned success") }
        catch { guard case StdioTransport.TransportError.backlogLimit = error else { Issue.record("lost terminal failure"); continue } }
    }
    #expect(throws: StdioTransport.TransportError.self) { try reader.requireHealthy() }
    #expect(throws: StdioTransport.TransportError.self) { try reader.registerReply(id: .int(3), deadline: ownershipTime(10)) }
    reader.consumeStdout { first.0 + Data([0x0A]) }
    #expect(signals.withLock { $0 } == 1)
    #expect(parses.withLock { $0 } == 2, "fatal streams drain without decoding or retaining further frames")
}

@Test("tiny generic stdio lines cannot allocate an unbounded frame queue")
func stdioTinyLineCountIsBounded() async throws {
    let output = Pipe(), errors = Pipe()
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    reader.consumeStdout { Data(String(repeating: "x\n", count: 1025).utf8) }
    do { _ = try await reader.nextLine(before: Date().addingTimeInterval(2)); Issue.record("tiny-line queue was unbounded") }
    catch { guard case StdioTransport.TransportError.backlogLimit = error else { Issue.record("wrong queue failure"); return } }
}

@Test("cancelling one stdio caller preserves another reply and rejects its later stale frame")
func stdioCallerCancellationIsLocal() async throws {
    let script = #"""
    IFS= read -r first
    printf 'first-read\n' >&2
    IFS= read -r second
    printf 'second-read\n' >&2
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":"second"}'
    IFS= read -r third
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":"stale"}' '{"jsonrpc":"2.0","id":3,"result":"third"}'
    IFS= read -r finish
    """#
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"])
    let first = Task { try await transport.request("first", timeout: 3) }
    #expect(await stdioPeerReady(transport, marker: "first-read"))
    let second = Task { try await transport.request("second", timeout: 3) }
    #expect(await stdioPeerReady(transport, marker: "second-read"))
    let start = ContinuousClock.now
    first.cancel()
    do { _ = try await first.value; Issue.record("cancelled caller succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(start.duration(to: .now) < .seconds(2))
    do {
        #expect(try await second.value == .string("second"))
        #expect(try await transport.request("third", timeout: 3) == .string("third"))
        await transport.shutdown()
    } catch { await transport.shutdown(); throw error }
}

@Test("stdio matched envelopes must be actual JSON-RPC responses", arguments: [
    #"{"jsonrpc":"1.0","id":1,"result":"bad"}"#,
    #"{"jsonrpc":"2.0","id":1,"result":"bad","error":{"code":-1,"message":"bad"}}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"server/request"}"#,
    #"{"jsonrpc":"2.0","id":1,"error":{"code":"bad","message":"bad"}}"#,
    #"{"jsonrpc":"2.0","id":1}"#
])
func stdioRejectsMalformedMatchedReply(reply: String) async throws {
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c",
        #"IFS= read -r request; printf '%s\n' "$1"; IFS= read -r finish"#, "fixture", reply], environment: ["PATH": "/usr/bin:/bin"])
    do { _ = try await transport.request("fixture", timeout: 2); await transport.shutdown(); Issue.record("malformed matched reply succeeded") }
    catch { await transport.shutdown(); guard case StdioTransport.TransportError.malformed = error else { Issue.record("wrong malformed-response failure: \(error)"); return } }
}

@Test("invalid timeouts precancelled callers and closed stdio transports never write")
func stdioInvalidCancelledAndClosedCalls() async throws {
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c", #"IFS= read -r request; printf 'unexpected-read\n' >&2"#], environment: ["PATH": "/usr/bin:/bin"])
    for timeout in [0, -1, Double.nan, Double.infinity, 86_401] {
        do { _ = try await transport.request("fixture", timeout: timeout); Issue.record("invalid timeout accepted") }
        catch { guard case StdioTransport.TransportError.malformed = error else { Issue.record("wrong invalid-timeout error"); continue } }
    }
    let gate = AsyncStream<Void>.makeStream()
    let cancelled = Task {
        for await _ in gate.stream { }
        return try await transport.request("fixture", timeout: 2)
    }
    cancelled.cancel(); gate.continuation.finish()
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await transport.stderrOutput().isEmpty)
    await transport.shutdown(); await transport.shutdown()
    await #expect(throws: StdioTransport.TransportError.self) { _ = try await transport.request("fixture", timeout: 2) }
    await #expect(throws: StdioTransport.TransportError.self) { try await transport.notify("fixture") }
}

@Test("an outgoing stdio encoding refusal leaves other request owners usable")
func stdioEncodingFailureIsLocal() async throws {
    let script = #"""
    IFS= read -r first
    printf 'first-read\n' >&2
    IFS= read -r third
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":"third"}' '{"jsonrpc":"2.0","id":1,"result":"first"}'
    IFS= read -r finish
    """#
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"])
    let first = Task { try await transport.request("first", timeout: 5) }
    #expect(await stdioPeerReady(transport, marker: "first-read"))
    do {
        _ = try await transport.request("too-large", params: .object(["fixture": .string(String(repeating: "x", count: RPCWireObject.maximumBytes))]), timeout: 2)
        Issue.record("oversized outgoing message was written")
    } catch { guard case StdioTransport.TransportError.malformed = error else { await transport.shutdown(); Issue.record("encoding refusal became stream failure"); return } }
    do {
        #expect(try await transport.request("third", timeout: 3) == .string("third"))
        #expect(try await first.value == .string("first"))
        await transport.shutdown()
    } catch { await transport.shutdown(); throw error }
}

// The bug: a call admitted before slow encoding could still start native I/O after cancellation
// or a terminal callback. A post-encoding admission check must observe both before sending bytes.
@Test("stdio rechecks cancellation and terminal state after encoding before native write", arguments: [false, true])
func stdioEncodingRechecksWriteAdmission(cancel: Bool) async throws {
    let input = Pipe(), output = Pipe(), errors = Pipe()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading, replyRouting: true)
    let transport = try StdioTransport(process: Process(), input: input, reader: reader, encodeFrame: { id, fields in
        entered.signal(); _ = release.wait(timeout: .now() + 5)
        return try RPCWireObject.encode(id: id, fields: fields)
    })
    defer { release.signal(); reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let work = Task { try await transport.request("fixture", timeout: 2) }
    #expect(await ownershipWait(entered, then: {
        if cancel { work.cancel() } else { reader.consumeStdout { Data() } }
        release.signal()
    }))
    do { _ = try await work.value; Issue.record("unadmitted write succeeded") }
    catch {
        if cancel { #expect(error is CancellationError) }
        else { guard case StdioTransport.TransportError.closed = error else { Issue.record("wrong terminal admission error"); await transport.shutdown(); return } }
    }
    await transport.shutdown()
    // Writer is now closed by its owner, so EOF makes this fixture read finite.
    let bytes = input.fileHandleForReading.availableData
    #expect(bytes.isEmpty, "cancellation/terminal observed before admission must send no bytes")
}
