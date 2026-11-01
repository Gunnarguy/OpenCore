import CoreModel
import Foundation
import Testing

@testable import CoreGraph
@testable import CoreStore

private func workspace() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-rehearsal-\(UUID().uuidString)", isDirectory: true)
}

private func temporaryStore(in folder: URL) async throws -> Store {
    try await Store.open(at: folder.appendingPathComponent("store.sqlite3"))
}

private let github = Source(kind: .github, handle: "user", displayName: "GitHub", defaultAuthority: .authoredArtifact, defaultDomain: .project)
private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private let day: TimeInterval = 86_400

private func repository(_ name: String = "Atlas", language: String = "Swift", pushed: Date) -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .repository, externalID: "user/\(name)", title: name,
        text: "user/\(name)\n\(name) is a repository.", authoredAt: pushed.addingTimeInterval(-100 * day),
        domain: .project, authority: .authoredArtifact,
        metadata: ["language": language, "archived": "false", "pushed_at": stamp(pushed)]
    )
}

private func populated(in folder: URL, now: Date) async throws -> (Store, CoreObject) {
    let store = try await temporaryStore(in: folder)
    try await store.upsert(github)
    let object = repository(pushed: now.addingTimeInterval(-5 * day))
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-4 * day)).run(objects: [object, repository("Beacon", pushed: now.addingTimeInterval(-6 * day))])
    return (store, object)
}

private func supportingEvidence(_ store: Store) async throws -> Evidence {
    let claim = try #require(try await store.claims(subject: subject()).first)
    return try #require(try await store.evidence(for: claim.id, stance: .supports).first?.0)
}

private func subject(_ name: String = "Atlas") -> EntityID {
    CoreEntity(kind: .project, canonicalName: name, domain: .project).id
}

// The bug: "Run Deterministic Rebuild Check" deleted every derived table in the live store. It
// was not a check, and rehearsing must leave the store exactly as it found it.
@Test("rehearsing changes nothing in the store it was pointed at")
func rehearsalLeavesTheStoreAlone() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let before = try await store.floorSignature()
    let claimsBefore = try await store.claimCount()

    _ = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))

    #expect(try await store.floorSignature() == before)
    #expect(try await store.claimCount() == claimsBefore)
}

// The bug: claim domains come from object domains, so a re-derive returned quarantined claims to
// readable domains. Traced on the real store, 327 of 519 would have reached MCP-readable domains,
// and row counts would not have moved, so the old verdict still read "Reproduced 100% Exactly".
@Test("quarantine survives a rebuild, and a rehearsal that lifted it could not be applied")
func quarantineHolds() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)
    _ = try await store.reclassifyObjects([.init(objectID: object.id, domain: .project, authority: .generatedSummary, reason: "review pending")], dryRun: false)
    _ = try await store.database.execute("UPDATE claim SET domain = 'restricted' WHERE subject = ?", [.text(subject().value)])

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))

    #expect(report.diff.domainsRaised == 0)
    #expect(report.diff.quarantineHeld > 0)
    #expect(report.canApply)

    var raised = RebuildDiff()
    raised.domainsRaised = 3
    #expect(!RebuildRehearsal.blockers(in: raised).isEmpty)
}

// Two guards, so two tests. This one has no flagged object at all: the claim is restricted only
// in the graph, and only the carry from the pristine copy can keep it there.
@Test("a claim restricted in the graph stays restricted with no flag on its object")
func quarantineByClaimHolds() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    _ = try await store.database.execute("UPDATE claim SET domain = 'restricted' WHERE subject = ?", [.text(subject().value)])

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.domainsRaised == 0)
    #expect(report.canApply)
}

// The other guard: a claim the rebuild derives for the first time from an object still awaiting
// review has no pristine row to copy a domain from. Its object's flag has to be enough.
@Test("a claim derived from an object awaiting review joins the quarantine")
func quarantineByObjectHolds() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)
    _ = try await store.updateObjectMetadata(object.id, merging: ["classification_requires_rebuild": "true"])
    // Delete the row so the rebuild has to mint it again, as a new extraction rule would.
    let rows = try await store.claims(subject: subject())
    let status = try #require(rows.first { $0.predicate == Predicate.status })
    _ = try await store.database.execute("DELETE FROM claim WHERE id = ?", [.text(status.id.value)])

    let directory = folder.appendingPathComponent("rehearsal")
    _ = try await RebuildRehearsal(store: store, now: now).rehearse(in: directory)
    let rebuilt = try await Store.open(at: directory.appendingPathComponent("rebuilt.sqlite3"))
    let held = try await rebuilt.claims(subject: subject()).filter { $0.predicate == Predicate.status }
    #expect(!held.isEmpty)
    #expect(held.allSatisfy { $0.domain == .restricted })
}

// The bug: `receipt_evidence` and `receipt_claim` were dropped and never replayed, so `opencore
// trace` came back empty. 964 and 523 links on the real store. Claims the extractor no longer
// produces are the hard case: they are retained as retracted rows, so their links survive too.
@Test("receipt links survive a rebuild, including links to a claim no longer derived")
func receiptLinksSurvive() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)

    let retired = CoreClaim(subject: subject(), predicate: Predicate.describes, literal: "something the extractor no longer says", confidence: 0.5, authority: .derivedPattern, derivation: .inferred, validity: Validity(observedAt: now), domain: .project)
    let evidence = Evidence(objectID: object.id, snippet: "user/Atlas", authority: .authoredArtifact)
    try await store.save([evidence])
    try await store.save([retired])
    try await store.link(claim: retired.id, to: evidence.id, stance: .supports)
    let receipt = Receipt(query: "atlas", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [], stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1, claimsConsulted: 1, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(receipt, evidence: [(evidence.id, 1.0)], claims: [retired.id])

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.receiptLinksKept == report.diff.receiptLinksBefore)
    #expect(report.diff.claimRowsDropped == 0)
    #expect(report.diff.claimsRetired == 1)

    try await RebuildRehearsal(store: store, now: now).apply(report)
    #expect(try await store.trace(receipt: receipt.id).count == 1)
    #expect(try await store.claim(retired.id)?.validity.isCurrent == false, "retained as history, not believed")
}

// The bug: one Keep click on a contradiction wrote a `correction`, and from then on `rebuild`
// refused forever, because nothing could replay it. The notification invited that click.
@Test("a correction is replayed through a rebuild and the wrong claim stays wrong")
func correctionsReplay() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let wrong = try #require(try await store.claims(subject: subject()).first { $0.predicate == Predicate.primaryLanguage })
    let asserted = CoreClaim(subject: subject(), predicate: Predicate.primaryLanguage, literal: "Rust", confidence: 1, authority: .directStatement, derivation: .corrected, validity: Validity(observedAt: now), domain: .project)
    try await BeliefEngine(store: store, now: now).correct(supersedingClaim: wrong.id, with: asserted, reason: "the owner said so", priorFailure: nil)

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.correctionsKept == 1)
    #expect(report.canApply)

    try await RebuildRehearsal(store: store, now: now).apply(report)
    #expect(try await store.claim(wrong.id)?.validity.isCurrent == false)
    let belief = try #require(try await store.currentBelief(key: "\(subject().value)|\(Predicate.primaryLanguage)"))
    #expect(try await store.claim(belief.claimID)?.literal == "Rust")
}

// The bug: the carry re-retracted only the row a correction names. A claim's id holds its subject,
// so a statement a rebuild moved to a new subject came back as a new current row. On a copy of the
// real store a corrected `describes` value went from 0 live rows to 1, and the report said
// "corrections kept 1 of 1", 0 blockers, and filed it as the same statement under a different name.
private func correctedUnderAnotherSubject(_ store: Store, _ now: Date) async throws -> (derived: CoreClaim, wrong: CoreClaim) {
    let derived = try #require(try await store.claims(subject: subject()).first { $0.predicate == Predicate.status })
    let evidence = try #require(try await store.evidence(for: derived.id, stance: .supports).first?.0)
    let renamed = CoreEntity(kind: .project, canonicalName: "Oldname", domain: .project)
    try await store.upsert([renamed])
    let wrong = CoreClaim(subject: renamed.id, predicate: derived.predicate, objectEntity: derived.objectEntity, literal: derived.literal, confidence: 0.8, authority: .derivedPattern, derivation: .observed, validity: Validity(observedAt: now), domain: .project)
    try await store.save([wrong])
    try await store.link(claim: wrong.id, to: evidence.id, stance: .supports)
    let asserted = CoreClaim(subject: renamed.id, predicate: derived.predicate, literal: "what the owner said", confidence: 1, authority: .directStatement, derivation: .corrected, validity: Validity(observedAt: now), domain: .project)
    try await BeliefEngine(store: store, now: now).correct(supersedingClaim: wrong.id, with: asserted, reason: "the owner said so", priorFailure: nil)
    return (derived, wrong)
}

private func value(_ claim: CoreClaim) -> String { claim.objectEntity?.value ?? claim.literal ?? "" }

@Test("a corrected statement stays retired when a rebuild moves it to a new subject under a new id")
func correctionFollowsTheStatement() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (derived, wrong) = try await correctedUnderAnotherSubject(store, now)
    // Gone before the rebuild, as in the measurement: nothing live held this value.
    _ = try await store.database.execute("DELETE FROM claim WHERE claim_key = ?", [.text(derived.claimKey)])

    let directory = folder.appendingPathComponent("rehearsal")
    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: directory)
    #expect(report.diff.correctionsUndone == 0)
    #expect(report.canApply)
    let held = try #require(report.explanation.claims.first { $0.claimID == derived.id.value })
    #expect(held.kind == .addedAsHistory)
    #expect(held.reason == .correctedByOwner)
    #expect(!report.explanation.beliefs.contains { $0.claimKey == derived.claimKey }, "and it is not believed either")

    try await rehearsal.apply(report)
    let rows = try await store.allClaims(currentOnly: true, limit: .max)
    #expect(!rows.contains { $0.predicate == wrong.predicate && value($0) == value(wrong) && $0.subject == derived.subject })
    #expect(try await store.currentBelief(key: derived.claimKey) == nil)

    let again = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("again"))
    #expect(again.diff.correctionsUndone == 0, "and it holds on the rebuild after that")
    #expect(again.diff.claimsAdded == 0)
}

// Two guards. The carry above can be right while the report is blind, which is what happened.
@Test("a rehearsal that would believe a corrected statement again is blocked")
func undoneCorrectionBlocks() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (derived, _) = try await correctedUnderAnotherSubject(store, now)
    _ = try await store.database.execute("DELETE FROM claim WHERE claim_key = ?", [.text(derived.claimKey)])

    let (pristine, rebuilt) = try await rederivedCopy(of: store, in: folder, now: now)
    let diff = try await rebuilt.diff(againstPristine: pristine)
    #expect(diff.correctionsUndone > 0)
    #expect(RebuildRehearsal.blockers(in: diff).contains { $0.contains("corrected") })
}

// A correction names one row. The same value already current under the other subject was never
// ruled on, so a rebuild leaves it standing rather than widening what the owner said.
@Test("a value that was current before the rebuild is not retired by a correction of another row")
func correctionDoesNotReachARowItDidNotName() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (derived, _) = try await correctedUnderAnotherSubject(store, now)

    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.correctionsUndone == 0)
    try await rehearsal.apply(report)
    #expect(try await store.claim(derived.id)?.validity.isCurrent == true)
}

// The bug: `decided_at` was carried only where a row kept its claim id, so a re-dated winner took
// the rebuild's time. Applied on a copy of the real store: 38 belief rows moved to the rehearsal
// time, `memory checkout 2026-10-30` lost 12 slots, and `memory log --since 1d` went from 1 line to
// 153, printing long-held facts as first evidence dated today. A second rehearsal moved 5 more.
private func beliefOnAnOlderRow(_ store: Store, _ now: Date) async throws -> (belief: Belief, derived: CoreClaim) {
    let derived = try #require(try await store.claims(subject: subject()).first { $0.predicate == Predicate.status })
    let older = CoreClaim(subject: derived.subject, predicate: derived.predicate, objectEntity: derived.objectEntity, literal: derived.literal, confidence: derived.confidence, authority: derived.authority, derivation: .observed, validity: Validity(validFrom: now.addingTimeInterval(-90 * day), observedAt: now.addingTimeInterval(-90 * day)), domain: .project)
    try await store.save([older])
    _ = try await store.database.execute("UPDATE belief SET claim_id = ? WHERE claim_key = ?", [.text(older.id.value), .text(derived.claimKey)])
    return (try #require(try await store.currentBelief(key: derived.claimKey)), derived)
}

@Test("a belief whose value did not change keeps its decision time when its winner is re-dated")
func unchangedBeliefKeepsItsKnowledgeTime() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (belief, derived) = try await beliefOnAnOlderRow(store, now)
    let key = belief.claimKey
    let chain = try await store.beliefHistory(key: key)
    let held = belief.decidedAt.addingTimeInterval(day)

    let later = now.addingTimeInterval(30 * day)
    let rehearsal = RebuildRehearsal(store: store, now: later)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.beliefVersionsDropped == 0)
    try await rehearsal.apply(report)

    let after = try await store.beliefHistory(key: key)
    #expect(after.map(\.id) == chain.map(\.id), "same value, so no version was added")
    #expect(after.map(\.decidedAt) == chain.map(\.decidedAt))
    #expect(after.last?.claimID == derived.id, "and it follows the row that is current now")
    #expect(try await store.beliefs(asOfKnowledge: held).contains { $0.claimKey == key }, "the store still knows what it held on that date")
    #expect(try await store.beliefsDecided(since: later.addingTimeInterval(-day)).isEmpty, "and nothing long held reads as learned today")
}

// The other half: the same statement stands, so a second rehearsal must find nothing to move.
@Test("a rehearsal after an apply moves no belief")
func secondRehearsalMovesNoBelief() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    _ = try await beliefOnAnOlderRow(store, now)
    let rehearsal = RebuildRehearsal(store: store, now: now.addingTimeInterval(30 * day))
    try await rehearsal.apply(try await rehearsal.rehearse(in: folder.appendingPathComponent("first")))

    let directory = folder.appendingPathComponent("second")
    let second = try await RebuildRehearsal(store: store, now: now.addingTimeInterval(60 * day)).rehearse(in: directory)
    #expect(second.diff.beliefVersionsDropped == 0)
    #expect(second.diff.beliefsChanged == 0)
    #expect(second.diff.beliefsAdded == 0)
    let copy = try await Store.open(at: directory.appendingPathComponent("rebuilt.sqlite3"))
    #expect(try await copy.beliefsDecided(since: .distantPast).map(\.id) == (try await store.beliefsDecided(since: .distantPast).map(\.id)))
    #expect(try await copy.beliefsDecided(since: .distantPast).map(\.decidedAt) == (try await store.beliefsDecided(since: .distantPast).map(\.decidedAt)))
}

// Two guards. The measured report compared against the already-wrong copy, so it saw nothing.
@Test("a recorded belief version that lost its date counts as lost and blocks the apply")
func movedDecisionTimeBlocks() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    _ = try await beliefOnAnOlderRow(store, now)
    let (pristine, rebuilt) = try await rederivedCopy(of: store, in: folder, now: now.addingTimeInterval(30 * day))
    let diff = try await rebuilt.diff(againstPristine: pristine)
    #expect(diff.beliefVersionsDropped > 0)
    #expect(!RebuildRehearsal.blockers(in: diff).isEmpty)
}

// The bug: both belief comparisons joined on slots present on both sides, so a slot gaining its
// first belief was invisible. On a copy 15 slots gained a current belief, none of them in the list
// by id, the "would change value" finding, or the confirmation the owner approves on.
@Test("a slot that gets its first belief is in the totals, the list by id, and the confirmation")
func firstBeliefIsReported() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let claim = try #require(try await store.claims(subject: subject()).first { $0.predicate == Predicate.status })
    _ = try await store.database.execute("DELETE FROM belief WHERE claim_key = ?", [.text(claim.claimKey)])

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.beliefsAdded > 0)
    let rows = report.explanation.beliefs.filter { $0.reason == .firstBeliefForSlot }
    #expect(rows.count == report.diff.beliefsAdded)
    #expect(report.explanation.beliefs.count - rows.count == report.diff.beliefsChanged)
    let row = try #require(rows.first { $0.claimKey == claim.claimKey })
    #expect(row.before == nil)
    #expect(row.claimBefore == nil)
    #expect(report.warnings.contains { $0.contains("first") })

    let narrative = RebuildNarrative(report)
    #expect(narrative.confirmation.contains("\(report.diff.beliefsAdded) new belief"))
    let finding = try #require(narrative.findings.first { $0.title == "Current beliefs" })
    #expect(finding.needsAttention)
    #expect(finding.breakdown.contains { $0.hasPrefix("\(rows.count):") })
}

// The bug: replay dates a version when an object's earlier state was learned, so a slot the store
// never decided appeared in `memory checkout` for a date before the rebuild. On a copy, 2 slots.
@Test("a belief the store never held is dated by the rebuild and not by replay")
func firstBeliefIsNotBackdated() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)
    let revised = CoreObject(sourceID: object.sourceID, kind: object.kind, externalID: object.externalID, title: object.title, text: object.text + " It changed.", authoredAt: object.authoredAt, domain: object.domain, authority: object.authority, metadata: object.metadata)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-2 * day)).run(objects: [revised])
    #expect(try await store.objectEpochs().isEmpty == false, "the fixture must replay an earlier state or this proves nothing")
    let claim = try #require(try await store.claims(subject: subject()).first { $0.predicate == Predicate.status })
    _ = try await store.database.execute("DELETE FROM belief WHERE claim_key = ?", [.text(claim.claimKey)])

    let later = now.addingTimeInterval(30 * day)
    let rehearsal = RebuildRehearsal(store: store, now: later)
    try await rehearsal.apply(try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal")))
    let chain = try await store.beliefHistory(key: claim.claimKey)
    #expect(!chain.isEmpty)
    #expect(chain.allSatisfy { abs($0.decidedAt.timeIntervalSince(later)) < 1 })
}

// The bug: `observed_at`, `decided_at` and `detected_at` became rebuild time, which erases what
// `memory checkout` is for.
@Test("a row that survives keeps the moment it was first known")
func knowledgeTimeSurvives() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let before = try #require(try await store.claims(subject: subject()).first)

    let later = now.addingTimeInterval(30 * day)
    let rehearsal = RebuildRehearsal(store: store, now: later)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))
    try await rehearsal.apply(report)

    let after = try #require(try await store.claim(before.id))
    #expect(after.validity.observedAt == before.validity.observedAt)
}

// The bug: dropping `chunk_vector` left retrieval lexical-only until a slow re-embed finished.
@Test("vectors are reused where the passage text did not change")
func vectorsAreCarried() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)
    let chunk = try #require(try await store.chunks(forObject: object.id).first)
    try await store.save(vectors: [StoredVector(chunkID: chunk.id, model: "test", values: [0.1, 0.2])], dimensions: 2)

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    try await RebuildRehearsal(store: store, now: now).apply(report)
    #expect(try await store.embeddedChunkCount(model: "test") == 1)
}

// A sync between the rehearsal and the approval means what was reviewed is not what would land.
@Test("a store that moved after the rehearsal refuses the apply and is left untouched")
func staleRehearsalIsRefused() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))

    _ = try await IngestPipeline(store: store, now: now).run(objects: [repository("Newcomer", pushed: now)])
    let signature = try await store.floorSignature()

    await #expect(throws: RebuildSafetyError.self) {
        try await RebuildRehearsal(store: store, now: now).apply(report)
    }
    #expect(try await store.floorSignature() == signature)
}

@Test("a blocked report cannot be applied, and there is no override")
func blockedReportIsRefused() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    var report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    report.blockers = ["a claim would become readable"]
    await #expect(throws: RebuildSafetyError.self) {
        try await RebuildRehearsal(store: store, now: now).apply(report)
    }
}

// Receipts keep arriving from running MCP sessions while a rehearsal waits for review. They must
// not make it stale, and they must not be lost.
@Test("a receipt written after the rehearsal keeps its links through the apply")
func lateReceiptSurvives() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)
    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))

    let evidence = try await supportingEvidence(store)
    #expect(evidence.objectID == object.id)
    let receipt = Receipt(query: "late", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [], stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1, claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(receipt, evidence: [(evidence.id, 1.0)])

    try await rehearsal.apply(report)
    #expect(try await store.trace(receipt: receipt.id).count == 1)
}

// The bug: the guard counted corrections and authority-5 claims, both zero on the real store, so
// the destructive drop passed.
@Test("an in-place drop refuses a store with receipt links or pending quarantine")
func inPlaceDropRefuses() async throws {
    let linked = workspace()
    let now = Date()
    let (store, object) = try await populated(in: linked, now: now)
    let evidence = try await supportingEvidence(store)
    let receipt = Receipt(query: "x", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [], stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1, claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(receipt, evidence: [(evidence.id, 1.0)])
    await #expect(throws: RebuildSafetyError.self) { try await store.dropDerivedLayers() }
    #expect(try await store.claimCount() > 0)

    let flagged = workspace()
    let (second, secondObject) = try await populated(in: flagged, now: now)
    #expect(object.id == secondObject.id, "same fixture")
    _ = try await second.reclassifyObjects([.init(objectID: secondObject.id, domain: .restricted, authority: .generatedSummary, reason: "review")], dryRun: false)
    await #expect(throws: RebuildSafetyError.self) { try await second.dropDerivedLayers() }
    #expect(try await second.claimCount() > 0)
}

@Test("a report round-trips through its file")
func reportRoundTrips() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let directory = folder.appendingPathComponent("rehearsal")
    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: directory)
    let loaded = try RebuildReport.load(from: directory)
    #expect(loaded.signature == report.signature)
    #expect(loaded.rebuiltPath == report.rebuiltPath)
}

// MARK: - Review of 2026-10-31. Each of these failed on a real store or a copy of one.

private func statementRestated(_ store: Store, _ now: Date) async throws -> (old: CoreClaim, evidence: Evidence) {
    let evidence = try await supportingEvidence(store)
    let old = CoreClaim(subject: subject(), predicate: Predicate.nextAction, literal: "Ship the fixture", confidence: 0.8, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: now.addingTimeInterval(-40 * day), observedAt: now.addingTimeInterval(-40 * day)), domain: .restricted)
    try await store.save([old])
    try await store.link(claim: old.id, to: evidence.id, stance: .supports)
    return (old, evidence)
}

/// A store copy re-derived from its objects, before anything has been carried back.
private func rederivedCopy(of store: Store, in folder: URL, now: Date) async throws -> (pristine: URL, rebuilt: Store) {
    let pristine = folder.appendingPathComponent("pristine.sqlite3")
    let path = folder.appendingPathComponent("rebuilt.sqlite3")
    try await store.snapshot(to: pristine)
    try FileManager.default.copyItem(at: pristine, to: path)
    let rebuilt = try await Store.open(at: path)
    try await rebuilt.clearDerivedLayersOfRehearsalCopy()
    _ = try await IngestPipeline(store: rebuilt, now: now).rederive()
    return (pristine, rebuilt)
}

// The bug: a claim's id includes the date it was valid from, so a statement re-derived with a new
// date is a new row. The quarantine was carried by id, and "domains raised" compared by id, so on a
// copy of the real store 7 restricted statements came back at `project` with the report saying 0.
@Test("a quarantined statement stays quarantined when it comes back under a new id")
func quarantineFollowsTheStatement() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (old, evidence) = try await statementRestated(store, now)
    let (pristine, rebuilt) = try await rederivedCopy(of: store, in: folder, now: now)

    // A fresh row saying the same thing, as a re-derivation with a later date would write it.
    let restated = CoreClaim(subject: subject(), predicate: Predicate.nextAction, literal: "Ship the fixture", confidence: 0.8, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: now, observedAt: now), domain: .project)
    #expect(restated.id != old.id, "the date is part of the id, which is the whole problem")

    try await rebuilt.save([restated])
    try await rebuilt.save([evidence])
    try await rebuilt.link(claim: restated.id, to: evidence.id, stance: .supports)

    // Guard one: the floor catches it before the carry has run.
    #expect(try await rebuilt.diff(againstPristine: pristine).domainsRaised == 1)

    // Guard two: the carry holds it.
    _ = try await rebuilt.carryDerivedState(from: pristine, now: now)
    #expect(try await rebuilt.claim(restated.id)?.domain == .restricted)
    #expect(try await rebuilt.diff(againstPristine: pristine).domainsRaised == 0)
}

// The bug: `floorSignature` held counts and totals, so quarantining a claim or flagging an object
// after the rehearsal left it unchanged, and the apply replaced that claim with a wider row.
@Test("quarantining a claim after the rehearsal makes the rehearsal stale")
func lateQuarantineIsStale() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))

    _ = try await store.database.execute("UPDATE claim SET domain = 'restricted' WHERE subject = ?", [.text(subject().value)])
    // By name: the floor check inside the apply refuses this too, which would hide a weak signature.
    await #expect {
        try await rehearsal.apply(report)
    } throws: { error in
        if case RebuildSafetyError.staleRehearsal = error { return true }
        return false
    }
}

@Test("flagging an object for review after the rehearsal makes the rehearsal stale")
func lateFlagIsStale() async throws {
    let folder = workspace()
    let now = Date()
    let (store, object) = try await populated(in: folder, now: now)
    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))

    _ = try await store.updateObjectMetadata(object.id, merging: ["classification_requires_rebuild": "true"])
    await #expect(throws: RebuildSafetyError.self) { try await rehearsal.apply(report) }
}

// Two guards, so this is the second. The report is a file, and an edited one must not get a raise
// past the apply: the check runs again inside the transaction, against the live rows.
@Test("an edited report cannot apply a rehearsed copy that raises a domain")
func applyChecksTheFloorItself() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    _ = try await store.database.execute("UPDATE claim SET domain = 'restricted' WHERE subject = ?", [.text(subject().value)])
    let directory = folder.appendingPathComponent("rehearsal")
    let rehearsal = RebuildRehearsal(store: store, now: now)
    var report = try await rehearsal.rehearse(in: directory)

    let tampered = try await Store.open(at: directory.appendingPathComponent("rebuilt.sqlite3"))
    _ = try await tampered.database.execute("UPDATE claim SET domain = 'project'")
    try await tampered.checkpoint()
    report.blockers = []

    await #expect(throws: RebuildSafetyError.self) { try await rehearsal.apply(report) }
    #expect(try await store.claims(subject: subject()).allSatisfy { $0.domain == .restricted })
}

// The bug: nothing carried `contradiction`, so a rebuild lost all 14 rows on the real store and
// wrote 4 new ones. Its ids come from claim ids, so a re-dated claim made a new pair. The
// `detected_at` carry looked right and matched nothing.
@Test("a contradiction a rebuild does not find again is kept, with the owner's ruling")
func contradictionsSurvive() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (old, _) = try await statementRestated(store, now)
    let other = CoreClaim(subject: subject(), predicate: Predicate.nextAction, literal: "Do something else", confidence: 0.8, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: now.addingTimeInterval(-30 * day), observedAt: now.addingTimeInterval(-30 * day)), domain: .project)
    try await store.save([other])
    let ruling = Contradiction(claimA: other.id, claimB: old.id, kind: .directConflict, resolution: .resolvedByCorrection, winner: other.id, detectedAt: now.addingTimeInterval(-20 * day), reason: "the owner ruled")
    try await store.save([ruling])

    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.contradictionRowsDropped == 0)
    try await rehearsal.apply(report)

    let kept = try #require(try await store.contradictions().first { $0.id == ruling.id })
    #expect(kept.resolution == .resolvedByCorrection)
    #expect(kept.reason == "the owner ruled")
    #expect(kept.detectedAt.timeIntervalSince(ruling.detectedAt) < 1, "keeps the moment it was found")
}

// The other half of that bug: the two open rows on the real store were decided by the rebuild's
// reconcile under new claim ids, so keeping them as they were would ask about a settled question.
@Test("an open contradiction closes only when the rebuild decided the same two values")
func openContradictionClosesOnlyOnTheSameValues() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    func claim(_ value: String, _ daysAgo: Double) -> CoreClaim {
        CoreClaim(subject: subject(), predicate: Predicate.nextAction, literal: value, confidence: 0.8, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: now.addingTimeInterval(-daysAgo * day), observedAt: now.addingTimeInterval(-daysAgo * day)), domain: .project)
    }
    let (a, b, c) = (claim("first", 30), claim("second", 29), claim("third", 28))
    try await store.save([a, b, c])
    let open = Contradiction(claimA: a.id, claimB: b.id, kind: .directConflict, resolution: .unresolved, reason: "open")
    let untouched = Contradiction(claimA: b.id, claimB: c.id, kind: .directConflict, resolution: .unresolved, reason: "open")
    try await store.save([open, untouched])

    let (pristine, rebuilt) = try await rederivedCopy(of: store, in: folder, now: now)
    let (a2, b2) = (claim("first", 3), claim("second", 2))
    try await rebuilt.save([a2, b2, a, b, c])
    try await rebuilt.save([Contradiction(claimA: b2.id, claimB: a2.id, kind: .temporalSupersession, resolution: .supersededByRecency, winner: b2.id, reason: "decided")])

    let outcome = try await rebuilt.carryDerivedState(from: pristine, now: now)
    #expect(outcome.contradictionsClosed == 1)
    let rows = try await rebuilt.contradictions()
    #expect(rows.first { $0.id == open.id }?.resolution == .supersededByRecency)
    #expect(rows.first { $0.id == untouched.id }?.resolution == .unresolved, "a question nobody settled stays open")
}

// The bug: replay rewrote a slot's history from what the floor still held, so 5 recorded versions
// vanished. The first repair compared claim ids, called 62 versions lost, and doubled the chains
// with re-dated rows saying the same value, so the assertions below cover both failures.
@Test("a belief version a rebuild cannot reach is kept beneath the rebuilt winner, and only that one")
func beliefHistorySurvives() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let language = try #require(try await store.claims(subject: subject()).first { $0.predicate == Predicate.primaryLanguage })
    let key = language.claimKey

    // A reading the floor no longer has, believed for a while.
    let lost = CoreClaim(subject: subject(), predicate: Predicate.primaryLanguage, literal: "COBOL", confidence: 0.9, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: now.addingTimeInterval(-2 * day), observedAt: now.addingTimeInterval(-2 * day)), domain: .project)
    try await store.save([lost])
    let current = try #require(try await store.currentBelief(key: key))
    try await store.save(Belief(claimKey: key, version: current.version + 1, claimID: lost.id, confidence: 0.9, authority: .authoredArtifact, validity: lost.validity, supersedes: current.id, reason: "changed", decidedAt: now.addingTimeInterval(-day)))

    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.beliefVersionsDropped == 0)
    #expect(report.carried.beliefVersionsKept == 1)
    try await rehearsal.apply(report)

    let chain = try await store.beliefHistory(key: key)
    #expect(chain.map(\.version) == Array(1...chain.count), "versions stay contiguous")
    #expect(chain.count == current.version + 2, "every recorded version once, and the rebuilt winner above them")
    #expect(chain[current.version - 1].decidedAt == current.decidedAt, "a recorded version keeps its date, even with its value above it again")
    #expect(chain.contains { $0.claimID == lost.id })
    #expect(chain.last?.claimID != lost.id, "history, not the answer")
    let decided = try #require(chain.last?.decidedAt)
    #expect(abs(decided.timeIntervalSince(now)) < 1, "the store's mind changed at the rebuild, not when replay dated it")
    #expect(zip(chain, chain.dropFirst()).allSatisfy { $1.supersedes == $0.id })
}

// The bug: "receipts still traced" counted receipts with evidence rows, so it said 6 of 6 on a
// store of 30, and it never ran a trace. A link whose evidence had gone still counted.
@Test("every receipt is reported, and a trace that came back short is broken")
func receiptAuditRunsTheTrace() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let evidence = try await supportingEvidence(store)
    func receipt(_ query: String, admitted: Int) -> Receipt {
        Receipt(query: query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [], stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: admitted, claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    }
    let linked = receipt("linked", admitted: 1)
    try await store.save(linked, evidence: [(evidence.id, 1.0)])
    let unlinked = receipt("unlinked", admitted: 0)
    try await store.save(unlinked)

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.receiptsTotal == 2)
    #expect(report.diff.receiptsWithEvidence == 1)
    #expect(report.diff.receiptsResolving == 1)
    #expect(report.diff.receiptsWithoutLinks == 1)

    // A rehearsed copy that lost the evidence: the link row is there, and the trace is short.
    let earlier = folder.appendingPathComponent("earlier.sqlite3")
    try await store.snapshot(to: earlier)
    _ = try await store.database.execute("PRAGMA foreign_keys = OFF")
    _ = try await store.database.execute("DELETE FROM evidence WHERE id = ?", [.text(evidence.id.value)])
    let audit = try await store.receiptTraceAudit(againstEarlier: earlier)
    #expect(audit.first { $0.id == linked.id.value }?.outcome == .broken)
    _ = try await store.database.execute("PRAGMA foreign_keys = ON")

    var diff = RebuildDiff()
    diff.record(audit)
    #expect(!RebuildRehearsal.blockers(in: diff).isEmpty)
}

// The bug: an older evidence row's id has no reading in it, so replaying an earlier state of an
// object rewrote its snippet. On a copy, one past answer's citation named the wrong commit.
@Test("a past answer keeps quoting the text it quoted")
func citedTextSurvives() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let evidence = try await supportingEvidence(store)
    let receipt = Receipt(query: "q", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [], stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1, claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(receipt, evidence: [(evidence.id, 1.0)])
    _ = try await store.database.execute("UPDATE evidence SET snippet = 'what the answer really quoted' WHERE id = ?", [.text(evidence.id.value)])

    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))
    #expect(report.diff.receiptsBroken == 0)
    try await rehearsal.apply(report)
    #expect(try await store.trace(receipt: receipt.id).first?.0.snippet == "what the answer really quoted")
}

@Test("every changed claim is in the report by id with a reason, and the totals count those rows")
func everyChangeIsExplained() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let (old, _) = try await statementRestated(store, now)
    _ = try await store.database.execute("UPDATE claim SET authority = 5 WHERE predicate = ? AND subject = ?", [.text(Predicate.primaryLanguage), .text(subject().value)])

    let report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    let claims = report.explanation.claims
    func rows(_ kind: RebuildChangeKind) -> [RebuildClaimChange] { claims.filter { $0.kind == kind } }

    #expect(rows(.retired).count == report.diff.claimsRetired)
    #expect(rows(.added).count == report.diff.claimsAdded)
    #expect(rows(.addedAsHistory).count == report.diff.claimsAddedAsHistory)
    #expect(rows(.restored).count == report.diff.claimsRestored)
    #expect(rows(.authorityChanged).count == report.diff.authorityChanged)
    #expect(rows(.domainLowered).count == report.diff.domainsLowered)
    #expect(report.explanation.unexplained == 0)

    let retired = try #require(rows(.retired).first { $0.claimID == old.id.value })
    #expect(retired.reason == .noLongerDerived)
    #expect(retired.predicate == Predicate.nextAction)
}

@Test("the same value on a new date is one statement, and a new subject from one object is a move")
func reasonsNameWhatHappened() {
    func facts(_ id: String, key: String, value: String = "v", object: String = "o", retired: Bool = false) -> RebuildClaimFacts {
        RebuildClaimFacts(id: id, key: key, subject: key, predicate: "describes", valueKey: value, value: value, domain: "project", authority: 4, retired: retired, sources: [.init(object: object, domain: "project", authority: 4, awaitingReview: false)])
    }
    let before = [facts("a", key: "s1"), facts("b", key: "s2"), facts("c", key: "s3", value: "w", object: "m"), facts("d", key: "s4", value: "gone", object: "q")]
    let after = [
        facts("a", key: "s1", retired: true), facts("a2", key: "s1"),
        facts("b", key: "s2", retired: true), facts("b2", key: "s2-renamed"),
        facts("c", key: "s3", value: "w", object: "m", retired: true), facts("c2", key: "s3", value: "other", object: "p"),
        facts("d", key: "s4", value: "gone", object: "q", retired: true),
        facts("e", key: "s5", value: "fresh", object: "r"),
    ]
    let changes = RebuildExplainer.claimChanges(before: before, after: after)
    func reason(_ id: String, _ kind: RebuildChangeKind) -> RebuildChangeReason? {
        changes.first { $0.claimID == id && $0.kind == kind }?.reason
    }
    #expect(reason("a", .retired) == .sameStatementNewDate)
    #expect(reason("a2", .added) == .sameStatementNewDate)
    #expect(reason("b", .retired) == .movedToAnotherSubject)
    #expect(reason("b2", .added) == .movedToAnotherSubject)
    #expect(reason("c", .retired) == .replacedByNewValue)
    #expect(reason("c2", .added) == .newValueInSlot)
    #expect(reason("d", .retired) == .noLongerDerived)
    #expect(reason("e", .added) == .newSlot)
}

@Test("an apply keeps a proved copy of the store as it was, including receipts newer than the rehearsal")
func applyKeepsABackup() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: folder.appendingPathComponent("rehearsal"))

    let late = Receipt(query: "after the rehearsal", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [], stages: [], objectsSearched: 1, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(late)
    let signature = try await store.floorSignature()

    let outcome = try await rehearsal.apply(report)
    #expect(outcome.receiptsBroken == 0)
    let backup = try await Store.open(at: URL(fileURLWithPath: outcome.backupPath))
    #expect(try await backup.floorSignature() == signature)
    #expect(try await backup.receipt(code: late.id.value) != nil, "the pristine copy could not have this")
}

@Test("a backup that is not the store about to change is refused before anything changes")
func wrongBackupIsRefused() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let backup = folder.appendingPathComponent("backup.sqlite3")
    try await store.snapshot(to: backup)
    try await store.verifyBackup(backup, expecting: try await store.floorSignature())

    await #expect(throws: RebuildSafetyError.self) {
        try await store.verifyBackup(backup, expecting: "something else")
    }
}

// `INSERT OR IGNORE` hides a skipped row, and a failed statement has to undo the deletes before it.
@Test("an apply that fails partway leaves the store exactly as it was")
func failedApplyRollsBack() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    let directory = folder.appendingPathComponent("rehearsal")
    let rehearsal = RebuildRehearsal(store: store, now: now)
    let report = try await rehearsal.rehearse(in: directory)
    let signature = try await store.floorSignature()
    let claims = try await store.claimCount()

    // A rehearsed copy with a dangling reference, which the live store's foreign keys reject.
    let tampered = try await Store.open(at: directory.appendingPathComponent("rebuilt.sqlite3"))
    _ = try await tampered.database.execute("PRAGMA foreign_keys = OFF")
    _ = try await tampered.database.execute("UPDATE claim_evidence SET evidence_id = 'missing' WHERE rowid = (SELECT MIN(rowid) FROM claim_evidence)")
    try await tampered.checkpoint()

    await #expect(throws: (any Error).self) { try await rehearsal.apply(report) }
    #expect(try await store.floorSignature() == signature)
    #expect(try await store.claimCount() == claims)
}

@Test("the confirmation carries the numbers the owner is approving, and the words are plain")
func narrativeShowsTheNumbers() async throws {
    let folder = workspace()
    let now = Date()
    let (store, _) = try await populated(in: folder, now: now)
    var report = try await RebuildRehearsal(store: store, now: now).rehearse(in: folder.appendingPathComponent("rehearsal"))
    report.diff.beliefsChanged = 8
    report.diff.beliefsAdded = 15
    report.diff.claimsRetired = 161
    report.diff.claimsAdded = 146
    report.diff.domainsLowered = 18
    report.diff.openContradictionsBefore = 2

    let narrative = RebuildNarrative(report)
    for number in ["8 belief", "15 new belief", "161 claim", "146 added", "18 claim", "2 to 0"] {
        #expect(narrative.confirmation.contains(number))
    }
    let everything = [RebuildNarrative.whatItIs, RebuildNarrative.whenToUse, RebuildNarrative.howItIsSafe, narrative.headline, narrative.confirmation]
        + narrative.applyWill + narrative.applyWillNot + narrative.findings.flatMap { [$0.title, $0.summary] + $0.breakdown }
    #expect(!everything.contains { $0.contains("\u{2014}") })

    report.blockers = ["blocked"]
    #expect(RebuildNarrative(report).headline.contains("cannot be applied"))
}
