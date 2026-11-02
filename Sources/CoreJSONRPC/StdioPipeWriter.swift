import Foundation
import Synchronization

private final class StdioWriteCancellation: Sendable {
    private let flag = Mutex(false)
    func cancel() { flag.withLock { $0 = true } }
    var cancelled: Bool { flag.withLock { $0 } }
}

/// Exactly one pump owns frame ordering. All continuation/accounting/close transitions are
/// actor-isolated; cancellation handlers only mark an atomic flag and request another turn.
actor StdioPipeWriter {
    private struct Job {
        let id: UUID
        let data: Data
        let deadline: ContinuousClock.Instant
        let timeoutError: StdioTransport.TransportError
        let cancellation: StdioWriteCancellation
        let continuation: CheckedContinuation<Void, any Error>
        let admit: @Sendable () throws -> Void
        var offset = 0
    }
    private let endpoint: any StdioPipeSink
    private let onFailure: @Sendable () -> Void
    private let onProgress: @Sendable (Int) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let maximumFrames: Int
    private let maximumBytes: Int
    private var queue: [Job] = []
    private var current: Job?
    private var retainedBytes = 0
    private var pump: Task<Void, Never>?
    private var closed = false

    // Chosen FIFO budgets/poll interval, not protocol maxima or measured latency guarantees.
    init(endpoint: any StdioPipeSink, maximumFrames: Int = 128, maximumBytes: Int = 16 * 1024 * 1024,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         onProgress: @escaping @Sendable (Int) -> Void = { _ in }, onFailure: @escaping @Sendable () -> Void = {}) {
        self.endpoint = endpoint; self.maximumFrames = maximumFrames; self.maximumBytes = maximumBytes
        self.onProgress = onProgress; self.onFailure = onFailure
        self.now = now
    }

    func send(_ data: Data, deadline: ContinuousClock.Instant, timeoutError: StdioTransport.TransportError,
              admit: @escaping @Sendable () throws -> Void) async throws {
        let cancellation = StdioWriteCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !closed else { continuation.resume(throwing: StdioPipeError.closed); return }
                guard !cancellation.cancelled else { continuation.resume(throwing: CancellationError()); return }
                guard now() < deadline else { continuation.resume(throwing: timeoutError); return }
                guard !data.isEmpty, queue.count + (current == nil ? 0 : 1) < maximumFrames,
                      data.count <= maximumBytes - retainedBytes else {
                    continuation.resume(throwing: StdioTransport.TransportError.writeQueueLimit); return
                }
                queue.append(Job(id: UUID(), data: data, deadline: deadline, timeoutError: timeoutError,
                    cancellation: cancellation, continuation: continuation, admit: admit))
                retainedBytes += data.count
                if pump == nil { pump = Task { await self.runPump() } }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancellationChanged() }
        }
    }

    func close() { closeAll(error: StdioPipeError.closed, notify: false) }
    func snapshot() -> (frames: Int, bytes: Int, closed: Bool) {
        (queue.count + (current == nil ? 0 : 1), retainedBytes, closed)
    }

    private func cancellationChanged() {
        pruneQueue()
        _ = finishInterruptedCurrent()
    }

    private func interruption(_ job: Job) -> (any Error)? {
        if job.cancellation.cancelled { return CancellationError() }
        if now() >= job.deadline { return job.timeoutError }
        return nil
    }

    private func pruneQueue() {
        var retained: [Job] = []
        for job in queue {
            if let error = interruption(job) {
                retainedBytes -= job.data.count; job.continuation.resume(throwing: error)
            } else { retained.append(job) }
        }
        queue = retained
    }

    /// Progress is applied before interruption is classified. A fully accepted frame keeps
    /// framing intact even when cancellation races its final byte; only an incomplete frame
    /// with accepted bytes makes the shared stream unusable.
    @discardableResult private func finishInterruptedCurrent() -> Bool {
        guard let job = current, let error = interruption(job) else { return false }
        if job.offset > 0, job.offset < job.data.count {
            finishCurrent(error)
            closeAll(error: StdioTransport.TransportError.writeFailed, notify: true)
        } else { finishCurrent(error) }
        return true
    }

    private func finishCurrent(_ error: (any Error)? = nil) {
        guard let job = current else { return }
        current = nil; retainedBytes -= job.data.count
        if let error { job.continuation.resume(throwing: error) } else { job.continuation.resume() }
    }

    private func closeAll(error: any Error, notify: Bool) {
        guard !closed else { return }
        closed = true
        endpoint.close()
        finishCurrent(error)
        let pending = queue; queue.removeAll()
        for job in pending { retainedBytes -= job.data.count; job.continuation.resume(throwing: error) }
        pump?.cancel()
        if notify { onFailure() }
    }

    private func runPump() async {
        defer { pump = nil }
        while !closed {
            pruneQueue() // A blocked head cannot delay other callers' own expiry/cancellation.
            if current == nil, !queue.isEmpty { current = queue.removeFirst() }
            guard let job = current else { return }
            if finishInterruptedCurrent() { continue }
            do { try job.admit() }
            catch {
                // Reader EOF/refusal already describes inbound state. Closing only the writer
                // preserves eligible replies previously cached by a naturally closed reader.
                closeAll(error: error, notify: false); return
            }
            if finishInterruptedCurrent() { continue }
            do {
                // No pointer or descriptor survives an await. endpoint serializes this one
                // nonblocking syscall with close, and obtains its owned handle afresh.
                switch try endpoint.attempt(job.data, offset: job.offset) {
                case .progress(let count):
                    guard current?.id == job.id else { return }
                    current!.offset += count
                    onProgress(current!.offset)
                    if !finishInterruptedCurrent(), current?.offset == job.data.count { finishCurrent() }
                    await Task.yield()
                case .wouldBlock, .interrupted:
                    if finishInterruptedCurrent() { continue }
                    pruneQueue()
                    do { try await Task.sleep(for: .milliseconds(5)) }
                    catch { if !closed { closeAll(error: StdioPipeError.closed, notify: false) }; return }
                }
            } catch { closeAll(error: StdioTransport.TransportError.writeFailed, notify: true); return }
        }
    }
}
