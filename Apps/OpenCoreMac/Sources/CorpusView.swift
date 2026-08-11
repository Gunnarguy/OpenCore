import CoreModel
import CoreStore
import SwiftUI

/// What OpenCore actually holds.
///
/// **Why this screen exists**, measured 2026-08-10: the question "how many of my apps are built
/// with Swift" was asked in *chat*, because there was nowhere else to ask it. That is somebody
/// trying to understand their own corpus with no surface offering it, and the answer came back
/// wrong by six times. The counting bug was real and is fixed, but the reason it was ever hit
/// is that this view did not exist.
///
/// Deliberately not diagnostics. Maintenance answers "is the store healthy"; this answers "what
/// does it know about me", which is a different question with a different reader.
struct CorpusView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot: CorpusSnapshot?

    var body: some View {
        ScrollView {
            if let snapshot {
                VStack(alignment: .leading, spacing: 24) {
                    totals(snapshot)
                    imbalance(snapshot)
                    breakdown("By kind", rows: snapshot.byKind.map { ($0.0.rawValue, $0.1) }, total: snapshot.objects)
                    breakdown("By source", rows: snapshot.bySource, total: snapshot.objects)
                    breakdown("By domain", rows: snapshot.byDomain.map { ($0.0.rawValue, $0.1) }, total: snapshot.objects)
                    overTime(snapshot)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle("Corpus")
        .task { if let store = model.store { snapshot = try? await store.corpusSnapshot() } }
    }

    private func totals(_ snapshot: CorpusSnapshot) -> some View {
        HStack(spacing: 20) {
            Total("objects", snapshot.objects)
            Total("passages", snapshot.chunks)
            Total("entities", snapshot.entities)
            Total("claims", snapshot.claims)
            Total("events", snapshot.events)
        }
    }

    /// The one number that makes the shape obvious.
    ///
    /// Shown near the top because it is the most consequential fact about this corpus and it is
    /// invisible in a list of counts. It is also the same imbalance underneath the
    /// commit-flooding retrieval defect: a corpus dominated by many short objects of one kind
    /// ranks that kind above everything, whatever the question was about.
    @ViewBuilder
    private func imbalance(_ snapshot: CorpusSnapshot) -> some View {
        if let top = snapshot.byKind.first, snapshot.dominantShare > 0.5 {
            Label(
                "\(Int(snapshot.dominantShare * 100))% of everything is \(top.0.rawValue). "
                    + "Retrieval sees that imbalance too: a corpus dominated by one kind of short object tends to return it whatever the question was about.",
                systemImage: "chart.pie"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
        }
    }

    private func breakdown(_ title: String, rows: [(String, Int)], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            ForEach(rows.prefix(12), id: \.0) { name, count in
                HStack(spacing: 10) {
                    Text(name).font(.callout).frame(width: 150, alignment: .leading).lineLimit(1)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(2, proxy.size.width * (total > 0 ? Double(count) / Double(total) : 0)))
                    }
                    .frame(height: 10)
                    Text("\(count)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func overTime(_ snapshot: CorpusSnapshot) -> some View {
        if !snapshot.byMonth.isEmpty {
            let peak = snapshot.byMonth.map(\.1).max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Over time")
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(snapshot.byMonth, id: \.0) { month, count in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(height: max(1, 90 * Double(count) / Double(peak)))
                            .help("\(month): \(count)")
                    }
                }
                .frame(height: 90)
                HStack {
                    Text(snapshot.byMonth.first?.0 ?? "").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(snapshot.byMonth.last?.0 ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
                // Stated rather than quietly omitted. A histogram that silently drops every
                // undated object presents a confident picture of a corpus it only partly drew.
                if snapshot.undated > 0 {
                    Text("\(snapshot.undated) objects carry no date and are not in this histogram. Unmeasured, not zero.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct Total: View {
    let label: String
    let value: Int
    init(_ label: String, _ value: Int) { self.label = label; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.title2.weight(.medium).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
