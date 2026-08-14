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
    public func homeSnapshot(windowDays: Int = 7, limit: Int = 12) async throws -> HomeSnapshot {
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)

        // Grouped in SQL. Loading 290 events to bucket them in Swift is merely wasteful today
        // and is the difference between a screen that opens and one that hangs at 100k.
        //
        // INNER JOIN, so an event whose subject resolves to no entity is excluded rather than
        // rendered under a raw hash. Those are counted separately below instead of vanishing:
        // an empty list because nothing happened and an empty list because nothing could be
        // named are different facts.
        let rows = try await database.query(
            """
            SELECT e.canonical_name AS name, e.kind AS kind, COUNT(*) AS n, MAX(v.occurred_at) AS last,
                   (SELECT verb FROM event v2 WHERE v2.subject = v.subject AND v2.occurred_at >= ?
                    GROUP BY v2.verb ORDER BY COUNT(*) DESC LIMIT 1) AS verb
            FROM event v JOIN entity e ON e.id = v.subject
            WHERE v.occurred_at >= ?
            GROUP BY v.subject
            ORDER BY n DESC
            LIMIT ?
            """,
            [.real(cutoff.timeIntervalSince1970), .real(cutoff.timeIntervalSince1970), .integer(Int64(limit))]
        )

        let recent = rows.compactMap { row -> HomeSnapshot.Activity? in
            guard let last = row.date("last"),
                  let kind = EntityKind(rawValue: row.requireString("kind"))
            else { return nil }
            return HomeSnapshot.Activity(
                subject: row.requireString("name"),
                events: row.requireInt("n"),
                lastAt: last,
                verb: row.string("verb") ?? "activity",
                kind: kind
            )
        }

        let unattributed = try await database.scalarInt(
            """
            SELECT COUNT(*) FROM event v
            WHERE v.occurred_at >= ? AND NOT EXISTS (SELECT 1 FROM entity e WHERE e.id = v.subject)
            """,
            [.real(cutoff.timeIntervalSince1970)]
        )

        let allSources = try await sources()

        return HomeSnapshot(
            recent: recent,
            windowDays: windowDays,
            unattributed: unattributed,
            openContradictions: try await contradictions(unresolvedOnly: true).count,
            objects: try await objectCount(),
            entities: try await database.scalarInt("SELECT COUNT(*) FROM entity"),
            lastSyncedAt: allSources.compactMap(\.lastSyncedAt).max(),
            neverSynced: allSources.filter { $0.lastSyncedAt == nil }.map(\.displayName)
        )
    }
}
