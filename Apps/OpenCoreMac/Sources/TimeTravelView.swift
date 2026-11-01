import CoreModel
import CoreReason
import SwiftUI

/// The bitemporal model made visible: move Knowledge Time, World Time, or both, and watch
/// what OpenCore believed or what was true in the world change.
struct TimeTravelView: View {
    @Environment(\.appModel) private var model
    @State private var axis: AppModel.TimeTravelAxis = .knowledge
    @State private var date = Date()
    @State private var worldDate = Date()
    @State private var rows: [AppModel.TimeTravelRow] = []
    @State private var onlyChanges = false
    @State private var filter = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var loadedQuery: TimeTravelQuery?

    private var timeQuery: TimeTravelQuery {
        TimeTravelQuery(day: day, worldDay: worldDay, axis: axis, dataGeneration: model.dataGeneration)
    }

    private var day: Date { Calendar.current.startOfDay(for: date) }
    private var worldDay: Date { Calendar.current.startOfDay(for: worldDate) }
    private var dayText: String { ClaimsView.formatter.string(from: day) }

    private var visible: [AppModel.TimeTravelRow] {
        var result = onlyChanges ? rows.filter { $0.change != .unchanged } : rows
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.subject.lowercased().contains(needle)
                    || $0.predicate.lowercased().contains(needle)
                    || ($0.then?.value.lowercased().contains(needle) ?? false)
                    || ($0.now?.value.lowercased().contains(needle) ?? false)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            content
        }
        .navigationTitle("Time travel")
        .searchable(text: $filter, prompt: "Filter subjects, predicates, or values")
        .task(id: timeQuery) {
            await reload()
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Axis", selection: $axis) {
                    ForEach(AppModel.TimeTravelAxis.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)

                DatePicker(
                    axis == .both ? "Knowledge:" : "",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .labelsHidden()

                if axis == .both {
                    Text("· World:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "World:",
                        selection: $worldDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                }

                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Only what changed", isOn: $onlyChanges)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                OpenCoreGlassCluster(spacing: 6) {
                    HStack(spacing: 6) {
                        presetButton("Today", daysAgo: 0)
                        presetButton("24h ago", daysAgo: 1)
                        presetButton("7d ago", daysAgo: 7)
                        presetButton("30d ago", daysAgo: 30)
                        presetButton("90d ago", daysAgo: 90)
                        presetButton("1y ago", daysAgo: 365)
                    }
                }
                Spacer()
                Text(axis.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func presetButton(_ label: String, daysAgo: Int) -> some View {
        Button(label) {
            let target = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            date = target
            if axis == .both { worldDate = target }
            let targetStr = ClaimsView.formatter.string(from: target)
            ActionFeedbackCenter.shared.record(
                button: "Time Travel Preset: \(label) (\(targetStr))",
                command: "Select Time Travel date",
                outcome: "Selected \(targetStr) (\(daysAgo) day(s) ago). Loading the requested comparison.",
                status: .received
            )
        }
        .controlSize(.small)
        .openCoreGlassButton(telemetryLabel: "Time Travel Preset: \(label)")
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                BitemporalExplainerCard(axis: axis)
                if !rows.isEmpty, loadedQuery == timeQuery {
                    TimeTravelSummary(dayText: dayText, query: timeQuery, rows: rows)
                        .id(timeQuery)
                }
                ForEach(loadedQuery == timeQuery ? visible : []) { row in
                    TimeTravelRowCard(row: row, dayText: dayText)
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if let loadError { EmptyState(message: "Could not load this comparison.\n\(loadError)") }
            else if visible.isEmpty && !loading { EmptyState(message: emptyMessage) }
        }
    }

    private var emptyMessage: String {
        if rows.isEmpty {
            return "OpenCore held no beliefs on \(dayText), and holds none now.\nSync a source first."
        }
        return "Nothing matched or changed between \(dayText) and now."
    }

    private func reload() async {
        let requested = timeQuery
        loading = true
        loadedQuery = nil
        rows = []
        loadError = nil
        do {
        let fetched = try await model.timeTravel(
            asOf: instant(endingOn: requested.day),
            worldInstant: instant(endingOn: requested.worldDay),
            axis: requested.axis
        )
        guard !Task.isCancelled, requested == timeQuery else { return }
        rows = fetched
        loadedQuery = requested
        loading = false
        } catch {
            guard !Task.isCancelled, requested == timeQuery else { return }
            loadError = error.localizedDescription
            loading = false
        }
    }

    private func instant(endingOn start: Date) -> Date {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return min(next.addingTimeInterval(-1), Date())
    }
}

private struct TimeTravelQuery: Hashable, Sendable {
    let day: Date
    let worldDay: Date
    let axis: AppModel.TimeTravelAxis
    let dataGeneration: Int
}

// MARK: - Two-Clock Bitemporal Explainer

private struct BitemporalExplainerCard: View {
    let axis: AppModel.TimeTravelAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Why Two Clocks? (Bitemporal Memory)", systemImage: "clock.badge.checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("Active axis: \(axis.rawValue)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clock 1: What OpenCore Knew")
                        .font(.caption.weight(.semibold))
                    Text("Knowledge Time (observedAt / decidedAt)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.accentColor)
                    Text("Rewinds OpenCore's database to that date. Shows what your notes and docs said before later edits or syncs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text("Clock 2: What Was True in Real Life")
                        .font(.caption.weight(.semibold))
                    Text("World Time (validFrom / validTo)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.purple)
                    Text("Filters facts by when they were actually true in the world, even if you synced the file weeks later.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10)
    }
}

// MARK: - Summary

private struct TimeTravelSummary: View {
    @Environment(\.appModel) private var model
    let dayText: String
    let query: TimeTravelQuery
    let rows: [AppModel.TimeTravelRow]

    @State private var synthesizing = false
    @State private var brief: Conversation.GroundedBrief?
    @State private var summaryTask: Task<Void, Never>?
    @State private var summaryRequestID = UUID()

    private var held: Int { rows.filter { $0.then != nil }.count }

    private func count(_ change: AppModel.TimeTravelRow.Change) -> Int {
        rows.filter { $0.change == change }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On \(dayText) OpenCore held \(held) active fact\(held == 1 ? "" : "s") (Belief rows).")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    startSummary()
                } label: {
                    HStack(spacing: 4) {
                        if synthesizing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Summarize Diff (/fm)")
                    }
                    .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
                .disabled(synthesizing)
                .help("Synthesize a grounded executive summary of what changed between \(dayText) and now using /usr/bin/fm.")
            }
            HStack(spacing: 12) {
                MetricPill(label: "retracted since (noLongerHeld)", value: "\(count(.noLongerHeld))")
                MetricPill(label: "updated since (changed)", value: "\(count(.changed))")
                MetricPill(label: "discovered since (learned)", value: "\(count(.learned))")
                MetricPill(label: "still true (unchanged)", value: "\(count(.unchanged))")
            }

            if let brief {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            "On-Device Bitemporal Diff Brief (\(brief.modelName))",
                            systemImage: "sparkles"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                        Spacer()
                        Button {
                            cancelSummary()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(brief.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10)
        .onChange(of: query) { _, _ in cancelSummary() }
        .onDisappear { cancelSummary() }
    }

    private func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryRequestID = UUID()
        synthesizing = false
        brief = nil
    }

    private func startSummary() {
        cancelSummary()
        let requestID = UUID()
        let requested = query
        summaryRequestID = requestID
        synthesizing = true
        summaryTask = Task {
            let result = await model.synthesizeTimeTravelBrief(dayText: dayText, rows: rows)
            // This view is also keyed by both clocks, axis, and corpus generation. A cancelled
            // synthesis from another coordinate cannot publish into the current summary.
            guard !Task.isCancelled, summaryRequestID == requestID,
                  requested == query, model.dataGeneration == requested.dataGeneration else { return }
            brief = result
            synthesizing = false
            summaryTask = nil
        }
    }
}

// MARK: - Rows

private struct TimeTravelRowCard: View {
    @Environment(\.appModel) private var model
    let row: AppModel.TimeTravelRow
    let dayText: String

    private var thenTone: Color { row.change == .unchanged ? .primary : .secondary }
    private var nowTone: Color { row.change == .noLongerHeld ? .red : .primary }
    private var reason: String? { (row.now ?? row.then)?.belief.reason }
    private var cardTint: Color? { row.change == .noLongerHeld ? .red : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TimeTravelBadge(change: row.change)
                Spacer()
                if let claimID = row.activeClaimID {
                    Button {
                        model.inspectClaim(claimID)
                    } label: {
                        Label("Inspect Provenance", systemImage: "doc.text.magnifyingglass")
                            .font(.caption2)
                    }
                    .buttonStyle(.link)
                }
            }

            HStack(spacing: 6) {
                EntityLinkChip(name: row.subject, entityID: row.subjectID, prominent: true)
                Text(row.predicate)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            TimeTravelSideRow(
                label: "then",
                held: row.then,
                missing: "not believed on \(dayText)",
                struck: row.change == .noLongerHeld,
                tone: thenTone
            )

            if row.change != .unchanged {
                TimeTravelSideRow(
                    label: "now",
                    held: row.now,
                    missing: "no longer held",
                    struck: false,
                    tone: nowTone
                )
            }

            if row.change == .noLongerHeld {
                TimeTravelRetraction(retractedAt: row.retractedAt)
            }

            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10, tint: cardTint)
    }
}

private struct TimeTravelSideRow: View {
    let label: String
    let held: AppModel.HeldBelief?
    let missing: String
    let struck: Bool
    let tone: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .frame(width: 40, alignment: .leading)
                .foregroundStyle(.tertiary)

            if let held {
                if let targetID = held.objectEntityID {
                    EntityLinkChip(name: held.value, entityID: targetID)
                } else {
                    Text(held.value)
                        .font(.callout)
                        .strikethrough(struck)
                        .foregroundStyle(tone)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                TimeTravelMeta(belief: held.belief)
            } else {
                Text(missing)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(tone)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct TimeTravelMeta: View {
    let belief: Belief

    var body: some View {
        HStack(spacing: 10) {
            MetricPill(label: "v", value: "\(belief.version)")
            MetricPill(label: "conf", value: String(format: "%.2f", belief.confidence))
            MetricPill(label: "decided", value: ClaimsView.formatter.string(from: belief.decidedAt))
        }
        .fixedSize()
    }
}

private struct TimeTravelBadge: View {
    let change: AppModel.TimeTravelRow.Change

    private var text: String {
        switch change {
        case .noLongerHeld: "NO LONGER HELD"
        case .changed: "CHANGED SINCE"
        case .learned: "LEARNED SINCE"
        case .unchanged: "STILL HELD"
        }
    }

    private var symbol: String {
        switch change {
        case .noLongerHeld: "xmark.circle.fill"
        case .changed: "arrow.triangle.swap"
        case .learned: "plus.circle"
        case .unchanged: "equal.circle"
        }
    }

    private var tone: Color {
        switch change {
        case .noLongerHeld: .red
        case .changed: .orange
        case .learned: Color.accentColor
        case .unchanged: .secondary
        }
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tone)
    }
}

private struct TimeTravelRetraction: View {
    let retractedAt: Date?

    var body: some View {
        HStack(spacing: 4) {
            Text("stopped believing").foregroundStyle(.tertiary)
            if let retractedAt {
                Text(ClaimsView.formatter.string(from: retractedAt))
                    .foregroundStyle(.secondary)
                    .monospaced()
            } else {
                Text("not measured").foregroundStyle(.tertiary).italic()
            }
        }
        .font(.caption)
    }
}
