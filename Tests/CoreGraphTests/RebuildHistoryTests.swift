import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreGraph

/// **The bug, and it is the worst one this project has had.** Measured 2026-08-12 on the real
/// store. Before a routine `opencore rebuild`: one contradiction, MMT-2025 `status` going
/// `dormant` to `active` by temporal supersession, and a belief at v2 reading "changed from
/// 'dormant' to 'active'". After: contradiction table empty, 43 beliefs all at version 1, all
/// reading "first evidence for this slot". The only change of mind in the entire store, and the
/// only working demonstration of the bitemporal design, destroyed by a maintenance command that
/// reported success.
///
/// Objects were upserted in place, so `ON CONFLICT DO UPDATE` overwrote the older `pushed_at`
/// that the `dormant` reading came from. Re-deriving could then only ever produce `active`.
/// The claim layer held history the object layer did not, which contradicts the project's first
/// non-negotiable: "Objects are the floor. Nothing derived may be the only copy of anything."
/// The invariant had not drifted; it was never achievable, because a mutable source has history
/// and the floor did not record it.
///
/// Migration 6 adds `object_version`, and `IngestPipeline.rederive()` replays it in stages
/// before deriving from the current objects. This test is the proof, and it is deliberately end to end rather than a unit
/// test of the table: the failure was not in any one function, it was in what survived a
/// round trip through the whole pipeline.

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-history-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

private let source = Source(
    kind: .github, handle: "gunnarguy", displayName: "gunnarguy",
    defaultAuthority: .authoredArtifact, defaultDomain: .project
)

private let january = Date(timeIntervalSince1970: 1_737_000_000)   // 2025-01-16
private let august = Date(timeIntervalSince1970: 1_754_000_000)    // 2025-08-01
private let now = Date(timeIntervalSince1970: 1_754_100_000)

/// The same repository, at two points in its life. Same `externalID`, so the second ingest is an
/// update rather than an insert, which is exactly the shape that used to destroy the first.
private func repository(pushedAt: Date) -> CoreObject {
    CoreObject(
        sourceID: source.id,
        kind: .repository,
        externalID: "gunnarguy/MMT-2025",
        title: "MMT-2025",
        // Text differs with the date so `contentHash` changes and the ingest is an update.
        text: "gunnarguy/MMT-2025\n\nLast pushed \(ISO8601DateFormatter().string(from: pushedAt)).",
        authoredAt: Date(timeIntervalSince1970: 1_700_000_000),
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "repo": "gunnarguy/MMT-2025",
            "pushed_at": ISO8601DateFormatter().string(from: pushedAt),
        ]
    )
}

@Test("a rebuild reproduces the contradiction it used to destroy")
func rebuildReproducesSupersession() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    // January's sync: nothing pushed for seven months, so the repository reads dormant.
    _ = try await IngestPipeline(store: store, now: january.addingTimeInterval(200 * 86_400))
        .run(objects: [repository(pushedAt: january)])

    // August's sync: the same repository, freshly pushed. This is the upsert that used to
    // overwrite January's content with no trace.
    _ = try await IngestPipeline(store: store, now: now)
        .run(objects: [repository(pushedAt: august)])

    let before = try await store.contradictions(unresolvedOnly: false)
    #expect(before.count == 1)
    #expect(before.first?.resolution == .supersededByRecency)

    let key = try #require(
        try await store.allClaims(currentOnly: false, limit: 100).first { $0.predicate == Predicate.status }
    ).claimKey
    #expect(try await store.beliefHistory(key: key).count == 2)

    // The rebuild. Exactly what `opencore rebuild` and the Maintenance screen do.
    try await store.dropDerivedLayers()
    _ = try await IngestPipeline(store: store, now: now).rederive()

    // The assertion the old code failed. Not "some contradiction exists": the same one, with the
    // same resolution, because a rebuild that produces a *different* graph is its own defect.
    let after = try await store.contradictions(unresolvedOnly: false)
    #expect(after.count == 1)
    #expect(after.first?.resolution == .supersededByRecency)

    // And the belief still knows it changed its mind. Before migration 6 this was 1, reading
    // "first evidence for this slot", which is a confident statement that nothing ever happened.
    let history = try await store.beliefHistory(key: key)
    #expect(history.count == 2)
    #expect(history.last?.reason.contains("dormant") == true)

    // Replayed for derivation, never indexed. Retrieval answers from what is true now, so a
    // superseded revision must not become a passage: a README's previous wording surfacing as
    // though it still stood would be a worse failure than the one this whole change fixes.
    let indexed = try await store.lexicalChunks(match: "pushed", limit: 20).map(\.chunk.text)
    #expect(indexed.allSatisfy { !$0.contains(ISO8601DateFormatter().string(from: january)) })
    #expect(indexed.contains { $0.contains(ISO8601DateFormatter().string(from: august)) })
}

@Test("replaying history does not manufacture a version out of an unchanged object")
func unchangedObjectRecordsNoHistory() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let object = repository(pushedAt: august)
    // Twice, byte-identical. `ingest` short-circuits on matching contentHash, so this must not
    // record a version. The failure it guards is the mirror of the bug above and just as bad:
    // a store that grows a version row per sync would double-derive every claim on every
    // rebuild and report a graph that grows without anything having happened.
    _ = try await store.ingest([object])
    let second = try await store.ingest([object])

    #expect(second.unchanged == 1)
    #expect(second.versioned == 0)
    #expect(try await store.objectHistory().isEmpty)
}

@Test("an object's superseded content is preserved, and it is not derived data")
func supersededContentSurvivesDroppingDerivedLayers() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    _ = try await store.ingest([repository(pushedAt: january)])
    let updated = try await store.ingest([repository(pushedAt: august)])
    #expect(updated.updated == 1)
    #expect(updated.versioned == 1)

    // The point of the whole change: this survives the thing that destroyed everything else.
    try await store.dropDerivedLayers()

    let history = try await store.objectHistory()
    #expect(history.count == 1)
    #expect(history.first?.metadata["pushed_at"] == ISO8601DateFormatter().string(from: january))

    // And it is genuinely the old content, not a pointer at the current row.
    let current = try await store.allObjects()
    #expect(current.first?.metadata["pushed_at"] == ISO8601DateFormatter().string(from: august))
}
