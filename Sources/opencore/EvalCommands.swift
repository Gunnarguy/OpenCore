import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation

/// `opencore eval` — the first measurement of retrieval quality in this project.
///
/// Every retrieval constant in the repository is chosen rather than measured, and each one
/// carries a comment saying so. This is the thing that lets those comments be replaced with
/// numbers, and until it has run, no accuracy claim anywhere in `Docs/` may be upgraded.
///
/// **Reported per leg, not as one number.** Lexical alone, dense alone, then fused. A single
/// fused score cannot answer the question that actually matters first: whether the dense leg
/// earns its cost on this corpus, or whether RRF is carrying a passenger and BM25 is doing
/// the work.
///
/// **Scored by object, not by chunk.** Chunk boundaries are themselves a tuned parameter, so
/// a benchmark keyed to chunk ids would be invalidated by the change it exists to evaluate.
enum Eval {
    struct Case: Decodable {
        let id: String
        let category: String
        let question: String
        /// Object titles, not ids. See `Store.objectIDs(title:)` for why.
        let relevant: [String]
        let note: String?
    }

    /// One leg's performance over the whole benchmark.
    struct Score {
        var recallAt1 = 0.0
        var recallAt3 = 0.0
        var recallAtK = 0.0
        var mrr = 0.0
        var ndcg = 0.0
        var casesFullyMissed = 0
    }

    // MARK: - Metrics

    /// Fraction of the relevant set found in the top `k`.
    ///
    /// Recall rather than precision because the question is whether the evidence reached the
    /// model at all. A passage ranked 4th of 6 is still in the answer's context; a passage
    /// ranked 40th does not exist as far as the reader is concerned.
    static func recall(_ ranked: [ObjectID], _ relevant: Set<ObjectID>, k: Int) -> Double {
        guard !relevant.isEmpty else { return 0 }
        let found = Set(ranked.prefix(k)).intersection(relevant)
        return Double(found.count) / Double(relevant.count)
    }

    /// Reciprocal rank of the first relevant object. 0 when none is retrieved at all.
    static func reciprocalRank(_ ranked: [ObjectID], _ relevant: Set<ObjectID>) -> Double {
        for (index, id) in ranked.enumerated() where relevant.contains(id) {
            return 1.0 / Double(index + 1)
        }
        return 0
    }

    /// nDCG with binary gains.
    ///
    /// Binary rather than graded because no graded judgements exist. Inventing a 0-3 scale by
    /// eye would be a measurement resting on the same intuition this harness exists to replace.
    static func ndcg(_ ranked: [ObjectID], _ relevant: Set<ObjectID>, k: Int) -> Double {
        var dcg = 0.0
        for (index, id) in ranked.prefix(k).enumerated() where relevant.contains(id) {
            dcg += 1.0 / log2(Double(index + 2))
        }
        var ideal = 0.0
        for index in 0..<min(k, relevant.count) {
            ideal += 1.0 / log2(Double(index + 2))
        }
        return ideal == 0 ? 0 : dcg / ideal
    }

    // MARK: - Running

    static func run() async throws {
        let path = option("file") ?? "Benchmarks/rag_eval_v1.jsonl"
        let k = option("k").flatMap(Int.init) ?? Conversation.sourceCount

        let url = URL(fileURLWithPath: path)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            print("cannot read \(path)")
            exit(1)
        }
        let decoder = JSONDecoder()
        let cases: [Case] = try raw
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(Case.self, from: Data($0.utf8)) }

        let store = try await openStore()
        let provider = embedder()

        // Overridable so a change can be measured against the shipped default in one command
        // rather than by editing a constant, rebuilding, and trusting memory of the last run.
        var tuning = RetrievalTuning.default
        if let value = option("rrf-k").flatMap(Double.init) { tuning.rrfK = value }
        if let value = option("mmr-lambda").flatMap(Double.init) { tuning.mmrLambda = value }
        if let value = option("candidates").flatMap(Int.init) { tuning.candidatesPerLeg = value }
        if let value = option("signal-scale").flatMap(Double.init) { tuning.signalScale = value }
        if let value = option("lexical-weight").flatMap(Double.init) { tuning.lexicalWeight = value }
        if let value = option("dense-weight").flatMap(Double.init) { tuning.denseWeight = value }
        let search = PassageSearch(store: store, embedder: provider, tuning: tuning)

        // The dense leg being empty produces a plausible-looking zero rather than an error,
        // and a zero here would be read as "dense retrieval does not work on this corpus".
        // Say which it is before any number is printed.
        let chunks = try await store.chunkCount()
        let embedded = provider == nil ? 0 : try await store.embeddedChunkCount(model: provider!.modelIdentifier)
        print("corpus       \(try await store.objectCount()) objects, \(chunks) chunks")
        print("vectors      \(embedded)/\(chunks) chunks embedded" + (embedded == 0 ? "  <- DENSE LEG IS EMPTY" : ""))
        print("cases        \(cases.count) from \(path)")
        print("k            \(k)")
        print("tuning       rrfK \(tuning.rrfK), mmrLambda \(tuning.mmrLambda), candidatesPerLeg \(tuning.candidatesPerLeg), signalScale \(tuning.signalScale)")
        print("leg weights  lexical \(tuning.lexicalWeight), dense \(tuning.denseWeight)"
            + (tuning == .default ? "" : "   <- NOT the shipped default"))
        print("")

        var lexical = Score(), dense = Score(), fused = Score()
        var unresolved: [String] = []
        var perCase: [(Case, Double, Double, Double)] = []

        for testCase in cases {
            // Resolve expected titles to ids. A title that matches nothing is a broken
            // benchmark row, not a retrieval failure, and must never be scored as one.
            var relevant = Set<ObjectID>()
            for title in testCase.relevant {
                let ids = try await store.objectIDs(title: title)
                if ids.isEmpty { unresolved.append("\(testCase.id): no object titled '\(title)'") }
                relevant.formUnion(ids)
            }
            guard !relevant.isEmpty else { continue }

            let classification = QueryClassifier().classify(testCase.question)
            let (domain, requested) = AdmissionPolicy.classifyDomain(
                testCase.question,
                knownEntitySurfaces: try await store.aliasSurfaces()
            )
            let rankings = try await search.rankings(
                query: testCase.question,
                queryClass: classification.queryClass,
                policy: AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested),
                limit: k
            )

            func accumulate(_ ranked: [ObjectID], into score: inout Score) -> Double {
                let atK = recall(ranked, relevant, k: k)
                score.recallAt1 += recall(ranked, relevant, k: 1)
                score.recallAt3 += recall(ranked, relevant, k: 3)
                score.recallAtK += atK
                score.mrr += reciprocalRank(ranked, relevant)
                score.ndcg += ndcg(ranked, relevant, k: k)
                if atK == 0 { score.casesFullyMissed += 1 }
                return atK
            }

            let l = accumulate(rankings.lexical, into: &lexical)
            let d = accumulate(rankings.dense, into: &dense)
            let f = accumulate(rankings.fused, into: &fused)
            perCase.append((testCase, l, d, f))
        }

        let n = Double(perCase.count)
        guard n > 0 else {
            print("no scoreable cases. Every expected title failed to resolve:")
            unresolved.forEach { print("  \($0)") }
            exit(1)
        }

        func row(_ name: String, _ score: Score) -> String {
            func pct(_ value: Double) -> String { String(format: "%5.1f%%", value / n * 100) }
            return "  \(name.padding(toLength: 9, withPad: " ", startingAt: 0))"
                + "\(pct(score.recallAt1))  \(pct(score.recallAt3))  \(pct(score.recallAtK))"
                + "   \(String(format: "%.3f", score.mrr / n))  \(String(format: "%.3f", score.ndcg / n))"
                + "   \(score.casesFullyMissed)"
        }

        print("             recall@1 recall@3 recall@\(k)     MRR   nDCG@\(k)   missed")
        print(row("lexical", lexical))
        print(row("dense", dense))
        print(row("fused", fused))

        if flag("verbose") {
            print("\nper case (recall@\(k): lexical / dense / fused)")
            for (testCase, l, d, f) in perCase {
                let flagged = f == 0 ? " <- FUSED MISS" : ""
                print("  \(testCase.id) \(testCase.category.padding(toLength: 14, withPad: " ", startingAt: 0))"
                    + "\(String(format: "%.2f", l)) / \(String(format: "%.2f", d)) / \(String(format: "%.2f", f))\(flagged)")
                print("       \(testCase.question)")
            }
        }

        if !unresolved.isEmpty {
            print("\n! \(unresolved.count) expected title(s) matched no object. Benchmark rows, not retrieval failures:")
            unresolved.forEach { print("    \($0)") }
        }

        // The comparison the harness was built to make.
        print("")
        let lexicalNDCG = lexical.ndcg / n, denseNDCG = dense.ndcg / n, fusedNDCG = fused.ndcg / n
        // A leg beating the fusion is not "fusion did not help". It means combining two
        // retrievers is destroying information one of them had, which is a different and
        // worse finding, and the wording has to keep them apart.
        let bestLeg = max(lexicalNDCG, denseNDCG)
        if denseNDCG == 0 {
            print("dense contributed nothing. Check the vector coverage line above before reading anything into that.")
        } else if fusedNDCG > bestLeg {
            print(String(format: "fusion beats both legs (%.3f vs lexical %.3f, dense %.3f). RRF is earning its place.", fusedNDCG, lexicalNDCG, denseNDCG))
        } else if fusedNDCG < bestLeg {
            let name = lexicalNDCG >= denseNDCG ? "lexical" : "dense"
            print(String(format: "FUSION IS DESTRUCTIVE: %@ alone scores %.3f, fused scores %.3f.", name, bestLeg, fusedNDCG))
            print("Combining the legs is losing information one of them already had. That is a")
            print("defect in how they are combined, not a tuning gap. Fix it before sweeping constants.")
        } else {
            print(String(format: "fusion matches its best leg (%.3f). It is currently costing a second retriever for nothing.", fusedNDCG))
        }
        print("Single corpus, \(perCase.count) hand-written cases, binary judgements. Directional, not an accuracy claim.")
    }
}
