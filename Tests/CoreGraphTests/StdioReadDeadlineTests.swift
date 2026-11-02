import Foundation
import Synchronization
import Testing
@testable import CoreJSONRPC

private final class ReadClock: Sendable {
    private let value: Mutex<Date>
    init(_ seconds: TimeInterval) { value = Mutex(Date(timeIntervalSince1970: seconds)) }
    func now() -> Date { value.withLock { $0 } }
    func set(_ seconds: TimeInterval) { value.withLock { $0 = Date(timeIntervalSince1970: seconds) } }
}
private func instant(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

// The fake clock can stop during a deliberately broken mutation. Bound every fixture wait
// independently so an expected regression reports a test failure instead of hanging the runner.
private func boundedLine(_ reader: StdioLineReader, before deadline: Date) async throws -> String? {
    let work = Task { try await reader.nextLine(before: deadline) }
    let limit = Task { do { try await Task.sleep(for: .seconds(5)); work.cancel() } catch { } }
    defer { limit.cancel() }
    return try await work.value
}

// Write both lines atomically; observing the first establishes the second is already buffered,
// without relying on a sleep to make a FileHandle callback win a scheduling race.
private func bufferedReply(at receivedAt: TimeInterval = 0) async throws -> (StdioLineReader, Pipe, Pipe, ReadClock) {
    let output = Pipe(), errors = Pipe(), clock = ReadClock(receivedAt)
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading, clock: { clock.now() })
    output.fileHandleForWriting.write(Data("ready\nreply\n".utf8))
    #expect(try await boundedLine(reader, before: instant(receivedAt + 5)) == "ready")
    return (reader, output, errors, clock)
}

// The bug: the reader checked its wall-clock deadline before looking at buffered lines.
// Executor delay could therefore discard a reply that had already arrived and report exit/timeout.
@Test("an on-time stdio reply survives a waiter resuming after its deadline")
func stdioBufferedReplySurvivesDeadline() async throws {
    let (reader, output, errors, clock) = try await bufferedReply()
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    clock.set(2)
    #expect(try await boundedLine(reader, before: instant(1)) == "reply")
    #expect(try await boundedLine(reader, before: instant(1)) == nil)
}

// Independent guard: consuming a buffered result must still honor caller cancellation. Previously
// cancellation was only observed by Task.sleep, which a buffered result bypassed entirely.
@Test("a cancelled stdio waiter cannot consume a buffered reply")
func stdioCancelledWaiterRejectsBufferedReply() async throws {
    let (reader, output, errors, clock) = try await bufferedReply()
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let gate = AsyncStream<Void>.makeStream()
    let task = Task {
        for await _ in gate.stream { }
        return try await reader.nextLine(before: instant(5))
    }
    task.cancel()
    gate.continuation.finish()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    clock.set(2)
    #expect(try await boundedLine(reader, before: instant(1)) == "reply", "a cancelled waiter leaves the reply untouched")
}

// The first repair consumed any queued line before checking expiry. A chatty peer could then
// keep a request alive forever with notifications. Only lines received by its deadline qualify.
@Test("late stdio lines cannot keep an expired request alive")
func stdioLateBacklogCannotExtendDeadline() async throws {
    let (reader, output, errors, clock) = try await bufferedReply(at: 2)
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    clock.set(4)
    #expect(try await boundedLine(reader, before: instant(1)) == nil)
    #expect(try await boundedLine(reader, before: instant(5)) == "reply", "a later request can still drain its eligible backlog")
}

@Test("stdio closure preserves eligible buffered lines before returning end of stream")
func stdioClosurePreservesBufferedReply() async throws {
    let (reader, output, errors, clock) = try await bufferedReply()
    defer { try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    reader.stop()
    clock.set(2)
    #expect(try await boundedLine(reader, before: instant(1)) == "reply")
    #expect(try await boundedLine(reader, before: instant(1)) == nil)
}

private func exerciseOverlappingCallbacks(_ reader: StdioLineReader, eof: Bool) -> Bool {
    let readingFirst = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0), secondFinished = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    finished.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        reader.consumeStdout {
            readingFirst.signal()
            _ = releaseFirst.wait(timeout: .now() + 5) // Chosen fixture escape hatch.
            return Data((eof ? "reply\n" : "first").utf8)
        }
        finished.leave()
    }
    let beganFirst = readingFirst.wait(timeout: .now() + 5) == .success
    finished.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        secondStarted.signal()
        reader.consumeStdout { eof ? Data() : Data("second\n".utf8) }
        secondFinished.signal()
        finished.leave()
    }
    let beganSecond = secondStarted.wait(timeout: .now() + 5) == .success
    // A broken concurrent read gets a chance to overtake the paused first read. Correct code
    // keeps it pending. This allowance sets up the race; it is not a production latency claim.
    _ = secondFinished.wait(timeout: .now() + 1)
    releaseFirst.signal()
    let joined = finished.wait(timeout: .now() + 5) == .success
    return beganFirst && beganSecond && joined
}

// The bug: a callback could read bytes, pause, then lose them when another callback published
// EOF first; concurrent nonempty reads could also append in reverse order. Neither outcome may
// depend on FileHandle callback serialization that the API does not promise.
@Test("overlapping stdio callbacks preserve byte order before EOF or the next chunk", arguments: [true, false])
func stdioReadsAndEOFAreOrdered(eof: Bool) async throws {
    let output = Pipe(), errors = Pipe()
    let reader = StdioLineReader(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
    defer { reader.stop(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    let established = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: exerciseOverlappingCallbacks(reader, eof: eof))
        }
    }
    #expect(established, "synthetic callback interleaving must complete")
    #expect(try await boundedLine(reader, before: Date().addingTimeInterval(5)) == (eof ? "reply" : "firstsecond"))
}
