import CoreModel
import Foundation

/// What has been going on, for the screen you land on.
///
/// **Why this exists.** The app had no front door. Opening it put you in a chat box with no
/// indication of what the store knew, what had changed, or whether anything needed attention.
/// Every other screen was a view onto one layer of the pipeline, which answers "show me the
/// claims table" and never answers "what am I looking at this for".
///
/// The counters here are deliberately the ones a person would ask about rather than the ones
/// that are cheap to compute. `StatusBar` already showed "6,654 objects", and that is a number
/// rather than an understanding.
public struct HomeSnapshot: Sendable {
    /// One subject and how much happened to it in the window.
    public struct Activity: Sendable, Identifiable, Hashable {
        public var id: String { subject }
        public var subject: String
        public var events: Int
        public var lastAt: Date
        /// The most common verb in the window, so a row says what *kind* of activity it was
        /// rather than only how much.
        public var verb: String
        /// Carried so the view can separate work from everything else.
        ///
        /// Measured on the real store before this field existed: the busiest subjects in a week
        /// were OpenIntelligence at 82, then **Birthdays at 53 and US Holidays at 19**. A
        /// subscribed holiday calendar outranked every project but one. Those are real events
        /// and hiding them would be a lie, but presenting them as the answer to "what have you
        /// been working on" is a different lie. They are `.concept` in the `personal` domain
        /// where a project is `.project`, so the distinction is already in the data.
        public var kind: EntityKind
        /// Commits that are upkeep rather than work. Counted apart so a nightly bot cannot lead
        /// the list of what you have been doing.
        public var upkeep: Int = 0
    }

    /// One slot whose value changed.
    public struct BeliefChange: Sendable, Identifiable, Hashable {
        public var id: BeliefID
        public var subject: String
        public var predicate: String
        public var reason: String
        public var decidedAt: Date
    }

    /// One open contradiction, named.
    public struct ContradictionRow: Sendable, Identifiable, Hashable {
        public var id: ContradictionID
        public var subject: String
        public var predicate: String
        public var reason: String
        public var detectedAt: Date
    }

    /// Projects and the like, busiest first.
    public var work: [Activity] { recent.filter { $0.kind == .project } }
    /// Everything else, which on a real store is mostly subscribed calendars.
    public var other: [Activity] { recent.filter { $0.kind != .project } }

    /// Busiest first. Empty is a real answer and the view must render it as one.
    public var recent: [Activity]
    /// How far back `recent` looks, in days. Carried rather than assumed, so the heading can
    /// say what it measured instead of the reader inferring it.
    public var windowDays: Int
    /// Events in the window that resolved to no known entity, so a quiet week is
    /// distinguishable from a week whose subjects could not be named.
    public var unattributed: Int

    public var openContradictions: Int
    /// Revisions in the window, real changes of mind before a document restating itself, each
    /// newest first. A first belief in a slot is not a change of mind.
    public var beliefChanges: [BeliefChange] = []
    /// The open contradictions behind `openContradictions`, newest first.
    public var contradictionRows: [ContradictionRow] = []
    /// Set only when a previous visit was known. nil and zero are different statements here.
    public var eventsSinceVisit: Int?
    public var beliefChangesSinceVisit: Int?
    public var objects: Int
    public var entities: Int

    /// Most recent successful sync across all sources, and the sources that have never had one.
    public var lastSyncedAt: Date?
    public var neverSynced: [String]
}

extension Store {
    /// - Parameter windowDays: how far back "recent" reaches. 7 by default, **chosen, not
    ///   measured**: it is one week because a week is the unit people plan in, not because any
    ///   retention or recall number pointed at it.
    /// - Parameter since: the previous visit, for "what changed since you were last here".
    ///
    /// **Sensitive subjects stay off this screen.** Home is on show whenever the app is, on a
    /// shared screen or in a screenshot, so it reads only domains a person would not mind seeing
    /// there. A query that names a sensitive domain still reaches them.
    public func homeSnapshot(windowDays: Int = 7, limit: Int = 12, since visit: Date? = nil, now: Date = Date()) async throws -> HomeSnapshot {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let visible = Set(Domain.allCases).filter { !$0.isSensitive && $0 != .restricted }

        let activity = try await activity(from: cutoff, to: now, domains: visible, limit: limit, detailsPerSubject: 0)
        let recent = activity.groups.map {
            HomeSnapshot.Activity(
                subject: $0.subject.canonicalName,
                events: $0.events,
                lastAt: $0.lastAt,
                verb: $0.verb,
                kind: $0.subject.kind,
                upkeep: $0.upkeep
            )
        }

        let unattributed = try await database.scalarInt(
            """
            SELECT COUNT(*) FROM event v
            WHERE v.occurred_at >= ? AND NOT EXISTS (SELECT 1 FROM entity e WHERE e.id = v.subject)
            """,
            [.real(cutoff.timeIntervalSince1970)]
        )

        // Newest first, version above 1, and only slots this screen may show.
        var beliefChanges: [HomeSnapshot.BeliefChange] = []
        for belief in try await beliefsDecided(since: cutoff).sorted(by: { $0.decidedAt > $1.decidedAt }) where belief.version > 1 {
            guard let claim = try await claim(belief.claimID),
                  visible.contains(claim.domain),
                  let subject = try await entity(claim.subject),
                  visible.contains(subject.domain)
            else { continue }
            beliefChanges.append(HomeSnapshot.BeliefChange(
                id: belief.id,
                subject: subject.canonicalName,
                predicate: claim.predicate,
                reason: belief.reason,
                decidedAt: belief.decidedAt
            ))
        }
        // Real changes of mind first. One handoff rewrite is three revisions, an objective, a commit
        // and a next action, and the screen shows six rows, so in date order a single session could
        // push a repository going dormant off it. Nothing is dropped: the count stays every revision.
        beliefChanges = beliefChanges.filter { !Predicate.documentRestated.contains($0.predicate) }
            + beliefChanges.filter { Predicate.documentRestated.contains($0.predicate) }

        var contradictionRows: [HomeSnapshot.ContradictionRow] = []
        let open = try await contradictions(unresolvedOnly: true)
        for item in open {
            guard let claim = try await claim(item.claimA),
                  visible.contains(claim.domain),
                  let subject = try await entity(claim.subject),
                  visible.contains(subject.domain)
            else { continue }
            contradictionRows.append(HomeSnapshot.ContradictionRow(
                id: item.id,
                subject: subject.canonicalName,
                predicate: claim.predicate,
                reason: item.reason,
                detectedAt: item.detectedAt
            ))
        }

        var eventsSinceVisit: Int?
        var beliefChangesSinceVisit: Int?
        if let visit {
            eventsSinceVisit = try await self.activity(from: visit, to: now, domains: visible, limit: 0).totalEvents
            beliefChangesSinceVisit = beliefChanges.filter { $0.decidedAt >= visit }.count
        }

        let allSources = try await sources()

        return HomeSnapshot(
            recent: recent,
            windowDays: windowDays,
            unattributed: unattributed,
            openContradictions: open.count,
            beliefChanges: beliefChanges,
            contradictionRows: contradictionRows,
            eventsSinceVisit: eventsSinceVisit,
            beliefChangesSinceVisit: beliefChangesSinceVisit,
            objects: try await objectCount(),
            entities: try await database.scalarInt("SELECT COUNT(*) FROM entity"),
            lastSyncedAt: allSources.compactMap(\.lastSyncedAt).max(),
            neverSynced: allSources.filter { $0.kind != .manual && $0.lastSyncedAt == nil }.map(\.displayName)
        )
    }
}
