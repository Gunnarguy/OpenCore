import AppKit
import CoreIngest
import CoreModel
import CoreSearch
import CoreStore
import SwiftUI

/// Credentials, tuning, privacy policy, and getting your data back out.
///
/// Built on `Form` with `.formStyle(.grouped)` rather than hand-rolled cards. The first
/// version stacked custom `VStack` panels and looked like a web page pasted into a Mac app:
/// wrong control sizes, wrong label alignment, wrong spacing. `Form` gets all of that from
/// the platform for free and matches System Settings.
///
/// The rule for what earns a place here: a setting must either change behaviour or reveal
/// state that is otherwise invisible. The domain matrix and the token-source list do the
/// second. Nothing is a preference for its own sake.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var tab: Tab = .credentials

    enum Tab: String, CaseIterable, Identifiable {
        case credentials = "Credentials"
        case retrieval = "Retrieval"
        case privacy = "Privacy"
        case sync = "Sync"
        case data = "Data"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .credentials: "key"
            case .retrieval: "slider.horizontal.3"
            case .privacy: "lock.shield"
            case .sync: "arrow.triangle.2.circlepath"
            case .data: "internaldrive"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch tab {
            case .credentials: CredentialsTab()
            case .retrieval: RetrievalTab()
            case .privacy: PrivacyTab()
            case .sync: SyncTab()
            case .data: DataTab()
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Credentials

private struct CredentialsTab: View {
    @State private var tokenField = ""
    @State private var status: Status = .unknown
    @State private var source: CredentialSource = .none
    /// Only true during a save. **Not** set by the background verify: gating the buttons on a
    /// network call is what made them feel dead, since an offline machine left Save disabled
    /// with no explanation.
    @State private var saving = false
    @State private var verifying = false

    enum Status: Equatable {
        case unknown, absent
        case present(login: String)
        case invalid(String)
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Status") { StatusLine(status: status, source: source, busy: verifying) }

                SecureField("Token", text: $tokenField, prompt: Text("ghp_… or github_pat_…"))
                    .onSubmit { Task { await save() } }

                HStack {
                    Button("Save") { Task { await save() } }
                        .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    if case .present = status {
                        Button("Clear", role: .destructive) { Task { await clear() } }.disabled(saving)
                    }
                    Button("Re-check") { Task { await refresh() } }.disabled(verifying)
                    if saving { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Classic tokens need `repo`, or `public_repo` for public repositories only. Saving verifies against the API first, because saved and working are different facts.")
            }

            SwiftUI.Section {
                ForEach(Array(Self.precedence.enumerated()), id: \.offset) { index, entry in
                    LabeledContent {
                        Text(entry.1).font(.caption).foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1).").foregroundStyle(.tertiary)
                            Text(entry.0).monospaced()
                        }
                    }
                }
            } header: {
                Text("Where a token is looked for")
            } footer: {
                Text("The environment wins over the keychain on purpose, so a one-off GITHUB_TOKEN=… run overrides a saved token without changing it.")
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    static let precedence: [(String, String)] = [
        ("--token", "passed to the CLI"),
        ("GITHUB_TOKEN", "environment variable"),
        ("keychain", "what this screen saves; the only source the app has on its own"),
        ("gh auth token", "the GitHub CLI, if installed and signed in"),
    ]

    private func refresh() async {
        verifying = true
        defer { verifying = false }
        let resolved = GitHubConnector.resolveTokenWithSource()
        source = resolved.source
        guard let token = resolved.token else { status = .absent; return }
        if let login = await GitHubConnector.verify(token: token) {
            status = .present(login: login)
        } else {
            status = .invalid("the token found via \(resolved.source.rawValue) was rejected")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let candidate = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard let login = await GitHubConnector.verify(token: candidate) else {
            status = .invalid("GitHub rejected that token. Check its scopes and expiry.")
            return
        }
        do {
            try Keychain.write(candidate, to: .githubToken)
            tokenField = ""
            status = .present(login: login)
            source = GitHubConnector.resolveTokenWithSource().source
        } catch { status = .invalid("\(error)") }
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
    let status: CredentialsTab.Status
    let source: CredentialSource
    let busy: Bool

    private var symbol: String {
        switch status {
        case .unknown: "hourglass"
        case .absent: "exclamationmark.triangle"
        case .present: "checkmark.circle.fill"
        case .invalid: "xmark.circle.fill"
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
        case .absent: "no token found"
        case .present(let login): "\(login), via \(source.rawValue)"
        case .invalid(let reason): reason
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message)
            if busy { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: - Retrieval

/// A numeric row.
///
/// Generic over its control rather than taking `AnyView`. The first version erased to
/// `AnyView`, which destroys SwiftUI's view identity and forces the whole subtree to be
/// rebuilt on every keystroke of a stepper instead of diffed. Every control on the screen
/// was wrapped in one, which is why they felt unresponsive.
private struct Tuned<Control: View>: View {
    let label: String
    let help: String
    let isDefault: Bool
    let defaultText: String
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                control
                if !isDefault {
                    Text("was \(defaultText)").font(.caption).foregroundStyle(.orange).monospacedDigit()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                Text(help).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct RetrievalTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            SwiftUI.Section {
                Tuned(label: "RRF k", help: "How fast rank advantage decays when fusing the two legs.", isDefault: settings.rrfK == 60, defaultText: "60") {
                    Stepper(value: $settings.rrfK, in: 1...200, step: 5) {
                        Text("\(Int(settings.rrfK))").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Tuned(label: "MMR λ", help: "Relevance versus diversity. At 1.0 diversification is off.", isDefault: settings.mmrLambda == 0.7, defaultText: "0.70") {
                    Stepper(value: $settings.mmrLambda, in: 0.1...1.0, step: 0.05) {
                        Text(settings.mmrLambda.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Tuned(label: "Candidates per leg", help: "Results each retriever contributes before fusion.", isDefault: settings.candidatesPerLeg == 100, defaultText: "100") {
                    Stepper(value: $settings.candidatesPerLeg, in: 10...500, step: 10) {
                        Text("\(settings.candidatesPerLeg)").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Tuned(label: "Signal scale", help: "How much authority and recency count once relevance is fused.", isDefault: settings.signalScale == 0.02, defaultText: "0.020") {
                    Stepper(value: $settings.signalScale, in: 0...0.2, step: 0.005) {
                        Text(settings.signalScale.formatted(.number.precision(.fractionLength(3)))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Tuned(label: "Results", help: "Passages returned by a search.", isDefault: settings.passageLimit == 8, defaultText: "8") {
                    Stepper(value: $settings.passageLimit, in: 1...50) {
                        Text("\(settings.passageLimit)").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Expand hits into neighbouring passages", isOn: $settings.expandContext)
            } header: {
                Text("Fusion and ranking")
            } footer: {
                Text("Every value here was chosen, not measured. Nothing in this project has an accuracy number yet, so treat these as an experiment rather than a configuration.")
            }

            SwiftUI.Section {
                Tuned(label: "Target size", help: "Characters per passage, roughly four per token.", isDefault: settings.chunkTargetSize == AppSettings.defaultChunkTargetSize, defaultText: "1200") {
                    Stepper(value: $settings.chunkTargetSize, in: 200...4000, step: 100) {
                        Text("\(settings.chunkTargetSize)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Tuned(label: "Overlap", help: "Trailing context repeated into the next passage.", isDefault: settings.chunkOverlap == AppSettings.defaultChunkOverlap, defaultText: "150") {
                    Stepper(value: $settings.chunkOverlap, in: 0...800, step: 25) {
                        Text("\(settings.chunkOverlap)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if settings.chunkingDirty {
                    Label("Stored passages were built with different values. Re-derive on the Maintenance tab, then rebuild embeddings, or the store stays inconsistent with these settings.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Chunking")
            } footer: {
                Text("The only settings that invalidate data already on disk.")
            }

            if !settings.retrievalIsDefault || !settings.chunkingIsDefault {
                SwiftUI.Section {
                    Button("Reset everything to defaults") {
                        settings.resetRetrieval()
                        settings.resetChunking()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            SwiftUI.Section {
                ForEach(Domain.allCases, id: \.self) { domain in
                    LabeledContent {
                        Text(domain.readableDomains.map(\.rawValue).sorted().joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(domain.rawValue)
                            .monospaced()
                            .foregroundStyle(domain.isSensitive ? Color.orange : Color.primary)
                    }
                }
            } header: {
                Text("What a question in each domain may read")
            } footer: {
                Text("Applied before ranking, so a blocked match is never scored rather than filtered out afterwards. Compiled in and not configurable; shown because a firewall you cannot see is one you cannot trust.")
            }

            SwiftUI.Section {
                Toggle("Let MCP callers reach medical, financial and relationship data", isOn: $settings.mcpExposeSensitiveDomains)
                if settings.mcpExposeSensitiveDomains {
                    Label("Any tool caller can now reach every domain. The query text reaching that server is written by a model, and a model asking about your diagnosis is not consent.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("MCP server")
            } footer: {
                Text(settings.mcpExposeSensitiveDomains
                     ? "Turn this off unless you control every client that connects."
                     : "Off. No wording in a tool call reaches those domains, and a question that classifies as sensitive is answered from project data rather than refused.")
            }

            SwiftUI.Section("Client config") { MCPConfigSnippet() }
        }
        .formStyle(.grouped)
    }
}

private struct MCPConfigSnippet: View {
    @Environment(AppSettings.self) private var settings
    @State private var copied = false

    private var snippet: String {
        """
        {
          "mcpServers": {
            "opencore": {
              "command": "/Users/gunnarhostetler/Documents/GitHub/OpenCore/.build/release/opencore",
              "args": ["mcp"\(settings.mcpExposeSensitiveDomains ? ", \"--unsafe-expose-sensitive\"" : "")]
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snippet)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                Text("Run `swift build -c release` first.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Sync

private struct SyncTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            SwiftUI.Section("GitHub") {
                Tuned(label: "Commits per repository", help: "How far back a full sync reads. Later syncs are incremental regardless.", isDefault: settings.githubCommitsPerRepo == 100, defaultText: "100") {
                    Stepper(value: $settings.githubCommitsPerRepo, in: 10...1000, step: 10) {
                        Text("\(settings.githubCommitsPerRepo)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Include forks", isOn: $settings.githubIncludeForks)
            }

            SwiftUI.Section("Calendar") {
                Tuned(label: "Look back", help: "Days of past events to read.", isDefault: settings.calendarLookBackDays == 730, defaultText: "730") {
                    Stepper(value: $settings.calendarLookBackDays, in: 30...3650, step: 30) {
                        Text("\(settings.calendarLookBackDays)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Tuned(label: "Look ahead", help: "Days of future events to read.", isDefault: settings.calendarLookAheadDays == 180, defaultText: "180") {
                    Stepper(value: $settings.calendarLookAheadDays, in: 0...730, step: 30) {
                        Text("\(settings.calendarLookAheadDays)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Data

private struct DataTab: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var outcome: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                if let path = model.storePath {
                    LabeledContent("Location") {
                        HStack {
                            Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.head)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                }
                LabeledContent("Contents", value: "\(model.objectCount) objects · \(model.chunkCount) passages · \(model.claimCount) claims")
            } header: {
                Text("Store")
            } footer: {
                Text("One SQLite file, shared with the opencore CLI. It holds no credentials, and it is not encrypted, so treat it as you would the documents it was built from.")
            }

            SwiftUI.Section {
                HStack {
                    ForEach(Exporter.Format.allCases, id: \.self) { format in
                        Button(format.rawValue.uppercased()) { Task { await export(format) } }.disabled(exporting)
                    }
                    if exporting { ProgressView().controlSize(.small) }
                }
                if let outcome {
                    Text(outcome).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Export")
            } footer: {
                Text("JSONL is the archival copy: one file per table, losslessly re-importable. Markdown is readable and lossy. Uninstall OpenCore and either still opens in any text editor.")
            }
        }
        .formStyle(.grouped)
    }

    private func export(_ format: Exporter.Format) async {
        exporting = true
        defer { exporting = false }
        outcome = await model.exportStore(format: format)
    }
}
