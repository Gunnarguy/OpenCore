import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Testing
@testable import CoreReason

private struct GroundingFixture {
    let directory: URL
    let store: Store
    let source: Source

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-grounding-\(UUID())")
        let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
        let source = Source(kind: .manual, handle: "grounding-fixture", displayName: "Fixture",
                            defaultAuthority: .authoredArtifact, defaultDomain: .project)
        try await store.upsert(source)
        return Self(directory: directory, store: store, source: source)
    }

    func object(_ key: String, text: String, domain: Domain = .project, authority: Authority = .authoredArtifact) async throws -> CoreObject {
        let object = CoreObject(sourceID: source.id, kind: .document, externalID: key, title: key,
                                text: text, domain: domain, authority: authority)
        try await store.ingest([object])
        try await store.save([CoreChunk(objectID: object.id, ordinal: 0, text: text, range: 0..<text.count)])
        return object
    }
}

// The system Intent combined claims under a nonexistent object ID and promoted all authorities.
// Its source construction also discarded the caveats already shown by Chat and MCP.
@Test("system claim sources resolve to admitted floor objects and keep each claim's caveats")
func systemClaimSourcesHaveRealProvenance() async throws {
    let f = try await GroundingFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let entity = CoreEntity(kind: .project, canonicalName: "Quillberry", domain: .project)
    try await f.store.upsert([entity])
    try await f.store.addAliases([EntityAlias(entityID: entity.id, surface: "Quillberry", confidence: 1)])
    let floor = try await f.object("inference basis", text: "Quillberry has recent repository activity.")
    let audit = try await f.object("counter audit", text: "Quillberry has no maintainer.")
    let rivalFloor = try await f.object("rival record", text: "Quillberry is dormant.")
    let secretFloor = try await f.object("private record", text: "PRIVATE_RIVAL_SENTINEL", domain: .medical)
    let support = Evidence(objectID: floor.id, snippet: floor.text, authority: floor.authority)
    let counter = Evidence(objectID: audit.id, snippet: audit.text, authority: audit.authority)
    let rivalSupport = Evidence(objectID: rivalFloor.id, snippet: rivalFloor.text, authority: rivalFloor.authority)
    let secretSupport = Evidence(objectID: secretFloor.id, snippet: secretFloor.text, authority: .directStatement)
    let validity = Validity(observedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let claim = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.6,
                          authority: .modelInference, derivation: .inferred, validity: validity, domain: .project)
    let rival = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "dormant", confidence: 0.6,
                          authority: .authoredArtifact, derivation: .observed, validity: validity, domain: .project)
    let overruled = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "archived", confidence: 0.8,
                              authority: .directStatement, derivation: .observed, validity: validity, domain: .project)
    let secret = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "PRIVATE_RIVAL_SENTINEL", confidence: 0.8,
                           authority: .directStatement, derivation: .observed, validity: validity, domain: .project)
    try await f.store.save([claim, rival, overruled, secret])
    try await f.store.save([support, counter, rivalSupport, secretSupport])
    try await f.store.link(claim: claim.id, to: support.id, stance: .supports)
    try await f.store.link(claim: claim.id, to: counter.id, stance: .refutes)
    try await f.store.link(claim: rival.id, to: rivalSupport.id, stance: .supports)
    try await f.store.link(claim: overruled.id, to: rivalSupport.id, stance: .supports)
    try await f.store.link(claim: secret.id, to: secretSupport.id, stance: .supports)
    try await f.store.save([
        Contradiction(claimA: claim.id, claimB: rival.id, kind: .directConflict, resolution: .unresolved, reason: "both retained"),
        Contradiction(claimA: claim.id, claimB: overruled.id, kind: .directConflict, resolution: .supersededByAuthority,
                      winner: overruled.id, reason: "higher standing"),
        Contradiction(claimA: claim.id, claimB: secret.id, kind: .directConflict, resolution: .unresolved, reason: "PRIVATE_RIVAL_SENTINEL"),
    ])
    let readonly = try await Store.openReadOnly(at: f.directory.appendingPathComponent("store.sqlite3"))
    let reasoner = Reasoner(store: readonly)
    let answer = try await reasoner.answer("status of Quillberry", externalCaller: true, persistReceipt: false)
    let point = try #require(answer.points.first { $0.claimID == claim.id })
    let reading = try await reasoner.claimSources(from: [point], policy: AdmissionPolicy(queryDomain: .project))
    let source = try #require(reading.sources.first)
    #expect(source.objectID == floor.id)
    #expect(source.authority == .modelInference)
    #expect(source.claimID == claim.id)
    #expect(source.text.contains("Inferred by OpenCore"))
    #expect(source.text.contains("Counter-evidence: Quillberry has no maintainer."))
    #expect(source.text.contains("Open contradiction: Quillberry is dormant."))
    #expect(source.text.contains("Overruled: Quillberry is archived."))
    #expect(!source.text.contains("PRIVATE_RIVAL_SENTINEL"))
    #expect(Set(source.representedObjectIDs ?? []) == [floor.id, audit.id, rivalFloor.id])
    #expect(reading.contradictions == 2)
    #expect(!reading.claims.contains(secret.id))
    for source in reading.sources { #expect(try await readonly.object(source.objectID) != nil) }
    #expect(try await readonly.receipts().isEmpty)
}

private actor SourceProbe {
    var sources: [GroundingSource] = []
    func synthesize(_ question: String, sources: [GroundingSource]) -> Conversation.BriefSynthesis {
        self.sources = sources
        let brief = Conversation.checkedBrief(sentences: sources.map { ($0.text, $0.index) }, sources: sources, modelName: "Fixture local writer")
        return Conversation.BriefSynthesis(brief: brief, requestedModel: "Fixture local writer", outcome: "Fixture returned prose.")
    }
}

// The Intent reran retrieval beneath an already saved receipt. Its model and extra sources were
// absent from that receipt; passage-only Reasoner answers had no trace rows at all.
@Test("a system supplement uses only its answer's passages and persists one accurate receipt")
func systemSupplementUsesOneReadingAndOneReceipt() async throws {
    let f = try await GroundingFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let object = try await f.object("first record", text: "Cobalt amaranth uses Swift and SQLite.", authority: .modelInference)
    let reasoner = Reasoner(store: f.store)
    let answer = try await reasoner.answer("cobalt amaranth", externalCaller: true, persistReceipt: false)
    #expect(answer.points.isEmpty)
    #expect(answer.passages.contains { $0.object.id == object.id })
    // A current metadata upgrade must not promote the authority of this earlier reading.
    var upgraded = object
    upgraded.authority = .directStatement
    upgraded.title = "Renamed after retrieval"
    try await f.store.ingest([upgraded])
    let later = try await f.object("later record", text: "Cobalt amaranth cobalt amaranth NEW_RETRIEVAL_SENTINEL")
    let probe = SourceProbe()
    let completed = try await reasoner.supplement(answer) { await probe.synthesize($0, sources: $1) }
    let sources = await probe.sources
    #expect(!sources.isEmpty)
    #expect(!sources.contains { $0.objectID == later.id })
    #expect(sources.map(\.index) == Array(1...sources.count))
    #expect(sources.allSatisfy { source in answer.passages.contains { $0.object.id == source.objectID } })
    let originalSource = try #require(sources.first { $0.objectID == object.id })
    #expect(originalSource.authority == .modelInference)
    #expect(originalSource.title == "first record")
    let receipt = try #require(try await f.store.receipt(code: completed.answer.receipt.shortCode))
    #expect(try await f.store.receipts().count == 1)
    #expect(receipt.id == answer.receipt.id)
    #expect(receipt.model == "Fixture local writer")
    #expect(receipt.objectsTransmitted == 0)
    #expect(receipt.confidence == nil)
    let trace = try await f.store.trace(receipt: receipt.id)
    #expect(trace.count == receipt.evidenceAdmitted)
    for hit in answer.passages {
        let row = try #require(trace.first { $0.0.snippet == hit.chunk.text })
        #expect(row.1.id == hit.object.id)
        #expect(row.0.range == hit.chunk.range)
        #expect(row.2 == hit.score)
    }
    let plain = try await reasoner.answer("cobalt amaranth", externalCaller: true)
    #expect(try await f.store.trace(receipt: plain.receipt.id).count == plain.passages.count)
    #expect(plain.receipt.evidenceAdmitted == plain.passages.count)
}

// A failed/empty supplement still needs its one deterministic receipt; it cannot invent a model.
@Test("empty system supplements retain their evidence receipt with no model")
func emptySystemSupplementHasNoInventedModel() async throws {
    let f = try await GroundingFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    _ = try await f.object("record", text: "Cobalt amaranth uses Swift.")
    let reasoner = Reasoner(store: f.store)
    let answer = try await reasoner.answer("cobalt amaranth", externalCaller: true, persistReceipt: false)
    let completed = try await reasoner.supplement(answer) { _, _ in Conversation.BriefSynthesis(outcome: "No writer requested.") }
    #expect(completed.brief == nil)
    #expect(completed.answer.receipt.model == nil)
    #expect(completed.answer.receipt.stages.last?.counters["sentences_returned"] == 0)
    #expect(completed.answer.receipt.stages.last?.counters["local_writer_requested"] == 0)
    #expect(try await f.store.receipts().count == 1)
    #expect(try await f.store.trace(receipt: completed.answer.receipt.id).count == answer.passages.count)
    let next = try await reasoner.answer("cobalt amaranth", externalCaller: true, persistReceipt: false)
    let refused = try await reasoner.supplement(next) { _, _ in
        Conversation.BriefSynthesis(requestedModel: "Fixture refused writer", outcome: "Local writer returned insufficient evidence; no supplemental prose.")
    }
    #expect(refused.answer.receipt.model == nil, "no model wrote the displayed deterministic answer")
    #expect(refused.answer.receipt.stages.last?.counters["local_writer_requested"] == 1)
    #expect(refused.answer.receipt.stages.last?.note?.contains("Fixture refused writer") == true)
    #expect(refused.answer.receipt.stages.last?.note?.contains("insufficient evidence") == true)
}

// CLI clipping once dropped the rival/counter floor IDs while retaining their quoted text.
@Test("CLI clipping preserves the floor objects represented by claim caveats")
func cliClippingPreservesRepresentedObjects() {
    let ids = [ObjectID("fixture-main"), ObjectID("fixture-counter")]
    let source = GroundingSource(index: 1, title: "Fixture claim", text: "A claim with a counter-record.",
                                 objectID: ids[0], authority: .modelInference, claimID: ClaimID("fixture-claim"), representedObjectIDs: ids)
    #expect(Conversation.clippedForCLI([source]).first?.representedObjectIDs == ids)
}

// Shortcut text appended bare statements even after a model had correctly caveated them.
@Test("Shortcut output qualifies stored claims with and without supplemental prose")
func shortcutClaimsKeepTheirStanding() async throws {
    let f = try await GroundingFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    var answer = try await Reasoner(store: f.store).answer("fixture", persistReceipt: false)
    let claim = ClaimID("fixture-disputed")
    answer.insufficientEvidence = nil
    answer.points = [AnswerPoint(statement: "Quillberry is active.", supporting: [],
        counter: [Evidence(objectID: ObjectID("fixture-counter"), snippet: "Quillberry has no maintainer.", authority: .authoredArtifact)],
        confidence: 0.6, authority: .modelInference, derivation: .inferred, claimID: claim,
        subject: EntityID("fixture-subject"), predicate: Predicate.status, claimRows: [claim])]
    let rival = ClaimID("fixture-rival")
    let winner = ClaimID("fixture-winner")
    answer.contradictions = [
        Contradiction(claimA: claim, claimB: rival, kind: .directConflict, resolution: .unresolved, reason: "both retained"),
        Contradiction(claimA: claim, claimB: winner, kind: .directConflict, resolution: .supersededByAuthority, winner: winner, reason: "higher standing"),
    ]
    for brief in [String?.none, "A supplemental summary."] {
        let text = answer.shortcutText(brief: brief)
        #expect(text.contains("Stored claims:"))
        #expect(!text.contains("Believed claims:"))
        #expect(text.contains("Inferred by OpenCore"))
        #expect(text.contains("Counter-evidence: Quillberry has no maintainer."))
        #expect(text.contains("Open contradiction: both retained"))
        #expect(text.contains("Overruled: higher standing"))
    }
}
