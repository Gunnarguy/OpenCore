import SwiftUI

@main
struct OpenCoreApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .task { await model.start() }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}

enum Section: String, CaseIterable, Identifiable, Hashable {
    case chat = "Chat"
    case ask = "Ask"
    case passages = "Passages"
    case claims = "Claims"
    case beliefs = "Beliefs"
    case timeline = "Timeline"
    case timeTravel = "Time travel"
    case contradictions = "Contradictions"
    case receipts = "Receipts"
    case sources = "Sources"
    case mcp = "MCP"
    case mcpStore = "MCP Store"
    case maintenance = "Maintenance"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .ask: "text.magnifyingglass"
        case .passages: "doc.text.magnifyingglass"
        case .claims: "list.bullet.rectangle"
        case .beliefs: "checkmark.seal"
        case .timeline: "calendar.day.timeline.left"
        case .timeTravel: "clock.arrow.circlepath"
        case .contradictions: "exclamationmark.triangle"
        case .receipts: "receipt"
        case .sources: "arrow.triangle.2.circlepath"
        case .mcp: "powerplug"
        case .mcpStore: "square.grid.2x2"
        case .maintenance: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section = .chat

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { StatusBar() }
        } detail: {
            switch section {
            case .chat: ChatView()
            case .ask: AskView()
            case .passages: PassagesView()
            case .claims: ClaimsView()
            case .beliefs: BeliefsView()
            case .timeline: TimelineView()
            case .timeTravel: TimeTravelView()
            case .contradictions: ContradictionsView()
            case .receipts: ReceiptsView()
            case .sources: SourcesView()
            case .mcp: MCPSourcesView()
            case .mcpStore: MCPStoreView()
            case .maintenance: MaintenanceView()
            case .settings: SettingsView()
            }
        }
    }

    private func badge(for item: Section) -> Int {
        switch item {
        case .claims: model.claimCount
        case .contradictions: model.openContradictionCount
        default: 0
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            switch model.state {
            case .idle:
                Label("\(model.objectCount) objects · \(model.claimCount) claims", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .working(let what):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(what)
                }
                .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(message)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
