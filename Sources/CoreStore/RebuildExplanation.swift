import CoreModel
import Foundation

/// What happened to a claim in a rehearsal.
public enum RebuildChangeKind: String, Codable, Sendable, CaseIterable {
    case retired
    case added
    /// New to the store, and retired by replaying history. Never believed.
    case addedAsHistory
    case restored
    case authorityChanged
    case domainLowered
}

/// Why it happened. Every change gets one, and a change that fits none is `unexplained`, which
/// the report counts and warns about instead of filing it somewhere plausible.
public enum RebuildChangeReason: String, Codable, Sendable, CaseIterable {
    /// The same value in the same slot, on a row with a different date. A claim's id includes
    /// the date, so this reads as one retired and one added and is one statement.
    case sameStatementNewDate
    /// The same value from the same object, under a different subject.
    case movedToAnotherSubject
    /// The slot still has a current value, and this is no longer it.
    case replacedByNewValue
    /// Nothing derives this any more.
    case noLongerDerived
    /// A slot that had rows, given a value it did not have.
    case newValueInSlot
    /// A slot with no rows before.
    case newSlot
    /// A row from an earlier state of an object, replayed and superseded in the same rebuild.
    case replayedHistory
    /// Re-derived, and retired at once because it says what the owner corrected.
    case correctedByOwner
    /// Retired before, and the objects produce it again.
    case derivedAgain
    /// The claim's authority now equals the highest authority of the objects it was read from.
    case followsObjectAuthority
    /// An object behind the claim is awaiting review.
    case objectAwaitingReview
    /// The claim was read from objects in different domains, which `Store.save` makes restricted.
    case mixedSourceDomains
    /// The claim's domain now equals its objects' domain.
    case followsObjectDomain
    case unexplained
}

/// One change to one claim, by id. A claim that changed twice has two rows.
public struct RebuildClaimChange: Codable, Sendable, Hashable, Identifiable {
    public var claimID: String
    public var kind: RebuildChangeKind
    public var reason: RebuildChangeReason
    public var subject: String
    public var predicate: String
    public var value: String
    public var domainBefore: String?
    public var domainAfter: String
    public var authorityBefore: Int?
    public var authorityAfter: Int
    /// The row that carries the statement now, or the row it came from.
    public var relatedClaimID: String?
    /// A new row held at the domain its earlier statement had, which is narrower than its object.
    public var heldAtEarlierDomain: Bool

    public var id: String { "\(claimID)|\(kind.rawValue)" }
}

public enum RebuildBeliefReason: String, Codable, Sendable, CaseIterable {
    /// `status` became dormant: no real work inside the threshold.
    case silencePassedThreshold
    /// The old winner led on authority its objects no longer have.
    case winnerLostItsAuthority
    /// The newest reading of the objects wins the slot.
    case newerReadingWins
    /// The slot had no belief, and has one now.
    case firstBeliefForSlot
}

/// One slot whose current belief changes value, or that gets its first.
public struct RebuildBeliefChange: Codable, Sendable, Hashable, Identifiable {
    public var claimKey: String
    public var subject: String
    public var predicate: String
    /// `nil` when the slot had no belief.
    public var before: String?
    public var after: String
    public var claimBefore: String?
    public var claimAfter: String
    public var reason: RebuildBeliefReason
    /// What the belief engine wrote down when it decided.
    public var engineReason: String

    public var id: String { claimKey }
}

public enum RebuildContradictionFate: String, Codable, Sendable, CaseIterable {
    /// Kept with the resolution it had.
    case kept
    /// Was open, and the rebuild's reconcile decided the same disagreement.
    case decidedByRebuild
    /// Resolved differently than before.
    case resolutionChanged
    /// Found by this rebuild.
    case new
}

/// One contradiction, by id.
public struct RebuildContradictionChange: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var fate: RebuildContradictionFate
    public var subject: String
    public var predicate: String
    public var resolutionBefore: String?
    public var resolutionAfter: String
    public var reason: String
}

/// Whether a past answer's trace still works, by running the trace.
public struct RebuildReceiptTrace: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// Every link it had still resolves, to the same text.
        case resolves
        /// It had no links, so its trace says why and a rebuild cannot change that.
        case noLinks
        /// It lost a link, or a link now cites different text.
        case broken
    }

    public var id: String
    public var code: String
    public var evidenceLinks: Int
    public var evidenceTraced: Int
    public var claimLinks: Int
    public var claimsResolved: Int
    public var outcome: Outcome
    public var detail: String
}

/// Everything a rehearsal changed, row by row. `RebuildDiff` holds the totals, and these lists
/// are what the totals are counting.
public struct RebuildExplanation: Codable, Sendable {
    public var claims: [RebuildClaimChange] = []
    public var beliefs: [RebuildBeliefChange] = []
    public var contradictions: [RebuildContradictionChange] = []
    public var receipts: [RebuildReceiptTrace] = []

    public init() {}

    public var unexplained: Int { claims.filter { $0.reason == .unexplained }.count }

    /// How many rows of one kind carry each reason.
    public func reasons(for kind: RebuildChangeKind) -> [(reason: RebuildChangeReason, count: Int)] {
        let rows = claims.filter { $0.kind == kind }
        return RebuildChangeReason.allCases.compactMap { reason in
            let count = rows.filter { $0.reason == reason }.count
            return count > 0 ? (reason, count) : nil
        }
    }
}

/// A claim as one side of a rehearsal saw it.
struct RebuildClaimFacts {
    struct Source: Hashable {
        var object: String
        var domain: String
        var authority: Int
        var awaitingReview: Bool
    }

    var id: String
    var key: String
    var subject: String
    var predicate: String
    var valueKey: String
    var value: String
    var domain: String
    var authority: Int
    var retired: Bool
    var sources: [Source]

    func sharesAnObject(with other: RebuildClaimFacts) -> Bool {
        !Set(sources.map(\.object)).isDisjoint(with: other.sources.map(\.object))
    }
}

enum RebuildExplainer {
    /// Give every changed claim a reason.
    ///
    /// Reads the facts on both sides and nothing else, so a reason is something a person can
    /// check against the two copies.
    /// `corrected` holds the ids retired because they say what the owner corrected.
    static func claimChanges(before: [RebuildClaimFacts], after: [RebuildClaimFacts], corrected: Set<String> = []) -> [RebuildClaimChange] {
        let earlier = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = after.filter { !$0.retired }
        let currentInSlot = Dictionary(grouping: current, by: \.key)
        let beforeInSlot = Dictionary(grouping: before, by: \.key)

        func change(_ claim: RebuildClaimFacts, _ kind: RebuildChangeKind, _ reason: RebuildChangeReason, was: RebuildClaimFacts?, related: String? = nil, held: Bool = false) -> RebuildClaimChange {
            RebuildClaimChange(
                claimID: claim.id, kind: kind, reason: reason, subject: claim.subject, predicate: claim.predicate,
                value: String(claim.value.prefix(160)), domainBefore: was?.domain, domainAfter: claim.domain,
                authorityBefore: was?.authority, authorityAfter: claim.authority, relatedClaimID: related, heldAtEarlierDomain: held
            )
        }

        /// A row elsewhere that says the same thing from an object this one was read from.
        func moved(_ claim: RebuildClaimFacts, among rows: [RebuildClaimFacts]) -> RebuildClaimFacts? {
            rows.first { $0.key != claim.key && $0.predicate == claim.predicate && $0.valueKey == claim.valueKey && $0.sharesAnObject(with: claim) }
        }

        var changes: [RebuildClaimChange] = []
        for claim in after {
            guard let was = earlier[claim.id] else {
                if claim.retired {
                    changes.append(change(claim, .addedAsHistory, corrected.contains(claim.id) ? .correctedByOwner : .replayedHistory, was: nil))
                    continue
                }
                let held = before.contains { $0.domain == claim.domain && $0.valueKey == claim.valueKey && $0.predicate == claim.predicate }
                    && !claim.sources.contains { $0.domain == claim.domain }
                    && !claim.sources.isEmpty
                if let twin = beforeInSlot[claim.key]?.first(where: { $0.valueKey == claim.valueKey }) {
                    changes.append(change(claim, .added, .sameStatementNewDate, was: twin, related: twin.id, held: held))
                } else if let origin = moved(claim, among: before) {
                    changes.append(change(claim, .added, .movedToAnotherSubject, was: origin, related: origin.id, held: held))
                } else if beforeInSlot[claim.key] != nil {
                    changes.append(change(claim, .added, .newValueInSlot, was: nil, held: held))
                } else {
                    changes.append(change(claim, .added, .newSlot, was: nil, held: held))
                }
                continue
            }

            if !was.retired, claim.retired {
                // Object facts from the pristine side: a retired row has no links to new objects.
                var asItWas = claim
                asItWas.sources = was.sources
                let slot = currentInSlot[claim.key] ?? []
                if let same = slot.first(where: { $0.valueKey == claim.valueKey && $0.id != claim.id }) {
                    changes.append(change(claim, .retired, .sameStatementNewDate, was: was, related: same.id))
                } else if let target = moved(asItWas, among: current) {
                    changes.append(change(claim, .retired, .movedToAnotherSubject, was: was, related: target.id))
                } else if let other = slot.first {
                    changes.append(change(claim, .retired, .replacedByNewValue, was: was, related: other.id))
                } else {
                    changes.append(change(claim, .retired, .noLongerDerived, was: was))
                }
            } else if was.retired, !claim.retired {
                changes.append(change(claim, .restored, .derivedAgain, was: was))
            }

            guard !was.retired, !claim.retired else { continue }
            if was.authority != claim.authority {
                let highest = claim.sources.map(\.authority).max()
                changes.append(change(claim, .authorityChanged, highest == claim.authority ? .followsObjectAuthority : .unexplained, was: was))
            }
            if Store.opennessRank(claim.domain) < Store.opennessRank(was.domain) {
                let reason: RebuildChangeReason
                if claim.sources.contains(where: \.awaitingReview) {
                    reason = .objectAwaitingReview
                } else if Set(claim.sources.map(\.domain)).count > 1 {
                    reason = .mixedSourceDomains
                } else if claim.sources.contains(where: { $0.domain == claim.domain }) {
                    reason = .followsObjectDomain
                } else {
                    reason = .unexplained
                }
                changes.append(change(claim, .domainLowered, reason, was: was))
            }
        }
        return changes.sorted { ($0.kind.rawValue, $0.reason.rawValue, $0.subject, $0.claimID) < ($1.kind.rawValue, $1.reason.rawValue, $1.subject, $1.claimID) }
    }
}

extension Store {
    /// Openness of a domain, matching `openness(_:)`, for code that already holds the rows.
    static func opennessRank(_ domain: String) -> Int {
        switch domain {
        case "medical", "financial", "relationship": 1
        case "personal": 2
        case "work": 3
        case "project": 4
        case "public": 5
        default: 0
        }
    }

    private static func claimFacts(_ connection: Connection, schema: String) throws -> [RebuildClaimFacts] {
        var sources: [String: [RebuildClaimFacts.Source]] = [:]
        for row in try connection.query(
            """
            SELECT ce.claim_id AS claim_id, o.id AS object, o.domain AS domain, o.authority AS authority,
                   json_extract(o.metadata, '$.classification_requires_rebuild') AS flag
            FROM \(schema).claim_evidence ce
            JOIN \(schema).evidence e ON e.id = ce.evidence_id
            JOIN \(schema).object o ON o.id = e.object_id
            WHERE ce.stance = 'supports'
            """
        ) {
            sources[row.requireString("claim_id"), default: []].append(.init(
                object: row.requireString("object"), domain: row.requireString("domain"),
                authority: row.requireInt("authority"), awaitingReview: row.string("flag") == "true"
            ))
        }
        return try connection.query(
            """
            SELECT c.id AS id, c.claim_key AS claim_key, COALESCE(e.canonical_name, '?') AS subject, c.predicate AS predicate,
                   COALESCE(c.object_entity, c.literal, '') AS value_key, COALESCE(o.canonical_name, c.literal, '?') AS value,
                   c.domain AS domain, c.authority AS authority, c.retracted_at IS NOT NULL AS retired
            FROM \(schema).claim c
            LEFT JOIN \(schema).entity e ON e.id = c.subject
            LEFT JOIN \(schema).entity o ON o.id = c.object_entity
            """
        ).map {
            let id = $0.requireString("id")
            return RebuildClaimFacts(
                id: id, key: $0.requireString("claim_key"), subject: $0.requireString("subject"),
                predicate: $0.requireString("predicate"), valueKey: $0.requireString("value_key"),
                value: $0.requireString("value"), domain: $0.requireString("domain"),
                authority: $0.requireInt("authority"), retired: $0.requireInt("retired") == 1,
                sources: sources[id] ?? []
            )
        }
    }

    /// Say what changed and why, row by row. Receipts are filled in by `receiptTraceAudit`.
    public func explain(againstPristine pristine: URL) async throws -> RebuildExplanation {
        try await database.withAttached(pristine, as: "pristine") { connection in
            var explanation = RebuildExplanation()
            let before = try Self.claimFacts(connection, schema: "pristine")
            let after = try Self.claimFacts(connection, schema: "main")
            let corrected = try connection.query(
                "SELECT c.id AS id FROM main.claim c WHERE c.retracted_at IS NOT NULL AND \(Self.saysWhatTheOwnerCorrected("c", schema: "main"))"
            ).map { $0.requireString("id") }
            explanation.claims = RebuildExplainer.claimChanges(before: before, after: after, corrected: Set(corrected))

            let facts = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let winner = { (schema: String) in
                """
                SELECT b.claim_key AS claim_key, b.claim_id AS claim_id, b.reason AS reason,
                       COALESCE((SELECT n.canonical_name FROM \(schema).entity n WHERE n.id = c.object_entity), c.literal, '') AS value
                FROM \(schema).belief b JOIN \(schema).claim c ON c.id = b.claim_id
                WHERE b.version = (SELECT MAX(v.version) FROM \(schema).belief v WHERE v.claim_key = b.claim_key)
                """
            }
            let changed = try connection.query(
                """
                SELECT now.claim_key AS claim_key, now.claim_id AS claim_after, now.value AS after, now.reason AS reason,
                       was.claim_id AS claim_before, was.value AS before
                FROM (\(winner("main"))) now LEFT JOIN (\(winner("pristine"))) was ON was.claim_key = now.claim_key
                WHERE was.claim_key IS NULL OR now.value != was.value
                ORDER BY now.claim_key
                """)
            explanation.beliefs = changed.map { row in
                let claimBefore = row.string("claim_before")
                let oldWinner = claimBefore.flatMap { facts[$0] }
                let newWinner = facts[row.requireString("claim_after")]
                let sourcesBefore = before.first { $0.id == claimBefore }?.sources ?? []
                let highestNow = sourcesBefore.compactMap { source in
                    after.lazy.flatMap(\.sources).first { $0.object == source.object }?.authority
                }.max()
                let reason: RebuildBeliefReason
                if claimBefore == nil {
                    reason = .firstBeliefForSlot
                } else if newWinner?.predicate == Predicate.status, row.requireString("after") == "dormant" {
                    reason = .silencePassedThreshold
                } else if let oldWinner, let highestNow, highestNow < oldWinner.authority {
                    reason = .winnerLostItsAuthority
                } else {
                    reason = .newerReadingWins
                }
                return RebuildBeliefChange(
                    claimKey: row.requireString("claim_key"), subject: newWinner?.subject ?? "?",
                    predicate: newWinner?.predicate ?? String(row.requireString("claim_key").split(separator: "|").last ?? ""),
                    before: row.string("before").map { String($0.prefix(160)) }, after: String(row.requireString("after").prefix(160)),
                    claimBefore: claimBefore, claimAfter: row.requireString("claim_after"),
                    reason: reason, engineReason: row.requireString("reason")
                )
            }

            let earlier = try connection.query("SELECT id, resolution FROM pristine.contradiction")
            let resolutions = Dictionary(earlier.map { ($0.requireString("id"), $0.requireString("resolution")) }, uniquingKeysWith: { first, _ in first })
            explanation.contradictions = try connection.query(
                """
                SELECT x.id AS id, x.resolution AS resolution, x.reason AS reason, x.claim_a AS claim_a
                FROM main.contradiction x ORDER BY x.detected_at, x.id
                """
            ).map { row in
                let id = row.requireString("id")
                let resolution = row.requireString("resolution")
                let was = resolutions[id]
                let fate: RebuildContradictionFate
                switch was {
                case nil: fate = .new
                case resolution: fate = .kept
                case Resolution.unresolved.rawValue: fate = .decidedByRebuild
                default: fate = .resolutionChanged
                }
                let claim = facts[row.requireString("claim_a")]
                return RebuildContradictionChange(
                    id: id, fate: fate, subject: claim?.subject ?? "?", predicate: claim?.predicate ?? "?",
                    resolutionBefore: was, resolutionAfter: resolution, reason: row.requireString("reason")
                )
            }
            return explanation
        }
    }

    /// Run the real trace for every receipt and compare it with what the earlier store returned.
    ///
    /// **The defect this replaces.** "Receipts still traced" counted `DISTINCT receipt_id` in
    /// `receipt_evidence`, so it reported 6 of 6 on a store of 30 receipts, and it only showed
    /// that a link row existed. A row whose evidence or object was gone still counted, and
    /// `Store.trace` drops that row with its inner joins and comes back short.
    public func receiptTraceAudit(againstEarlier earlier: URL) async throws -> [RebuildReceiptTrace] {
        let links = try await database.withAttached(earlier, as: "earlier") { connection in
            var evidence: [String: [String: String]] = [:]
            for row in try connection.query(
                """
                SELECT re.receipt_id AS receipt_id, re.evidence_id AS evidence_id, COALESCE(e.snippet, '') AS snippet
                FROM earlier.receipt_evidence re LEFT JOIN earlier.evidence e ON e.id = re.evidence_id
                """
            ) {
                evidence[row.requireString("receipt_id"), default: [:]][row.requireString("evidence_id")] = row.requireString("snippet")
            }
            var claims: [String: Set<String>] = [:]
            for row in try connection.query("SELECT receipt_id, claim_id FROM earlier.receipt_claim") {
                claims[row.requireString("receipt_id"), default: []].insert(row.requireString("claim_id"))
            }
            let found = Set(try connection.query(
                "SELECT rc.receipt_id || '|' || rc.claim_id AS link FROM earlier.receipt_claim rc JOIN main.claim c ON c.id = rc.claim_id JOIN main.receipt_claim m ON m.receipt_id = rc.receipt_id AND m.claim_id = rc.claim_id"
            ).map { $0.requireString("link") })
            return (evidence, claims, found)
        }

        var audit: [RebuildReceiptTrace] = []
        for receipt in try await receipts(limit: Int.max) {
            let id = receipt.id.value
            let cited = links.0[id] ?? [:]
            let claims = links.1[id] ?? []
            let traced = try await trace(receipt: receipt.id)
            let same = traced.filter { cited[$0.0.id.value] == $0.0.snippet }.count
            let resolved = claims.filter { links.2.contains("\(id)|\($0)") }.count

            let outcome: RebuildReceiptTrace.Outcome
            let detail: String
            if cited.isEmpty, claims.isEmpty {
                outcome = .noLinks
                if receipt.queryClass == .aggregate {
                    detail = "a computed count, which cites nothing by construction"
                } else if receipt.stages.contains(where: { $0.name == "activity" }) {
                    detail = "answered from the event log, which has no evidence rows"
                } else if !receipt.answeredFromClaims, receipt.evidenceAdmitted > 0 {
                    detail = "answered from passages, which leave no evidence rows"
                } else if receipt.evidenceAdmitted > 0 {
                    detail = "says it used evidence, but no links were saved when it was written"
                } else {
                    detail = "admitted no evidence"
                }
            } else if same == cited.count, resolved == claims.count {
                outcome = .resolves
                detail = "\(same) evidence row(s) and \(resolved) claim(s) resolve"
            } else {
                outcome = .broken
                detail = "\(same) of \(cited.count) evidence row(s) and \(resolved) of \(claims.count) claim(s) still resolve to the same text"
            }
            audit.append(RebuildReceiptTrace(
                id: id, code: receipt.shortCode, evidenceLinks: cited.count, evidenceTraced: same,
                claimLinks: claims.count, claimsResolved: resolved, outcome: outcome, detail: detail
            ))
        }
        return audit
    }
}
