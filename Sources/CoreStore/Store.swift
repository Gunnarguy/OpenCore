import CoreModel
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Typed persistence for every OpenCore primitive.
///
/// Every SQL string in the project lives in CoreStore. Nothing above this layer knows that
/// SQLite exists, which is what makes the storage substrate
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

    /// Inspection of an existing snapshot without migrations, writes or file creation.
    public static func openReadOnly(at path: URL) async throws -> Store {
        try await verifiedReadOnly(Database(path: path, readOnly: true))
    }

    /// Caller supplies a self-contained, unchanging copy. Immutable mode prevents SQLite from
    /// consulting live/aliased sidecars or creating WAL/SHM files; never use for a live database.
    public static func openReadOnlySnapshot(at path: URL) async throws -> Store {
        try await verifiedReadOnly(Database(path: path, readOnly: true, immutableSnapshot: true))
    }

    private static func verifiedReadOnly(_ database: Database) async throws -> Store {
        let version = try await database.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migration")
        guard version <= Database.schemaVersion else { throw StoreError.newerSchema(found: version, supported: Database.schemaVersion) }
        guard version == Database.schemaVersion else { throw StoreError.open("this snapshot needs migration before it can be inspected by this build") }
        return Store(database: database)
    }
}

// MARK: - Sources

extension Store {
    public func upsert(_ source: Source) async throws {
        try await database.execute(
            """
            INSERT INTO source (id, kind, handle, display_name, default_authority, default_domain, last_synced_at, sync_cursor, config)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                default_authority = excluded.default_authority,
                default_domain = excluded.default_domain,
                -- Keep the stored config when the caller does not supply one. A connector
                -- constructing a Source in passing must not wipe setup the user did.
                config = COALESCE(excluded.config, source.config)
            """,
            [
                .text(source.id.value), .text(source.kind.rawValue), .text(source.handle),
                .text(source.displayName), .integer(Int64(source.defaultAuthority.rawValue)),
                .text(source.defaultDomain.rawValue), SQLValue(date: source.lastSyncedAt),
                SQLValue(text: source.syncCursor), SQLValue(text: source.config),
            ]
        )
    }

    public func markSynced(_ sourceID: SourceID, at date: Date, cursor: String?) async throws {
        try await database.execute(
            "UPDATE source SET last_synced_at = ?, sync_cursor = ? WHERE id = ?",
            [.real(date.timeIntervalSince1970), SQLValue(text: cursor), .text(sourceID.value)]
        )
    }

    /// Where an incremental fetch should start, or nil to read everything.
    ///
    /// A source with a sync date and no objects has been poisoned by an empty first pass (see
    /// `Source.shouldAdvanceSync`), so its date is ignored rather than trusted.
    public func incrementalStart(for sourceID: SourceID) async throws -> Date? {
        guard let since = try await sources().first(where: { $0.id == sourceID })?.lastSyncedAt else { return nil }
        let held = try await database.scalarInt("SELECT COUNT(*) FROM object WHERE source_id = ?", [.text(sourceID.value)])
        return held > 0 ? since : nil
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
            defaultDomain: Domain(rawValue: row.requireString("default_domain")) ?? .restricted,
            lastSyncedAt: row.date("last_synced_at"),
            syncCursor: row.string("sync_cursor"),
            config: row.string("config")
        )
    }
}

extension Store {
    /// Remove a source and everything derived from it.
    ///
    /// Objects cascade, and so does everything below them. This is the one place a user can
    /// legitimately delete from the floor, because "I no longer want this source" is a
    /// different statement from "I changed my mind about a fact".
    public func removeSource(_ id: SourceID) async throws -> Int {
        let objects = try await database.scalarInt("SELECT COUNT(*) FROM object WHERE source_id = ?", [.text(id.value)])
        try await database.execute("DELETE FROM source WHERE id = ?", [.text(id.value)])
        return objects
    }

    public func source(handle: String, kind: SourceKind) async throws -> Source? {
        try await database.query(
            "SELECT * FROM source WHERE kind = ? AND handle = ?",
            [.text(kind.rawValue), .text(handle)]
        ).first.map(Source.init(row:))
    }
}

// MARK: - Objects

public struct IngestOutcome: Sendable {
    public var inserted: Int = 0
    public var updated: Int = 0
    public var unchanged: Int = 0
    /// Objects whose previous text was preserved into `object_version`. Metadata and policy
    /// repairs can increment `updated` without creating a new text version.
    public var versioned: Int = 0

    public init() {}

    public var total: Int { inserted + updated + unchanged }
}

extension Store {
    /// Insert or refresh objects in one transaction.
    ///
    /// Re-sync skips identical text and metadata. Policy changes are still applied when text
    /// is unchanged; affected interpretations are quarantined until an audited replay.
    @discardableResult
    public func ingest(_ objects: [CoreObject]) async throws -> IngestOutcome {
        try await database.write { connection in
            var outcome = IngestOutcome()
            var needsGlobalLegacyAudit = true
            for incoming in objects {
                var object = incoming
                let existing = try connection.query(
                    "SELECT * FROM object WHERE id = ?",
                    [.text(object.id.value)]
                ).first

                if let existing {
                    object.domain = Self.retainedImportDomain(existing: Domain(rawValue: existing.requireString("domain")) ?? .restricted, proposed: object.domain)
                    object.authority = min(Authority(rawValue: existing.requireInt("authority")) ?? .modelInference, object.authority)
                }
                let contentChanged = existing.map { $0.requireString("content_hash") != object.contentHash } ?? true
                let policyChanged = existing.map {
                    $0.requireString("domain") != object.domain.rawValue || $0.requireInt("authority") != object.authority.rawValue
                } ?? false
                let previousMetadata = existing.flatMap { $0.string("metadata") }.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                var mergedMetadata = previousMetadata.merging(object.metadata) { _, new in new }
                let metadataChanged = mergedMetadata != previousMetadata
                // Dates are compared as stored, never rebuilt. A `Date` keeps seconds since 2001, so
                // a file's sub-second mtime does not survive the trip through the 1970-based column:
                // 33 of 102 real mtimes came back unequal, measured 2026-10-31. Comparing the rebuilt
                // date called about a third of unchanged files changed on every re-read, and wrote
                // presentation history onto objects nothing had touched.
                let presentationChanged = existing.map {
                    $0.requireString("title") != object.title || $0.string("uri") != object.uri
                        || $0.double("authored_at") != object.authoredAt?.timeIntervalSince1970
                } ?? false
                let containerChanged = ["folder", "list", "root"].contains { previousMetadata[$0] != mergedMetadata[$0] }
                if let existing, !contentChanged, presentationChanged || containerChanged {
                    var history = ObjectPresentation.history(in: previousMetadata)
                    let prior = ObjectPresentation(object: CoreObject(row: existing))
                    if !history.contains(prior) { history.append(prior) }
                    mergedMetadata[ObjectPresentation.metadataKey] = (try? JSONEncoder().encode(history)).flatMap { String(data: $0, encoding: .utf8) }
                }
                if existing != nil, !contentChanged, !policyChanged, !metadataChanged, !presentationChanged {
                    outcome.unchanged += 1
                    continue
                }

                // Keep what it used to say, before the update below overwrites it.
                //
                // This is the floor doing its job. Without it an upsert destroyed the only
                // record of an object's previous content, and every claim derived from that
                // content became unreconstructible: a `rebuild` then produced a smaller graph
                // than the one it replaced and reported success. Measured 2026-08-12, that
                // silently deleted the store's only contradiction.
                //
                // `INSERT OR IGNORE` because the primary key is (object, content hash): an
                // object that flips back to earlier content is the same version returning, not
                // a new one, and recording it twice would double-derive from it on replay.
                if let existing, contentChanged {
                    try connection.execute(
                        """
                        INSERT OR IGNORE INTO object_version
                            (object_id, content_hash, title, text, uri, authored_at, ingested_at,
                             domain, authority, metadata, superseded_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(object.id.value),
                            .text(existing.requireString("content_hash")),
                            .text(existing.requireString("title")),
                            .text(existing.requireString("text")),
                            SQLValue(text: existing.string("uri")),
                            SQLValue(date: existing.date("authored_at")),
                            .real(existing.requireDate("ingested_at").timeIntervalSince1970),
                            .text(existing.requireString("domain")),
                            .integer(Int64(existing.requireInt("authority"))),
                            .text(existing.string("metadata") ?? "{}"),
                            .real(object.ingestedAt.timeIntervalSince1970),
                        ]
                    )
                    outcome.versioned += 1
                }

                if let existing, policyChanged {
                    mergedMetadata = try Self.repairPolicy(
                        objectID: object.id, existing: existing, domain: object.domain,
                        authority: object.authority, reason: "connector reclassification", metadata: mergedMetadata,
                        connection: connection, auditLegacyGlobally: needsGlobalLegacyAudit
                    ).metadata
                    needsGlobalLegacyAudit = false
                }
                let metadata = Self.encodeMetadata(mergedMetadata)
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
                        domain = excluded.domain,
                        authority = excluded.authority,
                        metadata = excluded.metadata
                    """,
                    [
                        .text(object.id.value), .text(object.sourceID.value), .text(object.kind.rawValue),
                        .text(object.externalID), .text(object.title), .text(object.text),
                        SQLValue(text: object.uri), SQLValue(date: object.authoredAt),
                        .real((contentChanged ? object.ingestedAt : existing?.requireDate("ingested_at") ?? object.ingestedAt).timeIntervalSince1970), .text(object.contentHash),
                        .text(object.domain.rawValue), .integer(Int64(object.authority.rawValue)), .text(metadata),
                    ]
                )
                if existing == nil { outcome.inserted += 1 } else { outcome.updated += 1 }
            }
            return outcome
        }
    }

    public struct ObjectPolicyRepair: Sendable {
        public let objectID: ObjectID
        public let domain: Domain
        public let authority: Authority
        public let reason: String
        public init(objectID: ObjectID, domain: Domain, authority: Authority, reason: String) {
            self.objectID = objectID; self.domain = domain; self.authority = authority; self.reason = reason
        }
    }

    public struct PolicyRepairReport: Sendable {
        public var objectsChanged = 0
        public var versionsChanged = 0
        public var claimsQuarantined = 0
        public var objectsPendingRebuild = 0
        public var legacySnapshotsAdded = 0
        public var requiresRebuild: Bool { claimsQuarantined > 0 || objectsPendingRebuild > 0 || legacySnapshotsAdded > 0 }
    }

    /// Makes the consistent snapshot itself instead of trusting a caller-supplied file's
    /// header. The destination must be new; exclusive creation rejects symlink/hardlink
    /// aliases to the active database and never overwrites another backup.
    public func createPolicyRepairBackup(at url: URL) async throws {
        try await database.createPolicyRepairBackup(at: url)
    }

    /// An explicit, dry-run-first repair. Text, version content, metadata, corrections and
    /// receipts survive. Existing interpretations are quarantined rather than assigned an
    /// invented new confidence or provenance. A separately audited rebuild is still required.
    public func reclassifyObjects(_ repairs: [ObjectPolicyRepair], dryRun: Bool = true) async throws -> PolicyRepairReport {
        try await database.write { connection in
            var report = PolicyRepairReport()
            var affectedClaims: Set<String> = []
            var seenRepairIDs: Set<ObjectID> = []
            let uniqueRepairs = repairs.filter { seenRepairIDs.insert($0.objectID).inserted }
            // Unchanged safe candidates remain independent proof even when the CLI scans
            // their source in this same batch. Exclude only floors actually changing policy.
            let repairingIDs = Set(try uniqueRepairs.compactMap { repair -> String? in
                guard let row = try connection.query("SELECT * FROM object WHERE id = ?", [.text(repair.objectID.value)]).first else { return nil }
                let current = CoreObject(row: row)
                if Self.retainedImportDomain(existing: current.domain, proposed: repair.domain) != current.domain || min(current.authority, repair.authority) != current.authority {
                    return repair.objectID.value
                }
                let versions = try connection.query("SELECT domain, authority FROM object_version WHERE object_id = ?", [.text(repair.objectID.value)])
                return versions.contains {
                    Self.retainedImportDomain(existing: Domain(rawValue: $0.requireString("domain")) ?? .restricted, proposed: repair.domain).rawValue != $0.requireString("domain")
                        || min($0.requireInt("authority"), repair.authority.rawValue) != $0.requireInt("authority")
                } ? repair.objectID.value : nil
            })
            let timelineProof: [String: Set<Domain>]
            if dryRun { timelineProof = [:] }
            else { timelineProof = try Self.independentTimelineProof(excluding: repairingIDs, connection: connection) }
            var needsGlobalLegacyAudit = true
            for repair in uniqueRepairs {
                guard let existing = try connection.query("SELECT * FROM object WHERE id = ?", [.text(repair.objectID.value)]).first else { continue }
                let current = CoreObject(row: existing)
                let domain = Self.retainedImportDomain(existing: current.domain, proposed: repair.domain)
                let authority = min(current.authority, repair.authority)
                let versions = try connection.query("SELECT * FROM object_version WHERE object_id = ?", [.text(repair.objectID.value)])
                let versionChanges = versions.filter {
                    Self.retainedImportDomain(existing: Domain(rawValue: $0.requireString("domain")) ?? .restricted, proposed: repair.domain).rawValue != $0.requireString("domain")
                        || min($0.requireInt("authority"), repair.authority.rawValue) != $0.requireInt("authority")
                }.count
                let changed = current.domain != domain || current.authority != authority
                if current.metadata["classification_requires_rebuild"] == "true" || changed || versionChanges > 0 { report.objectsPendingRebuild += 1 }
                guard changed || versionChanges > 0 else { continue }
                report.objectsChanged += changed ? 1 : 0
                report.versionsChanged += versionChanges
                for row in try connection.query("SELECT DISTINCT ce.claim_id FROM claim_evidence ce JOIN evidence e ON e.id = ce.evidence_id WHERE e.object_id = ?", [.text(repair.objectID.value)]) {
                    affectedClaims.insert(row.requireString("claim_id"))
                }
                if dryRun { continue }
                let result = try Self.repairPolicy(objectID: repair.objectID, existing: existing, domain: domain, authority: authority, reason: repair.reason, metadata: current.metadata, connection: connection, repairingIDs: repairingIDs, provenTimelineEvents: timelineProof, auditLegacyGlobally: needsGlobalLegacyAudit)
                needsGlobalLegacyAudit = false
                report.legacySnapshotsAdded += result.legacySnapshotsAdded
                try connection.execute("UPDATE object SET domain = ?, authority = ?, metadata = ? WHERE id = ?", [.text(domain.rawValue), .integer(Int64(authority.rawValue)), .text(Self.encodeMetadata(result.metadata)), .text(repair.objectID.value)])
            }
            report.claimsQuarantined = affectedClaims.count
            return report
        }
    }

    /// Automated imports can restrict an existing compartment, never promote a private
    /// source to project/public by a filename guess. Explicit retagging needs its own action.
    private static func retainedImportDomain(existing: Domain, proposed: Domain) -> Domain {
        if existing == proposed || existing == .restricted { return existing }
        if proposed == .restricted { return .restricted }
        if existing.isSensitive { return existing }
        if proposed.isSensitive { return proposed }
        if existing == .publicRecord { return proposed }
        if existing == .project, [.personal, .work].contains(proposed) { return proposed }
        if [.personal, .work].contains(existing), [.project, .publicRecord].contains(proposed) { return existing }
        return .restricted
    }

    private static func encodeMetadata(_ metadata: [String: String]) -> String {
        (try? JSONEncoder().encode(metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func policyAudit(_ metadata: [String: String], domain: String, authority: Int, reason: String) -> [String: String] {
        var result = metadata
        let entry = "domain=\(domain),authority=\(authority),reason=\(reason)"
        var history = metadata["classification_history"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        if !history.contains(entry) { history.append(entry) }
        result["classification_history"] = (try? JSONEncoder().encode(history)).flatMap { String(data: $0, encoding: .utf8) }
        result["classification_requires_rebuild"] = "true"
        return result
    }

    private static func repairPolicy(
        objectID: ObjectID, existing: Row, domain: Domain, authority: Authority, reason: String,
        metadata: [String: String], connection: Connection, repairingIDs: Set<String> = [],
        provenTimelineEvents: [String: Set<Domain>]? = nil, auditLegacyGlobally: Bool = true
    ) throws -> (metadata: [String: String], versions: Int, legacySnapshotsAdded: Int) {
        var updated = policyAudit(metadata, domain: existing.requireString("domain"), authority: existing.requireInt("authority"), reason: reason)
        let versions = try connection.query("SELECT * FROM object_version WHERE object_id = ?", [.text(objectID.value)])
        var eventObjects = [CoreObject(row: existing)]
        for version in versions {
            let oldMetadata = version.string("metadata").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            var oldObject = CoreObject(row: existing)
            oldObject.title = version.requireString("title"); oldObject.authoredAt = version.date("authored_at"); oldObject.metadata = oldMetadata
            eventObjects.append(oldObject)
            let versionDomain = retainedImportDomain(existing: Domain(rawValue: version.requireString("domain")) ?? .restricted, proposed: domain)
            let versionAuthority = min(version.requireInt("authority"), authority.rawValue)
            guard version.requireString("domain") != versionDomain.rawValue || version.requireInt("authority") != versionAuthority else { continue }
            let audited = policyAudit(oldMetadata, domain: version.requireString("domain"), authority: version.requireInt("authority"), reason: reason)
            try connection.execute("UPDATE object_version SET domain = ?, authority = ?, metadata = ? WHERE object_id = ? AND content_hash = ?", [.text(versionDomain.rawValue), .integer(Int64(versionAuthority)), .text(encodeMetadata(audited)), .text(objectID.value), .text(version.requireString("content_hash"))])
        }
        let claims = try connection.query("SELECT DISTINCT c.id, c.subject, c.object_entity FROM claim c JOIN claim_evidence ce ON ce.claim_id = c.id JOIN evidence e ON e.id = ce.evidence_id WHERE e.object_id = ?", [.text(objectID.value)])
        var entities = Set(claims.flatMap { [$0.string("subject"), $0.string("object_entity")].compactMap { $0 } })
        var eventIDs: Set<String> = []
        for object in eventObjects {
            for event in ObjectPresentation.timelineEvents(for: object) {
                eventIDs.insert(event.id.value); entities.insert(event.subject.value)
            }
        }
        for id in eventIDs { try connection.execute("UPDATE event SET domain = 'restricted' WHERE id = ?", [.text(id)]) }
        let excludedObjects = repairingIDs.union([objectID.value])
        let provenEvents: [String: Set<Domain>]
        if let provenTimelineEvents { provenEvents = provenTimelineEvents }
        else { provenEvents = try independentTimelineProof(excluding: excludedObjects, connection: connection) }
        var legacy: [CoreEvent] = []
        var safeTimelineContainers: Set<String> = []
        var legacyIDs: Set<EventID> = []
        // Older releases could overwrite a folder/title/date without preserving its floor
        // descriptor. There is then no truthful way to attribute the orphan by the current
        // container alone. Audit every legacy file/note event and retain visibility only
        // when an independent admitted floor proves that exact deterministic event.
        let candidateIDs = entities.sorted()
        let placeholders = candidateIDs.map { _ in "?" }.joined(separator: ",")
        let bindings = candidateIDs.map { SQLValue.text($0) }
        let entityRows: [Row]
        let eventRows: [Row]
        if auditLegacyGlobally {
            entityRows = try connection.query("SELECT * FROM entity")
            eventRows = try connection.query("SELECT * FROM event WHERE verb IN ('noted', 'edited', 'wrote')")
        } else if candidateIDs.isEmpty {
            entityRows = []; eventRows = []
        } else {
            entityRows = try connection.query("SELECT * FROM entity WHERE id IN (\(placeholders))", bindings)
            eventRows = try connection.query("SELECT * FROM event WHERE subject IN (\(placeholders)) AND verb IN ('noted', 'edited', 'wrote')", bindings)
        }
        let containers = Dictionary(uniqueKeysWithValues: entityRows.map { ($0.requireString("id"), $0) })
        for row in eventRows {
            let event = CoreEvent(row: row)
            if eventIDs.contains(event.id.value) { continue }
            let containerID = event.subject.value
            let originalDomain = containers[containerID].flatMap { Domain(rawValue: $0.requireString("domain")) } ?? .restricted
            let allowed: Set<Domain> = [.project, .publicRecord].contains(originalDomain) ? [.project, .publicRecord] : originalDomain.readableDomains
            if let proof = provenEvents[event.id.value], !proof.isDisjoint(with: allowed) {
                safeTimelineContainers.insert(containerID)
                continue
            }
            entities.insert(containerID)
            if event.domain == .restricted { continue }
            if legacyIDs.insert(event.id).inserted { legacy.append(event) }
            try connection.execute("UPDATE event SET domain = 'restricted' WHERE id = ?", [.text(event.id.value)])
        }
        let legacySnapshotsAdded = try preserveUnprovenLegacyEvents(legacy, connection: connection)
        let affectedClaimIDs = Set(claims.map { $0.requireString("id") })
        for entityID in entities {
            guard let entity = try connection.query("SELECT * FROM entity WHERE id = ?", [.text(entityID)]).first else { continue }
            let currentDomain = Domain(rawValue: entity.requireString("domain")) ?? .restricted
            let safeDomains: Set<Domain> = [.project, .publicRecord].contains(currentDomain) ? [.project, .publicRecord] : currentDomain.readableDomains.subtracting([.restricted])
            let independentClaim = try connection.query(
                """
                SELECT DISTINCT c.id, c.domain AS claim_domain, o.id AS object_id, o.domain AS object_domain
                FROM claim c JOIN claim_evidence ce ON ce.claim_id = c.id AND ce.stance = 'supports'
                JOIN evidence e ON e.id = ce.evidence_id JOIN object o ON o.id = e.object_id
                WHERE (c.subject = ? OR c.object_entity = ?) AND c.retracted_at IS NULL
                  AND c.domain != 'restricted' AND o.domain != 'restricted'
                """, [.text(entityID), .text(entityID)]
            ).contains { row in
                !affectedClaimIDs.contains(row.requireString("id"))
                    && !excludedObjects.contains(row.requireString("object_id"))
                    && Domain(rawValue: row.requireString("claim_domain")).map { safeDomains.contains($0) } == true
                    && Domain(rawValue: row.requireString("object_domain")).map { safeDomains.contains($0) } == true
            }
            if !independentClaim && !safeTimelineContainers.contains(entityID) {
                try connection.execute("UPDATE entity SET domain = 'restricted' WHERE id = ?", [.text(entityID)])
            }
        }
        for claim in claims { try connection.execute("UPDATE claim SET domain = 'restricted' WHERE id = ?", [.text(claim.requireString("id"))]) }
        try connection.execute("UPDATE evidence SET authority = MIN(authority, ?) WHERE object_id = ?", [.integer(Int64(authority.rawValue)), .text(objectID.value)])
        // Aliases have no per-object provenance. Affected shared entities remain usable by
        // canonical name, but external clients must not receive or resolve unproven aliases.
        let prior = metadata["classification_affected_entities"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        updated["classification_affected_entities"] = (try? JSONEncoder().encode(entities.union(prior).sorted())).flatMap { String(data: $0, encoding: .utf8) }
        return (updated, versions.count, legacySnapshotsAdded)
    }

    private static func independentTimelineProof(excluding excluded: Set<String>, connection: Connection) throws -> [String: Set<Domain>] {
        var proof: [String: Set<Domain>] = [:]
        for row in try connection.query("SELECT * FROM object") where !excluded.contains(row.requireString("id")) {
            for event in ObjectPresentation.timelineEvents(for: CoreObject(row: row)) where event.domain != .restricted {
                proof[event.id.value, default: []].insert(event.domain)
            }
        }
        let historical = try connection.query("""
            SELECT o.id AS parent_id, o.domain AS parent_domain, o.source_id, o.kind,
                   o.external_id, v.title, v.text, v.uri, v.authored_at,
                   v.ingested_at, v.domain, v.authority, v.metadata
            FROM object_version v JOIN object o ON o.id = v.object_id
            """)
        for row in historical where !excluded.contains(row.requireString("parent_id")) {
            var object = CoreObject(row: row)
            if let parent = Domain(rawValue: row.requireString("parent_domain")),
               parent == .restricted || (!object.domain.isSensitive && parent != .project && parent != .publicRecord) {
                object.domain = parent
            }
            for event in ObjectPresentation.timelineEvents(for: object) where event.domain != .restricted {
                proof[event.id.value, default: []].insert(event.domain)
            }
        }
        return proof
    }

    /// The source repair writes unproven legacy rows to. It holds objects and is never synced.
    static let privacyLedgerHandle = "privacy-repair-ledger"

    /// Uncertain legacy rows are observations of an older store, not evidence about the
    /// repaired project's content. Keep them in their own immutable restricted floor objects
    /// so a project artifact never acquires somebody else's private metadata by repair.
    private static func preserveUnprovenLegacyEvents(_ events: [CoreEvent], connection: Connection) throws -> Int {
        guard !events.isEmpty else { return 0 }
        let source = Source(kind: .manual, handle: privacyLedgerHandle, displayName: "Unproven legacy timeline records", defaultAuthority: .generatedSummary, defaultDomain: .restricted)
        try connection.execute("INSERT OR IGNORE INTO source (id, kind, handle, display_name, default_authority, default_domain) VALUES (?, ?, ?, ?, ?, ?)", [.text(source.id.value), .text(source.kind.rawValue), .text(source.handle), .text(source.displayName), .integer(Int64(source.defaultAuthority.rawValue)), .text(source.defaultDomain.rawValue)])
        var added = 0
        for event in events {
            let body = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            let snapshot = String(decoding: try JSONEncoder().encode([event]), as: UTF8.self)
            let object = CoreObject(sourceID: source.id, kind: .document, externalID: event.id.value,
                title: "Unproven legacy timeline record", text: body, domain: .restricted,
                authority: .generatedSummary, metadata: [ObjectPresentation.legacyEventsKey: snapshot, "legacy_provenance": "original floor unknown", "classification_requires_rebuild": "true", "classification_affected_entities": String(decoding: try JSONEncoder().encode([event.subject.value]), as: UTF8.self)])
            added += try connection.execute("""
                INSERT OR IGNORE INTO object (id, source_id, kind, external_id, title, text, uri,
                    authored_at, ingested_at, content_hash, domain, authority, metadata)
                VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?)
                """, [.text(object.id.value), .text(source.id.value), .text(object.kind.rawValue), .text(object.externalID), .text(object.title), .text(object.text), .real(object.ingestedAt.timeIntervalSince1970), .text(object.contentHash), .text(object.domain.rawValue), .integer(Int64(object.authority.rawValue)), .text(encodeMetadata(object.metadata))])
        }
        return added
    }

    public func object(_ id: ObjectID) async throws -> CoreObject? {
        try await database.query("SELECT * FROM object WHERE id = ?", [.text(id.value)]).first.map(CoreObject.init(row:))
    }

    /// Merge metadata keys onto an existing `CoreObject` without altering its `text` or
    /// `contentHash`. Used by `ModelClaimProposer` to persist byte-verified
    /// `model_proposed_claims` on the floor object so `IngestPipeline` and `opencore rebuild`
    /// can deterministically reconstruct `Authority.modelInference` claims.
    public func updateObjectMetadata(_ id: ObjectID, merging entries: [String: String]) async throws -> CoreObject? {
        guard var current = try await object(id) else { return nil }
        for (key, value) in entries {
            current.metadata[key] = value
        }
        let encoded = (try? JSONEncoder().encode(current.metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await database.execute(
            "UPDATE object SET metadata = ? WHERE id = ?",
            [.text(encoded), .text(id.value)]
        )
        return current
    }

    /// Objects whose title or text mentions `surface`, ordered newest first.
    public func objectsMentioning(_ surface: String, limit: Int = 6) async throws -> [CoreObject] {
        let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed)%"
        return try await database.query(
            """
            SELECT * FROM object
            WHERE title LIKE ? OR text LIKE ?
            ORDER BY COALESCE(authored_at, ingested_at) DESC
            LIMIT ?
            """,
            [.text(pattern), .text(pattern), .integer(Int64(max(1, limit)))]
        ).map(CoreObject.init(row:))
    }

    /// Filters run in SQLite before the limit, using the same labels and authored month
    /// as CorpusSnapshot, so a global distribution card is not a search of the latest page.
    public func recentObjects(
        kind: ObjectKind? = nil, domain: Domain? = nil, sourceName: String? = nil,
        authoredMonth: String? = nil, searchText: String? = nil, limit: Int = 60
    ) async throws -> [CoreObject] {
        var clauses: [String] = []
        var bindings: [SQLValue] = []
        if let kind { clauses.append("o.kind = ?"); bindings.append(.text(kind.rawValue)) }
        if let domain { clauses.append("o.domain = ?"); bindings.append(.text(domain.rawValue)) }
        if let sourceName { clauses.append("COALESCE(s.display_name, o.source_id) = ?"); bindings.append(.text(sourceName)) }
        if let authoredMonth { clauses.append("strftime('%Y-%m', o.authored_at, 'unixepoch') = ?"); bindings.append(.text(authoredMonth)) }
        if let searchText, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clauses.append("(instr(lower(o.title), lower(?)) > 0 OR instr(lower(o.text), lower(?)) > 0 OR instr(lower(COALESCE(o.uri, '')), lower(?)) > 0)")
            bindings += [.text(searchText), .text(searchText), .text(searchText)]
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        bindings.append(.integer(Int64(max(1, limit))))
        return try await database.query(
            """
            SELECT o.* FROM object o LEFT JOIN source s ON s.id = o.source_id
            \(whereSQL)
            ORDER BY COALESCE(o.authored_at, o.ingested_at) DESC
            LIMIT ?
            """, bindings
        ).map(CoreObject.init(row:))
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

    /// Objects with exactly this title.
    ///
    /// For the eval harness, which keys its expected answers to titles rather than ids:
    /// object ids are content-derived hashes, so a benchmark written against them would be
    /// unreadable and would break the moment an object's text changed. Returns every match,
    /// because a title is not unique by construction.
    public func objectIDs(title: String) async throws -> [ObjectID] {
        try await database
            .query("SELECT id FROM object WHERE title = ?", [.text(title)])
            .map { ObjectID($0.requireString("id")) }
    }

    public func objectCountsByKind() async throws -> [(ObjectKind, Int)] {
        try await database.query("SELECT kind, COUNT(*) AS n FROM object GROUP BY kind ORDER BY n DESC")
            .compactMap { row in
                guard let kind = ObjectKind(rawValue: row.requireString("kind")) else { return nil }
                return (kind, row.requireInt("n"))
            }
    }

    /// Objects of one kind, grouped and counted by one metadata key.
    ///
    /// This exists because **a counting question cannot be answered from a passage window.**
    /// The answer path hands the model six passages, so asked "how many of my apps are built
    /// in Swift" it counts the Swift ones among those six and reports that number with a
    /// straight face and a valid receipt. Measured 2026-08-10: it answered 2 against a true
    /// 12. A count has to be computed over the whole table, which means here.
    ///
    /// Objects carrying no value under `key` are **not** bucketed as "unknown". Absent
    /// metadata is unmeasured, and a bucket would put a number on something never observed.
    /// `total` is returned alongside so a caller can state the shortfall rather than implying
    /// the groups are exhaustive.
    public func objectCountsByMetadata(
        kind: ObjectKind, key: String, domains: Set<Domain>
    ) async throws -> MetadataBreakdown {
        guard !domains.isEmpty else { return MetadataBreakdown(kind: kind, key: key, counts: [], total: 0) }
        // Bound as a value, never interpolated: `key` reaches here from a query string.
        let path = "$.\(key)"
        let (clause, domainValues) = Self.domainFilter(domains)
        let counts = try await database.query(
            """
            SELECT json_extract(metadata, ?) AS value, COUNT(*) AS n FROM object
            WHERE kind = ? AND json_extract(metadata, ?) IS NOT NULL AND \(clause)
            GROUP BY value ORDER BY n DESC, value ASC
            """,
            [.text(path), .text(kind.rawValue), .text(path)] + domainValues
        ).map { MetadataCount(value: $0.requireString("value"), count: $0.requireInt("n")) }

        return MetadataBreakdown(
            kind: kind, key: key, counts: counts,
            total: try await objectCount(kind: kind, domains: domains)
        )
    }

    /// Metadata keys carried by objects of one kind, most common first.
    ///
    /// Exists so a counting question can be resolved against **what the store actually holds**
    /// rather than against a hardcoded list of fields. A list in code goes stale the first time
    /// a connector learns to record something new, and the symptom is a question that used to
    /// be answerable quietly becoming unanswerable.
    ///
    /// `minimumObjects` drops keys carried by only a handful of objects, which are far more
    /// often a connector quirk than a countable facet.
    public func metadataKeys(
        kind: ObjectKind, domains: Set<Domain>, minimumObjects: Int = 4
    ) async throws -> [String] {
        guard !domains.isEmpty else { return [] }
        let (clause, domainValues) = Self.domainFilter(domains)
        return try await database.query(
            """
            SELECT k.key AS key, COUNT(*) AS n FROM object, json_each(object.metadata) k
            WHERE object.kind = ? AND \(clause)
            GROUP BY k.key HAVING n >= ? ORDER BY n DESC, key ASC
            """,
            [.text(kind.rawValue)] + domainValues + [.integer(Int64(minimumObjects))]
        ).map { $0.requireString("key") }
    }

    public func objectCount(kind: ObjectKind, domains: Set<Domain>) async throws -> Int {
        guard !domains.isEmpty else { return 0 }
        let (clause, domainValues) = Self.domainFilter(domains)
        return try await database.scalarInt(
            "SELECT COUNT(*) FROM object WHERE kind = ? AND \(clause)",
            [.text(kind.rawValue)] + domainValues
        )
    }

    /// The domain allowlist as a bound `IN` clause.
    ///
    /// `domains` is **required** on every counting method above rather than defaulting to all
    /// of them, because the safe default is the one a caller cannot forget to pass. A count is
    /// a disclosure: "you have 14 medical appointments" answers a question the firewall exists
    /// to refuse, and it does so without retrieving a single passage the firewall would have
    /// blocked. Only the domain values are interpolated, and only as `?` placeholders.
    static func domainFilter(_ domains: Set<Domain>) -> (clause: String, values: [SQLValue]) {
        let ordered = domains.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ", ")
        return ("domain IN (\(placeholders))", ordered.map { .text($0) })
    }
}

/// One group in a metadata breakdown.
public struct MetadataCount: Sendable, Hashable, Codable {
    public var value: String
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// A counted grouping over one metadata key, with the part it could not classify kept visible.
public struct MetadataBreakdown: Sendable, Hashable, Codable {
    public var kind: ObjectKind
    public var key: String
    /// Most frequent first. Objects with no value for `key` are absent, not bucketed.
    public var counts: [MetadataCount]
    /// Every object of this kind, including the ones no group accounts for.
    public var total: Int

    public init(kind: ObjectKind, key: String, counts: [MetadataCount], total: Int) {
        self.kind = kind
        self.key = key
        self.counts = counts
        self.total = total
    }

    /// Objects of this kind carrying no value for `key`. Reported rather than hidden: "12 of
    /// 22" and "12 of 12" are different answers and only one of them is true.
    public var unclassified: Int { total - counts.reduce(0) { $0 + $1.count } }

    /// A yes/no field. Its name is the question ("archived", "completed"), and the buckets are
    /// the answer, which is the opposite of a field like `language` where the values are what
    /// a question names.
    public var isBoolean: Bool {
        !counts.isEmpty && counts.allSatisfy { $0.value == "true" || $0.value == "false" }
    }

    public func count(matching value: String) -> Int {
        counts.first { $0.value.caseInsensitiveCompare(value) == .orderedSame }?.count ?? 0
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
            domain: Domain(rawValue: row.requireString("domain")) ?? .restricted,
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
            try Self.saveEvidence(evidence, connection: connection)
        }
    }

    private static func saveEvidence(_ evidence: [Evidence], connection: Connection) throws {
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

    public func evidence(id: EvidenceID) async throws -> Evidence? {
        try await database.query("SELECT * FROM evidence WHERE id = ?", [.text(id.value)]).first.map(Evidence.init(row:))
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
        sql += " ORDER BY ce.weight DESC, e.id ASC"

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
        // The stored id, because a row made with `reading` can't be re-derived from its columns.
        id = EvidenceID(row.requireString("id"))
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

    private func entitiesWithUnprovenExternalAliases() async throws -> Set<EntityID> {
        let rows = try await database.query("SELECT metadata FROM object WHERE metadata LIKE '%classification_affected_entities%'")
        var ids: Set<EntityID> = []
        for row in rows {
            let metadata = row.string("metadata").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            let values = metadata["classification_affected_entities"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            ids.formUnion(values.map { EntityID($0) })
        }
        return ids
    }

    /// Canonical names remain usable for mixed-source entities; their aliases have no
    /// source provenance and cannot safely be attributed to the independently public facts.
    public func resolveForExternalCaller(surface: String) async throws -> [(CoreEntity, Double)] {
        let mixed = try await entitiesWithUnprovenExternalAliases()
        let needle = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = try await resolve(surface: needle).filter { entity, _ in
            !mixed.contains(entity.id) || entity.canonicalName.lowercased() == needle
        }
        if !matches.isEmpty { return matches }
        return try await database.query("SELECT * FROM entity WHERE lower(canonical_name) = ?", [.text(needle)]).map { (CoreEntity(row: $0), 1.0) }
    }

    public func aliasesForExternalCaller(for id: EntityID) async throws -> [String] {
        if try await entitiesWithUnprovenExternalAliases().contains(id) {
            return try await entity(id).map { [$0.canonicalName] } ?? []
        }
        return try await aliases(for: id)
    }

    public func aliasSurfacesForExternalCaller() async throws -> Set<String> {
        let mixed = try await entitiesWithUnprovenExternalAliases()
        let rows = try await database.query("SELECT a.entity_id, a.surface, e.canonical_name, e.domain FROM entity_alias a JOIN entity e ON e.id = a.entity_id")
        return Set(rows.compactMap { row in
            guard let domain = Domain(rawValue: row.requireString("domain")), !domain.isSensitive else { return nil }
            let surface = row.requireString("surface")
            if mixed.contains(EntityID(row.requireString("entity_id"))), surface.lowercased() != row.requireString("canonical_name").lowercased() { return nil }
            return surface
        })
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
            domain: Domain(rawValue: row.requireString("domain")) ?? .restricted,
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
                        confidence = CASE WHEN excluded.authority > claim.authority OR (excluded.authority = claim.authority AND excluded.confidence > claim.confidence) THEN excluded.confidence ELSE claim.confidence END,
                        derivation = CASE WHEN excluded.authority > claim.authority OR (excluded.authority = claim.authority AND excluded.confidence > claim.confidence) THEN excluded.derivation ELSE claim.derivation END,
                        domain = CASE WHEN claim.domain != excluded.domain THEN 'restricted' WHEN excluded.authority > claim.authority OR (excluded.authority = claim.authority AND excluded.confidence > claim.confidence) THEN excluded.domain ELSE claim.domain END,
                        valid_to = CASE WHEN excluded.authority > claim.authority OR (excluded.authority = claim.authority AND excluded.confidence > claim.confidence) THEN excluded.valid_to ELSE claim.valid_to END,
                        observed_at = CASE WHEN excluded.authority > claim.authority OR (excluded.authority = claim.authority AND excluded.confidence > claim.confidence) THEN excluded.observed_at ELSE claim.observed_at END,
                        authority = MAX(claim.authority, excluded.authority)
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

    /// Every claim in a slot that rests on `object`, retired ones included, in the order read.
    public func claims(key: String, readFrom object: ObjectID) async throws -> [CoreClaim] {
        try await database.query(
            """
            SELECT DISTINCT c.* FROM claim c
            JOIN claim_evidence ce ON ce.claim_id = c.id AND ce.stance = 'supports'
            JOIN evidence e ON e.id = ce.evidence_id
            WHERE c.claim_key = ? AND e.object_id = ?
            ORDER BY c.observed_at ASC, COALESCE(c.valid_from, c.observed_at) ASC, c.id ASC
            """,
            [.text(key), .text(object.value)]
        ).map(CoreClaim.init(row:))
    }

    public func claims(
        subject: EntityID,
        currentOnly: Bool = true,
        asOfWorld: Date? = nil,
        asOfKnowledge: Date? = nil
    ) async throws -> [CoreClaim] {
        let filter = (currentOnly && asOfWorld == nil && asOfKnowledge == nil) ? "AND retracted_at IS NULL" : ""
        let rows = try await database.query(
            "SELECT * FROM claim WHERE subject = ? \(filter) ORDER BY predicate, observed_at DESC, id ASC",
            [.text(subject.value)]
        ).map(CoreClaim.init(row:))
        return Self.held(rows, currentOnly: currentOnly, asOfWorld: asOfWorld, asOfKnowledge: asOfKnowledge)
    }

    /// Claims whose value is `entity`, under the same time rules as `claims(subject:)`.
    ///
    /// "Which projects use Swift" names Swift, and Swift is the subject of nothing: every fact
    /// about it reads "OpenClinic is built with Swift", with Swift in the value position.
    public func claims(
        pointingAt entity: EntityID,
        currentOnly: Bool = true,
        asOfWorld: Date? = nil,
        asOfKnowledge: Date? = nil
    ) async throws -> [CoreClaim] {
        let filter = (currentOnly && asOfWorld == nil && asOfKnowledge == nil) ? "AND retracted_at IS NULL" : ""
        let rows = try await database.query(
            "SELECT * FROM claim WHERE object_entity = ? \(filter) ORDER BY predicate, observed_at DESC, id ASC",
            [.text(entity.value)]
        ).map(CoreClaim.init(row:))
        return Self.held(rows, currentOnly: currentOnly, asOfWorld: asOfWorld, asOfKnowledge: asOfKnowledge)
    }

    private static func held(
        _ rows: [CoreClaim],
        currentOnly: Bool,
        asOfWorld: Date?,
        asOfKnowledge: Date?
    ) -> [CoreClaim] {
        if let asOfWorld, let asOfKnowledge {
            return rows.filter { $0.validity.asOf(world: asOfWorld, knowledge: asOfKnowledge) }
        }
        if let asOfWorld {
            return rows.filter {
                $0.validity.heldInWorld(at: asOfWorld) && (!currentOnly || $0.validity.isCurrent)
            }
        }
        if let asOfKnowledge {
            return rows.filter { $0.validity.wasBelieved(at: asOfKnowledge) }
        }
        return rows
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

    /// Subject entities of non-retracted claims backed by evidence from `objectID`.
    public func claimSubjects(forObject objectID: ObjectID) async throws -> [EntityID] {
        try await database.query(
            """
            SELECT DISTINCT c.subject AS subject
            FROM claim c
            JOIN claim_evidence ce ON ce.claim_id = c.id
            JOIN evidence e ON e.id = ce.evidence_id
            WHERE e.object_id = ? AND c.retracted_at IS NULL
            """,
            [.text(objectID.value)]
        ).map { EntityID($0.requireString("subject")) }
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
            domain: Domain(rawValue: row.requireString("domain")) ?? .restricted
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
        return try await database.query("SELECT * FROM contradiction \(filter) ORDER BY detected_at DESC, id ASC")
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

    /// What OpenCore believed at a past instant, optionally filtered to what held in the world at `world`.
    /// Backs `opencore memory checkout` and `TimeTravelView`.
    public func beliefs(asOfKnowledge instant: Date, asOfWorld world: Date? = nil) async throws -> [Belief] {
        let rows = try await database.query(
            """
            SELECT b.*, c.retracted_at AS c_retracted_at, c.valid_from AS c_valid_from, c.valid_to AS c_valid_to
            FROM belief b
            LEFT JOIN claim c ON c.id = b.claim_id
            WHERE b.decided_at <= ?
            ORDER BY b.claim_key ASC, b.version DESC
            """,
            [.real(instant.timeIntervalSince1970)]
        )

        struct VersionRow {
            let belief: Belief
            let claimRetractedAt: Date?
            let claimValidFrom: Date?
            let claimValidTo: Date?
        }

        var byKey: [String: [VersionRow]] = [:]
        var orderedKeys: [String] = []
        for row in rows {
            let belief = Belief(row: row)
            if byKey[belief.claimKey] == nil {
                orderedKeys.append(belief.claimKey)
            }
            byKey[belief.claimKey, default: []].append(VersionRow(
                belief: belief,
                claimRetractedAt: row.date("c_retracted_at"),
                claimValidFrom: row.date("c_valid_from"),
                claimValidTo: row.date("c_valid_to")
            ))
        }

        var selected: [Belief] = []
        for key in orderedKeys {
            guard let versions = byKey[key], let latest = versions.first else { continue }
            if let world {
                // Walk from newest version known at `instant` to oldest, bounding each
                // superseded version's world ceiling by the successor version's start.
                for (index, candidate) in versions.enumerated() {
                    let start = candidate.claimValidFrom ?? candidate.belief.validity.validFrom
                    let successorStart: Date? = index > 0
                        ? (versions[index - 1].claimValidFrom ?? versions[index - 1].belief.validity.validFrom ?? versions[index - 1].belief.decidedAt)
                        : candidate.claimRetractedAt
                    let end = candidate.claimValidTo ?? candidate.belief.validity.validTo ?? successorStart
                    if let start, world < start { continue }
                    if let end, world >= end { continue }
                    selected.append(candidate.belief)
                    break
                }
            } else {
                // Knowledge-time checkout: the latest version decided by `instant` stands
                // unless its underlying claim was already retracted by `instant`.
                if let retractedAt = latest.claimRetractedAt, retractedAt <= instant {
                    continue
                }
                selected.append(latest.belief)
            }
        }
        return selected
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

    public func events(from: Date, to: Date, domains: Set<Domain>? = nil, subject: EntityID? = nil, limit: Int = 200) async throws -> [CoreEvent] {
        var sql = "SELECT * FROM event WHERE occurred_at >= ? AND occurred_at <= ?"
        var bindings: [SQLValue] = [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
        if let subject {
            sql += " AND subject = ?"
            bindings.append(.text(subject.value))
        }
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
            domain: Domain(rawValue: row.requireString("domain")) ?? .restricted,
            authority: Authority(rawValue: row.requireInt("authority")) ?? .thirdPartyRecord
        )
    }
}

// MARK: - Receipts

extension Store {
    public func save(_ receipt: Receipt, evidence: [(EvidenceID, Double)] = [], claims: [ClaimID] = [], additionalEvidence: [Evidence] = []) async throws {
        try await database.write { connection in
            try Self.saveReceipt(receipt, evidence: evidence, claims: claims, additionalEvidence: additionalEvidence, connection: connection)
        }
    }

    /// Shared transaction primitive: callers that save other rows with a receipt must use the
    /// same connection and commit or roll back the whole exchange together.
    static func saveReceipt(_ receipt: Receipt, evidence: [(EvidenceID, Double)], claims: [ClaimID],
                            additionalEvidence: [Evidence], connection: Connection) throws {
        let stagesJSON = (try? JSONEncoder().encode(receipt.stages)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try Self.saveEvidence(additionalEvidence, connection: connection)
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
                domain: Domain(rawValue: row.requireString("o_domain")) ?? .restricted,
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
            // Unknown or malformed stored scopes must not disappear: doing so could make a
            // receipt look safe to a phone whose grant excludes the unrecognised domain.
            guard let raw = row.string(column) else { return [.restricted] }
            guard !raw.isEmpty else { return [] }
            return raw.split(separator: ",", omittingEmptySubsequences: false)
                .map { Domain(rawValue: String($0)) ?? .restricted }
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
            createdAt: row.requireDate("created_at"),
            // Read, never recomputed. The previous version re-derived the id from the query and
            // a millisecond timestamp and relied on the stored `Double` reproducing exactly,
            // which meant a receipt could silently become untraceable. Now the column is the
            // identity, which is the only way `opencore trace <code>` can be trusted.
            id: ReceiptID(row.requireString("id"))
        )
    }
}
