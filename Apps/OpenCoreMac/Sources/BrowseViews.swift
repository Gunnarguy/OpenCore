import CoreIngest
import CoreModel
import CoreReason
import SwiftUI

// MARK: - 1. Claims (Extracted Facts & Statements Explorer)

struct ClaimsView: View {
    @Environment(\.appModel) private var model
    @State private var filter = ""
    @State private var selectedOriginFilter: String = "all" // "all", "observed", "inferred", "model"
    @State private var selectedPredicateFilter: String?
    @State private var showAsTable = false
    @State private var correcting: AppModel.ClaimRow?

    private var loadedClaims: [AppModel.ClaimRow] {
        guard let subject = model.claimsSubject else { return model.claims }
        return model.subjectClaims.filter { $0.subjectID == subject.id }
    }

    private var topPredicates: [(String, Int)] {
        var counts: [String: Int] = [:]
        for r in loadedClaims {
            counts[r.predicate, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
    }

    private var rows: [AppModel.ClaimRow] {
        var list = loadedClaims
        switch selectedOriginFilter {
        case "observed":
            list = list.filter { $0.claim.derivation == .observed && $0.claim.authority != .modelInference }
        case "inferred":
            list = list.filter { $0.claim.derivation != .observed && $0.claim.authority != .modelInference }
        case "model":
            list = list.filter { $0.claim.authority == .modelInference }
        default:
            break
        }
        if let pred = selectedPredicateFilter {
            list = list.filter { $0.predicate == pred }
        }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.subject.lowercased().contains(needle)
                || $0.predicate.lowercased().contains(needle)
                || $0.value.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Regression: Knowledge Graph embeds this view outside Root's Claims banner.
            if model.selectedSection != .claims, let subject = model.claimsSubject {
                KnowledgeSubjectBanner(subject: subject) { model.claimsSubject = nil }
            }
            claimsHeaderDeck
            Divider()

            if showAsTable {
                claimsSpreadsheetTable
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if rows.isEmpty {
                            Text(loadedClaims.isEmpty ? "No current statements loaded for this view. Check Sources or inspect an original record; not every record produces a statement." : "No statements match these filters. Clear the search or change the origin and property filters.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                        ForEach(rows) { row in
                            ClaimCardView(
                                row: row,
                                onInspect: { model.inspectClaim(row.id) },
                                onCorrect: {
                                    correcting = row
                                    ActionFeedbackCenter.shared.record(
                                        button: "Open Fact Correction Sheet",
                                        command: "ClaimsView.correcting = \(row.subject) · \(row.predicate)",
                                        outcome: "Opened correction editor for '\(row.subject) \(row.predicate) = \(row.value)'.",
                                        status: .completed
                                    )
                                }
                            )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1440, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter statements by subject, property, or value")
        .sheet(item: $correcting) { CorrectionSheet(row: $0) }
        .navigationTitle("Claims")
        .task(id: KnowledgeBrowseKey(generation: model.dataGeneration, subject: model.claimsSubject)) {
            await model.loadClaims(for: model.claimsSubject)
        }
        .onChange(of: model.claimsSubject) { _, newSubject in
            if newSubject != nil {
                filter = ""
                selectedOriginFilter = "all"
                selectedPredicateFilter = nil
            }
        }
    }

    private var claimsHeaderDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Label("Extracted Statements (Claims)", systemImage: "list.bullet.rectangle")
                            .font(.headline)
                            .foregroundStyle(Pastel.butter)
                        Text("\(rows.count) of \(loadedClaims.count) LOADED STATEMENTS")
                            .openCorePastelBadge(Pastel.mint)
                    }
                    Text("Select a statement → Inspect evidence → Open its original record. Correct statement records a revision. The unscoped view loads up to 400 current statements; a subject view queries that subject directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showAsTable.toggle()
                    ActionFeedbackCenter.shared.record(
                        button: showAsTable ? "Switch Claims to Table View" : "Switch Claims to Card View",
                        command: "ClaimsView.showAsTable = \(showAsTable)",
                        outcome: "Switched Claims presentation to \(showAsTable ? "multi-column spreadsheet table" : "visual fact cards").",
                        status: .completed
                    )
                } label: {
                    Label(showAsTable ? "Visual Cards" : "Spreadsheet Table", systemImage: showAsTable ? "rectangle.grid.1x2" : "tablecells")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.sky, telemetryLabel: "Toggle Claims View Mode")

                Button {
                    Task {
                        let start = Date()
                        await model.loadClaims(for: model.claimsSubject)
                        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                        ActionFeedbackCenter.shared.record(
                            button: "Reload Claims Table",
                            command: model.claimsSubject == nil ? "Store.allClaims(limit: 400)" : "Store.claims(subject:)",
                            outcome: "Reloaded \(loadedClaims.count) statements for this view in \(ms) ms.",
                            status: .completed,
                            durationMs: ms
                        )
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(telemetryLabel: "Reload Claims Table")
            }

            // Origin & Predicate Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    originPill("all", label: "All Origins (\(loadedClaims.count))", tint: Pastel.ice)
                    originPill("observed", label: "● Observed in Files", tint: Pastel.mint)
                    originPill("inferred", label: "○ Inferred Pattern", tint: Pastel.peach)
                    originPill("model", label: "✦ On-Device AI (/fm)", tint: Pastel.lavender)

                    Divider().frame(height: 18)

                    ForEach(topPredicates, id: \.0) { pred, count in
                        let isSel = selectedPredicateFilter == pred
                        Button {
                            selectedPredicateFilter = isSel ? nil : pred
                            ActionFeedbackCenter.shared.record(
                                button: isSel ? "Clear Property Filter" : "Filter Claims by Property: \(pred)",
                                command: "selectedPredicateFilter = \(isSel ? "nil" : "'\(pred)'")",
                                outcome: isSel ? "Showing all properties." : "Filtered Claims to property '\(pred)' (\(count) matching facts).",
                                status: .completed
                            )
                        } label: {
                            Text("\(pred) (\(count))")
                                .font(.caption2.monospaced().weight(isSel ? .bold : .medium))
                                .foregroundStyle(isSel ? Pastel.sky : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(isSel ? Pastel.sky.opacity(0.20) : Color.primary.opacity(0.05), in: .capsule)
                                .overlay {
                                    Capsule().strokeBorder(isSel ? Pastel.sky : Color.primary.opacity(0.12), lineWidth: 0.8)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func originPill(_ id: String, label: String, tint: Color) -> some View {
        let isSel = selectedOriginFilter == id
        return Button {
            selectedOriginFilter = id
            ActionFeedbackCenter.shared.record(
                button: "Filter Claims Origin -> \(label)",
                command: "selectedOriginFilter = '\(id)'",
                outcome: "Filtered Claims list to origin '\(label)' (\(rows.count) claims shown).",
                status: .completed
            )
        } label: {
            Text(label)
                .font(.caption.weight(isSel ? .bold : .medium))
                .foregroundStyle(isSel ? tint : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSel ? tint.opacity(0.20) : Color.primary.opacity(0.05), in: .capsule)
                .overlay {
                    Capsule().strokeBorder(isSel ? tint : Color.primary.opacity(0.12), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }

    private var claimsSpreadsheetTable: some View {
        Table(rows) {
            TableColumn("Origin") { row in
                let isModel = row.claim.authority == .modelInference
                let isObserved = row.claim.derivation == .observed
                let symbol = isModel ? "sparkles" : (isObserved ? "circle.fill" : "circle.dashed")
                let color: Color = isModel ? Pastel.lavender : (isObserved ? Pastel.mint : Pastel.peach)
                let label = isModel ? "model (/fm)" : (isObserved ? "observed" : "inferred")
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 7))
                        .foregroundStyle(color)
                    Text(label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(color)
                }
            }
            .width(96)

            TableColumn("Subject (Thing)") { row in
                EntityLinkChip(name: row.subject, entityID: row.subjectID)
            }
            TableColumn("Property (Predicate)", value: \.predicate)
            TableColumn("Value (Fact)") { row in
                if let objectEntityID = row.objectEntityID {
                    EntityLinkChip(name: row.value, entityID: objectEntityID)
                } else {
                    Text(row.value).textSelection(.enabled)
                }
            }
            TableColumn("Conf") { row in
                Text(String(format: "%.0f%%", row.claim.confidence * 100)).monospaced()
            }
            .width(60)
            TableColumn("Authority") { row in
                Text(row.claim.authority.label).foregroundStyle(.secondary)
            }
            TableColumn("Valid From") { row in
                Text(row.claim.validity.validFrom.map(Self.formatter.string(from:)) ?? "recorded")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            TableColumn("Actions") { row in
                HStack(spacing: 6) {
                    Button("Evidence") { model.inspectClaim(row.id) }
                        .accessibilityIdentifier("inspect-claim-\(row.id.value)")
                        .buttonStyle(.link)
                        .font(.caption)
                    Button("Correct") { correcting = row }
                        .controlSize(.small)
                }
            }
            .width(136)
        }
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ClaimCardView: View {
    let row: AppModel.ClaimRow
    let onInspect: () -> Void
    let onCorrect: () -> Void

    private var isModel: Bool { row.claim.authority == .modelInference }
    private var isObserved: Bool { row.claim.derivation == .observed }
    private var originLabel: String { isModel ? "✦ AI Extracted (/fm)" : (isObserved ? "● Observed in File" : "○ Inferred Pattern") }
    private var originTint: Color { isModel ? Pastel.lavender : (isObserved ? Pastel.mint : Pastel.peach) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(originLabel)
                        .openCorePastelBadge(originTint)
                    Text("Authority: \(row.claim.authority.label)")
                        .openCorePastelBadge(Pastel.sky)
                    Text(String(format: "Confidence: %.0f%%", row.claim.confidence * 100))
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(Pastel.mint)
                    if let validFrom = row.claim.validity.validFrom {
                        Text("Date: \(ClaimsView.formatter.string(from: validFrom))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    EntityLinkChip(name: row.subject, entityID: row.subjectID, prominent: true)
                    Text(row.predicate)
                        .font(.callout.monospaced().weight(.bold))
                        .foregroundStyle(Pastel.butter)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Pastel.butter.opacity(0.14), in: .capsule)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    if let objectEntityID = row.objectEntityID {
                        EntityLinkChip(name: row.value, entityID: objectEntityID, prominent: true)
                    } else {
                        Text(row.value)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onInspect) {
                    Label("Inspect evidence", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Inspect Claim Quote: \(row.subject) \(row.predicate)")
                .accessibilityLabel("Inspect evidence for \(row.subject): \(row.predicate) \(row.value)")
                .accessibilityIdentifier("inspect-claim-\(row.id.value)")

                Button(action: onCorrect) {
                    Label("Correct statement", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.butter, telemetryLabel: "Correct Fact: \(row.subject) \(row.predicate)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: originTint)
    }
}

// MARK: - 2. Beliefs (Active Truth & Decision Log)

struct BeliefsView: View {
    @Environment(\.appModel) private var model
    @State private var search = ""
    @State private var onlyRevisions = false

    private var visibleBeliefs: [AppModel.BeliefRow] {
        var list = onlyRevisions ? model.beliefs.filter { $0.belief.version > 1 } : model.beliefs
        if let subject = model.beliefsSubject { list = list.filter { $0.subjectID == subject.id } }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.subject.lowercased().contains(needle)
                || $0.predicate.lowercased().contains(needle)
                || $0.value.lowercased().contains(needle)
                || $0.belief.reason.lowercased().contains(needle)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // Orientation Header Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Label("Decisions & Revisions (Beliefs)", systemImage: "checkmark.seal.fill")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(Pastel.mint)
                                Text("\(visibleBeliefs.count) BELIEF DECISIONS")
                                    .openCorePastelBadge(Pastel.sky)
                            }
                            Text("Each row records a selection at a point in time, including prior versions. Inspect evidence to see the selected statement and its sources; open Claims to compare alternatives.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button {
                                onlyRevisions.toggle()
                                ActionFeedbackCenter.shared.record(
                                    button: onlyRevisions ? "Filter Beliefs -> Revisions Only (v2+)" : "Filter Beliefs -> All Versions",
                                    command: "BeliefsView.onlyRevisions = \(onlyRevisions)",
                                    outcome: onlyRevisions
                                        ? "Showing \(visibleBeliefs.count) revised belief(s) (version >= v2) that superseded an earlier fact."
                                        : "Showing all \(visibleBeliefs.count) recorded belief decisions across v1 and v2+.",
                                    status: .completed
                                )
                            } label: {
                                Label(onlyRevisions ? "Showing Revisions (v2+)" : "Filter to Revisions (v2+)", systemImage: "clock.arrow.2.circlepath")
                                    .font(.caption.weight(.bold))
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(prominent: onlyRevisions, tint: Pastel.peach, telemetryLabel: "Filter Beliefs to Revisions")

                            Button {
                                Task {
                                    let start = Date()
                                    await model.loadBeliefs()
                                    let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                                    ActionFeedbackCenter.shared.record(
                                        button: "Refresh Beliefs Table",
                                        command: "Store.beliefsDecided(since: .distantPast)",
                                        outcome: "Loaded \(model.beliefs.count) belief decisions from SQLite in \(ms) ms.",
                                        status: .completed,
                                        durationMs: ms
                                    )
                                }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(telemetryLabel: "Refresh Beliefs Table")
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)

                if visibleBeliefs.isEmpty {
                    Text("No recorded decisions match this view. A searchable record or extracted statement does not always produce a belief decision.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
                ForEach(visibleBeliefs) { row in
                    let isRevision = row.belief.version > 1
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(isRevision ? "RECORDED REVISION v\(row.belief.version)" : "FIRST RECORDED DECISION v1")
                                    .openCorePastelBadge(isRevision ? Pastel.peach : Pastel.mint)
                                Text("Authority: \(row.belief.authority.label)")
                                    .openCorePastelBadge(Pastel.sky)
                                Text("Decided: \(ClaimsView.formatter.string(from: row.belief.decidedAt))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 8) {
                                EntityLinkChip(name: row.subject, entityID: row.subjectID, prominent: true)
                                Text(row.predicate)
                                    .font(.callout.monospaced().weight(.bold))
                                    .foregroundStyle(Pastel.butter)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Pastel.butter.opacity(0.14), in: .capsule)
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                if let objectEntityID = row.objectEntityID {
                                    EntityLinkChip(name: row.value, entityID: objectEntityID, prominent: true)
                                } else {
                                    Text(row.value)
                                        .font(.callout.weight(.bold))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                            }

                            Text("Why OpenCore chose this: \(row.belief.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            model.inspectClaim(row.belief.claimID)
                        } label: {
                            Label("Inspect evidence", systemImage: "doc.text.magnifyingglass")
                                .font(.caption.weight(.bold))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Inspect Belief Claim: \(row.subject) \(row.predicate)")
                        .accessibilityLabel("Inspect decision evidence for \(row.subject): \(row.predicate) \(row.value), version \(row.belief.version)")
                        .accessibilityIdentifier("inspect-belief-\(row.id.value)")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .openCoreGlassCard(cornerRadius: 12, tint: isRevision ? Pastel.peach : Pastel.mint)
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Regression: the embedded Beliefs tab must expose its retained subject filter.
            if model.selectedSection != .beliefs, let subject = model.beliefsSubject {
                KnowledgeSubjectBanner(subject: subject) { model.beliefsSubject = nil }
            }
        }
        .searchable(text: $search, prompt: "Search recorded belief decisions by subject, property, or value")
        .navigationTitle("Beliefs")
        .task(id: model.dataGeneration) { await model.loadBeliefs() }
        .onChange(of: model.beliefsSubject) { _, newSubject in
            if newSubject != nil { search = ""; onlyRevisions = false }
        }
    }
}

// MARK: - 3. Reality Checks & Diffs (ContradictionsView)

struct ContradictionsView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var analyzingID: String?
    @State private var analyses: [String: Conversation.GroundedBrief] = [:]
    @State private var showHeuristicDiffs = true

    var body: some View {
        let staleRepos = model.fleetCards.filter(\.isHandoffStale)
        let dirtyRepos = model.fleetCards.filter(\.isDirty)
        let usbBottlenecks = settings.usbHighlightBottlenecks ? HardwareInspectorManager.shared.performanceLimitedDevices : []
        let singleAgentDocRepos = model.fleetCards.filter { $0.hasClaudeMD != $0.hasAgentsMD }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                // Top Orientation & Re-Scan Deck
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label("Reality Checks, Handoff Drift & Document Fact Diffs", systemImage: "checkmark.shield.fill")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Pastel.mint)
                            Text("\(staleRepos.count + dirtyRepos.count + usbBottlenecks.count + model.contradictions.count) TOTAL FINDINGS")
                                .openCorePastelBadge(Pastel.butter)
                        }
                        Text("What this screen does: Compares live Git HEAD commits against recorded STATE.md handoffs, checks working tree cleanliness, verifies CLAUDE.md/AGENTS.md parity, checks USB negotiated speeds against hardware descriptors, and surfaces conflicting claims across synced documents.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            let start = Date()
                            ActionFeedbackCenter.shared.record(
                                button: "Re-Scan All Reality Checks",
                                command: "refreshFleetStatus() + HardwareInspector.refresh() + loadContradictions()",
                                outcome: "Scanning 24 Git repositories, IOKit USB tree, and SQLite claim conflicts...",
                                status: .running
                            )
                            await model.refreshFleetStatus()
                            HardwareInspectorManager.shared.refreshAll()
                            await model.loadContradictions()
                            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                            ActionFeedbackCenter.shared.record(
                                button: "Re-Scan All Reality Checks",
                                command: "Git HEAD + STATE.md + IOKit USB + SQLite contradictions",
                                outcome: "Reality check complete in \(ms) ms: \(staleRepos.count) stale handoff(s), \(dirtyRepos.count) dirty repo(s), \(usbBottlenecks.count) USB bottleneck(s), \(model.contradictions.count) document diff(s).",
                                status: .completed,
                                durationMs: ms
                            )
                        }
                    } label: {
                        Label("Re-Scan All Checks Now", systemImage: "arrow.clockwise.circle.fill")
                            .font(.caption.weight(.bold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Re-Scan All Reality Checks")
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)

                // 1. Undeniable Ground-Truth Reality Checks
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("1. Undeniable Ground-Truth Reality Checks (100% Measured)", systemImage: "checkmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(Pastel.mint)
                        Spacer()
                        Text("[git rev-parse HEAD · STATE.md · CLAUDE.md/AGENTS.md · IOKit USB]")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if staleRepos.isEmpty && dirtyRepos.isEmpty && usbBottlenecks.isEmpty && singleAgentDocRepos.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Pastel.mint)
                            Text("All repositories match their recorded STATE.md commits, working trees are clean, CLAUDE.md/AGENTS.md are paired, and all USB links are running at full spec.")
                                .font(.callout)
                        }
                        .padding(10)
                        .openCoreGlassCard(cornerRadius: 8, tint: .green)
                    } else {
                        ForEach(staleRepos) { repo in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "arrow.triangle.branch")
                                    .foregroundStyle(Pastel.peach)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(repo.name)
                                            .font(.callout.weight(.bold))
                                        Text("Git HEAD: \(repo.head) (\(repo.headWhen))")
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(Pastel.aqua)
                                        Text("vs")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text("\(repo.shortStateRel): \(repo.stateCommit.isEmpty ? "unrecorded" : repo.stateCommit)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Pastel.peach)
                                    }
                                    Text(repo.handoffProvenanceHelp)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if repo.stateExists {
                                    Button("Open STATE.md") {
                                        OperatorConsoleService.openFile(path: repo.statePath)
                                        ActionFeedbackCenter.shared.record(
                                            button: "Open STATE.md (\(repo.name))",
                                            command: "NSWorkspace.open(\(repo.statePath))",
                                            outcome: "Opened \(repo.statePath) in default editor.",
                                            status: .completed
                                        )
                                    }
                                    .controlSize(.small)
                                    .openCoreGlassButton(telemetryLabel: "Open STATE.md: \(repo.name)")
                                }
                                Button("Inspect Card") {
                                    Task { await model.auditRepository(repo) }
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(prominent: true, telemetryLabel: "Audit Repo: \(repo.name)")
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 8, tint: .orange)
                        }

                        ForEach(dirtyRepos) { repo in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "pencil.and.list.clipboard")
                                    .foregroundStyle(Pastel.aqua)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(repo.name)
                                            .font(.callout.weight(.bold))
                                        Text("\(repo.dirty) uncommitted file(s) on disk")
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(Pastel.aqua)
                                    }
                                    Text("Modified: \(repo.dirtySample.isEmpty ? "working tree changes" : repo.dirtySample.joined(separator: ", "))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open Terminal") {
                                    OperatorConsoleService.openInTerminal(rootPath: repo.root)
                                    ActionFeedbackCenter.shared.record(
                                        button: "Open Terminal (\(repo.name))",
                                        command: "open -a Terminal \(repo.root)",
                                        outcome: "Opened macOS Terminal at \(repo.root).",
                                        status: .completed
                                    )
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(telemetryLabel: "Open Terminal: \(repo.name)")
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 8, tint: .cyan)
                        }

                        ForEach(singleAgentDocRepos) { repo in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(Pastel.lavender)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(repo.name)
                                            .font(.callout.weight(.bold))
                                        Text(repo.hasClaudeMD ? "Has CLAUDE.md · Missing AGENTS.md" : "Has AGENTS.md · Missing CLAUDE.md")
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(Pastel.lavender)
                                    }
                                    Text("Cross-agent instruction parity check across Claude Code, Codex, and Antigravity.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Reveal Repo") {
                                    OperatorConsoleService.revealInFinder(path: repo.root)
                                    ActionFeedbackCenter.shared.record(
                                        button: "Reveal Repo in Finder (\(repo.name))",
                                        command: "NSWorkspace.selectFile(\(repo.root))",
                                        outcome: "Revealed \(repo.root) in Finder.",
                                        status: .completed
                                    )
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(telemetryLabel: "Reveal Repo: \(repo.name)")
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 8, tint: .purple)
                        }

                        ForEach(usbBottlenecks) { dev in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "cable.connector.horizontal")
                                    .foregroundStyle(Pastel.peach)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(dev.name)
                                            .font(.callout.weight(.bold))
                                        Text("Negotiated: \(dev.negotiatedSpeedDescription)")
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(Pastel.peach)
                                        Text("vs Descriptor: USB \(dev.usbVersion)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Pastel.mint)
                                    }
                                    Text(dev.performanceDiscrepancyReason ?? "Running below advertised USB capability.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open USB Topology") {
                                    model.navigate(to: .hardwareUSB)
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(prominent: true, telemetryLabel: "Open USB Topology")
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 8, tint: .orange)
                        }
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 12)

                // 2. Document Claim Conflicts
                DisclosureGroup(isExpanded: $showHeuristicDiffs) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("When two synced markdown documents or commits state different values for the same field (such as status, objective, or verify_command), both values are listed below so you can inspect the source quote or click 'Keep this' to lock in the winner.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(model.contradictions) { row in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    if let subjectID = row.subjectID, let subjectName = row.subjectName {
                                        EntityLinkChip(name: subjectName, entityID: subjectID)
                                    }
                                    Text(row.contradiction.kind.rawValue)
                                        .font(.caption.monospaced())
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    Text(row.contradiction.resolution.rawValue.uppercased())
                                        .openCorePastelBadge(row.contradiction.resolution == .unresolved ? Pastel.peach : Pastel.mint)
                                    Spacer()
                                    Button {
                                        let rowID = row.id.value
                                        analyzingID = rowID
                                        Task {
                                            let start = Date()
                                            ActionFeedbackCenter.shared.record(
                                                button: "Compare Conflicting Sources (/usr/bin/fm)",
                                                command: "AppModel.synthesizeContradictionAnalysis(\(rowID.prefix(8)))",
                                                outcome: "Comparing Side A and Side B quotes with on-device FoundationModels...",
                                                status: .running
                                            )
                                            if let res = await model.synthesizeContradictionAnalysis(row) {
                                                analyses[rowID] = res
                                                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                                                ActionFeedbackCenter.shared.record(
                                                    button: "Compare Conflicting Sources (/usr/bin/fm)",
                                                    command: "FoundationModels grounded comparison",
                                                    outcome: "Synthesized side-by-side conflict explanation in \(ms) ms.",
                                                    status: .completed,
                                                    durationMs: ms
                                                )
                                            }
                                            if analyzingID == rowID { analyzingID = nil }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if analyzingID == row.id.value {
                                                ProgressView().controlSize(.mini)
                                            } else {
                                                Image(systemName: "sparkles")
                                            }
                                            Text("Compare Sources (/usr/bin/fm)")
                                        }
                                        .font(.caption2.weight(.medium))
                                    }
                                    .controlSize(.small)
                                    .openCoreGlassButton(telemetryLabel: "Compare Sources (/fm)")
                                    .disabled(analyzingID == row.id.value)
                                }
                                Text(row.contradiction.reason).font(.callout).foregroundStyle(.secondary)

                                if let analysis = analyses[row.id.value] {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Label(
                                                "On-Device Source Comparison (\(analysis.modelName))",
                                                systemImage: "sparkles"
                                            )
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Pastel.lavender)
                                            Spacer()
                                            Button {
                                                analyses.removeValue(forKey: row.id.value)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Text(analysis.text)
                                            .font(.caption)
                                            .textSelection(.enabled)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .openCoreGlassCard(cornerRadius: 8, tint: .purple)
                                }

                                ForEach(row.sides) { side in
                                    ContradictionSideRow(
                                        side: side,
                                        isUnresolved: row.contradiction.resolution == .unresolved,
                                        onInspect: { model.inspectClaim(side.claim.id) },
                                        onKeep: {
                                            Task { await model.resolveContradiction(row.contradiction, keeping: side) }
                                        }
                                    )
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .openCoreGlassCard(cornerRadius: 12)
                        }
                    }
                } label: {
                    HStack {
                        Label("2. Document & Commit Fact Diffs (\(model.contradictions.count) Compared)", systemImage: "doc.text.magnifyingglass")
                            .font(.headline)
                            .foregroundStyle(Pastel.lavender)
                        Spacer()
                        Text("\(model.contradictions.count) diffs")
                            .openCorePastelBadge(Pastel.lavender)
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 12)
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Reality Checks & Diffs")
        .task(id: model.dataGeneration) { await model.loadContradictions() }
    }
}

private struct ContradictionSideRow: View {
    let side: AppModel.ContradictionSide
    let isUnresolved: Bool
    let onInspect: () -> Void
    let onKeep: () -> Void

    private var labelColor: Color { side.kept ? Pastel.mint : .secondary }
    private var textColor: Color { side.kept ? .primary : .secondary }

    var body: some View {
        HStack(spacing: 8) {
            Text(side.label.uppercased())
                .font(.caption2.weight(.bold))
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(labelColor)
            Text(side.text)
                .font(.caption)
                .strikethrough(side.label == "retired")
                .foregroundStyle(textColor)
            Spacer()
            Button("Inspect Quote", action: onInspect)
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.sky, telemetryLabel: "Inspect Conflict Quote")
            if isUnresolved {
                Button("Keep this", action: onKeep)
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Keep Conflict Side: \(side.value)")
            }
        }
    }
}

// MARK: - 4. Receipts (Zero-Egress Audit Log)

struct ReceiptsView: View {
    @Environment(\.appModel) private var model
    @State private var selected: Receipt?
    @State private var search: String = ""

    private var filteredReceipts: [Receipt] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.receipts }
        return model.receipts.filter {
            $0.query.lowercased().contains(needle)
                || $0.shortCode.lowercased().contains(needle)
                || $0.queryClass.rawValue.lowercased().contains(needle)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Orientation Header Card
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label("Answer Receipts", systemImage: "receipt.fill")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Pastel.aqua)
                            Text("\(model.receipts.count) AUDITED QUERIES")
                                .openCorePastelBadge(Pastel.mint)
                            Text("Local query audit")
                                .openCorePastelBadge(Pastel.sky)
                        }
                        Text("Open a receipt to inspect the recorded evidence, privacy admission and timings for that answer path. To create one, run the sample query or ask in Grounded Chat; unreceipted model supplements are labeled separately.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            let start = Date()
                            ActionFeedbackCenter.shared.record(
                                button: "Generate Sample Audited Query Receipt",
                                command: "Reasoner.answer(\"What is OpenCore's status?\")",
                                outcome: "Running grounded on-device query and recording a query audit receipt...",
                                status: .running
                            )
                            guard let answer = await model.reasonAnswer("What is OpenCore's current status and objective?", persistReceipt: true) else {
                                ActionFeedbackCenter.shared.record(
                                    button: "Generate Sample Audited Query Receipt", command: "Reasoner.answer",
                                    outcome: "The query did not return an answer or a saved receipt. Check the store status and retry.", status: .warning
                                )
                                return
                            }
                            await model.loadReceipts()
                            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                            ActionFeedbackCenter.shared.record(
                                button: "Generate Sample Audited Query Receipt",
                                command: "Reasoner.answer -> receipt \(answer.receipt.shortCode)",
                                outcome: "Saved receipt \(answer.receipt.shortCode) in \(ms) ms; \(answer.receipt.objectsTransmitted) source objects transmitted by the answer path.",
                                status: .completed,
                                durationMs: ms
                            )
                        }
                    } label: {
                        Label("Run Sample Audited Query", systemImage: "plus.circle.fill")
                            .font(.caption.weight(.bold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Run Sample Audited Query")
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.aqua)

                if filteredReceipts.isEmpty {
                    Text(model.receipts.isEmpty ? "No receipts yet. Run the sample audited query above, or ask a question in Grounded Chat." : "No receipts match this search. Try the question text or a receipt code.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
                ForEach(filteredReceipts) { receipt in
                    ReceiptCard(receipt: receipt, onTrace: receipt.answeredFromClaims ? {
                        Task {
                            await model.loadTrace(for: receipt)
                            selected = receipt
                        }
                    } : nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $search, prompt: "Filter receipts by question, short code (oc_...), or query class")
        .navigationTitle("Receipts")
        .task(id: model.dataGeneration) { await model.loadReceipts() }
        .sheet(item: $selected) { _ in TraceSheet(rows: model.traceRows) }
    }
}

// MARK: - 5. Sources & Connectors

struct SourcesView: View {
    @Environment(\.appModel) private var model
    @State private var folderDomain: Domain = .personal
    @State private var showingFolderPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label("Data Sources, Connectors & Semantic Index", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Pastel.sky)
                            Text("\(model.sources.count) CONNECTED SOURCES")
                                .openCorePastelBadge(Pastel.mint)
                        }
                        Text("What this screen does: Connects OpenCore to your local GitHub repositories, Claude/Codex/Antigravity agent memories, Apple Notes, Calendar, Reminders, Health, and custom folders. Click any connector tile below to sync it now and watch live telemetry at the top of the window.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.syncAllWorkspaceAndSources() }
                        } label: {
                            Label("Sync All Sources", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.bold))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Sync All Sources")
                        .disabled(isWorking)

                        Button {
                            model.navigate(to: .mcp)
                        } label: {
                            Label("Manage MCP Servers", systemImage: "powerplug.fill")
                                .font(.caption.weight(.medium))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(tint: Pastel.lavender, telemetryLabel: "Open MCP Servers")
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)

                ConnectorGrid(isWorking: isWorking, showingFolderPicker: $showingFolderPicker, folderDomain: $folderDomain)

                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title3)
                        .foregroundStyle(Pastel.sky)
                        .frame(width: 34, height: 34)
                        .background(Pastel.sky.opacity(0.14), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drag and Drop Files, Multi-Page PDFs, or Folders Anywhere")
                            .font(.callout.weight(.semibold))
                        Text("Drop any PDF, Markdown note, source file, or project folder onto the OpenCore window to extract passages, entities, and claims on device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Folder…") {
                        showingFolderPicker = true
                        ActionFeedbackCenter.shared.record(
                            button: "Choose Custom Folder to Ingest",
                            command: "NSOpenPanel(allowedContentTypes: [.folder])",
                            outcome: "Opened macOS folder picker to ingest a directory under domain '\(folderDomain.rawValue)'.",
                            status: .completed
                        )
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.sky, telemetryLabel: "Choose Folder to Sync")
                }
                .padding(14)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.sky)

                EmbeddingPanel(isWorking: isWorking)

                if model.sources.isEmpty {
                    Text("No sources connected. GitHub uses the token from `gh auth login` or GITHUB_TOKEN.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connected Sources (\(model.sources.count))")
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
                            ForEach(model.sources) { source in
                                HStack(spacing: 12) {
                                    Image(systemName: source.handle.hasPrefix("mcp:") ? "powerplug.fill" : "cylinder.split.1x2.fill")
                                        .font(.callout)
                                        .foregroundStyle(Pastel.mint)
                                        .frame(width: 32, height: 32)
                                        .background(Pastel.mint.opacity(0.14), in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.displayName).font(.callout.weight(.bold))
                                        Text("Authority: \(source.defaultAuthority.label) · Domain: \(source.defaultDomain.rawValue)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(source.handle != "apple-notes" && source.kind == .manual ? "local record" : (source.lastSyncedAt.map { "synced \(ClaimsView.formatter.string(from: $0))" } ?? "never synced"))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(Pastel.aqua)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .openCoreGlassCard(cornerRadius: 10)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Sources already observes AppModel.sources. A generation-keyed refresh here would
        // increment the same generation, cancel itself, and restart forever.
        .navigationTitle("Sources")
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let domain = folderDomain
            Task { await model.syncFolder(url, domain: domain) }
        }
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }
}

/// How fresh each source is, and why one is not. Shows with the schedule off as well: a sync run
/// by hand has a result too, and that is when someone most wants to see it.
private struct SyncScheduleSummary: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Sync automatically while OpenCore is running", isOn: Bindable(settings).scheduledSyncEnabled)
                .font(.caption.weight(.semibold))
            ForEach(model.reportedJobs, id: \.self) { job in
                SyncResultRow(job: job, record: model.scheduleRecords[job])
            }
            Text("Calendar and Reminders can only be read by this app, so they stay fresh only while it runs. Notes joins the schedule after you sync it once yourself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10)
    }
}

/// One source's last result: when it last worked, what that found, and what went wrong since.
private struct SyncResultRow: View {
    let job: SyncSchedule.Job
    let record: SyncSchedule.Record?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(job.label).font(.caption)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let error = record?.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(error)
                }
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        guard let success = record?.lastSuccess else {
            if let result = record?.lastResult { return "\(result), incomplete" }
            return record?.lastError == nil ? "not read yet" : "has not worked yet"
        }
        let when = success.formatted(.relative(presentation: .named))
        guard record?.lastError == nil else { return "last worked \(when)" }
        return [record?.lastResult, when].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct ConnectorGrid: View {
    @Environment(\.appModel) private var model
    let isWorking: Bool
    @Binding var showingFolderPicker: Bool
    @Binding var folderDomain: Domain

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ConnectorButton(title: "Local GitHub Workspace", subtitle: "CLAUDE.md, STATE.md, README across repos", symbol: "folder.fill.badge.gearshape", disabled: isWorking) {
                    Task { await model.syncLocalGitHubWorkspace() }
                }
                ConnectorButton(title: "Cross-Agent Memories", subtitle: "Claude + Codex + Antigravity rules & memory", symbol: "brain.head.profile", disabled: isWorking) {
                    Task { await model.syncCrossAgentMemories() }
                }
                ConnectorButton(title: "GitHub API", subtitle: "Remote repos, commits, PRs & docs", symbol: "chevron.left.forwardslash.chevron.right", disabled: isWorking) {
                    Task { await model.syncGitHub() }
                }
                ConnectorButton(title: "Apple Calendar", subtitle: "Events & schedule (personal domain)", symbol: "calendar", disabled: isWorking) {
                    Task { await model.syncCalendar() }
                }
                ConnectorButton(title: "Apple Reminders", subtitle: "Action items & tasks (personal domain)", symbol: "checklist", disabled: isWorking) {
                    Task { await model.syncReminders() }
                }
                ConnectorButton(title: "Apple Notes", subtitle: "Local Notes database via AppleScript", symbol: "note.text", disabled: isWorking) {
                    Task { await model.syncNotes() }
                }
                ConnectorButton(title: "Apple Health", subtitle: "Workouts & metrics (medical domain)", symbol: "heart.text.square", disabled: isWorking) {
                    Task { await model.syncHealth() }
                }
                ConnectorButton(title: "Add Custom Folder", subtitle: "Tagged as '\(folderDomain.rawValue)' domain", symbol: "folder.badge.plus", disabled: isWorking) {
                    showingFolderPicker = true
                }
                ConnectorButton(title: "Re-read Whole Calendar", subtitle: "Every event in the look-back, ignoring the last sync date", symbol: "calendar.badge.clock", disabled: isWorking) {
                    Task { await model.syncCalendar(full: true) }
                }
                ConnectorButton(title: "Re-read All Reminders", subtitle: "Every reminder, ignoring the last sync date", symbol: "checklist.checked", disabled: isWorking) {
                    Task { await model.syncReminders(full: true) }
                }
                ConnectorButton(title: "Re-read All Notes", subtitle: "Every note, ignoring the last sync date", symbol: "note.text.badge.plus", disabled: isWorking) {
                    Task { await model.syncNotes(full: true) }
                }
            }

            SyncScheduleSummary()

            HStack(spacing: 8) {
                Text("New folders are tagged with Privacy Domain:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $folderDomain) {
                    ForEach(Domain.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                Text("This tag controls which query classes are allowed to read passages from that folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectorButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            ActionFeedbackCenter.shared.record(
                button: "Trigger Connector Sync: \(title)",
                command: "AppModel.sync(\(title))",
                outcome: "Starting connector sync for '\(title)' (\(subtitle))...",
                status: .running
            )
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Pastel.mint)
                    .frame(width: 34, height: 34)
                    .background(Pastel.mint.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.bold))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("Sync")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Pastel.mint)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Pastel.mint)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Pastel.mint.opacity(hovering ? 0.24 : 0.12), in: .capsule)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .openCoreGlassCard(cornerRadius: 10, tint: hovering ? Pastel.mint : nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(disabled)
    }
}

private struct EmbeddingPanel: View {
    @Environment(\.appModel) private var model
    let isWorking: Bool

    private var coverage: Double {
        model.chunkCount > 0 ? Double(model.embeddedCount) / Double(model.chunkCount) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-Device 512-d Semantic Vector Index")
                        .font(.callout.weight(.bold))
                    Text(model.embeddingModel ?? "Apple NLEmbedding (not built yet)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Build / Verify Index") {
                    Task { await model.buildEmbeddings() }
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Build / Verify Semantic Index")
                .disabled(isWorking || model.chunkCount == 0)
            }

            ScoreBar(value: coverage)

            if model.embeddedCount < model.chunkCount {
                Label(
                    "\(model.embeddedCount) of \(model.chunkCount) passages embedded. Semantic search cannot see the remaining \(model.chunkCount - model.embeddedCount) passages until indexed.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Pastel.peach)
            } else if model.chunkCount > 0 {
                Text("100% coverage: All \(model.chunkCount) passages have 512-d semantic vectors stored on disk.")
                    .font(.caption)
                    .foregroundStyle(Pastel.mint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)
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
