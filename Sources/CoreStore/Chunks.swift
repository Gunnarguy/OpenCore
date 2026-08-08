import CoreModel
import Foundation

public struct ChunkCandidate: Sendable {
    public let chunk: CoreChunk
    public let object: CoreObject
    /// Raw `bm25()` for lexical candidates, or cosine similarity for dense candidates.
    public let rawScore: Double
}

extension Store {
    // MARK: - Writing

    public func save(_ chunks: [CoreChunk]) async throws {
        guard !chunks.isEmpty else { return }
        try await database.write { connection in
            for chunk in chunks {
                try connection.execute(
                    """
                    INSERT INTO chunk (id, object_id, ordinal, text, range_start, range_end, token_estimate)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text,
                        range_start = excluded.range_start,
                        range_end = excluded.range_end,
                        token_estimate = excluded.token_estimate
                    """,
                    [
                        .text(chunk.id.value), .text(chunk.objectID.value), .integer(Int64(chunk.ordinal)),
                        .text(chunk.text), .integer(Int64(chunk.range.lowerBound)),
                        .integer(Int64(chunk.range.upperBound)), .integer(Int64(chunk.tokenEstimate)),
                    ]
                )
            }
        }
    }

    public func save(vectors: [StoredVector], dimensions: Int) async throws {
        guard !vectors.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try await database.write { connection in
            for vector in vectors {
                try connection.execute(
                    """
                    INSERT INTO chunk_vector (chunk_id, model, dimensions, vector, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(chunk_id, model) DO UPDATE SET vector = excluded.vector, created_at = excluded.created_at
                    """,
                    [
                        .text(vector.chunkID.value), .text(vector.model), .integer(Int64(dimensions)),
                        .blob(VectorMath.encode(vector.values)), .real(now),
                    ]
                )
            }
        }
    }

    // MARK: - Reading

    public func chunkCount() async throws -> Int {
        try await database.scalarInt("SELECT COUNT(*) FROM chunk")
    }

    public func embeddedChunkCount(model: String) async throws -> Int {
        try await database.scalarInt("SELECT COUNT(*) FROM chunk_vector WHERE model = ?", [.text(model)])
    }

    /// Chunks with no vector for `model`. Drives incremental embedding: interrupt an
    /// embed run and the next one resumes rather than starting over.
    public func chunksMissingVectors(model: String, limit: Int) async throws -> [CoreChunk] {
        try await database.query(
            """
            SELECT c.* FROM chunk c
            LEFT JOIN chunk_vector v ON v.chunk_id = c.id AND v.model = ?
            WHERE v.chunk_id IS NULL
            LIMIT ?
            """,
            [.text(model), .integer(Int64(limit))]
        ).map(CoreChunk.init(row:))
    }

    public func recordEmbeddingRun(model: String, dimensions: Int, chunksDone: Int, finished: Bool) async throws {
        try await database.execute(
            """
            INSERT INTO embedding_run (model, dimensions, chunks_done, started_at, finished_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(model) DO UPDATE SET
                chunks_done = excluded.chunks_done,
                finished_at = excluded.finished_at
            """,
            [
                .text(model), .integer(Int64(dimensions)), .integer(Int64(chunksDone)),
                .real(Date().timeIntervalSince1970),
                finished ? .real(Date().timeIntervalSince1970) : .null,
            ]
        )
    }

    public func embeddingRuns() async throws -> [(model: String, dimensions: Int, chunksDone: Int, finished: Bool)] {
        try await database.query("SELECT * FROM embedding_run ORDER BY started_at DESC").map {
            ($0.requireString("model"), $0.requireInt("dimensions"), $0.requireInt("chunks_done"), $0.date("finished_at") != nil)
        }
    }

    // MARK: - Lexical retrieval over chunks

    public func lexicalChunks(match: String, limit: Int) async throws -> [ChunkCandidate] {
        guard !match.isEmpty else { return [] }
        return try await database.query(
            """
            SELECT c.*, o.id AS o_id, o.source_id AS o_source_id, o.kind AS o_kind,
                   o.external_id AS o_external_id, o.title AS o_title, o.text AS o_text,
                   o.uri AS o_uri, o.authored_at AS o_authored_at, o.ingested_at AS o_ingested_at,
                   o.domain AS o_domain, o.authority AS o_authority, o.metadata AS o_metadata,
                   bm25(chunk_fts) AS rank
            FROM chunk_fts
            JOIN chunk c ON c.rowid = chunk_fts.rowid
            JOIN object o ON o.id = c.object_id
            WHERE chunk_fts MATCH ?
            ORDER BY rank ASC
            LIMIT ?
            """,
            [.text(match), .integer(Int64(limit))]
        ).map { ChunkCandidate(chunk: CoreChunk(row: $0), object: CoreObject(prefixedRow: $0), rawScore: $0.double("rank") ?? 0) }
    }

    // MARK: - Dense retrieval

    /// Brute-force cosine search over stored vectors.
    ///
    /// Linear in the number of chunks, and that is a deliberate v0.2 choice rather than an
    /// oversight: a personal corpus is tens of thousands of chunks, a dot product over
    /// 512 floats is nanoseconds, and an approximate index would add a tuning surface and
    /// a recall cliff before anything here has been measured. When `doctor` shows this
    /// taking real time, that is the signal to build the index, not before.
    public func denseChunks(query: [Float], model: String, limit: Int) async throws -> [ChunkCandidate] {
        guard !query.isEmpty else { return [] }
        let normalisedQuery = VectorMath.normalise(query)

        let rows = try await database.query(
            """
            SELECT v.vector AS vector, v.dimensions AS dims, c.*,
                   o.id AS o_id, o.source_id AS o_source_id, o.kind AS o_kind,
                   o.external_id AS o_external_id, o.title AS o_title, o.text AS o_text,
                   o.uri AS o_uri, o.authored_at AS o_authored_at, o.ingested_at AS o_ingested_at,
                   o.domain AS o_domain, o.authority AS o_authority, o.metadata AS o_metadata
            FROM chunk_vector v
            JOIN chunk c ON c.id = v.chunk_id
            JOIN object o ON o.id = c.object_id
            WHERE v.model = ?
            """,
            [.text(model)]
        )

        var scored: [ChunkCandidate] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            guard let blob = row.data("vector") else { continue }
            let values = VectorMath.decode(blob, dimensions: row.requireInt("dims"))
            guard values.count == normalisedQuery.count else { continue }
            scored.append(ChunkCandidate(
                chunk: CoreChunk(row: row),
                object: CoreObject(prefixedRow: row),
                rawScore: Double(VectorMath.dot(normalisedQuery, values))
            ))
        }
        scored.sort { $0.rawScore > $1.rawScore }
        return Array(scored.prefix(limit))
    }

    /// Neighbouring chunks of the same object, for expanding a hit back into context.
    public func neighbours(of chunk: CoreChunk, window: Int = 1) async throws -> [CoreChunk] {
        try await database.query(
            "SELECT * FROM chunk WHERE object_id = ? AND ordinal BETWEEN ? AND ? ORDER BY ordinal",
            [
                .text(chunk.objectID.value),
                .integer(Int64(chunk.ordinal - window)),
                .integer(Int64(chunk.ordinal + window)),
            ]
        ).map(CoreChunk.init(row:))
    }
}

extension CoreChunk {
    init(row: Row) {
        let start = row.requireInt("range_start")
        let end = max(start, row.requireInt("range_end"))
        self.init(
            objectID: ObjectID(row.requireString("object_id")),
            ordinal: row.requireInt("ordinal"),
            text: row.requireString("text"),
            range: start..<end
        )
    }
}

extension CoreObject {
    /// Build from a joined row where object columns carry an `o_` prefix, so a chunk
    /// query can return both without column-name collisions on `id` and `text`.
    init(prefixedRow row: Row) {
        let metadata: [String: String] = row.string("o_metadata")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

        self.init(
            sourceID: SourceID(row.requireString("o_source_id")),
            kind: ObjectKind(rawValue: row.requireString("o_kind")) ?? .document,
            externalID: row.requireString("o_external_id"),
            title: row.requireString("o_title"),
            text: row.requireString("o_text"),
            uri: row.string("o_uri"),
            authoredAt: row.date("o_authored_at"),
            ingestedAt: row.requireDate("o_ingested_at"),
            domain: Domain(rawValue: row.requireString("o_domain")) ?? .project,
            authority: Authority(rawValue: row.requireInt("o_authority")) ?? .thirdPartyRecord,
            metadata: metadata
        )
    }
}
