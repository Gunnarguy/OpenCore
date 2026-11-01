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
        /// Open contradictions no earlier pass recorded. `unresolved` is every open slot, and
        /// `reconcile` is global, so that number repeats on every pass whether or not anything
        /// happened. An alert driven by it fired "2 Unresolved Contradictions" on every sync.
        public var newlyOpened: [ContradictionID] = []
        /// Claims a newer revision of their own document replaced, which no contradiction records.
        public var documentSuccessions: Int = 0
    }

    @discardableResult
    public func reconcile() async throws -> Outcome {
        var outcome = Outcome()
        var contradictions: [Contradiction] = []
        /// Slots where adjudication declined to pick. Collected because **both** loops below
        /// would otherwise write a belief for them, and the second one is the easier to miss.
        var undecided: Set<String> = []
        /// Open this pass, with what makes each one the disagreement it is.
        var opened: [(id: ContradictionID, disagreement: String)] = []
        let knownDisagreements = try await recordedDisagreements()

        for key in try await store.contestedClaimKeys() {
            let predicate = String(key.split(separator: "|").last ?? "")
            guard Predicate.functional.contains(predicate) else { continue }

            var claims = try await store.claims(key: key).filter { $0.validity.isCurrent }
            guard claims.count > 1 else { continue }

            // A record rewriting itself is not two sources disagreeing. Settled first, by time,
            // because everything below compares authority and would let an old revision beat a
            // new one.
            var valuesWithRow: Set<String> = []
            for revision in try await revisions(among: claims).sorted(by: { isEarlierReading($1.retired, $0.retired) }) {
                try await store.retract(revision.retired.id, at: now)
                outcome.claimsRetracted += 1
                try await recordRetirement(of: revision.retired, by: revision.current)
                claims.removeAll { $0.id == revision.retired.id }

                if revision.isDocument {
                    outcome.documentSuccessions += 1
                } else if valuesWithRow.insert(value(of: revision.retired)).inserted {
                    // A repository's status or language changing is a thing that happened, and
                    // it is rare, so it keeps its row: one for the change, however many stale rows
                    // said the old value, and newest first so it names the last of them. A handoff
                    // is rewritten every session, so the same row for a document only buried the
                    // rows worth reading.
                    contradictions.append(Contradiction(
                        claimA: revision.current.id,
                        claimB: revision.retired.id,
                        kind: .temporalSupersession,
                        resolution: .supersededByRecency,
                        winner: revision.current.id,
                        detectedAt: now,
                        // Read dates, because they order a record. A status's own date can be a
                        // threshold nothing observed, or a push from before the change.
                        reason: "read \(day(revision.current.validity.observedAt)), superseding the reading of \(day(revision.retired.validity.observedAt))"
                    ))
                    outcome.contradictionsFound += 1
                    outcome.resolved += 1
                }
            }

            // Distinct values only. Two identical claims from two sources agree; they are
            // corroboration, and corroboration is not a contradiction.
            let byValue = Dictionary(grouping: claims) { value(of: $0) }
            guard byValue.count > 1 else { continue }

            // Sorted because `byValue.values` changes order per process. Three values tied on rank
            // otherwise chose a different winner in a different process, and that recorded a pair
            // no pass had seen: a new open row and a new alert on a store where nothing changed.
            let representatives = byValue.values.compactMap { $0.max(by: ranksBelow) }.sorted(by: ranksBelow)
            guard let winner = representatives.last else { continue }

            for loser in representatives where loser.id != winner.id {
                let verdict = adjudicate(winner: winner, loser: loser)
                let contradiction = Contradiction(
                    claimA: winner.id,
                    claimB: loser.id,
                    kind: verdict.kind,
                    resolution: verdict.resolution,
                    winner: verdict.resolution == .unresolved ? nil : winner.id,
                    detectedAt: now,
                    reason: verdict.reason
                )
                contradictions.append(contradiction)
                outcome.contradictionsFound += 1
                try await recordCounterEvidence(between: winner, and: loser)

                if verdict.resolution == .unresolved {
                    outcome.unresolved += 1
                    undecided.insert(key)
                    opened.append((contradiction.id, disagreement(in: key, between: winner, and: loser)))
                } else {
                    outcome.resolved += 1
                    // Retract, never delete. `valid_to` closes the world-time interval so
                    // "what was the primary language in March" still resolves correctly.
                    try await store.retract(loser.id, at: now)
                    outcome.claimsRetracted += 1
                }
            }

            // Nothing is written when the engine declined to choose. This used to run
            // unconditionally, so a slot could carry a contradiction reading "equal authority
            // and no temporal ordering; both retained" while the Beliefs screen showed one of
            // the two as a settled value labelled "selected over 1 competing claim". Saying
            // out loud that a coin flip is not a conclusion, and then recording the coin flip,
            // is the one failure this project cannot afford: the whole argument is that an
            // absent belief is an honest answer.
            //
            // The existing belief, if any, is left alone rather than retracted. It was a real
            // decision when it was made, and deleting it to record a change of mind is exactly
            // what the append-only rule forbids.
            if undecided.contains(key) { continue }

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
        for claim in try await store.allClaims(currentOnly: true, limit: .max) {
            guard Predicate.functional.contains(claim.predicate) else { continue }
            if let held = bestPerKey[claim.claimKey], !ranksBelow(held, claim) { continue }
            bestPerKey[claim.claimKey] = claim
        }
        for (key, winner) in bestPerKey {
            // The same exclusion, and the reason it is a separate line rather than one guard:
            // an undecided slot's claims are all still current, precisely because none was
            // retracted, so this loop sees them as an ordinary uncontested slot and would
            // cheerfully pick the top-ranked one. Fixing only the loop above would have moved
            // the bug rather than removed it.
            if undecided.contains(key) { continue }
            if try await recordBelief(key: key, winner: winner, alternatives: 0) {
                outcome.beliefsWritten += 1
            }
        }

        outcome.newlyOpened = opened.filter { !knownDisagreements.contains($0.disagreement) }.map(\.id)
        try await store.save(contradictions)
        try await closeSettledContradictions()
        return outcome
    }

    // MARK: - Revisions of one record

    /// One value replaced by a newer reading of the record that stated it.
    private struct Revision {
        var retired: CoreClaim
        var current: CoreClaim
        var isDocument: Bool
    }

    /// Where a claim was read from, for asking whether that place has since said otherwise.
    private struct Origin: Hashable {
        var identity: String
        var isDocument: Bool
    }

    /// The claims in one slot that a newer reading of their own record has replaced.
    ///
    /// **The defect.** A handoff document says what is true now, and the next one says what is
    /// true next. Those are not two sources disagreeing, yet every rewrite became a contradiction
    /// row, and because authority came before time, the older revision could win. It did: 70
    /// objects from an old `/private/tmp` copy of the repositories sat at a higher tier than the
    /// real files, so OpenCore's own objective froze on a superseded sentence, two newer values
    /// were retracted, and the screen said "authored artifact outranks generated summary" about
    /// the same document. Of 14 contradictions on the real store, 6 were this.
    ///
    /// A repository record has the same shape and the same trap: `archived` is observed and
    /// `active` is inferred, so a repository brought back from the archive stayed archived for
    /// good, because the record's own newer reading ranked below its older one.
    ///
    /// **Order within a document** is the claim's world time, then when OpenCore read it, because
    /// an old copy of a file can be read after the new one.
    ///
    /// **Order within a repository record** is the other way round: when it was read, then world
    /// time. There is one record, so a later reading is what it says now. World time can't order
    /// these. `dormant` is dated by a threshold and `archived` by the last push, and the connector
    /// records no archive date, so a repository archived after going quiet read `dormant` as
    /// newest, an inferred status retired the observed one, and an archived repository can't be
    /// pushed to, so that stood for good. Restoring it with no new push failed the same way, as
    /// `active` is dated by the last real work. Language needs this too: GitHub recomputes it after
    /// a push, so two readings can share a date and differ. Both of the store's open contradictions
    /// were that, and the later reading matched GitHub. Two readings from one pass with the same
    /// world time have no order at all, and the slot falls through to ordinary adjudication.
    ///
    /// **A claim retires only when everything behind it has moved on.** The same value can reach
    /// a slot from two documents, and one of them changing its mind says nothing about the other.
    /// A claim with no recorded origin, such as a correction, is never retired here.
    private func revisions(among claims: [CoreClaim]) async throws -> [Revision] {
        var originsByClaim: [ClaimID: Set<Origin>] = [:]
        var statedBy: [Origin: [CoreClaim]] = [:]
        for claim in claims {
            let origins = try await origins(of: claim)
            originsByClaim[claim.id] = origins
            for origin in origins { statedBy[origin, default: []].append(claim) }
        }

        // What each origin says now. An origin whose newest readings tie and differ says nothing
        // that can be acted on. A model's reading of a document is a proposal about it, not the
        // document speaking, so it takes no part here in either direction: this step runs before
        // anything looks at authority, and a proposal must not reach past that floor through it.
        // Adjudication settles proposals below, where the row says why one lost.
        var latest: [Origin: CoreClaim] = [:]
        for (origin, stated) in statedBy {
            let spoken = stated.filter { $0.authority != .modelInference }
            let order = origin.isDocument ? isOlder : isEarlierReading
            guard let newest = spoken.max(by: order) else { continue }
            let tied = spoken.filter { !order($0, newest) }
            if Set(tied.map(value(of:))).count == 1 { latest[origin] = newest }
        }

        var revisions: [Revision] = []
        for claim in claims where claim.authority != .modelInference {
            guard let origins = originsByClaim[claim.id], !origins.isEmpty else { continue }
            // Sorted because a set's order changes per process and a rebuild must reproduce a row.
            let replacements = origins.sorted { $0.identity < $1.identity }.compactMap { latest[$0] }
            guard replacements.count == origins.count,
                  replacements.allSatisfy({ value(of: $0) != value(of: claim) }),
                  let current = replacements.max(by: isOlder)
            else { continue }
            revisions.append(Revision(retired: claim, current: current, isDocument: origins.allSatisfy(\.isDocument)))
        }
        return revisions
    }

    /// Where a claim was read from.
    ///
    /// A file is known by its name, because the same `STATE.md` reaches the store through several
    /// sources and paths, and a `/private/tmp` copy is a different object and the same document.
    /// Within one slot, which is one subject and one predicate, a `README.md` and a `STATE.md` are
    /// two documents and stay a real disagreement. Measured 2026-10-31: every functional slot
    /// fed by two same-named files on the real store was one file under two roots.
    private func origins(of claim: CoreClaim) async throws -> Set<Origin> {
        var origins: Set<Origin> = []
        for (evidence, _, _) in try await store.evidence(for: claim.id, stance: .supports) {
            guard let object = try await store.object(evidence.objectID) else { continue }
            if object.kind == .file, let name = object.externalID.split(separator: "/").last {
                origins.insert(Origin(identity: "file:\(name.lowercased())", isDocument: true))
            } else {
                origins.insert(Origin(identity: "object:\(object.id.value)", isDocument: object.kind != .repository))
            }
        }
        return origins
    }

    private func isOlder(_ first: CoreClaim, _ second: CoreClaim) -> Bool {
        (time(of: first), first.validity.observedAt) < (time(of: second), second.validity.observedAt)
    }

    private func isEarlierReading(_ first: CoreClaim, _ second: CoreClaim) -> Bool {
        (first.validity.observedAt, time(of: first)) < (second.validity.observedAt, time(of: second))
    }

    private func time(of claim: CoreClaim) -> Date {
        claim.validity.validFrom ?? claim.validity.observedAt
    }

    private func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    /// Counter-evidence is a row, never an absence: each claim's support is recorded as `.refutes`
    /// on the other, so inspecting either surfaces what argued against it.
    ///
    /// **Evidence both claims rest on is skipped.** `claim_evidence` holds one stance per pair, and
    /// a repository record's evidence has no byte range, so every reading of one repository shares
    /// a single evidence row. Writing `.refutes` over it erased the claim's own `.supports`: on the
    /// real store 14 claims had no support left, 9 of them current, and each cited its own
    /// evidence as refuting it. An answer drops a claim with no support, so those statuses and
    /// languages could vanish from answers. A shared row is what is left when time alone changed
    /// the conclusion, and it argues for neither side.
    private func recordCounterEvidence(between first: CoreClaim, and second: CoreClaim) async throws {
        let firstSupport = (try? await store.evidence(for: first.id, stance: .supports)) ?? []
        let secondSupport = (try? await store.evidence(for: second.id, stance: .supports)) ?? []
        let shared = Set(firstSupport.map(\.0.id)).intersection(secondSupport.map(\.0.id))
        for (evidence, _, weight) in firstSupport where !shared.contains(evidence.id) {
            try? await store.link(claim: second.id, to: evidence.id, stance: .refutes, weight: weight)
        }
        for (evidence, _, weight) in secondSupport where !shared.contains(evidence.id) {
            try? await store.link(claim: first.id, to: evidence.id, stance: .refutes, weight: weight)
        }
    }

    /// What a retired claim records about why it retired.
    ///
    /// One way only, unlike a disagreement. A record's older reading doesn't argue against its
    /// newer one. Writing both ways gave the current objective every earlier sentence of its own
    /// file as `.refutes`, one more per rewrite, with no contradiction row to explain them, and an
    /// answer and a receipt present those as evidence against the line.
    ///
    /// Evidence both claims rest on can't carry the stance, as the note above says, so the retired
    /// claim gets its own row at the same place. It reads what the current claim's row reads, and
    /// without it a retired reading of a repository records nothing at all.
    private func recordRetirement(of retired: CoreClaim, by current: CoreClaim) async throws {
        let own = Set(try await store.evidence(for: retired.id, stance: .supports).map(\.0.id))
        for (evidence, _, weight) in try await store.evidence(for: current.id, stance: .supports) {
            guard own.contains(evidence.id) else {
                try await store.link(claim: retired.id, to: evidence.id, stance: .refutes, weight: weight)
                continue
            }
            let counter = Evidence(
                objectID: evidence.objectID, range: evidence.range, snippet: evidence.snippet,
                authority: evidence.authority, reading: "refutes:\(current.id.value)"
            )
            try await store.save([counter])
            try await store.link(claim: retired.id, to: counter.id, stance: .refutes, weight: weight)
        }
    }

    // MARK: - What counts as new

    /// A slot and the two values disagreeing in it, whatever rows happen to be asserting them.
    ///
    /// A claim id includes the claim's date, so re-saving two tied documents mints new ids for an
    /// old argument. Keying "new" on the row called that a new contradiction and raised the alert
    /// again. Two values in one slot are one disagreement however many dates they have carried.
    private func disagreement(in key: String, between first: CoreClaim, and second: CoreClaim) -> String {
        ([key] + [value(of: first), value(of: second)].sorted()).joined(separator: "\u{1F}")
    }

    /// Every disagreement any pass has recorded, open or settled.
    private func recordedDisagreements() async throws -> Set<String> {
        var recorded: Set<String> = []
        for row in try await store.contradictions() {
            guard let first = try await store.claim(row.claimA),
                  let second = try await store.claim(row.claimB)
            else { continue }
            recorded.insert(disagreement(in: first.claimKey, between: first, and: second))
        }
        return recorded
    }

    /// Closes open contradictions a later pass has settled by retiring one side.
    ///
    /// A row stays in the table forever and only its resolution changes, so without this a slot
    /// that resolved under a new pair of claims left its old pair reading "unresolved" for good.
    private func closeSettledContradictions() async throws {
        var closed: [Contradiction] = []
        for var open in try await store.contradictions(unresolvedOnly: true) {
            guard let claimA = try await store.claim(open.claimA),
                  let claimB = try await store.claim(open.claimB)
            else { continue }
            switch (claimA.validity.isCurrent, claimB.validity.isCurrent) {
            case (true, false): open.winner = open.claimA
            case (false, true): open.winner = open.claimB
            // Both sides were replaced by something newer, so neither won and nothing is open.
            case (false, false): open.winner = nil
            case (true, true): continue
            }
            open.resolution = .supersededByRecency
            open.reason += "; settled later when the other claim was superseded"
            closed.append(open)
        }
        try await store.save(closed)
    }

    // MARK: - Adjudication

    /// What a claim asserts, for grouping, comparison and display.
    ///
    /// One helper because there were two orderings of the same coalesce in this file, and a
    /// value compared one way and printed the other is the kind of disagreement that only
    /// shows up in a screenshot.
    private func value(of claim: CoreClaim) -> String {
        claim.objectEntity?.value ?? claim.literal ?? "∅"
    }

    /// Human-readable claim value for belief reason strings.
    ///
    /// `value(of:)` uses raw `EntityID` hashes so distinct entities never collide when
    /// grouping by canonical name, whereas `Belief.reason` is read by a person in the UI
    /// and CLI and must show the resolved entity name rather than a 16-character hex hash.
    private func displayValue(of claim: CoreClaim) async throws -> String {
        if let objectEntity = claim.objectEntity, let resolved = try await store.entity(objectEntity) {
            return resolved.canonicalName
        }
        return claim.literal ?? claim.objectEntity?.value ?? "∅"
    }

    /// Where a claim stands before time is consulted.
    ///
    /// For almost every predicate that is its authority. **The exception is what a working
    /// document says about itself.** The tier of an objective records where a file sat when it was
    /// read, and the same `STATE.md` read 2 from one root and 4 from another, so it says nothing
    /// about which of two statements is current. Those tiers compare equal and time decides.
    ///
    /// The ends stay apart on purpose. A model may only propose, so a newer proposal must never
    /// displace something a person wrote or a rule derived, and a correction is the owner speaking,
    /// so a newer file does not overrule it. This compares tiers and never does arithmetic on them.
    private func standing(_ claim: CoreClaim) -> Int {
        guard Predicate.documentRestated.contains(claim.predicate) else { return claim.authority.rawValue }
        switch claim.authority {
        case .modelInference: return 0
        case .derivedPattern: return 1
        case .generatedSummary, .thirdPartyRecord, .authoredArtifact: return 2
        case .directStatement: return 3
        }
    }

    /// Ordering used to pick a winner: standing, then world time, then authority within a standing,
    /// then confidence. Authority is compared, never multiplied. A `directStatement` beats an
    /// `authoredArtifact` because the user said so, not because 5 > 4 arithmetically.
    private func rank(_ claim: CoreClaim) -> (Int, TimeInterval, Int, Double) {
        (standing(claim), time(of: claim).timeIntervalSince1970, claim.authority.rawValue, claim.confidence)
    }

    /// `rank` made a total order, so a tie comes out the same way in every process. The value
    /// breaks a tie only to pick which claim is named first. Adjudication still calls it undecided.
    private func ranksBelow(_ first: CoreClaim, _ second: CoreClaim) -> Bool {
        if rank(first) != rank(second) { return rank(first) < rank(second) }
        return (value(of: first), first.id.value) < (value(of: second), second.id.value)
    }

    private struct Verdict {
        var kind: ContradictionKind
        var resolution: Resolution
        var reason: String
    }

    /// Why `winner` stands, in words that stay true when someone reads them on the screen.
    ///
    /// Authority used to be reported without saying what it had overridden, so "authored artifact
    /// outranks generated summary" sat over an old sentence beating a newer one and read like a
    /// finding. Authority can still beat recency, and it must, for a model proposal or a
    /// correction. When it does, the reason now says so and gives both dates.
    private func adjudicate(winner: CoreClaim, loser: CoreClaim) -> Verdict {
        let winnerTime = time(of: winner)
        let loserTime = time(of: loser)
        let outranked = "\(winner.authority.label) outranks \(loser.authority.label) for the same slot"

        if standing(winner) > standing(loser) {
            let overridden = loserTime > winnerTime
                ? ", although the other claim is newer (\(day(loserTime)) against \(day(winnerTime)))"
                : ""
            return Verdict(kind: .directConflict, resolution: .supersededByAuthority, reason: outranked + overridden)
        }

        if winnerTime > loserTime {
            return Verdict(
                kind: .temporalSupersession,
                resolution: .supersededByRecency,
                reason: "dated \(day(winnerTime)), superseding \(day(loserTime))"
            )
        }

        // Tied in time and apart in tier. Reachable only where tiers share a standing, and the
        // tier is then the one thing left that separates them.
        if winner.authority > loser.authority {
            return Verdict(kind: .directConflict, resolution: .supersededByAuthority, reason: outranked + ", with no difference in date")
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

        // Same value at the same standing is corroboration, not supersession. Standing is part
        // of the test on purpose: a user correction that re-asserts the value already held *is* a
        // change worth versioning, because what changed is how well the claim is known, and that
        // is the whole point of an ordinal authority tier. A handoff re-read from another root
        // changes nothing about how well it is known, which is why this is not raw authority.
        if let previousClaim,
           value(of: previousClaim) == value(of: winner),
           standing(previousClaim) == standing(winner) {
            return false
        }

        let reason: String
        if let previousClaim {
            let previousDisplay = try await displayValue(of: previousClaim)
            let winnerDisplay = try await displayValue(of: winner)
            if previousDisplay == winnerDisplay {
                reason = "re-asserted '\(winnerDisplay)' at \(winner.authority.label) (was \(previousClaim.authority.label))"
            } else {
                reason = "changed from '\(previousDisplay)' to '\(winnerDisplay)'"
            }
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
            var updatedContradictions: [Contradiction] = [
                Contradiction(
                    claimA: claim.id,
                    claimB: wrong,
                    kind: .directConflict,
                    resolution: .resolvedByCorrection,
                    winner: claim.id,
                    detectedAt: now,
                    reason: reason
                ),
            ]
            let openConflicts = try await store.contradictions(unresolvedOnly: true)
            for var open in openConflicts where open.claimA == wrong || open.claimB == wrong {
                open.resolution = .resolvedByCorrection
                open.winner = open.claimA == wrong ? open.claimB : open.claimA
                open.reason = reason
                updatedContradictions.append(open)
            }
            try await store.save(updatedContradictions)
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
