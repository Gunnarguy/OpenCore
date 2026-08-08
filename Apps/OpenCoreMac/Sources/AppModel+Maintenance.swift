import CoreGraph
import CoreIngest
import CoreModel
import CoreStore
import Foundation

/// The app half of `opencore doctor` and `opencore rebuild`.
///
/// These return their results rather than publishing them, because an extension cannot add
/// stored properties to `AppModel` and `MaintenanceView` is the only thing that reads them.
/// Errors still land in `state`, the same as every other model action.
extension AppModel {
    /// The countable shape of the derived graph.
    ///
    /// `Equatable` is the whole point. Objects are the floor, so re-deriving from them must
    /// leave this identical. A difference is a defect, not a new reading.
    struct GraphCounts: Equatable, Sendable {
        var objects = 0
        var chunks = 0
        var entities = 0
        var claims = 0
        var beliefs = 0
        var contradictions = 0
        var unresolvedContradictions = 0

        /// Declaration order is display order in both the diagnostics grid and the
        /// before/after comparison, so the two can never disagree about what a row means.
        var labelled: [CountRow] {
            [
                CountRow(label: "objects", value: objects),
                CountRow(label: "passages", value: chunks),
                CountRow(label: "entities", value: entities),
                CountRow(label: "claims", value: claims),
                CountRow(label: "beliefs", value: beliefs),
                CountRow(label: "contradictions", value: contradictions),
                CountRow(label: "unresolved contradictions", value: unresolvedContradictions),
            ]
        }
    }

    struct CountRow: Identifiable, Sendable {
        let label: String
        let value: Int
        var id: String { label }
    }

    struct KindCount: Identifiable, Sendable {
        let kind: ObjectKind
        let count: Int
        var id: String { kind.rawValue }
    }

    /// Coverage for one embedding model. `recorded` is what the run wrote down and `vectors`
    /// is what is actually on disk; they disagree when a run was interrupted, and the
    /// smaller of the two is the one dense retrieval can actually see.
    struct EmbeddingCoverage: Identifiable, Sendable {
        let model: String
        let dimensions: Int
        let recorded: Int
        let vectors: Int
        let finished: Bool
        var id: String { model }
    }

    struct Diagnostics: Sendable {
        let databasePath: String
        /// nil when the file size could not be read. Never substitute a zero: a size we
        /// failed to measure and a store that is empty are different facts.
        let databaseBytes: Int64?
        let counts: GraphCounts
        let kinds: [KindCount]
        let embeddings: [EmbeddingCoverage]
        let sources: [Source]
        let hasGitHubToken: Bool
    }

    struct CountComparison: Identifiable, Sendable {
        let label: String
        let before: Int
        let after: Int
        var id: String { label }
        var matches: Bool { before == after }
        var delta: Int { after - before }
    }

    struct RebuildComparison: Sendable {
        let before: GraphCounts
        let after: GraphCounts
        let outcome: IngestPipeline.Outcome

        /// Load-bearing. If this is false, something above the objects was holding the only
        /// copy of something, which is the one thing this system promises cannot happen.
        var reproducedExactly: Bool { before == after }

        var rows: [CountComparison] {
            let beforeRows = before.labelled
            let afterRows = after.labelled
            return beforeRows.indices.map { index in
                CountComparison(
                    label: beforeRows[index].label,
                    before: beforeRows[index].value,
                    after: afterRows[index].value
                )
            }
        }
    }

    // MARK: - Diagnostics

    /// Everything `opencore doctor` prints, gathered in one pass.
    func loadDiagnostics() async -> Diagnostics? {
        guard let store else { return nil }
        do {
            let databaseURL = await store.database.path

            var embeddings: [EmbeddingCoverage] = []
            for run in try await store.embeddingRuns() {
                embeddings.append(EmbeddingCoverage(
                    model: run.model,
                    dimensions: run.dimensions,
                    recorded: run.chunksDone,
                    vectors: try await store.embeddedChunkCount(model: run.model),
                    finished: run.finished
                ))
            }

            return Diagnostics(
                databasePath: databaseURL.path,
                databaseBytes: bytesOnDisk(for: databaseURL),
                counts: try await graphCounts(in: store),
                kinds: try await store.objectCountsByKind().map { KindCount(kind: $0.0, count: $0.1) },
                embeddings: embeddings,
                sources: try await store.sources(),
                hasGitHubToken: GitHubConnector.resolveToken() != nil
            )
        } catch {
            state = .failed("\(error)")
            return nil
        }
    }

    // MARK: - Rebuild

    /// Drop every derived layer and re-derive it from the stored objects.
    ///
    /// Mirrors `opencore rebuild` statement for statement, including the table list and the
    /// page size, so the app and the CLI cannot disagree about what "rebuild" means. The
    /// before and after counts come back together because reproducing the graph exactly is
    /// the invariant being tested, and a rebuild that quietly changes the numbers is a bug
    /// the user needs to see rather than a result to accept.
    func runRebuild() async -> RebuildComparison? {
        guard let store else { return nil }
        do {
            state = .working("counting the graph")
            let before = try await graphCounts(in: store)

            // Vectors go too: a vector describes chunk text, and a chunk whose boundaries
            // moved has a vector for text that no longer exists. Re-embed afterwards.
            //
            // The SQL is here rather than in `CoreStore` because the CLI's rebuild writes it
            // inline as well, and one copy drifting from the other is worse than either
            // being in the wrong module.
            state = .working("dropping derived layers")
            for table in ["claim", "evidence", "contradiction", "belief", "event", "edge", "chunk_vector", "chunk", "embedding_run"] {
                try await store.database.execute("DELETE FROM \(table)")
            }

            state = .working("loading objects")
            var offset = 0
            var all: [CoreObject] = []
            while true {
                let rows = try await store.database.query("SELECT id FROM object LIMIT 500 OFFSET ?", [.integer(Int64(offset))])
                if rows.isEmpty { break }
                all.append(contentsOf: try await store.objects(ids: rows.map { ObjectID($0.requireString("id")) }))
                offset += 500
            }

            state = .working("re-deriving from \(all.count) objects")
            let outcome = try await IngestPipeline(store: store).run(objects: all, storeObjects: false) { [weak self] message in
                Task { @MainActor in self?.state = .working(message) }
            }

            let after = try await graphCounts(in: store)
            await refresh()
            state = .idle
            return RebuildComparison(before: before, after: after, outcome: outcome)
        } catch {
            state = .failed("rebuild: \(error)")
            return nil
        }
    }

    // MARK: - Measuring

    private func graphCounts(in store: Store) async throws -> GraphCounts {
        var counts = GraphCounts()
        counts.objects = try await store.objectCount()
        counts.chunks = try await store.chunkCount()
        counts.entities = try await store.entities().count
        counts.claims = try await store.claimCount()
        counts.beliefs = try await store.beliefsDecided(since: .distantPast).count

        let contradictions = try await store.contradictions()
        counts.contradictions = contradictions.count
        counts.unresolvedContradictions = contradictions.filter { $0.resolution == .unresolved }.count
        return counts
    }

    /// The write-ahead log and shared-memory sidecars are part of the store on disk, so a
    /// size that ignored them would understate it by whatever has not been checkpointed.
    private func bytesOnDisk(for url: URL) -> Int64? {
        var total: Int64 = 0
        var measured = false
        for suffix in ["", "-wal", "-shm"] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix),
                  let size = attributes[.size] as? NSNumber
            else { continue }
            total += size.int64Value
            measured = true
        }
        return measured ? total : nil
    }
}
