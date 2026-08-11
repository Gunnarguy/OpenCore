import CoreModel
import Foundation

/// What OpenCore actually holds, in a shape a person can look at.
///
/// **Why this exists.** The store had 6,654 objects and no surface that showed their shape.
/// `StatusBar` reported "6654 objects", which is a number rather than an understanding, and
/// Maintenance reported counts by kind as diagnostics for someone debugging a rebuild.
///
/// The measured consequence, 2026-08-10: asked "how many of my apps are built with Swift" in
/// *chat*, because there was nowhere else to ask it. That was a person trying to understand
/// their own corpus with no screen offering it, and the answer they got was wrong by six times.
/// The counting bug was real, but the reason it was ever hit is this missing view.
public struct CorpusSnapshot: Sendable {
    public var objects: Int
    public var chunks: Int
    public var claims: Int
    public var entities: Int
    public var events: Int
    public var byKind: [(ObjectKind, Int)]
    public var byDomain: [(Domain, Int)]
    public var bySource: [(String, Int)]
    /// Objects per calendar month, oldest first, as `yyyy-MM`.
    public var byMonth: [(String, Int)]
    public var earliest: Date?
    public var latest: Date?
    /// Objects with no `authoredAt`. Reported rather than dropped from the timeline silently:
    /// a month histogram that quietly omits a third of the corpus is a misleading picture.
    public var undated: Int

    /// The largest kind as a share of everything.
    ///
    /// One number that makes an imbalance obvious. At 5,366 notes in 6,654 objects this reads
    /// 81%, which is the same imbalance sitting underneath the commit-flooding retrieval defect:
    /// a corpus dominated by many short objects of one kind ranks that kind above everything.
    public var dominantShare: Double {
        guard objects > 0, let top = byKind.first else { return 0 }
        return Double(top.1) / Double(objects)
    }
}

extension Store {
    public func corpusSnapshot() async throws -> CorpusSnapshot {
        let byKind = try await objectCountsByKind()

        let byDomain = try await database
            .query("SELECT domain, COUNT(*) AS n FROM object GROUP BY domain ORDER BY n DESC")
            .compactMap { row -> (Domain, Int)? in
                guard let domain = Domain(rawValue: row.requireString("domain")) else { return nil }
                return (domain, row.requireInt("n"))
            }

        let bySource = try await database.query(
            """
            SELECT COALESCE(s.display_name, o.source_id) AS name, COUNT(*) AS n
            FROM object o LEFT JOIN source s ON s.id = o.source_id
            GROUP BY o.source_id ORDER BY n DESC
            """
        ).map { ($0.requireString("name"), $0.requireInt("n")) }

        // Grouped in SQL rather than by loading every row and bucketing in Swift, which at
        // 6,654 objects is merely wasteful and at 100k is the difference between a screen that
        // opens and one that hangs.
        let byMonth = try await database.query(
            """
            SELECT strftime('%Y-%m', authored_at, 'unixepoch') AS month, COUNT(*) AS n
            FROM object WHERE authored_at IS NOT NULL GROUP BY month ORDER BY month ASC
            """
        ).map { ($0.requireString("month"), $0.requireInt("n")) }

        let bounds = try await database.query(
            "SELECT MIN(authored_at) AS lo, MAX(authored_at) AS hi FROM object WHERE authored_at IS NOT NULL"
        ).first

        return CorpusSnapshot(
            objects: try await objectCount(),
            chunks: try await chunkCount(),
            claims: try await claimCount(),
            entities: try await database.scalarInt("SELECT COUNT(*) FROM entity"),
            events: try await database.scalarInt("SELECT COUNT(*) FROM event"),
            byKind: byKind,
            byDomain: byDomain,
            bySource: bySource,
            byMonth: byMonth,
            earliest: bounds?.date("lo"),
            latest: bounds?.date("hi"),
            undated: try await database.scalarInt("SELECT COUNT(*) FROM object WHERE authored_at IS NULL")
        )
    }
}
