import CoreModel
import CoreStore
import Foundation

/// Finds claims that cannot both be true, decides which one currently stands, and records
/// the decision as a new belief version rather than an overwrite.
///
/// The scope rule that keeps this honest: **only functional predicates can contradict.**
/// A project genuinely is built with Swift *and* Python, so two `built_with` claims are
/// two facts, not a conflict. A project has exactly one `primary_language` at a time, so
/// two current `primary_language` claims mean something changed and the system has not
/// noticed yet. Treating every repeated predicate as a conflict is how these systems end
/// up manufacturing drama out of ordinary multi-valued data.
public struct BeliefEngine: Sendable {
    private let store: Store
    private let now: Date

    public init(store: Store, now: Date = Date()) {
        self.store = store
        self.now = now
    }

    public struct Outcome: Sendable {
        public var contradictionsFound: Int = 0
        public var resolved: Int = 0
        public var unresolved: Int = 0
        public var beliefsWritten: Int = 0
        public var claimsRetracted: Int = 0
    }

    @discardableResult
    public func reconcile() async throws -> Outcome {
        var outcome = Outcome()
        var contradictions: [Contradiction] = []

        for key in try await store.contestedClaimKeys() {
            let predicate = String(key.split(separator: "|").last ?? "")
            guard Predicate.functional.contains(predicate) else { continue }

            let claims = try await store.claims(key: key).filter { $0.validity.isCurrent }
            guard claims.count > 1 else { continue }

            // Distinct values only. Two identical claims from two sources agree; they are
            // corroboration, and corroboration is not a contradiction.
            let byValue = Dictionary(grouping: claims) { value(of: $0) }
            guard byValue.count > 1 else { continue }

            let representatives = byValue.values.compactMap { group in
                group.max { rank($0) < rank($1) }
            }
            guard let winner = representatives.max(by: { rank($0) < rank($1) }) else { continue }

            for loser in representatives where loser.id != winner.id {
                let verdict = adjudicate(winner: winner, loser: loser)
                contradictions.append(Contradiction(
                    claimA: winner.id,
                    claimB: loser.id,
                    kind: verdict.kind,
                    resolution: verdict.resolution,
                    winner: verdict.resolution == .unresolved ? nil : winner.id,
                    detectedAt: now,
                    reason: verdict.reason
                ))
                outcome.contradictionsFound += 1

                if verdict.resolution == .unresolved {
                    outcome.unresolved += 1
                } else {
                    outcome.resolved += 1
                    // Retract, never delete. `valid_to` closes the world-time interval so
                    // "what was the primary language in March" still resolves correctly.
                    try await store.retract(loser.id, at: now)
                    outcome.claimsRetracted += 1
                }
            }

            if try await recordBelief(key: key, winner: winner, alternatives: representatives.count - 1) {
                outcome.beliefsWritten += 1
            }
        }

        // Uncontested functional claims still deserve a belief row, so `memory log` shows
        // the moment something was first believed and not only the moment it changed.
        //
        // **One belief per slot, not one per claim row.** This used to call `recordBelief`
        // for every current functional claim individually, and a slot routinely holds several
        // rows that say exactly the same thing: `ClaimID` is derived partly from
        // `validity.validFrom`, so every GitHub push mints a *new* claim id for the unchanged
        // `status = active`. Each call then saw a `winner.id` different from the one on the
        // stored belief, so each wrote a version, and the next sync wrote more. Measured on
        // the real store before this fix: 4 slots holding 5 versions each, 16 of the 17
        // recorded belief changes reading `changed from 'active' to 'active'`.
        //
        // Picking the ranked best also makes the winner deterministic. Previously it was
        // whichever row `allClaims` happened to return last, which is row order, not evidence.
        var bestPerKey: [String: CoreClaim] = [:]
        for claim in try await store.allClaims(currentOnly: true, limit: 5_000) {
            guard Predicate.functional.contains(claim.predicate) else { continue }
            if let held = bestPerKey[claim.claimKey], rank(held) >= rank(claim) { continue }
            bestPerKey[claim.claimKey] = claim
        }
        for (key, winner) in bestPerKey {
            if try await recordBelief(key: key, winner: winner, alternatives: 0) {
                outcome.beliefsWritten += 1
            }
        }

        try await store.save(contradictions)
        return outcome
    }

    // MARK: - Adjudication

    /// Ordering used to pick a winner. Authority dominates; world-time recency breaks ties
    /// within a tier; confidence breaks what is left.
    ///
    /// Authority is compared, never multiplied. A `directStatement` beats an
    /// `authoredArtifact` because the user said so, not because 5 > 4 arithmetically.
    /// What a claim asserts, for grouping, comparison and display.
    ///
    /// One helper because there were two orderings of the same coalesce in this file, and a
    /// value compared one way and printed the other is the kind of disagreement that only
    /// shows up in a screenshot.
    private func value(of claim: CoreClaim) -> String {
        claim.objectEntity?.value ?? claim.literal ?? "∅"
    }

    private func rank(_ claim: CoreClaim) -> (Int, TimeInterval, Double) {
        (
            claim.authority.rawValue,
            (claim.validity.validFrom ?? claim.validity.observedAt).timeIntervalSince1970,
            claim.confidence
        )
    }

    private struct Verdict {
        var kind: ContradictionKind
        var resolution: Resolution
        var reason: String
    }

    private func adjudicate(winner: CoreClaim, loser: CoreClaim) -> Verdict {
        if winner.authority > loser.authority {
            return Verdict(
                kind: .directConflict,
                resolution: .supersededByAuthority,
                reason: "\(winner.authority.label) outranks \(loser.authority.label) for the same slot"
            )
        }

        let winnerTime = winner.validity.validFrom ?? winner.validity.observedAt
        let loserTime = loser.validity.validFrom ?? loser.validity.observedAt
        if winnerTime > loserTime {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return Verdict(
                kind: .temporalSupersession,
                resolution: .supersededByRecency,
                reason: "observed \(formatter.string(from: winnerTime)), superseding \(formatter.string(from: loserTime))"
            )
        }

        // Same authority, no usable ordering. Say so rather than picking one and
        // presenting the coin flip as a conclusion.
        return Verdict(
            kind: .directConflict,
            resolution: .unresolved,
            reason: "equal authority (\(winner.authority.label)) and no temporal ordering; both retained"
        )
    }

    // MARK: - Belief versioning

    /// Returns true if a new belief version was written.
    ///
    /// **A version records a change of mind.** Re-observing the same fact is not one. The
    /// guard here used to compare only `claimID`, which asks "did a different row win" rather
    /// than "does the winner say something different", and those are not the same question
    /// when a slot holds several rows asserting the same value. See the grouping in
    /// `reconcile` for why it does.
    private func recordBelief(key: String, winner: CoreClaim, alternatives: Int) async throws -> Bool {
        let current = try await store.currentBelief(key: key)
        if let current, current.claimID == winner.id { return false }

        var previousClaim: CoreClaim?
        if let current { previousClaim = try await store.claim(current.claimID) }

        // Same value at the same authority is corroboration, not supersession. Authority is
        // part of the test on purpose: a user correction that re-asserts the value already
        // held *is* a change worth versioning, because what changed is how well the claim is
        // known, and that is the whole point of an ordinal authority tier.
        if let previousClaim,
           value(of: previousClaim) == value(of: winner),
           previousClaim.authority == winner.authority {
            return false
        }

        let reason: String
        if let previousClaim {
            reason = "changed from '\(value(of: previousClaim))' to '\(value(of: winner))'"
        } else if alternatives > 0 {
            reason = "selected over \(alternatives) competing claim\(alternatives == 1 ? "" : "s")"
        } else {
            reason = "first evidence for this slot"
        }

        try await store.save(Belief(
            claimKey: key,
            version: (current?.version ?? 0) + 1,
            claimID: winner.id,
            confidence: winner.confidence,
            authority: winner.authority,
            validity: winner.validity,
            supersedes: current?.id,
            reason: reason,
            decidedAt: now
        ))
        return true
    }
}

// MARK: - Corrections

extension BeliefEngine {
    /// Apply a user correction.
    ///
    /// The correction does not edit the wrong claim. It asserts a new one at
    /// `directStatement` authority, retracts the old, and stores *why the old one was
    /// reachable* — which is the part that lets the extractor get fixed instead of the
    /// symptom getting patched.
    public func correct(
        supersedingClaim wrong: ClaimID?,
        with asserted: CoreClaim,
        reason: String,
        priorFailure: String?
    ) async throws {
        var claim = asserted
        claim.authority = .directStatement
        claim.derivation = .corrected
        claim.confidence = 1.0

        try await store.save([claim])

        if let wrong {
            try await store.retract(wrong, at: now)
            try await store.save([Contradiction(
                claimA: claim.id,
                claimB: wrong,
                kind: .directConflict,
                resolution: .resolvedByCorrection,
                winner: claim.id,
                detectedAt: now,
                reason: reason
            )])
        }

        try await store.save(Correction(
            supersededClaim: wrong,
            assertedClaim: claim.id,
            reason: reason,
            priorFailure: priorFailure,
            createdAt: now
        ))

        _ = try await recordBelief(key: claim.claimKey, winner: claim, alternatives: wrong == nil ? 0 : 1)
    }
}
