import CoreModel
import SwiftUI

/// Recorded evidence, delivery outcomes and uncertainty for one answer.
struct ReceiptCard: View {
    @Environment(\.appModel) private var model
    let receipt: Receipt
    var onTrace: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Header: Question Asked + Short Code + Zero-Egress Proof Badge
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label("\(receipt.isRequestAudit ? "Request audit" : "Receipt") \(receipt.shortCode)", systemImage: "receipt.fill")
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(Pastel.aqua)
                        Text(receipt.queryClass.rawValue.uppercased())
                            .openCorePastelBadge(Pastel.sky)
                        Text(receipt.outboundStatusLabel)
                            .openCorePastelBadge(receipt.hasOutboundActivity ? Pastel.rose : Pastel.ice)
                        Text(ClaimsView.formatter.string(from: receipt.createdAt))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("\"\(receipt.query)\"")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        model.askInChat(receipt.query)
                    } label: {
                        Label("Re-Ask in Chat", systemImage: "bubble.left.and.bubble.right")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(tint: Pastel.lavender, telemetryLabel: "Re-Ask Receipt Query: \(receipt.query)")

                    if let onTrace {
                        Button {
                            ActionFeedbackCenter.shared.record(
                                button: "Trace Evidence Spans (\(receipt.shortCode))",
                                command: "Store.trace(receipt: \(receipt.shortCode))",
                                outcome: "Loading ranked Floor Object evidence spans for receipt \(receipt.shortCode)...",
                                status: .completed
                            )
                            onTrace()
                        } label: {
                            Label("Trace Evidence Spans (\(receipt.evidenceAdmitted))", systemImage: "doc.text.magnifyingglass")
                                .font(.caption.weight(.bold))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Trace Evidence Spans: \(receipt.shortCode)")
                    }
                }
            }

            Text(receipt.outboundDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            // 2. Four Visual Audit Counters
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                receiptMetric("Items Scanned", value: "\(receipt.objectsSearched)", subtitle: "objectsSearched", tint: Pastel.sky)
                receiptMetric("Candidates Matched", value: "\(receipt.objectsRetrieved)", subtitle: "objectsRetrieved", tint: Pastel.aqua)
                receiptMetric(
                    "Evidence Spans Linked",
                    value: "\(receipt.evidenceAdmitted)",
                    subtitle: "evidenceAdmitted",
                    tint: Pastel.mint
                )
                receiptMetric("Graph Claims Checked", value: "\(receipt.claimsConsulted)", subtitle: "claimsConsulted", tint: Pastel.lavender)
            }

            // 3. Model, Confidence & Privacy Firewall Domains
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Prose author:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(receipt.model ?? "No model author")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(Pastel.ice)
                }

                HStack(spacing: 6) {
                    Text("Confidence:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let confidence = receipt.confidence {
                        Text(String(format: "%.0f%% (%.2f)", confidence * 100, confidence))
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(Pastel.mint)
                    } else {
                        Text("not measured (never faked)")
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                    }
                }

                if !receipt.domainsAdmitted.isEmpty {
                    HStack(spacing: 6) {
                        Text("Admitted Domains:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(receipt.domainsAdmitted.map(\.rawValue).joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(Pastel.mint)
                    }
                }

                if !receipt.domainsBlocked.isEmpty {
                    HStack(spacing: 6) {
                        Text("Blocked by Firewall:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Pastel.peach)
                        Text(receipt.domainsBlocked.map(\.rawValue).joined(separator: ", "))
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(Pastel.peach)
                    }
                }
                Spacer()
            }

            // 4. Pipeline Stage Timings
            if !receipt.stages.isEmpty {
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    Text("Stage Timings:")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(receipt.stages.enumerated()), id: \.offset) { _, stage in
                                HStack(spacing: 4) {
                                    Text(stage.name)
                                        .font(.caption2.monospaced().weight(.semibold))
                                        .foregroundStyle(Pastel.sky)
                                    Text("\(stage.milliseconds) ms")
                                        .font(.caption2.monospaced().weight(.bold))
                                        .foregroundStyle(Pastel.mint)
                                    if !stage.counters.isEmpty {
                                        Text("(\(stage.counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.05), in: .capsule)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)
    }

    private func receiptMetric(_ title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

struct TraceSheet: View {
    @Environment(\.appModel) private var model
    let rows: [AppModel.TraceRow]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Evidence behind this answer").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .openCoreGlassButton(telemetryLabel: "Close Trace Sheet")
            }
            .padding()
            Divider()

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Text("No evidence rows resolved for this receipt.")
                    Text("It reports consulting the claim graph, so there should be some. Either they were removed, or the answer was saved without them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ScoreBar(value: row.score)
                            Text(String(format: "%.3f", row.score)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                dismiss()
                                model.inspectObject(row.object.id, highlight: row.evidence.snippet)
                            } label: {
                                Label("Inspect original", systemImage: "doc.text.magnifyingglass")
                                    .font(.caption2)
                            }
                            .buttonStyle(.link)
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
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct ScoreBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Pastel.sky, Pastel.mint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 6)
    }
}
