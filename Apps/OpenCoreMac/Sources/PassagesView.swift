import CoreModel
import CoreSearch
import SwiftUI

/// Passage retrieval with its mechanics on the surface.
///
/// `Ask` answers a question. This shows how the evidence behind an answer is found: two
/// independent retrievers, fused by rank, then diversified. Every count, timing and missing
/// signal is on screen because a retrieval stack you cannot inspect is a retrieval stack
/// you have to trust, and this project's whole claim is that you should not have to.
struct PassagesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var result: AppModel.PassageResult?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .navigationTitle("Passages")
        .task { await model.refresh() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the passages themselves", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit { run() }
            if case .working = model.state { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PassagesUnavailablePanel(signals: result.outcome.unavailableSignals)
                    PassagesDiagnostics(result: result)
                    PassagesHitList(rows: result.rows)
                }
                .padding(24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            PassagesEmptyState()
        }
    }

    private func run() {
        let text = query
        Task { result = await model.searchPassages(text) }
    }
}

// MARK: - Empty state

private struct PassagesEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Two retrievers run, and you get to see both.")
                .font(.headline)
            Text("BM25 finds the words. Vectors find the meaning. Their ranks are fused, never their scores, because a bm25 number and a cosine number are not on the same scale.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Missing signals

/// Signals that did not run, and why.
///
/// Placed above the numbers rather than below them: a diagnostics panel reporting zero
/// dense candidates is not informative until you know whether the leg ran and found
/// nothing or never ran at all.
private struct PassagesUnavailablePanel: View {
    @Environment(AppModel.self) private var model
    let signals: [String: String]

    private struct SignalRow: Identifiable {
        let id: String
        let reason: String
    }

    private var rows: [SignalRow] {
        signals.sorted { $0.key < $1.key }.map { SignalRow(id: $0.key, reason: $0.value) }
    }

    /// Nothing is embedded yet, which the user can fix from here. A provider that failed to
    /// construct at all cannot be fixed by embedding, so that case gets the reason only.
    private var canBuild: Bool {
        model.chunkCount > 0 && (signals["semantic"] != nil || signals["semantic-coverage"] != nil)
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("This search did not use every signal", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))

                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.id).font(.caption.monospaced())
                        Text(row.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if canBuild {
                    Button("Build embeddings") { Task { await model.buildEmbeddings() } }
                        .controlSize(.small)
                        .disabled(isWorking)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 10))
        }
    }
}

// MARK: - Diagnostics

private struct PassagesDiagnostics: View {
    let result: AppModel.PassageResult

    private var outcome: PassageOutcome { result.outcome }

    /// Zero dense candidates because the leg never ran is not a measurement of zero.
    private var denseCandidates: String? {
        result.denseLegRan ? "\(outcome.denseCandidates)" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MetricPill(label: "class", value: result.queryClass)
                MetricPill(label: "chunks searched", value: "\(outcome.chunksSearched)")
                MetricPill(label: "hits", value: "\(outcome.hits.count)")
            }

            Divider()

            PassagesLegCounts(outcome: outcome, denseCandidates: denseCandidates)

            Divider()

            PassagesStageTimings(stages: result.stages)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private struct PassagesLegCounts: View {
    let outcome: PassageOutcome
    let denseCandidates: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PassagesStatRow(label: "lexical candidates", value: "\(outcome.lexicalCandidates)")
            PassagesStatRow(label: "dense candidates", value: denseCandidates)
            PassagesStatRow(label: "fused total", value: "\(outcome.afterFusion)")
            PassagesStatRow(label: "blocked by domain", value: "\(outcome.blockedByDomain)")
            PassagesStatRow(label: "dropped by MMR", value: "\(outcome.droppedByDiversity)")
        }
    }
}

private struct PassagesStageTimings: View {
    let stages: [AppModel.PassageResult.Stage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("stage timings").font(.caption).foregroundStyle(.tertiary)
            ForEach(stages) { stage in
                PassagesStatRow(label: stage.id, value: stage.milliseconds.map { "\($0)ms" })
            }
        }
    }
}

/// A nil value is a value that was never measured, and it says so rather than showing a
/// zero that looks like a reading.
private struct PassagesStatRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.tertiary)
                .frame(width: 150, alignment: .leading)
            valueText
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var valueText: some View {
        if let value {
            Text(value).foregroundStyle(.secondary).monospaced()
        } else {
            Text("not measured").foregroundStyle(.tertiary).italic()
        }
    }
}

// MARK: - Hits

private struct PassagesHitList: View {
    let rows: [AppModel.PassageRow]

    var body: some View {
        if rows.isEmpty {
            Text("No passage matched. Lexical retrieval needs a shared word, so a query with none of the corpus's vocabulary depends entirely on the dense leg.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    PassagesHitCard(row: row)
                }
            }
        }
    }
}

private struct PassagesHitCard: View {
    let row: AppModel.PassageRow
    @State private var showingContext = false

    private var contextLabel: String {
        showingContext ? "Hide context" : "Show \(row.neighbourCount) neighbouring passages"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PassagesLegRanks(legs: row.legs)

            Text(row.text)
                .font(.callout)
                .lineLimit(6)

            HStack(spacing: 10) {
                ScoreBar(value: row.relativeScore)
                Text(String(format: "%.4f", row.score))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("\(row.title) · \(row.kind) · \(row.authority)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if row.neighbourCount > 0 {
                Button(contextLabel) { showingContext.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)

                if showingContext {
                    PassagesContext(passages: row.context)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

/// The per-leg ranks, and the reason to build this view at all.
///
/// Two badges mean two independent retrievers both surfaced this passage, which is the case
/// Reciprocal Rank Fusion exists for. One badge names the retriever that carried it alone,
/// and that is usually the more interesting number of the two.
private struct PassagesLegRanks: View {
    let legs: [AppModel.PassageRow.Leg]

    var body: some View {
        HStack(spacing: 6) {
            if legs.isEmpty {
                Text("no leg reported a rank")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(legs) { leg in
                    PassagesLegBadge(leg: leg)
                }
                if legs.count > 1 {
                    Text("found by both legs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PassagesLegBadge: View {
    let leg: AppModel.PassageRow.Leg

    /// Precomputed rather than inlined: a ternary producing a `ShapeStyle` inside a card
    /// inside a `ForEach` inside a `LazyVStack` is the shape that blows the type checker.
    private var tint: Color { leg.id == "dense" ? .purple : Color.accentColor }

    var body: some View {
        HStack(spacing: 3) {
            Text(leg.id)
            Text("#\(leg.rank)").monospaced()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

// MARK: - Context

private struct PassagesContext: View {
    let passages: [AppModel.PassageRow.ContextPassage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(passages) { passage in
                PassagesContextLine(passage: passage)
            }
        }
        .padding(.top, 2)
    }
}

private struct PassagesContextLine: View {
    let passage: AppModel.PassageRow.ContextPassage

    private var textColor: Color { passage.isHit ? .primary : .secondary }
    private var markColor: Color { passage.isHit ? Color.accentColor : .clear }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(markColor)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("passage \(passage.ordinal)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(passage.text)
                    .font(.caption)
                    .foregroundStyle(textColor)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
