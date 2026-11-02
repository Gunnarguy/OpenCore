import CorePresentation
import CoreSpotlight
import CoreTelemetry
import Foundation
import SwiftUI

#if !OPENCORE_REVIEW
@main
struct OpenCoreApp: App {
    @State private var model: AppModel

    init() {
        do { try ReviewSnapshotPolicy.requireProductionArguments(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("Review launch requires the separate OpenCoreReview build.\n".utf8))
            exit(2)
        }
        _model = State(initialValue: AppModel.shared)
    }

    var body: some Scene {
        WindowGroup(id: "main", for: String.self) { _ in
            RootView()
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
                .preferredColorScheme(model.settings.appearanceMode.colorScheme)
                .tint(model.settings.pastelAccent.color)
                .dynamicTypeSize(model.settings.fontScale.dynamicTypeSize)
                .task {
                    model.settings.applyAppearanceToNSApp()
                    await model.start()
                }
                .frame(minWidth: 960, minHeight: 620)
        } defaultValue: {
            "workspace"
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Navigate") {
                Button("Back") {
                    model.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)

                Button("Forward") {
                    model.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)

                Divider()

                Button("Toggle Light / Dark Mode") {
                    model.settings.toggleLightDarkMode()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Quick Jump & Command Palette…") {
                    model.showingQuickJump = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("How OpenCore Fits Together…") { model.showingWorkspaceMap = true }

                Button("J.A.R.V.I.S. Executive & Multimodal HUD…") {
                    model.showingJarvisHUD = true
                }
                .keyboardShortcut("j", modifiers: .command)

                Button(model.showingInspector ? "Hide Provenance Inspector" : "Show Provenance Inspector") {
                    model.showingInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                ComputerRunStopCommand()

                Divider()

                Button("Ask") { model.navigate(to: .ask) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Mac Overview") { model.navigate(to: .macOverview) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Projects") { model.navigate(to: .repoFleet) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Agents") { model.navigate(to: .codingAgents) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Computer Use") { model.navigate(to: .computerControl) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Models") { model.navigate(to: .aiModelsRAM) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Hardware") { model.navigate(to: .hardwareUSB) }
                    .keyboardShortcut("7", modifiers: .command)
                Button("Topics") { model.navigate(to: .entities) }
                    .keyboardShortcut("8", modifiers: .command)
                Button("Events") { model.navigate(to: .timeline) }
                    .keyboardShortcut("9", modifiers: .command)
                Button("Connections") { model.openConnections() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Sync Workspace & Sources Now") {
                    Task { await model.syncAllWorkspaceAndSources() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            VStack(spacing: 0) {
                if let failure = model.failure {
                    FailureBanner(failure: failure) { model.dismissFailure() }
                }
                if case .working(let operation) = model.state {
                    ProgressView(operation)
                        .controlSize(.small)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsView()
            }
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
                .preferredColorScheme(model.settings.appearanceMode.colorScheme)
                .tint(model.settings.pastelAccent.color)
                .dynamicTypeSize(model.settings.fontScale.dynamicTypeSize)
                .frame(minWidth: 900, idealWidth: 1000, minHeight: 620, idealHeight: 720)
                .task {
                    model.settings.applyAppearanceToNSApp()
                    await model.start()
                }
        }

        MenuBarExtra("OpenCore", systemImage: "brain.head.profile") {
            MenuBarView()
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
                .preferredColorScheme(model.settings.appearanceMode.colorScheme)
                .tint(model.settings.pastelAccent.color)
        }
        .menuBarExtraStyle(.window)
    }
}

#endif

/// Every screen. Three places hold them: Ask, Mac and Evidence, in `WorkspaceFamily`.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case ask = "Ask"

    case macOverview = "Overview"
    case repoFleet = "Projects"
    case codingAgents = "Agents"
    case computerControl = "Computer Use"
    case aiModelsRAM = "Models"
    case hardwareUSB = "Hardware"

    case sources = "Sources"
    case corpus = "Originals"
    case passages = "Excerpts"
    case claims = "Statements"
    case beliefs = "Decisions"
    case receipts = "Receipts"
    case entities = "Topics"
    case timeline = "Events"
    case timeTravel = "Time Travel"
    case contradictions = "Checks"
    case maintenance = "Health"

    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .ask: "bubble.left.and.bubble.right"
        case .macOverview: "sparkles.rectangle.stack"
        case .repoFleet: "folder.fill.badge.gearshape"
        case .codingAgents: "point.3.filled.connected.trianglepath.dotted"
        case .computerControl: "viewfinder.rectangular"
        case .aiModelsRAM: "cpu.fill"
        case .hardwareUSB: "cable.connector.horizontal"
        case .entities: "point.3.connected.trianglepath.dotted"
        case .corpus: "chart.pie"
        case .passages: "doc.text.magnifyingglass"
        case .claims: "list.bullet.rectangle"
        case .beliefs: "checkmark.seal"
        case .timeline: "clock.arrow.circlepath"
        case .timeTravel: "clock.badge.checkmark"
        case .contradictions: "checkmark.shield"
        case .receipts: "receipt"
        case .sources: "arrow.triangle.2.circlepath"
        case .maintenance: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(\.appModel) private var model
    @AppStorage("sidebar.showEvidence") private var showEvidence = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedSection }, set: { model.navigate(to: $0) })) {
                sidebarLabel(.ask).tag(Section.ask)

                SwiftUI.Section(WorkspaceFamily.mac.rawValue) {
                    ForEach(WorkspaceFamily.mac.sections) { item in
                        sidebarLabel(item).tag(item)
                    }
                }

                SwiftUI.Section {
                    if showEvidence {
                        ForEach(WorkspaceFamily.evidence.sections) { item in
                            sidebarLabel(item)
                                .badge(item == .contradictions ? model.openContradictionCount : 0)
                                .tag(item)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showEvidence.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(WorkspaceFamily.evidence.rawValue)
                            Image(systemName: showEvidence ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                SwiftUI.Section {
                    sidebarLabel(.settings).tag(Section.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 300)
            .safeAreaInset(edge: .bottom) { StatusBar() }
            .onChange(of: model.selectedSection) { _, newSection in
                if newSection.family == .evidence { showEvidence = true }
            }
        } detail: {
            // The automatic inspector entered an AppKit layout cycle on this Mac when opened.
            // Own this split explicitly so the evidence pane has bounded space in the window.
            HSplitView {
                VStack(spacing: 0) {
                    if let failure = model.failure {
                        FailureBanner(failure: failure) { model.dismissFailure() }
                    }
                    ComputerRunStopBar()
                    ActionFeedbackBar()
                    // Evidence screens are the ones that need explaining. Ask and Mac speak for themselves.
                    if model.selectedSection.family == .evidence {
                        WorkspaceOrientationView(section: model.selectedSection)
                    }
                    if let subject = model.knowledgeSubject(for: model.selectedSection) {
                        KnowledgeSubjectBanner(subject: subject) { model.navigate(to: model.selectedSection) }
                    }
                    detailView(for: model.selectedSection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if model.showingInspector {
                    ProvenanceInspector()
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 480, maxHeight: .infinity)
                }
            }
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    Task { await model.ingestDroppedURLs(urls) }
                    return true
                } isTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isDropTargeted = targeted
                    }
                }
                .overlay {
                    if isDropTargeted {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                                .padding(10)
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text("Drop files, PDFs, screenshots, or folders to ingest into OpenCore")
                                    .font(.headline)
                                Text("Objects are extracted (with Vision OCR for images and scanned PDFs), chunked, and reconciled on device.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(24)
                            .openCoreGlassCard(cornerRadius: 16, tint: .accentColor)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            model.goBack()
                            ActionFeedbackCenter.shared.record(
                                button: "Navigate Back",
                                command: "AppModel.goBack()",
                                outcome: "Returned to \(model.selectedSection.rawValue).",
                                status: .completed
                            )
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!model.canGoBack)
                        .help("Back (⌘[)")

                        Button {
                            model.goForward()
                            ActionFeedbackCenter.shared.record(
                                button: "Navigate Forward",
                                command: "AppModel.goForward()",
                                outcome: "Advanced to \(model.selectedSection.rawValue).",
                                status: .completed
                            )
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!model.canGoForward)
                        .help("Forward (⌘])")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.showingQuickJump = true
                            ActionFeedbackCenter.shared.record(
                                button: "Quick Jump (⌘K)",
                                command: "showingQuickJump = true",
                                outcome: "Opened instant command, entity, and passage search palette.",
                                status: .completed
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                Text("Search")
                                Text("⌘K")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help("Jump to any entity, claim, passage, or command (⌘K)")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showingInspector.toggle()
                            ActionFeedbackCenter.shared.record(
                                button: "Toggle Provenance Inspector",
                                command: "showingInspector = \(model.showingInspector)",
                                outcome: model.showingInspector ? "Opened right-hand Floor Object & Byte-Span Provenance Inspector." : "Closed right-hand Provenance Inspector.",
                                status: .completed
                            )
                        } label: {
                            Label("Provenance Inspector", systemImage: "sidebar.right")
                        }
                        .help("Toggle Provenance & Floor Object Inspector (⌥⌘I)")
                    }
                }
        }
        .sheet(isPresented: $model.showingQuickJump, onDismiss: {
            if model.openWorkspaceMapAfterQuickJump {
                model.openWorkspaceMapAfterQuickJump = false
                model.showingWorkspaceMap = true
            }
        }) {
            QuickJumpSheet()
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
        }
        .sheet(isPresented: $model.showingWorkspaceMap) {
            WorkspaceMapView()
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
        }
        .sheet(isPresented: $model.showingJarvisHUD) {
            JarvisHUDView()
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
        }
        .sheet(item: $model.correctingRow) { row in
            CorrectionSheet(row: row)
                .environment(\.appModel, model)
                .environment(\.appSettings, model.settings)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let entityID = SpotlightIndexer.entityID(from: activity) {
                model.openEntity(id: entityID)
            }
        }
    }

    @ViewBuilder
    private func detailView(for section: Section) -> some View {
        @Bindable var model = model
        switch section {
        case .ask: ChatView()
        case .macOverview: HomeView(section: Binding(get: { model.selectedSection }, set: { model.navigate(to: $0) }))
        case .repoFleet: RepoFleetWorkspaceView()
        case .codingAgents: CodingAgentsWorkspaceView()
        case .computerControl: ComputerControlView()
        case .aiModelsRAM: AIModelsAndRAMWorkspaceView()
        case .hardwareUSB: HardwareUSBView()
        case .entities: EntityView()
        case .corpus: CorpusView()
        case .passages: PassagesView()
        case .claims: ClaimsView()
        case .beliefs: BeliefsView()
        case .timeline: TimelineView()
        case .timeTravel: TimeTravelView()
        case .contradictions: ContradictionsView()
        case .receipts: ReceiptsView()
        case .sources: SourcesView()
        case .maintenance: MaintenanceView()
        case .settings: SettingsView()
        }
    }

    private func sidebarLabel(_ item: Section) -> some View {
        Label(item.rawValue, systemImage: item.symbol)
            .lineLimit(1)
            .help(item.guide.purpose)
    }
}

struct StatusBar: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                switch model.state {
                case .idle:
                    Label("\(model.objectCount) obj · \(model.claimCount) claims", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .working(let what):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(what)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(message)
                    if model.store == nil {
                        Button("Retry opening store") { Task { await model.start() } }
                            .controlSize(.small)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    settings.toggleLightDarkMode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: settings.isEffectiveLightMode ? "sun.max.fill" : "moon.stars.fill")
                            .foregroundStyle(settings.isEffectiveLightMode ? Pastel.butter : Pastel.lavender)
                        Text(settings.isEffectiveLightMode ? "Light" : "Dark")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Switch between Light Frost and Dark Obsidian mode (⇧⌘L)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The last thing that went wrong, until someone dismisses it.
///
/// `model.state` is one slot that every operation overwrites, so a failure used to last until
/// the next line of code. The sidebar's status line still shows the current state; this shows
/// what failed and when, and it stays until a person has seen it.
private struct FailureBanner: View {
    let failure: AppModel.AppFailure
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Text(failure.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .controlSize(.small)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(failure.message)")
    }
}
