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

/// The sidebar, grouped by what a reader is trying to do rather than by which layer of the
/// pipeline produced the data.
///
/// It used to be a flat list of fourteen, named after the architecture: Claims, Beliefs,
/// Contradictions, Receipts, Passages. That is the schema with a sidebar around it, perfectly
/// navigable to whoever built the pipeline and unmapped for everyone else.
///
/// `Ask` is gone. It ran the same query -> retrieval -> model -> receipt path as `Chat`, which
/// does it multi-turn and keeps a saved thread, so it was a second door onto one room.
///
/// `MCP Store` is gone too, folded into `MCP` as a mode. That split was not cosmetic: adding a
/// server lived on one row and managing one on the other, which stranded the tool picker on the
/// new-source path and left "choose tools after signing in" reachable only from the CLI.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case chat = "Chat"
    case entities = "Entities"
    case corpus = "Corpus"
    case timeline = "Timeline"
    case timeTravel = "Time travel"
    case contradictions = "Contradictions"
    case claims = "Claims"
    case beliefs = "Beliefs"
    case passages = "Passages"
    case receipts = "Receipts"
    case sources = "Sources"
    case mcp = "MCP"
    case maintenance = "Maintenance"
    case settings = "Settings"

    var id: String { rawValue }

    /// Which band of the sidebar this belongs to.
    ///
    /// Ask, browse, configure. The ordering within `Section.allCases` already reflects it; this
    /// makes the grouping explicit so a row added later lands somewhere deliberate instead of
    /// at the bottom of whichever list it was appended to.
    enum Band: String, CaseIterable, Identifiable {
        case ask = "Ask"
        case explore = "Explore"
        case inspect = "Inspect"
        case configure = "Set up"

        var id: String { rawValue }
    }

    var band: Band {
        switch self {
        case .chat: .ask
        case .entities, .corpus, .timeline, .timeTravel: .explore
        case .contradictions, .claims, .beliefs, .passages, .receipts: .inspect
        case .sources, .mcp, .maintenance, .settings: .configure
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .entities: "square.stack.3d.up"
        case .corpus: "chart.pie"
        case .passages: "doc.text.magnifyingglass"
        case .claims: "list.bullet.rectangle"
        case .beliefs: "checkmark.seal"
        case .timeline: "calendar.day.timeline.left"
        case .timeTravel: "clock.arrow.circlepath"
        case .contradictions: "exclamationmark.triangle"
        case .receipts: "receipt"
        case .sources: "arrow.triangle.2.circlepath"
        case .mcp: "powerplug"
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
            List(selection: $section) {
                // Banded rather than flat. Fourteen undifferentiated rows is a list you scan
                // every time; four short groups is one you learn once.
                ForEach(Section.Band.allCases) { band in
                    SwiftUI.Section(band.rawValue) {
                        ForEach(Section.allCases.filter { $0.band == band }) { item in
                            Label(item.rawValue, systemImage: item.symbol)
                                .badge(badge(for: item))
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { StatusBar() }
        } detail: {
            switch section {
            case .chat: ChatView()
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
