import SwiftUI

@main
struct OpenCoreApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}

enum Section: String, CaseIterable, Identifiable, Hashable {
    case ask = "Ask"
    case claims = "Claims"
    case beliefs = "Beliefs"
    case contradictions = "Contradictions"
    case receipts = "Receipts"
    case sources = "Sources"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .ask: "text.magnifyingglass"
        case .claims: "list.bullet.rectangle"
        case .beliefs: "clock.arrow.circlepath"
        case .contradictions: "exclamationmark.triangle"
        case .receipts: "doc.text.magnifyingglass"
        case .sources: "arrow.triangle.2.circlepath"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section = .ask

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
            case .ask: AskView()
            case .claims: ClaimsView()
            case .beliefs: BeliefsView()
            case .contradictions: ContradictionsView()
            case .receipts: ReceiptsView()
            case .sources: SourcesView()
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
