import CoreGraph
import CoreModel
import SwiftUI

/// What is on disk, and the one operation that rebuilds everything above it.
///
/// The rebuild is presented as a claim being tested rather than a maintenance chore: it must
/// return the same counts it started with, and this screen exists partly so that a failure of
/// that invariant is impossible to miss.
struct MaintenanceView: View {
    @Environment(AppModel.self) private var model
    @State private var diagnostics: AppModel.Diagnostics?
    @State private var comparison: AppModel.RebuildComparison?
    @State private var confirmingRebuild = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let diagnostics {
                    MaintenanceStorePanel(diagnostics: diagnostics)
                    MaintenanceCountsPanel(counts: diagnostics.counts)
                    MaintenanceKindPanel(kinds: diagnostics.kinds)
                    MaintenanceEmbeddingPanel(coverage: diagnostics.embeddings, passages: diagnostics.counts.chunks)
                    MaintenanceSourcePanel(sources: diagnostics.sources)
                } else {
                    Text("No store open yet.").font(.callout).foregroundStyle(.secondary)
                }

                MaintenanceRebuildPanel(disabled: isWorking || diagnostics == nil) {
                    confirmingRebuild = true
                }

                if let comparison {
                    MaintenanceVerdictCard(reproducedExactly: comparison.reproducedExactly)
                    MaintenanceComparisonPanel(comparison: comparison)
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Maintenance")
        .task { diagnostics = await model.loadDiagnostics() }
        .confirmationDialog(
            "Re-derive every layer above your objects?",
            isPresented: $confirmingRebuild,
            titleVisibility: .visible
        ) {
            Button("Re-derive from objects", role: .destructive) { rebuild() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.confirmation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Maintenance").font(.title2.weight(.semibold))
            Text("What is stored, and how much of it can be reconstructed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Both counts are refreshed from the same store afterwards, so the panels above cannot
    /// keep showing pre-rebuild numbers beside a post-rebuild comparison.
    private func rebuild() {
        Task {
            comparison = nil
            comparison = await model.runRebuild()
            diagnostics = await model.loadDiagnostics()
        }
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }

    private static let confirmation = """
        Claims, evidence, contradictions, beliefs, events, edges, passages and vectors are all \
        deleted, then rebuilt from the objects already in the store.

        The objects themselves are never touched.

        Vectors go with the rest, so the semantic index has to be built again afterwards.
        """
}

// MARK: - Store

private struct MaintenanceStorePanel: View {
    let diagnostics: AppModel.Diagnostics

    private var size: String? {
        diagnostics.databaseBytes.map { $0.formatted(.byteCount(style: .file)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Store").font(.subheadline.weight(.semibold))

            Text(diagnostics.databasePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                maintenanceRow("size on disk", size)
                maintenanceRow("github token", diagnostics.hasGitHubToken ? "available" : "none")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Counts

private struct MaintenanceCountsPanel: View {
    let counts: AppModel.GraphCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Graph").font(.subheadline.weight(.semibold))
            Text("Objects are the floor. Every other row is derived from them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                ForEach(counts.labelled) { row in
                    maintenanceRow(row.label, "\(row.value)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private struct MaintenanceKindPanel: View {
    let kinds: [AppModel.KindCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Objects by kind").font(.subheadline.weight(.semibold))

            if kinds.isEmpty {
                Text("Nothing stored yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(kinds) { row in
                    HStack {
                        Text(row.kind.rawValue).font(.callout)
                        Spacer()
                        Text("\(row.count)").font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Embeddings

private struct MaintenanceEmbeddingPanel: View {
    let coverage: [AppModel.EmbeddingCoverage]
    let passages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Embedding coverage").font(.subheadline.weight(.semibold))

            if coverage.isEmpty {
                Label(
                    "No vectors stored. Retrieval runs on its lexical leg alone until the index is built.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                ForEach(coverage) { run in
                    MaintenanceEmbeddingRow(run: run, passages: passages)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private struct MaintenanceEmbeddingRow: View {
    let run: AppModel.EmbeddingCoverage
    let passages: Int

    /// Measured against vectors actually on disk rather than what the run recorded, because
    /// the stored vectors are what dense retrieval can reach.
    private var fraction: Double {
        passages > 0 ? Double(run.vectors) / Double(passages) : 0
    }

    private var isComplete: Bool { run.vectors >= passages }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.model).font(.caption.monospaced())
                Spacer()
                Text("\(run.dimensions) dimensions").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            ScoreBar(value: fraction)
            detail
            note
        }
    }

    @ViewBuilder private var detail: some View {
        if isComplete {
            Text("\(run.vectors) of \(passages) passages embedded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(run.vectors) of \(passages) passages embedded. Semantic search cannot see the rest.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var note: some View {
        if run.recorded != run.vectors {
            Text("the run recorded \(run.recorded), which does not match what is stored")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if !run.finished {
            Text("this run did not finish")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Sources

private struct MaintenanceSourcePanel: View {
    let sources: [Source]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last synced").font(.subheadline.weight(.semibold))

            if sources.isEmpty {
                Text("No sources connected.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    ForEach(sources) { source in
                        maintenanceRow(source.displayName, synced(source))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    /// "never synced" is a measured fact, not a missing measurement, so it is a value here
    /// rather than the dimmed unmeasured rendering.
    private func synced(_ source: Source) -> String {
        source.lastSyncedAt.map { ClaimsView.formatter.string(from: $0) } ?? "never synced"
    }
}

// MARK: - Rebuild

private struct MaintenanceRebuildPanel: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Re-derive from objects").font(.subheadline.weight(.semibold))

            Text("This deletes every derived layer: claims, evidence, contradictions, beliefs, events, edges, passages and their vectors. All of it is then rebuilt from the objects already in the store.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Your objects are never touched. They are the floor of this system, and nothing above them is the only copy of anything.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Vectors go with the rest, because a vector describes passage text and passage boundaries can move. Build the semantic index again on the Sources screen afterwards, or dense retrieval will see nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Rebuilding should reproduce the graph exactly. The counts before and after are compared here, and a difference is a bug rather than a result.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Re-derive from objects", role: .destructive, action: action)
                .disabled(disabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

/// The verdict gets its own card ahead of the numbers, because the numbers alone read as a
/// report when a mismatch is actually a defect.
private struct MaintenanceVerdictCard: View {
    let reproducedExactly: Bool

    var body: some View {
        if reproducedExactly { matched } else { mismatched }
    }

    private var matched: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Rebuild reproduced the graph exactly", systemImage: "checkmark.seal")
                .font(.subheadline.weight(.semibold))
            Text("Every derived layer came back with the count it had before, which is what it means for objects to be the floor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private var mismatched: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Rebuild did not reproduce the graph", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("This is a bug in the derivation pipeline, not a new set of numbers to accept.")
                .font(.callout.weight(.medium))
            Text("Objects are the floor of this system, so re-deriving from them has to reconstruct every layer exactly. A count that moved means either something above the objects held the only copy of something, or a derivation stage is not deterministic. The rows that changed are marked below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

private struct MaintenanceComparisonPanel: View {
    let comparison: AppModel.RebuildComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("before").foregroundStyle(.tertiary)
                    Text("after").foregroundStyle(.tertiary)
                    Text("")
                }
                .font(.caption2.weight(.semibold))

                ForEach(comparison.rows) { row in
                    maintenanceComparisonRow(row)
                }
            }

            Divider()
            MaintenancePipelineReport(outcome: comparison.outcome)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private struct MaintenancePipelineReport: View {
    let outcome: IngestPipeline.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("what the pipeline reported")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                maintenanceRow("passages", "\(outcome.chunks)")
                maintenanceRow("entities", "\(outcome.entities) resolved, \(outcome.aliases) aliases")
                maintenanceRow("claims", "\(outcome.claims) from \(outcome.evidence) evidence spans")
                maintenanceRow("events", "\(outcome.events)")
                maintenanceRow("beliefs", "\(outcome.beliefs) written")
                maintenanceRow("conflicts", "\(outcome.contradictions) found, \(outcome.contradictionsResolved) resolved, \(outcome.contradictionsOpen) open")
            }
        }
    }
}

// MARK: - Shared

/// A label and its value. `nil` renders as "not measured" rather than a zero, because a
/// number we failed to take and a number that is genuinely zero are different facts.
///
/// A free function rather than a `View` so it stays a `GridRow` the enclosing `Grid` can lay
/// out, which is the same reason `ReceiptCard` builds its rows this way.
private func maintenanceRow(_ label: String, _ value: String?) -> some View {
    GridRow {
        Text(label).foregroundStyle(.tertiary)
        if let value {
            Text(value).foregroundStyle(.secondary).monospaced()
        } else {
            Text("not measured").foregroundStyle(.tertiary).italic()
        }
    }
    .font(.caption)
}

private func maintenanceComparisonRow(_ row: AppModel.CountComparison) -> some View {
    let valueColor: Color = row.matches ? .secondary : .red
    let delta = row.delta > 0 ? "+\(row.delta)" : "\(row.delta)"

    return GridRow {
        Text(row.label).foregroundStyle(.tertiary)
        Text("\(row.before)").foregroundStyle(.secondary).monospaced()
        Text("\(row.after)").foregroundStyle(valueColor).monospaced()
        Text(row.matches ? "" : delta).foregroundStyle(Color.red).monospaced()
    }
    .font(.caption)
}
