import CoreIngest
import CoreJSONRPC
import CoreMCP
import CoreModel
import CorePresentation
import CoreSearch
import CoreStore
import SwiftUI

/// One hub for Connections & MCP: local workspace & Apple connectors, external MCP sources,
/// the official server catalogue, OpenCore's own outbound MCP server playground, and corpus rebuild.
struct MCPView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sources = "MCP Ecosystem"
        case connectors = "Workspace & Connectors"
        case catalogue = "Registry Catalogue"
        case server = "OpenCore Server (8 Tools)"
        case corpus = "Corpus & Rebuild"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .sources

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)

            Divider()

            switch mode {
            case .sources:
                MCPSourcesView(
                    onOpenCatalogue: { mode = .catalogue },
                    onOpenServerInspector: { mode = .server }
                )
            case .connectors:
                SourcesView()
            case .catalogue:
                MCPStoreView { mode = .sources }
            case .server:
                OpenCoreMCPServerInspectorView()
            case .corpus:
                CorpusView()
            }
        }
        .navigationTitle("Connections & MCP")
    }
}

/// Reviewing a server's tools and ticking the safe ones is the part the terminal does badly.
/// The CLI makes you read a printed list, then retype each name behind `--tool`. Here the
/// list you read and the list you approve are the same object.
struct MCPSourcesView: View {
    @Environment(\.appModel) private var model
    var onOpenCatalogue: () -> Void = {}
    var onOpenServerInspector: () -> Void = {}

    @State private var mcp = MCPSourcesModel()
    @State private var showingCustomForm = false

    @State private var name = ""
    @State private var command = ""
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var domain: Domain = .project

    @State private var pendingRemoval: MCPSourcesModel.SourceRow?
    @State private var showingRemoval = false

    var body: some View {
        @Bindable var mcp = mcp
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ecosystemStatusBanner
                if let notice = mcp.notice { MCPSourcesNotice(text: notice) }
                if showingCustomForm { form }
                if !mcp.discoveredTools.isEmpty && mcp.editing == nil { discovery }
                configured
                if !mcp.detectedOnMac.isEmpty { detectedSection }
                if !mcp.curatedPresets.isEmpty { presetsSection }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Context Protocol Ecosystem")
                    .font(.title2.weight(.semibold))
                Text("Connected local and OAuth MCP servers on your Mac. Every server starts default-deny: nothing is called until you tick its read-only tools.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            OpenCoreGlassCluster(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.loadMCPSources(into: mcp) }
                    } label: {
                        Label("Rescan Mac", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .openCoreGlassButton()
                    .disabled(isWorking)

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showingCustomForm.toggle()
                        }
                    } label: {
                        Label(
                            showingCustomForm ? "Hide Custom Form" : "Custom Server…",
                            systemImage: showingCustomForm ? "chevron.up.circle" : "plus.circle.fill"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .openCoreGlassButton(prominent: !showingCustomForm)
                }
            }
        }
    }

    private var ecosystemStatusBanner: some View {
        let readyCount = mcp.sources.filter { !($0.config?.allowedTools.isEmpty ?? true) }.count
        return HStack(spacing: 12) {
            MCPSummaryStatCard(
                title: "Configured Servers",
                value: "\(mcp.sources.count)",
                subtitle: "\(readyCount) with active tool allowlist",
                symbol: "powerplug.fill",
                tint: .accentColor
            )
            MCPSummaryStatCard(
                title: "Featured Presets",
                value: "\(mcp.curatedPresets.count + mcp.detectedOnMac.count)",
                subtitle: "1-click add or browse 9,600+ in Registry",
                symbol: "square.grid.2x2.fill",
                tint: .purple,
                action: onOpenCatalogue
            )
            MCPSummaryStatCard(
                title: "OpenCore Outbound Server",
                value: "8 Read-Only Tools",
                subtitle: mcp.registeredOpenCoreClients.isEmpty
                    ? "Click to test & inspect JSON-RPC"
                    : "Active in \(mcp.registeredOpenCoreClients.joined(separator: " · "))",
                symbol: "checkmark.shield.fill",
                tint: .green,
                action: onOpenServerInspector
            )
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
            mcp.pendingDiscoveredConfig = config
            Task { await model.discoverMCP(config: config, into: mcp) }
        }
    }

    private var discovery: some View {
        MCPToolPicker(mcp: mcp, actionLabel: "Add Source with Selected Tools", disabled: !canAdd) {
            let config = addConfig()
            Task { await model.addMCPSource(config: config, into: mcp) }
        }
    }

    private var configured: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Configured MCP Sources")
                    .font(.headline)
                Text("\(mcp.sources.count) connected")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Browse Full Registry →", action: onOpenCatalogue)
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if mcp.sources.isEmpty {
                Text("No MCP servers configured yet. Add one from the detected or preset cards below, or open the Registry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .openCoreGlassCard(cornerRadius: 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
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
    }

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected on This Mac")
                        .font(.headline)
                    Text("Discovered in your local Claude Code / Antigravity / Gemini MCP configurations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore All (\(mcp.detectedOnMac.count))") {
                    Task { await model.registerAllDetectedServers(into: mcp) }
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
                .disabled(isWorking)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                ForEach(mcp.detectedOnMac) { server in
                    MCPDetectedServerCard(
                        server: server,
                        disabled: isWorking,
                        onAdd: {
                            Task { await model.registerDetectedServer(server, into: mcp) }
                        },
                        onDiscover: {
                            populateForm(from: server)
                            Task { await model.discoverDetectedServer(server, into: mcp) }
                        }
                    )
                }
            }
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Featured & Official MCP Presets")
                        .font(.headline)
                    Text("One-click templates for popular local stdio and hosted OAuth MCP servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Search 9,600+ Servers in Catalogue →", action: onOpenCatalogue)
                    .buttonStyle(.link)
                    .font(.caption)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                ForEach(mcp.curatedPresets) { server in
                    MCPDetectedServerCard(
                        server: server,
                        disabled: isWorking,
                        onAdd: {
                            Task { await model.registerDetectedServer(server, into: mcp) }
                        },
                        onDiscover: {
                            populateForm(from: server)
                            Task { await model.discoverDetectedServer(server, into: mcp) }
                        }
                    )
                }
            }
        }
    }

    private func populateForm(from server: MCPSourcesModel.DetectedServer) {
        name = server.config.name
        command = server.config.command
        argumentsText = server.config.arguments.joined(separator: " ")
        environmentText = server.config.environmentNames.joined(separator: " ")
        domain = server.config.domain
    }

    // MARK: - Form to config

    private func discoverConfig() -> MCPServerConfig {
        MCPServerConfig(
            name: trimmed(name).isEmpty ? "discover" : trimmed(name),
            command: trimmed(command),
            arguments: words(argumentsText),
            environmentNames: words(environmentText),
            domain: domain
        )
    }

    private func addConfig() -> MCPServerConfig {
        let allowed = mcp.discoveredTools.map(\.name).filter { mcp.isAllowed($0) }

        var arguments: [String: [String: JSONValue]] = [:]
        for tool in allowed {
            let filled = (mcp.toolArguments[tool] ?? [:]).compactMapValues { raw -> JSONValue? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .string(trimmed)
            }
            if !filled.isEmpty { arguments[tool] = filled }
        }

        if var base = mcp.pendingDiscoveredConfig {
            base.allowedTools = allowed
            base.toolArguments = arguments
            return base
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
        if let pending = mcp.pendingDiscoveredConfig {
            return !pending.name.isEmpty && (!pending.command.isEmpty || pending.url != nil)
        }
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

private struct MCPSummaryStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { cardBody }
                    .buttonStyle(.plain)
            } else {
                cardBody
            }
        }
    }

    private var cardBody: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: tint)
        .contentShape(.rect)
    }
}

private struct MCPDetectedServerCard: View {
    let server: MCPSourcesModel.DetectedServer
    let disabled: Bool
    let onAdd: () -> Void
    let onDiscover: () -> Void

    private var isHosted: Bool { server.config.url != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: server.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.displayTitle)
                            .font(.callout.weight(.semibold))
                        Text(server.sourceBadge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(server.isInstalledOnMac ? .green : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (server.isInstalledOnMac ? Color.green : Color.secondary).opacity(0.14),
                                in: .capsule
                            )
                    }
                    Text(server.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                MetricPill(label: "transport", value: isHosted ? "OAuth HTTP" : "stdio")
                MetricPill(label: "domain", value: server.config.domain.rawValue)
                Spacer()
                if !isHosted {
                    Button("Discover Tools", action: onDiscover)
                        .controlSize(.small)
                        .openCoreGlassButton()
                        .disabled(disabled)
                }
                Button("Add to Sources", action: onAdd)
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true)
                    .disabled(disabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12)
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
            Text("Connect a Custom Stdio MCP Server")
                .font(.subheadline.weight(.semibold))
            MCPSourcesField(label: "Name", prompt: "slack", text: $name)
            MCPSourcesField(label: "Command", prompt: "npx", text: $command)
            MCPSourcesField(label: "Arguments", prompt: "-y @modelcontextprotocol/server-slack", text: $argumentsText)
            MCPSourcesField(label: "Environment", prompt: "SLACK_BOT_TOKEN", text: $environmentText)

            Text("Arguments are split on spaces. Environment takes variable NAMES, never values: the value is read from your environment or Keychain when the server launches and is never written to the database.")
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
                Button("Discover Tools", action: discover)
                    .openCoreGlassButton(prominent: true)
                    .disabled(disabled || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12)
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
            HStack(alignment: .top) {
                MCPSourcesDiscoveryHeader(
                    serverName: mcp.discoveredServerName,
                    protocolVersion: mcp.discoveredProtocolVersion,
                    command: mcp.discoveredCommand,
                    toolCount: mcp.discoveredTools.count
                )
                Spacer()
                HStack(spacing: 8) {
                    Button("Tick Likely Read-Only") {
                        mcp.selectAllLikelyReadOnly()
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true)
                    .help("Pre-check ready tools whose advisory is Likely Read. Review before saving.")

                    Button("Clear All") {
                        mcp.clearAllowed()
                    }
                    .controlSize(.small)
                    .openCoreGlassButton()
                    .disabled(mcp.allowedCount == 0)
                }
            }

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
        .padding(16)
        .openCoreGlassCard(cornerRadius: 12)
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
    @Environment(\.appModel) private var model
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
                MCPToolPicker(mcp: mcp, actionLabel: "Save Allowlist", disabled: mcp.allowedCount == 0) {
                    Task {
                        await model.saveAllowedTools(for: row, into: mcp)
                        dismiss()
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, minHeight: 640)
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
        .openCoreGlassCard(cornerRadius: 10)
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
            Button(label, action: action)
                .openCoreGlassButton(prominent: true)
                .disabled(disabled)
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

    private var serverIcon: String {
        let low = row.name.lowercased()
        if low.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if low == "rea" || low.contains("reverse") { return "cpu.fill" }
        if low.contains("notion") { return "doc.richtext" }
        if low.contains("context7") { return "book.pages" }
        if low.contains("gemini") { return "sparkles" }
        if low.contains("developer-knowledge") { return "books.vertical.fill" }
        if low.contains("home") { return "house.and.flag.fill" }
        if low.contains("catalog") || low.contains("dataplex") { return "cylinder.split.1x2.fill" }
        if low.contains("sequential") { return "brain.head.profile" }
        if low.contains("data-agent") { return "cloud.fill" }
        if low.contains("notebook") { return "menucard.fill" }
        if low.contains("visual") { return "chart.xyaxis.line" }
        if low.contains("linear") { return "line.3.horizontal.decrease.circle" }
        if low.contains("sentry") { return "ladybug.fill" }
        if low.contains("slack") { return "bubble.left.and.text.bubble.right.fill" }
        return "powerplug.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: serverIcon)
                    .font(.title3)
                    .foregroundStyle(hasAllowlist ? Color.accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        (hasAllowlist ? Color.accentColor : Color.secondary).opacity(0.14),
                        in: .rect(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(row.source.displayName)
                            .font(.callout.weight(.semibold))
                        Text(hostedEndpoint != nil ? "OAUTH HTTP" : "STDIO")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: .capsule)
                        if hasAllowlist {
                            Text("\(row.config?.allowedTools.count ?? 0) tools enabled")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: .capsule)
                        }
                    }
                    Text(commandLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                HStack(spacing: 8) {
                    if hostedEndpoint != nil { signInButton }
                    toolsButton
                    Button("Sync", action: sync)
                        .controlSize(.small)
                        .openCoreGlassButton()
                        .disabled(disabled || !canCall || !hasAllowlist)
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help("Remove \(row.name)")
                    .disabled(disabled)
                }
            }

            detail

            if let signInError {
                Label(signInError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: hasAllowlist ? .accentColor : nil)
        .task { refreshSignedIn() }
    }

    private var hostedEndpoint: URL? {
        guard let raw = row.config?.url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var canCall: Bool { row.config != nil && (hostedEndpoint == nil || signedIn) }

    private var hasAllowlist: Bool { !(row.config?.allowedTools.isEmpty ?? true) }

    @ViewBuilder
    private var toolsButton: some View {
        if hasAllowlist {
            Button("Edit Tools", action: chooseTools)
                .controlSize(.small)
                .openCoreGlassButton()
                .disabled(disabled || !canCall)
                .help(toolsHelp)
        } else {
            Button("Choose Tools", action: chooseTools)
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
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
            Button("Sign Out") {
                do {
                    try MCPSignIn.signOut(server: row.name)
                    signInError = nil
                    refreshSignedIn()
                } catch {
                    signInError = error.localizedDescription
                }
            }
            .controlSize(.small)
            .openCoreGlassButton()
        } else {
            Button("Sign In", action: startSignIn)
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
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
        if let url = config.url, !url.isEmpty { return url }
        return ([config.command] + config.arguments).joined(separator: " ")
    }

    @ViewBuilder
    private var detail: some View {
        if let config = row.config {
            MCPSourcesAllowlistLine(tools: config.allowedTools, isHostedAndUnsigned: hostedEndpoint != nil && !signedIn)
            HStack(spacing: 12) {
                MetricPill(label: "domain", value: config.domain.rawValue)
                MetricPill(label: "authority", value: config.authority.label)
                syncedPill
                let origins = config.environmentOrigins()
                if !origins.isEmpty {
                    ForEach(origins, id: \.variable) { item in
                        MetricPill(label: item.variable, value: item.origin)
                    }
                }
            }
            if !row.missingEnvironment.isEmpty {
                Label(
                    "not set in your environment or Keychain: \(row.missingEnvironment.joined(separator: ", ")). Sync refuses to run until they are set.",
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
    var isHostedAndUnsigned: Bool = false

    var body: some View {
        if tools.isEmpty {
            if isHostedAndUnsigned {
                Label("Hosted OAuth server: click Sign In, then Choose Tools to select read-only tools.", systemImage: "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Ready to configure: click Choose Tools to inspect this server and tick read-only tools.", systemImage: "checklist")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("allowed: \(tools.joined(separator: ", "))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

// MARK: - Shared

private struct MCPSourcesNotice: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10, tint: .accentColor)
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

// MARK: - OpenCore Outbound MCP Server Inspector & Live Playground

struct OpenCoreMCPServerInspectorView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings

    enum ToolChoice: String, CaseIterable, Identifiable {
        case ask = "core_ask"
        case search = "core_search"
        case claims = "core_claims"
        case dossier = "core_dossier"
        case timeline = "core_timeline"
        case contradictions = "core_contradictions"
        case changed = "core_changed"
        case trace = "core_trace"

        var id: String { rawValue }

        var promptPlaceholder: String {
            switch self {
            case .ask: "Question (e.g. What is OpenCore built with?)"
            case .search: "Search query (e.g. SQLite)"
            case .claims, .dossier: "Entity name (e.g. OpenCore)"
            case .timeline: "Optional entity filter (or leave blank for all)"
            case .contradictions: "Leave blank (or type 'unresolved' for unresolved only)"
            case .changed: "Days lookback (e.g. 30)"
            case .trace: "Receipt short code (e.g. oc_...)"
            }
        }
    }

    struct CheckRow: Identifiable, Sendable {
        let id: String
        let endpoint: String
        let passed: Bool
        let milliseconds: Int
        let preview: String
    }

    @State private var selectedTool: ToolChoice = .ask
    @State private var parameterInput = "What is OpenCore built with?"
    @State private var secondaryInput = ""
    @State private var outputText = ""
    @State private var lastLatencyMs: Int?
    @State private var running = false
    @State private var healthChecks: [CheckRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusBanner
                playgroundPanel
                healthcheckPanel
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("OpenCore MCP Server")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await runFullHealthcheck() }
                } label: {
                    Label("Verify All Endpoints", systemImage: "checkmark.shield.fill")
                        .font(.caption.weight(.semibold))
                }
                .openCoreGlassButton(prominent: true)
                .disabled(running || model.store == nil)
            }
            Text("Inspect and test the exact JSON-RPC methods and 8 read-only tools that Claude Code, Codex, and Antigravity call over `opencore mcp`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 16) {
            MetricPill(label: "protocol", value: MCPServer.protocolVersion)
            MetricPill(label: "supported", value: MCPServer.supportedProtocolVersions.joined(separator: ", "))
            MetricPill(label: "tools", value: "\(MCPServer.toolDefinitions.count)")
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: settings.confirmedMCPExposure == nil ? "questionmark.diamond" :
                        settings.confirmedMCPExposure == true ? "lock.open.trianglebadge.exclamationmark" : "lock.shield.fill")
                    .foregroundStyle(settings.confirmedMCPExposure == true ? .orange : .secondary)
                Text(settings.mcpExposureSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(settings.confirmedMCPExposure == true ? .orange : .secondary)
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 10)
        .task { settings.observeInitialMCPStartupConfiguration(SharedConfig.readMCPExposure()) }
    }

    private var playgroundPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Live Tool Playground")

            HStack(spacing: 10) {
                Picker("Tool", selection: $selectedTool) {
                    ForEach(ToolChoice.allCases) { tool in
                        Text(tool.rawValue).font(.caption.monospaced()).tag(tool)
                    }
                }
                .frame(width: 220)
                .onChange(of: selectedTool) { _, newValue in
                    switch newValue {
                    case .ask: parameterInput = "What is OpenCore built with?"
                    case .search: parameterInput = "evidence"
                    case .claims, .dossier: parameterInput = "OpenCore"
                    case .timeline: parameterInput = ""
                    case .contradictions: parameterInput = ""
                    case .changed: parameterInput = "30"
                    case .trace: parameterInput = model.receipts.first?.shortCode ?? ""
                    }
                }

                TextField(selectedTool.promptPlaceholder, text: $parameterInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await runSelectedTool() }
                    }

                if selectedTool == .ask || selectedTool == .claims {
                    TextField("as_of (YYYY-MM-DD, optional)", text: $secondaryInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 175)
                }

                Button("Execute") {
                    Task { await runSelectedTool() }
                }
                .openCoreGlassButton(prominent: true)
                .disabled(running || model.store == nil)
            }

            if !outputText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Response (\(selectedTool.rawValue))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let lastLatencyMs {
                            Text("\(lastLatencyMs) ms")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ScrollView {
                        Text(outputText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 140, maxHeight: 280)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 12)
    }

    @ViewBuilder
    private var healthcheckPanel: some View {
        if !healthChecks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Endpoint Verification Matrix", count: healthChecks.count)
                    Spacer()
                    let passedCount = healthChecks.filter(\.passed).count
                    Text("\(passedCount)/\(healthChecks.count) passed")
                        .font(.caption.monospaced())
                        .foregroundStyle(passedCount == healthChecks.count ? .green : .orange)
                }

                ForEach(healthChecks) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: row.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(row.passed ? .green : .red)
                        Text(row.endpoint)
                            .font(.caption.monospaced().weight(.semibold))
                            .frame(width: 175, alignment: .leading)
                        Text(row.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.milliseconds)ms")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 12)
        }
    }

    private func makeServer() -> MCPServer? {
        guard let store = model.store else { return nil }
        let current = SharedConfig.readMCPExposure()
        settings.observeInitialMCPStartupConfiguration(current)
        let verified = settings.revalidateMCPStartupConfirmation(currentSharedSetting: current)
        return MCPServer(
            store: store,
            embedder: try? NLEmbeddingProvider(),
            sensitiveDomainsUnlockable: verified && settings.confirmedMCPExposure == true
        )
    }

    private func sendRPC(_ server: MCPServer, method: String, params: [String: JSONValue] = [:]) async throws -> (JSONValue, Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string(method),
            "params": .object(params),
        ])
        let data = try JSONEncoder().encode(payload)
        let req = try RPCRequest.decode(data)
        let result = try await server.handle(req)
        let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return (result, ms)
    }

    private func callTool(_ server: MCPServer, name: String, arguments: [String: JSONValue]) async throws -> (String, Bool, Int) {
        let (res, ms) = try await sendRPC(
            server,
            method: "tools/call",
            params: [
                "name": .string(name),
                "arguments": .object(arguments),
            ]
        )
        let isErr = res["isError"]?.boolValue ?? false
        let text = res["content"]?.arrayValue?.first?["text"]?.stringValue ?? "\(res)"
        return (text, isErr, ms)
    }

    private func runSelectedTool() async {
        guard let server = makeServer() else { return }
        running = true
        defer { running = false }

        let trimmed = parameterInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = secondaryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: JSONValue] = [:]

        switch selectedTool {
        case .ask:
            args["query"] = .string(trimmed.isEmpty ? "What is OpenCore?" : trimmed)
            if !secondary.isEmpty { args["as_of"] = .string(secondary) }
        case .search:
            args["query"] = .string(trimmed.isEmpty ? "OpenCore" : trimmed)
            args["limit"] = .number(6)
        case .claims:
            args["entity"] = .string(trimmed.isEmpty ? "OpenCore" : trimmed)
            if !secondary.isEmpty { args["as_of"] = .string(secondary) }
        case .dossier:
            args["entity"] = .string(trimmed.isEmpty ? "OpenCore" : trimmed)
        case .timeline:
            args["days"] = .number(90)
            if !trimmed.isEmpty { args["entity"] = .string(trimmed) }
        case .contradictions:
            args["unresolved_only"] = .bool(trimmed.lowercased().contains("unresolved"))
        case .changed:
            args["days"] = .number(Double(Int(trimmed) ?? 30))
        case .trace:
            args["receipt"] = .string(trimmed)
        }

        do {
            let (text, _, ms) = try await callTool(server, name: selectedTool.rawValue, arguments: args)
            outputText = text
            lastLatencyMs = ms
        } catch {
            outputText = "RPC error: \(error)"
            lastLatencyMs = nil
        }
    }

    private func runFullHealthcheck() async {
        guard let server = makeServer(), let store = model.store else { return }
        running = true
        defer { running = false }

        var rows: [CheckRow] = []
        let sampleEntity = (try? await store.entitiesByActivity(limit: 1).first?.0.canonicalName) ?? "OpenCore"

        do {
            let (initRes, ms) = try await sendRPC(server, method: "initialize", params: ["protocolVersion": .string("2025-11-25")])
            let ver = initRes["protocolVersion"]?.stringValue ?? "?"
            rows.append(CheckRow(id: "initialize", endpoint: "initialize", passed: ver == "2025-11-25", milliseconds: ms, preview: "protocolVersion: \(ver)"))
        } catch {
            rows.append(CheckRow(id: "initialize", endpoint: "initialize", passed: false, milliseconds: 0, preview: "\(error)"))
        }

        do {
            let (pingRes, ms) = try await sendRPC(server, method: "ping")
            rows.append(CheckRow(id: "ping", endpoint: "ping", passed: pingRes.objectValue != nil, milliseconds: ms, preview: "200 OK"))
        } catch {
            rows.append(CheckRow(id: "ping", endpoint: "ping", passed: false, milliseconds: 0, preview: "\(error)"))
        }

        do {
            let (listRes, ms) = try await sendRPC(server, method: "tools/list")
            let count = listRes["tools"]?.arrayValue?.count ?? 0
            rows.append(CheckRow(id: "tools/list", endpoint: "tools/list", passed: count == 8, milliseconds: ms, preview: "\(count) tools registered"))
        } catch {
            rows.append(CheckRow(id: "tools/list", endpoint: "tools/list", passed: false, milliseconds: 0, preview: "\(error)"))
        }

        let toolCalls: [(String, [String: JSONValue])] = [
            ("core_ask", ["query": .string("What is \(sampleEntity)?")]),
            ("core_search", ["query": .string(sampleEntity), "limit": .number(4)]),
            ("core_claims", ["entity": .string(sampleEntity)]),
            ("core_dossier", ["entity": .string(sampleEntity)]),
            ("core_timeline", ["days": .number(90)]),
            ("core_contradictions", ["unresolved_only": .bool(false)]),
            ("core_changed", ["days": .number(30)]),
        ]

        var latestReceiptCode = "oc_none"
        for (name, args) in toolCalls {
            do {
                let (text, isErr, ms) = try await callTool(server, name: name, arguments: args)
                if name == "core_ask",
                   let code = text.components(separatedBy: "--- receipt ").dropFirst().first?.components(separatedBy: " ---").first {
                    latestReceiptCode = code
                }
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                rows.append(CheckRow(id: name, endpoint: name, passed: !isErr && !text.isEmpty, milliseconds: ms, preview: firstLine))
            } catch {
                rows.append(CheckRow(id: name, endpoint: name, passed: false, milliseconds: 0, preview: "\(error)"))
            }
        }

        do {
            let (text, isErr, ms) = try await callTool(server, name: "core_trace", arguments: ["receipt": .string(latestReceiptCode)])
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            rows.append(CheckRow(id: "core_trace", endpoint: "core_trace", passed: !isErr && !text.isEmpty, milliseconds: ms, preview: firstLine))
        } catch {
            rows.append(CheckRow(id: "core_trace", endpoint: "core_trace", passed: false, milliseconds: 0, preview: "\(error)"))
        }

        healthChecks = rows
    }
}
