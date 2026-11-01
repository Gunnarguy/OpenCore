import Foundation

/// One sync at a time, and which one it is.
///
/// A scheduled pass ran `guard !isRunning` once, at its start, and nothing else asked at all: a
/// click during a pass ran on top of it, Sync All pressed twice ran twice, and each finishing
/// sync set the shared status to idle while the other was still working. The store survives that
/// (it is an actor), but the sync date and the status line do not. So the rule is one lane.
public struct SyncLane: Sendable, Equatable {
    public struct Pass: Sendable, Hashable {
        public let id: UUID
        public let label: String
        public let unattended: Bool

        public init(id: UUID = UUID(), label: String, unattended: Bool = false) {
            self.id = id
            self.label = label
            self.unattended = unattended
        }
    }

    public enum Entry: Sendable, Equatable {
        /// The lane was free and now belongs to this pass.
        case entered
        /// The pass asking is already inside: Sync All running Calendar, for instance.
        case joined
        /// Someone else holds it. Carries that holder's label, so a refusal can say why.
        case busy(String)
    }

    public private(set) var holder: Pass?

    public init() {}

    /// - Parameter inherited: the pass the caller is already running inside, if any.
    public mutating func enter(_ pass: Pass, inherited: Pass? = nil) -> Entry {
        guard let holder else {
            self.holder = pass
            return .entered
        }
        return holder == inherited ? .joined : .busy(holder.label)
    }

    /// Only the holder can leave, so a pass that was refused can never free someone else's lane.
    public mutating func leave(_ pass: Pass) {
        if holder == pass { holder = nil }
    }
}

/// Runs work in the lane. Lives here rather than in the app because the app has no test target,
/// and overlap is the one thing that has to be proved with real overlapping tasks.
@MainActor
public final class SyncCoordinator {
    /// A task local, so a pass and the individual syncs it calls are recognised as one, while a
    /// click arriving in the middle of that pass is not.
    private enum Inherited {
        @TaskLocal static var pass: SyncLane.Pass?
    }

    public private(set) var lane = SyncLane()

    public init() {}

    /// Run `work` if the lane is free or already ours. Otherwise return `refused` without
    /// running it, because queueing would stack up exactly what this exists to prevent.
    public func exclusively<Value>(
        _ label: String,
        unattended: Bool = false,
        refused: (_ holder: String) -> Value,
        _ work: @MainActor () async -> Value
    ) async -> Value {
        let pass = SyncLane.Pass(label: label, unattended: unattended)
        switch lane.enter(pass, inherited: Inherited.pass) {
        case .joined:
            return await work()
        case .busy(let holder):
            return refused(holder)
        case .entered:
            defer { lane.leave(pass) }
            return await Inherited.$pass.withValue(pass) { await work() }
        }
    }
}
