import CoreModel
import SwiftUI

/// The bitemporal model made visible: move the date and watch what OpenCore believed change.
///
/// The screen is a diff rather than a snapshot. A snapshot asks the reader to remember the
/// current set and spot the difference themselves, and the difference is the entire reason
/// the belief table is append-only.
struct TimeTravelView: View {
    @Environment(AppModel.self) private var model
    @State private var date = Date()
    @State private var rows: [AppModel.TimeTravelRow] = []
    @State private var onlyChanges = false
    @State private var loading = false

    private var day: Date { Calendar.current.startOfDay(for: date) }
    private var dayText: String { ClaimsView.formatter.string(from: day) }

    private var visible: [AppModel.TimeTravelRow] {
        onlyChanges ? rows.filter { $0.change != .unchanged } : rows
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            content
        }
        .navigationTitle("Time travel")
        // Keyed on the store as well as the day: the detail view can appear before
        // `start()` has opened it, and the query would otherwise answer empty forever.
        .task(id: TimeTravelQuery(day: day, storeReady: model.store != nil)) { await reload() }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Only what changed", isOn: $onlyChanges)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("Transaction time: what OpenCore believed on this date, not what was true on it. Valid time is the other axis and this picker does not move it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !rows.isEmpty {
                    TimeTravelSummary(dayText: dayText, rows: rows)
                }
                ForEach(visible) { row in
                    TimeTravelRowCard(row: row, dayText: dayText)
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if visible.isEmpty { EmptyState(message: emptyMessage) }
        }
    }

    private var emptyMessage: String {
        if rows.isEmpty {
            return "OpenCore held no beliefs on \(dayText), and holds none now.\nSync a source first."
        }
        return "Nothing changed between \(dayText) and now."
    }

    private func reload() async {
        loading = true
        let fetched = await model.timeTravel(asOf: instant(endingOn: day))
        // A superseded run still finishes its awaits, so without this the older answer can
        // land on top of the newer one.
        guard !Task.isCancelled else { return }
        rows = fetched
        loading = false
    }

    /// A picked day means "as that day ended", clamped to now.
    ///
    /// Reading it as midnight would make the default of today report a full day of drift
    /// against itself, which is the opposite of what a reader expects from "today".
    private func instant(endingOn start: Date) -> Date {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return min(next.addingTimeInterval(-1), Date())
    }
}

private struct TimeTravelQuery: Equatable, Sendable {
    let day: Date
    let storeReady: Bool
}

// MARK: - Summary

private struct TimeTravelSummary: View {
    let dayText: String
    let rows: [AppModel.TimeTravelRow]

    private var held: Int { rows.filter { $0.then != nil }.count }

    private func count(_ change: AppModel.TimeTravelRow.Change) -> Int {
        rows.filter { $0.change == change }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On \(dayText) OpenCore held \(held) belief\(held == 1 ? "" : "s").")
                .font(.callout)
            HStack(spacing: 12) {
                MetricPill(label: "no longer held", value: "\(count(.noLongerHeld))")
                MetricPill(label: "changed since", value: "\(count(.changed))")
                MetricPill(label: "learned since", value: "\(count(.learned))")
                MetricPill(label: "unchanged", value: "\(count(.unchanged))")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Rows

/// Colors and labels are precomputed for the reason `ContradictionSideRow` documents:
/// ternaries over `ShapeStyle` inside a `ForEach` inside a `LazyVStack` exhaust the
/// type checker's budget.
private struct TimeTravelRowCard: View {
    let row: AppModel.TimeTravelRow
    let dayText: String

    private var thenTone: Color { row.change == .unchanged ? .primary : .secondary }
    private var nowTone: Color { row.change == .noLongerHeld ? .red : .primary }
    private var reason: String? { (row.now ?? row.then)?.belief.reason }

    private var fill: AnyShapeStyle {
        switch row.change {
        case .noLongerHeld: AnyShapeStyle(Color.red.opacity(0.10))
        default: AnyShapeStyle(HierarchicalShapeStyle.quaternary.opacity(0.3))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimeTravelBadge(change: row.change)

            Text("\(row.subject) \(row.predicate)")
                .font(.callout.weight(.medium))

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
        .background(fill, in: .rect(cornerRadius: 10))
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
                Text(held.value)
                    .font(.callout)
                    .strikethrough(struck)
                    .foregroundStyle(tone)
                    .lineLimit(1)
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

/// Retraction is a recorded event, so an unrecorded date says so rather than guessing one.
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
