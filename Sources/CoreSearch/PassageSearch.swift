import CoreModel
import CoreStore
import CoreTelemetry
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

    /// Keys used for the dense leg's unavailability. Named here because they are written in
    /// one module and read in another, and a literal on each side is a mismatch waiting to
    /// happen. It happened: the engine wrote `semantic-disabled` and the app tested for
    /// `semantic`, so a leg that had been switched off read as a leg that ran and found
    /// nothing.
    public enum Signal {
        /// No provider, no vectors, or no query embedding. The leg could not run.
        public static let semantic = "semantic"
        /// Weighted to zero by tuning, so it was deliberately not run.
        public static let semanticDisabled = "semantic-disabled"
        /// It ran, but part of the corpus has no vectors yet. Still a measurement.
        public static let semanticCoverage = "semantic-coverage"
    }

    /// True when the dense leg actually ran, so `denseCandidates` is a measurement rather
    /// than an absence.
    ///
    /// **Zero because a leg never ran is not a measurement of zero**, which is the rule this
    /// whole `unavailableSignals` channel exists to enforce, and the display was breaking it.
    /// Partial coverage does not count as "did not run": the leg ran and saw part of the
    /// corpus, which is a weaker measurement rather than no measurement, and it is reported
    /// separately as exactly that.
    public var denseLegRan: Bool {
        unavailableSignals[Signal.semantic] == nil && unavailableSignals[Signal.semanticDisabled] == nil
    }
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

    /// Per-leg multipliers on the RRF contribution.
    ///
    /// Textbook RRF has no such thing: every leg contributes `1/(k+rank)` and the method's
    /// appeal is that it needs no per-retriever calibration. That assumes the legs are
    /// *independently informative*, so agreement between them is evidence.
    ///
    /// Measured on this corpus 2026-08-09, that assumption is false and expensive. The dense
    /// leg scores nDCG@6 0.059 while lexical scores 0.420, and fusing them at equal weight
    /// produces 0.073: worse than either the good leg alone or, arithmetically, than ignoring
    /// the bad one. A leg that is close to noise still earns full RRF credit, and where its
    /// noise happens to coincide with the lexical leg's tail, the pair outranks whatever
    /// lexical put first.
    ///
    /// They are here to be swept by `opencore eval` rather than argued about.
    ///
    /// **These once defaulted to 1.0 in `init` while `.default` said 0.0**, on the reasoning
    /// that 1.0 preserved the pre-measurement behaviour for callers who omitted them. That is
    /// how the app spent two days running the measured-worst configuration: `AppSettings`
    /// built a `RetrievalTuning` without these arguments and got the *old* behaviour, not the
    /// measured one, while the CLI started from `.default` and was correct. Two defaults that
    /// disagree is not a compatibility shim, it is a trap. There is one default now.
    public var lexicalWeight: Double
    public var denseWeight: Double

    /// The first defaults in this project chosen by measurement rather than by taste.
    ///
    /// `denseWeight: 0` and `mmrLambda: 0.85` come from `opencore eval` on 2026-08-09, 20
    /// cases, nDCG@6 of the fused output:
    ///
    /// | denseWeight | mmrLambda 0.7 | mmrLambda 0.85 |
    /// |---|---|---|
    /// | 1.0 | 0.073 | 0.073 |
    /// | 0.5 | 0.136 | 0.140 |
    /// | 0.25 | 0.235 | 0.242 |
    /// | **0.0** | 0.417 | **0.422** |
    ///
    /// Monotonic, and the effect is enormous: the dense leg at equal weight was destroying
    /// 83% of the achievable score. At `denseWeight: 0` the pipeline finally beats its own
    /// lexical leg (0.422 against 0.420) instead of scoring a sixth of it.
    ///
    /// **This is a measured disable, not a deletion, and it is loud.** `search` reports the
    /// dense leg as unavailable-by-tuning so no query silently runs half a retriever. It
    /// should be reverted the day the embedding question is settled: `NLContextualEmbedding`
    /// is a mean-pooled token model and was never trained for asymmetric query-to-document
    /// retrieval, which is the leading hypothesis for why it scores 0.059 alone.
    ///
    /// `rrfK` and `signalScale` keep their chosen values. `signalScale` was swept over
    /// 0.02 / 0.005 / 0 and measured **inert**: identical nDCG at every value. The comment
    /// calling it the most unprincipled number here was right, and it turns out to be doing
    /// nothing at all, which is a separate thing to fix rather than tune.
    public static let `default` = RetrievalTuning(
        rrfK: 60, mmrLambda: 0.85, candidatesPerLeg: 100, signalScale: 0.02,
        lexicalWeight: 1.0, denseWeight: 0.0
    )

    public init(
        rrfK: Double,
        mmrLambda: Double,
        candidatesPerLeg: Int,
        signalScale: Double,
        lexicalWeight: Double = 1.0,
        // 0.0, matching `.default`. Omitting this argument must not hand a caller the
        // configuration that measurement rejected.
        denseWeight: Double = 0.0
    ) {
        self.rrfK = rrfK
        self.mmrLambda = mmrLambda
        self.candidatesPerLeg = candidatesPerLeg
        self.signalScale = signalScale
        self.lexicalWeight = lexicalWeight
        self.denseWeight = denseWeight
    }

    /// Decoded by hand so a store or a settings blob written before the leg weights existed
    /// still loads. Synthesised `Decodable` requires every key, and a settings file that
    /// silently fails to decode falls back to defaults, which would look like the user's
    /// tuning being ignored at random.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rrfK = try container.decode(Double.self, forKey: .rrfK)
        mmrLambda = try container.decode(Double.self, forKey: .mmrLambda)
        candidatesPerLeg = try container.decode(Int.self, forKey: .candidatesPerLeg)
        signalScale = try container.decode(Double.self, forKey: .signalScale)
        lexicalWeight = try container.decodeIfPresent(Double.self, forKey: .lexicalWeight) ?? 1.0
        denseWeight = try container.decodeIfPresent(Double.self, forKey: .denseWeight) ?? 1.0
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
        try await Telemetry.span(
            "search.passages",
            .search,
            attributes: ["queryClass": queryClass.rawValue, "limit": String(limit)]
        ) { search in
        var unavailable: [String: String] = [:]
        var timings: [String: Int] = [:]

        let chunksSearched = try await store.chunkCount()
        search.set("chunks.searched", chunksSearched)

        // ---- Leg 1: lexical ----
        let lexicalStart = DispatchTime.now().uptimeNanoseconds
        let match = HybridSearch.ftsQuery(from: query)
        let perLeg = candidatesPerLeg ?? tuning.candidatesPerLeg
        let lexical = try await Telemetry.span("leg.lexical", .search, attributes: ["match": String(match.prefix(120))]) { leg in
            leg.attribute("weight", String(tuning.lexicalWeight))
            let hits = try await store.lexicalChunks(match: match, limit: perLeg)
            leg.set("candidates", hits.count)
            // Hitting the cap means the leg was truncated, so a better candidate may exist
            // just past it. That is invisible from the result set alone.
            leg.attribute("sawLimit", String(hits.count >= perLeg))
            return hits
        }
        timings["lexical"] = elapsed(since: lexicalStart)

        // ---- Leg 2: dense ----
        var dense: [ChunkCandidate] = []
        let denseStart = DispatchTime.now().uptimeNanoseconds
        // A leg switched off by tuning must be as visible as one that failed. Silently
        // running half a retriever is the failure `rebuild` dropping every vector already
        // demonstrated, and a deliberate disable does not get to be quieter than an accident.
        //
        // It is also skipped rather than computed and then discarded. `absorb` drops this
        // leg's entire output on its first line when the weight is 0, so the query embedding
        // and the vector scan were pure waste: measured 2026-08-09 at 320ms of a 350ms warm
        // query, 91% of the time, producing nothing. `denseCandidates` reporting 0 afterwards
        // is honest, because the leg did not run.
        //
        // `rankings(...)` deliberately does *not* get this guard. The eval harness measures
        // the dense leg through it, and that measurement is the whole reason this weight is 0.
        if tuning.denseWeight == 0 {
            unavailable[PassageOutcome.Signal.semanticDisabled] = "dense leg weighted to 0, so it was not run; measured 2026-08-09 as net-harmful on this corpus (fused nDCG 0.073 at weight 1.0 against 0.422 at 0)"
        } else if let embedder {
            let embedded = try await store.embeddedChunkCount(model: embedder.modelIdentifier)
            if embedded == 0 {
                unavailable[PassageOutcome.Signal.semantic] = "provider '\(embedder.modelIdentifier)' is configured but no chunk has a vector yet; run `opencore embed`"
            } else {
                // Separated from `leg.dense` because it is a different cost with a different
                // cause: this is the embedding model, that is the vector scan. Folded
                // together they read as one slow leg and neither is actionable.
                let vector = try await Telemetry.span("embed.query", .search, attributes: ["model": embedder.modelIdentifier]) { scope in
                    let vector = try await embedder.embed(query)
                    scope.set("dimensions", vector.count)
                    return vector
                }
                if vector.isEmpty {
                    unavailable[PassageOutcome.Signal.semantic] = "query produced no embedding"
                } else {
                    dense = try await Telemetry.span("leg.dense", .search, attributes: ["model": embedder.modelIdentifier]) { leg in
                        leg.attribute("weight", String(tuning.denseWeight))
                        leg.set("chunks.embedded", embedded)
                        let hits = try await store.denseChunks(query: vector, model: embedder.modelIdentifier, limit: perLeg)
                        leg.set("candidates", hits.count)
                        return hits
                    }
                    if embedded < chunksSearched {
                        // Partial coverage is a correctness problem masquerading as a
                        // performance one: the dense leg silently cannot see the
                        // un-embedded remainder. Say so rather than returning a
                        // confident answer over a fraction of the corpus.
                        unavailable[PassageOutcome.Signal.semanticCoverage] = "\(embedded) of \(chunksSearched) chunks embedded; the dense leg cannot see the rest"
                    }
                }
            }
        } else {
            unavailable[PassageOutcome.Signal.semantic] = "no embedding provider configured; lexical carries this query alone"
        }
        timings["dense"] = elapsed(since: denseStart)

        // ---- Fuse by rank ----
        let fuseStart = DispatchTime.now().uptimeNanoseconds
        var fused: [ChunkID: PassageHit] = [:]

        func absorb(_ candidates: [ChunkCandidate], leg: String, weight: Double) {
            guard weight > 0 else { return }
            for (index, candidate) in candidates.enumerated() {
                let rank = index + 1
                let contribution = weight / (tuning.rrfK + Double(rank))
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

        absorb(lexical, leg: "lexical", weight: tuning.lexicalWeight)
        absorb(dense, leg: "dense", weight: tuning.denseWeight)
        timings["fuse"] = elapsed(since: fuseStart)

        Telemetry.event("fuse", .search, attributes: [
            "k": String(tuning.rrfK),
            "fused": String(fused.count),
            // Overlap is the one number that says whether the two legs are actually finding
            // different things. Equal to neither leg means genuine diversity; equal to the
            // smaller leg means one is a subset and the fusion is doing nothing.
            "overlap": String(lexical.count + dense.count - fused.count),
        ])

        // ---- Domain admission, before any further ranking ----
        let admitted = fused.values.filter { policy.admits($0.object.domain) }
        let blocked = fused.count - admitted.count
        // The firewall is the security-relevant stage, so what it blocked is recorded even
        // when it blocked nothing. An absent counter and a zero would otherwise be the same.
        Telemetry.event("admission", .search, attributes: [
            "admitted": String(admitted.count),
            "blocked": String(blocked),
        ])

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
        let diversified = Telemetry.spanSync("mmr", .search, attributes: ["lambda": String(tuning.mmrLambda)]) { scope in
            scope.set("in", scored.count)
            let result = diversify(scored, limit: limit)
            scope.set("out", result.count)
            return result
        }
        let dropped = min(scored.count, limit * 2) - diversified.count
        timings["mmr"] = elapsed(since: mmrStart)

        // ---- Expand back into context ----
        var final = diversified
        if expandContext {
            try await Telemetry.span("expand.context", .search) { scope in
                for index in final.indices {
                    final[index].context = (try? await store.neighbours(of: final[index].chunk, window: 1)) ?? []
                    scope.count("neighbours", final[index].context.count)
                }
            }
        }

        search.set("hits", final.count)
        search.set("blockedByDomain", blocked)
        search.set("droppedByDiversity", max(0, dropped))
        // Every reason a signal was missing, named. A retriever quietly running on one leg
        // is the failure mode this whole dictionary exists for, so it reaches telemetry too
        // rather than only the receipt the caller may never print.
        for (signal, reason) in unavailable {
            Telemetry.event("signal.unavailable", .search, attributes: ["signal": signal, "reason": String(reason.prefix(160))])
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
    }

    // MARK: - Per-leg rankings, for evaluation

    /// Each leg's ranked objects, independently, alongside the real pipeline's output.
    ///
    /// `search` cannot answer this. By the time it returns, the two legs have been fused,
    /// filtered by domain, re-scored by authority and recency, diversified by MMR and cut to
    /// `limit`, so a leg's own ranking is no longer recoverable from `PassageHit.ranks`:
    /// anything a leg ranked which did not survive is simply absent.
    ///
    /// Ranked by **object**, not by chunk, and deduplicated keeping the best rank. Chunk
    /// boundaries are a tuned parameter, so a benchmark keyed to chunk ids would be
    /// invalidated by the very change it exists to evaluate.
    public struct LegRankings: Sendable {
        public var lexical: [ObjectID]
        public var dense: [ObjectID]
        public var fused: [ObjectID]
        /// Why the dense leg is empty, when it is. Distinguishes "no vectors" from "found
        /// nothing", which score identically and mean opposite things.
        public var denseUnavailable: String?
    }

    public func rankings(
        query: String,
        queryClass: QueryClass,
        policy: AdmissionPolicy,
        limit: Int = 12
    ) async throws -> LegRankings {
        let perLeg = tuning.candidatesPerLeg
        let match = HybridSearch.ftsQuery(from: query)
        let lexical = try await store.lexicalChunks(match: match, limit: perLeg)

        var dense: [ChunkCandidate] = []
        var denseUnavailable: String?
        if let embedder {
            let embedded = try await store.embeddedChunkCount(model: embedder.modelIdentifier)
            if embedded == 0 {
                denseUnavailable = "no chunk has a vector; run `opencore embed`"
            } else {
                let vector = try await embedder.embed(query)
                if vector.isEmpty {
                    denseUnavailable = "query produced no embedding"
                } else {
                    dense = try await store.denseChunks(query: vector, model: embedder.modelIdentifier, limit: perLeg)
                    let total = try await store.chunkCount()
                    if embedded < total {
                        denseUnavailable = "\(embedded) of \(total) chunks embedded"
                    }
                }
            }
        } else {
            denseUnavailable = "no embedding provider configured"
        }

        // The domain firewall runs before ranking everywhere else, so it runs here too.
        // Measuring a leg over passages the pipeline would never admit would flatter it.
        func objects(_ candidates: [ChunkCandidate]) -> [ObjectID] {
            var seen = Set<ObjectID>()
            var ordered: [ObjectID] = []
            for candidate in candidates where policy.admits(candidate.object.domain) {
                if seen.insert(candidate.object.id).inserted { ordered.append(candidate.object.id) }
            }
            return ordered
        }

        // Ask for more chunks than the caller wants objects, because several chunks can
        // belong to one object and would otherwise collapse into fewer than `limit` distinct
        // answers. Without this the fused list is scored on fewer object slots than each leg
        // gets, and fusion is charged for a deficit the harness created.
        let outcome = try await search(
            query: query, queryClass: queryClass, policy: policy,
            limit: limit * 3, expandContext: false
        )
        var seenFused = Set<ObjectID>()
        let fused = outcome.hits.map(\.object.id).filter { seenFused.insert($0).inserted }

        return LegRankings(
            lexical: objects(lexical),
            dense: objects(dense),
            fused: fused,
            denseUnavailable: denseUnavailable
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

        let pool = Array(hits.prefix(limit * 2))
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
