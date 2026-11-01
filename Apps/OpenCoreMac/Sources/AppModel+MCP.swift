import CoreGraph
import CoreIngest
import CoreJSONRPC
import CoreModel
import CoreStore
import Foundation
import Observation

// MARK: - Review state

/// The scratch state of an MCP review: what a server offered, and what a person has ticked.
///
/// It is a separate object rather than stored properties on `AppModel` because a Swift
/// extension cannot add storage. The *behaviour* still lives in `extension AppModel` below so
/// the app cannot drift from the CLI; only the in-progress review lives here. Losing it when
/// the screen closes is the right outcome: a half-reviewed tool list must never survive as
/// though it had been approved.
@MainActor
@Observable
final class MCPSourcesModel {
    /// What the last discovery listed. Discovery calls nothing, so this is a menu, not a log.
    var discoveredTools: [MCPTool] = []
    var discoveredServerName: String?
    var discoveredProtocolVersion: String?
    /// The command the current list came from, so a list cannot be read as belonging to a
    /// command the user has edited since.
    var discoveredCommand: String?

    /// The allowlist under construction. Empty, and it stays empty until a person ticks.
    var allowed: Set<String> = []
    /// Fixed arguments per tool, keyed tool name then argument name.
    var toolArguments: [String: [String: String]] = [:]

    /// The configured source whose tools are being chosen, or `nil` when the discovery panel
    /// belongs to the add-a-new-server form.
    ///
    /// The two cases end differently: a new server is written with `addMCPSource`, an existing
    /// one has its allowlist updated in place, and only the second must leave `lastSyncedAt`
    /// alone.
    var editing: SourceRow?

    /// Arguments already stored as something other than a JSON string, rendered for display.
    ///
    /// The form's fields are text, so anything typed here is a `.string`. An object or number
    /// set from the CLI's `--tool-arg-json` cannot round-trip through a text field, so it is
    /// shown read-only rather than offered for editing and silently flattened.
    var lockedArguments: [String: [String: String]] = [:]

    var sources: [SourceRow] = []
    var detectedOnMac: [DetectedServer] = []
    var curatedPresets: [DetectedServer] = []
    var registeredOpenCoreClients: [String] = []
    var pendingDiscoveredConfig: MCPServerConfig?
    /// The one line of outcome text the CLI would have printed.
    var notice: String?

    struct SourceRow: Identifiable, Sendable {
        let id: SourceID
        let source: Source
        /// The handle without its `mcp:` prefix, which is the name the CLI takes.
        let name: String
        let config: MCPServerConfig?
        let missingEnvironment: [String]
    }

    struct DetectedServer: Identifiable, Sendable, Hashable {
        var id: String { name }
        let name: String
        let displayTitle: String
        let summary: String
        let symbol: String
        let sourceBadge: String
        let config: MCPServerConfig
        let isInstalledOnMac: Bool
    }

    var allowedCount: Int { allowed.count }

    func isAllowed(_ tool: String) -> Bool { allowed.contains(tool) }

    /// Convenience button in the human review sheet: ticks all ready tools whose advisory is
    /// `.likelyRead`. Nothing is saved or called until the user reviews the selection and
    /// clicks Save / Add Source.
    func selectAllLikelyReadOnly() {
        for tool in discoveredTools where MCPToolRisk(tool) == .likelyRead && isReady(tool) {
            allowed.insert(tool.name)
        }
    }

    func clearAllowed() {
        allowed.removeAll()
    }

    /// A tool whose required arguments are unfilled cannot be ticked. Calling it anyway
    /// would fail inside the server, and the user would read that as the server being broken
    /// rather than as a form they did not finish.
    ///
    /// An argument already set as JSON counts as filled. It is not editable here, but it is
    /// present, and refusing to tick a tool the CLI has fully configured would be wrong.
    func isReady(_ tool: MCPTool) -> Bool {
        tool.requiredArguments.allSatisfy { key in
            if lockedArguments[tool.name]?[key] != nil { return true }
            return !argument(key, for: tool.name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func lockedArgument(_ key: String, for tool: String) -> String? {
        lockedArguments[tool]?[key]
    }

    func setAllowed(_ isOn: Bool, for tool: MCPTool) {
        guard isOn else {
            allowed.remove(tool.name)
            return
        }
        guard isReady(tool) else { return }
        allowed.insert(tool.name)
    }

    func argument(_ key: String, for tool: String) -> String {
        toolArguments[tool]?[key] ?? ""
    }

    func setArgument(_ value: String, key: String, for tool: MCPTool) {
        toolArguments[tool.name, default: [:]][key] = value
        // Emptying an argument un-ticks the tool rather than leaving an allowlist entry that
        // would go out with a parameter missing.
        if !isReady(tool) { allowed.remove(tool.name) }
    }

    func clearDiscovery() {
        discoveredTools = []
        discoveredServerName = nil
        discoveredProtocolVersion = nil
        discoveredCommand = nil
        allowed = []
        toolArguments = [:]
        lockedArguments = [:]
        editing = nil
        pendingDiscoveredConfig = nil
    }

    /// Point the discovery panel at a source that already exists, pre-filled with what it
    /// already allows.
    ///
    /// Showing an allowlist a person previously ticked is not deriving one. Default-deny is a
    /// rule about what a *server* offers; opening this sheet with every box clear would read as
    /// the allowlist having been lost and would invite re-ticking from scratch.
    func beginEditing(_ row: SourceRow, config: MCPServerConfig) {
        editing = row
        allowed = Set(config.allowedTools)
        for (tool, arguments) in config.toolArguments {
            for (key, value) in arguments {
                if case .string(let text) = value {
                    toolArguments[tool, default: [:]][key] = text
                } else {
                    lockedArguments[tool, default: [:]][key] = value.displayJSON
                }
            }
        }
    }

    /// The allowlist's arguments, ready to store.
    ///
    /// Values carried in `lockedArguments` are taken from `existing` untouched. The form writes
    /// strings, and parsing its text back into JSON to preserve an object would be the guess
    /// this project deliberately refused when it added `--tool-arg-json` as a second flag
    /// rather than making `--tool-arg` clever: `{"limit":"10"}` and `{"limit":10}` are both
    /// real, and no rule can tell which a server wants without reading its schema.
    func mergedArguments(
        allowed: [String],
        existing: [String: [String: JSONValue]]
    ) -> [String: [String: JSONValue]] {
        var merged: [String: [String: JSONValue]] = [:]
        for tool in allowed {
            var arguments: [String: JSONValue] = [:]
            let locked = lockedArguments[tool] ?? [:]
            for (key, value) in existing[tool] ?? [:] where locked[key] != nil {
                arguments[key] = value
            }
            for (key, raw) in toolArguments[tool] ?? [:] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, locked[key] == nil else { continue }
                arguments[key] = .string(trimmed)
            }
            if !arguments.isEmpty { merged[tool] = arguments }
        }
        return merged
    }
}

private extension JSONValue {
    /// Compact JSON, for showing a value this form cannot edit.
    var displayJSON: String {
        guard let data = try? JSONEncoder().encode(self) else { return "unreadable" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Advisory reading

/// How a tool's advisory should read at a glance.
///
/// Derived from `MCPTool.readOnlyAdvisory` rather than from a second look at the hints, so a
/// colour can never disagree with the sentence printed beside it. Like the advisory itself
/// this is a review aid and never a gate. The allowlist is the gate.
enum MCPToolRisk: Sendable {
    case destructive
    case write
    case unclear
    case likelyRead

    init(_ tool: MCPTool) {
        let advisory = tool.readOnlyAdvisory
        if advisory.contains("DESTRUCTIVE") {
            self = .destructive
        } else if advisory.contains("WRITE") || advisory.contains("NOT read-only") {
            self = .write
        } else if advisory.contains("read-only") || advisory.contains("suggests read") {
            self = .likelyRead
        } else {
            self = .unclear
        }
    }
}

// MARK: - Behaviour

extension AppModel {
    /// Connect, list what the server offers, call nothing. Mirrors `mcp-source discover`.
    func discoverMCP(config: MCPServerConfig, into mcp: MCPSourcesModel) async {
        mcp.clearDiscovery()

        let missing = config.missingEnvironment
        mcp.notice = missing.isEmpty
            ? nil
            : "Declared but not set in your environment: \(missing.joined(separator: ", ")). The server may fail to authenticate."

        // A hosted server has no command, so naming one would print "connecting to " and read
        // as a truncated message rather than as a server reached over HTTP.
        let reached = config.url ?? config.command
        state = .working("connecting to \(reached)")
        do {
            let result = try await MCPClientConnector.discover(config: config)
            mcp.discoveredTools = result.tools.sorted { $0.name < $1.name }
            mcp.discoveredServerName = result.serverName
            mcp.discoveredProtocolVersion = result.version
            mcp.discoveredCommand = reached
            state = .idle
        } catch {
            state = .failed("mcp discover: \(error)")
        }
    }

    /// List what an **already configured** source offers, so its allowlist can be changed
    /// without the CLI.
    ///
    /// This is the step that was stranded. Adding a hosted server records it with no allowlist,
    /// because a hosted server cannot list its tools until it is signed in, and until now
    /// nothing in the app could run discovery against a source that already existed. Sync then
    /// failed with `noAllowedTools` and the only remedy was `opencore mcp-source discover`.
    func discoverTools(for row: MCPSourcesModel.SourceRow, into mcp: MCPSourcesModel) async {
        guard let config = row.config else {
            state = .failed("\(row.name): configuration missing or unreadable. Remove and add it again.")
            return
        }
        // Runs first: it calls `clearDiscovery`, which would otherwise wipe the editing target.
        await discoverMCP(config: config, into: mcp)
        guard !mcp.discoveredTools.isEmpty else { return }
        mcp.beginEditing(row, config: config)
    }

    /// Write a changed allowlist back to a configured source.
    ///
    /// Upserts the row that was read rather than rebuilding a `Source` from the connector, so
    /// `lastSyncedAt` and the sync cursor survive. Rebuilding would reset both and make the
    /// next sync re-fetch everything as though the source were new.
    func saveAllowedTools(for row: MCPSourcesModel.SourceRow, into mcp: MCPSourcesModel) async {
        guard let store, var config = row.config else { return }

        let allowed = mcp.discoveredTools.map(\.name).filter { mcp.isAllowed($0) }
        guard !allowed.isEmpty else {
            state = .failed("Nothing is called by default. Tick at least one tool, or remove the source.")
            return
        }

        config.allowedTools = allowed
        config.toolArguments = mcp.mergedArguments(allowed: allowed, existing: config.toolArguments)

        state = .working("updating mcp:\(row.name)")
        do {
            var source = row.source
            source.config = try Self.encodeMCPConfig(config)
            try await store.upsert(source)

            mcp.clearDiscovery()
            mcp.notice = "\(row.name) now allows \(allowed.count) tool(s). Sync it to fetch."
            await loadMCPSources(into: mcp)
            state = .idle
        } catch {
            state = .failed("mcp tools: \(error)")
        }
    }

    /// Mirrors `mcp-source add`. The Source comes from the connector rather than being built
    /// here, so the app and the CLI cannot produce two different rows for the same server.
    func addMCPSource(config: MCPServerConfig, into mcp: MCPSourcesModel) async {
        guard let store else { return }
        guard !config.allowedTools.isEmpty else {
            state = .failed("Nothing is called by default. Tick at least one tool before adding this source.")
            return
        }

        state = .working("adding mcp:\(config.name)")
        do {
            var source = MCPClientConnector(config: config).source
            source.config = try Self.encodeMCPConfig(config)
            try await store.upsert(source)

            mcp.clearDiscovery()
            mcp.notice = "Added \(config.name) with \(config.allowedTools.count) allowed tool(s). Sync it to fetch."
            await loadMCPSources(into: mcp)
            await refresh()
            state = .idle
        } catch {
            state = .failed("mcp add: \(error)")
        }
    }

    /// Mirrors `sync mcp NAME`, including running the result through `IngestPipeline`, which
    /// is the only path from objects to a reconciled graph.
    ///
    /// It does not reuse the app's generic connector funnel because that funnel rebuilds a
    /// Source from the connector, while an MCP source's allowlist lives on the stored row and
    /// is the thing being honoured here.
    func syncMCPSource(_ row: MCPSourcesModel.SourceRow, into mcp: MCPSourcesModel) async {
        guard let store else { return }
        guard let config = row.config else {
            state = .failed("\(row.name): configuration missing or unreadable. Remove and add it again.")
            return
        }

        await exclusively("mcp:\(row.name)", refused: { _ in }) {
            state = .working("connecting to mcp:\(row.name)")
            do {
                let connector = MCPClientConnector(config: config)
                let report = try await SourceSync(store: store, pipeline: pipeline(for: store)).run(
                    row.id,
                    phase: { [weak self] phase in
                        guard case .deriving(let objects) = phase else { return }
                        await self?.showDerivingFromMCP(objects)
                    },
                    fetch: { [weak self] since in
                        try await connector.fetch(since: since, cursor: nil) { message in
                            Task { @MainActor in self?.state = .working(message) }
                        }
                    }
                )

                if let outcome = report.derived {
                    mcp.notice = "\(row.name): \(outcome.ingest.inserted) new, \(outcome.ingest.updated) changed, \(outcome.ingest.unchanged) unchanged."
                } else {
                    mcp.notice = "\(row.name): \(report.heldBecause ?? "nothing new.")"
                }
                await loadMCPSources(into: mcp)
                await refresh()
                state = .idle
            } catch {
                state = .failed("mcp:\(row.name): \(error)")
            }
        }
    }

    private func showDerivingFromMCP(_ objects: Int) {
        state = .working("deriving from \(objects) objects")
    }

    /// Mirrors `mcp-source remove`, which takes the objects with it. That is legitimate:
    /// "I no longer want this source" is a different statement from "I changed my mind about
    /// a fact", and only the second one is forbidden from deleting.
    func removeMCPSource(_ row: MCPSourcesModel.SourceRow, into mcp: MCPSourcesModel) async {
        guard let store else { return }
        state = .working("removing mcp:\(row.name)")
        do {
            var dismissed = Set(UserDefaults.standard.stringArray(forKey: "mcp.dismissedLocalServers") ?? [])
            dismissed.insert(row.name)
            UserDefaults.standard.set(Array(dismissed).sorted(), forKey: "mcp.dismissedLocalServers")

            let removed = try await store.removeSource(row.id)
            mcp.notice = "Removed \(row.name) and \(removed) object(s) derived from it."
            await loadMCPSources(into: mcp)
            await refresh()
            state = .idle
        } catch {
            state = .failed("mcp remove: \(error)")
        }
    }

    /// Connect and list tools for a detected or preset server.
    func discoverDetectedServer(_ server: MCPSourcesModel.DetectedServer, into mcp: MCPSourcesModel) async {
        await discoverMCP(config: server.config, into: mcp)
        if !mcp.discoveredTools.isEmpty {
            mcp.pendingDiscoveredConfig = server.config
        }
    }

    /// Register a detected or preset server in `store` with an empty allowlist (`allowedTools: []`),
    /// preserving default-deny until a human chooses which tools may run.
    func registerDetectedServer(_ server: MCPSourcesModel.DetectedServer, into mcp: MCPSourcesModel) async {
        guard let store else { return }
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: "mcp.dismissedLocalServers") ?? [])
        dismissed.remove(server.name)
        UserDefaults.standard.set(Array(dismissed).sorted(), forKey: "mcp.dismissedLocalServers")

        state = .working("adding mcp:\(server.name)")
        do {
            var config = server.config
            config.allowedTools = []
            var source = MCPClientConnector(config: config).source
            source.config = try Self.encodeMCPConfig(config)
            try await store.upsert(source)
            mcp.notice = "Added \(server.displayTitle). Click Choose tools on its card to select which read-only tools may run."
            await loadMCPSources(into: mcp)
            await refresh()
            state = .idle
        } catch {
            state = .failed("mcp add: \(error)")
        }
    }

    /// Register all detected Mac MCP servers at once with `allowedTools: []`.
    func registerAllDetectedServers(into mcp: MCPSourcesModel) async {
        guard let store, !mcp.detectedOnMac.isEmpty else { return }
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: "mcp.dismissedLocalServers") ?? [])
        let servers = mcp.detectedOnMac
        state = .working("importing \(servers.count) detected MCP servers")
        do {
            for server in servers {
                dismissed.remove(server.name)
                var config = server.config
                config.allowedTools = []
                var source = MCPClientConnector(config: config).source
                source.config = try Self.encodeMCPConfig(config)
                try await store.upsert(source)
            }
            UserDefaults.standard.set(Array(dismissed).sorted(), forKey: "mcp.dismissedLocalServers")
            mcp.notice = "Imported \(servers.count) MCP server(s) detected on this Mac. Click Choose tools on any card to enable read tools."
            await loadMCPSources(into: mcp)
            await refresh()
            state = .idle
        } catch {
            state = .failed("mcp import: \(error)")
        }
    }

    /// Read-only loader that also scans the Mac's installed MCP configurations (`~/.gemini/config/mcp_config.json`,
    /// `~/.claude.json`, Claude Desktop, Cursor) and seeds newly discovered local servers into `store`
    /// with `allowedTools: []` (strict default-deny preserved).
    func loadMCPSources(into mcp: MCPSourcesModel) async {
        guard let store else { return }
        do {
            let scanResult = Self.scanLocalMCPConfigs()
            mcp.registeredOpenCoreClients = scanResult.openCoreClients

            var all = try await store.sources()
            var existingNames = Set(
                all.filter { $0.handle.hasPrefix("mcp:") }
                    .map { String($0.handle.dropFirst("mcp:".count)).lowercased() }
            )
            let dismissed = Set(
                (UserDefaults.standard.stringArray(forKey: "mcp.dismissedLocalServers") ?? [])
                    .map { $0.lowercased() }
            )

            // Seed newly discovered local MCP servers into `store` with `allowedTools: []` so the
            // user immediately sees every MCP server already installed on their Mac without
            // breaking the default-deny tool allowlist gate.
            var didSeedAny = false
            for detected in scanResult.servers {
                let lowered = detected.name.lowercased()
                let normalized = lowered.replacingOccurrences(of: "-mcp-server", with: "")
                if existingNames.contains(lowered) || existingNames.contains(normalized) || dismissed.contains(lowered) {
                    continue
                }
                var config = detected.config
                config.allowedTools = []
                var source = MCPClientConnector(config: config).source
                source.config = try Self.encodeMCPConfig(config)
                try await store.upsert(source)
                existingNames.insert(lowered)
                didSeedAny = true
            }
            if didSeedAny {
                all = try await store.sources()
            }

            let configuredRows = all
                .filter { $0.handle.hasPrefix("mcp:") }
                .map { source -> MCPSourcesModel.SourceRow in
                    let config = source.config.flatMap { Self.decodeMCPConfig($0) }
                    return MCPSourcesModel.SourceRow(
                        id: source.id,
                        source: source,
                        name: String(source.handle.dropFirst("mcp:".count)),
                        config: config,
                        missingEnvironment: config?.missingEnvironment ?? []
                    )
                }
            mcp.sources = configuredRows

            let activeNames = Set(configuredRows.map { $0.name.lowercased() })
            mcp.detectedOnMac = scanResult.servers.filter { !activeNames.contains($0.name.lowercased()) }
            mcp.curatedPresets = Self.builtInPresets().filter { preset in
                let low = preset.name.lowercased()
                return !activeNames.contains(low)
                    && !activeNames.contains("\(low)-mcp-server")
                    && !mcp.detectedOnMac.contains(where: { $0.name.lowercased() == low })
            }
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Local Mac MCP Discovery & Presets

    private struct LocalScanResult {
        var servers: [MCPSourcesModel.DetectedServer]
        var openCoreClients: [String]
    }

    /// Scans local AI client MCP configuration files (`~/.gemini/config/mcp_config.json`,
    /// `~/.claude.json`, Claude Desktop, Cursor).
    ///
    /// Security invariant: `MCPServerConfig` only ever stores environment variable **names**
    /// (`environmentNames`), never values. Any non-empty credential value present in a local
    /// config file is bridged directly into the macOS Keychain (`Keychain.mcpAccount`) so
    /// subprocesses can authenticate without a single secret ever touching SQLite, logs, or UI.
    private static func scanLocalMCPConfigs() -> LocalScanResult {
        let home = NSHomeDirectory()
        let candidates: [(badge: String, path: String)] = [
            ("Antigravity / Gemini", "\(home)/.gemini/config/mcp_config.json"),
            ("Antigravity IDE", "\(home)/.gemini/antigravity/mcp_config.json"),
            ("Claude Code", "\(home)/.claude.json"),
            ("Claude Desktop", "\(home)/Library/Application Support/Claude/claude_desktop_config.json"),
            ("Cursor", "\(home)/.cursor/mcp.json"),
        ]

        var seenNames = Set<String>()
        var discovered: [MCPSourcesModel.DetectedServer] = []
        var openCoreClients: [String] = []

        for candidate in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mcpServers = root["mcpServers"] as? [String: Any]
            else { continue }

            for (rawName, rawEntry) in mcpServers.sorted(by: { $0.key < $1.key }) {
                guard let entry = rawEntry as? [String: Any] else { continue }
                let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }

                if trimmedName.lowercased() == "opencore" {
                    if !openCoreClients.contains(candidate.badge) {
                        openCoreClients.append(candidate.badge)
                    }
                    continue
                }

                let dedupeKey = trimmedName.lowercased()
                guard !seenNames.contains(dedupeKey) else { continue }

                let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let args = (entry["args"] as? [String]) ?? (entry["arguments"] as? [String]) ?? []
                let url = ((entry["url"] as? String) ?? (entry["serverUrl"] as? String) ?? (entry["httpUrl"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !command.isEmpty || (url != nil && !(url?.isEmpty ?? true)) else { continue }

                var envKeys: [String] = []
                if let envDict = entry["env"] as? [String: Any] {
                    for (key, rawVal) in envDict.sorted(by: { $0.key < $1.key }) {
                        envKeys.append(key)
                        if let strVal = rawVal as? String, !strVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let account = Keychain.mcpAccount(server: trimmedName, variable: key)
                            if Keychain.read(account: account) == nil {
                                try? Keychain.write(strVal, toAccount: account)
                            }
                        }
                    }
                }

                let meta = metadata(forServerNamed: trimmedName, command: command, args: args, url: url)
                let config = MCPServerConfig(
                    name: trimmedName,
                    url: (url?.isEmpty == false) ? url : nil,
                    command: command,
                    arguments: args,
                    environmentNames: envKeys,
                    allowedTools: [],
                    domain: meta.domain
                )
                seenNames.insert(dedupeKey)
                discovered.append(
                    MCPSourcesModel.DetectedServer(
                        name: trimmedName,
                        displayTitle: meta.title,
                        summary: meta.summary,
                        symbol: meta.symbol,
                        sourceBadge: candidate.badge,
                        config: config,
                        isInstalledOnMac: true
                    )
                )
            }
        }

        return LocalScanResult(servers: discovered, openCoreClients: openCoreClients)
    }

    private static func metadata(
        forServerNamed name: String,
        command: String,
        args: [String],
        url: String?
    ) -> (title: String, summary: String, symbol: String, domain: Domain) {
        let low = name.lowercased()
        if low.contains("github") {
            return (
                "GitHub MCP Server",
                "Repositories, pull requests, issues, code search, and commit history via GitHub API.",
                "chevron.left.forwardslash.chevron.right",
                .project
            )
        }
        if low == "rea" || low.contains("reverse") {
            return (
                "REA (Reverse Engineer Anything)",
                "Native Mach-O, Swift/ObjC symbols, Ghidra/Rizin decompilation, Frida runtime & binary analysis.",
                "cpu.fill",
                .project
            )
        }
        if low.contains("notion") {
            return (
                "Notion Workspace",
                "Pages, databases, data sources, blocks, and workspace search.",
                "doc.richtext",
                .project
            )
        }
        if low.contains("context7") {
            return (
                "Context7 Live SDK Docs",
                "Up-to-date framework and package documentation indexed for coding agents.",
                "book.pages",
                .project
            )
        }
        if low.contains("geminidocs") || low.contains("gemini") {
            return (
                "Gemini API & SDK Docs",
                "Official Gemini API specifications, live docs search, and code guides.",
                "sparkles",
                .project
            )
        }
        if low.contains("google-developer-knowledge") || low.contains("developer-knowledge") {
            return (
                "Google Developer Knowledge",
                "Search and query official developer documentation and reference articles.",
                "books.vertical.fill",
                .project
            )
        }
        if low.contains("google-home") {
            return (
                "Google Home Developer",
                "Smart home device feedback, anomaly distribution, and developer docs.",
                "house.and.flag.fill",
                .project
            )
        }
        if low.contains("knowledge-catalog") || low.contains("dataplex") {
            return (
                "Knowledge Catalog (Dataplex)",
                "Enterprise data catalog entries, schema context, and governance lookup.",
                "cylinder.split.1x2.fill",
                .project
            )
        }
        if low.contains("sequential") {
            return (
                "Sequential Thinking",
                "Structured multi-step reasoning and hypothesis revision protocol.",
                "brain.head.profile",
                .project
            )
        }
        if low.contains("data-agent") {
            return (
                "Data Cloud Agent Kit",
                "Google Cloud data pipeline and BigQuery asset discovery bridge.",
                "cloud.fill",
                .project
            )
        }
        if low.contains("notebook") {
            return (
                "Jupyter Notebooks Bridge",
                "Notebook execution, cell inspection, and data science runtime tools.",
                "menucard.fill",
                .project
            )
        }
        if low.contains("visual") {
            return (
                "Visualization Sidecar",
                "Interactive scientific and data visualization rendering server.",
                "chart.xyaxis.line",
                .project
            )
        }
        let fallbackSummary = url ?? ([command] + args).joined(separator: " ")
        return (name, fallbackSummary, "powerplug.fill", .project)
    }

    private static func builtInPresets() -> [MCPSourcesModel.DetectedServer] {
        [
            MCPSourcesModel.DetectedServer(
                name: "github",
                displayTitle: "GitHub",
                summary: "Issues, PRs, commits, and repository files. Uses your existing `gh auth` login automatically.",
                symbol: "chevron.left.forwardslash.chevron.right",
                sourceBadge: "Official Preset",
                config: MCPServerConfig(
                    name: "github",
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-github"],
                    environmentNames: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
                    domain: .project
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "linear",
                displayTitle: "Linear",
                summary: "Issues, cycles, projects, and engineering roadmaps over hosted OAuth HTTP.",
                symbol: "line.3.horizontal.decrease.circle",
                sourceBadge: "Hosted OAuth",
                config: MCPServerConfig(
                    name: "linear",
                    url: "https://mcp.linear.app/mcp",
                    command: "",
                    domain: .project
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "sentry",
                displayTitle: "Sentry",
                summary: "Production crash reports, stack traces, and release health over hosted OAuth HTTP.",
                symbol: "ladybug.fill",
                sourceBadge: "Hosted OAuth",
                config: MCPServerConfig(
                    name: "sentry",
                    url: "https://mcp.sentry.dev/mcp",
                    command: "",
                    domain: .project
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "slack",
                displayTitle: "Slack",
                summary: "Channel history, threads, and workspace search via `SLACK_BOT_TOKEN`.",
                symbol: "bubble.left.and.text.bubble.right.fill",
                sourceBadge: "Official Preset",
                config: MCPServerConfig(
                    name: "slack",
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-slack"],
                    environmentNames: ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"],
                    domain: .personal
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "brave-search",
                displayTitle: "Brave Web Search",
                summary: "Live web and local search results via `BRAVE_API_KEY`.",
                symbol: "globe",
                sourceBadge: "Official Preset",
                config: MCPServerConfig(
                    name: "brave-search",
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-brave-search"],
                    environmentNames: ["BRAVE_API_KEY"],
                    domain: .project
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "postgres",
                displayTitle: "PostgreSQL Inspector",
                summary: "Read-only schema inspection and SQL queries against a PostgreSQL database.",
                symbol: "cylinder.fill",
                sourceBadge: "Official Preset",
                config: MCPServerConfig(
                    name: "postgres",
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-postgres"],
                    domain: .project
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "memory",
                displayTitle: "MCP Knowledge Memory",
                summary: "Reference local JSON graph memory server from the Model Context Protocol suite.",
                symbol: "memorychip",
                sourceBadge: "Official Preset",
                config: MCPServerConfig(
                    name: "memory",
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-memory"],
                    domain: .personal
                ),
                isInstalledOnMac: false
            ),
            MCPSourcesModel.DetectedServer(
                name: "fetch",
                displayTitle: "Web Page Fetch & Markdown",
                summary: "Fetches web URLs and converts HTML documentation into clean Markdown passages.",
                symbol: "arrow.down.doc.fill",
                sourceBadge: "Official Preset",
                config: MCPServerConfig(
                    name: "fetch",
                    command: "uvx",
                    arguments: ["mcp-server-fetch"],
                    domain: .project
                ),
                isInstalledOnMac: false
            ),
        ]
    }

    // MARK: - Coding

    /// Byte-for-byte the shape the CLI writes, so a source added in either place is readable
    /// from the other.
    private static func encodeMCPConfig(_ config: MCPServerConfig) throws -> String {
        let data = try JSONEncoder().encode(config)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeMCPConfig(_ raw: String) -> MCPServerConfig? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MCPServerConfig.self, from: data)
    }
}
