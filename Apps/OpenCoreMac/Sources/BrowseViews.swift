import CoreModel
import SwiftUI

// MARK: - Claims

struct ClaimsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var rows: [AppModel.ClaimRow] {
        guard !filter.isEmpty else { return model.claims }
        let needle = filter.lowercased()
        return model.claims.filter {
            $0.subject.lowercased().contains(needle)
                || $0.predicate.lowercased().contains(needle)
                || $0.value.lowercased().contains(needle)
        }
    }

    var body: some View {
        Table(rows) {
            TableColumn("") { row in
                Image(systemName: row.claim.derivation == .observed ? "circle.fill" : "circle.dashed")
                    .font(.system(size: 7))
                    .foregroundStyle(row.claim.derivation == .observed ? Color.accentColor : .orange)
                    .help(row.claim.derivation == .observed ? "read directly from source data" : "inferred by OpenCore")
            }
            .width(16)

            TableColumn("Subject", value: \.subject)
            TableColumn("Predicate", value: \.predicate)
            TableColumn("Value", value: \.value)

            TableColumn("Confidence") { row in
                Text(String(format: "%.2f", row.claim.confidence)).monospaced()
            }
            .width(80)

            TableColumn("Authority") { row in
                Text(row.claim.authority.label).foregroundStyle(.secondary)
            }

            TableColumn("Valid from") { row in
                Text(row.claim.validity.validFrom.map(Self.formatter.string(from:)) ?? "unknown")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }
        .searchable(text: $filter, prompt: "Filter claims")
        .navigationTitle("Claims")
        .task { await model.loadClaims() }
        .overlay {
            if model.claims.isEmpty { EmptyState(message: "No claims yet. Sync a source first.") }
        }
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Beliefs

struct BeliefsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.beliefs) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(row.belief.version == 1 ? Color.accentColor : .orange)
                                .frame(width: 8, height: 8)
                            Rectangle().fill(.quaternary).frame(width: 1)
                        }
                        .frame(width: 8)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(row.belief.version == 1 ? "LEARNED" : "UPDATED")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(row.belief.version == 1 ? Color.accentColor : .orange)
                                Text("v\(row.belief.version)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                Text(ClaimsView.formatter.string(from: row.belief.decidedAt))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(row.subject) \(row.predicate) → \(row.value)").font(.callout)
                            Text(row.belief.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Beliefs")
        .task { await model.loadBeliefs() }
        .overlay {
            if model.beliefs.isEmpty { EmptyState(message: "No beliefs recorded yet.") }
        }
    }
}

// MARK: - Contradictions

struct ContradictionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(model.contradictions) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(row.contradiction.kind.rawValue)
                                .font(.caption.monospaced())
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(row.contradiction.resolution.rawValue)
                                .font(.caption.weight(.semibold).monospaced())
                                .foregroundStyle(row.contradiction.resolution == .unresolved ? .orange : .secondary)
                        }
                        Text(row.contradiction.reason).font(.callout).foregroundStyle(.secondary)

                        ForEach(Array(row.sides.enumerated()), id: \.offset) { _, side in
                            ContradictionSideRow(label: side.label, text: side.text, kept: side.kept)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
                }
            }
            .padding(24)
        }
        .navigationTitle("Contradictions")
        .task { await model.loadContradictions() }
        .overlay {
            if model.contradictions.isEmpty {
                EmptyState(message: "No contradictions detected.\nThey appear when a source changes what it says about something.")
            }
        }
    }
}

/// Split out of `ContradictionsView` because the inline version exceeded the type
/// checker's budget. Ternaries producing different `ShapeStyle` types inside a `ForEach`
/// inside a `LazyVStack` is reliably the shape that does it.
private struct ContradictionSideRow: View {
    let label: String
    let text: String
    let kept: Bool

    private var labelColor: Color { kept ? .accentColor : .secondary }
    private var textColor: Color { kept ? .primary : .secondary }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(labelColor)
            Text(text)
                .font(.caption)
                .strikethrough(label == "retired")
                .foregroundStyle(textColor)
        }
    }
}

// MARK: - Receipts

struct ReceiptsView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Receipt?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.receipts) { receipt in
                    ReceiptCard(receipt: receipt) {
                        Task {
                            await model.loadTrace(for: receipt)
                            selected = receipt
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Receipts")
        .task { await model.loadReceipts() }
        .sheet(item: $selected) { _ in TraceSheet(rows: model.traceRows) }
        .overlay {
            if model.receipts.isEmpty { EmptyState(message: "No receipts yet. Ask something.") }
        }
    }
}

extension Receipt: @retroactive Identifiable {}

// MARK: - Sources

struct SourcesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources").font(.title2.weight(.semibold))
                    Text("Objects are the floor. Everything above them can be rebuilt from here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.syncGitHub() }
                } label: {
                    Label("Sync GitHub", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isWorking)
            }

            if model.sources.isEmpty {
                Text("No sources connected. GitHub uses the token from `gh auth login` or GITHUB_TOKEN.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName).font(.body.weight(.medium))
                            Text("default authority: \(source.defaultAuthority.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(source.lastSyncedAt.map { "synced \(ClaimsView.formatter.string(from: $0))" } ?? "never synced")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
                }
            }

            if !model.countsByKind.isEmpty {
                Divider()
                Text("Stored objects").font(.subheadline.weight(.semibold))
                ForEach(model.countsByKind, id: \.0) { kind, count in
                    HStack {
                        Text(kind.rawValue).font(.callout)
                        Spacer()
                        Text("\(count)").font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Sources")
        .task { await model.refresh() }
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }
}

// MARK: - Shared

struct EmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
