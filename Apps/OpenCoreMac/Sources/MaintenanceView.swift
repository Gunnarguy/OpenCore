import AppKit
import CoreGraph
import CoreModel
import SwiftUI

/// Database Health, Vector Coverage & Deterministic Rebuild Studio (full-width `maxWidth: 1440`).
struct MaintenanceView: View {
    @Environment(\.appModel) private var model
    @State private var diagnostics: AppModel.Diagnostics?
    @State private var rehearsal: RebuildReport?
    @State private var confirmingApply = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                if let diagnostics {
                    // 1. Top 4 Health KPI Cards
                    topHealthGrid(diagnostics: diagnostics)

                    // 2. Interactive SQLite Table Layer Cards
                    MaintenanceCountsPanel(counts: diagnostics.counts)

                    // 3. Two-Column Embedding Coverage + Source Sync Timestamps
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 480), spacing: 14)], spacing: 14) {
                        MaintenanceEmbeddingPanel(coverage: diagnostics.embeddings, passages: diagnostics.counts.chunks)
                        MaintenanceSourcePanel(sources: diagnostics.sources)
                    }

                    // 4. Objects by Kind Distribution
                    MaintenanceKindPanel(kinds: diagnostics.kinds)
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Inspecting SQLite store, vector index, and table row counts...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .openCoreGlassCard(cornerRadius: 12)
                }

                // 5. Rebuild, rehearsed on a copy
                MaintenanceRebuildPanel(disabled: isWorking || diagnostics == nil) {
                    rehearse()
                }

                if let rehearsal {
                    MaintenanceRehearsalPanel(report: rehearsal, disabled: isWorking) {
                        confirmingApply = true
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Maintenance")
        .task(id: model.dataGeneration) {
            diagnostics = await model.loadDiagnostics()
        }
        .confirmationDialog(
            rehearsal.map { RebuildNarrative($0).confirmationTitle } ?? "Apply this rebuild?",
            isPresented: $confirmingApply,
            titleVisibility: .visible
        ) {
            Button("Apply to Store", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rehearsal.map { RebuildNarrative($0).confirmation } ?? "")
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label("Store & Index Health", systemImage: "stethoscope")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Pastel.mint)
                    if let diagnostics {
                        let sizeStr = diagnostics.databaseBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "Not measured"
                        Text("SQLITE: \(sizeStr.uppercased())")
                            .openCorePastelBadge(Pastel.sky)
                    }
                }
                Text("Check record counts, source syncs and index coverage first. Open a layer below to inspect its data. A rebuild is rehearsed on a copy and changes nothing until you approve it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task {
                        let start = Date()
                        diagnostics = await model.loadDiagnostics()
                        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                        ActionFeedbackCenter.shared.record(
                            button: "Refresh Store Diagnostics",
                            command: "AppModel.loadDiagnostics()",
                            outcome: "Measured SQLite file size, 9 table counts, and vector index coverage in \(ms) ms.",
                            status: .completed,
                            durationMs: ms
                        )
                    }
                } label: {
                    Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.aqua, telemetryLabel: "Refresh Store Diagnostics")

                Button {
                    Task { await model.buildEmbeddings() }
                } label: {
                    Label("Build / Verify Vectors", systemImage: "cpu")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Build / Verify Semantic Vectors")
                .disabled(isWorking)
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
    }

    private func topHealthGrid(diagnostics: AppModel.Diagnostics) -> some View {
        let sizeStr = diagnostics.databaseBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "unmeasured"
        let vecCount = diagnostics.embeddings.first?.vectors ?? 0
        let passageCount = diagnostics.counts.chunks
        let pct = passageCount > 0 ? Int((Double(vecCount) / Double(passageCount) * 100).rounded()) : 100

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
            // Card 1: SQLite File on Disk
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("On-Device SQLite Store", systemImage: "internaldrive.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Pastel.sky)
                    Spacer()
                    Text(sizeStr)
                        .openCorePastelBadge(Pastel.sky)
                }
                Text(diagnostics.databasePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: diagnostics.databasePath)])
                        ActionFeedbackCenter.shared.record(
                            button: "Reveal SQLite Database in Finder",
                            command: "NSWorkspace.activateFileViewerSelecting(\(diagnostics.databasePath))",
                            outcome: "Revealed \(diagnostics.databasePath) (\(sizeStr)) in macOS Finder.",
                            status: .completed
                        )
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(.caption2.weight(.semibold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton(tint: Pastel.sky, telemetryLabel: "Reveal SQLite in Finder")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.databasePath, forType: .string)
                        ActionFeedbackCenter.shared.record(
                            button: "Copy SQLite Path",
                            command: "NSPasteboard.setString(\"\(diagnostics.databasePath)\")",
                            outcome: "Copied full SQLite database file path to macOS Clipboard.",
                            status: .completed
                        )
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                            .font(.caption2.weight(.semibold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton(telemetryLabel: "Copy SQLite Path")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.sky)

            // Card 2: Vector Index Health
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("512-d Semantic Vector Coverage", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(pct >= 100 ? Pastel.mint : Pastel.peach)
                    Spacer()
                    Text("\(pct)% (\(vecCount)/\(passageCount))")
                        .openCorePastelBadge(pct >= 100 ? Pastel.mint : Pastel.peach)
                }
                ScoreBar(value: passageCount > 0 ? Double(vecCount) / Double(passageCount) : 1.0)
                Text(pct >= 100
                     ? "Every passage has a 512-d Apple NaturalLanguage vector on disk for hybrid search."
                     : "\(passageCount - vecCount) passage(s) are missing vectors. Click 'Build / Verify Vectors' to index them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .openCoreGlassCard(cornerRadius: 12, tint: pct >= 100 ? Pastel.mint : Pastel.peach)

            // Card 3: GitHub & Connector Credentials
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("GitHub Token & Connectors", systemImage: "key.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(diagnostics.hasGitHubToken ? Pastel.mint : Pastel.butter)
                    Spacer()
                    Text(diagnostics.hasGitHubToken ? "TOKEN READY" : "NO TOKEN")
                        .openCorePastelBadge(diagnostics.hasGitHubToken ? Pastel.mint : Pastel.butter)
                }
                Text(diagnostics.hasGitHubToken
                     ? "GitHub API credential resolved via Local Vault or `gh auth`. Ready for repo/commit sync."
                     : "No GitHub token configured. Add one in Settings or run `gh auth login`.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        model.navigate(to: .sources)
                    } label: {
                        Label("Open Sources", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.semibold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton(tint: Pastel.mint, telemetryLabel: "Open Sources from Maintenance")

                    Button {
                        model.navigate(to: .settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.caption2.weight(.semibold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton(telemetryLabel: "Open Settings from Maintenance")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
        }
    }

    private func rehearse() {
        Task {
            let start = Date()
            ActionFeedbackCenter.shared.record(
                button: "Rehearse Rebuild on a Copy",
                command: "RebuildRehearsal.rehearse(in: Rehearsals/)",
                outcome: "Copying the store, rebuilding the copy, and comparing by id. Your store is not touched.",
                status: .running
            )
            rehearsal = nil
            let report = await model.rehearseRebuild()
            rehearsal = report
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            if let report {
                ActionFeedbackCenter.shared.record(
                    button: "Rehearse Rebuild on a Copy",
                    command: "RebuildReport: \(report.blockers.count) blocker(s), \(report.warnings.count) warning(s)",
                    outcome: report.canApply
                        ? "Rehearsal finished in \(ms) ms. Nothing has changed yet. Read the difference below before applying it."
                        : "Rehearsal finished in \(ms) ms and found something that stops it being applied.",
                    status: report.canApply ? .completed : .warning,
                    durationMs: ms
                )
            }
        }
    }

    private func apply() {
        guard let rehearsal else { return }
        Task {
            let start = Date()
            let applied = await model.applyRehearsal(rehearsal)
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            if applied != nil { self.rehearsal = nil }
            diagnostics = await model.loadDiagnostics()
            ActionFeedbackCenter.shared.record(
                button: "Apply Rebuild to Store",
                command: "Store.applyRehearsal(rebuilt:expecting:)",
                outcome: applied.map {
                    "Applied in \(ms) ms. \($0.receiptsBroken) past answer(s) broken. The store as it was is kept at \($0.backupPath)."
                } ?? "Not applied. Your store is unchanged.",
                status: applied == nil ? .warning : .completed,
                durationMs: ms
            )
        }
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }
}

// MARK: - Counts

private struct MaintenanceCountsPanel: View {
    @Environment(\.appModel) private var model
    let counts: AppModel.GraphCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Data Layers & Destinations", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                    .foregroundStyle(Pastel.sky)
                Spacer()
                Text("Click any table card to open its workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Original records anchor derived knowledge. Receipts and corrections also preserve history; their presence does not mean every record can safely be rebuilt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                ForEach(counts.labelled) { row in
                    let meta = tableMetadata(for: row.label)
                    Button {
                        if let target = meta.section {
                            model.navigate(to: target)
                        }
                        ActionFeedbackCenter.shared.record(
                            button: "Inspect SQLite Table: \(row.label)",
                            command: "Open \(meta.section?.rawValue ?? meta.title) · count from loaded diagnostics",
                            outcome: "\(meta.title): \(row.value.formatted()) rows currently stored. \(meta.explanation)",
                            status: .completed
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(meta.title, systemImage: meta.symbol)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(meta.tint)
                                Spacer()
                                Text("\(row.value.formatted())")
                                    .font(.title3.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.primary)
                            }
                            Text("SQLite table: \(row.label)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(meta.explanation)
                                .font(.caption2)
                                .foregroundStyle(Pastel.ice)
                                .lineLimit(2)
                            Text(meta.section.map { "Open \($0.guide.shortName) →" } ?? "Count only · no dedicated browser")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 10, tint: meta.tint)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(meta.section == nil)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
    }

    private func tableMetadata(for label: String) -> (title: String, symbol: String, tint: Color, explanation: String, section: Section?) {
        switch label.lowercased() {
        case "objects":
            return ("Raw Floor Objects", "doc.on.doc.fill", Pastel.sky, "Original files, notes, commits & events. Never deleted on rebuild.", .corpus)
        case "chunks", "passages":
            return ("Searchable Passages", "doc.text.magnifyingglass", Pastel.mint, "Paragraph chunks split from Floor Objects for BM25 + Vector search.", .passages)
        case "entities":
            return ("Resolved Entities", "point.3.connected.trianglepath.dotted", Pastel.lavender, "Canonical projects, people, repos, and concepts across files.", .entities)
        case "aliases":
            return ("Entity Aliases", "tag.fill", Pastel.periwinkle, "Alternate names and surface forms mapped to canonical entities.", .entities)
        case "claims":
            return ("Statements · Claims", "list.bullet.rectangle", Pastel.butter, "Extracted statements and inferences; inspect their evidence before correcting them.", .claims)
        case "evidence":
            return ("Evidence Byte Spans", "quote.opening", Pastel.aqua, "Open a statement, then Inspect evidence to see its original UTF-8 byte ranges.", .claims)
        case "beliefs":
            return ("Decisions · Beliefs", "checkmark.seal.fill", Pastel.mint, "Selections and revisions, with the reason each statement was selected.", .beliefs)
        case "contradictions", "conflicts", "unresolved contradictions":
            return ("Detected Conflicts", "exclamationmark.shield.fill", Pastel.peach, "Competing claims where two sources state different values.", .contradictions)
        case "events":
            return ("Timeline Events", "clock.arrow.circlepath", Pastel.sky, "Dated actions, commits, and milestones on the chronological timeline.", .timeline)
        case "edges":
            return ("Knowledge Graph Edges", "arrow.triangle.branch", Pastel.lilac, "Directed relationships linking two entities in the graph.", .entities)
        case "receipts":
            return ("Audit Receipts", "receipt.fill", Pastel.aqua, "Stored query stages, source references, and objects transmitted by the answer path.", .receipts)
        default:
            return (label.capitalized, "tablecells", Pastel.ice, "SQLite table in opencore.sqlite3.", nil)
        }
    }
}

private struct MaintenanceKindPanel: View {
    @Environment(\.appModel) private var model
    let kinds: [AppModel.KindCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Floor Objects by Document Kind", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.aqua)
                Spacer()
                Button("Explore in Corpus") {
                    model.navigate(to: .corpus)
                }
                .controlSize(.mini)
                .openCoreGlassButton(tint: Pastel.aqua, telemetryLabel: "Explore Kinds in Corpus")
            }

            if kinds.isEmpty {
                Text("Nothing stored yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                let total = max(kinds.reduce(0) { $0 + $1.count }, 1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(kinds) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.kind.rawValue.capitalized)
                                    .font(.caption.weight(.bold))
                                Spacer()
                                Text("\(row.count)")
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(Pastel.aqua)
                            }
                            ScoreBar(value: Double(row.count) / Double(total))
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)
    }
}

// MARK: - Embeddings

private struct MaintenanceEmbeddingPanel: View {
    @Environment(\.appModel) private var model
    let coverage: [AppModel.EmbeddingCoverage]
    let passages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Semantic Vector Index Runs", systemImage: "cpu.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.mint)
                Spacer()
                Button("Rebuild Missing Vectors") {
                    Task { await model.buildEmbeddings() }
                }
                .controlSize(.mini)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Rebuild Missing Vectors")
            }

            if coverage.isEmpty {
                Label(
                    "No vectors stored yet. Retrieval runs on BM25 keyword search alone until you click 'Rebuild Missing Vectors'.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Pastel.peach)
            } else {
                ForEach(coverage) { run in
                    MaintenanceEmbeddingRow(run: run, passages: passages)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)
    }
}

private struct MaintenanceEmbeddingRow: View {
    let run: AppModel.EmbeddingCoverage
    let passages: Int

    private var fraction: Double {
        passages > 0 ? Double(run.vectors) / Double(passages) : 0
    }

    private var isComplete: Bool { run.vectors >= passages }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.model)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(Pastel.mint)
                Spacer()
                Text("\(run.dimensions)-d float32 vectors")
                    .openCorePastelBadge(Pastel.sky)
            }
            ScoreBar(value: fraction)
            detail
            note
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private var detail: some View {
        if isComplete {
            Text("\(run.vectors) of \(passages) passages embedded (100% dense semantic search coverage).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(run.vectors) of \(passages) passages embedded. Semantic search cannot see the remaining \(passages - run.vectors) passages until indexed.")
                .font(.caption)
                .foregroundStyle(Pastel.peach)
        }
    }

    @ViewBuilder private var note: some View {
        if run.recorded != run.vectors {
            Text("Run metadata recorded \(run.recorded), whereas \(run.vectors) vectors are physically stored on disk.")
                .font(.caption2)
                .foregroundStyle(Pastel.peach)
        } else if !run.finished {
            Text("This indexing pass was interrupted and can be resumed at any time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sources

private struct MaintenanceSourcePanel: View {
    @Environment(\.appModel) private var model
    let sources: [Source]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connected Data Sources & Last Sync", systemImage: "cylinder.split.1x2.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.lavender)
                Spacer()
                Button("Manage Sources") {
                    model.navigate(to: .sources)
                }
                .controlSize(.mini)
                .openCoreGlassButton(tint: Pastel.lavender, telemetryLabel: "Manage Sources from Maintenance")
            }

            if sources.isEmpty {
                Text("No sources connected.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(sources) { source in
                    HStack {
                        Text(source.displayName)
                            .font(.caption.weight(.bold))
                        Spacer()
                        Text(synced(source))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.3)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
    }

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
            HStack {
                Label("Rebuild", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Pastel.peach)
                Spacer()
                Button(action: action) {
                    Label("Rehearse Rebuild on a Copy", systemImage: "doc.on.doc.fill")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.peach, telemetryLabel: "Rehearse Rebuild on a Copy")
                .disabled(disabled)
            }

            maintenanceExplainer("What it is", RebuildNarrative.whatItIs)
            maintenanceExplainer("When you would use it", RebuildNarrative.whenToUse)
            maintenanceExplainer("Why a rehearsal is safe", RebuildNarrative.howItIsSafe)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.peach)
    }
}

/// What a rehearsal found and what applying it would do. The sentences and their numbers come
/// from `RebuildNarrative`, where they are tested.
private struct MaintenanceRehearsalPanel: View {
    let report: RebuildReport
    let disabled: Bool
    let apply: () -> Void

    private var narrative: RebuildNarrative { RebuildNarrative(report) }

    var body: some View {
        let narrative = narrative
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(report.canApply ? "Rehearsal Ready for Review" : "Rehearsal Blocked",
                      systemImage: report.canApply ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(report.canApply ? Pastel.mint : Pastel.peach)
                Spacer()
                Button(role: .destructive, action: apply) {
                    Label("Apply to Store…", systemImage: "square.and.arrow.down.on.square.fill")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: report.canApply, tint: Pastel.peach, telemetryLabel: "Apply Rebuild to Store")
                .disabled(disabled || !report.canApply)
            }

            Text(narrative.headline)
                .font(.callout.weight(.semibold))

            ForEach(report.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "xmark.octagon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            Text("What the rehearsal found").font(.caption.weight(.bold))
            ForEach(narrative.findings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(finding.needsAttention ? Pastel.peach : .primary)
                    Text(finding.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(finding.breakdown, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                }
            }

            if !report.explanation.beliefs.isEmpty {
                Divider()
                Text("Beliefs that would change or be new").font(.caption.weight(.bold))
                ForEach(report.explanation.beliefs) { belief in
                    Text("\(belief.subject) \(belief.predicate.replacingOccurrences(of: "_", with: " ")): \(belief.before ?? "no belief") → \(belief.after)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Divider()
            Text("What Apply will do").font(.caption.weight(.bold))
            ForEach(narrative.applyWill, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle").font(.caption)
            }
            Text("What Apply will not do").font(.caption.weight(.bold))
            ForEach(narrative.applyWillNot, id: \.self) { line in
                Label(line, systemImage: "shield").font(.caption)
            }

            Text("Every change, by id and reason, is in rebuild-report.json in \(report.pristinePath.replacingOccurrences(of: "/pristine.sqlite3", with: "")).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 14, tint: report.canApply ? Pastel.mint : Pastel.peach)
    }
}

private func maintenanceExplainer(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption.weight(.bold))
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Shared

private func maintenanceRow(_ label: String, _ value: String?) -> some View {
    GridRow {
        Text(label).foregroundStyle(.secondary)
        if let value {
            Text(value).foregroundStyle(.primary).monospaced()
        } else {
            Text("not measured").foregroundStyle(.tertiary).italic()
        }
    }
    .font(.caption)
}

private func maintenanceComparisonRow(_ row: AppModel.CountComparison) -> some View {
    let valueColor: Color = row.matches ? Pastel.mint : Pastel.rose
    let delta = row.delta > 0 ? "+\(row.delta)" : "\(row.delta)"

    return GridRow {
        Text(row.label).fontWeight(.semibold)
        Text("\(row.before)").foregroundStyle(.secondary).monospaced()
        Text("\(row.after)").foregroundStyle(valueColor).monospaced()
        Text(row.matches ? "0 (Exact Match)" : delta).foregroundStyle(valueColor).monospaced()
    }
    .font(.caption)
}
