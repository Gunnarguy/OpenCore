import CoreModel
import CoreReason
import SwiftUI

struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showingTrace = false

    var body: some View {
        VStack(spacing: 0) {
            askBar
            Divider()

            if let answer = model.answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let insufficient = answer.insufficientEvidence {
                            InsufficientEvidenceCard(message: insufficient)
                        } else {
                            Text(answer.summary)
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            ForEach(Array(answer.points.enumerated()), id: \.offset) { _, point in
                                AnswerPointCard(point: point)
                            }
                        }

                        if !answer.contradictions.isEmpty {
                            ContradictionCallout(contradictions: answer.contradictions)
                        }

                        ReceiptCard(receipt: answer.receipt) {
                            Task {
                                await model.loadTrace(for: answer.receipt)
                                showingTrace = true
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyAskState()
            }
        }
        .navigationTitle("Ask")
        .sheet(isPresented: $showingTrace) { TraceSheet(rows: model.traceRows) }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Ask about your own history", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit { Task { await model.ask(query) } }
            if case .working = model.state { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct EmptyAskState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Every answer here is assembled from stored claims.")
                .font(.headline)
            Text("No model writes the prose, so each line has a row and a source behind it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InsufficientEvidenceCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not enough evidence", systemImage: "questionmark.circle")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Answering anyway would mean inventing the connection.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

private struct AnswerPointCard: View {
    let point: AnswerPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: point.derivation == .observed ? "circle.fill" : "circle.dashed")
                    .font(.system(size: 8))
                    .foregroundStyle(point.derivation == .observed ? Color.accentColor : .orange)
                Text(point.statement).font(.body.weight(.medium))
            }

            HStack(spacing: 12) {
                MetricPill(label: "confidence", value: String(format: "%.2f", point.confidence))
                MetricPill(label: "authority", value: point.authority.label)
                MetricPill(label: "derivation", value: point.derivation.rawValue)
            }

            ForEach(Array(point.supporting.prefix(3).enumerated()), id: \.offset) { _, evidence in
                EvidenceLine(text: evidence.snippet, stance: .supports)
            }
            ForEach(Array(point.counter.prefix(3).enumerated()), id: \.offset) { _, evidence in
                EvidenceLine(text: evidence.snippet, stance: .refutes)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospaced()
        }
        .font(.caption)
    }
}

private struct EvidenceLine: View {
    let text: String
    let stance: Stance

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: stance == .supports ? "arrow.turn.down.right" : "xmark")
                .font(.caption2)
                .foregroundStyle(stance == .supports ? .secondary : Color.red)
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct ContradictionCallout: View {
    let contradictions: [Contradiction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Contradictions touching this answer", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            ForEach(contradictions.prefix(4)) { contradiction in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(contradiction.kind.rawValue) → \(contradiction.resolution.rawValue)")
                        .font(.caption.monospaced())
                    Text(contradiction.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 10))
    }
}
