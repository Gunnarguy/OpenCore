import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Synchronous subprocess boundary for existing blocking CLI adapters. Both output streams are
/// drained independently, retained output is bounded, and a stalled child is terminated.
public enum BoundedProcess {
    private final class Buffer: Sendable {
        let data = Mutex(Data())
    }
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        public let timedOut: Bool
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 2_000_000
    ) throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        // The parent must not keep a writer alive after the child closes its copy.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let out = Buffer()
        let err = Buffer()
        let readers = DispatchGroup()
        let outputLimit = max(0, maximumOutputBytes)
        func drain(_ handle: FileHandle, into storage: Buffer) {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); readers.leave() }
                while let data = try? handle.read(upToCount: 65_536), !data.isEmpty {
                    storage.data.withLock { bytes in
                        let remaining = max(0, outputLimit - bytes.count)
                        bytes.append(data.prefix(remaining))
                    }
                }
            }
        }
        drain(output.fileHandleForReading, into: out)
        drain(errors.fileHandleForReading, into: err)
        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        var finished = false
        while !Task.isCancelled, Date() < deadline {
            if completed.wait(timeout: .now() + min(0.05, max(0.001, deadline.timeIntervalSinceNow))) == .success {
                finished = true
                break
            }
        }
        var timedOut = !finished && !Task.isCancelled
        if !finished {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        // A successful child can exit before its pipe readers run or inherited writers close.
        // The old fixed one-second grace returned status 0 with silently incomplete output.
        // Keep draining within the original overall budget and label an unfinished drain as
        // a timeout. Pipe-drain cleanup after termination uses at most one second and observes cancellation.
        let drainDeadline = finished ? deadline : min(deadline, Date().addingTimeInterval(1))
        var drained = readers.wait(timeout: .now()) == .success
        while !drained, !Task.isCancelled, Date() < drainDeadline {
            drained = readers.wait(timeout: .now() + min(0.05, max(0.001, drainDeadline.timeIntervalSinceNow))) == .success
        }
        if !drained { timedOut = true }
        try Task.checkCancellation()
        return Result(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: out.data.withLock { $0 },
            stderr: err.data.withLock { $0 },
            timedOut: timedOut
        )
    }
}
