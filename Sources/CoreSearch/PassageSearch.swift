import CoreModel
import CoreStore
import Foundation

public struct PassageHit: Sendable {
    public var chunk: CoreChunk
    public var object: CoreObject
    public var score: Double
    /// Rank in each retrieval leg, 1-based. Absent means the leg did not return it, which
    /// is different from returning it last.
    public var ranks: [String: Int]
    public var signals: [String: Double]
    /// Neighbouring passages, when the hit was expanded back into its context.
    public var context: [CoreChunk]
}

public struct PassageOutcome: Sendable {
    public var hits: [PassageHit]
    public var chunksSearched: Int
    public var lexicalCandidates: Int
    public var denseCandidates: Int
    public var afterFusion: Int
    public var blockedByDomain: Int
    public var droppedByDiversity: Int
    public var unavailableSignals: [String: String]
    public var stageTimings: [String: Int]
}

/// The OpenIntelligence retrieval shape, over passages:
///
/// ```
/// query ──┬─► dense (cosine over chunk vectors) ──┐
///         └─► lexical (BM25 over chunk_fts) ──────┴─► RRF fuse ─► MMR ─► admit ─► expand
/// ```
///
/// Two legs run independently and are fused by **rank**, not by score. That is the point
/// of Reciprocal Rank Fusion: BM25 returns unbounded negative numbers and cosine returns
/// -1...1, so any attempt to blend the raw values requires inventing a normalisation, and
/// the invented constant ends up doing more work than either retriever. Ranks are
/// comparable by construction.
/// The knobs.
///
/// Every value here is **chosen, not measured**, and they are gathered into one type for two
/// reasons. First, so the honesty is in one place rather than scattered across comments.
/// Second, so they can be varied: an eval harness sweeping these, or a laboratory comparing
/// two configurations side by side, both need them to be data rather than constants.
///
/// Changing any of these invalidates nothing on disk. Chunking parameters are the exception
/// and live on `Chunker`, because changing those requires re-chunking and re-embedding.
public struct RetrievalTuning: Sendable, Hashable, Codable {
    /// RRF damping. 60 is the value from the original Cormack et al. formulation, used
    /// unchanged because nothing here has measured an alternative. It controls how quickly
    /// rank advantage decays: higher means a top-1 hit in one leg matters less relative to
    /// appearing in both.
    public var rrfK: Double

    /// MMR trade-off. Higher keeps relevance dominant; lower penalises a result that says the
    /// same thing as one already selected. At 1.0 MMR is off entirely.
    public var mmrLambda: Double

    /// How many candidates each leg contributes before fusion. Raising it costs a linear scan
    /// on the dense side and finds more of the tail.
    public var candidatesPerLeg: Int

    /// Scaling applied to the authority and recency terms so they do not swamp RRF output,
    /// which is small (~0.03). Arbitrary, and the most obviously unprincipled number here.
    public var signalScale: Double

    public static let `default` = RetrievalTuning(rrfK: 60, mmrLambda: 0.7, candidatesPerLeg: 100, signalScale: 0.02)

    public init(rrfK: Double, mmrLambda: Double, candidatesPerLeg: Int, signalScale: Double) {
        self.rrfK = rrfK
        self.mmrLambda = mmrLambda
        self.candidatesPerLeg = candidatesPerLeg
        self.signalScale = signalScale
    }

    /// True when every value still matches the shipped default, so a UI can say whether what
    /// you are looking at is the baseline or something you changed.
    public var isDefault: Bool { self == .default }
}

public struct PassageSearch: Sendable {
    private let store: Store
    private let embedder: (any EmbeddingProvider)?
    public let tuning: RetrievalTuning

    public init(store: Store, embedder: (any EmbeddingProvider)? = nil, tuning: RetrievalTuning = .default) {
        self.store = store
        self.embedder = embedder
        self.tuning = tuning
    }

    public func search(
        query: String,
        queryClass: QueryClass,
        policy: AdmissionPolicy,
        limit: Int = 12,
        candidatesPerLeg: Int? = nil,
        expandContext: Bool = true
    ) async throws -> PassageOutcome {
        var unavailable: [String: String] = [:]
        var timings: [String: Int] = [:]

        let chunksSearched = try await store.chunkCount()

        // ---- Leg 1: lexical ----
        let lexicalStart = DispatchTime.now().uptimeNanoseconds
        let match = HybridSearch.ftsQuery(from: query)
        let perLeg = candidatesPerLeg ?? tuning.candidatesPerLeg
        let lexical = try await store.lexicalChunks(match: match, limit: perLeg)
        timings["lexical"] = elapsed(since: lexicalStart)

        // ---- Leg 2: dense ----
        var dense: [ChunkCandidate] = []
        let denseStart = DispatchTime.now().uptimeNanoseconds
        if let embedder {
            let embedded = try await store.embeddedChunkCount(model: embedder.modelIdentifier)
            if embedded == 0 {
                unavailable["semantic"] = "provider '\(embedder.modelIdentifier)' is configured but no chunk has a vector yet; run `opencore embed`"
            } else {
                let vector = try await embedder.embed(query)
                if vector.isEmpty {
                    unavailable["semantic"] = "query produced no embedding"
                } else {
                    dense = try await store.denseChunks(query: vector, model: embedder.modelIdentifier, limit: perLeg)
                    if embedded < chunksSearched {
                        // Partial coverage is a correctness problem masquerading as a
                        // performance one: the dense leg silently cannot see the
                        // un-embedded remainder. Say so rather than returning a
                        // confident answer over a fraction of the corpus.
                        unavailable["semantic-coverage"] = "\(embedded) of \(chunksSearched) chunks embedded; the dense leg cannot see the rest"
                    }
                }
            }
        } else {
            unavailable["semantic"] = "no embedding provider configured; lexical carries this query alone"
        }
        timings["dense"] = elapsed(since: denseStart)

        // ---- Fuse by rank ----
        let fuseStart = DispatchTime.now().uptimeNanoseconds
        var fused: [ChunkID: PassageHit] = [:]

        func absorb(_ candidates: [ChunkCandidate], leg: String) {
            for (index, candidate) in candidates.enumerated() {
                let rank = index + 1
                let contribution = 1.0 / (tuning.rrfK + Double(rank))
                if var existing = fused[candidate.chunk.id] {
                    existing.score += contribution
                    existing.ranks[leg] = rank
                    existing.signals[leg] = candidate.rawScore
                    fused[candidate.chunk.id] = existing
                } else {
                    fused[candidate.chunk.id] = PassageHit(
                        chunk: candidate.chunk,
                        object: candidate.object,
                        score: contribution,
                        ranks: [leg: rank],
                        signals: [leg: candidate.rawScore],
                        context: []
                    )
                }
            }
        }

        absorb(lexical, leg: "lexical")
        absorb(dense, leg: "dense")
        timings["fuse"] = elapsed(since: fuseStart)

        // ---- Domain admission, before any further ranking ----
        let admitted = fused.values.filter { policy.admits($0.object.domain) }
        let blocked = fused.count - admitted.count

        // ---- Non-relevance signals fold in after fusion ----
        let now = Date()
        let weights = queryClass.weights
        var scored = admitted.map { hit -> PassageHit in
            var hit = hit
            let authority = Double(hit.object.authority.rawValue) / Double(Authority.directStatement.rawValue)
            let temporal: Double
            if let authoredAt = hit.object.authoredAt {
                temporal = pow(0.5, max(0, now.timeIntervalSince(authoredAt) / 86_400) / 365.0)
            } else {
                temporal = 0
            }
            hit.signals["authority"] = authority
            hit.signals["temporal"] = temporal
            // RRF output is small (~0.03 max), so the additive terms are scaled to match
            // rather than swamping it. This scaling is arbitrary and is flagged as such
            // in Docs/RETRIEVAL.md; it is exactly the kind of constant the eval harness
            // exists to replace.
            hit.score += (weights.authority * authority + weights.temporal * temporal) * tuning.signalScale
            return hit
        }
        scored.sort { $0.score > $1.score }

        // ---- MMR ----
        let mmrStart = DispatchTime.now().uptimeNanoseconds
        let diversified = diversify(scored, limit: limit)
        let dropped = min(scored.count, limit * 2) - diversified.count
        timings["mmr"] = elapsed(since: mmrStart)

        // ---- Expand back into context ----
        var final = diversified
        if expandContext {
            for index in final.indices {
                final[index].context = (try? await store.neighbours(of: final[index].chunk, window: 1)) ?? []
            }
        }

        return PassageOutcome(
            hits: final,
            chunksSearched: chunksSearched,
            lexicalCandidates: lexical.count,
            denseCandidates: dense.count,
            afterFusion: fused.count,
            blockedByDomain: blocked,
            droppedByDiversity: max(0, dropped),
            unavailableSignals: unavailable,
            stageTimings: timings
        )
    }

    // MARK: - MMR

    /// Maximal Marginal Relevance.
    ///
    /// Greedily picks the highest-scoring passage, then repeatedly picks whichever
    /// remaining passage maximises `λ·relevance − (1−λ)·maxSimilarityToAlreadyPicked`.
    /// Without it, retrieval over a personal corpus returns five phrasings of one
    /// paragraph, which reads as five pieces of corroborating evidence and is one.
    ///
    /// Similarity here is lexical overlap rather than cosine, because it must work when
    /// the dense leg did not run. That is a weaker signal than vector similarity and is
    /// documented as such.
    private func diversify(_ hits: [PassageHit], limit: Int) -> [PassageHit] {
        guard hits.count > 1 else { return hits }

        var pool = Array(hits.prefix(limit * 2))
        var selected: [PassageHit] = []
        var selectedTokens: [Set<String>] = []

        let tokenSets = pool.map { Self.tokens(of: $0.chunk.text) }
        var available = Array(pool.indices)

        while selected.count < limit, !available.isEmpty {
            var bestIndex = available[0]
            var bestValue = -Double.infinity

            for index in available {
                let relevance = pool[index].score
                var maximumSimilarity = 0.0
                for tokens in selectedTokens {
                    maximumSimilarity = max(maximumSimilarity, Self.jaccard(tokenSets[index], tokens))
                }
                let value = tuning.mmrLambda * relevance - (1 - tuning.mmrLambda) * maximumSimilarity * relevanceScale(pool)
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }

            var chosen = pool[bestIndex]
            chosen.signals["mmr"] = bestValue
            selected.append(chosen)
            selectedTokens.append(tokenSets[bestIndex])
            available.removeAll { $0 == bestIndex }
        }
        return selected
    }

    /// Similarity is 0...1 while RRF relevance is ~0.03, so the penalty is scaled into the
    /// same range. Otherwise the diversity term dominates completely and MMR returns
    /// whatever is most *different*, which is usually whatever is least relevant.
    private func relevanceScale(_ hits: [PassageHit]) -> Double {
        hits.first?.score ?? 1.0
    }

    public static func tokens(of text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.count + b.count - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func elapsed(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
