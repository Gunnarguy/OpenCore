import AppKit
import CoreIngest
import CoreModel
import CoreSearch
import CoreStore
import SwiftUI

/// Credentials, tuning, privacy policy, and getting your data back out.
///
/// The organising idea is that a setting should either change behaviour or reveal state that
/// is otherwise invisible. The retrieval section does the first; the domain matrix and the
/// token-source list do the second. Nothing here is a preference for its own sake.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(.title2.weight(.semibold))
                    Text("Credentials live in your keychain. Preferences live in UserDefaults. Neither is in the store.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GitHubCredentialPanel()
                RetrievalPanel()
                ChunkingPanel()
                PrivacyPanel()
                MCPServerPanel()
                SyncPanel()
                DataPanel()
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Shared chrome

private struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol).font(.callout.weight(.medium))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

/// A labelled numeric control with its default shown, so "is this the baseline" never needs
/// checking against source.
private struct TunedValue: View {
    let label: String
    let help: String
    let defaultText: String
    let isDefault: Bool
    @ViewBuilder var control: () -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                control()
                if !isDefault {
                    Text("default \(defaultText)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
            }
            Text(help).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - GitHub

private struct GitHubCredentialPanel: View {
    @State private var tokenField = ""
    @State private var status: Status = .unknown
    @State private var source: CredentialSource = .none
    @State private var checking = false

    enum Status: Equatable {
        case unknown, absent
        case present(login: String)
        case invalid(String)
    }

    var body: some View {
        Panel(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right") {
            StatusLine(status: status, source: source, checking: checking)

            HStack(spacing: 8) {
                SecureField("ghp_… or github_pat_…", text: $tokenField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
                Button("Save") { Task { await save() } }
                    .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if case .present = status {
                    Button("Clear", role: .destructive) { Task { await clear() } }.disabled(checking)
                }
            }

            Text("Classic tokens need `repo`, or `public_repo` for public repositories only. Saving verifies against the API before reporting success.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()
            PrecedenceList()
        }
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        defer { checking = false }
        let resolved = GitHubConnector.resolveTokenWithSource()
        source = resolved.source
        guard let token = resolved.token else { status = .absent; return }
        if let login = await GitHubConnector.verify(token: token) {
            status = .present(login: login)
        } else {
            status = .invalid("the token found via \(resolved.source.rawValue) was rejected by GitHub")
        }
    }

    private func save() async {
        checking = true
        defer { checking = false }
        let candidate = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard let login = await GitHubConnector.verify(token: candidate) else {
            status = .invalid("GitHub rejected that token. Check its scopes and that it has not expired.")
            return
        }
        do {
            try Keychain.write(candidate, to: .githubToken)
            tokenField = ""
            status = .present(login: login)
            source = GitHubConnector.resolveTokenWithSource().source
        } catch {
            status = .invalid("\(error)")
        }
    }

    private func clear() async {
        do {
            try Keychain.delete(.githubToken)
            tokenField = ""
            await refresh()
        } catch { status = .invalid("\(error)") }
    }
}

private struct StatusLine: View {
    let status: GitHubCredentialPanel.Status
    let source: CredentialSource
    let checking: Bool

    private var symbol: String {
        switch status {
        case .unknown: "hourglass"
        case .absent: "exclamationmark.triangle"
        case .present: "checkmark.circle"
        case .invalid: "xmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .unknown: .secondary
        case .absent: .orange
        case .present: .green
        case .invalid: .red
        }
    }

    private var message: String {
        switch status {
        case .unknown: "checking"
        case .absent: "No token found. GitHub sync will not work until you add one."
        case .present(let login): "Authenticated as \(login), via \(source.rawValue)."
        case .invalid(let reason): reason
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).font(.callout)
            Spacer(minLength: 0)
            if checking { ProgressView().controlSize(.small) }
        }
    }
}

private struct PrecedenceList: View {
    static let entries: [(String, String)] = [
        ("--token", "passed to the CLI"),
        ("GITHUB_TOKEN", "environment variable"),
        ("keychain", "what this screen saves; the only source the app can use on its own"),
        ("gh auth token", "the GitHub CLI, if installed and signed in"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Looked for in this order").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(Self.entries.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text(entry.0).font(.caption.monospaced())
                    Text(entry.1).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text("The environment wins over the keychain on purpose, so a one-off GITHUB_TOKEN=… run overrides a saved token without changing it.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
        }
    }
}

// MARK: - Retrieval

private struct RetrievalPanel: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Panel(
            title: "Retrieval",
            symbol: "slider.horizontal.3",
            subtitle: "Every value here was chosen, not measured. Nothing in this project has an accuracy number yet, so treat these as an experiment rather than a configuration."
        ) {
            TunedValue(label: "RRF k", help: "How fast rank advantage decays when fusing the two legs. Higher means appearing in both matters more than topping one.", defaultText: "60", isDefault: settings.rrfK == 60) {
                AnyView(Stepper(value: $settings.rrfK, in: 1...200, step: 5) {
                    Text(String(format: "%.0f", settings.rrfK)).font(.caption.monospaced()).frame(width: 34, alignment: .trailing)
                }.labelsHidden())
            }
            TunedValue(label: "MMR λ", help: "Relevance versus diversity. At 1.0 diversification is off and near-duplicate passages come back together.", defaultText: "0.70", isDefault: settings.mmrLambda == 0.7) {
                AnyView(Stepper(value: $settings.mmrLambda, in: 0.1...1.0, step: 0.05) {
                    Text(String(format: "%.2f", settings.mmrLambda)).font(.caption.monospaced()).frame(width: 34, alignment: .trailing)
                }.labelsHidden())
            }
            TunedValue(label: "Candidates per leg", help: "How many results each retriever contributes before fusion. Higher finds more of the tail and costs a longer scan.", defaultText: "100", isDefault: settings.candidatesPerLeg == 100) {
                AnyView(Stepper(value: $settings.candidatesPerLeg, in: 10...500, step: 10) {
                    Text("\(settings.candidatesPerLeg)").font(.caption.monospaced()).frame(width: 34, alignment: .trailing)
                }.labelsHidden())
            }
            TunedValue(label: "Signal scale", help: "How much authority and recency count once relevance is fused. The most obviously unprincipled number in the system.", defaultText: "0.020", isDefault: settings.signalScale == 0.02) {
                AnyView(Stepper(value: $settings.signalScale, in: 0...0.2, step: 0.005) {
                    Text(String(format: "%.3f", settings.signalScale)).font(.caption.monospaced()).frame(width: 40, alignment: .trailing)
                }.labelsHidden())
            }
            TunedValue(label: "Results", help: "Passages returned by a search.", defaultText: "8", isDefault: settings.passageLimit == 8) {
                AnyView(Stepper(value: $settings.passageLimit, in: 1...50) {
                    Text("\(settings.passageLimit)").font(.caption.monospaced()).frame(width: 34, alignment: .trailing)
                }.labelsHidden())
            }

            Toggle("Expand hits into neighbouring passages", isOn: $settings.expandContext)
                .font(.caption)

            if !settings.retrievalIsDefault {
                Button("Reset to defaults") { settings.resetRetrieval() }.controlSize(.small)
            }
        }
    }
}

// MARK: - Chunking

private struct ChunkingPanel: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Panel(
            title: "Chunking",
            symbol: "square.split.2x1",
            subtitle: "The only settings here that invalidate data already on disk."
        ) {
            TunedValue(label: "Target size", help: "Characters per passage. Roughly four characters per token.", defaultText: "1200", isDefault: settings.chunkTargetSize == AppSettings.defaultChunkTargetSize) {
                AnyView(Stepper(value: $settings.chunkTargetSize, in: 200...4000, step: 100) {
                    Text("\(settings.chunkTargetSize)").font(.caption.monospaced()).frame(width: 42, alignment: .trailing)
                }.labelsHidden())
            }
            TunedValue(label: "Overlap", help: "Trailing context repeated into the next passage, so a fact split across a boundary stays findable.", defaultText: "150", isDefault: settings.chunkOverlap == AppSettings.defaultChunkOverlap) {
                AnyView(Stepper(value: $settings.chunkOverlap, in: 0...800, step: 25) {
                    Text("\(settings.chunkOverlap)").font(.caption.monospaced()).frame(width: 42, alignment: .trailing)
                }.labelsHidden())
            }

            if !settings.chunkingIsDefault {
                Label(
                    "Existing passages were built with the old values and will not match until you re-derive, then rebuild embeddings. Until then the store is inconsistent with these settings.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Reset to defaults") { settings.resetChunking() }.controlSize(.small)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPanel: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Panel(
            title: "Domains",
            symbol: "lock.shield",
            subtitle: "What a question in one domain is allowed to read. Applied before ranking, so a blocked match is never scored rather than being filtered out afterwards."
        ) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Domain.allCases, id: \.self) { domain in
                    DomainRow(domain: domain)
                }
            }

            Text("This matrix is compiled in, not configurable. It is shown because a firewall you cannot see is one you cannot trust.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()

            Toggle(isOn: $settings.mcpExposeSensitiveDomains) {
                Text("Let MCP callers reach medical, financial and relationship data")
                    .font(.caption)
            }
            Text(settings.mcpExposeSensitiveDomains
                 ? "ON. Any tool caller can reach every domain. The query text reaching that server is written by a model, and a model asking about your diagnosis is not consent. Turn this off unless you control every client."
                 : "Off. No wording in a tool call reaches those domains, and a question that classifies as sensitive is answered from project data instead of refused.")
                .font(.caption2)
                .foregroundStyle(settings.mcpExposeSensitiveDomains ? Color.orange : Color.secondary)
        }
    }
}

private struct DomainRow: View {
    let domain: Domain

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(domain.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(domain.isSensitive ? Color.orange : .primary)
                .frame(width: 92, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(domain.readableDomains.map(\.rawValue).sorted().joined(separator: ", "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - MCP server

private struct MCPServerPanel: View {
    @Environment(AppSettings.self) private var settings
    @State private var copied = false

    /// The release binary is what a client should launch. Debug works but lives in a scratch
    /// path that gets wiped.
    private var binaryPath: String {
        "/Users/gunnarhostetler/Documents/GitHub/OpenCore/.build/release/opencore"
    }

    private var snippet: String {
        """
        {
          "mcpServers": {
            "opencore": {
              "command": "\(binaryPath)",
              "args": ["mcp"\(settings.mcpExposeSensitiveDomains ? ", \"--unsafe-expose-sensitive\"" : "")]
            }
          }
        }
        """
    }

    var body: some View {
        Panel(
            title: "Serve over MCP",
            symbol: "antenna.radiowaves.left.and.right",
            subtitle: "Let Claude or any MCP client query your history and cite it back to the commit it came from."
        ) {
            Text("Build the release binary first: `swift build -c release`. Then paste this into your client's config.")
                .font(.caption2).foregroundStyle(.tertiary)

            Text(snippet)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))

            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                Text("Six tools: ask, search, claims, contradictions, changed, trace.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Sync

private struct SyncPanel: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Panel(title: "Sync", symbol: "arrow.triangle.2.circlepath") {
            TunedValue(label: "Commits per repository", help: "How far back GitHub history is read on a full sync. Later syncs are incremental regardless.", defaultText: "100", isDefault: settings.githubCommitsPerRepo == 100) {
                AnyView(Stepper(value: $settings.githubCommitsPerRepo, in: 10...1000, step: 10) {
                    Text("\(settings.githubCommitsPerRepo)").font(.caption.monospaced()).frame(width: 42, alignment: .trailing)
                }.labelsHidden())
            }
            Toggle("Include forks", isOn: $settings.githubIncludeForks).font(.caption)

            Divider()

            TunedValue(label: "Calendar look-back", help: "Days of past events to read.", defaultText: "730", isDefault: settings.calendarLookBackDays == 730) {
                AnyView(Stepper(value: $settings.calendarLookBackDays, in: 30...3650, step: 30) {
                    Text("\(settings.calendarLookBackDays)").font(.caption.monospaced()).frame(width: 42, alignment: .trailing)
                }.labelsHidden())
            }
            TunedValue(label: "Calendar look-ahead", help: "Days of future events to read.", defaultText: "180", isDefault: settings.calendarLookAheadDays == 180) {
                AnyView(Stepper(value: $settings.calendarLookAheadDays, in: 0...730, step: 30) {
                    Text("\(settings.calendarLookAheadDays)").font(.caption.monospaced()).frame(width: 42, alignment: .trailing)
                }.labelsHidden())
            }
        }
    }
}

// MARK: - Data

private struct DataPanel: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var result: String?

    var body: some View {
        Panel(
            title: "Your data",
            symbol: "square.and.arrow.up",
            subtitle: "One SQLite file, shared with the opencore CLI. No credentials in it, and it is not encrypted, so treat it as you would the documents it was built from."
        ) {
            if let path = model.storePath {
                HStack(spacing: 8) {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            Text("Export everything. JSONL is the archival copy, one file per table, losslessly re-importable. Markdown is the readable copy and is lossy.")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                ForEach(Exporter.Format.allCases, id: \.self) { format in
                    Button(format.rawValue.uppercased()) { Task { await export(format) } }
                        .controlSize(.small)
                        .disabled(exporting)
                }
                if exporting { ProgressView().controlSize(.small) }
                if let result {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Nothing here holds your data hostage. Uninstall OpenCore and the export still opens in any text editor.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func export(_ format: Exporter.Format) async {
        exporting = true
        defer { exporting = false }
        result = await model.exportStore(format: format)
    }
}
