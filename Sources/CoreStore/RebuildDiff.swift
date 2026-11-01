import CoreModel
import Foundation

/// One claim, as a rehearsal report shows it.
public struct RebuildClaimRow: Codable, Sendable, Hashable {
    public var subject: String
    public var predicate: String
    public var value: String
    public var domain: String
    /// What changed, for rows that exist on both sides.
    public var note: String?
}

/// What a rebuild would change, compared by id rather than by count.
///
/// **Counts cannot answer this.** The old verdict was `before == after` over row counts, labelled
/// "Reproduced 100% Exactly". A claim moving from a restricted domain to a readable one changes
/// no count at all, and that is the single most dangerous thing a rebuild can do here.
public struct RebuildDiff: Codable, Sendable {
    public struct Count: Codable, Sendable, Hashable {
        public var table: String
        public var before: Int
        public var after: Int
    }

    public var counts: [Count] = []
    /// Believed before, and no longer derived from the floor. Kept as retracted rows, never
    /// deleted: a change of mind is recorded, and receipts that cited them still resolve.
    public var claimsRetired = 0
    /// Rows that existed before and exist nowhere afterwards. Always a blocker.
    public var claimRowsDropped = 0
    /// Retired before, believed afterwards.
    public var claimsRestored = 0
    /// Believed afterwards, never seen before.
    public var claimsAdded = 0
    /// Believed afterwards and new to the store, but only because replaying history retired it
    /// at once. Never believed, and listed so the row count adds up.
    public var claimsAddedAsHistory = 0
    /// Moved to a domain more people can read, or to a sensitive domain with different readers.
    /// Counts a statement that came back under a new id as well as a row that kept its id.
    /// Always a blocker.
    public var domainsRaised = 0
    /// The same check over events, which carry a domain of their own. Always a blocker.
    public var eventsRaised = 0
    public var domainsLowered = 0
    public var authorityChanged = 0
    /// Claims held in quarantine because their floor object is awaiting review. They would have
    /// been raised without the carry-across.
    public var quarantineHeld = 0
    /// Slots whose current belief changed value.
    public var beliefsChanged = 0
    /// Slots with no belief before that have one now. A comparison of slots present on both sides
    /// cannot see these, and the owner approves an apply on this number too.
    public var beliefsAdded = 0
    public var openContradictionsBefore = 0
    public var openContradictionsAfter = 0
    /// Rows that existed before and exist nowhere afterwards. Always a blocker.
    public var contradictionRowsDropped = 0
    /// Recorded belief versions with no row afterwards, or with a different decision time, which
    /// is the same loss: `memory checkout` no longer finds them on the date they were held. Always
    /// a blocker.
    public var beliefVersionsDropped = 0
    public var receiptLinksBefore = 0
    public var receiptLinksKept = 0
    /// Every receipt in the store, linked or not.
    public var receiptsTotal = 0
    /// Receipts with evidence rows behind them. An answer from passages or a count has none.
    public var receiptsWithEvidence = 0
    public var receiptsWithClaims = 0
    /// Receipts with no links before the rebuild, so there is nothing a rebuild could keep.
    public var receiptsWithoutLinks = 0
    /// Receipts whose real trace returned everything it returned before.
    public var receiptsResolving = 0
    /// Receipts whose trace lost a link or changed what it cites. Always a blocker.
    public var receiptsBroken = 0
    public var correctionsBefore = 0
    public var correctionsKept = 0
    /// Current rows saying what the owner corrected, which were not current before. Always a
    /// blocker: `correctionsKept` counts correction rows, and those survive even when the value
    /// they ruled out is believed again.
    public var correctionsUndone = 0
    public var chunksWithoutVector = 0
    public var chunksAdded = 0
    public var chunksRemoved = 0
    public var edgesRemoved = 0
    /// A sample, for reading. Bounded so the report stays a report.
    public var samples: [String: [RebuildClaimRow]] = [:]

    public init() {}

    /// Fill in the receipt totals from an audit that ran the real trace.
    public mutating func record(_ audit: [RebuildReceiptTrace]) {
        receiptsTotal = audit.count
        receiptsWithEvidence = audit.filter { $0.evidenceLinks > 0 }.count
        receiptsWithClaims = audit.filter { $0.claimLinks > 0 }.count
        receiptsWithoutLinks = audit.filter { $0.outcome == .noLinks }.count
        receiptsResolving = audit.filter { $0.outcome == .resolves }.count
        receiptsBroken = audit.filter { $0.outcome == .broken }.count
    }
}

/// Carried across, counted, and reported.
public struct RebuildCarryOutcome: Codable, Sendable {
    public var userClaims = 0
    public var modelClaims = 0
    public var retained = 0
    public var corrections = 0
    public var vectors = 0
    public var quarantined = 0
    /// New rows held at the domain their earlier statement had.
    public var heldAtEarlierDomain = 0
    /// Contradiction rows kept as history because a rebuild did not find them again.
    public var contradictionsKept = 0
    /// Open contradictions the rebuild's own reconcile decided.
    public var contradictionsClosed = 0
    /// Belief versions kept as history because a rebuild did not reach them again.
    public var beliefVersionsKept = 0
    /// Evidence rows put back to the text past answers cited.
    public var evidenceTextKept = 0
}

extension Store {
    /// A string that changes whenever the floor or the conclusions drawn from it change.
    ///
    /// Taken before a rehearsal and compared inside the apply transaction. Receipts are left
    /// out on purpose: every `core_ask` from a running MCP session writes one, and they are
    /// merged at apply rather than replaced.
    ///
    /// **Counts could not see a quarantine.** This compared counts and totals, so a claim moved
    /// to `restricted`, or an object flagged for review, after the rehearsal left it unchanged.
    /// The apply then replaced that claim with the rehearsal's wider row. `content` covers each
    /// row's identity and policy, and costs a few milliseconds on 10,000 objects.
    public func floorSignature() async throws -> String {
        try await database.read { try Self.floorSignature($0) }
    }

    static func floorSignature(_ connection: Connection, schema prefix: String = "main") throws -> String {
        let row = try connection.query(
            """
            SELECT (SELECT COUNT(*) FROM \(prefix).object) AS objects,
                   (SELECT COUNT(*) FROM \(prefix).object_version) AS versions,
                   (SELECT MAX(ingested_at) FROM \(prefix).object) AS ingested,
                   (SELECT MAX(superseded_at) FROM \(prefix).object_version) AS superseded,
                   (SELECT COUNT(*) FROM \(prefix).correction) AS corrections,
                   (SELECT COUNT(*) FROM \(prefix).claim) AS claims,
                   (SELECT COUNT(*) FROM \(prefix).claim WHERE retracted_at IS NULL) AS current,
                   (SELECT COUNT(*) FROM \(prefix).belief) AS beliefs,
                   (SELECT COUNT(*) FROM \(prefix).source) AS sources,
                   (SELECT COALESCE(SUM(authority), 0) FROM \(prefix).object) AS authority,
                   (SELECT group_concat(domain || ':' || n) FROM (
                        SELECT domain, COUNT(*) AS n FROM \(prefix).object GROUP BY domain ORDER BY domain
                   )) AS domains
            """
        ).first
        guard let row else { return "" }
        return [
            "objects=\(row.int("objects") ?? 0)", "versions=\(row.int("versions") ?? 0)",
            "ingested=\(row.double("ingested") ?? 0)", "superseded=\(row.double("superseded") ?? 0)",
            "corrections=\(row.int("corrections") ?? 0)", "claims=\(row.int("claims") ?? 0)",
            "current=\(row.int("current") ?? 0)", "beliefs=\(row.int("beliefs") ?? 0)",
            "sources=\(row.int("sources") ?? 0)", "authority=\(row.int("authority") ?? 0)",
            "domains=\(row.string("domains") ?? "")",
            "content=\(try contentDigest(connection, schema: prefix))",
        ].joined(separator: ";")
    }

    /// One digest over each row a rebuild reads or replaces, in a fixed order.
    private static func contentDigest(_ connection: Connection, schema prefix: String) throws -> String {
        let lines = [
            ("id || '|' || domain || '|' || authority || '|' || content_hash || '|' || COALESCE(metadata, '')", "object"),
            ("id || '|' || domain || '|' || authority || '|' || COALESCE(retracted_at, '')", "claim"),
            ("id || '|' || domain", "event"),
            ("id || '|' || resolution", "contradiction"),
            ("id || '|' || claim_id", "belief"),
            ("id", "correction"),
        ]
        var joined = ""
        for (line, table) in lines {
            let row = try connection.query("SELECT group_concat(line, char(10)) AS lines FROM (SELECT \(line) AS line FROM \(prefix).\(table) ORDER BY 1)").first
            joined += row?.string("lines") ?? ""
            joined += "\n--\n"
        }
        return Digest.hex(joined)
    }

    // MARK: - Domain floor

    /// Openness of a domain column, narrowest first. Anything not named reads as narrowest, so an
    /// unknown domain can only ever look like a raise and get a human's attention.
    private static func openness(_ column: String) -> String {
        """
        CASE \(column) WHEN 'restricted' THEN 0 WHEN 'medical' THEN 1 WHEN 'financial' THEN 1
        WHEN 'relationship' THEN 1 WHEN 'personal' THEN 2 WHEN 'work' THEN 3 WHEN 'project' THEN 4
        WHEN 'public' THEN 5 ELSE 0 END
        """
    }

    /// True when `after` lets someone read what `before` did not. Two sensitive domains rank the
    /// same and have different readers, so moving between them counts.
    private static func wider(_ after: String, than before: String) -> String {
        "(\(openness(after)) > \(openness(before)) OR (\(after) != \(before) AND \(openness(after)) = \(openness(before))))"
    }

    /// True when a new row says what an earlier row said: the same slot and value, or the same
    /// predicate and value under another subject, read from an object they share.
    private static func sameStatement(new: String, newSchema: String, old: String, oldSchema: String) -> String {
        """
        \(old).predicate = \(new).predicate
        AND COALESCE(\(old).object_entity, \(old).literal, '') = COALESCE(\(new).object_entity, \(new).literal, '')
        AND (\(old).claim_key = \(new).claim_key OR EXISTS (
            SELECT 1 FROM \(oldSchema).claim_evidence oce
            JOIN \(oldSchema).evidence oe ON oe.id = oce.evidence_id
            JOIN \(newSchema).claim_evidence nce ON nce.claim_id = \(new).id
            JOIN \(newSchema).evidence ne ON ne.id = nce.evidence_id
            WHERE oce.claim_id = \(old).id AND oe.object_id = ne.object_id
        ))
        """
    }

    /// True of row `c` when it says what the owner corrected, and is not something the owner said.
    /// Needs `pristine` attached, which is where the corrections are.
    static func saysWhatTheOwnerCorrected(_ c: String, schema: String) -> String {
        """
        \(c).authority != \(Authority.directStatement.rawValue) AND \(c).derivation != 'corrected'
        AND \(c).id NOT IN (SELECT asserted_claim FROM pristine.correction)
        AND EXISTS (
            SELECT 1 FROM pristine.correction x JOIN pristine.claim p ON p.id = x.superseded_claim
            WHERE \(sameStatement(new: c, newSchema: schema, old: "p", oldSchema: "pristine"))
        )
        """
    }

    /// Current rows the owner's corrections rule out. A value that was current before the rebuild
    /// is left out: a correction names one row, so another row in that slot was never ruled on.
    private static func correctionUndone(_ c: String, schema: String) -> String {
        """
        \(c).retracted_at IS NULL AND \(saysWhatTheOwnerCorrected(c, schema: schema))
        AND NOT EXISTS (
            SELECT 1 FROM pristine.claim k
            WHERE k.retracted_at IS NULL AND k.claim_key = \(c).claim_key
              AND COALESCE(k.object_entity, k.literal, '') = COALESCE(\(c).object_entity, \(c).literal, '')
        )
        """
    }

    /// Rows of `after` that would be readable by someone `before` kept out. Alias `c`.
    ///
    /// **A claim's id includes the date it was valid from**, so a statement re-derived with a new
    /// date is a new row. Comparing by id alone said "0 raised" while 7 quarantined statements
    /// came back at `project` under new ids, measured on a copy on 2026-10-31.
    private static func raisedClaims(after: String, before: String) -> String {
        """
        (EXISTS (SELECT 1 FROM \(before).claim p WHERE p.id = c.id AND \(wider("c.domain", than: "p.domain")))
         OR (c.id NOT IN (SELECT id FROM \(before).claim) AND EXISTS (
            SELECT 1 FROM \(before).claim p
            WHERE \(sameStatement(new: "c", newSchema: after, old: "p", oldSchema: before))
              AND \(wider("c.domain", than: "p.domain"))
         )))
        """
    }

    /// Empty a rehearsal copy's derived layers, whatever they hold.
    ///
    /// The one route past `dropDerivedLayers`' guards, and it refuses the real store. The guards
    /// exist because an in-place drop loses things; a rehearsal keeps the pristine snapshot
    /// beside it and carries them back across.
    public func clearDerivedLayersOfRehearsalCopy() async throws {
        let path = await database.path.standardizedFileURL.resolvingSymlinksInPath()
        guard path != Database.defaultPath().standardizedFileURL.resolvingSymlinksInPath() else {
            throw RebuildSafetyError.notARehearsalCopy
        }
        try await database.write { connection in
            for table in Self.derivedTables {
                try connection.execute("DELETE FROM \(table)")
            }
        }
    }

    /// Bring across what derivation cannot produce: user assertions, corrections, and proposals
    /// whose floor copy is gone.
    ///
    /// **This is correction replay.** It exists because a Keep click on a contradiction writes a
    /// `correction` row, which disabled `rebuild` permanently, and the notification invited
    /// that click. A correction is the user saying something, so it is primary and it survives.
    /// Run before the final reconcile, so a corrected slot adjudicates against what the rebuild
    /// derived.
    public func carryUserClaims(from pristine: URL) async throws -> RebuildCarryOutcome {
        try await database.withAttached(pristine, as: "pristine") { connection in
            var outcome = RebuildCarryOutcome()
            let keep = """
                SELECT id FROM pristine.claim WHERE authority IN (?, ?) OR derivation = 'corrected'
                UNION SELECT superseded_claim FROM pristine.correction WHERE superseded_claim IS NOT NULL
                UNION SELECT asserted_claim FROM pristine.correction
                """
            let bindings: [SQLValue] = [.integer(Int64(Authority.directStatement.rawValue)), .integer(Int64(Authority.modelInference.rawValue))]
            try connection.execute(
                """
                INSERT OR IGNORE INTO evidence SELECT * FROM pristine.evidence WHERE id IN (
                    SELECT evidence_id FROM pristine.claim_evidence WHERE claim_id IN (\(keep))
                )
                """, bindings)
            outcome.userClaims = try connection.scalarInt("SELECT COUNT(*) FROM pristine.claim WHERE authority = ?", [bindings[0]])
            outcome.modelClaims = try connection.scalarInt("SELECT COUNT(*) FROM pristine.claim WHERE authority = ?", [bindings[1]])
            try connection.execute("INSERT OR IGNORE INTO claim SELECT * FROM pristine.claim WHERE id IN (\(keep))", bindings)
            try connection.execute(
                "INSERT OR IGNORE INTO claim_evidence SELECT * FROM pristine.claim_evidence WHERE claim_id IN (\(keep))",
                bindings)
            try connection.execute("INSERT OR IGNORE INTO correction SELECT * FROM pristine.correction")
            outcome.corrections = try connection.scalarInt("SELECT COUNT(*) FROM correction")
            // What the user said was wrong stays wrong, even if the same row was re-derived.
            try connection.execute(
                """
                UPDATE claim SET retracted_at = (
                    SELECT MIN(c.created_at) FROM pristine.correction c WHERE c.superseded_claim = claim.id
                ) WHERE id IN (SELECT superseded_claim FROM pristine.correction WHERE superseded_claim IS NOT NULL)
                """)
            // The same statement under another id. A claim's id holds its subject and date, so
            // following the id alone let a corrected value come back as a current row. Measured on
            // a copy on 2026-10-31: a corrected `describes` claim moved to a new subject, one live
            // row held it again, and the report said "corrections kept 1 of 1".
            let undone = Self.correctionUndone("claim", schema: "main")
            let same = Self.sameStatement(new: "claim", newSchema: "main", old: "p", oldSchema: "pristine")
            try connection.executeScript(
                """
                CREATE TEMP TABLE corrected_away AS SELECT claim.id AS id FROM main.claim claim WHERE \(undone)
                    UNION SELECT superseded_claim FROM pristine.correction WHERE superseded_claim IS NOT NULL;
                """)
            try connection.execute(
                """
                UPDATE claim SET retracted_at = (
                    SELECT MIN(x.created_at) FROM pristine.correction x
                    JOIN pristine.claim p ON p.id = x.superseded_claim WHERE \(same)
                ) WHERE retracted_at IS NULL AND id IN (SELECT id FROM temp.corrected_away)
                """)
            // Replay may have believed it. The final reconcile writes those slots again from what
            // is still current, and nothing here is the store's: its chains are carried afterwards.
            try connection.execute(
                """
                DELETE FROM belief WHERE claim_key IN (
                    SELECT claim_key FROM belief WHERE claim_id IN (SELECT id FROM temp.corrected_away)
                )
                """)
            try connection.executeScript("DROP TABLE temp.corrected_away;")
            return outcome
        }
    }

    /// Carry across what a re-derivation resets, after the final reconcile.
    ///
    /// - **Quarantine.** Claim domains come from object domains, so a re-derive quietly lifts
    ///   it. Anything restricted stays restricted, and anything backed by an object still
    ///   flagged for review joins it. Lifting quarantine is a separate reviewed decision.
    /// - **Knowledge time.** A re-derive stamps everything with today, which erases what
    ///   `memory checkout` is for. A row that survived keeps the time it was first known, and a
    ///   belief's chain is carried whole. See `carryBeliefHistory`.
    /// - **Vectors.** Reused wherever the chunk's text is unchanged. A rebuild otherwise
    ///   leaves the dense leg empty until a slow re-embed finishes.
    /// - **Retired claims.** A claim the extractor no longer produces is retracted here, not
    ///   dropped. "Never delete to record a change of mind" holds for rebuilds too, and a receipt
    ///   that cited it keeps something to point at.
    /// - **Receipt links.** Ids are deterministic, so a link survives whenever its target does.
    public func carryDerivedState(from pristine: URL, now: Date = Date()) async throws -> RebuildCarryOutcome {
        try await database.withAttached(pristine, as: "pristine") { connection in
            var outcome = RebuildCarryOutcome()

            // Retired claims, first, so everything below treats them like any other row.
            try connection.executeScript(
                """
                CREATE TEMP TABLE not_rederived AS
                    SELECT id FROM pristine.claim WHERE id NOT IN (SELECT id FROM main.claim);
                """
            )
            try connection.execute(
                """
                INSERT OR IGNORE INTO evidence SELECT * FROM pristine.evidence WHERE id IN (
                    SELECT evidence_id FROM pristine.claim_evidence WHERE claim_id IN (SELECT id FROM temp.not_rederived)
                )
                """)
            try connection.execute("INSERT OR IGNORE INTO claim SELECT * FROM pristine.claim WHERE id IN (SELECT id FROM temp.not_rederived)")
            try connection.execute("INSERT OR IGNORE INTO claim_evidence SELECT * FROM pristine.claim_evidence WHERE claim_id IN (SELECT id FROM temp.not_rederived)")
            outcome.retained = try connection.execute(
                "UPDATE claim SET retracted_at = ? WHERE retracted_at IS NULL AND id IN (SELECT id FROM temp.not_rederived)",
                [.real(now.timeIntervalSince1970)]
            )
            try connection.executeScript("DROP TABLE temp.not_rederived;")

            // Quarantine is a floor. A row that existed keeps its domain or a narrower one.
            try connection.execute(
                """
                UPDATE claim SET domain = (SELECT p.domain FROM pristine.claim p WHERE p.id = claim.id)
                WHERE EXISTS (SELECT 1 FROM pristine.claim p WHERE p.id = claim.id AND \(Self.wider("claim.domain", than: "p.domain")))
                """)
            // Anything read from an object still awaiting review joins it.
            try connection.execute(
                """
                UPDATE claim SET domain = 'restricted' WHERE domain != 'restricted' AND id IN (
                    SELECT ce.claim_id FROM claim_evidence ce
                    JOIN evidence e ON e.id = ce.evidence_id
                    JOIN object o ON o.id = e.object_id
                    WHERE json_extract(o.metadata, '$.classification_requires_rebuild') = 'true'
                )
                """)
            // A statement that came back under a new id is the same statement. Without this the
            // quarantine followed the row and not what it said.
            let earlier = Self.sameStatement(new: "claim", newSchema: "main", old: "p", oldSchema: "pristine")
            outcome.heldAtEarlierDomain = try connection.execute(
                """
                UPDATE claim SET domain = (
                    SELECT p.domain FROM pristine.claim p WHERE \(earlier) ORDER BY \(Self.openness("p.domain")) LIMIT 1
                ) WHERE id NOT IN (SELECT id FROM pristine.claim) AND EXISTS (
                    SELECT 1 FROM pristine.claim p WHERE \(earlier) AND \(Self.wider("claim.domain", than: "p.domain"))
                )
                """)
            try connection.execute(
                """
                UPDATE event SET domain = (SELECT p.domain FROM pristine.event p WHERE p.id = event.id)
                WHERE EXISTS (SELECT 1 FROM pristine.event p WHERE p.id = event.id AND \(Self.wider("event.domain", than: "p.domain")))
                """)
            outcome.quarantined = try connection.scalarInt("SELECT COUNT(*) FROM claim WHERE domain = 'restricted' AND retracted_at IS NULL")

            // Knowledge time.
            try connection.execute(
                """
                UPDATE claim SET observed_at = (SELECT MIN(p.observed_at, claim.observed_at) FROM pristine.claim p WHERE p.id = claim.id)
                WHERE id IN (SELECT id FROM pristine.claim)
                """)
            try connection.execute(
                """
                UPDATE claim SET retracted_at = (SELECT p.retracted_at FROM pristine.claim p WHERE p.id = claim.id)
                WHERE retracted_at IS NOT NULL AND id IN (SELECT id FROM pristine.claim WHERE retracted_at IS NOT NULL)
                """)
            try connection.execute(
                """
                UPDATE contradiction SET detected_at = (SELECT p.detected_at FROM pristine.contradiction p WHERE p.id = contradiction.id)
                WHERE id IN (SELECT id FROM pristine.contradiction)
                """)

            // Counter-evidence is a row, and a change of mind is never deleted.
            let contradictions = try Self.carryContradictions(connection)
            outcome.contradictionsKept = contradictions.kept
            outcome.contradictionsClosed = contradictions.closed
            outcome.beliefVersionsKept = try Self.carryBeliefHistory(connection, now: now)

            // Evidence text. An older row's id has no reading in it, so replaying an object's earlier
            // states rewrote its snippet, and a past answer quoted text it never saw. Measured on a
            // copy on 2026-10-31: 2 rows, cited 3 times, one of them naming the wrong commit.
            outcome.evidenceTextKept = try connection.execute(
                """
                UPDATE evidence SET snippet = (SELECT p.snippet FROM pristine.evidence p WHERE p.id = evidence.id)
                WHERE EXISTS (SELECT 1 FROM pristine.evidence p WHERE p.id = evidence.id AND p.snippet != evidence.snippet)
                """)

            // Vectors.
            try connection.execute(
                """
                INSERT OR IGNORE INTO chunk_vector
                SELECT v.* FROM pristine.chunk_vector v
                JOIN pristine.chunk old ON old.id = v.chunk_id
                JOIN chunk new ON new.id = old.id AND new.text = old.text
                """)
            try connection.execute("INSERT OR IGNORE INTO embedding_run SELECT * FROM pristine.embedding_run")
            outcome.vectors = try connection.scalarInt("SELECT COUNT(*) FROM chunk_vector")

            // Receipt links.
            try connection.execute("INSERT OR IGNORE INTO receipt_evidence SELECT * FROM pristine.receipt_evidence WHERE evidence_id IN (SELECT id FROM evidence)")
            try connection.execute("INSERT OR IGNORE INTO receipt_claim SELECT * FROM pristine.receipt_claim WHERE claim_id IN (SELECT id FROM claim)")
            return outcome
        }
    }

    /// Keep every contradiction the store had recorded.
    ///
    /// **The bug this repairs.** Nothing carried this table, so a rebuild lost all 14 rows on the
    /// real store and wrote 4 new ones. A contradiction's id comes from its two claim ids, so a
    /// claim re-derived under a new date made a new pair and the old row was simply gone, along
    /// with any `resolvedByCorrection` row saying the owner had ruled on it.
    ///
    /// A row the rebuild did not find again stays exactly as it was. An open row stays open unless
    /// the rebuild's reconcile decided the same two values in the same slot, and then it is closed
    /// with that decision, because leaving it open would ask the owner about a settled question.
    private static func carryContradictions(_ connection: Connection) throws -> (kept: Int, closed: Int) {
        try connection.execute(
            """
            UPDATE contradiction SET
                resolution = (SELECT p.resolution FROM pristine.contradiction p WHERE p.id = contradiction.id),
                winner = (SELECT p.winner FROM pristine.contradiction p WHERE p.id = contradiction.id),
                reason = (SELECT p.reason FROM pristine.contradiction p WHERE p.id = contradiction.id)
            WHERE id IN (SELECT id FROM pristine.contradiction WHERE resolution = 'resolvedByCorrection')
            """)
        let kept = try connection.execute("INSERT OR IGNORE INTO contradiction SELECT * FROM pristine.contradiction")

        func value(_ alias: String) -> String { "COALESCE(\(alias).object_entity, \(alias).literal, '')" }
        try connection.executeScript(
            """
            CREATE TEMP TABLE decided_again AS
            SELECT open.id AS id, later.resolution AS resolution, later.winner AS winner, later.reason AS reason
            FROM contradiction open
            JOIN claim oa ON oa.id = open.claim_a
            JOIN claim ob ON ob.id = open.claim_b
            JOIN contradiction later ON later.id != open.id AND later.resolution != 'unresolved'
            JOIN claim la ON la.id = later.claim_a
            JOIN claim lb ON lb.id = later.claim_b
            WHERE open.resolution = 'unresolved' AND oa.claim_key = la.claim_key
              AND ((\(value("oa")) = \(value("la")) AND \(value("ob")) = \(value("lb")))
                OR (\(value("oa")) = \(value("lb")) AND \(value("ob")) = \(value("la"))))
            GROUP BY open.id;
            """
        )
        let closed = try connection.execute(
            """
            UPDATE contradiction SET
                resolution = (SELECT d.resolution FROM temp.decided_again d WHERE d.id = contradiction.id),
                winner = (SELECT d.winner FROM temp.decided_again d WHERE d.id = contradiction.id),
                reason = 'Decided by a rebuild: ' || (SELECT d.reason FROM temp.decided_again d WHERE d.id = contradiction.id)
            WHERE id IN (SELECT id FROM temp.decided_again)
            """)
        try connection.executeScript("DROP TABLE temp.decided_again;")
        return (kept, closed)
    }

    /// True of a pristine belief `p` when nothing the rebuild decided for that slot says the same
    /// value, which is what `beliefVersionsKept` counts. By value and not by claim id: a re-dated row
    /// has a new id, and comparing ids called 62 versions unreached.
    private static let beliefVersionLost = """
        NOT EXISTS (
            SELECT 1 FROM main.belief m
            JOIN main.claim now ON now.id = m.claim_id
            JOIN main.claim was ON was.id = p.claim_id
            WHERE m.claim_key = p.claim_key
              AND COALESCE(now.object_entity, now.literal, '') = COALESCE(was.object_entity, was.literal, '')
        )
        """

    /// Keep every slot's recorded chain as it was, and add a version only if the answer changed.
    ///
    /// **A rebuild never rewrites what the store believed and when.** Replay decides a slot's
    /// history again from what the floor still holds, and that is not a record of what the store
    /// thought. Replacing the chain lost 5 versions on the real store. Carrying `decided_at` only
    /// where a row kept its claim id then left re-dated winners at the rebuild's time: on a copy,
    /// `memory checkout 2026-10-30` lost 12 slots it had held and `memory log --since 1d` printed
    /// long-held facts as first learned today. A value on both sides of a chain also lost its older
    /// row, so the slot was unknown before the version the rebuild added.
    ///
    /// So the recorded rows stay, ids and dates included. When the rebuilt winner says the same
    /// thing as the last of them, that row only follows it to the current claim, because a re-dated
    /// row has a new id and the old one may be retired. When it differs, the store's mind changes
    /// here and not when replay dated it, so it is a new version at `now`. Replay's own versions in
    /// a recorded slot are dropped: the store never held them. A slot with no recorded chain keeps
    /// the versions replay wrote, dated `now`.
    private static func carryBeliefHistory(_ connection: Connection, now: Date) throws -> Int {
        let kept = try connection.scalarInt("SELECT COUNT(*) FROM pristine.belief p WHERE \(Self.beliefVersionLost)")
        let columns = "id, claim_key, version, claim_id, confidence, authority, valid_from, valid_to, observed_at, retracted_at, supersedes, reason, decided_at"
        func lastVersion(_ alias: String) -> String {
            "\(alias).version = (SELECT MAX(v.version) FROM main.belief v WHERE v.claim_key = \(alias).claim_key)"
        }
        try connection.executeScript(
            """
            CREATE TEMP TABLE rebuilt_winner AS
                SELECT b.claim_key AS claim_key, b.claim_id AS claim_id, b.confidence AS confidence, b.authority AS authority,
                       b.valid_from AS valid_from, b.valid_to AS valid_to, b.observed_at AS observed_at, b.retracted_at AS retracted_at,
                       COALESCE(c.object_entity, c.literal, '') AS value
                FROM main.belief b JOIN main.claim c ON c.id = b.claim_id
                WHERE b.claim_key IN (SELECT claim_key FROM pristine.belief) AND \(lastVersion("b"));
            DELETE FROM main.belief WHERE claim_key IN (SELECT claim_key FROM pristine.belief);
            INSERT INTO main.belief (\(columns)) SELECT \(columns) FROM pristine.belief;
            """
        )
        let slots = try connection.query(
            """
            SELECT b.id AS id, b.claim_key AS claim_key, b.version AS version, b.retracted_at IS NULL AS open,
                   COALESCE(c.object_entity, c.literal, '') AS recorded, w.value AS rebuilt
            FROM main.belief b JOIN main.claim c ON c.id = b.claim_id
            LEFT JOIN temp.rebuilt_winner w ON w.claim_key = b.claim_key
            WHERE b.claim_key IN (SELECT claim_key FROM pristine.belief) AND \(lastVersion("b"))
            """)
        for slot in slots {
            let id = slot.requireString("id")
            let key = slot.requireString("claim_key")
            guard let rebuilt = slot.string("rebuilt") else {
                // Nothing supports this slot any more, so its last version is history.
                if slot.requireInt("open") == 1 {
                    try connection.execute("UPDATE main.belief SET retracted_at = ? WHERE id = ?", [.real(now.timeIntervalSince1970), .text(id)])
                }
                continue
            }
            if rebuilt == slot.requireString("recorded") {
                try connection.execute(
                    """
                    UPDATE main.belief SET (claim_id, confidence, authority, valid_from, valid_to, retracted_at) = (
                        SELECT claim_id, confidence, authority, valid_from, valid_to, retracted_at FROM temp.rebuilt_winner WHERE claim_key = ?
                    ) WHERE id = ?
                    """, [.text(key), .text(id)])
            } else {
                let version = slot.requireInt("version") + 1
                try connection.execute(
                    """
                    INSERT INTO main.belief (\(columns))
                    SELECT ?, claim_key, ?, claim_id, confidence, authority, valid_from, valid_to, observed_at, retracted_at, ?, ?, ?
                    FROM temp.rebuilt_winner WHERE claim_key = ?
                    """,
                    [
                        .text(BeliefID.derived(from: key, String(version)).value), .integer(Int64(version)), .text(id),
                        .text("re-derived from the objects by a rebuild, replacing version \(version - 1)"),
                        .real(now.timeIntervalSince1970), .text(key),
                    ])
            }
        }
        try connection.executeScript("DROP TABLE temp.rebuilt_winner;")
        // The other direction of the same lie. A slot the store never decided can't have been
        // decided when replay dated it, and on a copy 2 such slots appeared in `memory checkout` for
        // a date before the rebuild. A store with no beliefs at all is the exception: it is being
        // restored from its objects, and replay's dates are the only record there is.
        try connection.execute(
            """
            UPDATE main.belief SET decided_at = ?
            WHERE claim_key NOT IN (SELECT claim_key FROM pristine.belief) AND EXISTS (SELECT 1 FROM pristine.belief)
            """, [.real(now.timeIntervalSince1970)])
        return kept
    }

    /// Compare this rebuilt copy against the pristine snapshot it came from.
    public func diff(againstPristine pristine: URL, sampleLimit: Int = 25) async throws -> RebuildDiff {
        try await database.withAttached(pristine, as: "pristine") { connection in
            var diff = RebuildDiff()
            for table in ["object", "object_version", "chunk", "chunk_vector", "evidence", "claim", "event", "edge", "belief", "contradiction", "correction", "receipt", "receipt_evidence", "receipt_claim", "entity"] {
                diff.counts.append(RebuildDiff.Count(
                    table: table,
                    before: try connection.scalarInt("SELECT COUNT(*) FROM pristine.\(table)"),
                    after: try connection.scalarInt("SELECT COUNT(*) FROM main.\(table)")
                ))
            }

            func rows(_ condition: String, note: String? = nil, table: String = "main") throws -> [RebuildClaimRow] {
                try connection.query(
                    """
                    SELECT e.canonical_name AS subject, c.predicate AS predicate,
                           COALESCE(o.canonical_name, c.literal, '?') AS value, c.domain AS domain
                    FROM \(table).claim c
                    JOIN \(table).entity e ON e.id = c.subject
                    LEFT JOIN \(table).entity o ON o.id = c.object_entity
                    WHERE \(condition)
                    ORDER BY e.canonical_name, c.predicate, value
                    LIMIT ?
                    """, [.integer(Int64(sampleLimit))]
                ).map {
                    RebuildClaimRow(
                        subject: $0.requireString("subject"),
                        predicate: $0.requireString("predicate"),
                        value: String($0.requireString("value").prefix(160)),
                        domain: $0.requireString("domain"),
                        note: note
                    )
                }
            }

            let retired = "c.retracted_at IS NOT NULL AND c.id IN (SELECT id FROM pristine.claim WHERE retracted_at IS NULL)"
            diff.claimsRetired = try connection.scalarInt("SELECT COUNT(*) FROM main.claim c WHERE \(retired)")
            diff.samples["claimsRetired"] = try rows(retired)
            // A row must survive every rebuild, retired or not. Nothing here should ever be
            // non-zero, and it is reported rather than assumed.
            diff.claimRowsDropped = try connection.scalarInt("SELECT COUNT(*) FROM pristine.claim WHERE id NOT IN (SELECT id FROM main.claim)")

            let restored = "c.retracted_at IS NULL AND c.id IN (SELECT id FROM pristine.claim WHERE retracted_at IS NOT NULL)"
            diff.claimsRestored = try connection.scalarInt("SELECT COUNT(*) FROM main.claim c WHERE \(restored)")
            diff.samples["claimsRestored"] = try rows(restored)

            let added = "c.retracted_at IS NULL AND c.id NOT IN (SELECT id FROM pristine.claim)"
            diff.claimsAdded = try connection.scalarInt("SELECT COUNT(*) FROM main.claim c WHERE \(added)")
            diff.samples["claimsAdded"] = try rows(added)
            diff.claimsAddedAsHistory = try connection.scalarInt(
                "SELECT COUNT(*) FROM main.claim c WHERE c.retracted_at IS NOT NULL AND c.id NOT IN (SELECT id FROM pristine.claim)")

            let raised = Self.raisedClaims(after: "main", before: "pristine")
            diff.domainsRaised = try connection.scalarInt("SELECT COUNT(*) FROM main.claim c WHERE \(raised)")
            diff.samples["domainsRaised"] = try rows(raised, note: "readable by more callers than before")
            diff.eventsRaised = try connection.scalarInt(
                "SELECT COUNT(*) FROM main.event c JOIN pristine.event p ON p.id = c.id WHERE \(Self.wider("c.domain", than: "p.domain"))")
            let lowered = """
                c.retracted_at IS NULL AND EXISTS (
                    SELECT 1 FROM pristine.claim p WHERE p.id = c.id AND p.retracted_at IS NULL
                      AND \(Self.openness("c.domain")) < \(Self.openness("p.domain"))
                )
                """
            diff.domainsLowered = try connection.scalarInt("SELECT COUNT(*) FROM main.claim c WHERE \(lowered)")
            diff.authorityChanged = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM main.claim c JOIN pristine.claim p ON p.id = c.id
                WHERE c.authority != p.authority AND c.retracted_at IS NULL AND p.retracted_at IS NULL
                """)
            diff.quarantineHeld = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM main.claim c WHERE c.domain = 'restricted' AND c.retracted_at IS NULL
                """)

            // Current belief per slot is the highest version.
            let currentBelief = { (schema: String) in
                """
                SELECT b.claim_key AS claim_key,
                       COALESCE((SELECT n.canonical_name FROM \(schema).entity n WHERE n.id = c.object_entity), c.literal, '') AS value
                FROM \(schema).belief b JOIN \(schema).claim c ON c.id = b.claim_id
                WHERE b.version = (SELECT MAX(v.version) FROM \(schema).belief v WHERE v.claim_key = b.claim_key)
                """
            }
            let changedBeliefs = try connection.query(
                """
                SELECT e.canonical_name AS subject, after.claim_key AS claim_key, before.value AS before, after.value AS after
                FROM (\(currentBelief("main"))) after
                JOIN (\(currentBelief("pristine"))) before ON before.claim_key = after.claim_key
                LEFT JOIN main.claim c ON c.claim_key = after.claim_key
                LEFT JOIN main.entity e ON e.id = c.subject
                WHERE before.value != after.value
                GROUP BY after.claim_key
                ORDER BY subject, after.claim_key
                """)
            diff.beliefsChanged = changedBeliefs.count
            diff.samples["beliefsChanged"] = changedBeliefs.prefix(sampleLimit).map {
                RebuildClaimRow(
                    subject: $0.string("subject") ?? "?",
                    predicate: String($0.requireString("claim_key").split(separator: "|").last ?? ""),
                    value: String($0.requireString("after").prefix(160)),
                    domain: "",
                    note: "was: \($0.requireString("before").prefix(160))"
                )
            }

            let firstBeliefs = try connection.query(
                """
                SELECT e.canonical_name AS subject, after.claim_key AS claim_key, after.value AS after
                FROM (\(currentBelief("main"))) after
                LEFT JOIN main.claim c ON c.claim_key = after.claim_key
                LEFT JOIN main.entity e ON e.id = c.subject
                WHERE after.claim_key NOT IN (SELECT claim_key FROM pristine.belief)
                GROUP BY after.claim_key
                ORDER BY subject, after.claim_key
                """)
            diff.beliefsAdded = firstBeliefs.count
            diff.samples["beliefsAdded"] = firstBeliefs.prefix(sampleLimit).map {
                RebuildClaimRow(
                    subject: $0.string("subject") ?? "?",
                    predicate: String($0.requireString("claim_key").split(separator: "|").last ?? ""),
                    value: String($0.requireString("after").prefix(160)),
                    domain: "",
                    note: "no belief before"
                )
            }

            diff.openContradictionsBefore = try connection.scalarInt("SELECT COUNT(*) FROM pristine.contradiction WHERE resolution = 'unresolved'")
            diff.openContradictionsAfter = try connection.scalarInt("SELECT COUNT(*) FROM main.contradiction WHERE resolution = 'unresolved'")

            diff.receiptLinksBefore = try connection.scalarInt("SELECT (SELECT COUNT(*) FROM pristine.receipt_evidence) + (SELECT COUNT(*) FROM pristine.receipt_claim)")
            diff.receiptLinksKept = try connection.scalarInt("SELECT (SELECT COUNT(*) FROM main.receipt_evidence) + (SELECT COUNT(*) FROM main.receipt_claim)")
            diff.contradictionRowsDropped = try connection.scalarInt("SELECT COUNT(*) FROM pristine.contradiction WHERE id NOT IN (SELECT id FROM main.contradiction)")
            diff.beliefVersionsDropped = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM pristine.belief p WHERE NOT EXISTS (
                    SELECT 1 FROM main.belief m WHERE m.id = p.id AND m.version = p.version AND m.decided_at = p.decided_at
                )
                """)
            diff.chunksAdded = try connection.scalarInt("SELECT COUNT(*) FROM main.chunk WHERE id NOT IN (SELECT id FROM pristine.chunk)")
            diff.chunksRemoved = try connection.scalarInt("SELECT COUNT(*) FROM pristine.chunk WHERE id NOT IN (SELECT id FROM main.chunk)")
            diff.edgesRemoved = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM pristine.edge p WHERE NOT EXISTS (
                    SELECT 1 FROM main.edge m WHERE m.source_entity = p.source_entity
                      AND m.relation = p.relation AND m.target_entity = p.target_entity
                )
                """)
            diff.correctionsBefore = try connection.scalarInt("SELECT COUNT(*) FROM pristine.correction")
            diff.correctionsKept = try connection.scalarInt("SELECT COUNT(*) FROM main.correction")
            let undone = Self.correctionUndone("c", schema: "main")
            diff.correctionsUndone = try connection.scalarInt("SELECT COUNT(*) FROM main.claim c WHERE \(undone)")
            diff.samples["correctionsUndone"] = try rows(undone, note: "the owner corrected this")
            diff.chunksWithoutVector = try connection.scalarInt(
                "SELECT COUNT(*) FROM main.chunk WHERE id NOT IN (SELECT chunk_id FROM main.chunk_vector)")
            return diff
        }
    }

    /// Replace this store's derived layers with a rehearsal's, in one transaction.
    ///
    /// **Replaced in place, never by swapping the file.** Several `opencore mcp` processes
    /// hold this database open for days. Moving a new file over it would leave them reading
    /// an unlinked inode with its own write-ahead log, and writing receipts nobody will see.
    /// Replacing rows inside one transaction means a running reader sees the old graph or the
    /// new one and never a half-empty one, which an in-place rebuild could not promise.
    ///
    /// Receipts written after the rehearsal keep their links wherever the target survives.
    ///
    /// **`INSERT OR IGNORE` drops a row without saying so**, so the transaction ends by comparing
    /// each table with the rehearsal and rolls back on any difference. The floor is checked again
    /// here, against the live rows, because the report it was first checked on is a file.
    public func applyRehearsal(rebuilt: URL, expecting signature: String) async throws {
        guard FileManager.default.fileExists(atPath: rebuilt.path) else {
            throw RebuildSafetyError.rehearsalBlocked(["the rehearsed copy is missing at \(rebuilt.path)"])
        }
        try await database.withAttached(rebuilt, as: "rebuilt") { connection in
            guard try Self.floorSignature(connection) == signature else { throw RebuildSafetyError.staleRehearsal }
            let raised = try connection.scalarInt("SELECT COUNT(*) FROM rebuilt.claim c WHERE \(Self.raisedClaims(after: "rebuilt", before: "main"))")
            guard raised == 0 else {
                throw RebuildSafetyError.rehearsalBlocked(["\(raised) claim(s) would become readable by more callers than today"])
            }

            try connection.executeScript(
                """
                CREATE TEMP TABLE keep_receipt_evidence AS SELECT * FROM main.receipt_evidence;
                CREATE TEMP TABLE keep_receipt_claim AS SELECT * FROM main.receipt_claim;
                """
            )
            for table in Self.derivedTables {
                try connection.execute("DELETE FROM main.\(table)")
            }
            // Rederiving can name new entities. It never removes one.
            try connection.execute("INSERT OR IGNORE INTO main.entity SELECT * FROM rebuilt.entity")
            try connection.execute("INSERT OR IGNORE INTO main.entity_alias SELECT * FROM rebuilt.entity_alias")
            let replaced = ["chunk", "chunk_vector", "embedding_run", "evidence", "claim", "claim_evidence", "event", "edge", "belief", "contradiction", "correction"]
            for table in replaced + ["receipt_evidence", "receipt_claim"] {
                try connection.execute("INSERT OR IGNORE INTO main.\(table) SELECT * FROM rebuilt.\(table)")
            }
            try connection.execute("INSERT OR IGNORE INTO main.receipt_evidence SELECT * FROM temp.keep_receipt_evidence WHERE evidence_id IN (SELECT id FROM main.evidence)")
            try connection.execute("INSERT OR IGNORE INTO main.receipt_claim SELECT * FROM temp.keep_receipt_claim WHERE claim_id IN (SELECT id FROM main.claim)")
            try connection.executeScript(
                """
                DROP TABLE temp.keep_receipt_evidence;
                DROP TABLE temp.keep_receipt_claim;
                """
            )
            for table in replaced {
                let expected = try connection.scalarInt("SELECT COUNT(*) FROM rebuilt.\(table)")
                let landed = try connection.scalarInt("SELECT COUNT(*) FROM main.\(table)")
                guard expected == landed else {
                    throw RebuildSafetyError.applyMismatch(table: table, expected: expected, landed: landed)
                }
            }
        }
    }

    /// Prove a backup is whole and holds the store that was about to change.
    public func verifyBackup(_ backup: URL, expecting signature: String) async throws {
        try await database.withAttached(backup, as: "backup") { connection in
            let check = try connection.query("PRAGMA backup.quick_check(1)").first?.string("quick_check")
            guard check == "ok" else { throw RebuildSafetyError.backupFailed(check ?? "no result from quick_check") }
            guard try Self.floorSignature(connection, schema: "backup") == signature else {
                throw RebuildSafetyError.backupFailed("the backup does not match the store")
            }
        }
    }

    /// Consistent copy of this store, by SQLite's backup API.
    public func snapshot(to url: URL) async throws {
        try await database.createPolicyRepairBackup(at: url)
    }

    /// Fold the write-ahead log into the main file.
    public func checkpoint() async throws {
        try await database.checkpoint()
    }
}
