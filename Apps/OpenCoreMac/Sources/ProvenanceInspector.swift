import CoreModel
import CoreReason
import SwiftUI

/// Right-hand provenance and floor-object inspector (`Cmd+Opt+I`).
///
/// Clicking any claim, belief, contradiction side, or cited source anywhere in the app opens
/// this drawer so the reader can inspect the exact supporting spans, counter-evidence rows,
/// bitemporal validity window, and underlying floor `CoreObject` without losing their place.
struct ProvenanceInspector: View {
    @Environment(\.appModel) private var model
    @State private var synthesizingObjectID: String?
    @State private var objectBriefs: [String: Conversation.GroundedBrief] = [:]
    @State private var proposingObjectID: String?
    @State private var proposalStatus: String?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Evidence inspector").font(.caption.weight(.semibold))
                Spacer()
                Button {
                    model.showingInspector = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close evidence inspector")
            }
            .padding(12)
            Divider()
        Group {
            switch model.inspectorState {
            case .failed(let message):
                ContentUnavailableView("Could Not Load Provenance", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .empty:
                ContentUnavailableView(
                    "Nothing Inspected",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select any belief, claim, contradiction, or cited source to inspect its supporting spans, counter-evidence, and floor object.")
                )
            case .loading:
                ProgressView("Loading provenance…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .claim(let inspection):
                claimView(inspection)
            case .object(let inspection):
                objectView(inspection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Claim Inspection

    private func claimView(_ inspection: AppModel.ClaimInspection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Statement & Evidence", systemImage: "checkmark.seal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("CoreClaim + Evidence byte spans")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        Task { await model.startCorrection(for: inspection.row.claim) }
                    } label: {
                        Label("Correct statement", systemImage: "pencil")
                    }
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        EntityLinkChip(
                            name: inspection.row.subject,
                            entityID: inspection.row.subjectID,
                            prominent: true
                        )
                        Text(inspection.row.predicate)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let objectEntityID = inspection.row.objectEntityID {
                        EntityLinkChip(
                            name: inspection.row.value,
                            entityID: objectEntityID,
                            prominent: true
                        )
                    } else {
                        Text(inspection.row.value)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 6) {
                        Chip("authority: \(inspection.row.claim.authority.label)")
                        Chip(
                            inspection.row.claim.authority == .modelInference
                                ? "model (/fm · byte-verified)"
                                : (inspection.row.claim.derivation == .observed ? "observed (direct)" : "inferred (pattern)")
                        )
                        Chip("domain: \(inspection.row.claim.domain.rawValue)")
                        Text(String(format: "conf %.2f", inspection.row.claim.confidence))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 10)

                bitemporalCard(inspection.row.claim, belief: inspection.belief)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow \(inspection.row.subject)").font(.headline)
                    KnowledgeSubjectActions(subject: KnowledgeSubject(id: inspection.row.subjectID, name: inspection.row.subject), compact: true)
                }

                if !inspection.refuting.isEmpty {
                    evidenceSection(
                        title: "Conflicting Evidence (Stance.refutes)",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        items: inspection.refuting
                    )
                }

                evidenceSection(
                    title: "Supporting Source Spans (Stance.supports)",
                    symbol: "quote.opening",
                    tint: .accentColor,
                    items: inspection.supporting
                )
            }
            .padding(16)
        }
    }

    private func bitemporalCard(_ claim: CoreClaim, belief: Belief?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Two-Clock Timestamps (Bitemporal Window)")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                inspectorRow(
                    "Applies from (validFrom)",
                    claim.validity.validFrom.map { Self.dayFormatter.string(from: $0) } ?? "unbounded"
                )
                inspectorRow(
                    "Applies until (validTo)",
                    claim.validity.validTo.map { Self.dayFormatter.string(from: $0) } ?? "present"
                )
                inspectorRow(
                    "Learned (observedAt)",
                    Self.dayFormatter.string(from: claim.validity.observedAt)
                )
                inspectorRow(
                    "Retracted (retractedAt)",
                    claim.validity.retractedAt.map { Self.dayFormatter.string(from: $0) } ?? "still held"
                )
                if let belief {
                    inspectorRow("Recorded decision", "v\(belief.version) (\(belief.reason))")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10)
    }

    private func evidenceSection(
        title: String,
        symbol: String,
        tint: Color,
        items: [AppModel.EvidenceDetail]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).font(.caption)
                SectionLabel(title, count: items.count)
            }

            if items.isEmpty {
                Text("No evidence spans linked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if let object = item.object {
                                Button {
                                    model.inspectObject(object.id, highlight: item.evidence.snippet)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("Inspect original: \(object.title)")
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .font(.caption2)
                                    }
                                }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("inspect-original-\(object.id.value)")
                            }
                            Spacer()
                            if let range = item.evidence.range {
                                Text("bytes \(range.lowerBound)..<\(range.upperBound)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text(item.evidence.snippet)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(tint.opacity(0.08), in: .rect(cornerRadius: 6))

                        HStack {
                            Text("authority: \(item.evidence.authority.label)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if let uri = item.object?.uri, let url = URL(string: uri) {
                                Link("Open source location", destination: url)
                                    .font(.caption2)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .openCoreGlassCard(cornerRadius: 8)
                }
            }
        }
    }

    // MARK: - Object Inspection

    private func objectView(_ inspection: AppModel.ObjectInspection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Original Record (Floor Object)", systemImage: "cube.box")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Immutable CoreObject · Everything above rebuilds from here")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let uri = inspection.object.uri, let url = URL(string: uri) {
                        Link(destination: url) {
                            Label("Open Source", systemImage: "arrow.up.right.square")
                        }
                        .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(inspection.object.title)
                        .font(.headline)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        Chip("kind: \(inspection.object.kind.rawValue)")
                        Chip("domain: \(inspection.object.domain.rawValue)")
                        Chip("authority: \(inspection.object.authority.label)")
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        inspectorRow("Connector (sourceID)", inspection.object.sourceID.value)
                        inspectorRow("Source key (externalID)", inspection.object.externalID)
                        inspectorRow(
                            "Created (authoredAt)",
                            inspection.object.authoredAt.map { Self.dayFormatter.string(from: $0) } ?? "undated"
                        )
                        inspectorRow("Synced (ingestedAt)", Self.dayFormatter.string(from: inspection.object.ingestedAt))
                    }
                    .padding(.top, 4)

                    HStack(spacing: 8) {
                        Button {
                            let objID = inspection.object.id.value
                            synthesizingObjectID = objID
                            Task {
                                if let res = await model.synthesizeFloorObjectBrief(inspection) {
                                    objectBriefs[objID] = res
                                }
                                if synthesizingObjectID == objID { synthesizingObjectID = nil }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if synthesizingObjectID == inspection.object.id.value {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text("Summarize (/fm)")
                            }
                            .font(.caption2.weight(.medium))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true)
                        .disabled(synthesizingObjectID == inspection.object.id.value)

                        Button {
                            let objID = inspection.object.id.value
                            proposingObjectID = objID
                            proposalStatus = nil
                            Task {
                                do {
                                    let report = try await model.proposeClaimsForObject(inspection.object.id)
                                    guard proposingObjectID == objID else { return }
                                    let rejected = report.rejectedUnverifiedSpan + report.rejectedInvalidPredicate
                                    proposalStatus = "\(report.verifiedProposals.count) verified · \(rejected) rejected"
                                } catch {
                                    guard proposingObjectID == objID else { return }
                                    proposalStatus = "Extraction failed: \(error.localizedDescription)"
                                }
                                if proposingObjectID == objID { proposingObjectID = nil }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if proposingObjectID == inspection.object.id.value {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text("Extract Claims (/fm)")
                            }
                            .font(.caption2.weight(.medium))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton()
                        .disabled(proposingObjectID == inspection.object.id.value)
                    }
                    .padding(.top, 6)

                    if let proposalStatus {
                        Text(proposalStatus)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.purple)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 10)

                if let brief = objectBriefs[inspection.object.id.value] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(
                                "On-Device Floor Summary (\(brief.modelName))",
                                systemImage: "sparkles"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                            Spacer()
                            Button {
                                objectBriefs.removeValue(forKey: inspection.object.id.value)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(brief.text)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .openCoreGlassCard(cornerRadius: 10, tint: .purple)
                }

                if !inspection.derivedClaims.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Facts Extracted From This Item (Derived Claims)", count: inspection.derivedClaims.count)
                        ForEach(inspection.derivedClaims.prefix(20)) { row in
                            Button {
                                model.inspectClaim(row.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(row.subject).font(.caption.weight(.semibold))
                                    Text(row.predicate).font(.caption).foregroundStyle(.secondary)
                                    Text(row.value).font(.caption.weight(.medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .openCoreGlassCard(cornerRadius: 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Indexed Paragraphs (Passages / Chunks)", count: inspection.chunks.count)
                    ForEach(inspection.chunks, id: \.id) { chunk in
                        let matchesHighlight = inspection.highlight.map {
                            chunk.text.localizedCaseInsensitiveContains($0)
                        } ?? false
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("passage #\(chunk.ordinal)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("bytes \(chunk.range.lowerBound)..<\(chunk.range.upperBound)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(chunk.text)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(
                            cornerRadius: 8,
                            tint: matchesHighlight ? .accentColor : nil
                        )
                    }
                }
            }
            .padding(16)
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospaced().lineLimit(2)
        }
        .font(.caption2)
    }
}
