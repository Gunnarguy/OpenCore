import CoreIngest
import CoreJSONRPC
import CoreModel
import SwiftUI

/// One screen for MCP, in two modes.
///
/// These used to be two sidebar rows, MCP and MCP Store, and the split was not merely
/// cosmetic: it is why choosing tools after signing in was only possible from the CLI. Adding
/// a server lived on one tab, managing one lived on the other, and the discovery panel and
/// tool picker that the second needed were built into the first and reachable only on the
/// new-source path. Two doors onto one job, with a working part stranded behind the wrong one.
struct MCPView: View {
    /// Which half of the job is on screen. `sources` is the default because the catalogue is
    /// where you go once and the source list is where you come back to.
    private enum Mode: String, CaseIterable, Identifiable {
        case sources = "Your sources"
        case catalogue = "Catalogue"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .sources

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.vertical, 10)

            Divider()

            switch mode {
            case .sources: MCPSourcesView()
            // Adding from the catalogue lands you back on the source list, because adding is
            // not the end of the job: a new source has no allowlist and fetches nothing until
            // its tools are chosen, which happens over there.
            case .catalogue: MCPStoreView { mode = .sources }
            }
        }
        .navigationTitle("MCP")
    }
}

/// Reviewing a server's tools and ticking the safe ones is the part the terminal does badly.
/// The CLI makes you read a printed list, then retype each name behind `--tool`. Here the
/// list you read and the list you approve are the same object.
struct MCPSourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var mcp = MCPSourcesModel()

    @State private var name = ""
    @State private var command = ""
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var domain: Domain = .personal

    @State private var pendingRemoval: MCPSourcesModel.SourceRow?
    @State private var showingRemoval = false

    var body: some View {
        @Bindable var mcp = mcp
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                form
                if let notice = mcp.notice { MCPSourcesNotice(text: notice) }
                // Only the add-a-new-server path renders inline. Editing an existing source
                // puts the same picker in a sheet, so a list of ticks can never be ambiguous
                // about which server it belongs to.
                if !mcp.discoveredTools.isEmpty && mcp.editing == nil { discovery }
                configured
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await model.loadMCPSources(into: mcp) }
        .sheet(item: $mcp.editing) { row in
            MCPToolSheet(row: row, mcp: mcp)
        }
        .confirmationDialog(
            "Remove this MCP source?",
            isPresented: $showingRemoval,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { row in
            Button("Remove \(row.name) and its objects", role: .destructive) {
                Task { await model.removeMCPSource(row, into: mcp) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("Deletes \(row.name) and every object derived from it. Objects are the floor, so nothing above them survives either.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MCP servers").font(.title2.weight(.semibold))
            Text("Any MCP server can be a source. Nothing it offers is called until you tick it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        MCPSourcesServerForm(
            name: $name,
            command: $command,
            argumentsText: $argumentsText,
            environmentText: $environmentText,
            domain: $domain,
            disabled: isWorking
        ) {
            let config = discoverConfig()
            Task { await model.discoverMCP(config: config, into: mcp) }
        }
    }

    private var discovery: some View {
        MCPToolPicker(mcp: mcp, actionLabel: "Add source", disabled: !canAdd) {
            let config = addConfig()
            Task { await model.addMCPSource(config: config, into: mcp) }
        }
    }

    private var configured: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Configured MCP sources").font(.subheadline.weight(.semibold))

            if mcp.sources.isEmpty {
                Text("None yet. Enter a command above and discover what it offers, or pick one from the catalogue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mcp.sources) { row in
                    MCPSourcesConfiguredRow(row: row, disabled: isWorking) {
                        Task { await model.syncMCPSource(row, into: mcp) }
                    } chooseTools: {
                        Task { await model.discoverTools(for: row, into: mcp) }
                    } remove: {
                        pendingRemoval = row
                        showingRemoval = true
                    }
                }
            }
        }
    }

    // MARK: - Form to config

    private func discoverConfig() -> MCPServerConfig {
        MCPServerConfig(
            // Discovery calls nothing, so the name is only a label in error text. The CLI
            // uses a placeholder here for the same reason.
            name: trimmed(name).isEmpty ? "discover" : trimmed(name),
            command: trimmed(command),
            arguments: words(argumentsText),
            environmentNames: words(environmentText),
            domain: domain
        )
    }

    private func addConfig() -> MCPServerConfig {
        let allowed = mcp.discoveredTools.map(\.name).filter { mcp.isAllowed($0) }

        // The form's fields are text, so everything it collects is a JSON string. A tool
        // needing an object or a number is configurable only from the CLI's
        // `--tool-arg-json` until this panel grows a typed editor.
        var arguments: [String: [String: JSONValue]] = [:]
        for tool in allowed {
            let filled = (mcp.toolArguments[tool] ?? [:]).compactMapValues { raw -> JSONValue? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .string(trimmed)
            }
            if !filled.isEmpty { arguments[tool] = filled }
        }

        return MCPServerConfig(
            name: trimmed(name),
            command: trimmed(command),
            arguments: words(argumentsText),
            environmentNames: words(environmentText),
            allowedTools: allowed,
            toolArguments: arguments,
            domain: domain
        )
    }

    private var canAdd: Bool {
        guard !isWorking, mcp.allowedCount > 0 else { return false }
        return !trimmed(name).isEmpty && !trimmed(command).isEmpty
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func words(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }
}

// MARK: - Server form

private struct MCPSourcesServerForm: View {
    @Binding var name: String
    @Binding var command: String
    @Binding var argumentsText: String
    @Binding var environmentText: String
    @Binding var domain: Domain
    let disabled: Bool
    let discover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MCPSourcesField(label: "Name", prompt: "slack", text: $name)
            MCPSourcesField(label: "Command", prompt: "npx", text: $command)
            MCPSourcesField(label: "Arguments", prompt: "-y @modelcontextprotocol/server-slack", text: $argumentsText)
            MCPSourcesField(label: "Environment", prompt: "SLACK_BOT_TOKEN", text: $environmentText)

            Text("Arguments are split on spaces. Environment takes variable NAMES, never values: the value is read from your environment when the server launches and is never written to the database.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Text("Everything from this server is tagged").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $domain) {
                    ForEach(Domain.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                Button("Discover", action: discover)
                    .disabled(disabled || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private struct MCPSourcesField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
        }
    }
}

// MARK: - Discovery

/// The list a person reads and ticks.
///
/// Shared by both paths that reach it, adding a new server and changing an existing one's
/// allowlist, so the safety note and the risk advisories cannot end up on one and not the
/// other. That divergence is exactly what the old two-tab split produced.
private struct MCPToolPicker: View {
    let mcp: MCPSourcesModel
    let actionLabel: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MCPSourcesDiscoveryHeader(
                serverName: mcp.discoveredServerName,
                protocolVersion: mcp.discoveredProtocolVersion,
                command: mcp.discoveredCommand,
                toolCount: mcp.discoveredTools.count
            )

            MCPSourcesSafetyNote()

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(mcp.discoveredTools, id: \.name) { tool in
                    MCPSourcesToolRow(tool: tool, mcp: mcp)
                }
            }

            MCPSourcesAddBar(
                allowedCount: mcp.allowedCount,
                toolCount: mcp.discoveredTools.count,
                label: actionLabel,
                disabled: disabled,
                action: action
            )
        }
    }
}

/// Choosing tools for a source that already exists.
///
/// A sheet rather than the inline panel, because this list belongs to one named server and the
/// inline version sits under a form describing a different, unsaved one. Cancelling changes
/// nothing: the stored allowlist is only rewritten by Save.
private struct MCPToolSheet: View {
    let row: MCPSourcesModel.SourceRow
    let mcp: MCPSourcesModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools for \(row.source.displayName)").font(.headline)
                    Text("Ticking a tool is the only thing that lets it be called.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    mcp.clearDiscovery()
                    dismiss()
                }
            }
            .padding()
            Divider()

            ScrollView {
                MCPToolPicker(mcp: mcp, actionLabel: "Save", disabled: mcp.allowedCount == 0) {
                    Task {
                        await model.saveAllowedTools(for: row, into: mcp)
                        dismiss()
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 620)
    }
}

private struct MCPSourcesDiscoveryHeader: View {
    let serverName: String?
    let protocolVersion: String?
    let command: String?
    let toolCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(serverName ?? "unnamed server").font(.headline)
            HStack(spacing: 12) {
                MetricPill(label: "tools", value: "\(toolCount)")
                MetricPill(label: "command", value: command ?? "unknown")
                protocolPill
            }
        }
    }

    /// A server that never reported a protocol version has not been measured at one, and a
    /// guessed version here would read as a fact about the peer.
    @ViewBuilder
    private var protocolPill: some View {
        if let protocolVersion {
            MetricPill(label: "protocol", value: protocolVersion)
        } else {
            HStack(spacing: 4) {
                Text("protocol").foregroundStyle(.tertiary)
                Text("not reported").foregroundStyle(.tertiary).italic()
            }
            .font(.caption)
        }
    }
}

/// Sits directly above the checkboxes and cannot be dismissed, because the reason the boxes
/// start empty is the only thing standing between a sync and a sent message.
private struct MCPSourcesSafetyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nothing is called unless you tick it", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
            Text("An MCP server can expose tools that send messages or delete data. Its own read-only annotation is a claim from an untrusted peer, not a check, so this allowlist is the only thing that decides what runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The advisory beside each tool is a guess from the tool's name plus that claim. get_message reads; get_approval might send one. Read the descriptions and decide yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Whatever a server returns is stored as third-party evidence to cite, never as instruction.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 10))
    }
}

private struct MCPSourcesToolRow: View {
    let tool: MCPTool
    let mcp: MCPSourcesModel

    private var risk: MCPToolRisk { MCPToolRisk(tool) }
    private var isReady: Bool { mcp.isReady(tool) }

    private var allowedBinding: Binding<Bool> {
        Binding(
            get: { mcp.isAllowed(tool.name) },
            set: { mcp.setAllowed($0, for: tool) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: allowedBinding) {
                HStack(spacing: 8) {
                    Text(tool.name).font(.callout.monospaced())
                    MCPSourcesRiskChip(risk: risk)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!isReady)

            Text(tool.readOnlyAdvisory)
                .font(.caption)
                .foregroundStyle(risk.tint)

            descriptionLine

            if !tool.requiredArguments.isEmpty {
                MCPSourcesArgumentFields(tool: tool, mcp: mcp)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private var descriptionLine: some View {
        if tool.description.isEmpty {
            Text("no description provided").font(.caption).foregroundStyle(.tertiary).italic()
        } else {
            Text(tool.description).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MCPSourcesRiskChip: View {
    let risk: MCPToolRisk

    var body: some View {
        Text(risk.chipLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(risk.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.tint.opacity(0.12), in: .capsule)
    }
}

private struct MCPSourcesArgumentFields: View {
    let tool: MCPTool
    let mcp: MCPSourcesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Requires \(tool.requiredArguments.joined(separator: ", ")). This tool cannot be ticked until every one has a value.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(Array(tool.requiredArguments.enumerated()), id: \.offset) { _, key in
                MCPSourcesArgumentField(tool: tool, key: key, mcp: mcp)
            }
        }
    }
}

private struct MCPSourcesArgumentField: View {
    let tool: MCPTool
    let key: String
    let mcp: MCPSourcesModel

    private var valueBinding: Binding<String> {
        Binding(
            get: { mcp.argument(key, for: tool.name) },
            set: { mcp.setArgument($0, key: key, for: tool) }
        )
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            if let locked = mcp.lockedArgument(key, for: tool.name) {
                lockedValue(locked)
            } else {
                TextField("value", text: valueBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
        }
    }

    /// An argument already stored as an object, array or number.
    ///
    /// Shown, not offered for editing. This field writes text, and turning `{"page_size":10}`
    /// back into JSON would mean guessing whether the user meant the number or the string,
    /// which is the guess `--tool-arg-json` exists as a separate flag to avoid. Editable here
    /// would silently flatten a working Notion configuration into nonsense.
    private func lockedValue(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(json)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 5))
            Text("set as JSON, and kept as-is when you save. Change it with opencore mcp-source add --tool-arg-json.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MCPSourcesAddBar: View {
    let allowedCount: Int
    let toolCount: Int
    let label: String
    let disabled: Bool
    let action: () -> Void

    private var countColor: Color { allowedCount == 0 ? .orange : .secondary }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(allowedCount) of \(toolCount) tools allowed")
                .font(.caption.monospaced())
                .foregroundStyle(countColor)
            Spacer()
            Button(label, action: action).disabled(disabled)
        }
    }
}

// MARK: - Configured sources

private struct MCPSourcesConfiguredRow: View {
    let row: MCPSourcesModel.SourceRow
    let disabled: Bool
    let sync: () -> Void
    let chooseTools: () -> Void
    let remove: () -> Void

    @State private var signIn = MCPSignIn()
    @State private var signedIn = false
    @State private var signingIn = false
    @State private var signInError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.source.displayName).font(.body.weight(.medium))
                    Text(commandLine).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if hostedEndpoint != nil { signInButton }
                toolsButton
                Button("Sync", action: sync).disabled(disabled || !canCall)
                Button("Remove", action: remove).disabled(disabled)
            }

            detail

            if let signInError {
                Label(signInError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
        .task { refreshSignedIn() }
    }

    /// A hosted server signs in; a local one reads a credential from the environment. Only one
    /// of those two is ever offered, so the row cannot suggest an action that does nothing.
    private var hostedEndpoint: URL? {
        guard let raw = row.config?.url else { return nil }
        return URL(string: raw)
    }

    /// A hosted server cannot be reached at all until it is signed in, so neither listing its
    /// tools nor syncing is offered before that.
    private var canCall: Bool { hostedEndpoint == nil || signedIn }

    private var hasAllowlist: Bool { !(row.config?.allowedTools.isEmpty ?? true) }

    /// Prominent when the allowlist is empty, because that source fetches nothing and this
    /// button is the whole remedy. It is the step that used to require the CLI.
    ///
    /// Two branches rather than one button with an erased style: type-erasing a view destroys
    /// its identity, and this app has already paid for that once in Settings.
    @ViewBuilder
    private var toolsButton: some View {
        if hasAllowlist {
            Button("Tools", action: chooseTools)
                .disabled(disabled || !canCall)
                .help(toolsHelp)
        } else {
            Button("Choose tools", action: chooseTools)
                .buttonStyle(.borderedProminent)
                .disabled(disabled || !canCall)
                .help(toolsHelp)
        }
    }

    private var toolsHelp: String {
        canCall
            ? "Connect and list what this server offers. Listing is not calling; nothing runs until you tick it."
            : "Sign in first. A hosted server cannot list its tools until it is authenticated."
    }

    @ViewBuilder
    private var signInButton: some View {
        if signingIn {
            ProgressView().controlSize(.small)
        } else if signedIn {
            Button("Sign out") {
                MCPSignIn.signOut(server: row.name)
                refreshSignedIn()
            }
        } else {
            Button("Sign in", action: startSignIn).buttonStyle(.borderedProminent)
        }
    }

    private func startSignIn() {
        guard let endpoint = hostedEndpoint else { return }
        signInError = nil
        signingIn = true
        Task {
            do {
                try await signIn.signIn(server: row.name, endpoint: endpoint)
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            signingIn = false
            refreshSignedIn()
        }
    }

    private func refreshSignedIn() {
        signedIn = MCPSignIn.isSignedIn(server: row.name)
    }

    private var commandLine: String {
        guard let config = row.config else { return "configuration unreadable" }
        if let url = config.url { return url }
        return ([config.command] + config.arguments).joined(separator: " ")
    }

    @ViewBuilder
    private var detail: some View {
        if let config = row.config {
            MCPSourcesAllowlistLine(tools: config.allowedTools)
            HStack(spacing: 12) {
                MetricPill(label: "domain", value: config.domain.rawValue)
                MetricPill(label: "authority", value: config.authority.label)
                syncedPill
            }
            if !row.missingEnvironment.isEmpty {
                Label(
                    "not set in your environment: \(row.missingEnvironment.joined(separator: ", ")). Sync refuses to run until they are set.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } else {
            Text("Configuration missing or unreadable. Remove this source and add it again.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var syncedPill: some View {
        if let synced = row.source.lastSyncedAt {
            MetricPill(label: "synced", value: ClaimsView.formatter.string(from: synced))
        } else {
            HStack(spacing: 4) {
                Text("synced").foregroundStyle(.tertiary)
                Text("never").foregroundStyle(.tertiary).italic()
            }
            .font(.caption)
        }
    }
}

/// An MCP source with no allowlist fetches nothing, which looks identical to a server that
/// has gone quiet. Say which one it is.
private struct MCPSourcesAllowlistLine: View {
    let tools: [String]

    var body: some View {
        if tools.isEmpty {
            Text("no tools allowed, so this source fetches nothing. Choose tools to fix it.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("allowed: \(tools.joined(separator: ", "))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared

private struct MCPSourcesNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private extension MCPToolRisk {
    var tint: Color {
        switch self {
        case .destructive: .red
        case .write: .orange
        case .unclear: .secondary
        case .likelyRead: .accentColor
        }
    }

    var chipLabel: String {
        switch self {
        case .destructive: "DESTRUCTIVE"
        case .write: "WRITE"
        case .unclear: "UNCLEAR"
        case .likelyRead: "LIKELY READ"
        }
    }
}
