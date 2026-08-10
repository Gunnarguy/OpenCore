import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreSearch

/// **The bug.** `denseWeight` has been 0 since it was measured net-harmful on 2026-08-09, and
/// `absorb` discards the dense leg on its first line at that weight. `search` computed it
/// anyway: it embedded the query and scored every `chunk_vector` row before throwing the whole
/// result away. Telemetry measured it at 320ms of a 350ms warm query, so 91% of retrieval time
/// produced nothing at all. Cold, the query embedding alone was 594ms.
///
/// **Two independent guards**, asserted separately because a test that passes on one cannot
/// tell you the other was deleted:
///
/// 1. `search` must not run the leg when its weight is 0, and must say so rather than
///    reporting a silent zero, and
/// 2. `rankings` must still run it unconditionally. The eval harness measures the dense leg
///    through `rankings`, and that measurement is the entire reason the weight is 0. A guard
///    added there would delete the evidence for the decision that motivated this fix.
@Suite("Dense leg")
struct DenseLegSkipTests {
    private static func temporaryStore() async throws -> Store {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3")
        return try await Store.open(at: path)
    }

    /// Counts every call, so "did the leg run" is a fact about execution rather than an
    /// inference from the result set. A leg that ran and returned nothing and a leg that never
    /// ran are indistinguishable from the output alone, and only one of them is the fix.
    private actor CountingEmbedder: EmbeddingProvider {
        nonisolated let modelIdentifier = "counting-test-embedder"
        nonisolated let dimensions = 3
        private(set) var calls = 0

        func embed(_ text: String) async throws -> [Float] {
            calls += 1
            return [1, 0, 0]
        }

        func embed(batch: [String]) async throws -> [[Float]] {
            calls += batch.count
            return batch.map { _ in [1, 0, 0] }
        }
    }

    private static func seed(_ store: Store) async throws -> CoreObject {
        let source = Source(
            kind: .github, handle: "tester", displayName: "test",
            defaultAuthority: .authoredArtifact, defaultDomain: .project
        )
        try await store.upsert(source)
        let object = CoreObject(
            sourceID: source.id, kind: .document, externalID: "doc1", title: "retrieval notes",
            text: "reciprocal rank fusion blends two retrieval legs",
            domain: .project, authority: .authoredArtifact
        )
        try await store.ingest([object])
        let chunk = CoreChunk(
            objectID: object.id, ordinal: 0,
            text: "reciprocal rank fusion blends two retrieval legs", range: 0..<48
        )
        try await store.save([chunk])
        try await store.save(
            vectors: [StoredVector(chunkID: chunk.id, model: "counting-test-embedder", values: [1, 0, 0])],
            dimensions: 3
        )
        return object
    }

    @Test("search does not embed the query when the dense leg is weighted to zero")
    func searchSkipsTheDenseLegAtZeroWeight() async throws {
        let store = try await Self.temporaryStore()
        _ = try await Self.seed(store)
        let embedder = CountingEmbedder()

        var tuning = RetrievalTuning.default
        tuning.denseWeight = 0
        let outcome = try await PassageSearch(store: store, embedder: embedder, tuning: tuning)
            .search(query: "retrieval legs", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project))

        // The expensive half. Embedding the query was 63ms warm and 594ms cold, and it happened
        // on every single query for a leg whose output was discarded.
        #expect(await embedder.calls == 0)
        #expect(outcome.denseCandidates == 0)

        // A disabled leg must be as loud as a broken one. Reporting 0 candidates with no reason
        // is indistinguishable from a leg that ran and found nothing.
        #expect(outcome.unavailableSignals["semantic-disabled"] != nil)

        // The whole point: skipping the leg must not change which passages come back, because
        // `absorb` was discarding them anyway.
        #expect(!outcome.hits.isEmpty)
    }

    @Test("search still runs the dense leg when it carries weight")
    func searchRunsTheDenseLegWhenWeighted() async throws {
        let store = try await Self.temporaryStore()
        _ = try await Self.seed(store)
        let embedder = CountingEmbedder()

        var tuning = RetrievalTuning.default
        tuning.denseWeight = 1
        _ = try await PassageSearch(store: store, embedder: embedder, tuning: tuning)
            .search(query: "retrieval legs", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project))

        // The guard must be on the weight, not on the leg. A version that skipped dense
        // unconditionally would pass the test above and silently break real hybrid retrieval
        // the day the embedding question is settled and the weight goes back up.
        #expect(await embedder.calls == 1)
    }

    @Test("rankings measures the dense leg even at zero weight, because that is what set it")
    func rankingsAlwaysRunsTheDenseLeg() async throws {
        let store = try await Self.temporaryStore()
        _ = try await Self.seed(store)
        let embedder = CountingEmbedder()

        var tuning = RetrievalTuning.default
        tuning.denseWeight = 0
        _ = try await PassageSearch(store: store, embedder: embedder, tuning: tuning)
            .rankings(query: "retrieval legs", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project))

        // `opencore eval` reports dense nDCG through this path. Copying the `search` guard here
        // would make the harness report 0 for a leg it never ran, and the next person to read
        // the table would conclude the embeddings had broken.
        #expect(await embedder.calls == 1)
    }
}
