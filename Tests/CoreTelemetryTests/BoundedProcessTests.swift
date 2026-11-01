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
