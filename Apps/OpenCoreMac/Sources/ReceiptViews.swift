import CoreModel
import SwiftUI

/// The receipt is the product, so it gets a real view rather than a debug dump.
///
/// The one rule this view enforces: a value that was never measured renders as
/// "not measured" in a dimmed style, never as a number. A receipt that fills in a
/// plausible confidence is worse than no receipt, because it looks like proof.
struct ReceiptCard: View {
    let receipt: Receipt
    var onTrace: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Receipt \(receipt.shortCode)", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let onTrace {
                    Button("Trace evidence", action: onTrace).controlSize(.small)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                row("class", receipt.queryClass.rawValue)
                row("objects searched", "\(receipt.objectsSearched)")
                row("objects retrieved", "\(receipt.objectsRetrieved)")
                row("evidence admitted", "\(receipt.evidenceAdmitted)")
                row("claims consulted", "\(receipt.claimsConsulted)")
                row("contradictions", "\(receipt.contradictionsSurfaced)")
                row("model", receipt.model ?? "none — assembled from claims")
                row("objects transmitted", "\(receipt.objectsTransmitted)")
                if let confidence = receipt.confidence {
                    row("confidence", String(format: "%.2f", confidence))
                } else {
                    GridRow {
                        Text("confidence").foregroundStyle(.tertiary)
                        Text("not measured").foregroundStyle(.tertiary).italic()
                    }
                    .font(.caption)
                }
            }

            if !receipt.domainsBlocked.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("domains blocked").font(.caption).foregroundStyle(.tertiary)
                    Text(receipt.domainsBlocked.map(\.rawValue).joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if !receipt.stages.isEmpty {
                Divider()
                ForEach(Array(receipt.stages.enumerated()), id: \.offset) { _, stage in
                    HStack(alignment: .top) {
                        Text(stage.name).font(.caption.monospaced()).frame(width: 150, alignment: .leading)
                        Text("\(stage.milliseconds)ms").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(stage.counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospaced()
        }
        .font(.caption)
    }
}

struct TraceSheet: View {
    let rows: [AppModel.TraceRow]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Evidence behind this answer").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if rows.isEmpty {
                Text("This answer admitted no evidence.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ScoreBar(value: row.score)
                            Text(String(format: "%.3f", row.score)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(row.object.title).font(.body.weight(.medium))
                        Text("\(row.object.kind.rawValue) · \(row.object.authority.label)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(row.evidence.snippet.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if let uri = row.object.uri, let url = URL(string: uri) {
                            Link(uri, destination: url).font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}

struct ScoreBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
    }
}
