import CoreModel
import CoreReason
import CoreSearch
import SwiftUI

/// Hybrid Search & Passage Explorer (full-width `maxWidth: 1440`): BM25 Keyword + 512-d Semantic Vector fusion inspector.
struct PassagesView: View {
    @Environment(\.appModel) private var model
    @State private var query = ""
    @State private var result: AppModel.PassageResult?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = UUID()
    @State private var activeSearchQuery: String?
    @State private var initializedQuery = false
    @State private var searchError: String?

    private let starterQueries = [
        "OpenCore",
        "STATE.md",
        "Swift",
        "Xcode",
        "Claude",
        "USB",
        "FoundationModels",
        "Architecture"
    ]

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            content
        }
        .navigationTitle("Passages")
        .task(id: model.dataGeneration) {
            if consumePendingQueryIfNeeded() { return }
            if !initializedQuery, model.chunkCount > 0 {
                initializedQuery = true
                query = "OpenCore"
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run()
            }
        }
        .onChange(of: query) { _, value in
            if activeSearchQuery != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                cancelSearch()
                result = nil
                searchError = nil
            }
        }
        .onChange(of: model.pendingPassageQuery) { _, _ in
            _ = consumePendingQueryIfNeeded()
        }
        .onDisappear { cancelSearch() }
    }

    @discardableResult
    private func consumePendingQueryIfNeeded() -> Bool {
        guard let pending = model.pendingPassageQuery, !pending.isEmpty else { return false }
        model.pendingPassageQuery = nil
        initializedQuery = true
        query = pending
        run()
        return true
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Pastel.mint)
                TextField("Search \(model.chunkCount) indexed passages (exact keywords + 512-d meaning)...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { run() }

                Button {
                    run()
                } label: {
                    Label("Run Hybrid Search", systemImage: "magnifyingglass")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.regular)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Run Hybrid Search")

                if !query.isEmpty {
                    Button {
                        cancelSearch()
                        initializedQuery = true
                        query = ""
                        result = nil
                        searchError = nil
                        ActionFeedbackCenter.shared.record(
                            button: "Clear Passage Search",
                            command: "PassagesView.query = \"\"",
                            outcome: "Cleared search input and reset Hybrid Search telemetry view.",
                            status: .completed
                        )
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(telemetryLabel: "Clear Passage Search")
                }

                if case .working = model.state { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 8) {
                Text("1-Click Sample Searches:")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(starterQueries, id: \.self) { sample in
                            let isCurrent = query.caseInsensitiveCompare(sample) == .orderedSame
                            Button {
                                query = sample
                                run()
                            } label: {
                                Text(sample)
                                    .font(.caption.weight(isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? Pastel.mint : .primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(isCurrent ? Pastel.mint.opacity(0.20) : Color.primary.opacity(0.05), in: .capsule)
                                    .overlay {
                                        Capsule().strokeBorder(isCurrent ? Pastel.mint : Color.primary.opacity(0.12), lineWidth: 0.8)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                Text("\(model.embeddedCount)/\(model.chunkCount) passages vectorized")
                    .font(.caption2.monospaced())
                    .foregroundStyle(model.embeddedCount >= model.chunkCount ? Pastel.mint : Pastel.peach)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Orientation Card
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("How OpenCore Hybrid Passage Search Works (No Black Box)", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                            .foregroundStyle(Pastel.sky)
                        Text("Every search runs two independent engines in parallel: (1) SQLite FTS5 BM25 for exact words & identifiers, and (2) Apple NLEmbedding 512-d vectors for conceptual meaning. Their ranks (#1, #2, #3...) are merged with Reciprocal Rank Fusion (RRF), checked against the Privacy Domain Firewall, and deduplicated via Maximal Marginal Relevance (MMR).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.embeddedCount < model.chunkCount {
                        Button {
                            Task { await model.buildEmbeddings() }
                        } label: {
                            Label("Build Missing Vectors (\(model.chunkCount - model.embeddedCount))", systemImage: "cpu")
                                .font(.caption.weight(.bold))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true, tint: Pastel.peach, telemetryLabel: "Build Missing Vectors")
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)

                if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Pastel.peach)
                }
                if let result {
                    if let report = result.report {
                        PassagesWindowPanel(report: report)
                    }
                    PassagesUnavailablePanel(signals: result.outcome.unavailableSignals)
                    PassagesDiagnostics(result: result)
                    PassagesHitList(rows: result.rows)
                } else {
                    PassagesEmptyState(onPickSample: { sample in
                        query = sample
                        run()
                    })
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchID = UUID()
        activeSearchQuery = nil
    }

    private func run() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()
        guard !text.isEmpty else { result = nil; return }
        initializedQuery = true
        let requestID = UUID()
        let generation = model.dataGeneration
        searchID = requestID
        activeSearchQuery = text
        searchError = nil
        searchTask = Task {
            let start = Date()
            ActionFeedbackCenter.shared.record(
                button: "Hybrid Passage Search: '\(text)'",
                command: "AppModel.searchPassages",
                outcome: "Searching \(model.chunkCount) passages for '\(text)'...",
                status: .running
            )
            let res = await model.searchPassages(text)
            // Regression: cancelled or older searches must not refill Clear or replace a newer query.
            guard !Task.isCancelled, searchID == requestID,
                  generation == model.dataGeneration,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            result = res
            searchTask = nil
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let res {
                ActionFeedbackCenter.shared.record(
                    button: "Hybrid Passage Search: '\(text)'",
                    command: "AppModel.searchPassages",
                    outcome: "Found \(res.rows.count) ranked passage(s) from \(res.outcome.chunksSearched) chunks searched in \(ms) ms.",
                    status: .completed,
                    durationMs: ms
                )
            } else {
                searchError = "Passage search could not finish. Try again after the store is ready."
                ActionFeedbackCenter.shared.record(
                    button: "Hybrid Passage Search: '\(text)'",
                    command: "AppModel.searchPassages",
                    outcome: searchError ?? "Search did not return a result.",
                    status: .warning,
                    durationMs: ms
                )
            }
        }
    }

}

// MARK: - Empty state

private struct PassagesEmptyState: View {
    let onPickSample: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(Pastel.mint)
            Text("Pick any sample query above or type a phrase to inspect Hybrid Retrieval")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(["OpenCore", "STATE.md", "Swift", "Xcode"], id: \.self) { sample in
                    Button("Try '\(sample)'") {
                        onPickSample(sample)
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Try Sample Search: \(sample)")
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
    }
}

// MARK: - Time window

/// What a date filter did to these results.
///
/// **The defect.** A query holding "today", "in 2025", "recently" or "in March" was filtered by
/// date here and the screen said nothing, so passages from other years and every undated object
/// vanished without a word. `core_search` and `opencore passages` both print these same lines.
private struct PassagesWindowPanel: View {
    let report: WindowReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Filtered to a stretch of time", systemImage: "calendar")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(report.behind.isEmpty ? Pastel.sky : Pastel.peach)
            ForEach(report.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("A passage with no date cannot be placed in a window, so it is left out here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: report.behind.isEmpty ? Pastel.sky : Pastel.peach)
    }
}

// MARK: - Missing signals

private struct PassagesUnavailablePanel: View {
    @Environment(\.appModel) private var model
    let signals: [String: String]

    private struct SignalRow: Identifiable {
        let id: String
        let reason: String
    }

    private var rows: [SignalRow] {
        signals.sorted { $0.key < $1.key }.map { SignalRow(id: $0.key, reason: $0.value) }
    }

    private var canBuild: Bool {
        model.chunkCount > 0 && (signals[PassageOutcome.Signal.semantic] != nil || signals[PassageOutcome.Signal.semanticCoverage] != nil)
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Retrieval Signal Notice", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Pastel.peach)
                    Spacer()
                    if canBuild {
                        Button("Build Semantic Vectors Now") {
                            Task { await model.buildEmbeddings() }
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true, tint: Pastel.peach, telemetryLabel: "Build Semantic Vectors")
                        .disabled(isWorking)
                    }
                }

                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.id)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(Pastel.butter)
                        Text(row.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.peach)
        }
    }
}

// MARK: - Diagnostics

private struct PassagesDiagnostics: View {
    let result: AppModel.PassageResult

    private var outcome: PassageOutcome { result.outcome }

    private var denseCandidates: String {
        result.denseLegRan ? "\(outcome.denseCandidates)" : "not run"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Hybrid Retrieval Telemetry & Funnel Breakdown", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.aqua)
                Spacer()
                HStack(spacing: 10) {
                    MetricPill(label: "queryClass", value: result.queryClass)
                    MetricPill(label: "paragraphs scanned", value: "\(outcome.chunksSearched)")
                    MetricPill(label: "returned hits", value: "\(outcome.hits.count)")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                funnelCard("1. Keyword Leg (BM25)", value: "\(outcome.lexicalCandidates) hits", subtitle: "SQLite FTS5 exact word matches", tint: Pastel.sky)
                funnelCard("2. Meaning Leg (512-d)", value: "\(denseCandidates) hits", subtitle: "Apple NLEmbedding cosine similarity", tint: Pastel.lavender)
                funnelCard("3. RRF Fused Union", value: "\(outcome.afterFusion) unique", subtitle: "Combined by reciprocal rank", tint: Pastel.mint)
                funnelCard("4. Firewall & MMR", value: "-\(outcome.blockedByDomain) priv / -\(outcome.droppedByDiversity) dup", subtitle: "Privacy & diversity filter", tint: Pastel.butter)
            }

            HStack(spacing: 12) {
                Text("Stage Timings:")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(result.stages) { stage in
                    HStack(spacing: 4) {
                        Text(stage.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(stage.milliseconds.map { "\($0) ms" } ?? "not measured")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(Pastel.mint)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: .capsule)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)
    }

    private func funnelCard(_ title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Hits

private struct PassagesHitList: View {
    let rows: [AppModel.PassageRow]

    var body: some View {
        if rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("No matching passages found for this query", systemImage: "magnifyingglass.circle")
                    .font(.headline)
                    .foregroundStyle(Pastel.butter)
                Text("Try one of the 1-Click Sample Searches at the top of the screen, or sync additional folders on the Sources tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.butter)
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
    @Environment(\.appModel) private var model
    let row: AppModel.PassageRow
    @State private var showingContext = false

    private var contextLabel: String {
        showingContext ? "Hide surrounding paragraphs" : "Show \(row.neighbourCount) surrounding paragraphs"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PassagesLegRanks(legs: row.legs)
                Spacer()
                Button {
                    model.askInChat("Tell me about \(row.title)")
                } label: {
                    Label("Ask in Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption2.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.lavender, telemetryLabel: "Ask in Chat: \(row.title)")

                Button {
                    model.inspectObject(row.objectID, highlight: row.text)
                } label: {
                    Label("Inspect original", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Inspect Source Document: \(row.title)")
            }

            HStack(spacing: 8) {
                Text(row.title)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.primary)
                Text(row.kind)
                    .openCorePastelBadge(Pastel.sky)
                Text(row.authority)
                    .openCorePastelBadge(Pastel.aqua)
                Spacer()
                Text(String(format: "RRF Fused Score: %.4f", row.score))
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Pastel.mint)
            }

            Text(row.text)
                .font(.callout)
                .foregroundStyle(Pastel.ice)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))

            ScoreBar(value: row.relativeScore)

            if row.neighbourCount > 0 {
                Button {
                    showingContext.toggle()
                    ActionFeedbackCenter.shared.record(
                        button: contextLabel,
                        command: "Toggle context passages for \(row.title)",
                        outcome: showingContext
                            ? "Expanded \(row.neighbourCount) neighbouring paragraph(s) from '\(row.title)'."
                            : "Collapsed neighbouring paragraphs for '\(row.title)'.",
                        status: .completed
                    )
                } label: {
                    Label(contextLabel, systemImage: showingContext ? "chevron.up.circle.fill" : "chevron.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.sky, telemetryLabel: contextLabel)

                if showingContext {
                    PassagesContext(passages: row.context)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: row.legs.count > 1 ? Pastel.mint : Pastel.sky)
    }
}

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
                    Text("MATCHED BY BOTH KEYWORD & MEANING")
                        .openCorePastelBadge(Pastel.mint)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PassagesLegBadge: View {
    let leg: AppModel.PassageRow.Leg

    private var tint: Color { leg.id == "dense" ? Pastel.lavender : Pastel.sky }
    private var humanLeg: String { leg.id == "dense" ? "512-d Meaning" : "BM25 Keyword" }

    var body: some View {
        HStack(spacing: 4) {
            Text(humanLeg)
            Text("#\(leg.rank)").monospaced()
        }
        .openCorePastelBadge(tint)
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
        .padding(.top, 4)
    }
}

private struct PassagesContextLine: View {
    let passage: AppModel.PassageRow.ContextPassage

    private var textColor: Color { passage.isHit ? .primary : .secondary }
    private var markColor: Color { passage.isHit ? Pastel.mint : .clear }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(markColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paragraph #\(passage.ordinal)\(passage.isHit ? " (Matched Passage)" : "")")
                    .font(.caption2.monospaced().weight(passage.isHit ? .bold : .regular))
                    .foregroundStyle(passage.isHit ? Pastel.mint : .secondary)
                Text(passage.text)
                    .font(.caption)
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(passage.isHit ? Pastel.mint.opacity(0.10) : Color.primary.opacity(0.03), in: .rect(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }
}
