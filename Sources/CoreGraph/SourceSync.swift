import CoreModel
import CoreStore
import Foundation

/// One read of one source: where it starts, what it does with the answer, and when the source's
/// sync date may move.
///
/// These decisions lived in the app and again in the CLI, and the app has no test target, so
/// nothing could prove them. They are the ones that lose data quietly: a wrong date here hides
/// everything older from every later sync, and no screen ever says so.
///
/// Connectors stay in `CoreIngest` and `CoreGraph` cannot see them, so the fetch arrives as a
/// closure. That closure is also what lets a test fail a read on purpose.
public struct SourceSync: Sendable {
    public enum Reach: Sendable {
        /// Start from the last sync date, when there is one worth trusting.
        case sinceLastSync
        /// Read everything the connector can reach, which is the only way an object already on
        /// disk gains a field its connector learned later.
        case everything
    }

    public enum Phase: Sendable, Equatable {
        case fetching(since: Date?)
        case deriving(objects: Int)
    }

    public typealias Fetched = ConnectorBatch

    public struct Report: Sendable {
        /// The date the fetch was given. nil means it read from the beginning.
        public let since: Date?
        public let startedAt: Date
        /// How many objects the fetch returned, which is not how many changed.
        public let read: Int
        /// nil when the fetch returned nothing, so nothing was derived.
        public let derived: IngestPipeline.Outcome?
        /// Whether the source's sync date moved.
        public let advanced: Bool
        /// What the read could not reach. Not empty means the date stayed, though what was read
        /// is kept.
        public let unread: [String]

        /// Why the date stayed, in words, or nil when it moved. Every surface shows this one, so
        /// none of them can call a read that held the date "nothing new".
        public var heldBecause: String? {
            if advanced { return nil }
            if unread.isEmpty { return "It returned nothing, so the sync date did not move." }
            return (unread + ["The sync date did not move, so the next sync looks again."]).joined(separator: " ")
        }

        /// Objects that were new or differed from the floor. An incremental read can return
        /// objects that turn out to be identical, so this is what says whether anything happened.
        public var changed: Int {
            derived.map { $0.ingest.inserted + $0.ingest.updated } ?? 0
        }
    }

    private let store: Store
    private let pipeline: IngestPipeline
    private let clock: @Sendable () -> Date

    public init(store: Store, pipeline: IngestPipeline, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.pipeline = pipeline
        self.clock = clock
    }

    /// Read one source and derive from what came back.
    ///
    /// A fetch that throws leaves the sync date where it was, because nothing after it runs.
    ///
    /// **So does a fetch that says it fell short.** What it did read is stored and derived, because
    /// losing that helps nobody, and the date stays. The next pass then covers the same span again.
    /// A source that falls short on every read therefore never moves its date and says so each
    /// time, which costs a comparison against the floor. Moving it would cost the records it missed.
    ///
    /// **The date recorded is when the read began, not when it finished.** Connectors filter on
    /// `modified < since`, so a date taken after the read skips anything changed while it ran,
    /// on every later sync, with nothing to say so. Notes can take minutes to answer. Reading
    /// something twice costs a comparison against the floor; missing it costs the change.
    ///
    /// - Parameters:
    ///   - phase: awaited, so a caller's status line cannot arrive after the sync has finished.
    ///   - fetch: receives the date to start from.
    public func run(
        _ sourceID: SourceID,
        reach: Reach = .sinceLastSync,
        log: @Sendable (String) -> Void = { _ in },
        phase: @Sendable (Phase) async -> Void = { _ in },
        fetch: @Sendable (Date?) async throws -> Fetched
    ) async throws -> Report {
        let since: Date?
        switch reach {
        case .sinceLastSync: since = try await store.incrementalStart(for: sourceID)
        case .everything: since = nil
        }

        let startedAt = clock()
        await phase(.fetching(since: since))
        let fetched = try await fetch(since)

        let complete = fetched.unread.isEmpty

        guard !fetched.objects.isEmpty else {
            // An empty first pass must not set the date. See `Source.shouldAdvanceSync`.
            let advance = complete && Source.shouldAdvanceSync(previous: since, fetched: 0)
            if advance {
                try await store.markSynced(sourceID, at: startedAt, cursor: fetched.cursor)
            }
            return Report(since: since, startedAt: startedAt, read: 0, derived: nil, advanced: advance, unread: fetched.unread)
        }

        await phase(.deriving(objects: fetched.objects.count))
        let derived = try await pipeline.run(objects: fetched.objects, log: log)
        if complete {
            try await store.markSynced(sourceID, at: startedAt, cursor: fetched.cursor)
        }
        return Report(since: since, startedAt: startedAt, read: fetched.objects.count, derived: derived, advanced: complete, unread: fetched.unread)
    }
}
