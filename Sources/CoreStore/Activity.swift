import CoreModel
import Foundation

/// One subject and what happened to it inside a window.
public struct ActivityGroup: Sendable, Identifiable {
    public var id: EntityID { subject.id }
    public var subject: CoreEntity
    /// Events that are the work itself.
    public var events: Int
    /// Commits that are upkeep around the work: docs, bots, merges. Counted apart rather than
    /// dropped, because they did happen and hiding them would be a lie of a different kind.
    public var upkeep: Int
    public var lastAt: Date
    /// The most common verb, so a row says what kind of activity it was.
    public var verb: String
    /// The newest events, work before upkeep.
    public var latest: [CoreEvent]
}

public struct ActivitySummary: Sendable {
    public var groups: [ActivityGroup]
    /// Every event in the window that was admitted, including those in groups past `limit`.
    public var totalEvents: Int
    /// The newest admitted event at or before the window's end, whether or not it is inside
    /// the window. It tells "nothing happened" from "the store has not been synced".
    public var newestEventAt: Date?
    /// Every subject with an event in the window, including those past `limit`. `groups.count`
    /// is how many are shown, so printing it as the total reported a cap as a measurement.
    public var totalSubjects: Int = 0
    /// True when `scanLimit` stopped the read, so `totalEvents` is a floor and not a count.
    public var isTruncated: Bool = false
}

/// How far one kind of source has got.
public struct SourceFreshness: Sendable, Hashable {
    public var kind: SourceKind
    /// What an answer calls these sources. The kind, except that `.manual` holds three unlike
    /// things: "manual 2026-08-14" would name none of them.
    public var label: String
    /// Nil when no source of this kind has ever synced, which is not the same as long ago.
    public var lastSyncedAt: Date?
    /// The newest dated object these sources hold at or before the moment asked about.
    public var newestItemAt: Date?

    public init(kind: SourceKind, label: String? = nil, lastSyncedAt: Date?, newestItemAt: Date?) {
        self.kind = kind
        self.label = label ?? kind.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.newestItemAt = newestItemAt
    }
}

/// What an answer about a stretch of time can actually see.
public struct StoreFreshness: Sendable, Hashable {
    /// Each kind of source holding something the caller may read.
    public var sources: [SourceFreshness]
    /// The newest admitted event before the moment asked about.
    public var newestEventAt: Date?

    public init(sources: [SourceFreshness], newestEventAt: Date?) {
        self.sources = sources
        self.newestEventAt = newestEventAt
    }
}

extension Store {
    /// How fresh the store is, as far as a caller admitted to `domains` may know.
    ///
    /// Without this a stale store reads exactly like a quiet week. On 2026-10-31 the newest
    /// non-MCP sync was seven days old, so "what happened this week" had an honest-looking short
    /// answer that said nothing about the machine having stopped looking.
    ///
    /// **By kind, and only sources holding an admitted object.** A handle is a folder or
    /// repository name, so it does not leave here: an MCP source is "mcp", never its server's
    /// name. A source is left out unless the caller could read something from it, because a sync
    /// date for a source the firewall hides says that source exists.
    ///
    /// **Left out by handle, not by kind.** `.manual` is not "nothing syncs this". MCP sources,
    /// Apple Notes and Apple Health are all `.manual` and all sync, and excluding the kind meant a
    /// stopped MCP source never reached a `Stale:` line, so a thin window built from it read as
    /// quiet. The privacy ledger is the one source nothing syncs. It is written once by a repair,
    /// and its rows would read as permanently stale.
    ///
    /// Within a label this reports the newest sync. One abandoned folder should not mark every
    /// folder stale, at the cost that a stale folder beside a fresh one does not show.
    ///
    /// - Parameter notAfter: the moment being asked about. Events and objects after it do not
    ///   count, so a calendar entry next February is not "the newest thing in the store".
    public func freshness(domains: Set<Domain>, notAfter: Date) async throws -> StoreFreshness {
        guard !domains.isEmpty else { return StoreFreshness(sources: [], newestEventAt: nil) }
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
        let domainBindings = Self.sortedDomainBindings(domains)

        let rows = try await database.query(
            """
            SELECT s.kind AS kind, s.handle AS handle, s.last_synced_at AS synced, MAX(o.authored_at) AS newest
            FROM source s JOIN object o ON o.source_id = s.id
            WHERE s.handle != ? AND o.domain IN (\(placeholders))
              AND (o.authored_at IS NULL OR o.authored_at < ?)
            GROUP BY s.id
            """,
            [.text(Self.privacyLedgerHandle)] + domainBindings + [.real(notAfter.timeIntervalSince1970)]
        )
        var byLabel: [String: SourceFreshness] = [:]
        for row in rows {
            guard let kind = SourceKind(rawValue: row.requireString("kind")) else { continue }
            let label = Self.freshnessLabel(kind: kind, handle: row.requireString("handle"))
            var entry = byLabel[label] ?? SourceFreshness(kind: kind, label: label, lastSyncedAt: nil, newestItemAt: nil)
            entry.lastSyncedAt = [entry.lastSyncedAt, row.date("synced")].compactMap(\.self).max()
            entry.newestItemAt = [entry.newestItemAt, row.date("newest")].compactMap(\.self).max()
            byLabel[label] = entry
        }
        return StoreFreshness(
            sources: byLabel.values.sorted { $0.label < $1.label },
            newestEventAt: try await newestEvent(before: notAfter, placeholders: placeholders, domainBindings: domainBindings)
        )
    }

    /// What a freshness line calls a source. Fixed words only, so no handle reaches an answer.
    private static func freshnessLabel(kind: SourceKind, handle: String) -> String {
        guard kind == .manual else { return kind.rawValue }
        if handle.hasPrefix("mcp:") { return "mcp" }
        return switch handle {
        case "apple-notes": "notes"
        case "apple-health": "health"
        default: kind.rawValue
        }
    }

    private static func sortedDomainBindings(_ domains: Set<Domain>) -> [SQLValue] {
        domains.sorted { $0.rawValue < $1.rawValue }.map { SQLValue.text($0.rawValue) }
    }

    private func newestEvent(before end: Date, placeholders: String, domainBindings: [SQLValue]) async throws -> Date? {
        try await database.query(
            """
            SELECT MAX(v.occurred_at) AS newest FROM event v JOIN entity e ON e.id = v.subject
            WHERE v.occurred_at < ? AND v.domain IN (\(placeholders)) AND e.domain IN (\(placeholders))
            """,
            [.real(end.timeIntervalSince1970)] + domainBindings + domainBindings
        ).first?.date("newest")
    }

    /// What happened between two instants, grouped by subject, busiest first.
    ///
    /// Grouped here rather than in SQL because the split between work and upkeep is a rule in
    /// Swift (`CommitNature`), and sorting by a count SQL cannot see would put a nightly bot at
    /// the top of "what was I working on".
    ///
    /// Both the event and its subject must be admitted. An event in a readable domain about an
    /// entity in a blocked one would otherwise print the blocked entity's name.
    ///
    /// - Parameters:
    ///   - limit: groups returned. The rest still count toward `totalEvents`.
    ///   - scanLimit: events read. 20,000 is a chosen cap, far above the 862 in the largest
    ///     30-day window measured, there so a long window cannot load the whole table.
    public func activity(
        from start: Date,
        to end: Date,
        domains: Set<Domain>,
        subjects: Set<EntityID>? = nil,
        limit: Int = 12,
        detailsPerSubject: Int = 3,
        scanLimit: Int = 20_000
    ) async throws -> ActivitySummary {
        guard !domains.isEmpty else { return ActivitySummary(groups: [], totalEvents: 0, newestEventAt: nil) }
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
        let domainBindings = Self.sortedDomainBindings(domains)

        // The subject filter is in the SQL for the same reason `core_timeline`'s should be: after
        // the cap, a quiet subject's events can be cut by a busy one's and report as nothing.
        let subjectIDs = subjects?.map(\.value).sorted()
        let subjectClause = subjectIDs.map { ids in
            "AND v.subject IN (\(Array(repeating: "?", count: ids.count).joined(separator: ", ")))"
        } ?? ""

        let rows = try await database.query(
            """
            SELECT v.* FROM event v JOIN entity e ON e.id = v.subject
            WHERE v.occurred_at >= ? AND v.occurred_at < ?
              AND v.domain IN (\(placeholders)) AND e.domain IN (\(placeholders))
              \(subjectClause)
            ORDER BY v.occurred_at DESC, v.id ASC
            LIMIT ?
            """,
            [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
                + domainBindings + domainBindings
                + (subjectIDs ?? []).map { SQLValue.text($0) }
                + [.integer(Int64(scanLimit))]
        )

        let events = rows.map(CoreEvent.init(row:))
        let newest = try await newestEvent(before: end, placeholders: placeholders, domainBindings: domainBindings)

        var bySubject: [EntityID: [CoreEvent]] = [:]
        for event in events { bySubject[event.subject, default: []].append(event) }

        var groups: [ActivityGroup] = []
        for (subject, grouped) in bySubject {
            guard let entity = try await entity(subject), domains.contains(entity.domain) else { continue }
            let isUpkeep = { (event: CoreEvent) in event.verb == "committed" && CommitNature.isUpkeep(title: event.detail) }
            let work = grouped.filter { !isUpkeep($0) }
            let upkeep = grouped.filter(isUpkeep)
            let verbCounts = Dictionary(grouping: grouped, by: \.verb).mapValues(\.count)
            let verb = verbCounts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "activity"
            groups.append(ActivityGroup(
                subject: entity,
                events: work.count,
                upkeep: upkeep.count,
                lastAt: grouped.map(\.occurredAt).max() ?? start,
                verb: verb,
                latest: Array((work + upkeep).prefix(max(0, detailsPerSubject)))
            ))
        }
        // Projects first, because on a real store the busiest non-project subject is a folder
        // of edited files or a subscribed calendar. Then a total order, so the same store gives
        // the same answer in every process.
        groups.sort {
            ($0.subject.kind == .project ? 1 : 0, $0.events, $0.upkeep, $0.lastAt.timeIntervalSince1970, $1.subject.canonicalName)
                > ($1.subject.kind == .project ? 1 : 0, $1.events, $1.upkeep, $1.lastAt.timeIntervalSince1970, $0.subject.canonicalName)
        }
        return ActivitySummary(
            groups: Array(groups.prefix(max(0, limit))),
            totalEvents: events.count,
            newestEventAt: newest,
            totalSubjects: groups.count,
            isTruncated: rows.count >= scanLimit
        )
    }
}

extension Store {
    /// A repository's commits, newest first, no later than `notAfter`.
    ///
    /// Bounded by `notAfter` so a replayed epoch sees only the commits that existed then.
    /// Reading today's commits while re-deriving last year's state would date a repository's
    /// dormancy from work that had not happened yet.
    ///
    /// `limit` keeps the newest rows, so a caller asking about the oldest commit or scanning for
    /// one kind of commit has to pass `.max`.
    public func commits(
        repository: String,
        notAfter: Date,
        limit: Int = 200
    ) async throws -> [(title: String, author: String?, authoredAt: Date)] {
        try await database.query(
            """
            SELECT title, json_extract(metadata, '$.author') AS author, authored_at FROM object
            WHERE kind = 'commit' AND json_extract(metadata, '$.repo') = ?
              AND authored_at IS NOT NULL AND authored_at <= ?
            ORDER BY authored_at DESC
            LIMIT ?
            """,
            [.text(repository), .real(notAfter.timeIntervalSince1970), .integer(Int64(limit))]
        ).compactMap { row in
            row.date("authored_at").map { (row.requireString("title"), row.string("author"), $0) }
        }
    }
}
