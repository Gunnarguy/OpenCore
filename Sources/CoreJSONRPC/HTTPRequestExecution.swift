import Foundation
import Synchronization

struct HTTPTransferResult: Sendable {
    let envelope: JSONValue?
    let statusCode: Int
    let sessionID: String?
}

/// One completion winner across headers, body, timeout and caller cancellation. URLSession
/// cancellation acknowledgement is asynchronous; a late worker cannot publish another result.
final class HTTPRequestExecution: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct State {
        var started = false
        var result: Result<HTTPTransferResult, any Error>?
        var continuation: CheckedContinuation<HTTPTransferResult, any Error>?
        var task: URLSessionTask?
        var worker: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let method: String
    private let seconds: TimeInterval
    private let deadline: ContinuousClock.Instant

    init(method: String, timeout: TimeInterval) throws {
        // Chosen one-day API ceiling, not a measured peer limit; also keeps Duration conversion safe.
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else {
            throw HTTPTransportError.malformed("timeout must be finite, positive and at most one day")
        }
        self.method = method
        seconds = timeout
        deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        super.init()
    }

    func value(operation: @escaping @Sendable (HTTPRequestExecution) async throws -> HTTPTransferResult) async throws -> HTTPTransferResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let existing: Result<HTTPTransferResult, any Error>? = state.withLock { value in
                    guard !value.started else {
                        return .failure(HTTPTransportError.malformed("request execution was already used"))
                    }
                    value.started = true
                    if let result = value.result { return result }
                    value.continuation = continuation
                    return nil
                }
                if let existing { continuation.resume(with: existing); return }
                let watchdog = Task { [self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    complete(.failure(HTTPTransportError.timedOut(method: method, seconds: seconds)))
                }
                let worker = Task { [self] in
                    do {
                        try Task.checkCancellation()
                        guard !isFinished else { return }
                        complete(.success(try await operation(self)))
                    } catch { complete(.failure(error)) }
                }
                let finished = state.withLock { value in
                    guard value.result == nil else { return true }
                    value.worker = worker
                    value.watchdog = watchdog
                    return false
                }
                if finished { worker.cancel(); watchdog.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { complete(.failure(CancellationError())) }

    private var isFinished: Bool { state.withLock { $0.result != nil } }

    /// Synchronous first callback, before task creation returns/resume. An actor hop here
    /// would lose cancellation while waiting for headers.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { register(task) }

    func register(_ task: URLSessionTask) {
        let finished = state.withLock { value in
            guard value.result == nil else { return true }
            value.task = task
            return false
        }
        if finished { task.cancel() }
    }

    private func complete(_ proposed: Result<HTTPTransferResult, any Error>) {
        let resources = state.withLock { value -> (
            CheckedContinuation<HTTPTransferResult, any Error>?, Result<HTTPTransferResult, any Error>,
            URLSessionTask?, Task<Void, Never>?, Task<Void, Never>?
        )? in
            guard value.result == nil else { return nil }
            let result: Result<HTTPTransferResult, any Error>
            if case .failure(is CancellationError) = proposed { result = proposed }
            else if ContinuousClock.now >= deadline {
                result = .failure(HTTPTransportError.timedOut(method: method, seconds: seconds))
            } else { result = proposed }
            value.result = result
            let owned = (value.continuation, result, value.task, value.worker, value.watchdog)
            value.continuation = nil
            value.task = nil
            value.worker = nil
            value.watchdog = nil
            return owned
        }
        guard let (continuation, result, task, worker, watchdog) = resources else { return }
        // Never invoke cancellation handlers under the mutex or wait for their acknowledgement.
        continuation?.resume(with: result)
        task?.cancel()
        worker?.cancel()
        watchdog?.cancel()
    }
}
