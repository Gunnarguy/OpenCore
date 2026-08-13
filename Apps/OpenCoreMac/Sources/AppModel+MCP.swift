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

    var allowedCount: Int { allowed.count }

    func isAllowed(_ tool: String) -> Bool { allowed.contains(tool) }

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

        state = .working("connecting to mcp:\(row.name)")
        do {
            let connector = MCPClientConnector(config: config)
            let batch = try await connector.fetch(since: row.source.lastSyncedAt, cursor: nil) { [weak self] message in
                Task { @MainActor in self?.state = .working(message) }
            }

            guard !batch.objects.isEmpty else {
                try await store.markSynced(row.id, at: Date(), cursor: batch.cursor)
                mcp.notice = "\(row.name) returned nothing."
                await loadMCPSources(into: mcp)
                await refresh()
                state = .idle
                return
            }

            state = .working("deriving from \(batch.objects.count) objects")
            let outcome = try await pipeline(for: store).run(objects: batch.objects)
            try await store.markSynced(row.id, at: Date(), cursor: batch.cursor)

            mcp.notice = "\(row.name): \(outcome.ingest.inserted) new, \(outcome.ingest.updated) changed, \(outcome.ingest.unchanged) unchanged."
            await loadMCPSources(into: mcp)
            await refresh()
            state = .idle
        } catch {
            state = .failed("mcp:\(row.name): \(error)")
        }
    }

    /// Mirrors `mcp-source remove`, which takes the objects with it. That is legitimate:
    /// "I no longer want this source" is a different statement from "I changed my mind about
    /// a fact", and only the second one is forbidden from deleting.
    func removeMCPSource(_ row: MCPSourcesModel.SourceRow, into mcp: MCPSourcesModel) async {
        guard let store else { return }
        state = .working("removing mcp:\(row.name)")
        do {
            let removed = try await store.removeSource(row.id)
            mcp.notice = "Removed \(row.name) and \(removed) object(s) derived from it."
            await loadMCPSources(into: mcp)
            await refresh()
            state = .idle
        } catch {
            state = .failed("mcp remove: \(error)")
        }
    }

    /// Read-only, so it leaves `state` alone unless it fails, like the other loaders.
    func loadMCPSources(into mcp: MCPSourcesModel) async {
        guard let store else { return }
        do {
            let all = try await store.sources()
            mcp.sources = all
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
        } catch {
            state = .failed("\(error)")
        }
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
