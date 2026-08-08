import CoreModel
import Foundation

/// Typed persistence for every OpenCore primitive.
///
/// Every SQL string in the project lives in this file or in `Search.swift`. Nothing above
/// this layer knows that SQLite exists, which is what makes the storage substrate
/// replaceable and the derived layers rebuildable.
public struct Store: Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    public static func open(at path: URL? = nil) async throws -> Store {
        let database = try Database(path: path ?? Database.defaultPath())
        try await database.migrate()
        return Store(database: database)
    }
}

// MARK: - Sources

extension Store {
    public func upsert(_ source: Source) async throws {
        try await database.execute(
            """
            INSERT INTO source (id, kind, handle, display_name, default_authority, default_domain, last_synced_at, sync_cursor)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                default_authority = excluded.default_authority,
                default_domain = excluded.default_domain
            """,
            [
                .text(source.id.value), .text(source.kind.rawValue), .text(source.handle),
                .text(source.displayName), .integer(Int64(source.defaultAuthority.rawValue)),
                .text(source.defaultDomain.rawValue), SQLValue(date: source.lastSyncedAt),
                SQLValue(text: source.syncCursor),
            ]
        )
    }

    public func markSynced(_ sourceID: SourceID, at date: Date, cursor: String?) async throws {
        try await database.execute(
            "UPDATE source SET last_synced_at = ?, sync_cursor = ? WHERE id = ?",
            [.real(date.timeIntervalSince1970), SQLValue(text: cursor), .text(sourceID.value)]
        )
    }

    public func sources() async throws -> [Source] {
        try await database.query("SELECT * FROM source ORDER BY kind, handle").map(Source.init(row:))
    }
}

extension Source {
    init(row: Row) {
        self.init(
            kind: SourceKind(rawValue: row.requireString("kind")) ?? .manual,
            handle: row.requireString("handle"),
            displayName: row.requireString("display_name"),
            defaultAuthority: Authority(rawValue: row.requireInt("default_authority")) ?? .thirdPartyRecord,
            defaultDomain: Domain(rawValue: row.requireString("default_domain")) ?? .project,
            lastSyncedAt: row.date("last_synced_at"),
            syncCursor: row.string("sync_cursor")
        )
    }
}

// MARK: - Objects

public struct IngestOutcome: Sendable {
    public var inserted: Int = 0
    public var updated: Int = 0
    public var unchanged: Int = 0

    public var total: Int { inserted + updated + unchanged }
}

extension Store {
    /// Insert or refresh objects in one transaction.
    ///
    /// Content-hash comparison is the reason a re-sync is cheap: an object whose text has
    /// not changed is left completely alone, so its evidence, claims and FTS rows survive
    /// untouched rather than being torn down and rebuilt identically.
    @discardableResult
    public func ingest(_ objects: [CoreObject]) async throws -> IngestOutcome {
        try await database.write { connection in
            var outcome = IngestOutcome()
            for object in objects {
                let existing = try connection.query(
                    "SELECT content_hash FROM object WHERE id = ?",
                    [.text(object.id.value)]
                ).first

                if let existing, existing.requireString("content_hash") == object.contentHash {
                    outcome.unchanged += 1
                    continue
                }

                let metadata = (try? JSONEncoder().encode(object.metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try connection.execute(
                    """
                    INSERT INTO object (id, source_id, kind, external_id, title, text, uri, authored_at,
                                        ingested_at, content_hash, domain, authority, metadata)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        text = excluded.text,
                        uri = excluded.uri,
                        authored_at = excluded.authored_at,
                        ingested_at = excluded.ingested_at,
                        content_hash = excluded.content_hash,
                        metadata = excluded.metadata
                    """,
                    [
                        .text(object.id.value), .text(object.sourceID.value), .text(object.kind.rawValue),
                        .text(object.externalID), .text(object.title), .text(object.text),
                        SQLValue(text: object.uri), SQLValue(date: object.authoredAt),
                        .real(object.ingestedAt.timeIntervalSince1970), .text(object.contentHash),
                        .text(object.domain.rawValue), .integer(Int64(object.authority.rawValue)), .text(metadata),
                    ]
                )
                if existing == nil { outcome.inserted += 1 } else { outcome.updated += 1 }
            }
            return outcome
        }
    }

    public func object(_ id: ObjectID) async throws -> CoreObject? {
        try await database.query("SELECT * FROM object WHERE id = ?", [.text(id.value)]).first.map(CoreObject.init(row:))
    }

    public func objects(ids: [ObjectID]) async throws -> [CoreObject] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try await database
            .query("SELECT * FROM object WHERE id IN (\(placeholders))", ids.map { .text($0.value) })
            .map(CoreObject.init(row:))
    }

    public func objectCount() async throws -> Int {
        try await database.scalarInt("SELECT COUNT(*) FROM object")
    }

    public func objectCountsByKind() async throws -> [(ObjectKind, Int)] {
        try await database.query("SELECT kind, COUNT(*) AS n FROM object GROUP BY kind ORDER BY n DESC")
            .compactMap { row in
                guard let kind = ObjectKind(rawValue: row.requireString("kind")) else { return nil }
                return (kind, row.requireInt("n"))
            }
    }
}

extension CoreObject {
    init(row: Row) {
        let metadata: [String: String] = row.string("metadata")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

        self.init(
            sourceID: SourceID(row.requireString("source_id")),
            kind: ObjectKind(rawValue: row.requireString("kind")) ?? .document,
            externalID: row.requireString("external_id"),
            title: row.requireString("title"),
            text: row.requireString("text"),
            uri: row.string("uri"),
            authoredAt: row.date("authored_at"),
            ingestedAt: row.requireDate("ingested_at"),
            domain: Domain(rawValue: row.requireString("domain")) ?? .project,
            authority: Authority(rawValue: row.requireInt("authority")) ?? .thirdPartyRecord,
            metadata: metadata
        )
    }
}

// MARK: - Evidence

extension Store {
    public func save(_ evidence: [Evidence]) async throws {
        guard !evidence.isEmpty else { return }
        try await database.write { connection in
            for item in evidence {
                try connection.execute(
                    """
                    INSERT INTO evidence (id, object_id, range_start, range_end, snippet, authority)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET snippet = excluded.snippet
                    """,
                    [
                        .text(item.id.value), .text(item.objectID.value),
                        SQLValue(int: item.range?.lowerBound), SQLValue(int: item.range?.upperBound),
                        .text(item.snippet), .integer(Int64(item.authority.rawValue)),
                    ]
                )
            }
        }
    }

    public func evidence(for claimID: ClaimID, stance: Stance? = nil) async throws -> [(Evidence, Stance, Double)] {
        var sql = """
            SELECT e.*, ce.stance AS stance, ce.weight AS weight
            FROM evidence e
            JOIN claim_evidence ce ON ce.evidence_id = e.id
            WHERE ce.claim_id = ?
            """
        var bindings: [SQLValue] = [.text(claimID.value)]
        if let stance {
            sql += " AND ce.stance = ?"
            bindings.append(.text(stance.rawValue))
        }
        sql += " ORDER BY ce.weight DESC"

        return try await database.query(sql, bindings).map { row in
            (
                Evidence(row: row),
                Stance(rawValue: row.requireString("stance")) ?? .supports,
                row.requireDouble("weight")
            )
        }
    }
}

extension Evidence {
    init(row: Row) {
        let range: Range<Int>? = {
            guard let start = row.int("range_start"), let end = row.int("range_end"), start < end else { return nil }
            return start..<end
        }()
        self.init(
            objectID: ObjectID(row.requireString("object_id")),
            range: range,
            snippet: row.requireString("snippet"),
            authority: Authority(rawValue: row.requireInt("authority")) ?? .thirdPartyRecord
        )
    }
}

// MARK: - Entities

extension Store {
    public func upsert(_ entities: [CoreEntity]) async throws {
        guard !entities.isEmpty else { return }
        try await database.write { connection in
            for entity in entities {
                try connection.execute(
                    """
                    INSERT INTO entity (id, kind, canonical_name, domain, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        last_seen_at = MAX(entity.last_seen_at, excluded.last_seen_at),
                        first_seen_at = MIN(entity.first_seen_at, excluded.first_seen_at)
                    """,
                    [
                        .text(entity.id.value), .text(entity.kind.rawValue), .text(entity.canonicalName),
                        .text(entity.domain.rawValue), .real(entity.firstSeenAt.timeIntervalSince1970),
                        .real(entity.lastSeenAt.timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    public func addAliases(_ aliases: [EntityAlias]) async throws {
        guard !aliases.isEmpty else { return }
        try await database.write { connection in
            for alias in aliases {
                try connection.execute(
                    """
                    INSERT INTO entity_alias (entity_id, surface, confidence) VALUES (?, ?, ?)
                    ON CONFLICT(surface, entity_id) DO UPDATE SET confidence = MAX(entity_alias.confidence, excluded.confidence)
                    """,
                    [.text(alias.entityID.value), .text(alias.surface.lowercased()), .real(alias.confidence)]
                )
            }
        }
    }

    public func entity(_ id: EntityID) async throws -> CoreEntity? {
        try await database.query("SELECT * FROM entity WHERE id = ?", [.text(id.value)]).first.map(CoreEntity.init(row:))
    }

    public func entities() async throws -> [CoreEntity] {
        try await database.query("SELECT * FROM entity ORDER BY canonical_name").map(CoreEntity.init(row:))
    }

    /// Resolve a surface form to entities, most confident first.
    public func resolve(surface: String) async throws -> [(CoreEntity, Double)] {
        try await database.query(
            """
            SELECT e.*, a.confidence AS alias_confidence
            FROM entity e JOIN entity_alias a ON a.entity_id = e.id
            WHERE a.surface = ?
            ORDER BY a.confidence DESC
            """,
            [.text(surface.lowercased())]
        ).map { (CoreEntity(row: $0), $0.requireDouble("alias_confidence")) }
    }

    /// Every surface form the graph knows, lowercased.
    ///
    /// Used by domain classification to mask names before keyword scanning, so a project
    /// called OpenClinic does not read as a medical question.
    public func aliasSurfaces() async throws -> Set<String> {
        Set(try await database.query("SELECT DISTINCT surface FROM entity_alias").map { $0.requireString("surface") })
    }

    public func addEdge(from source: EntityID, relation: String, to target: EntityID, weight: Double = 1.0, claim: ClaimID? = nil) async throws {
        try await database.execute(
            """
            INSERT INTO edge (source_entity, relation, target_entity, weight, claim_id) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_entity, relation, target_entity) DO UPDATE SET weight = excluded.weight
            """,
            [.text(source.value), .text(relation), .text(target.value), .real(weight), SQLValue(text: claim?.value)]
        )
    }

    /// Entities within `hops` of `start`, with the hop distance. Used by graph scoring.
    public func neighbourhood(of start: EntityID, hops: Int = 2) async throws -> [EntityID: Int] {
        var distances: [EntityID: Int] = [start: 0]
        var frontier: [EntityID] = [start]

        for hop in 1...max(1, hops) {
            guard !frontier.isEmpty else { break }
            let placeholders = Array(repeating: "?", count: frontier.count).joined(separator: ", ")
            let bindings = frontier.map { SQLValue.text($0.value) }
            let rows = try await database.query(
                """
                SELECT target_entity AS other FROM edge WHERE source_entity IN (\(placeholders))
                UNION
                SELECT source_entity AS other FROM edge WHERE target_entity IN (\(placeholders))
                """,
                bindings + bindings
            )
            var next: [EntityID] = []
            for row in rows {
                let id = EntityID(row.requireString("other"))
                if distances[id] == nil {
                    distances[id] = hop
                    next.append(id)
                }
            }
            frontier = next
        }
        return distances
    }
}

extension CoreEntity {
    init(row: Row) {
        self.init(
            kind: EntityKind(rawValue: row.requireString("kind")) ?? .concept,
            canonicalName: row.requireString("canonical_name"),
            domain: Domain(rawValue: row.requireString("domain")) ?? .project,
            firstSeenAt: row.requireDate("first_seen_at"),
            lastSeenAt: row.requireDate("last_seen_at")
        )
    }
}

// MARK: - Claims

extension Store {
    public func save(_ claims: [CoreClaim]) async throws {
        guard !claims.isEmpty else { return }
        try await database.write { connection in
            for claim in claims {
                try connection.execute(
                    """
                    INSERT INTO claim (id, subject, predicate, object_entity, literal, confidence, authority,
                                       derivation, domain, valid_from, valid_to, observed_at, retracted_at, claim_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        confidence = excluded.confidence,
                        authority = MAX(claim.authority, excluded.authority),
                        valid_to = excluded.valid_to
                    """,
                    [
                        .text(claim.id.value), .text(claim.subject.value), .text(claim.predicate),
                        SQLValue(text: claim.objectEntity?.value), SQLValue(text: claim.literal),
                        .real(claim.confidence), .integer(Int64(claim.authority.rawValue)),
                        .text(claim.derivation.rawValue), .text(claim.domain.rawValue),
                        SQLValue(date: claim.validity.validFrom), SQLValue(date: claim.validity.validTo),
                        .real(claim.validity.observedAt.timeIntervalSince1970),
                        SQLValue(date: claim.validity.retractedAt), .text(claim.claimKey),
                    ]
                )
            }
        }
    }

    public func link(claim: ClaimID, to evidence: EvidenceID, stance: Stance, weight: Double = 1.0) async throws {
        try await database.execute(
            """
            INSERT INTO claim_evidence (claim_id, evidence_id, stance, weight) VALUES (?, ?, ?, ?)
            ON CONFLICT(claim_id, evidence_id) DO UPDATE SET stance = excluded.stance, weight = excluded.weight
            """,
            [.text(claim.value), .text(evidence.value), .text(stance.rawValue), .real(weight)]
        )
    }

    public func claim(_ id: ClaimID) async throws -> CoreClaim? {
        try await database.query("SELECT * FROM claim WHERE id = ?", [.text(id.value)]).first.map(CoreClaim.init(row:))
    }

    public func claims(key: String) async throws -> [CoreClaim] {
        try await database.query(
            "SELECT * FROM claim WHERE claim_key = ? ORDER BY COALESCE(valid_from, observed_at) ASC",
            [.text(key)]
        ).map(CoreClaim.init(row:))
    }

    public func claims(subject: EntityID, currentOnly: Bool = true) async throws -> [CoreClaim] {
        let filter = currentOnly ? "AND retracted_at IS NULL" : ""
        return try await database.query(
            "SELECT * FROM claim WHERE subject = ? \(filter) ORDER BY predicate, observed_at DESC",
            [.text(subject.value)]
        ).map(CoreClaim.init(row:))
    }

    public func allClaims(currentOnly: Bool = true, limit: Int = 500) async throws -> [CoreClaim] {
        let filter = currentOnly ? "WHERE retracted_at IS NULL" : ""
        return try await database.query(
            "SELECT * FROM claim \(filter) ORDER BY observed_at DESC LIMIT ?",
            [.integer(Int64(limit))]
        ).map(CoreClaim.init(row:))
    }

    /// Every distinct `claim_key` that has more than one non-retracted claim. This is the
    /// candidate set for contradiction detection, computed in SQL so the graph layer never
    /// has to load the whole claim table to find conflicts.
    public func contestedClaimKeys() async throws -> [String] {
        try await database.query(
            """
            SELECT claim_key FROM claim
            WHERE retracted_at IS NULL
            GROUP BY claim_key
            HAVING COUNT(*) > 1
            """
        ).map { $0.requireString("claim_key") }
    }

    public func retract(_ id: ClaimID, at date: Date) async throws {
        try await database.execute(
            "UPDATE claim SET retracted_at = ? WHERE id = ? AND retracted_at IS NULL",
            [.real(date.timeIntervalSince1970), .text(id.value)]
        )
    }

    public func claimCount() async throws -> Int {
        try await database.scalarInt("SELECT COUNT(*) FROM claim WHERE retracted_at IS NULL")
    }
}

extension CoreClaim {
    init(row: Row) {
        self.init(
            subject: EntityID(row.requireString("subject")),
            predicate: row.requireString("predicate"),
            objectEntity: row.string("object_entity").map { EntityID($0) },
            literal: row.string("literal"),
            confidence: row.requireDouble("confidence"),
            authority: Authority(rawValue: row.requireInt("authority")) ?? .modelInference,
            derivation: Derivation(rawValue: row.requireString("derivation")) ?? .observed,
            validity: Validity(
                validFrom: row.date("valid_from"),
                validTo: row.date("valid_to"),
                observedAt: row.requireDate("observed_at"),
                retractedAt: row.date("retracted_at")
            ),
            domain: Domain(rawValue: row.requireString("domain")) ?? .project
        )
    }
}

// MARK: - Contradictions, beliefs, corrections

extension Store {
    public func save(_ contradictions: [Contradiction]) async throws {
        guard !contradictions.isEmpty else { return }
        try await database.write { connection in
            for item in contradictions {
                try connection.execute(
                    """
                    INSERT INTO contradiction (id, claim_a, claim_b, kind, resolution, winner, detected_at, reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        resolution = excluded.resolution,
                        winner = excluded.winner,
                        reason = excluded.reason
                    """,
                    [
                        .text(item.id.value), .text(item.claimA.value), .text(item.claimB.value),
                        .text(item.kind.rawValue), .text(item.resolution.rawValue),
                        SQLValue(text: item.winner?.value),
                        .real(item.detectedAt.timeIntervalSince1970), .text(item.reason),
                    ]
                )
            }
        }
    }

    public func contradictions(unresolvedOnly: Bool = false) async throws -> [Contradiction] {
        let filter = unresolvedOnly ? "WHERE resolution = 'unresolved'" : ""
        return try await database.query("SELECT * FROM contradiction \(filter) ORDER BY detected_at DESC")
            .map(Contradiction.init(row:))
    }

    public func save(_ belief: Belief) async throws {
        try await database.execute(
            """
            INSERT INTO belief (id, claim_key, version, claim_id, confidence, authority, valid_from, valid_to,
                                observed_at, retracted_at, supersedes, reason, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(belief.id.value), .text(belief.claimKey), .integer(Int64(belief.version)),
                .text(belief.claimID.value), .real(belief.confidence), .integer(Int64(belief.authority.rawValue)),
                SQLValue(date: belief.validity.validFrom), SQLValue(date: belief.validity.validTo),
                .real(belief.validity.observedAt.timeIntervalSince1970), SQLValue(date: belief.validity.retractedAt),
                SQLValue(text: belief.supersedes?.value), .text(belief.reason),
                .real(belief.decidedAt.timeIntervalSince1970),
            ]
        )
    }

    public func currentBelief(key: String) async throws -> Belief? {
        try await database.query(
            "SELECT * FROM belief WHERE claim_key = ? ORDER BY version DESC LIMIT 1",
            [.text(key)]
        ).first.map(Belief.init(row:))
    }

    public func beliefHistory(key: String) async throws -> [Belief] {
        try await database.query("SELECT * FROM belief WHERE claim_key = ? ORDER BY version ASC", [.text(key)])
            .map(Belief.init(row:))
    }

    /// Every belief decided in a window, newest first. Backs `opencore memory log`.
    public func beliefsDecided(since: Date, until: Date = .distantFuture) async throws -> [Belief] {
        try await database.query(
            "SELECT * FROM belief WHERE decided_at >= ? AND decided_at <= ? ORDER BY decided_at DESC",
            [.real(since.timeIntervalSince1970), .real(min(until.timeIntervalSince1970, Date.distantFuture.timeIntervalSince1970))]
        ).map(Belief.init(row:))
    }

    /// What OpenCore believed at a past instant. Backs `opencore memory checkout`.
    public func beliefs(asOfKnowledge instant: Date) async throws -> [Belief] {
        try await database.query(
            """
            SELECT b.* FROM belief b
            JOIN (
                SELECT claim_key, MAX(version) AS v FROM belief WHERE decided_at <= ? GROUP BY claim_key
            ) latest ON latest.claim_key = b.claim_key AND latest.v = b.version
            ORDER BY b.claim_key
            """,
            [.real(instant.timeIntervalSince1970)]
        ).map(Belief.init(row:))
    }

    public func save(_ correction: Correction) async throws {
        try await database.execute(
            """
            INSERT INTO correction (id, superseded_claim, asserted_claim, authority, reason, prior_failure, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(correction.id.value), SQLValue(text: correction.supersededClaim?.value),
                .text(correction.assertedClaim.value), .integer(Int64(correction.authority.rawValue)),
                .text(correction.reason), SQLValue(text: correction.priorFailure),
                .real(correction.createdAt.timeIntervalSince1970),
            ]
        )
    }
}

extension Contradiction {
    init(row: Row) {
        self.init(
            claimA: ClaimID(row.requireString("claim_a")),
            claimB: ClaimID(row.requireString("claim_b")),
            kind: ContradictionKind(rawValue: row.requireString("kind")) ?? .directConflict,
            resolution: Resolution(rawValue: row.requireString("resolution")) ?? .unresolved,
            winner: row.string("winner").map { ClaimID($0) },
            detectedAt: row.requireDate("detected_at"),
            reason: row.requireString("reason")
        )
    }
}

extension Belief {
    init(row: Row) {
        self.init(
            claimKey: row.requireString("claim_key"),
            version: row.requireInt("version"),
            claimID: ClaimID(row.requireString("claim_id")),
            confidence: row.requireDouble("confidence"),
            authority: Authority(rawValue: row.requireInt("authority")) ?? .modelInference,
            validity: Validity(
                validFrom: row.date("valid_from"),
                validTo: row.date("valid_to"),
                observedAt: row.requireDate("observed_at"),
                retractedAt: row.date("retracted_at")
            ),
            supersedes: row.string("supersedes").map { BeliefID($0) },
            reason: row.requireString("reason"),
            decidedAt: row.requireDate("decided_at")
        )
    }
}

// MARK: - Events

extension Store {
    public func save(_ events: [CoreEvent]) async throws {
        guard !events.isEmpty else { return }
        try await database.write { connection in
            for event in events {
                try connection.execute(
                    """
                    INSERT INTO event (id, subject, verb, detail, occurred_at, domain, authority)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    [
                        .text(event.id.value), .text(event.subject.value), .text(event.verb),
                        .text(event.detail), .real(event.occurredAt.timeIntervalSince1970),
                        .text(event.domain.rawValue), .integer(Int64(event.authority.rawValue)),
                    ]
                )
            }
        }
    }

    public func events(from: Date, to: Date, domains: Set<Domain>? = nil, limit: Int = 200) async throws -> [CoreEvent] {
        var sql = "SELECT * FROM event WHERE occurred_at >= ? AND occurred_at <= ?"
        var bindings: [SQLValue] = [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
        if let domains, !domains.isEmpty {
            let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
            sql += " AND domain IN (\(placeholders))"
            bindings += domains.map { .text($0.rawValue) }
        }
        sql += " ORDER BY occurred_at DESC LIMIT ?"
        bindings.append(.integer(Int64(limit)))
        return try await database.query(sql, bindings).map(CoreEvent.init(row:))
    }
}

extension CoreEvent {
    init(row: Row) {
        self.init(
            subject: EntityID(row.requireString("subject")),
            verb: row.requireString("verb"),
            detail: row.requireString("detail"),
            occurredAt: row.requireDate("occurred_at"),
            domain: Domain(rawValue: row.requireString("domain")) ?? .project,
            authority: Authority(rawValue: row.requireInt("authority")) ?? .thirdPartyRecord
        )
    }
}

// MARK: - Receipts

extension Store {
    public func save(_ receipt: Receipt, evidence: [(EvidenceID, Double)] = [], claims: [ClaimID] = []) async throws {
        let stagesJSON = (try? JSONEncoder().encode(receipt.stages)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try await database.write { connection in
            try connection.execute(
                """
                INSERT INTO receipt (id, query, query_class, domains_admitted, domains_blocked, stages,
                                     objects_searched, objects_retrieved, evidence_admitted, claims_consulted,
                                     contradictions_surfaced, model, objects_transmitted, confidence, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(receipt.id.value), .text(receipt.query), .text(receipt.queryClass.rawValue),
                    .text(receipt.domainsAdmitted.map(\.rawValue).joined(separator: ",")),
                    .text(receipt.domainsBlocked.map(\.rawValue).joined(separator: ",")),
                    .text(stagesJSON),
                    .integer(Int64(receipt.objectsSearched)), .integer(Int64(receipt.objectsRetrieved)),
                    .integer(Int64(receipt.evidenceAdmitted)), .integer(Int64(receipt.claimsConsulted)),
                    .integer(Int64(receipt.contradictionsSurfaced)), SQLValue(text: receipt.model),
                    .integer(Int64(receipt.objectsTransmitted)), SQLValue(double: receipt.confidence),
                    .real(receipt.createdAt.timeIntervalSince1970),
                ]
            )
            for (rank, item) in evidence.enumerated() {
                try connection.execute(
                    "INSERT INTO receipt_evidence (receipt_id, evidence_id, rank, score) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING",
                    [.text(receipt.id.value), .text(item.0.value), .integer(Int64(rank)), .real(item.1)]
                )
            }
            for claim in claims {
                try connection.execute(
                    "INSERT INTO receipt_claim (receipt_id, claim_id) VALUES (?, ?) ON CONFLICT DO NOTHING",
                    [.text(receipt.id.value), .text(claim.value)]
                )
            }
        }
    }

    public func receipts(limit: Int = 20) async throws -> [Receipt] {
        try await database.query("SELECT * FROM receipt ORDER BY created_at DESC LIMIT ?", [.integer(Int64(limit))])
            .map(Receipt.init(row:))
    }

    /// Look a receipt up by its short code (`oc_8f2a91`) or full id.
    public func receipt(code: String) async throws -> Receipt? {
        let bare = code.hasPrefix("oc_") ? String(code.dropFirst(3)) : code
        return try await database.query("SELECT * FROM receipt WHERE id LIKE ? ORDER BY created_at DESC LIMIT 1", [.text(bare + "%")])
            .first.map(Receipt.init(row:))
    }

    /// The evidence a given answer actually used, ranked. This is `opencore trace`.
    public func trace(receipt id: ReceiptID) async throws -> [(Evidence, CoreObject, Double)] {
        let rows = try await database.query(
            """
            SELECT e.*, re.score AS score, o.id AS o_id, o.source_id AS o_source_id, o.kind AS o_kind,
                   o.external_id AS o_external_id, o.title AS o_title, o.text AS o_text, o.uri AS o_uri,
                   o.authored_at AS o_authored_at, o.ingested_at AS o_ingested_at, o.domain AS o_domain,
                   o.authority AS o_authority, o.metadata AS o_metadata
            FROM receipt_evidence re
            JOIN evidence e ON e.id = re.evidence_id
            JOIN object o ON o.id = e.object_id
            WHERE re.receipt_id = ?
            ORDER BY re.rank ASC
            """,
            [.text(id.value)]
        )
        return rows.map { row in
            let object = CoreObject(
                sourceID: SourceID(row.requireString("o_source_id")),
                kind: ObjectKind(rawValue: row.requireString("o_kind")) ?? .document,
                externalID: row.requireString("o_external_id"),
                title: row.requireString("o_title"),
                text: row.requireString("o_text"),
                uri: row.string("o_uri"),
                authoredAt: row.date("o_authored_at"),
                ingestedAt: row.requireDate("o_ingested_at"),
                domain: Domain(rawValue: row.requireString("o_domain")) ?? .project,
                authority: Authority(rawValue: row.requireInt("o_authority")) ?? .thirdPartyRecord
            )
            return (Evidence(row: row), object, row.requireDouble("score"))
        }
    }
}

extension Receipt {
    init(row: Row) {
        let stages: [ReceiptStage] = row.string("stages")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([ReceiptStage].self, from: $0) } ?? []

        func domains(_ column: String) -> [Domain] {
            (row.string(column) ?? "").split(separator: ",").compactMap { Domain(rawValue: String($0)) }
        }

        self.init(
            query: row.requireString("query"),
            queryClass: QueryClass(rawValue: row.requireString("query_class")) ?? .factual,
            domainsAdmitted: domains("domains_admitted"),
            domainsBlocked: domains("domains_blocked"),
            stages: stages,
            objectsSearched: row.requireInt("objects_searched"),
            objectsRetrieved: row.requireInt("objects_retrieved"),
            evidenceAdmitted: row.requireInt("evidence_admitted"),
            claimsConsulted: row.requireInt("claims_consulted"),
            contradictionsSurfaced: row.requireInt("contradictions_surfaced"),
            model: row.string("model"),
            objectsTransmitted: row.requireInt("objects_transmitted"),
            confidence: row.double("confidence"),
            createdAt: row.requireDate("created_at")
        )
    }
}
