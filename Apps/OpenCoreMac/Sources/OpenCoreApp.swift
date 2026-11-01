import CoreSpotlight
import SwiftUI

@main
struct OpenCoreApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
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

                Button("Command Center") { model.navigate(to: .home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Grounded Chat") { model.navigate(to: .chat) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Repo Fleet & Handoffs") { model.navigate(to: .repoFleet) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Coding Agents Hub") { model.navigate(to: .codingAgents) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Computer Use Studio") { model.navigate(to: .computerControl) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("AI Models & RAM (LM Studio)") { model.navigate(to: .aiModelsRAM) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Hardware, USB & Disk") { model.navigate(to: .hardwareUSB) }
                    .keyboardShortcut("7", modifiers: .command)
                Button("Knowledge Graph") { model.navigate(to: .entities) }
                    .keyboardShortcut("8", modifiers: .command)
                Button("Timeline & Time Travel") { model.navigate(to: .timeline) }
                    .keyboardShortcut("9", modifiers: .command)
                Button("Connections & MCP") { model.navigate(to: .mcp) }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Sync Workspace & Sources Now") {
                    Task { await model.syncAllWorkspaceAndSources() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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

/// The sidebar, organized into human-centered categories where each major domain gets its own clean workspace.
enum Section: String, CaseIterable, Identifiable, Hashable {
    // 1. Overview & Ask
    case home = "Command Center"
    case chat = "Grounded Chat"

    // 2. Projects & Coding Agents
    case repoFleet = "Repo Fleet & Handoffs"
    case codingAgents = "Coding Agents Hub"

    // 3. Computer Use & Local AI
    case computerControl = "Computer Use Studio"
    case aiModelsRAM = "AI Models & RAM"

    // 4. Hardware & System
    case hardwareUSB = "Hardware, USB & Disk"

    // 5. Knowledge & Connections
    case entities = "Knowledge Graph"
    case timeline = "Timeline & Time Travel"
    case mcp = "Connections & MCP"
    case settings = "Settings"

    // 6. Developer Tables (Collapsible)
    case contradictions = "Reality Checks & Diffs"
    case claims = "Claims"
    case beliefs = "Beliefs"
    case passages = "Passages"
    case receipts = "Receipts"
    case timeTravel = "Time travel"
    case sources = "Sources"
    case corpus = "Corpus"
    case maintenance = "Maintenance"

    var id: String { rawValue }

    /// Which band of the sidebar this belongs to.
    enum Band: String, CaseIterable, Identifiable {
        case overview = "Overview & Ask"
        case projectsAndAgents = "Projects & Agents"
        case computerUseAndAI = "Computer Use & Local AI"
        case hardware = "Hardware & System"
        case knowledgeAndConfig = "Knowledge & Connections"
        case developer = "Evidence & Engine"

        var id: String { rawValue }
    }

    var band: Band {
        switch self {
        case .home, .chat: .overview
        case .repoFleet, .codingAgents: .projectsAndAgents
        case .computerControl, .aiModelsRAM: .computerUseAndAI
        case .hardwareUSB: .hardware
        case .entities, .timeline, .mcp, .settings: .knowledgeAndConfig
        case .contradictions, .claims, .beliefs, .passages, .receipts, .timeTravel, .sources, .corpus, .maintenance: .developer
        }
    }

    var symbol: String {
        switch self {
        case .home: "sparkles.rectangle.stack"
        case .chat: "bubble.left.and.bubble.right"
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
        case .mcp: "powerplug"
        case .maintenance: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(\.appModel) private var model
    @ObservedObject private var connectedDisplays = ConnectedDisplayInventory.shared
    @AppStorage("sidebar.showDeveloper") private var showDeveloper = true
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedSection }, set: { model.navigate(to: $0) })) {
                ForEach(Section.Band.allCases) { band in
                    if band != .developer {
                        SwiftUI.Section(band.rawValue) {
                            ForEach(Section.allCases.filter { $0.band == band }) { item in
                                sidebarLabel(item)
                                    .badge(badge(for: item))
                                    .tag(item)
                            }
                        }
                    }
                }

                SwiftUI.Section {
                    if showDeveloper {
                        ForEach(Section.evidenceSections) { item in
                            sidebarLabel(item)
                                .badge(badge(for: item))
                                .tag(item)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showDeveloper.toggle() }
                        ActionFeedbackCenter.shared.record(
                            button: "Toggle Evidence & Engine Workspaces",
                            command: "sidebar.showDeveloper = \(showDeveloper)",
                            outcome: showDeveloper ? "Expanded all \(Section.evidenceSections.count) Evidence & Engine workspaces." : "Collapsed Evidence & Engine workspaces.",
                            status: .completed
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Text("Evidence & Engine")
                            Image(systemName: showDeveloper ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 300)
            .safeAreaInset(edge: .bottom) { StatusBar() }
            .onChange(of: model.selectedSection) { _, newSection in
                if newSection.band == .developer { showDeveloper = true }
                ActionFeedbackCenter.shared.record(
                    button: "Switch Workspace -> \(newSection.rawValue)",
                    command: "NavigationSplitView.select(\(newSection.id))",
                    outcome: "Opened '\(newSection.rawValue)' (\(newSection.band.rawValue)) and refreshed view bindings.",
                    status: .completed
                )
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
                    WorkspaceOrientationView(section: model.selectedSection)
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
                                Text("Quick Jump")
                                Text("⌘K")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help("Jump to any entity, claim, passage, or command (⌘K)")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.showingJarvisHUD = true
                            ActionFeedbackCenter.shared.record(
                                button: "J.A.R.V.I.S. HUD (⌘J)",
                                command: "showingJarvisHUD = true",
                                outcome: "Opened On-Device Executive Briefing, Speech & Vision HUD.",
                                status: .completed
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles.tv.fill")
                                Text("J.A.R.V.I.S.")
                                Text("⌘J")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help("Open J.A.R.V.I.S. Executive Briefing, On-Device Voice & Vision HUD (⌘J)")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.navigate(to: .hardwareUSB)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cable.connector.horizontal")
                                    .foregroundStyle(Pastel.aqua)
                                Text("Hardware")
                                    .font(.caption)
                            }
                        }
                        .help("Inspect connected displays, USB, Thunderbolt and disks (⌘7)")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.navigate(to: .computerControl)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "viewfinder.rectangular")
                                    .foregroundStyle(Pastel.mint)
                                Text("Computer Use")
                                    .font(.caption)
                            }
                        }
                        .help("Open supported Local Hub tasks, routines and planner previews (⌘5)")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.navigate(to: .aiModelsRAM)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cpu.fill")
                                    .foregroundStyle(Pastel.lavender)
                                Text("Models & RAM")
                                    .font(.caption)
                            }
                        }
                        .help("Check runtime support, load status, diagnostics and memory (⌘6)")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.settings.toggleLightDarkMode()
                            let modeName = model.settings.isEffectiveLightMode ? "Light Frost (☀️)" : "Dark Obsidian (🌙)"
                            ActionFeedbackCenter.shared.record(
                                button: "Toggle Light / Dark Theme",
                                command: "NSApp.appearance = \(model.settings.isEffectiveLightMode ? ".aqua" : ".darkAqua")",
                                outcome: "Switched entire window and Liquid Glass surfaces to \(modeName).",
                                status: .completed
                            )
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: model.settings.isEffectiveLightMode ? "sun.max.fill" : "moon.stars.fill")
                                    .foregroundStyle(model.settings.isEffectiveLightMode ? Pastel.butter : Pastel.lavender)
                                Text(model.settings.isEffectiveLightMode ? "Light" : "Dark")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .help("Toggle between Light Frost and Dark Obsidian mode (⇧⌘L)")
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
        case .home: HomeView(section: Binding(get: { model.selectedSection }, set: { model.navigate(to: $0) }))
        case .chat: ChatView()
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
        case .mcp: MCPView()
        case .maintenance: MaintenanceView()
        case .settings: SettingsView()
        }
    }

    private func sidebarLabel(_ item: Section) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.rawValue).lineLimit(1)
                Text(item.guide.shortName == item.rawValue ? item.guide.role : item.guide.shortName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: item.symbol)
        }
        .help(item.guide.purpose)
    }

    private func badge(for item: Section) -> Int {
        switch item {
        case .repoFleet: model.fleetCards.count
        case .codingAgents: 3
        case .aiModelsRAM: ComputerUseStudioController.shared.specialistCatalog.count
        case .entities: model.entityCount
        case .hardwareUSB: HardwareInspectorManager.shared.devices.count + connectedDisplays.displays.count
        case .claims: model.claimCount
        case .contradictions: model.openContradictionCount
        default: 0
        }
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
