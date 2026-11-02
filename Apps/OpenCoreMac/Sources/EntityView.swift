import CoreModel
import CorePresentation
import CoreReason
import CoreStore
import SwiftUI

/// One thing, and everything the store knows about it.
@MainActor
@Observable
final class EntityModel {
    var entities: [(CoreEntity, Int)] = []
    var filter = ""
    var selected: EntityID?
    var dossier: EntityDossier?
    var history: [Belief] = []
    var showingHistoryFor: String?
    var loading = false
    var fmBrief: Conversation.GroundedBrief?
    var synthesizingBrief = false
    var extractingClaims = false
    var lastProposalSummary: String?
    var loadError: String?
    /// Retained for refresh/retry until a manual selection replaces the explicit jump.
    var navigationTarget: EntityNavigationRead.Target?
    private(set) var selectionRevision = 0
    @ObservationIgnored private var listRequestID = UUID()
    @ObservationIgnored private var dossierRequestID = UUID()
    @ObservationIgnored private var historyRequestID = UUID()
    @ObservationIgnored var briefTask: Task<Void, Never>?
    @ObservationIgnored var extractionTask: Task<Void, Never>?
    @ObservationIgnored var briefRequestID = UUID()
    @ObservationIgnored var extractionRequestID = UUID()

    var visible: [(CoreEntity, Int)] {
        guard !filter.isEmpty else { return entities }
        let needle = filter.lowercased()
        return entities.filter {
            $0.0.canonicalName.lowercased().contains(needle)
                || $0.0.kind.rawValue.lowercased().contains(needle)
        }
    }

    func load(store: Store, selectDefault: Bool = true) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        let selectionAtStart = selected
        let revisionAtStart = selectionRevision
        let dossierRequestAtStart = dossierRequestID
        listRequestID = requestID
        do {
            let fetched = try await store.entitiesByActivity()
            guard !Task.isCancelled, listRequestID == requestID else { return }
            entities = fetched
            // A list reply does not own a dossier/error from a read that began after it.
            guard selected == selectionAtStart, selectionRevision == revisionAtStart,
                  dossierRequestID == dossierRequestAtStart else { return }
            loadError = nil
            // A selection made while the list was loading owns its own dossier request.
            guard selectDefault, selected == selectionAtStart else { return }
            if let selected { await select(selected, store: store) }
            else if let first = fetched.first?.0.id { await select(first, store: store) }
        } catch {
            guard !Task.isCancelled, listRequestID == requestID, selected == selectionAtStart,
                  selectionRevision == revisionAtStart, dossierRequestID == dossierRequestAtStart else { return }
            loadError = "Entities could not load: \(error.localizedDescription)"
        }
    }

    func prepareNavigation() {
        selectionRevision += 1
        cancelGeneratedWork()
        selected = nil
        dossier = nil
        fmBrief = nil
        lastProposalSummary = nil
        dossierRequestID = UUID()
        historyRequestID = UUID()
        showingHistoryFor = nil
        history = []
        loadError = nil
        loading = true
    }

    /// Explicit navigation cannot fall back to a prior/default dossier when its target is missing.
    func navigate(to target: EntityNavigationRead.Target, store: Store,
                  isCurrent: () -> Bool) async -> EntityNavigationRead.Outcome {
        guard !Task.isCancelled else { return .discarded }
        navigationTarget = target
        prepareNavigation()
        let requestID = dossierRequestID
        let outcome = await EntityNavigationRead.run(
            target: target,
            knownEntities: entities.map(\.0),
            resolve: { try await store.resolve(surface: $0).map(\.0) },
            read: { try await store.dossier(for: $0) },
            isCurrent: { self.dossierRequestID == requestID && self.navigationTarget == target && isCurrent() }
        )
        guard dossierRequestID == requestID, navigationTarget == target, isCurrent() else { return .discarded }
        loading = false
        switch outcome {
        case .loaded(let fetched):
            selected = fetched.entity.id
            dossier = fetched
        case .notFound:
            loadError = "The requested entity was not found. No dossier was loaded."
        case .failed(let message):
            loadError = "Dossier could not load: \(message)"
        case .discarded: break
        }
        return outcome
    }

    func select(_ id: EntityID, store: Store) async {
        guard !Task.isCancelled else { return }
        navigationTarget = nil
        if selected != id {
            selectionRevision += 1
            cancelGeneratedWork()
            selected = id
            dossier = nil
            fmBrief = nil
            lastProposalSummary = nil
        }
        let requestID = UUID()
        dossierRequestID = requestID
        historyRequestID = UUID()
        showingHistoryFor = nil
        history = []
        loading = true
        do {
            let fetched = try await store.dossier(for: id)
            guard !Task.isCancelled, selected == id, dossierRequestID == requestID else { return }
            dossier = fetched
            loading = false
            loadError = nil
        } catch {
            guard !Task.isCancelled, selected == id, dossierRequestID == requestID else { return }
            loading = false
            loadError = "Dossier could not load: \(error.localizedDescription)"
        }
    }

    func cancelBrief() {
        briefTask?.cancel()
        briefTask = nil
        briefRequestID = UUID()
        synthesizingBrief = false
        fmBrief = nil
    }

    func cancelGeneratedWork() {
        cancelBrief()
        extractionTask?.cancel()
        extractionTask = nil
        extractionRequestID = UUID()
        extractingClaims = false
    }

    func loadHistory(key: String, store: Store) async {
        historyRequestID = UUID()
        if showingHistoryFor == key {
            showingHistoryFor = nil
            history = []
            return
        }
        let requestID = historyRequestID
        let entityID = selected
        let revision = selectionRevision
        showingHistoryFor = key
        history = []
        do {
            let fetched = try await store.beliefHistory(key: key)
            guard !Task.isCancelled, historyRequestID == requestID,
                  showingHistoryFor == key, selected == entityID,
                  selectionRevision == revision else { return }
            history = fetched
        } catch {
            guard !Task.isCancelled, historyRequestID == requestID, selected == entityID else { return }
            loadError = "Belief history could not load: \(error.localizedDescription)"
        }
    }

}

private struct EntityLoadTrigger: Equatable {
    let dataGeneration: Int
    let navigationRevision: Int
}

struct EntityView: View {
    @Environment(\.appModel) private var model
    @State private var expandedHistoryRow: ClaimID?
    @State private var entities = EntityModel()
    @AppStorage("entity.viewMode") private var viewMode: ViewMode = .split
    @State private var workspaceTab: WorkspaceTab = .entities
    @State private var selectionTask: Task<Void, Never>?
    @State private var lastNavigationRevision: Int?

    enum WorkspaceTab: String, CaseIterable, Identifiable {
        case entities = "Entities & Dossier"
        case claims = "Statements"
        case contradictions = "Reality Checks & Diffs"
        case beliefs = "Decisions & Revisions"

        var id: String { rawValue }

        var humanHeadline: String {
            switch self {
            case .entities:
                "Everything OpenCore knows about one project, person, or tool"
            case .claims:
                "Extracted statements with evidence you can inspect and corrections you can record"
            case .contradictions:
                "Compare conflicting statements and inspect available local checks"
            case .beliefs:
                "Recorded selections and revisions, with their evidence and reasons"
            }
        }

        var engineJargon: String {
            switch self {
            case .entities:
                "EntityDossier · • observed (direct from text) vs ○ inferred (derived pattern)"
            case .claims:
                "CoreClaim · Evidence spans · Ordinal authority tiers"
            case .contradictions:
                "Contradiction · Functional Predicates (objective, verify_command, status, primary_language) allow only 1 active value"
            case .beliefs:
                "Belief versions retain earlier selections for historical inspection"
            }
        }
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        case dossier = "Dossier"
        case graph = "Graph"
        case split = "Split"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .dossier: "list.bullet.rectangle"
            case .graph: "point.3.connected.trianglepath.dotted"
            case .split: "rectangle.split.2x1"
            }
        }
    }

    var body: some View {
        @Bindable var entities = entities
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Knowledge Workspace", selection: $workspaceTab) {
                        ForEach(WorkspaceTab.allCases) { tab in
                            if tab == .contradictions && model.openContradictionCount > 0 {
                                Text("\(tab.rawValue) (\(model.openContradictionCount))").tag(tab)
                            } else {
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text(workspaceTab.humanHeadline)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(workspaceTab.engineJargon)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)

            Divider()

            switch workspaceTab {
            case .entities:
                HSplitView {
                    list.frame(minWidth: 220, idealWidth: 260)
                    detail.frame(minWidth: 440)
                }
                .searchable(text: $entities.filter, prompt: "Filter entities")
            case .claims:
                ClaimsView()
            case .contradictions:
                ContradictionsView()
            case .beliefs:
                BeliefsView()
            }
        }
        .navigationTitle("Knowledge Graph")
        .task(
            id: EntityLoadTrigger(
                dataGeneration: model.dataGeneration,
                navigationRevision: model.entityNavigationRevision
            )
        ) {
            guard let store = model.store else { return }
            let revision = model.entityNavigationRevision
            let target: EntityNavigationRead.Target?
            var legacyNavigation = false
            if let id = model.pendingEntityID { target = .id(id) }
            else if let name = model.pendingEntityName { target = .name(name) }
            else if let name = PendingEntity.shared.take() { target = .name(name); legacyNavigation = true }
            else { target = model.entityNavigationTarget }
            let presentDossier = lastNavigationRevision != revision || legacyNavigation
            lastNavigationRevision = revision
            let feedbackButton = presentDossier ? "Open Entity" : "Refresh Entity"
            if let target {
                if presentDossier { workspaceTab = .entities }
                model.entityNavigationTarget = target
                entities.navigationTarget = target
                entities.prepareNavigation()
                model.activeEntityID = nil
            }
            let selectionBeforeList = entities.selectionRevision
            await entities.load(store: store, selectDefault: target == nil)
            guard !Task.isCancelled, model.entityNavigationRevision == revision else { return }
            if let target {
                guard entities.selectionRevision == selectionBeforeList,
                      entities.navigationTarget == target, model.entityNavigationTarget == target else { return }
                ActionFeedbackCenter.shared.record(button: feedbackButton, command: "Read entity dossier",
                    outcome: "Loading the requested entity dossier.", status: .running)
                let result = await entities.navigate(to: target, store: store,
                    isCurrent: { model.entityNavigationRevision == revision && model.entityNavigationTarget == target })
                guard !Task.isCancelled, model.entityNavigationRevision == revision else { return }
                switch result {
                case .loaded(let dossier):
                    ActionFeedbackCenter.shared.record(button: feedbackButton, command: "Read entity dossier",
                        outcome: "Loaded '\(dossier.entity.canonicalName)': \(dossier.claims.count) statement rows, \(dossier.events.count) recent events and \(dossier.contradictions.count) contradictions.", status: .completed)
                case .notFound:
                    ActionFeedbackCenter.shared.record(button: feedbackButton, command: "Read entity dossier",
                        outcome: "The requested entity was not found. No dossier was loaded.", status: .warning)
                case .failed(let message):
                    ActionFeedbackCenter.shared.record(button: feedbackButton, command: "Read entity dossier",
                        outcome: "The requested dossier could not load: \(message)", status: .warning)
                    let prior = model.failure.map { "\n" + $0.message } ?? ""
                    model.failure = .init(message: "Entity navigation failed: \(message)" + prior, at: Date())
                case .discarded: return
                }
                model.pendingEntityID = nil
                model.pendingEntityName = nil
            }
            guard !Task.isCancelled else { return }
            model.activeEntityID = entities.selected
        }
        .onChange(of: model.dataGeneration) { _, _ in entities.cancelBrief() }
        .onDisappear {
            selectionTask?.cancel()
            entities.cancelGeneratedWork()
        }
    }

    private var list: some View {
        List(selection: Binding(
            get: { entities.selected },
            set: { id in
                guard let id, let store = model.store else { return }
                model.pendingEntityID = nil
                model.pendingEntityName = nil
                entities.navigationTarget = nil
                model.entityNavigationTarget = .id(id)
                model.activeEntityID = id
                selectionTask?.cancel()
                selectionTask = Task { await entities.select(id, store: store) }
            }
        )) {
            ForEach(entities.visible, id: \.0.id) { entity, count in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entity.canonicalName).font(.callout).lineLimit(1)
                        Text("\(entity.kind.rawValue) · \(entity.domain.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .tag(entity.id)
            }
        }
        .overlay {
            if entities.entities.isEmpty {
                EmptyState(message: "No entities yet.\n\nThey are resolved from synced objects, so sync a source first.")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = entities.loadError {
            VStack(spacing: 12) {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry") {
                    guard let store = model.store else { return }
                    if let target = entities.navigationTarget {
                        switch target {
                        case .id(let id): model.openEntity(id: id)
                        case .name(let name): model.openEntity(named: name)
                        }
                        return
                    }
                    selectionTask?.cancel()
                    selectionTask = Task { await entities.load(store: store) }
                }
            }
            .padding()
        } else if let dossier = entities.dossier, dossier.entity.id == entities.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(dossier)
                    dossierVisualTelemetryBar(dossier)
                    if let brief = entities.fmBrief {
                        dossierBriefCard(brief)
                    }
                    if dossier.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Resolved as an entity, but nothing has been claimed about it yet.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button {
                                startExtractClaims(for: dossier)
                            } label: {
                                Label(
                                    entities.extractingClaims ? "Extracting via /usr/bin/fm…" : "Extract Byte-Verified Claims from Passages (/usr/bin/fm → modelInference)",
                                    systemImage: "wand.and.stars"
                                )
                                .font(.caption.weight(.semibold))
                            }
                            .openCoreGlassButton(prominent: true)
                            .disabled(entities.extractingClaims)
                        }
                    } else {
                        if viewMode == .graph || viewMode == .split {
                            EntityGraphCanvas(dossier: dossier)
                        }
                        if viewMode == .dossier || viewMode == .split {
                            if !dossier.contradictions.isEmpty { contradictions(dossier) }
                            beliefs(dossier)
                            if !dossier.events.isEmpty { timeline(dossier) }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if entities.loading {
            ProgressView()
        } else {
            EmptyState(message: "Pick something to see what OpenCore knows about it.")
        }
    }

    private func header(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(dossier.entity.canonicalName)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()

                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .help("Switch between Dossier, interactive Knowledge Graph, or Split view")

                Button {
                    startSynthesizeBrief(for: dossier)
                } label: {
                    HStack(spacing: 4) {
                        if entities.synthesizingBrief {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Brief (/fm)")
                    }
                    .font(.caption.weight(.medium))
                }
                .openCoreGlassButton(prominent: true)
                .disabled(entities.synthesizingBrief)
                .help("Synthesize an on-device grounded executive dossier brief via /usr/bin/fm with [1]..[N] citations")

                Button {
                    startExtractClaims(for: dossier)
                } label: {
                    HStack(spacing: 4) {
                        if entities.extractingClaims {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text("Extract Claims (/fm)")
                    }
                    .font(.caption.weight(.medium))
                }
                .openCoreGlassButton()
                .disabled(entities.extractingClaims)
                .help("Propose and byte-verify Authority.modelInference claims from unstructured passages mentioning \(dossier.entity.canonicalName)")

                Button {
                    model.openPassages(query: dossier.entity.canonicalName)
                } label: {
                    Label("Passages", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.medium))
                }
                .openCoreGlassButton()

                Button {
                    model.askInChat("What do I know about \(dossier.entity.canonicalName)?")
                } label: {
                    Label("Ask in Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption.weight(.medium))
                }
                .openCoreGlassButton()
            }

            HStack(spacing: 8) {
                Chip(dossier.entity.kind.rawValue)
                Chip(dossier.entity.domain.rawValue)
                Text("first seen \(Self.day.string(from: dossier.entity.firstSeenAt))")
                    .font(.caption).foregroundStyle(.tertiary)
                if let summary = entities.lastProposalSummary {
                    Text("· \(summary)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.purple)
                }
            }
            if !dossier.aliases.isEmpty {
                Text("also known as: " + dossier.aliases.prefix(8).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func dossierVisualTelemetryBar(_ dossier: EntityDossier) -> some View {
        let observedCount = dossier.claims.filter { $0.claim.derivation == .observed }.count
        let inferredCount = dossier.claims.filter { $0.claim.derivation != .observed }.count
        let totalFacts = max(dossier.claims.count, 1)
        let matchingRepo = model.fleetCards.first {
            $0.name.caseInsensitiveCompare(dossier.entity.canonicalName) == .orderedSame
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("FACT EVIDENCE BREAKDOWN (\(dossier.claims.count) BELIEFS · \(dossier.events.count) EVENTS)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 7, height: 7)
                                Text("Direct / Observed: \(observedCount)")
                                    .font(.caption2.monospaced())
                            }
                            HStack(spacing: 4) {
                                Circle().fill(.blue).frame(width: 7, height: 7)
                                Text("Derived / Inferred: \(inferredCount)")
                                    .font(.caption2.monospaced())
                            }
                        }
                    }

                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            if observedCount > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.green.gradient)
                                    .frame(width: max(geo.size.width * CGFloat(observedCount) / CGFloat(totalFacts) - 2, 12))
                            }
                            if inferredCount > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue.gradient)
                                    .frame(width: max(geo.size.width * CGFloat(inferredCount) / CGFloat(totalFacts) - 2, 12))
                            }
                        }
                    }
                    .frame(height: 10)
                }
            }

            if let repo = matchingRepo {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .foregroundStyle(Color.accentColor)
                    Text("Live Git Ground Truth: \(repo.branch) @ \(repo.head) (\(repo.headWhen))")
                        .font(.caption.monospaced().weight(.semibold))
                    Text(repo.dirty == 0 ? "· Working Tree Clean" : "· \(repo.dirty) Dirty File(s)")
                        .font(.caption.monospaced())
                        .foregroundStyle(repo.dirty == 0 ? .green : .cyan)
                    Text("· STATE.md: \(repo.stateStatus.uppercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(repo.isHandoffCurrent ? .green : .orange)
                    Spacer()
                    Button("Open Terminal") {
                        OperatorConsoleService.openInTerminal(rootPath: repo.root)
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton()
                    Button("Reveal in Finder") {
                        OperatorConsoleService.revealInFinder(path: repo.root)
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton()
                }
            }
        }
        .padding(12)
        .openCoreGlassCard(cornerRadius: 10)
    }

    private func startSynthesizeBrief(for dossier: EntityDossier) {
        entities.cancelBrief()
        let entityID = dossier.entity.id
        let revision = entities.selectionRevision
        let generation = model.dataGeneration
        let requestID = UUID()
        entities.briefRequestID = requestID
        entities.synthesizingBrief = true
        entities.briefTask = Task {
            let brief = await model.synthesizeEntityBrief(dossier)
            guard !Task.isCancelled, entities.selected == entityID,
                  entities.selectionRevision == revision, model.dataGeneration == generation,
                  entities.briefRequestID == requestID else { return }
            entities.fmBrief = brief
            entities.synthesizingBrief = false
            entities.briefTask = nil
        }
    }

    private func startExtractClaims(for dossier: EntityDossier) {
        entities.extractionTask?.cancel()
        let entityID = dossier.entity.id
        let revision = entities.selectionRevision
        let requestID = UUID()
        entities.extractionRequestID = requestID
        entities.extractingClaims = true
        entities.extractionTask = Task {
            do {
            let outcomes = try await model.proposeClaimsForEntity(entityID)
            // The proposal method refreshes AppModel itself. Selection revision, rather than its
            // old generation, identifies which dossier may receive this operation's summary.
            guard !Task.isCancelled, entities.selected == entityID,
                  entities.selectionRevision == revision,
                  entities.extractionRequestID == requestID else { return }
            let verifiedCount = outcomes.reduce(0) { $0 + $1.verifiedProposals.count }
            let rejectedCount = outcomes.reduce(0) { $0 + $1.rejectedUnverifiedSpan }
            entities.lastProposalSummary = "\(verifiedCount) byte-verified modelInference claim(s) extracted (\(rejectedCount) unverified spans rejected)"
            entities.extractingClaims = false
            entities.extractionTask = nil
            if let store = model.store {
                await entities.select(entityID, store: store)
            }
            } catch {
                guard !Task.isCancelled, entities.selected == entityID,
                      entities.selectionRevision == revision, entities.extractionRequestID == requestID else { return }
                entities.lastProposalSummary = "Extraction failed: \(error.localizedDescription)"
                entities.extractingClaims = false
                entities.extractionTask = nil
            }
        }
    }

    private func dossierBriefCard(_ brief: Conversation.GroundedBrief) -> some View {
        let groundedCount = brief.verdicts.filter(\.isGrounded).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("On-Device Executive Brief (\(brief.modelName))", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                if !brief.verdicts.isEmpty {
                    Text("\(groundedCount)/\(brief.verdicts.count) sentences grounded")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.14), in: .capsule)
                        .foregroundStyle(.green)
                }
                Text("On-device synthesis")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    entities.fmBrief = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Text(brief.text)
                .font(.callout)
                .textSelection(.enabled)

            if !brief.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(brief.sources) { src in
                            Button {
                                model.inspectObject(src.objectID, highlight: src.text)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("[\(src.index)]")
                                        .font(.caption2.weight(.bold).monospaced())
                                        .foregroundStyle(Color.accentColor)
                                    Text(src.title)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10, tint: .accentColor)
    }

    private func contradictions(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("Disagreements Across Sources (Contradictions)", count: dossier.contradictions.count)
                Text("Functional predicates allow only one active truth")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(dossier.contradictions, id: \.id) { contradiction in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: contradiction.resolution == .unresolved
                            ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(contradiction.resolution == .unresolved ? .orange : .secondary)
                        Text(contradiction.kind.rawValue).font(.callout.weight(.medium))
                        Text(contradiction.resolution.rawValue).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Inspect Side A") {
                            model.inspectClaim(contradiction.claimA)
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        Button("Inspect Side B") {
                            model.inspectClaim(contradiction.claimB)
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        if contradiction.resolution == .unresolved {
                            Button("Resolve Conflict →") {
                                model.selectedSection = .contradictions
                            }
                            .controlSize(.mini)
                        }
                    }
                    Text(contradiction.reason).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(
                    cornerRadius: 8,
                    tint: contradiction.resolution == .unresolved ? .orange : nil
                )
            }
        }
    }

    private func beliefs(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("Current claim statements", count: dossier.claims.count)
                Text("• observed = read directly from file · ○ inferred = derived pattern · Click Evidence for exact byte span")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(dossier.claims.prefix(60)) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        let isModelProposed = row.claim.authority == .modelInference
                        Image(systemName: isModelProposed ? "sparkles" : (row.claim.derivation == .observed ? "circle.fill" : "circle.dashed"))
                            .font(.system(size: isModelProposed ? 9 : 7))
                            .foregroundStyle(isModelProposed ? .purple : (row.claim.derivation == .observed ? Color.accentColor : .orange))
                            .help(isModelProposed ? "modelInference: proposed by /usr/bin/fm and verified against an exact UTF-8 byte span (outranked by all deterministic rules)" : (row.claim.derivation == .observed ? "observed: read directly from source data" : "inferred: derived by OpenCore from activity patterns"))

                        Text(isModelProposed ? "model (/fm)" : (row.claim.derivation == .observed ? "observed" : "inferred"))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isModelProposed ? .purple : (row.claim.derivation == .observed ? Color.accentColor : .orange))

                        Text(row.claim.predicate.replacingOccurrences(of: "_", with: " "))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .help("Engine predicate: \(row.claim.predicate)")

                        if let targetID = row.claim.objectEntity, targetID != dossier.entity.id {
                            EntityLinkChip(name: row.value, entityID: targetID)
                        } else {
                            Text(row.value)
                                .font(.callout.weight(.medium))
                                .textSelection(.enabled)
                        }

                        if row.occurrences > 1 {
                            Text("×\(row.occurrences)").font(.caption2).foregroundStyle(.tertiary)
                                .help("Supported by \(row.occurrences) distinct evidence spans")
                        }
                        Spacer()

                        Button {
                            model.inspectClaim(row.claim.id)
                        } label: {
                            Label("Inspect evidence", systemImage: "doc.text.magnifyingglass")
                                .font(.caption2)
                        }
                        .buttonStyle(.link)
                        .help("Inspect supporting byte spans, counter-evidence, and raw Floor Object")

                        Button {
                            Task { await model.startCorrection(for: row.claim) }
                        } label: {
                            Text("Correct")
                                .font(.caption2)
                        }
                        .controlSize(.mini)
                        .help("Override this belief at userConfirmed / directStatement authority (retracts old claim without deleting)")

                        if Predicate.functional.contains(row.claim.predicate) {
                            Text(row.isBelieved ? "Believed" : "Candidate")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(row.isBelieved ? .green : .secondary)
                        }
                        Text(String(format: "claim score %.2f", row.claim.confidence))
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 8) {
                        Text("authority: \(row.claim.authority.label)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if let revisions = row.revisions {
                            Button(expandedHistoryRow == row.id && entities.showingHistoryFor == row.claim.claimKey ? "hide \(revisions) belief versions" : "changed \(revisions) times (view decision history)") {
                                guard let store = model.store else { return }
                                if expandedHistoryRow == row.id {
                                    expandedHistoryRow = nil
                                } else {
                                    expandedHistoryRow = row.id
                                    if entities.showingHistoryFor != row.claim.claimKey {
                                        Task { await entities.loadHistory(key: row.claim.claimKey, store: store) }
                                    }
                                }
                            }
                            .buttonStyle(.link).font(.caption2)
                        }
                    }
                    if expandedHistoryRow == row.id && entities.showingHistoryFor == row.claim.claimKey { historyList }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 8)
            }
            if dossier.claims.count > 60 {
                Button("+ \(dossier.claims.count - 60) more distinct statements in Claims →") {
                    model.selectedSection = .claims
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entities.history, id: \.id) { belief in
                HStack(spacing: 8) {
                    Text("v\(belief.version)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text(Self.day.string(from: belief.decidedAt)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text(belief.reason).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Inspect evidence") {
                        model.inspectClaim(belief.claimID)
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }
        }
        .padding(.top, 4)
    }

    private func timeline(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("Recent events loaded", count: dossier.events.count)
                Text("Commits, calendar meetings, and file updates")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(dossier.events.prefix(40), id: \.id) { event in
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.day.string(from: event.occurredAt))
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 84, alignment: .leading)
                    Text(event.verb.replacingOccurrences(of: "_", with: " "))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 80, alignment: .leading)
                    Text(event.detail).font(.caption).lineLimit(2)
                }
            }
            if dossier.events.count > 40 {
                Button("View older events in Timeline →") {
                    model.selectedSection = .timeline
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct SectionLabel: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct Chip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
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

// MARK: - Interactive Knowledge Graph Canvas

/// Radial ego-network around `dossier.entity`.
///
/// Linked entities are clickable nodes that jump to their own dossier (with `⌘[` back-stack
/// support); literal claims and edges open the `ProvenanceInspector` directly on the floor
/// object and byte span that produced the belief.
struct EntityGraphCanvas: View {
    @Environment(\.appModel) private var model
    let dossier: EntityDossier
    @State private var hoveredClaimID: ClaimID?

    private struct Spoke: Identifiable {
        var id: ClaimID { row.claim.id }
        let index: Int
        let row: DossierClaim
        let predicateLabel: String
        let isEntityLink: Bool
        let hasOpenConflict: Bool
    }

    private var spokes: [Spoke] {
        let openClaimIDs = Set(
            dossier.contradictions
                .filter { $0.resolution == .unresolved }
                .flatMap { [$0.claimA, $0.claimB] }
        )
        // Prioritize entity-to-entity links and high-signal functional predicates.
        let sorted = dossier.claims.sorted { lhs, rhs in
            let lLink = lhs.claim.objectEntity != nil && lhs.claim.objectEntity != dossier.entity.id
            let rLink = rhs.claim.objectEntity != nil && rhs.claim.objectEntity != dossier.entity.id
            if lLink != rLink { return lLink }
            return lhs.occurrences > rhs.occurrences
        }
        return Array(sorted.prefix(12)).enumerated().map { idx, row in
            let targetID = row.claim.objectEntity
            return Spoke(
                index: idx,
                row: row,
                predicateLabel: row.claim.predicate.replacingOccurrences(of: "_", with: " "),
                isEntityLink: targetID != nil && targetID != dossier.entity.id,
                hasOpenConflict: openClaimIDs.contains(row.claim.id)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Relationship Graph", count: spokes.count)
                Spacer()
                HStack(spacing: 12) {
                    Label("Click entity to jump", systemImage: "arrow.up.forward.app")
                    Label("Click attribute to inspect evidence", systemImage: "doc.text.magnifyingglass")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let rx = max(120, min(geo.size.width * 0.37, 290))
                let ry = max(95, min(geo.size.height * 0.36, 145))
                let count = max(1, spokes.count)

                ZStack {
                    Canvas { context, _ in
                        for spoke in spokes {
                            let angle = (2.0 * .pi * Double(spoke.index) / Double(count)) - (.pi / 2.0)
                            let target = CGPoint(
                                x: center.x + CGFloat(cos(angle)) * rx,
                                y: center.y + CGFloat(sin(angle)) * ry
                            )
                            let mid = CGPoint(
                                x: (center.x + target.x) / 2,
                                y: (center.y + target.y) / 2 - 10
                            )
                            var path = Path()
                            path.move(to: center)
                            path.addQuadCurve(to: target, control: mid)

                            let isHovered = hoveredClaimID == spoke.id
                            let strokeColor: Color = if spoke.hasOpenConflict {
                                .orange
                            } else if isHovered {
                                .accentColor
                            } else if spoke.isEntityLink {
                                .accentColor.opacity(0.45)
                            } else {
                                .secondary.opacity(0.32)
                            }

                            let style = StrokeStyle(
                                lineWidth: isHovered ? 2.4 : 1.4,
                                lineCap: .round,
                                dash: spoke.row.claim.derivation == .inferred || spoke.hasOpenConflict ? [5, 4] : []
                            )
                            context.stroke(path, with: .color(strokeColor), style: style)
                        }
                    }

                    ForEach(spokes) { spoke in
                        let angle = (2.0 * .pi * Double(spoke.index) / Double(count)) - (.pi / 2.0)
                        let target = CGPoint(
                            x: center.x + CGFloat(cos(angle)) * rx,
                            y: center.y + CGFloat(sin(angle)) * ry
                        )
                        let edgeLabelPos = CGPoint(
                            x: center.x + CGFloat(cos(angle)) * (rx * 0.48),
                            y: center.y + CGFloat(sin(angle)) * (ry * 0.48) - 4
                        )

                        Text(spoke.predicateLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(hoveredClaimID == spoke.id ? Color.primary : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(.ultraThinMaterial, in: .capsule)
                            .position(edgeLabelPos)
                            .onTapGesture {
                                model.inspectClaim(spoke.row.claim.id)
                            }

                        spokeNode(spoke)
                            .position(target)
                    }

                    VStack(spacing: 2) {
                        Text(dossier.entity.canonicalName)
                            .font(.callout.weight(.bold))
                            .lineLimit(1)
                        Text("\(dossier.entity.kind.rawValue) · \(dossier.claims.count) beliefs")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .openCoreGlassCard(cornerRadius: 14, tint: .accentColor)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .position(center)
                }
            }
            .frame(height: 330)
            .openCoreGlassCard(cornerRadius: 12)
        }
    }

    @ViewBuilder
    private func spokeNode(_ spoke: Spoke) -> some View {
        let isHovered = hoveredClaimID == spoke.id
        let tint: Color = spoke.hasOpenConflict ? .orange : (spoke.isEntityLink ? .accentColor : .secondary)

        HStack(spacing: 5) {
            Circle()
                .fill(spoke.row.claim.derivation == .observed ? tint : .orange)
                .frame(width: 6, height: 6)

            Button {
                if let targetID = spoke.row.claim.objectEntity, targetID != dossier.entity.id {
                    model.openEntity(id: targetID)
                } else {
                    model.inspectClaim(spoke.row.claim.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(spoke.row.value)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: 145)
                    if spoke.isEntityLink {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                model.inspectClaim(spoke.row.claim.id)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Inspect supporting evidence in Provenance Inspector")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            isHovered ? tint.opacity(0.22) : tint.opacity(0.11),
            in: .capsule
        )
        .overlay(
            Capsule()
                .strokeBorder(isHovered ? tint.opacity(0.75) : tint.opacity(0.25), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredClaimID = hovering ? spoke.id : nil
        }
        .help("\(spoke.predicateLabel): \(spoke.row.value) (\(spoke.row.claim.authority.label), confidence \(String(format: "%.2f", spoke.row.claim.confidence)))")
    }
}
