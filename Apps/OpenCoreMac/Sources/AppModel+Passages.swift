import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation

// MARK: - Passage retrieval

extension AppModel {
    /// Everything one passage search produced.
    ///
    /// This is returned rather than stored on `AppModel` because `@Observable` publishes
    /// stored properties and Swift cannot add a stored property from an extension. The
    /// engine's own `PassageOutcome` travels inside untouched, so the view reports what
    /// retrieval actually did instead of a summary written on top of it.
    struct PassageResult: Sendable {
        let query: String
        let queryClass: String
        /// Set when the query named a stretch of time and the rows were filtered to it. A view
        /// showing these rows has to show this too: a date filter is the one thing here that
        /// removes evidence, and undated objects fall out with everything else.
        let report: WindowReport?
        let outcome: PassageOutcome
        let rows: [PassageRow]
        /// Whether the dense leg actually executed. Without this, a dense candidate count
        /// of zero reads identically to a leg that never ran, and those are not the same
        /// result.
        let denseLegRan: Bool
        /// Pipeline order, with a stage the engine did not time carried as nil rather than
        /// as zero milliseconds.
        let stages: [Stage]

        struct Stage: Identifiable, Sendable {
            let id: String
            let milliseconds: Int?
        }
    }

    /// One retrieved passage, flattened for display.
    ///
    /// `legs` is why this exists. A passage the dense leg ranked third and the lexical leg
    /// ranked fifty-seventh is the case neither retriever handles alone, and until that
    /// pair of numbers is on screen, fusion is something you take on faith.
    struct PassageRow: Identifiable, Sendable {
        let id: ChunkID
        let objectID: ObjectID
        let title: String
        let kind: String
        let authority: String
        let text: String
        let score: Double
        /// Score as a fraction of the top hit. RRF totals sit around 0.03 in absolute
        /// terms, so a bar drawn against 1.0 would render every result as empty.
        let relativeScore: Double
        let legs: [Leg]
        let context: [ContextPassage]

        var neighbourCount: Int { context.filter { !$0.isHit }.count }

        struct Leg: Identifiable, Sendable {
            /// The leg's name is its identity: "lexical" or "dense".
            let id: String
            let rank: Int
        }

        struct ContextPassage: Identifiable, Sendable {
            let id: ChunkID
            let ordinal: Int
            let text: String
            let isHit: Bool
        }
    }

    /// Passage retrieval: BM25 and dense vectors run independently, fused by rank, then
    /// diversified by MMR.
    ///
    /// Deliberately the same sequence, in the same order, with the same classifier and the
    /// same policy as `opencore passages`. The app and the CLI read one store and must not
    /// disagree about what it contains.
    ///
    /// - Parameter readingTime: false when `query` is a name and not a question. A project called
    ///   "Last Week" is not a filter on its own dossier.
    func searchPassages(_ query: String, readingTime: Bool = true) async -> PassageResult? {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        state = .working("retrieving passages")
        do {
            let surfaces = try await store.aliasSurfaces()
            let (domain, requested) = AdmissionPolicy.classifyDomain(query, knownEntitySurfaces: surfaces)
            let policy = AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested)
            let classification = QueryClassifier().classify(query)

            // A search that ran without its dense leg is a different search, not a slightly
            // worse one, so the reason travels with the result rather than being swallowed
            // into a silently lexical-only answer.
            let provider: (any EmbeddingProvider)?
            let providerFailure: String?
            do {
                provider = try NLEmbeddingProvider()
                providerFailure = nil
            } catch {
                provider = nil
                providerFailure = "\(error)"
            }

            // Home and Quick Jump hand this the question they just sent to `ask`, then write a
            // model summary over whatever comes back. Searching all of time here put a passage
            // from any year under an answer that said it read one week. The Passages screen
            // reads the same way, as `core_search` and `opencore passages` do, so every caller
            // gets the report with the rows.
            let window = readingTime ? TemporalIntent.window(in: query) : nil
            let searchText = window?.searchText ?? query
            var report: WindowReport?
            if let window {
                report = try await store.windowReport(window, domains: policy.admitted, calendar: .current)
            }

            var outcome = try await PassageSearch(store: store, embedder: provider, tuning: settings.tuning).search(
                query: searchText,
                queryClass: classification.queryClass,
                policy: policy,
                // Both were hardcoded here while Settings offered controls for them. "Results"
                // and "Expand hits into neighbouring passages" saved to disk, survived a
                // relaunch, and changed nothing: `search` has taken both parameters all along
                // and this call site passed neither. A setting that persists a preference it
                // never applies is worse than no setting, because the screen keeps confirming
                // it back to you.
                //
                // The default remains 8, matching `opencore passages`, chosen to fit a reading
                // column rather than measured against any recall target.
                limit: settings.passageLimit,
                expandContext: settings.expandContext,
                window: window?.interval
            )
            if let providerFailure {
                // Folded into the engine's own channel so the view has one place to render
                // every reason a signal is missing.
                outcome.unavailableSignals["embedding-provider"] = providerFailure
            }

            state = .idle
            return PassageResult(
                query: query,
                queryClass: classification.queryClass.rawValue,
                report: report,
                outcome: outcome,
                rows: Self.passageRows(from: outcome),
                denseLegRan: outcome.denseLegRan,
                stages: Self.passageStages(from: outcome.stageTimings)
            )
        } catch {
            state = .failed("passages: \(error)")
            return nil
        }
    }

    private static func passageRows(from outcome: PassageOutcome) -> [PassageRow] {
        let top = outcome.hits.first?.score ?? 0
        return outcome.hits.map { hit in
            PassageRow(
                id: hit.chunk.id,
                objectID: hit.object.id,
                title: hit.object.title,
                kind: hit.object.kind.rawValue,
                authority: hit.object.authority.label,
                text: hit.chunk.text.replacingOccurrences(of: "\n", with: " "),
                score: hit.score,
                relativeScore: top > 0 ? hit.score / top : 0,
                legs: hit.ranks.sorted { $0.key < $1.key }.map { PassageRow.Leg(id: $0.key, rank: $0.value) },
                context: hit.context.map { chunk in
                    PassageRow.ContextPassage(
                        id: chunk.id,
                        ordinal: chunk.ordinal,
                        text: chunk.text.replacingOccurrences(of: "\n", with: " "),
                        isHit: chunk.id == hit.chunk.id
                    )
                }
            )
        }
    }

    private static let passageStageOrder = ["lexical", "dense", "fuse", "mmr"]

    private static func passageStages(from timings: [String: Int]) -> [PassageResult.Stage] {
        // A stage the engine starts timing later still appears, rather than vanishing from
        // the one view whose whole job is to report what ran.
        let extra = timings.keys.filter { !passageStageOrder.contains($0) }.sorted()
        return (passageStageOrder + extra).map {
            PassageResult.Stage(id: $0, milliseconds: timings[$0])
        }
    }
}
