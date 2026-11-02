import AppKit
import CoreModel
import CoreReason
import CoreSearch
import SwiftUI

/// Always-on macOS Menu Bar companion window (`MenuBarExtra`).
///
/// Gives the user an instant `<50ms` deterministic Quick Ask bar, live corpus telemetry,
/// 1-click workspace launchers, and full-width zero-truncation sync triggers from any app.
struct MenuBarView: View {
    @Environment(\.appModel) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var feedback = ActionFeedbackCenter.shared

    @State private var query = ""
    @State private var quickAnswer: Answer?
    @State private var fmSentences: [(text: String, source: Int?)] = []
    @State private var asking = false
    @State private var synthesizingFM = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickAskBar

            if asking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching claims and passages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let quickAnswer {
                answerPreview(quickAnswer)
            }

            Divider()
            pulseGrid
            Divider()
            actionButtons

            if let latest = feedback.currentEvent {
                menuBarTelemetryStrip(latest)
            }
        }
        .padding(16)
        .frame(width: 480)
        .task {
            if model.store == nil {
                await model.start()
            }
            if HardwareInspectorManager.shared.devices.isEmpty {
                HardwareInspectorManager.shared.refreshAll()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("OpenCore", systemImage: "brain.head.profile")
                .font(.headline.weight(.bold))
                .fixedSize(horizontal: true, vertical: false)

            Text("Menu Bar Companion")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            Spacer()

            Button {
                model.settings.toggleLightDarkMode()
                let isLight = model.settings.isEffectiveLightMode
                ActionFeedbackCenter.shared.record(
                    button: "Menu Bar Theme Toggle",
                    command: "AppSettings.appearanceMode = \(isLight ? ".light" : ".dark")",
                    outcome: "Switched OpenCore to \(isLight ? "Light Frost" : "Dark Obsidian") mode.",
                    status: .completed
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.settings.isEffectiveLightMode ? "sun.max.fill" : "moon.stars.fill")
                        .foregroundStyle(model.settings.isEffectiveLightMode ? Pastel.butter : Pastel.lavender)
                    Text(model.settings.isEffectiveLightMode ? "Light" : "Dark")
                        .font(.caption2.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Toggle Light Frost / Dark Obsidian Mode (⇧⌘L)")

            switch model.state {
            case .idle:
                Text("Ready")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Pastel.mint)
                    .fixedSize(horizontal: true, vertical: false)
            case .working(let what):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(what)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .failed:
                Text("Attention")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Pastel.peach)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var quickAskBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Quick ask your history (press Return)…", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { runQuickAsk() }
            if !query.isEmpty {
                Button {
                    query = ""
                    quickAnswer = nil
                    fmSentences = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .openCoreGlassCard(cornerRadius: 8)
    }

    private func answerPreview(_ answer: Answer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if synthesizingFM {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Synthesizing on-device (/usr/bin/fm)…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !fmSentences.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("On-Device (/usr/bin/fm)", systemImage: "cpu.fill")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Pastel.mint)
                    ForEach(Array(fmSentences.prefix(3).enumerated()), id: \.offset) { _, s in
                        Text(s.source != nil ? "\(s.text) [\(s.source!)]" : s.text)
                            .font(.caption)
                    }
                }
            }

            if let counted = answer.counted {
                Text(counted.sentence)
                    .font(.callout.weight(.medium))
            } else {
                Text(answer.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let activity = answer.activity, activity.totalEvents > 0 {
                    ActivityRows(activity: activity)
                }

                ForEach(Array(answer.points.prefix(4).enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: point.counter.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(point.counter.isEmpty ? Color.accentColor : .orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.statement)
                                .font(.caption)
                            if !point.counter.isEmpty {
                                Text("\(point.counter.count) counter-evidence span\(point.counter.count == 1 ? "" : "s")")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Pastel.peach)
                            }
                        }
                    }
                }

                if answer.points.isEmpty && fmSentences.isEmpty, let topPassage = answer.passages.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topPassage.object.title)
                            .font(.caption.weight(.semibold))
                        Text(topPassage.chunk.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            HStack {
                Text("receipt \(answer.receipt.shortCode)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Continue in Grounded Chat →") {
                    let q = query
                    NSApp.activate(ignoringOtherApps: true)
                    model.askInChat(q)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 8)
    }

    private var pulseGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 8
        ) {
            menuMetricButton(
                label: "Objects",
                value: "\(model.objectCount)",
                symbol: "cube.box.fill",
                tint: Pastel.sky
            ) {
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = .corpus
            }

            menuMetricButton(
                label: "Claims",
                value: "\(model.claimCount)",
                symbol: "text.quote",
                tint: Pastel.mint
            ) {
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = .claims
            }

            menuMetricButton(
                label: "USB Bus",
                value: "\(HardwareInspectorManager.shared.devices.count)",
                symbol: "cable.connector.horizontal",
                tint: Pastel.aqua
            ) {
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = .hardwareUSB
            }

            menuMetricButton(
                label: "Automation",
                value: "Studio",
                symbol: "viewfinder.rectangular",
                tint: Pastel.lavender
            ) {
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = .computerControl
            }
        }
    }

    private func menuMetricButton(
        label: String,
        value: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.26), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                Button {
                    Task { await model.syncAllWorkspaceAndSources() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                        Text("Sync All Sources")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.sky)

                Button {
                    Task { await model.syncGitHub() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync GitHub Activity")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.mint)

                Button {
                    Task {
                        await model.syncCalendar()
                        await model.syncNotes()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                        Text("Sync Calendar & Notes")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.butter)

                Button {
                    openWindow(id: "main", value: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                    model.showingJarvisHUD = true
                    Task { await JarvisController.shared.generateMorningBriefing(using: model) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles.tv.fill")
                        Text("J.A.R.V.I.S. Briefing")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.lavender)
            }

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main", value: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                    model.selectedSection = .aiModelsRAM
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip.fill")
                        Text("AI Models & RAM")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.aqua)

                Button {
                    openWindow(id: "main", value: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                    model.selectedSection = .home
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                        Text("Open Command Center")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint)
            }
        }
    }

    private func menuBarTelemetryStrip(_ entry: ActionFeedbackCenter.Event) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.status.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(entry.status.tint)
            Text(entry.status.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.status.tint)
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(entry.outcomeExplanation)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let ms = entry.durationMs {
                Text("\(ms) ms")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(entry.status.tint.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    private func runQuickAsk() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let store = model.store else { return }
        asking = true
        fmSentences = []
        ActionFeedbackCenter.shared.record(
            button: "Menu Bar Quick Ask",
            command: "Reasoner(store).answer(\"\(q)\")",
            outcome: "Running hybrid retrieval and grounded synthesis for '\(q)'...",
            status: .running
        )
        Task {
            defer { asking = false }
            let start = Date()
            // The same embedder and tuning as every other surface. A bare `Reasoner(store:)`
            // here meant this one could answer differently from the app behind it.
            let reasoner = Reasoner(
                store: store,
                embedder: try? NLEmbeddingProvider(),
                tuning: model.settings.tuning
            )
            let result = await Result { try await reasoner.answer(q) }
            if case .failure(let error) = result {
                // `try?` left the feedback line reading "running" forever.
                ActionFeedbackCenter.shared.record(
                    button: "Menu Bar Quick Ask",
                    command: "Reasoner.answer(\"\(q)\")",
                    outcome: "Could not answer: \(error)",
                    status: .warning
                )
                model.state = .failed("Quick Ask: \(error)")
            }
            if case .success(let ans) = result {
                quickAnswer = ans
                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                ActionFeedbackCenter.shared.record(
                    button: "Menu Bar Quick Ask",
                    command: "Reasoner.answer(\"\(q)\") -> receipt \(ans.receipt.shortCode)",
                    outcome: "Retrieved \(ans.points.count) grounded claims and \(ans.passages.count) passages in \(ms) ms.",
                    status: .completed,
                    durationMs: ms
                )

                var numbered: [GroundingSource] = []
                for point in ans.points.prefix(5) {
                    numbered.append(GroundingSource(
                        index: numbered.count + 1,
                        title: point.statement,
                        text: point.statement,
                        objectID: ObjectID.derived(from: "menubar-claim", point.statement),
                        authority: .authoredArtifact,
                        uri: nil
                    ))
                }
                for hit in ans.passages.prefix(4) {
                    numbered.append(GroundingSource(
                        index: numbered.count + 1,
                        title: hit.object.title,
                        text: hit.chunk.text,
                        objectID: hit.object.id,
                        authority: hit.object.authority,
                        uri: hit.object.uri
                    ))
                }
                if !numbered.isEmpty {
                    synthesizingFM = true
                    defer { synthesizingFM = false }
                    if let res = await Conversation.synthesizeGroundedBrief(question: q, sources: numbered) {
                        fmSentences = [(res.text, nil)]
                    }
                }
            }
        }
    }
}
