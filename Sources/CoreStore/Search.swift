import CoreModel
import Foundation

/// A lexical candidate: an object plus its raw FTS5 rank.
public struct LexicalCandidate: Sendable {
    public let object: CoreObject
    /// Raw `bm25()` output. Negative, and more negative is a better match. Left raw on
    /// purpose so the scorer above decides how to normalise it rather than inheriting a
    /// normalisation choice buried in the storage layer.
    public let bm25: Double
}

extension Store {
    /// BM25 candidates for an FTS5 MATCH expression.
    ///
    /// This lives in `CoreStore` rather than in `CoreSearch` so that the rule holds: every
    /// SQL string in the project is in this module. The scoring layer receives typed
    /// candidates and never learns that SQLite exists, which is what keeps the storage
    /// substrate swappable.
    ///
    /// - Parameter match: a *pre-escaped* FTS5 expression. Callers build it with
    ///   `HybridSearch.ftsQuery(from:)`; passing raw user text here is a syntax error at
    ///   best and an accidental corpus-wide prefix scan at worst.
    public func lexicalCandidates(match: String, limit: Int) async throws -> [LexicalCandidate] {
        guard !match.isEmpty else { return [] }

        // Title weighted 2x against body: a commit whose subject line is the match is
        // more likely to be the thing you meant than one that mentions it in a paragraph.
        return try await database.query(
            """
            SELECT o.*, bm25(object_fts, 2.0, 1.0) AS rank
            FROM object_fts
            JOIN object o ON o.rowid = object_fts.rowid
            WHERE object_fts MATCH ?
            ORDER BY rank ASC
            LIMIT ?
            """,
            [.text(match), .integer(Int64(limit))]
        ).map { LexicalCandidate(object: CoreObject(row: $0), bm25: $0.double("rank") ?? 0) }
    }
}
