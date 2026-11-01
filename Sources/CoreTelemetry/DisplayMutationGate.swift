import Foundation

/// Serializes a whole display operation, including its preflight and readback.
/// The caller isolates this value; it holds no request payloads or monitor state.
public struct DisplayMutationGate: Sendable {
    private var lease: UUID?
    private var pendingRequests = Set<String>()
    private var unknownRequests = Set<String>()

    public init() {}

    /// Outstanding posts remain busy even if their operation accidentally releases early.
    public var isBusy: Bool { lease != nil || !pendingRequests.isEmpty || hasUnknownOutcome }
    public var hasUnknownOutcome: Bool { !unknownRequests.isEmpty }

    public mutating func reserve() -> UUID? {
        guard !isBusy else { return nil }
        let token = UUID()
        lease = token
        return token
    }

    public func owns(_ lease: UUID) -> Bool { self.lease == lease }

    public mutating func release(_ lease: UUID) {
        guard owns(lease) else { return }
        self.lease = nil
    }

    /// Register immediately before posting. A stale task cannot post under a newer lease.
    @discardableResult
    public mutating func posted(requestID: String, lease: UUID) -> Bool {
        guard owns(lease), !requestID.isEmpty, !hasUnknownOutcome,
              !pendingRequests.contains(requestID) else { return false }
        pendingRequests.insert(requestID)
        return true
    }

    /// Timing out locally does not mean the provider stopped processing the posted request.
    public mutating func expired(requestID: String) {
        guard pendingRequests.remove(requestID) != nil else { return }
        unknownRequests.insert(requestID)
    }

    /// Only the exact provider response clears its uncertainty; the operation still owns
    /// its lease until readback and cleanup explicitly release it.
    public mutating func replied(requestID: String) {
        pendingRequests.remove(requestID)
        unknownRequests.remove(requestID)
    }
}
