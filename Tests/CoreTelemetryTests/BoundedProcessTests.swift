import CoreTelemetry
import Foundation
import Testing

// Original bug: fm and other CLI adapters drained stdout alone; enough stderr filled its
// pipe and stalled the app forever. Every child also lacked a wall-clock deadline.
@Test("a child writing more than a pipe buffer to stderr still completes with bounded retained output")
func subprocessDrainsBothStreams() throws {
    let result = try BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 >&2 2>/dev/null; printf done"], timeout: 5, maximumOutputBytes: 1024)
    #expect(!result.timedOut); #expect(result.status == 0)
    #expect(result.stdoutText == "done"); #expect(result.stderr.count <= 1024)
}

@Test("a stalled child is stopped after its deadline")
func subprocessHasDeadline() throws {
    let started = Date()
    let result = try BoundedProcess.run(executable: "/bin/sleep", arguments: ["20"], timeout: 0.1)
    #expect(result.timedOut); #expect(Date().timeIntervalSince(started) < 4)
}

// Original bug: canceling a chat did not reach its CLI producer, so the child kept running.
@Test("canceling a subprocess task terminates its child before the normal timeout")
func subprocessRespondsToCancellation() async throws {
    let started = Date()
    let worker = Task.detached {
        try BoundedProcess.run(executable: "/bin/sleep", arguments: ["20"], timeout: 15)
    }
    try await Task.sleep(for: .milliseconds(50))
    worker.cancel()
    do { _ = try await worker.value; Issue.record("canceled process returned success") }
    catch is CancellationError { }
    #expect(Date().timeIntervalSince(started) < 4)
}

// The bug: a successful parent could exit before its inherited pipe writer or a queued drain.
// A fixed one-second wait then returned status 0 and empty/truncated output as a complete reply.
@Test("successful subprocess output is complete even when its final writer closes later")
func subprocessWaitsForCompleteOutput() throws {
    let result = try BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 1.3; printf late; printf diagnostic >&2) & exit 0"], timeout: 5, maximumOutputBytes: 1024)
    #expect(result.status == 0)
    #expect(!result.timedOut)
    #expect(result.stdoutText == "late")
    #expect(result.stderrText == "diagnostic")
}

@Test("an unfinished subprocess pipe is a timeout even after a successful parent exit")
func subprocessIncompleteOutputIsTimeout() throws {
    let result = try BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 2; printf late) & exit 0"], timeout: 1, maximumOutputBytes: 1024)
    #expect(result.status == 0)
    #expect(result.timedOut)
}

// Separate guard: the direct child can already be gone when cancellation arrives. Waiting
// the entire remaining pipe deadline here would defer a cancellation for minutes in Notes.
@Test("cancelling after a subprocess exits interrupts its pending output drain")
func subprocessCancellationInterruptsDrain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("process-drain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ready = directory.appendingPathComponent("ready")
    let worker = Task.detached {
        try BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 2; printf late) & printf ready > \"$1\"", "fixture", ready.path], timeout: 15)
    }
    let readyDeadline = Date().addingTimeInterval(5) // Chosen fixture startup allowance.
    while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard FileManager.default.fileExists(atPath: ready.path) else {
        worker.cancel(); _ = try? await worker.value
        Issue.record("synthetic parent never signalled readiness"); return
    }
    try await Task.sleep(for: .milliseconds(50))
    let cancelledAt = Date()
    worker.cancel()
    await #expect(throws: CancellationError.self) { _ = try await worker.value }
    #expect(Date().timeIntervalSince(cancelledAt) < 1, "cancellation must not wait for the two-second writer")
}
