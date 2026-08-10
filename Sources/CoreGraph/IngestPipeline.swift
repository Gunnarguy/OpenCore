import CoreModel
import CoreStore
import CoreTelemetry
import Foundation

/// The one path from raw objects to a reconciled graph.
///
/// It exists so the CLI, the app, and `rebuild` cannot drift apart. Before this, adding a
/// stage meant remembering to add it in three places, and the third place is exactly where
/// a derived layer silently stops being rebuilt.
public struct IngestPipeline: Sendable {
    private let store: Store
    private let chunker: Chunker
    private let now: Date

    public init(store: Store, chunker: Chunker = Chunker(), now: Date = Date()) {
        self.store = store
        self.chunker = chunker
        self.now = now
    }

    public struct Outcome: Sendable {
        public var ingest = IngestOutcome()
        public var chunks = 0
        public var entities = 0
        public var aliases = 0
        public var claims = 0
        public var events = 0
        public var evidence = 0
        public var beliefs = 0
        public var contradictions = 0
        public var contradictionsResolved = 0
        public var contradictionsOpen = 0
    }

    /// Store objects, then derive everything above them.
    ///
    /// - Parameter storeObjects: false when the objects are already on disk, which is the
    ///   `rebuild` case: re-deriving must never rewrite the floor it is deriving from.
    public func run(objects: [CoreObject], storeObjects: Bool = true, log: @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        try await Telemetry.span("pipeline.run", .graph, attributes: ["storeObjects": String(storeObjects)]) { pipeline in
            pipeline.set("objects.in", objects.count)
            var outcome = Outcome()

            if storeObjects {
                outcome.ingest = try await Telemetry.span("store.objects", .graph) { scope in
                    let ingested = try await store.ingest(objects)
                    scope.set("inserted", ingested.inserted)
                    scope.set("updated", ingested.updated)
                    scope.set("unchanged", ingested.unchanged)
                    return ingested
                }
                log("objects: \(outcome.ingest.inserted) new, \(outcome.ingest.updated) changed, \(outcome.ingest.unchanged) unchanged")
            }

            // Chunks. Passages come before entities because everything retrieval-facing
            // depends on them, and a failure here should surface before the expensive stages.
            let allChunks = try await Telemetry.span("chunk", .graph) { scope in
                var chunks: [CoreChunk] = []
                for object in objects {
                    chunks.append(contentsOf: chunker.chunks(for: object))
                }
                try await store.save(chunks)
                scope.set("chunks", chunks.count)
                // Chunks per object is the number that says whether the chunker is doing
                // anything: a corpus averaging 1.0 means every object is landing under the
                // split threshold and the structure-first splitter never runs.
                if !objects.isEmpty {
                    scope.attribute("perObject", String(format: "%.1f", Double(chunks.count) / Double(objects.count)))
                }
                return chunks
            }
            outcome.chunks = allChunks.count
            log("chunks: \(allChunks.count)")

            let resolved = try await Telemetry.span("resolve.entities", .graph) { scope in
                let resolved = try await EntityResolver(store: store).resolve(objects: objects)
                scope.set("entities", resolved.entities)
                scope.set("aliases", resolved.aliases)
                return resolved
            }
            outcome.entities = resolved.entities
            outcome.aliases = resolved.aliases
            log("entities: \(resolved.entities) with \(resolved.aliases) aliases")

            let extracted = try await Telemetry.span("extract.claims", .graph) { scope in
                let extracted = try await ClaimExtractor(store: store, now: now).extract(from: objects)
                scope.set("claims", extracted.claims)
                scope.set("events", extracted.events)
                scope.set("evidence", extracted.evidence)
                return extracted
            }
            outcome.claims = extracted.claims
            outcome.events = extracted.events
            outcome.evidence = extracted.evidence
            log("claims: \(extracted.claims) from \(extracted.evidence) evidence spans, \(extracted.events) events")

            let reconciled = try await Telemetry.span("reconcile.beliefs", .graph) { scope in
                let reconciled = try await BeliefEngine(store: store, now: now).reconcile()
                scope.set("beliefs", reconciled.beliefsWritten)
                scope.set("contradictions", reconciled.contradictionsFound)
                scope.set("resolved", reconciled.resolved)
                // Unresolved contradictions are the ones a person has to look at, so they are
                // a counter rather than something inferred from the other two.
                scope.set("open", reconciled.unresolved)
                return reconciled
            }
            outcome.beliefs = reconciled.beliefsWritten
            outcome.contradictions = reconciled.contradictionsFound
            outcome.contradictionsResolved = reconciled.resolved
            outcome.contradictionsOpen = reconciled.unresolved
            log("beliefs: \(reconciled.beliefsWritten) written, \(reconciled.contradictionsFound) contradictions (\(reconciled.resolved) resolved, \(reconciled.unresolved) open)")

            return outcome
        }
    }
}

/// Builds vectors for chunks that do not have one yet.
///
/// Resumable by construction: it asks the store for chunks missing a vector for this
/// model, so an interrupted run continues rather than restarting. That matters because
/// embedding a real corpus takes minutes and the first thing anyone does is press Ctrl-C.
public struct EmbeddingIndexer: Sendable {
    private let store: Store
    private let provider: any EmbeddingProvider

    public init(store: Store, provider: any EmbeddingProvider) {
        self.store = store
        self.provider = provider
    }

    @discardableResult
    public func run(batchSize: Int = 32, log: @Sendable (String) -> Void = { _ in }) async throws -> Int {
        try await Telemetry.span(
            "embed",
            .graph,
            attributes: ["model": provider.modelIdentifier, "dimensions": String(provider.dimensions), "batchSize": String(batchSize)]
        ) { run in
            let total = try await store.chunkCount()
            var done = try await store.embeddedChunkCount(model: provider.modelIdentifier)
            let startedAt = done
            run.set("chunks.total", total)
            run.set("chunks.alreadyEmbedded", startedAt)

            while true {
                let pending = try await store.chunksMissingVectors(model: provider.modelIdentifier, limit: batchSize)
                guard !pending.isEmpty else { break }

                let stored = try await Telemetry.span("embed.batch", .graph) { batch in
                    batch.set("pending", pending.count)
                    let vectors = try await provider.embed(batch: pending.map(\.text))
                    var stored: [StoredVector] = []
                    for (chunk, values) in zip(pending, vectors) where !values.isEmpty {
                        stored.append(StoredVector(chunkID: chunk.id, model: provider.modelIdentifier, values: values))
                    }
                    batch.set("vectors", stored.count)
                    // The gap between pending and vectors is chunks the provider returned
                    // nothing for. Silently dropping them is how a corpus ends up with
                    // partial coverage that nobody notices.
                    batch.set("empty", pending.count - stored.count)
                    return stored
                }
                run.count("vectors", stored.count)
                run.count("batches")

                // A chunk whose embedding came back empty would otherwise be selected forever,
                // so the loop must make progress on batch size rather than on stored count.
                guard !stored.isEmpty || pending.isEmpty else {
                    Telemetry.event("embed.stalled", .graph, attributes: ["pending": String(pending.count)])
                    log("warning: a batch of \(pending.count) produced no vectors; stopping to avoid an infinite loop")
                    break
                }

                try await store.save(vectors: stored, dimensions: provider.dimensions)
                done += stored.count
                log("embedded \(done)/\(total)")
                try await store.recordEmbeddingRun(model: provider.modelIdentifier, dimensions: provider.dimensions, chunksDone: done, finished: false)
            }

            try await store.recordEmbeddingRun(model: provider.modelIdentifier, dimensions: provider.dimensions, chunksDone: done, finished: true)
            run.set("chunks.embeddedThisRun", done - startedAt)
            // Coverage is the number that decides whether a weak dense leg is a model problem
            // or an index problem, and it was previously only obtainable by hand.
            if total > 0 {
                run.attribute("coverage", String(format: "%.1f%%", Double(done) / Double(total) * 100))
            }
            return done - startedAt
        }
    }
}
