import Foundation
import Combine
import CoreTelemetry

/// BetterDisplay's documented local notification protocol. No HTTP listener, token or CLI install.
@MainActor
final class BetterDisplayClient: ObservableObject {
    static let shared = BetterDisplayClient()
    struct Reply: Decodable, Sendable { let uuid: String?; let result: Bool?; let payload: String? }
    private struct Request: Encodable { let uuid: String; let commands: [String]; let parameters: [String: String?] }
    private struct Pending {
        let continuation: CheckedContinuation<Reply, any Error>
        let timeout: Task<Void, Never>
        let isMutation: Bool
    }
    private var pending: [String: Pending] = [:]
    private var observer: NSObjectProtocol?
    @Published private var mutationGate = DisplayMutationGate()
    var isMutating: Bool { mutationGate.isBusy }
    var hasUncertainMutation: Bool { mutationGate.hasUnknownOutcome }

    func reserveMutation() throws -> UUID {
        guard let token = mutationGate.reserve() else { throw Self.failure("Wait for the current display change to finish.") }
        return token
    }

    func releaseMutation(_ token: UUID) { mutationGate.release(token) }
    private let center = DistributedNotificationCenter.default()

    private init() {
        observer = center.addObserver(forName: .init("pro.betterdisplay.BetterDisplay.response"), object: nil, queue: .main) { [weak self] notification in
            guard let text = notification.object as? String else { return }
            Task { @MainActor [weak self] in self?.receive(text) }
        }
    }

    func request(_ commands: [String], parameters: [String: String?], lease: UUID? = nil) async throws -> String {
        try Task.checkCancellation()
        let mutation = commands.contains { $0 != "get" && $0 != "help" }
        let operationLease: UUID?
        if mutation {
            if let lease {
                guard mutationGate.owns(lease) else { throw Self.failure("The display change reservation expired.") }
                operationLease = lease
            } else {
                operationLease = try reserveMutation()
            }
        } else { operationLease = nil }
        defer { if mutation && lease == nil, let operationLease { releaseMutation(operationLease) } }
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(Request(uuid: id, commands: commands, parameters: parameters))
        guard let object = String(data: data, encoding: .utf8) else { throw Self.failure("Could not encode the display request.") }
        let reply: Reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                // Chosen deadline, matching the companion CLI's bounded request behavior.
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.expire(id, cancelled: false)
                }
                if let operationLease, !mutationGate.posted(requestID: id, lease: operationLease) {
                    timeout.cancel()
                    continuation.resume(throwing: Self.failure("The display change reservation no longer permits this request."))
                    return
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout, isMutation: mutation)
                center.postNotificationName(.init("pro.betterdisplay.BetterDisplay.request"), object: object, userInfo: nil, deliverImmediately: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expire(id, cancelled: true) }
        }
        guard reply.result == true else { throw Self.failure(reply.payload?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "BetterDisplay could not perform this request for the selected display.") }
        return reply.payload ?? ""
    }

    func get(_ feature: String, uuid: String? = nil, extra: [String: String?] = [:]) async throws -> String {
        var parameters = extra
        parameters.updateValue(nil, forKey: feature)
        if let uuid { parameters["UUID"] = uuid }
        return try await request(["get"], parameters: parameters)
    }

    private func receive(_ text: String) {
        guard let data = text.data(using: .utf8), let reply = try? JSONDecoder().decode(Reply.self, from: data), let id = reply.uuid else { return }
        mutationGate.replied(requestID: id)
        finish(id, with: .success(reply))
    }

    private func expire(_ id: String, cancelled: Bool) {
        guard let operation = pending[id] else { return }
        mutationGate.expired(requestID: id)
        if operation.isMutation {
            // A local timeout/cancellation cannot retract an admitted IPC write.
            // Keep the cross-provider lock until its actual matching reply arrives.
            finish(id, with: .failure(Self.failure("The display change has no confirmed outcome and may still apply. Further changes are blocked until BetterDisplay replies. Read-only refresh remains available.")))
        } else {
            finish(id, with: .failure(cancelled ? CancellationError() : Self.failure("BetterDisplay did not reply. Check that it is running and notification integration is enabled.")))
        }
    }

    private func finish(_ id: String, with result: Result<Reply, any Error>) {
        guard let operation = pending.removeValue(forKey: id) else { return }
        operation.timeout.cancel()
        operation.continuation.resume(with: result)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OpenCore.BetterDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
