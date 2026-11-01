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

    /// Chunks dated inside `window` that a caller admitted to `domains` may read.
    ///
    /// This is what a date-filtered search can truly say it searched. Only admitted domains are
    /// counted: `chunkCount()` is one number about the whole store, but a count per window is a
    /// question a caller can repeat, and with blocked chunks in it, it would say how much
    /// medical text exists from any month it cared to ask about.
    public func chunkCount(authoredIn window: DateInterval, domains: Set<Domain>) async throws -> Int {
        guard !domains.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
        return try await database.scalarInt(
            """
            SELECT COUNT(*) FROM chunk c JOIN object o ON o.id = c.object_id
            WHERE o.authored_at >= ? AND o.authored_at < ? AND o.domain IN (\(placeholders))
            """,
            [.real(window.start.timeIntervalSince1970), .real(window.end.timeIntervalSince1970)]
                + domains.sorted { $0.rawValue < $1.rawValue }.map { SQLValue.text($0.rawValue) }
        )
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

    public func lexicalChunks(
        match: String,
        limit: Int,
        admittedDomains: Set<Domain>? = nil,
        includeBlockedTopWindowForTelemetry: Bool = false,
        authoredIn window: DateInterval? = nil
    ) async throws -> [ChunkCandidate] {
        guard !match.isEmpty else { return [] }
        // 15x (floor 1200) is a chosen constant, not a measured one: large enough to reach
        // `.project` chunks behind thousands of `.personal` notes before SQL truncation.
        let poolLimit = max(limit * 15, 1200)

        // In the SQL, not applied to the results. Filtering afterwards would search all of
        // time, cut to a few hundred rows, and then discard most of them, so a question about
        // last week could miss last week's passages because older text outranked them.
        //
        // An object with no authored date cannot be placed in a window, so it is excluded
        // rather than assumed to fall inside it.
        let dateClause = window == nil ? "" : "AND o.authored_at >= ? AND o.authored_at < ?"
        let dateBindings: [SQLValue] = window.map {
            [.real($0.start.timeIntervalSince1970), .real($0.end.timeIntervalSince1970)]
        } ?? []

        let chunkRows = try await database.query(
            """
            SELECT c.*, o.id AS o_id, o.source_id AS o_source_id, o.kind AS o_kind,
                   o.external_id AS o_external_id, o.title AS o_title, o.text AS o_text,
                   o.uri AS o_uri, o.authored_at AS o_authored_at, o.ingested_at AS o_ingested_at,
                   o.domain AS o_domain, o.authority AS o_authority, o.metadata AS o_metadata,
                   bm25(chunk_fts) AS rank
            FROM chunk_fts
            JOIN chunk c ON c.rowid = chunk_fts.rowid
            JOIN object o ON o.id = c.object_id
            WHERE chunk_fts MATCH ? \(dateClause)
            ORDER BY rank ASC, c.id ASC
            LIMIT ?
            """,
            [.text(match)] + dateBindings + [.integer(Int64(poolLimit))]
        )

        // Lead passages of objects whose title or body matched `object_fts` (where title carries
        // 2x weight). `chunk_fts` indexes only `chunk.text`, so a README chunk or repository
        // overview whose title names the entity directly can otherwise be outranked by dozens of
        // 8-word commit messages that each repeat `Owner/Repo` on their first line.
        let titleRows = try await database.query(
            """
            SELECT c.*, o.id AS o_id, o.source_id AS o_source_id, o.kind AS o_kind,
                   o.external_id AS o_external_id, o.title AS o_title, o.text AS o_text,
                   o.uri AS o_uri, o.authored_at AS o_authored_at, o.ingested_at AS o_ingested_at,
                   o.domain AS o_domain, o.authority AS o_authority, o.metadata AS o_metadata,
                   bm25(object_fts, 2.0, 1.0) AS rank
            FROM object_fts
            JOIN object o ON o.rowid = object_fts.rowid
            JOIN chunk c ON c.object_id = o.id AND c.ordinal = 0
            WHERE object_fts MATCH ? \(dateClause)
            ORDER BY rank ASC, c.id ASC
            LIMIT ?
            """,
            // 2x (floor 120) is a chosen constant, not a measured one.
            [.text(match)] + dateBindings + [.integer(Int64(max(limit * 2, 120)))]
        )

        let queryTerms = Self.extractTerms(fromMatch: match)
        var byChunkID: [ChunkID: ChunkCandidate] = [:]

        for row in chunkRows + titleRows {
            let chunk = CoreChunk(row: row)
            let object = CoreObject(prefixedRow: row)
            let rawBM25 = row.double("rank") ?? 0
            let adjusted = Self.adjustedLexicalScore(
                rawBM25: rawBM25,
                chunk: chunk,
                object: object,
                queryTerms: queryTerms
            )
            if let existing = byChunkID[chunk.id] {
                if adjusted < existing.rawScore {
                    byChunkID[chunk.id] = ChunkCandidate(chunk: chunk, object: object, rawScore: adjusted)
                }
            } else {
                byChunkID[chunk.id] = ChunkCandidate(chunk: chunk, object: object, rawScore: adjusted)
            }
        }

        // Pair top-ranked `.repository` cards with their `#readme` lead passage (and vice versa).
        // `GitHubConnector` splits each repository into `Owner/Repo` (`.repository`) and
        // `Owner/Repo#readme` (`.document`); when a query matches prose in the README, the
        // companion `.repository` card carries the canonical metadata, and when a query matches
        // the repository card or topics, the `#readme` lead passage carries the overview prose.
        let initialStructural = byChunkID.values
            .filter { candidate in
                if let admittedDomains, !admittedDomains.contains(candidate.object.domain) {
                    return false
                }
                return candidate.object.kind == .repository ||
                    (candidate.object.kind == .document && candidate.object.externalID.hasSuffix("#readme"))
            }
            .sorted(by: Self.bestFirst)

        var pairedRepos = Set<String>()
        for candidate in initialStructural {
            // Pairing cap of 4 and companion score factor of 0.92 are chosen constants, not measured ones.
            guard pairedRepos.count < 4 else { break }
            let ext = candidate.object.externalID
            let repoExternalID: String
            let companionExternalID: String
            if candidate.object.kind == .repository {
                repoExternalID = ext
                companionExternalID = ext + "#readme"
            } else if ext.hasSuffix("#readme") {
                repoExternalID = String(ext.dropLast("#readme".count))
                companionExternalID = repoExternalID
            } else {
                continue
            }
            guard pairedRepos.insert(repoExternalID).inserted else { continue }
            let companionScore = candidate.rawScore * 0.92
            let companionRows = try await database.query(
                """
                SELECT c.*, o.id AS o_id, o.source_id AS o_source_id, o.kind AS o_kind,
                       o.external_id AS o_external_id, o.title AS o_title, o.text AS o_text,
                       o.uri AS o_uri, o.authored_at AS o_authored_at, o.ingested_at AS o_ingested_at,
                       o.domain AS o_domain, o.authority AS o_authority, o.metadata AS o_metadata
                FROM object o
                JOIN chunk c ON c.object_id = o.id AND c.ordinal = 0
                WHERE o.external_id = ? \(dateClause)
                ORDER BY c.id ASC
                LIMIT 1
                """,
                [.text(companionExternalID)] + dateBindings
            )
            if let row = companionRows.first {
                let chunk = CoreChunk(row: row)
                let object = CoreObject(prefixedRow: row)
                if let existing = byChunkID[chunk.id] {
                    if companionScore < existing.rawScore {
                        byChunkID[chunk.id] = ChunkCandidate(chunk: chunk, object: object, rawScore: companionScore)
                    }
                } else {
                    byChunkID[chunk.id] = ChunkCandidate(chunk: chunk, object: object, rawScore: companionScore)
                }
            }
        }

        let sorted = byChunkID.values.sorted(by: Self.bestFirst)
        return Self.selectCandidates(
            from: sorted,
            limit: limit,
            admittedDomains: admittedDomains,
            includeBlockedTopWindowForTelemetry: includeBlockedTopWindowForTelemetry
        )
    }

    /// Best lexical candidate first, and a total order. More negative is better, matching
    /// SQLite bm25().
    ///
    /// The chunk id is what makes it total. Identical text scores identically, and these
    /// candidates arrive from a `Dictionary`, whose order changes with each process's hash
    /// seed. Sorted on score alone, tied chunks took different ranks in different processes, so
    /// the same question on an unchanged store quoted a different passage. Measured 2026-10-31:
    /// 2 distinct outputs in 12 runs of one question.
    private static func bestFirst(_ lhs: ChunkCandidate, _ rhs: ChunkCandidate) -> Bool {
        (lhs.rawScore, lhs.chunk.id.value) < (rhs.rawScore, rhs.chunk.id.value)
    }

    private static func selectCandidates(
        from sorted: [ChunkCandidate],
        limit: Int,
        admittedDomains: Set<Domain>?,
        includeBlockedTopWindowForTelemetry: Bool
    ) -> [ChunkCandidate] {
        // Prevent a single repository's commit log from monopolising the retrieval window
        // before structural objects (.repository, .document, .file, .note) are seen, and prevent
        // blocked domains from starving admitted domains of their `limit` budget while still
        // preserving blocked candidates from the raw top `limit` when telemetry requests them.
        // The per-repository primary commit cap of 2 is a chosen constant, not a measured one.
        var primaryAdmitted: [ChunkCandidate] = []
        var overflowAdmittedCommits: [ChunkCandidate] = []
        var blockedInTopWindow: [ChunkCandidate] = []
        var commitsPerRepo: [String: Int] = [:]

        for (rawIndex, candidate) in sorted.enumerated() {
            if let admittedDomains, !admittedDomains.contains(candidate.object.domain) {
                if includeBlockedTopWindowForTelemetry && rawIndex < limit {
                    blockedInTopWindow.append(candidate)
                }
                continue
            }
            if candidate.object.kind == .commit {
                let repoKey = candidate.object.metadata["repo"] ?? candidate.object.externalID
                let seen = commitsPerRepo[repoKey, default: 0]
                if seen >= 2 {
                    overflowAdmittedCommits.append(candidate)
                    continue
                }
                commitsPerRepo[repoKey] = seen + 1
            }
            primaryAdmitted.append(candidate)
        }

        let admitted = Array((primaryAdmitted + overflowAdmittedCommits).prefix(limit))
        if !includeBlockedTopWindowForTelemetry || admittedDomains == nil {
            return admitted
        }
        return admitted + blockedInTopWindow
    }

    private static func extractTerms(fromMatch match: String) -> [String] {
        match
            .split(separator: "\"")
            .map {
                $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*")))
                    .lowercased()
            }
            .filter { !$0.isEmpty && $0 != "or" && $0 != "and" }
    }

    /// Adjust raw FTS5 BM25 for structural signals `chunk_fts` cannot see on its own:
    /// whether the query matched `object.title`, and whether a `.commit` only matched because
    /// `GitHubConnector` prepends `Owner/Repo` to every commit chunk.
    ///
    /// Returns a negative score (more negative = stronger match), preserving BM25 sign.
    private static func adjustedLexicalScore(
        rawBM25: Double,
        chunk: CoreChunk,
        object: CoreObject,
        queryTerms: [String]
    ) -> Double {
        var strength = max(0.001, -rawBM25)
        guard !queryTerms.isEmpty else { return -strength }

        let titleLower = object.title.lowercased()
        let textLower = chunk.text.lowercased()
        let titleHits = queryTerms.filter { titleLower.contains($0) }.count
        let distinctTextHits = queryTerms.filter { textLower.contains($0) }.count

        if object.kind == .commit {
            // Strip the prepended `Owner/Repo\n` header before checking whether the commit
            // message itself mentions the query terms.
            let bodyWithoutRepoHeader: String
            if let newline = chunk.text.firstIndex(of: "\n") {
                bodyWithoutRepoHeader = String(chunk.text[chunk.text.index(after: newline)...]).lowercased()
            } else {
                bodyWithoutRepoHeader = titleLower
            }
            let messageHits = queryTerms.filter { bodyWithoutRepoHeader.contains($0) }.count
            if messageHits == 0 && titleHits == 0 {
                // Matched only on the prepended `Owner/Repo` line. Keep it reachable, but never
                // ahead of the repository's own overview or README.
                // 0.12 and 0.45 below are chosen constants, not measured ones.
                strength *= 0.12
            } else {
                strength *= 0.45
            }
        } else {
            // 0.55, 1.5, 6.0, and 1.65 below are chosen constants, not measured ones.
            if distinctTextHits > 1 {
                strength *= (1.0 + 0.55 * Double(distinctTextHits - 1))
            }
            if titleHits > 0 {
                strength *= (1.0 + 1.5 * Double(titleHits))
                if queryTerms.contains(where: { titleLower == $0 || titleLower.hasPrefix($0 + " ") || titleLower.hasPrefix($0 + " —") }) {
                    strength += 6.0
                }
            }
            if object.kind == .repository || object.kind == .document {
                // Compensate for FTS5 length normalisation against a corpus whose average chunk
                // length is pulled down by thousands of short notes and 8-word commits.
                strength *= 1.65
            }
        }

        return -strength
    }

    // MARK: - Dense retrieval

    /// Brute-force cosine search over stored vectors.
    ///
    /// Linear in the number of chunks, and that is a deliberate v0.2 choice rather than an
    /// oversight: a personal corpus is tens of thousands of chunks, a dot product over
    /// 512 floats is nanoseconds, and an approximate index would add a tuning surface and
    /// a recall cliff before anything here has been measured. When `doctor` shows this
    /// taking real time, that is the signal to build the index, not before.
    public func denseChunks(
        query: [Float],
        model: String,
        limit: Int,
        admittedDomains: Set<Domain>? = nil,
        includeBlockedTopWindowForTelemetry: Bool = false,
        authoredIn window: DateInterval? = nil
    ) async throws -> [ChunkCandidate] {
        guard !query.isEmpty else { return [] }
        let normalisedQuery = VectorMath.normalise(query)

        // In the SQL for the reason `lexicalChunks` gives: filtering the capped list lets older
        // text fill the cap and leaves nothing to filter. Half open, as there. `DateInterval
        // .contains` includes its end, so the two legs disagreed about a passage at the boundary.
        let dateClause = window == nil ? "" : "AND o.authored_at >= ? AND o.authored_at < ?"
        let dateBindings: [SQLValue] = window.map {
            [.real($0.start.timeIntervalSince1970), .real($0.end.timeIntervalSince1970)]
        } ?? []

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
            WHERE v.model = ? \(dateClause)
            """,
            [.text(model)] + dateBindings
        )

        var scored: [ChunkCandidate] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            guard let blob = row.data("vector") else { continue }
            let values = VectorMath.decode(blob, dimensions: row.requireInt("dims"))
            guard values.count == normalisedQuery.count else { continue }
            let object = CoreObject(prefixedRow: row)
            var sim = Double(VectorMath.dot(normalisedQuery, values))
            if object.kind == .commit {
                // 0.85 is a chosen constant, not a measured one: dampens short commit chunks
                // whose prepended `Owner/Repo` header dominates mean-pooled token vectors.
                sim *= 0.85
            }
            scored.append(ChunkCandidate(
                chunk: CoreChunk(row: row),
                object: object,
                rawScore: sim
            ))
        }
        scored.sort { ($0.rawScore, $1.chunk.id.value) > ($1.rawScore, $0.chunk.id.value) }
        return Self.selectCandidates(
            from: scored,
            limit: limit,
            admittedDomains: admittedDomains,
            includeBlockedTopWindowForTelemetry: includeBlockedTopWindowForTelemetry
        )
    }

    /// All chunks of a floor object, in passage order.
    public func chunks(forObject objectID: ObjectID) async throws -> [CoreChunk] {
        try await database.query(
            "SELECT * FROM chunk WHERE object_id = ? ORDER BY ordinal",
            [.text(objectID.value)]
        ).map(CoreChunk.init(row:))
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
