import CoreModel
import Foundation
import Testing

@testable import CoreStore

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-test-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

private func makeSource() -> Source {
    Source(kind: .github, handle: "tester", displayName: "test", defaultAuthority: .authoredArtifact, defaultDomain: .project)
}

@Test("migration creates the schema and is idempotent")
func migrationIsIdempotent() async throws {
    let store = try await temporaryStore()
    try await store.database.migrate()
    try await store.database.migrate()

    let applied = try await store.database.query("SELECT COUNT(*) AS n FROM schema_migration")
    #expect(applied.first?.requireInt("n") == 1)
}

@Test("re-ingesting unchanged text leaves the row alone")
func ingestIsContentAddressed() async throws {
    let store = try await temporaryStore()
    let source = makeSource()
    try await store.upsert(source)

    let object = CoreObject(
        sourceID: source.id, kind: .commit, externalID: "abc123",
        title: "first", text: "hello world", domain: .project, authority: .authoredArtifact
    )

    let first = try await store.ingest([object])
    #expect(first.inserted == 1)

    let second = try await store.ingest([object])
    #expect(second.unchanged == 1)
    #expect(second.inserted == 0)

    var edited = object
    edited.text = "hello, world, revised"
    edited.contentHash = Digest.hex(edited.text)
    let third = try await store.ingest([edited])
    #expect(third.updated == 1)
    #expect(try await store.objectCount() == 1)
}

@Test("full-text search finds an ingested object")
func fullTextIndexIsPopulated() async throws {
    let store = try await temporaryStore()
    let source = makeSource()
    try await store.upsert(source)

    try await store.ingest([
        CoreObject(
            sourceID: source.id, kind: .commit, externalID: "sha1",
            title: "Replace vector-only retrieval with hybrid BM25",
            text: "Replace vector-only retrieval with hybrid BM25",
            domain: .project, authority: .authoredArtifact
        )
    ])

    let rows = try await store.database.query(
        "SELECT o.id FROM object_fts JOIN object o ON o.rowid = object_fts.rowid WHERE object_fts MATCH ?",
        [.text("\"hybrid\"")]
    )
    #expect(rows.count == 1)
}

@Test("deleting derived rows leaves objects intact")
func objectsAreTheFloor() async throws {
    let store = try await temporaryStore()
    let source = makeSource()
    try await store.upsert(source)
    try await store.ingest([
        CoreObject(sourceID: source.id, kind: .repository, externalID: "me/thing", title: "thing",
                   text: "a thing", domain: .project, authority: .authoredArtifact)
    ])

    let entity = CoreEntity(kind: .project, canonicalName: "thing", domain: .project)
    try await store.upsert([entity])
    try await store.save([
        CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active",
                  confidence: 0.9, authority: .derivedPattern, derivation: .inferred,
                  validity: Validity(observedAt: Date()), domain: .project)
    ])

    #expect(try await store.claimCount() == 1)
    try await store.database.execute("DELETE FROM claim")
    #expect(try await store.claimCount() == 0)
    #expect(try await store.objectCount() == 1)
}

@Test("a retracted claim is preserved, not deleted")
func retractionPreservesHistory() async throws {
    let store = try await temporaryStore()
    let entity = CoreEntity(kind: .project, canonicalName: "thing", domain: .project)
    try await store.upsert([entity])

    let claim = CoreClaim(
        subject: entity.id, predicate: Predicate.status, literal: "active",
        confidence: 0.9, authority: .derivedPattern, derivation: .inferred,
        validity: Validity(observedAt: Date()), domain: .project
    )
    try await store.save([claim])
    try await store.retract(claim.id, at: Date())

    #expect(try await store.claimCount() == 0)
    let recovered = try await store.claim(claim.id)
    #expect(recovered != nil)
    #expect(recovered?.validity.isCurrent == false)
}

@Test("a receipt round-trips with its stages and null confidence")
func receiptRoundTrips() async throws {
    let store = try await temporaryStore()
    let receipt = Receipt(
        query: "why did retrieval change?",
        queryClass: .causal,
        domainsAdmitted: [.project, .publicRecord],
        domainsBlocked: [.medical],
        stages: [ReceiptStage(name: "retrieve", counters: ["retrieved": 7], milliseconds: 12)],
        objectsSearched: 1000, objectsRetrieved: 7, evidenceAdmitted: 3,
        claimsConsulted: 2, contradictionsSurfaced: 1,
        model: nil, objectsTransmitted: 0, confidence: nil
    )
    try await store.save(receipt)

    let recovered = try await store.receipt(code: receipt.shortCode)
    #expect(recovered != nil)
    // Unmeasured confidence must survive as nil rather than becoming a plausible number.
    #expect(recovered?.confidence == nil)
    #expect(recovered?.stages.first?.counters["retrieved"] == 7)
    #expect(recovered?.domainsBlocked == [.medical])
}
