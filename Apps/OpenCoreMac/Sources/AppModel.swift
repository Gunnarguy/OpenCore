import CoreGraph
import CoreIngest
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation
import Observation
import SwiftUI

private struct AppModelEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = AppModel.shared
}

private struct AppSettingsEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = AppModel.shared.settings
}

extension EnvironmentValues {
    var appModel: AppModel {
        get { self[AppModelEnvironmentKey.self] }
        set { self[AppModelEnvironmentKey.self] = newValue }
    }

    var appSettings: AppSettings {
        get { self[AppSettingsEnvironmentKey.self] }
        set { self[AppSettingsEnvironmentKey.self] = newValue }
    }
}

/// The app's single point of contact with the engine.
///
/// Everything below `Store` is already actor-isolated, so this exists to hold view state
/// and to keep SwiftUI off the concurrency details, not to add another layer of caching.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum LoadState: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    private(set) var store: Store?
    /// Owned here so there is one instance, injected into the environment by OpenCoreApp.
    let settings = AppSettings.shared

    /// What is happening right now. `.failed` is recorded in `failure` as it is set, because
    /// this is one slot that every operation writes: `refresh()` set `.failed` and its caller
    /// set `.idle` on the next line, so real errors reached nobody.
    var state: LoadState = .idle {
        didSet {
            if case .failed(let message) = state {
                failure = AppFailure(message: message, at: Date())
            }
        }
    }

    /// The last thing that went wrong, until someone dismisses it.
    var failure: AppFailure?

    /// When the app was last opened before this launch, so Home can say what changed since.
    /// nil on a first launch, and nil is what Home says: it falls back to a plain window.
    let previousVisit: Date? = {
        let key = "home.lastVisit"
        let previous = UserDefaults.standard.object(forKey: key) as? Date
        UserDefaults.standard.set(Date(), forKey: key)
        return previous
    }()

    // Scheduled sync. See `AppModel+Schedule.swift`.
    var scheduleRecords: [SyncSchedule.Job: SyncSchedule.Record] = [:]
    var syncActivity: NSBackgroundActivityScheduler?
    let syncCoordinator = SyncCoordinator()
    /// Read on a background thread and kept here, because the Sources screen asks during
    /// rendering and the answer can mean starting `gh`.
    var githubTokenAvailable = false

    struct AppFailure: Equatable, Sendable {
        let message: String
        let at: Date
    }

    func dismissFailure() { failure = nil }

    /// Incremented whenever the store opens or any sync, rebuild, or correction finishes.
    /// Views key their `.task(id:)` on this counter so no screen stays blank on launch or stale
    /// after a mutation.
    var dataGeneration = 0

    // Navigation & global overlays
    var selectedSection: Section = .home
    var activeEntityID: EntityID?
    var pendingEntityID: EntityID?
    var pendingEntityName: String?
    var pendingQuestion: String?
    var pendingPassageQuery: String?
    var showingQuickJump = false
    var showingJarvisHUD = false
    var showingWorkspaceMap = false
    var openWorkspaceMapAfterQuickJump = false
    var showingInspector = false
    var inspectorState: InspectorState = .empty
    private var inspectorTask: Task<Void, Never>?
    private var inspectorRequestID = UUID()
    var correctingRow: ClaimRow?

    struct NavigationStop: Equatable, Sendable {
        let section: Section
        let entityID: EntityID?
        let entityName: String?
        let subject: KnowledgeSubject?
    }

    var navigationBackStack: [NavigationStop] = []
    var navigationForwardStack: [NavigationStop] = []
    var canGoBack: Bool { !navigationBackStack.isEmpty }
    var canGoForward: Bool { !navigationForwardStack.isEmpty }

    // Overview
    var objectCount = 0
    var entityCount = 0
    var claimCount = 0
    var openContradictionCount = 0
    var sources: [Source] = []
    var countsByKind: [(ObjectKind, Int)] = []
    /// Shown in Settings so it is obvious the app and the CLI share one file.
    var storePath: String?
    var projectBriefs: [ProjectBrief] = []

    struct ProjectBrief: Identifiable, Sendable {
        let id: EntityID
        let name: String
        let status: String?
        let primaryLanguage: String?
        let lastVerifiedCommit: String?
        let objective: String?
        let nextAction: String?
        let verifyCommand: String?
        let claimCount: Int
        let hasOpenConflict: Bool
    }

    // Browsing
    var claims: [ClaimRow] = []
    var subjectClaims: [ClaimRow] = []
    var beliefs: [BeliefRow] = []
    var claimsSubject: KnowledgeSubject?
    var beliefsSubject: KnowledgeSubject?
    private var claimsLoadID = UUID()
    private var subjectClaimsLoadID = UUID()
    var contradictions: [ContradictionRow] = []
    var receipts: [Receipt] = []

    // Asking
    var answer: Answer?
    var traceRows: [TraceRow] = []

    struct ClaimRow: Identifiable, Sendable {
        let id: ClaimID
        let subjectID: EntityID
        let subject: String
        let predicate: String
        let objectEntityID: EntityID?
        let value: String
        let claim: CoreClaim

        init(
            id: ClaimID,
            subjectID: EntityID? = nil,
            subject: String,
            predicate: String,
            objectEntityID: EntityID? = nil,
            value: String,
            claim: CoreClaim
        ) {
            self.id = id
            self.subjectID = subjectID ?? claim.subject
            self.subject = subject
            self.predicate = predicate
            self.objectEntityID = objectEntityID ?? claim.objectEntity
            self.value = value
            self.claim = claim
        }
    }

    struct BeliefRow: Identifiable, Sendable {
        let id: BeliefID
        let subjectID: EntityID
        let subject: String
        let predicate: String
        let objectEntityID: EntityID?
        let value: String
        let belief: Belief
    }

    struct ContradictionSide: Identifiable, Sendable {
        var id: ClaimID { claim.id }
        let claim: CoreClaim
        let subjectID: EntityID
        let subject: String
        let predicate: String
        let value: String
        let label: String
        let text: String
        let kept: Bool
    }

    struct ContradictionRow: Identifiable, Sendable {
        let id: ContradictionID
        let contradiction: Contradiction
        let subjectID: EntityID?
        let subjectName: String?
        let sides: [ContradictionSide]
    }

    struct TraceRow: Identifiable, Sendable {
        let id: EvidenceID
        let evidence: Evidence
        let object: CoreObject
        let score: Double
    }

    // MARK: - Provenance Inspector models

    struct EvidenceDetail: Identifiable, Sendable {
        var id: EvidenceID { evidence.id }
        let evidence: Evidence
        let object: CoreObject?
        let weight: Double
    }

    struct ClaimInspection: Sendable {
        let row: ClaimRow
        let belief: Belief?
        let supporting: [EvidenceDetail]
        let refuting: [EvidenceDetail]
    }

    struct ObjectInspection: Sendable {
        let object: CoreObject
        let chunks: [CoreChunk]
        let derivedClaims: [ClaimRow]
        let highlight: String?
    }

    enum InspectorState: Sendable {
        case failed(String)
        case empty
        case loading
        case claim(ClaimInspection)
        case object(ObjectInspection)
    }

    // MARK: - Cross-screen Navigation

    private var currentNavigationStop: NavigationStop {
        NavigationStop(
            section: selectedSection,
            entityID: selectedSection == .entities ? (activeEntityID ?? pendingEntityID) : nil,
            entityName: selectedSection == .entities ? pendingEntityName : nil,
            subject: knowledgeSubject(for: selectedSection)
        )
    }

    private func pushHistoryBeforeJumping() {
        let stop = currentNavigationStop
        if navigationBackStack.last != stop {
            navigationBackStack.append(stop)
            if navigationBackStack.count > 40 {
                navigationBackStack.removeFirst()
            }
        }
        navigationForwardStack.removeAll()
    }

    func navigate(to section: Section) {
        // Generic navigation (sidebar, global totals, palette) opens a global view.
        // Related-subject navigation uses openStatements/openDecisions explicitly.
        guard section != selectedSection || knowledgeSubject(for: section) != nil else { return }
        pushHistoryBeforeJumping()
        if section == .claims { claimsSubject = nil }
        if section == .beliefs { beliefsSubject = nil }
        selectedSection = section
    }

    func goBack() {
        guard let previous = navigationBackStack.popLast() else { return }
        let current = currentNavigationStop
        navigationForwardStack.append(current)
        applyNavigationStop(previous)
    }

    func goForward() {
        guard let next = navigationForwardStack.popLast() else { return }
        let current = currentNavigationStop
        navigationBackStack.append(current)
        applyNavigationStop(next)
    }

    private func applyNavigationStop(_ stop: NavigationStop) {
        if stop.section == .claims { claimsSubject = stop.subject }
        if stop.section == .beliefs { beliefsSubject = stop.subject }
        if let entityID = stop.entityID {
            pendingEntityID = entityID
            pendingEntityName = nil
        } else if let entityName = stop.entityName {
            pendingEntityName = entityName
            pendingEntityID = nil
            PendingEntity.shared.name = entityName
        }
        selectedSection = stop.section
    }

    func openEntity(id: EntityID) {
        if selectedSection == .entities, activeEntityID == id { return }
        pushHistoryBeforeJumping()
        pendingEntityID = id
        pendingEntityName = nil
        selectedSection = .entities
    }

    func openEntity(named name: String) {
        pushHistoryBeforeJumping()
        pendingEntityName = name
        pendingEntityID = nil
        selectedSection = .entities
        PendingEntity.shared.name = name
    }

    func askInChat(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushHistoryBeforeJumping()
        pendingQuestion = trimmed
        PendingQuestion.shared.text = trimmed
        selectedSection = .chat
    }

    func openPassages(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pushHistoryBeforeJumping()
        if !trimmed.isEmpty {
            pendingPassageQuery = trimmed
        }
        selectedSection = .passages
    }

    func knowledgeSubject(for section: Section) -> KnowledgeSubject? {
        switch section {
        case .claims: claimsSubject
        case .beliefs: beliefsSubject
        default: nil
        }
    }

    func openStatements(for subject: KnowledgeSubject) {
        showingInspector = false
        guard selectedSection != .claims || claimsSubject != subject else { return }
        pushHistoryBeforeJumping()
        claimsSubject = subject
        selectedSection = .claims
    }

    func openDecisions(for subject: KnowledgeSubject) {
        showingInspector = false
        guard selectedSection != .beliefs || beliefsSubject != subject else { return }
        pushHistoryBeforeJumping()
        beliefsSubject = subject
        selectedSection = .beliefs
    }

    func followWorkspace(to section: Section) {
        // Keep an explicitly visible subject when crossing between its related views.
        if let subject = knowledgeSubject(for: selectedSection) {
            switch section {
            case .claims: openStatements(for: subject); return
            case .beliefs: openDecisions(for: subject); return
            case .passages: openPassages(query: subject.name); return
            case .entities: openEntity(id: subject.id); return
            default: break
            }
        }
        navigate(to: section)
    }

    func startCorrection(for claim: CoreClaim) async {
        guard let store else { return }
        do {
            let subjectName = try await name(of: claim.subject, in: store)
            let displayVal = try await value(of: claim, in: store)
            correctingRow = ClaimRow(
                id: claim.id,
                subjectID: claim.subject,
                subject: subjectName,
                predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                objectEntityID: claim.objectEntity,
                value: displayVal,
                claim: claim
            )
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Resolve a contradiction in one click by promoting the chosen claim to `.directStatement`
    /// authority and retracting the competing claim.
    func resolveContradiction(_ contradiction: Contradiction, keeping winningSide: ContradictionSide) async {
        let start = Date()
        let loserID = contradiction.claimA == winningSide.claim.id ? contradiction.claimB : contradiction.claimA
        guard let store, let loser = try? await store.claim(loserID) else { return }
        let outcome = await correct(
            claim: loser,
            to: winningSide.value,
            reason: "User resolved contradiction in favor of '\(winningSide.value)'",
            priorFailure: "Contradiction \(contradiction.kind.rawValue): \(contradiction.reason)"
        )
        guard outcome.hasPrefix("Corrected.") else {
            ActionFeedbackCenter.shared.record(button: "Resolve Contradiction", command: "BeliefEngine.correct",
                                               outcome: outcome, status: .warning)
            return
        }
        await loadContradictions()
        await loadBeliefs()
        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
        ActionFeedbackCenter.shared.record(
            button: "Keep Version: \(winningSide.subject) \(winningSide.predicate) = \(winningSide.value)",
            command: "Store.correct(claim: \(loserID.value.prefix(8))) -> userConfirmed",
            outcome: "Promoted '\(winningSide.value)' to userConfirmed authority and retracted competing claim in \(ms) ms.",
            status: .completed,
            durationMs: ms
        )
    }

    func inspectClaim(_ claimID: ClaimID) {
        inspectorTask?.cancel()
        let requestID = UUID()
        inspectorRequestID = requestID
        let start = Date()
        showingInspector = true
        inspectorState = .loading
        inspectorTask = Task {
            guard !Task.isCancelled, inspectorRequestID == requestID else { return }
            guard let store else {
                inspectorState = .empty
                return
            }
            do {
                guard let claim = try await store.claim(claimID) else {
                    guard !Task.isCancelled, inspectorRequestID == requestID else { return }
                    inspectorState = .failed("The selected record no longer exists in the store.")
                    return
                }
                let subjectName = try await name(of: claim.subject, in: store)
                let displayVal = try await value(of: claim, in: store)
                let row = ClaimRow(
                    id: claim.id,
                    subjectID: claim.subject,
                    subject: subjectName,
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    objectEntityID: claim.objectEntity,
                    value: displayVal,
                    claim: claim
                )
                let currentBelief = try await store.currentBelief(key: claim.claimKey)
                var supportingDetails: [EvidenceDetail] = []
                for (ev, _, weight) in try await store.evidence(for: claim.id, stance: .supports) {
                    let obj = try await store.object(ev.objectID)
                    supportingDetails.append(EvidenceDetail(evidence: ev, object: obj, weight: weight))
                }
                var refutingDetails: [EvidenceDetail] = []
                for (ev, _, weight) in try await store.evidence(for: claim.id, stance: .refutes) {
                    let obj = try await store.object(ev.objectID)
                    refutingDetails.append(EvidenceDetail(evidence: ev, object: obj, weight: weight))
                }
                guard !Task.isCancelled, inspectorRequestID == requestID else { return }
                inspectorState = .claim(ClaimInspection(
                    row: row,
                    belief: currentBelief,
                    supporting: supportingDetails,
                    refuting: refutingDetails
                ))
                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                ActionFeedbackCenter.shared.record(
                    button: "Inspect Claim: \(subjectName) · \(row.predicate)",
                    command: "Store.evidence(for: \(claim.id.value.prefix(8)))",
                    outcome: "Opened Provenance Inspector with \(supportingDetails.count) supporting quote(s) and \(refutingDetails.count) refuting quote(s) for '\(subjectName) \(row.predicate) = \(displayVal)'.",
                    status: .completed,
                    durationMs: ms
                )
            } catch {
                guard !Task.isCancelled, inspectorRequestID == requestID else { return }
                inspectorState = .failed("Could not load provenance: \(error.localizedDescription)")
                ActionFeedbackCenter.shared.record(button: "Inspect Provenance", command: "Load store evidence",
                                                   outcome: error.localizedDescription, status: .warning)
            }
        }
    }

    func inspectObject(_ objectID: ObjectID, highlight: String? = nil) {
        inspectorTask?.cancel()
        let requestID = UUID()
        inspectorRequestID = requestID
        let start = Date()
        showingInspector = true
        inspectorState = .loading
        inspectorTask = Task {
            guard !Task.isCancelled, inspectorRequestID == requestID else { return }
            guard let store else {
                inspectorState = .empty
                return
            }
            do {
                guard let object = try await store.object(objectID) else {
                    guard !Task.isCancelled, inspectorRequestID == requestID else { return }
                    inspectorState = .failed("The selected record no longer exists in the store.")
                    return
                }
                let chunks = try await store.chunks(forObject: objectID)
                let subjectIDs = try await store.claimSubjects(forObject: objectID)
                var derivedRows: [ClaimRow] = []
                for subjectID in subjectIDs {
                    for claim in try await store.claims(subject: subjectID, currentOnly: false) {
                        let supporting = try await store.evidence(for: claim.id, stance: .supports)
                        guard supporting.contains(where: { $0.0.objectID == objectID }) else { continue }
                        derivedRows.append(ClaimRow(
                            id: claim.id,
                            subjectID: claim.subject,
                            subject: try await name(of: claim.subject, in: store),
                            predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                            objectEntityID: claim.objectEntity,
                            value: try await value(of: claim, in: store),
                            claim: claim
                        ))
                    }
                }
                guard !Task.isCancelled, inspectorRequestID == requestID else { return }
                inspectorState = .object(ObjectInspection(
                    object: object,
                    chunks: chunks,
                    derivedClaims: derivedRows,
                    highlight: highlight
                ))
                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                ActionFeedbackCenter.shared.record(
                    button: "Inspect Floor Object: \(object.title)",
                    command: "Store.object(\(objectID.value.prefix(8))) + chunks + claims",
                    outcome: "Opened '\(object.title)' (\(object.kind.rawValue)) in Provenance Inspector: \(chunks.count) passage(s), \(derivedRows.count) derived claim(s).",
                    status: .completed,
                    durationMs: ms
                )
            } catch {
                guard !Task.isCancelled, inspectorRequestID == requestID else { return }
                inspectorState = .failed("Could not load provenance: \(error.localizedDescription)")
                ActionFeedbackCenter.shared.record(button: "Inspect Provenance", command: "Load store evidence",
                                                   outcome: error.localizedDescription, status: .warning)
            }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        // The window and the menu bar both call this, and the guard on `store` does not cover
        // the await below, so two callers could open two connections.
        guard store == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        state = .working("opening store")
        BeliefNotifier.requestAuthorizationIfNeeded()
        do {
            let opened = try await Store.open()
            store = opened
            storePath = await opened.database.path.path
            await refresh()
            await SpotlightIndexer.indexEntities(from: opened)
            state = .idle
            Task { await refreshMachineHealth() }
            Task { await refreshFleetStatus() }
            startScheduledSync()
        } catch {
            state = .failed("\(error)")
        }
    }

    private var isStarting = false

    /// The one way this app derives anything from objects.
    func pipeline(for store: Store) -> IngestPipeline {
        IngestPipeline(store: store, chunker: settings.chunker)
    }

    func refresh() async {
        guard let store else { return }
        do {
            objectCount = try await store.objectCount()
            entityCount = try await store.entities().count
            claimCount = try await store.claimCount()
            openContradictionCount = try await store.contradictions(unresolvedOnly: true).count
            sources = try await store.sources()
            countsByKind = try await store.objectCountsByKind()
            chunkCount = try await store.chunkCount()
            if let run = try await store.embeddingRuns().first {
                embeddingModel = run.model
                embeddedCount = run.chunksDone
            } else {
                embeddedCount = 0
            }
            if let wantedSection = PendingSection.shared.take() {
                selectedSection = wantedSection
            }
            projectBriefs = await loadProjectBriefs(from: store)
            dataGeneration &+= 1
        } catch {
            state = .failed("\(error)")
        }
    }

    private func loadProjectBriefs(from store: Store) async -> [ProjectBrief] {
        guard let allEntities = try? await store.entities() else { return [] }
        let entities = allEntities.filter { $0.kind == .project }.prefix(80)
        let openConflicts = (try? await store.contradictions(unresolvedOnly: true)) ?? []
        var briefs: [ProjectBrief] = []

        for entity in entities {
            guard let claims = try? await store.claims(subject: entity.id, currentOnly: true),
                  !claims.isEmpty
            else { continue }

            var status: String?
            var primaryLanguage: String?
            var lastVerifiedCommit: String?
            var objective: String?
            var nextAction: String?
            var verifyCommand: String?
            let claimIDs = Set(claims.map(\.id))
            let hasConflict = openConflicts.contains { claimIDs.contains($0.claimA) || claimIDs.contains($0.claimB) }

            for claim in claims {
                switch claim.predicate {
                case Predicate.status:
                    if status == nil { status = claim.literal }
                case Predicate.primaryLanguage:
                    if primaryLanguage == nil {
                        primaryLanguage = try? await value(of: claim, in: store)
                    }
                case Predicate.lastVerifiedCommit:
                    if lastVerifiedCommit == nil { lastVerifiedCommit = claim.literal }
                case Predicate.objective:
                    if objective == nil { objective = claim.literal }
                case Predicate.nextAction:
                    if nextAction == nil { nextAction = claim.literal }
                case Predicate.verifyCommand:
                    if verifyCommand == nil { verifyCommand = claim.literal }
                default:
                    break
                }
            }

            briefs.append(ProjectBrief(
                id: entity.id,
                name: entity.canonicalName,
                status: status,
                primaryLanguage: primaryLanguage,
                lastVerifiedCommit: lastVerifiedCommit,
                objective: objective,
                nextAction: nextAction,
                verifyCommand: verifyCommand,
                claimCount: claims.count,
                hasOpenConflict: hasConflict
            ))
        }

        return briefs.sorted { lhs, rhs in
            let lRich = (lhs.objective != nil ? 4 : 0) + (lhs.lastVerifiedCommit != nil ? 2 : 0) + (lhs.nextAction != nil ? 1 : 0)
            let rRich = (rhs.objective != nil ? 4 : 0) + (rhs.lastVerifiedCommit != nil ? 2 : 0) + (rhs.nextAction != nil ? 1 : 0)
            if lRich != rRich { return lRich > rRich }
            return lhs.claimCount > rhs.claimCount
        }
    }

    // MARK: - Sync & Operator Console State

    var chunkCount = 0
    var embeddedCount = 0
    var embeddingModel: String?

    var fleetCards: [FleetRepoCard] = []
    var isLoadingFleet = false
    var machineHealth: MachineHealthSnapshot?
    var agentEcosystem: AgentEcosystemSnapshot?
    var isLoadingMachineHealth = false
    var activeAuditRepo: FleetRepoCard?
    var activeAuditOutput: String?
    var isRunningRepoAudit = false

    func refreshFleetStatus() async {
        guard !isLoadingFleet else { return }
        isLoadingFleet = true
        defer { isLoadingFleet = false }
        async let cardsTask = OperatorConsoleService.collectFleet()
        async let ecoTask = OperatorConsoleService.collectAgentEcosystem()
        let (cards, eco) = await (cardsTask, ecoTask)
        if !cards.isEmpty {
            fleetCards = cards
        }
        agentEcosystem = eco
    }

    func refreshSingleRepo(_ card: FleetRepoCard) async {
        guard let updated = await OperatorConsoleService.collectSingleRepo(
            root: card.root,
            existingName: card.name,
            existingDesc: card.desc
        ) else { return }
        if let idx = fleetCards.firstIndex(where: { $0.name == card.name }) {
            fleetCards[idx] = updated
        }
    }

    func refreshMachineHealth(checkTailnet: Bool = true) async {
        guard !isLoadingMachineHealth else { return }
        isLoadingMachineHealth = true
        defer { isLoadingMachineHealth = false }
        async let healthTask = OperatorConsoleService.collectMachineHealth(checkTailnet: checkTailnet)
        async let ecoTask = OperatorConsoleService.collectAgentEcosystem()
        let (health, eco) = await (healthTask, ecoTask)
        machineHealth = health
        agentEcosystem = eco
    }

    func auditRepository(_ card: FleetRepoCard) async {
        activeAuditRepo = card
        activeAuditOutput = nil
        isRunningRepoAudit = true
        let report = await OperatorConsoleService.runReadOnlyRepoAudit(repo: card)
        activeAuditOutput = report
        isRunningRepoAudit = false
    }

    /// Says why a sync skipped repositories, because the skip is otherwise silent. See
    /// `AgentMemoryPolicy.classification`.
    private func reportPrivateNamesProblem(button: String) {
        guard let problem = LocalPrivateNames.currentProblem else { return }
        ActionFeedbackCenter.shared.record(
            button: button,
            command: "LocalPrivateNames.read()",
            outcome: problem.explanation,
            status: .noOpExplained
        )
    }

    /// Scans `~/Documents/GitHub`, `~/Claude/Projects`, and `~/Documents/Projects` for local
    /// repository state and documentation files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `README.md`,
    /// `STATE.md`, `HANDOFF.md`, `ARCHITECTURE.md`, `.claude/.state/last-stop.md`) and ingests them
    /// directly at their permanent file paths without walking build trees or `.git`.
    @discardableResult
    func syncLocalGitHubWorkspace() async -> SyncSchedule.Outcome {
        reportPrivateNamesProblem(button: "Sync Connector: Local Repository Docs")
        let found = await Task.detached(priority: .utility) { AgentMemoryPolicy.discoverRepositories() }.value
        return await sync(found, handle: "GitHub-Workspace", label: "Local Repository Docs (\(found.roots.count) files)", job: .repositories)
    }

    /// Ingests unified memory and rule files across Claude Code (`~/.claude/projects/*/memory`),
    /// Codex (`~/.codex/memories/MEMORY.md`, `memory_summary.md`, `rollout_summaries/*.md`, `STATE.md`),
    /// and Antigravity (`~/.gemini/config/rules/gunnar.md`, `codex-antigravity-parity.md`, `MACHINE-MAP.md`).
    @discardableResult
    func syncCrossAgentMemories() async -> SyncSchedule.Outcome {
        reportPrivateNamesProblem(button: "Sync Connector: Agent Memories")
        let found = await Task.detached(priority: .utility) { AgentMemoryPolicy.discoverMemories() }.value
        return await sync(found, handle: "Cross-Agent-Memory", label: "Claude + Codex + Antigravity Memories (\(found.roots.count) roots)", job: .memories)
    }

    /// Read what a walk of the agents' folders found. The walk itself stays off the main actor in
    /// both callers: it lists three folders and checks twelve paths per repository, some under
    /// `~/Documents`, where iCloud has stalled single files for minutes, and a schedule starts
    /// this with nobody watching a window that has stopped drawing.
    private func sync(_ found: AgentMemoryPolicy.Discovery, handle: String, label: String, job: SyncSchedule.Job) async -> SyncSchedule.Outcome {
        guard !found.roots.isEmpty else {
            // Nothing to read, so nothing moves. With everything withheld that is worth a record.
            guard let reason = found.unread.first else { return .finished(read: 0, changed: 0) }
            return noting(.held(read: 0, changed: 0, reason: reason), for: job)
        }
        let connector = FilesystemConnector(handle: handle, roots: found.roots, knownUnread: found.unread)
        return noting(await sync(connector, label: label), for: job)
    }

    /// Syncs a single repository's anchor docs and Claude memory folder into OpenCore.
    func syncSingleRepository(_ card: FleetRepoCard) async {
        guard !card.root.isEmpty, !card.missingDir else { return }
        let repoURL = URL(fileURLWithPath: card.root, isDirectory: true)
        let anchorRelativePaths = [
            "CLAUDE.md", "AGENTS.md", "README.md", "HANDOFF.md",
            "Docs/ai/STATE.md", "docs/ai/STATE.md", "Docs/HANDOFF.md", "docs/HANDOFF.md",
            "Docs/ARCHITECTURE.md", "docs/ARCHITECTURE.md", ".claude/.state/last-stop.md",
        ]
        var roots: [FilesystemConnector.Root] = []
        for rel in anchorRelativePaths {
            let fileURL = repoURL.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                if let policy = AgentMemoryPolicy.classification(for: fileURL) {
                    roots.append(FilesystemConnector.Root(url: fileURL, domain: policy.domain, authority: policy.authority))
                }
            }
        }
        if !card.slugDir.isEmpty {
            let expandedSlug = (card.slugDir as NSString).expandingTildeInPath
            let memURL = URL(fileURLWithPath: expandedSlug, isDirectory: true)
                .appendingPathComponent("memory", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: memURL.path, isDirectory: &isDir), isDir.boolValue {
                if let policy = AgentMemoryPolicy.classification(for: memURL) {
                    roots.append(FilesystemConnector.Root(url: memURL, domain: policy.domain, authority: policy.authority))
                }
            }
        }
        guard !roots.isEmpty else { return }
        let connector = FilesystemConnector(handle: "Repo-\(card.name)", roots: roots)
        await sync(connector, label: "\(card.name) docs & memories")
        await buildEmbeddings()
        await refreshSingleRepo(card)
    }

    /// 1-click full refresh: local repository state docs, cross-agent memories
    /// (`~/.claude/projects/*/memory` + `MACHINE-MAP.md`), GitHub API, Calendar, Reminders, Notes
    /// and semantic embeddings.
    ///
    /// The Apple sources were left out, so "Sync All" did not sync all, and nothing else ever
    /// ran them either. That is why they stopped on 2026-08-14.
    ///
    /// One pass in the sync lane, so a second press or a scheduled tick cannot run on top of it.
    func syncAllWorkspaceAndSources() async {
        let hasToken = await checkGitHubToken()
        let ran = await exclusively("Sync All", refused: { _ in false }) {
            await syncLocalGitHubWorkspace()
            await syncCrossAgentMemories()
            if hasToken {
                await syncGitHub()
            }
            await syncCalendar()
            await syncReminders()
            await syncNotes()
            await buildEmbeddings()
            return true
        }
        guard ran else { return }
        await refreshFleetStatus()
        await refreshMachineHealth(checkTailnet: false)
    }

    @discardableResult
    func syncGitHub() async -> SyncSchedule.Outcome {
        noting(await readGitHub(), for: .github)
    }

    private func readGitHub() async -> SyncSchedule.Outcome {
        let resolved = await Task.detached {
            GitHubConnector.invalidateTokenCache()
            return GitHubConnector.resolveTokenWithSource()
        }.value
        guard let token = resolved.token else {
            return failSync(resolved.source == .none
                ? "No GitHub token. Set GITHUB_TOKEN or run `gh auth login` in Terminal."
                : resolved.source.rawValue)
        }
        do {
            struct User: Decodable { let login: String }
            var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let login = (try? JSONDecoder().decode(User.self, from: data))?.login else {
                return failSync("Could not resolve the GitHub account for this token.")
            }
            return await sync(GitHubConnector(login: login, token: token, commitsPerRepo: settings.githubCommitsPerRepo, includeForks: settings.githubIncludeForks), label: "github:\(login)")
        } catch {
            return failSync("\(error)")
        }
    }

    /// - Parameters:
    ///   - full: re-read everything the connector can reach, ignoring the last sync date. Needed
    ///     once after a connector learns a new field, because only an object that gets re-read
    ///     can gain it.
    ///   - unattended: nobody started this, so it must not raise a permission prompt.
    @discardableResult
    func syncCalendar(full: Bool = false, unattended: Bool = false) async -> SyncSchedule.Outcome {
        noting(await sync(AppleEventKitConnector(scope: .calendar, lookBackDays: settings.calendarLookBackDays, lookAheadDays: settings.calendarLookAheadDays, unattended: unattended), label: "Calendar", full: full), for: .calendar)
    }
    @discardableResult
    func syncReminders(full: Bool = false, unattended: Bool = false) async -> SyncSchedule.Outcome {
        noting(await sync(AppleEventKitConnector(scope: .reminders, unattended: unattended), label: "Reminders", full: full), for: .reminders)
    }
    @discardableResult
    func syncNotes(full: Bool = false) async -> SyncSchedule.Outcome {
        noting(await sync(AppleNotesConnector(), label: "Notes", full: full), for: .notes)
    }
    func syncHealth() async { await sync(HealthKitConnector(), label: "Health") }

    func syncFolder(_ url: URL, domain: Domain) async {
        await sync(FilesystemConnector.handedOver(folder: url, domain: domain), label: "\(url.lastPathComponent) [\(domain.rawValue)]")
    }

    /// Ingests files (`.pdf`, `.md`, source code, notes) or folders dropped onto the app window.
    /// Directories sync directly as roots; individual files are passed as single-file roots, so
    /// dropping one file from `~/Downloads` never walks the parent folder.
    func ingestDroppedURLs(_ urls: [URL], domain: Domain = .project) async {
        guard !urls.isEmpty else { return }
        var directories: [URL] = []
        var singleFiles: [URL] = []
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    directories.append(url)
                } else {
                    singleFiles.append(url)
                }
            }
        }

        for dir in directories {
            await syncFolder(dir, domain: domain)
        }

        guard !singleFiles.isEmpty else { return }
        let connector = FilesystemConnector.handedOver(files: singleFiles, domain: domain)
        await sync(connector, label: "\(singleFiles.count) dropped file\(singleFiles.count == 1 ? "" : "s") [\(domain.rawValue)]")
    }

    /// One sync path for every connector, so the app cannot drift from the CLI.
    ///
    /// The decisions are in `SourceSync`, which the CLI shares and tests can reach. This is the
    /// part that belongs to a window: status, feedback, notifications. Runs in the sync lane, and
    /// reports what happened so a schedule can tell a failure from nothing new.
    @discardableResult
    private func sync(_ connector: any Connector, label: String, full: Bool = false) async -> SyncSchedule.Outcome {
        await exclusively(label, refused: { .refused($0) }) {
            await read(connector, label: label, full: full)
        }
    }

    private func read(_ connector: any Connector, label: String, full: Bool) async -> SyncSchedule.Outcome {
        guard let store else { return .failed("The store is not open.") }
        let start = Date()
        state = .working("connecting to \(label)")
        ActionFeedbackCenter.shared.record(
            button: "Sync Connector: \(label)",
            command: "Connector.fetch(source: \(connector.source.handle))",
            outcome: "Connecting to \(label) and scanning for new or modified records...",
            status: .running
        )
        do {
            try await store.upsert(connector.source)
            let report = try await SourceSync(store: store, pipeline: pipeline(for: store)).run(
                connector.source.id,
                reach: full ? .everything : .sinceLastSync,
                phase: { [weak self] phase in await self?.showSyncPhase(phase, label: label) },
                fetch: { since in try await connector.fetch(since: since, cursor: nil) { _ in } }
            )
            let result = SyncSchedule.Outcome(read: report.read, changed: report.changed, heldBecause: report.heldBecause)

            guard let outcome = report.derived else {
                await refresh()
                finishRead(report, label: label)
                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                ActionFeedbackCenter.shared.record(
                    button: "Sync Connector: \(label)",
                    command: "Connector.fetch(since: \(report.since.map { "\($0)" } ?? "nil"))",
                    outcome: report.heldBecause.map { "\(label): \($0)" } ?? "Scanned \(label) in \(ms) ms: 0 new or modified items since last sync.",
                    status: report.unread.isEmpty ? .noOpExplained : .warning,
                    durationMs: ms
                )
                return result
            }

            await BeliefNotifier.notifyIfNeeded(outcome: outcome, since: report.startedAt, store: store)
            await SpotlightIndexer.indexEntities(from: store)
            await refresh()
            finishRead(report, label: label)
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            let held = report.heldBecause.map { " \($0)" } ?? ""
            ActionFeedbackCenter.shared.record(
                button: "Sync Connector: \(label)",
                command: "IngestPipeline.run(objects: \(report.read))",
                outcome: "Processed \(report.read) item(s) from \(label): derived \(outcome.chunks) passages, \(outcome.entities) entities, and \(outcome.claims) claims in \(ms) ms.\(held)",
                status: report.unread.isEmpty ? .completed : .warning,
                durationMs: ms
            )
            return result
        } catch {
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            ActionFeedbackCenter.shared.record(
                button: "Sync Connector: \(label)",
                command: "Connector.fetch(\(connector.source.handle))",
                outcome: "Sync notice for \(label): \(error)",
                status: .warning,
                durationMs: ms
            )
            return failSync("\(label): \(error)")
        }
    }

    /// A read that fell short raises the banner, because the store is missing something. One that
    /// simply found nothing does not: an empty first read of an empty source is nobody's failure.
    private func finishRead(_ report: SourceSync.Report, label: String) {
        if !report.unread.isEmpty, let held = report.heldBecause {
            state = .failed("\(label): \(held)")
        } else {
            state = .idle
        }
    }

    private func showSyncPhase(_ phase: SourceSync.Phase, label: String) {
        switch phase {
        case .fetching: state = .working("fetching from \(label)")
        case .deriving(let objects): state = .working("deriving from \(objects) objects")
        }
    }

    /// The one way a sync fails: visible now, and carried back to whoever keeps the record.
    /// The record used to read the shared failure slot, which could hold someone else's error,
    /// or nothing when a sync gave up before setting it.
    private func failSync(_ message: String) -> SyncSchedule.Outcome {
        state = .failed(message)
        return .failed(message)
    }

    /// Build vectors for every passage that lacks one. Resumable: interrupting it and
    /// running again continues rather than restarting.
    func buildEmbeddings() async {
        guard let store else { return }
        let start = Date()
        let beforeEmbedded = embeddedCount
        ActionFeedbackCenter.shared.record(
            button: "Build Semantic Vector Index",
            command: "EmbeddingIndexer.run(provider: NLEmbeddingProvider 512-d)",
            outcome: "Scanning \(chunkCount) passages for missing 512-d semantic vectors...",
            status: .running
        )
        do {
            let provider = try NLEmbeddingProvider()
            embeddingModel = provider.modelIdentifier
            state = .working("preparing \(provider.modelIdentifier)")

            let indexer = EmbeddingIndexer(store: store, provider: provider)
            _ = try await indexer.run(batchSize: 32) { [weak self] message in
                Task { @MainActor in self?.state = .working(message) }
            }
            await refresh()
            state = .idle
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            let delta = max(0, embeddedCount - beforeEmbedded)
            ActionFeedbackCenter.shared.record(
                button: "Build Semantic Vector Index",
                command: "NLEmbeddingProvider(\(provider.modelIdentifier))",
                outcome: delta == 0
                    ? "Verified all \(embeddedCount) of \(chunkCount) passages already have 512-d semantic vectors on disk (0 missing)."
                    : "Computed \(delta) new 512-d vector(s) on device (\(embeddedCount)/\(chunkCount) passages covered).",
                status: delta == 0 ? .noOpExplained : .completed,
                durationMs: ms
            )
        } catch {
            state = .failed("embedding: \(error)")
        }
    }

    // MARK: - Asking

    private var answerRequestID = UUID()

    func clearAnswer() {
        answerRequestID = UUID()
        answer = nil
        traceRows = []
        if case .working("answering") = state { state = .idle }
    }

    func ask(_ query: String) async {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let requestID = UUID()
        answerRequestID = requestID
        state = .working("answering")
        do {
            let reasoner = Reasoner(store: store, embedder: try? NLEmbeddingProvider(), tuning: settings.tuning)
            let result = try await reasoner.answer(query)
            guard !Task.isCancelled, answerRequestID == requestID else { return }
            answer = result
            traceRows = []
            state = .idle
        } catch {
            guard !Task.isCancelled, answerRequestID == requestID else { return }
            state = .failed("\(error)")
        }
    }

    /// Deterministic claim & counter-evidence query for ChatView (`persistReceipt: false`) and MenuBarExtra (`persistReceipt: true`).
    func reasonAnswer(_ query: String, persistReceipt: Bool = true) async -> Answer? {
        guard let store, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let reasoner = Reasoner(store: store, embedder: try? NLEmbeddingProvider(), tuning: settings.tuning)
        return try? await reasoner.answer(query, persistReceipt: persistReceipt)
    }

    func loadTrace(for receipt: Receipt) async {
        guard let store else { return }
        do {
            traceRows = try await store.trace(receipt: receipt.id).map {
                TraceRow(id: $0.0.id, evidence: $0.0, object: $0.1, score: $0.2)
            }
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Browsing

    func loadClaims(for subject: KnowledgeSubject? = nil) async {
        guard let store else { return }
        let requestID = UUID()
        if subject == nil { claimsLoadID = requestID }
        else { subjectClaimsLoadID = requestID }
        do {
            var rows: [ClaimRow] = []
            // Scope at the store boundary; filtering a global 400-row page hides older subjects.
            let loaded: [CoreClaim]
            if let subject {
                loaded = try await store.claims(subject: subject.id)
            } else {
                loaded = try await store.allClaims(limit: 400)
            }
            for claim in loaded {
                guard !Task.isCancelled else { return }
                rows.append(ClaimRow(
                    id: claim.id,
                    subjectID: claim.subject,
                    subject: try await name(of: claim.subject, in: store),
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    objectEntityID: claim.objectEntity,
                    value: try await value(of: claim, in: store),
                    claim: claim
                ))
            }
            guard !Task.isCancelled else { return }
            if let subject {
                guard subjectClaimsLoadID == requestID, claimsSubject == subject else { return }
                subjectClaims = rows
            } else {
                guard claimsLoadID == requestID else { return }
                claims = rows
            }
        } catch {
            guard !Task.isCancelled else { return }
            if let subject {
                guard subjectClaimsLoadID == requestID, claimsSubject == subject else { return }
            } else {
                guard claimsLoadID == requestID else { return }
            }
            state = .failed("\(error)")
        }
    }

    func loadBeliefs() async {
        guard let store else { return }
        do {
            var rows: [BeliefRow] = []
            for belief in try await store.beliefsDecided(since: .distantPast) {
                guard let claim = try await store.claim(belief.claimID) else { continue }
                rows.append(BeliefRow(
                    id: belief.id,
                    subjectID: claim.subject,
                    subject: try await name(of: claim.subject, in: store),
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    objectEntityID: claim.objectEntity,
                    value: try await value(of: claim, in: store),
                    belief: belief
                ))
            }
            beliefs = rows
        } catch {
            state = .failed("\(error)")
        }
    }

    func loadContradictions() async {
        guard let store else { return }
        do {
            var rows: [ContradictionRow] = []
            for contradiction in try await store.contradictions() {
                var sides: [ContradictionSide] = []
                var firstSubjectID: EntityID?
                var firstSubjectName: String?
                for id in [contradiction.claimA, contradiction.claimB] {
                    guard let claim = try await store.claim(id) else { continue }
                    let subject = try await name(of: claim.subject, in: store)
                    if firstSubjectID == nil {
                        firstSubjectID = claim.subject
                        firstSubjectName = subject
                    }
                    let val = try await value(of: claim, in: store)
                    let pred = claim.predicate.replacingOccurrences(of: "_", with: " ")
                    let label: String
                    if contradiction.winner == id {
                        label = "kept"
                    } else if contradiction.resolution == .unresolved {
                        label = "open"
                    } else {
                        label = "retired"
                    }
                    sides.append(ContradictionSide(
                        claim: claim,
                        subjectID: claim.subject,
                        subject: subject,
                        predicate: pred,
                        value: val,
                        label: label,
                        text: "\(subject) \(pred) \(val)  ·  \(claim.authority.label)",
                        kept: contradiction.winner == id
                    ))
                }
                rows.append(ContradictionRow(
                    id: contradiction.id,
                    contradiction: contradiction,
                    subjectID: firstSubjectID,
                    subjectName: firstSubjectName,
                    sides: sides
                ))
            }
            contradictions = rows
        } catch {
            state = .failed("\(error)")
        }
    }

    func loadReceipts() async {
        guard let store else { return }
        do { receipts = try await store.receipts(limit: 100) } catch { state = .failed("\(error)") }
    }

    // MARK: - Naming

    func name(of entity: EntityID, in store: Store) async throws -> String {
        try await store.entity(entity)?.canonicalName ?? String(entity.value.prefix(8))
    }

    func value(of claim: CoreClaim, in store: Store) async throws -> String {
        if let objectEntity = claim.objectEntity, let resolved = try await store.entity(objectEntity) {
            return resolved.canonicalName
        }
        return claim.literal ?? "unknown"
    }

    // MARK: - On-Device Foundation Model (`/usr/bin/fm`) Synthesis & Claim Proposal (`v0.6` #11)

    func proposeClaimsForObject(_ objectID: ObjectID) async throws -> ModelClaimProposer.ProposalOutcome {
        guard let store else { throw CocoaError(.fileReadNoSuchFile) }
        state = .working("Extracting claims and verifying source spans")
        do {
            guard let object = try await store.object(objectID) else { throw CocoaError(.fileReadNoSuchFile) }
            let outcome = try await ModelClaimProposer(store: store).propose(from: object)
            await refresh()
            if case .working = state { state = .idle }
            if case .object(let current) = inspectorState, current.object.id == objectID {
                inspectObject(objectID, highlight: current.highlight)
            }
            return outcome
        } catch {
            state = .failed("Extraction failed: \(error.localizedDescription)")
            throw error
        }
    }

    func proposeClaimsForEntity(_ entityID: EntityID) async throws -> [ModelClaimProposer.ProposalOutcome] {
        guard let store else { throw CocoaError(.fileReadNoSuchFile) }
        state = .working("Extracting claims and verifying source spans")
        do {
            let outcomes = try await ModelClaimProposer(store: store).proposeForEntity(entityID, limit: 4)
            await refresh()
            if case .working = state { state = .idle }
            return outcomes
        } catch {
            state = .failed("Extraction failed: \(error.localizedDescription)")
            throw error
        }
    }

    func synthesizeEntityBrief(_ dossier: EntityDossier) async -> Conversation.GroundedBrief? {
        var sources: [GroundingSource] = []
        let fallbackObjID = ObjectID.derived(from: "dossier", dossier.entity.id.value)

        let claimLines = dossier.claims.prefix(12).map { row in
            "\(dossier.entity.canonicalName) \(row.claim.predicate) \(row.value) (\(row.claim.derivation.rawValue), \(row.claim.authority.label))"
        }
        if !claimLines.isEmpty {
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: "\(dossier.entity.canonicalName) · Active Believed Claims",
                text: claimLines.joined(separator: "\n"),
                objectID: fallbackObjID,
                authority: .authoredArtifact,
                uri: nil
            ))
        }

        if !dossier.contradictions.isEmpty {
            let conflictLines = dossier.contradictions.prefix(6).map {
                "\($0.kind.rawValue) (\($0.resolution.rawValue)): \($0.reason)"
            }
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: "\(dossier.entity.canonicalName) · Contradictions",
                text: conflictLines.joined(separator: "\n"),
                objectID: fallbackObjID,
                authority: .authoredArtifact,
                uri: nil
            ))
        }

        if !dossier.events.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let eventLines = dossier.events.prefix(8).map {
                "\(fmt.string(from: $0.occurredAt)) \($0.verb): \($0.detail)"
            }
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: "\(dossier.entity.canonicalName) · Recent Activity Timeline",
                text: eventLines.joined(separator: "\n"),
                objectID: fallbackObjID,
                authority: .authoredArtifact,
                uri: nil
            ))
        }

        if let passageRes = await searchPassages(dossier.entity.canonicalName, readingTime: false) {
            for hit in passageRes.rows.prefix(max(0, 6 - sources.count)) {
                sources.append(GroundingSource(
                    index: sources.count + 1,
                    title: hit.title,
                    text: hit.text,
                    objectID: hit.objectID,
                    authority: .authoredArtifact,
                    uri: nil
                ))
            }
        }

        guard !sources.isEmpty else { return nil }
        return await Conversation.synthesizeGroundedBrief(
            question: "Summarize what is known about \(dossier.entity.canonicalName), including its primary technology/purpose, current status or objective, and any conflicts or recent activity.",
            sources: sources
        )
    }

    func synthesizeContradictionAnalysis(_ row: ContradictionRow) async -> Conversation.GroundedBrief? {
        guard let store else { return nil }
        var sources: [GroundingSource] = []
        for (idx, side) in row.sides.prefix(2).enumerated() {
            let evidenceRows = (try? await store.evidence(for: side.claim.id)) ?? []
            var lines: [String] = [
                "Claim (\(side.label)): \(side.text)",
                "Authority: \(side.claim.authority.label), Derivation: \(side.claim.derivation.rawValue), Confidence: \(String(format: "%.2f", side.claim.confidence))",
            ]
            var firstObjectID = ObjectID.derived(from: "claim", side.claim.id.value)
            var firstURI: String?
            for (ev, _, _) in evidenceRows.prefix(2) {
                lines.append("Evidence snippet: \(ev.snippet)")
                firstObjectID = ev.objectID
                if firstURI == nil, let obj = try? await store.object(ev.objectID) {
                    firstURI = obj.uri
                    lines.append("Source object: \(obj.title)")
                }
            }
            sources.append(GroundingSource(
                index: idx + 1,
                title: "Side \(idx == 0 ? "A" : "B") (\(side.label)): \(side.text)",
                text: lines.joined(separator: "\n"),
                objectID: firstObjectID,
                authority: side.claim.authority,
                uri: firstURI
            ))
        }
        guard !sources.isEmpty else { return nil }
        return await Conversation.synthesizeGroundedBrief(
            question: "Compare Side A [1] and Side B [2]: state what each side asserts, which source and authority tier backs each side, and why they conflict (\(row.contradiction.reason)).",
            sources: sources
        )
    }

    func synthesizeTimeTravelBrief(dayText: String, rows: [TimeTravelRow]) async -> Conversation.GroundedBrief? {
        let changedRows = rows.filter { $0.change != .unchanged }
        let selected = (changedRows.isEmpty ? Array(rows.prefix(6)) : Array(changedRows.prefix(6)))
        guard !selected.isEmpty else { return nil }

        let sources: [GroundingSource] = selected.enumerated().map { idx, row in
            let thenText = row.then?.value ?? "not held on \(dayText)"
            let nowText = row.now?.value ?? "retracted / no longer held"
            let reason = (row.now ?? row.then)?.belief.reason ?? ""
            let body = """
            \(row.subject) \(row.predicate) (\(String(describing: row.change))):
            On \(dayText): \(thenText)
            Now: \(nowText)
            Decision reason: \(reason)
            """
            return GroundingSource(
                index: idx + 1,
                title: "\(row.subject) · \(row.predicate) (\(String(describing: row.change)))",
                text: body,
                objectID: ObjectID.derived(from: "timetravel", row.id),
                authority: .authoredArtifact,
                uri: nil
            )
        }
        return await Conversation.synthesizeGroundedBrief(
            question: "Summarize what OpenCore learned, updated, or retracted between \(dayText) and today.",
            sources: sources
        )
    }

    func synthesizeFloorObjectBrief(_ inspection: ObjectInspection) async -> Conversation.GroundedBrief? {
        var sources: [GroundingSource] = inspection.chunks.prefix(6).enumerated().map { idx, chunk in
            GroundingSource(
                index: idx + 1,
                title: "\(inspection.object.title) · passage #\(chunk.ordinal)",
                text: chunk.text,
                objectID: inspection.object.id,
                authority: inspection.object.authority,
                uri: inspection.object.uri
            )
        }
        if sources.isEmpty, !inspection.object.text.isEmpty {
            sources.append(GroundingSource(
                index: 1,
                title: inspection.object.title,
                text: String(inspection.object.text.prefix(1_600)),
                objectID: inspection.object.id,
                authority: inspection.object.authority,
                uri: inspection.object.uri
            ))
        }
        guard !sources.isEmpty else { return nil }
        return await Conversation.synthesizeGroundedBrief(
            question: "Summarize the key facts, decisions, and contents of \(inspection.object.title).",
            sources: sources
        )
    }
}
