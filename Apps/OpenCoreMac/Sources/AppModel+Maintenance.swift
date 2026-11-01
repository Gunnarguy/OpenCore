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

    /// Rebuild a copy of the store and report the difference. Writes nothing to the store.
    ///
    /// In the sync lane, like applying one: a scheduled sync now writes on its own, and the copy
    /// a rehearsal reports on should not be moving underneath it.
    func rehearseRebuild() async -> RebuildReport? {
        guard let store else { return nil }
        return await exclusively("Rebuild rehearsal", refused: { _ in nil }) {
            do {
                state = .working("rehearsing a rebuild on a copy")
                let directory = RebuildRehearsal.defaultDirectory()
                let report = try await RebuildRehearsal(store: store, chunker: settings.chunker)
                    .rehearse(in: directory) { [weak self] message in
                        Task { @MainActor in self?.state = .working(message) }
                    }
                state = .idle
                return report
            } catch {
                state = .failed("rebuild rehearsal: \(error)")
                return nil
            }
        }
    }

    /// Apply a rehearsal someone has read. One transaction, so a running `opencore mcp` sees
    /// the old graph or the new one and never a half-empty one.
    func applyRehearsal(_ report: RebuildReport) async -> RebuildApplyOutcome? {
        guard let store else { return nil }
        return await exclusively("Applying a rebuild", refused: { _ in nil }) {
            do {
                state = .working("applying the reviewed rebuild")
                let outcome = try await RebuildRehearsal(store: store, chunker: settings.chunker).apply(report)

                // Cleared here and not earlier: "your passages do not match your chunking settings"
                // is only false once the new passages actually exist in the store.
                settings.chunkingDirty = false

                // Only passages whose text changed still need a vector, so this is usually quick.
                await buildEmbeddings()
                await refresh()
                state = .idle
                return outcome
            } catch {
                state = .failed("applying rebuild: \(error.localizedDescription)")
                return nil
            }
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
