import Foundation

/// A collection attempt is distinct from a usable capture. Values are observations, not evidence.
public struct OperatorSnapshotRead<Value: Sendable>: Sendable {
    public enum Outcome: Sendable {
        case complete(Value)
        case partial(Value, issues: [String])
        case failed(String)
    }

    public let attemptedAt: Date
    public let finishedAt: Date
    public let outcome: Outcome
    public let order: UInt64

    public init(attemptedAt: Date, finishedAt: Date, order: UInt64 = DispatchTime.now().uptimeNanoseconds, outcome: Outcome) {
        self.attemptedAt = attemptedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.order = order
    }

    public var value: Value? {
        switch outcome { case .complete(let value), .partial(let value, _): value; case .failed: nil }
    }
    public var capturedAt: Date? { value == nil ? nil : finishedAt }
    public var isComplete: Bool { if case .complete = outcome { true } else { false } }
    public var issues: [String] {
        switch outcome { case .complete: []; case .partial(_, let issues): issues; case .failed(let issue): [issue] }
    }
}

/// Callers serialize their requests. A failed attempt never refreshes or erases the last capture.
public struct OperatorSnapshotCache<Value: Sendable>: Sendable {
    public private(set) var lastAttempt: OperatorSnapshotRead<Value>?
    public private(set) var lastCapture: OperatorSnapshotRead<Value>?
    private var rowOrders: [String: UInt64] = [:]

    public init() {}
    public var value: Value? { lastCapture?.value }

    public mutating func record(_ read: OperatorSnapshotRead<Value>) {
        // Reject a late result from an older request, rather than publishing stale data as fresh.
        guard lastAttempt.map({ read.order >= $0.order }) ?? true else { return }
        lastAttempt = read
        // Keep the attempt's status even when newer row values prevent replacing the payload.
        if !rowOrders.values.contains(where: { $0 > read.order }) {
            if read.capturedAt != nil { lastCapture = read }
            rowOrders.removeAll()
        }
    }

    /// A narrow row refresh does not certify a new collection of the whole inventory.
    @discardableResult
    public mutating func amendCapturedValue(_ value: Value, rowKey: String, order: UInt64, issues: [String] = []) -> Bool {
        guard let old = lastCapture, order >= (lastAttempt?.order ?? 0), order >= (rowOrders[rowKey] ?? 0) else { return false }
        let outcome: OperatorSnapshotRead<Value>.Outcome
        switch old.outcome {
        case .complete: outcome = issues.isEmpty ? .complete(value) : .partial(value, issues: issues)
        case .partial(_, let oldIssues): outcome = .partial(value, issues: Array(Set(oldIssues + issues)).sorted())
        case .failed: return false
        }
        lastCapture = OperatorSnapshotRead(attemptedAt: old.attemptedAt, finishedAt: old.finishedAt, order: old.order, outcome: outcome)
        rowOrders[rowKey] = order
        return true
    }
}

/// Missing/error/defaulted repository fields cannot prove that a working tree was clean.
public struct RepositoryStatusObservation: Sendable {
    public let dirtyCount: Int?
    public init(isGit: Bool, dirtyCount: Int?, hasError: Bool, isMissing: Bool) {
        self.dirtyCount = isGit && !hasError && !isMissing ? dirtyCount.flatMap { $0 >= 0 ? $0 : nil } : nil
    }
    public var isMeasured: Bool { dirtyCount != nil }
    public var isClean: Bool { dirtyCount == 0 }
    public var summary: String { dirtyCount.map { $0 == 0 ? "clean" : "\($0) modified files" } ?? "not measured" }

    public init(json: Data) throws {
        struct Fields: Decodable {
            var git: Bool
            var dirty: Int?
            var error: String?
            var missing_dir: Bool?
        }
        let fields = try JSONDecoder().decode(Fields.self, from: json)
        self.init(isGit: fields.git, dirtyCount: fields.dirty, hasError: fields.error != nil, isMissing: fields.missing_dir == true)
    }
}

/// Chosen traversal limits are checked between filesystem calls, which can themselves block.
public struct CooperativeScanBudget: Sendable {
    private let startedAt: UInt64
    private let maximumNanoseconds: UInt64
    private let maximumEntries: Int
    private var visited = 0

    public init(startedAt: UInt64, maximumNanoseconds: UInt64, maximumEntries: Int) {
        self.startedAt = startedAt
        self.maximumNanoseconds = maximumNanoseconds
        self.maximumEntries = maximumEntries
    }

    public mutating func admit(now: UInt64, cancelled: Bool) -> Bool {
        guard !cancelled, now >= startedAt, now - startedAt < maximumNanoseconds, visited < maximumEntries else { return false }
        visited += 1
        return true
    }
}

public enum OperatorSnapshotFormatting {
    public static func numberedFiles(count: Int, reachedLimit: Bool, error: String?) -> String {
        if let error { return error }
        guard count >= 0 else { return "Numbered-file count not measured." }
        return (reachedLimit ? "At least " : "") + "\(count) numbered-file candidates; filenames do not prove an iCloud conflict."
    }

    public static func peers(requested: Bool, reachable: [String]) -> String {
        guard requested else { return "Tailnet not checked" }
        return reachable.isEmpty ? "No reachable remote peer recorded" : "Reachable peers: " + reachable.joined(separator: ", ")
    }
}

public enum SharedSkillInventory {
    /// Resolve once while collecting, never while rendering an older snapshot.
    public static func sameSourceCount(firstNames: [String], secondNames: [String], firstRoot: URL, secondRoot: URL) -> Int {
        Set(firstNames).intersection(secondNames).filter { name in
            firstRoot.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL ==
                secondRoot.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        }.count
    }
}
