import CoreJSONRPC
import CoreModel
import CoreTelemetry
import Foundation

/// Configuration for one MCP server used as a source.
///
/// Persisted as JSON on the `source` row. **Contains no secret values, ever** — only the
/// *names* of environment variables to forward. A server needing `SLACK_TOKEN` records the
/// string `SLACK_TOKEN`; the value is read from the process environment at launch and never
/// touches the database, a log line, or the repository.
public struct MCPServerConfig: Sendable, Codable, Hashable {
    public var name: String
    /// A hosted server's MCP endpoint. When set, the transport is streamable HTTP and
    /// `command`/`arguments` are unused.
    ///
    /// Stored as a string rather than a `URL` so a malformed value read back from the database
    /// surfaces as a connection error naming the server, instead of silently decoding the
    /// whole `source` row to nil and making the source vanish from the list.
    public var url: String?
    public var command: String
    public var arguments: [String]
    /// Environment variable names to forward from the current process.
    public var environmentNames: [String]
    /// **The allowlist.** Only these tools are ever called. See `MCPClientConnector` for why
    /// this is not derived automatically.
    public var allowedTools: [String]
    /// Fixed arguments per tool, for tools that require them.
    ///
    /// Values are arbitrary JSON, not strings. MCP tool schemas routinely take objects and
    /// arrays — Notion's `notion-query-data-sources` takes a whole `{data: {query, params}}`
    /// object — and a string-only map cannot express them, so those tools could not be
    /// configured at all.
    ///
    /// The top level stays a named map because the MCP `tools/call` `arguments` field is
    /// always an object; only the values needed widening. Configs written by the earlier
    /// string-valued version decode unchanged, since a bare JSON string decodes to
    /// `.string`, so there is no migration.
    public var toolArguments: [String: [String: JSONValue]]
    public var domain: Domain
    public var authority: Authority

    public init(
        name: String,
        url: String? = nil,
        command: String,
        arguments: [String] = [],
        environmentNames: [String] = [],
        allowedTools: [String] = [],
        toolArguments: [String: [String: JSONValue]] = [:],
        domain: Domain = .personal,
        authority: Authority = .thirdPartyRecord
    ) {
        self.name = name
        self.url = url
        self.command = command
        self.arguments = arguments
        self.environmentNames = environmentNames
        self.allowedTools = allowedTools
        self.toolArguments = toolArguments
        self.domain = domain
        self.authority = authority
    }

    /// The client for whichever transport this server uses.
    ///
    /// One place decides, so a caller cannot accidentally launch a subprocess for a hosted
    /// server or hand a bearer token to a local one. The OAuth token is read at call time
    /// rather than held, because a refresh between two syncs must not be missed.
    public func makeClient() async throws -> MCPClient {
        if let url {
            guard let endpoint = URL(string: url), endpoint.scheme?.hasPrefix("http") == true else {
                throw MCPClientConnector.ClientError.badEndpoint(name: name, url: url)
            }
            // Refreshed, not read raw. An access token expires in hours and the refresh token
            // outlives it by a long way, so reading the stored value directly meant every
            // hosted source stopped working a few hours after sign-in and stayed broken:
            // `server requires authorization`, with the refresh already implemented and never
            // called. `validAccessToken` is a no-op when the token is still good.
            let token = try await MCPOAuth.validAccessToken(server: name, endpoint: endpoint)
            return MCPClient(endpoint: endpoint, accessToken: token)
        }
        return try MCPClient(command: command, arguments: arguments, environment: resolvedEnvironment())
    }

    /// True when this server signs in rather than reading a credential from the environment.
    public var usesOAuth: Bool { url != nil }

    /// Build the child environment: PATH and HOME so the server can run at all, plus only the
    /// named variables that are actually set. A name with no value is skipped silently rather
    /// than passed as empty, because an empty credential produces a confusing auth error
    /// instead of an obvious missing-variable one.
    public func resolvedEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var child: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "TMPDIR", "USER"] {
            if let value = parent[key] { child[key] = value }
        }
        // GUI apps launched from Finder/Dock receive a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin)
        // that omits Homebrew, nvm, and user-local toolchains where npx, uvx, node, and python3 live.
        let home = parent["HOME"] ?? NSHomeDirectory()
        var extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
        ]
        let nvmNodesDir = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNodesDir.path) {
            for version in versions.sorted().reversed() {
                extraPaths.insert("\(home)/.nvm/versions/node/\(version)/bin", at: 0)
            }
        }
        var pathParts = (child["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for extra in extraPaths.reversed() where !pathParts.contains(extra) {
            pathParts.insert(extra, at: 0)
        }
        child["PATH"] = pathParts.joined(separator: ":")

        for variable in environmentNames {
            // Process environment first, so a one-off shell override still works, then the
            // keychain, which is the only source the app has when launched from Finder, and
            // finally the authenticated gh CLI when a GitHub MCP server requests a token.
            if let value = parent[variable], !value.isEmpty {
                child[variable] = value
            } else if let stored = Keychain.read(account: Keychain.mcpAccount(server: name, variable: variable)), !stored.isEmpty {
                child[variable] = stored
            } else if Self.isGitHubTokenVariable(variable), let ghToken = GitHubConnector.resolveToken(), !ghToken.isEmpty {
                child[variable] = ghToken
            }
        }
        return child
    }

    public var missingEnvironment: [String] {
        let parent = ProcessInfo.processInfo.environment
        return environmentNames.filter { variable in
            if let value = parent[variable], !value.isEmpty { return false }
            if let stored = Keychain.read(account: Keychain.mcpAccount(server: name, variable: variable)), !stored.isEmpty {
                return false
            }
            if Self.isGitHubTokenVariable(variable), let ghToken = GitHubConnector.resolveToken(), !ghToken.isEmpty {
                return false
            }
            return true
        }
    }

    /// Where each declared variable's value is currently coming from, for display. Never
    /// returns a value, only its origin.
    public func environmentOrigins() -> [(variable: String, origin: String)] {
        let parent = ProcessInfo.processInfo.environment
        return environmentNames.map { variable in
            if let value = parent[variable], !value.isEmpty { return (variable, "environment") }
            switch Keychain.readResult(account: Keychain.mcpAccount(server: name, variable: variable)) {
            case .found(_, source: .keychain): return (variable, "system Keychain")
            case .found(_, source: .legacyVault): return (variable, "legacy vault; save again to protect in Keychain")
            case .authenticationRequired: return (variable, "Keychain authorization required")
            case .failed: return (variable, "credential storage error; original preserved")
            case .missing: break
            }
            if Self.isGitHubTokenVariable(variable), let ghToken = GitHubConnector.resolveToken(), !ghToken.isEmpty {
                return (variable, "gh CLI")
            }
            return (variable, "not set")
        }
    }

    private static func isGitHubTokenVariable(_ variable: String) -> Bool {
        let upper = variable.uppercased()
        return upper == "GITHUB_TOKEN" || upper == "GITHUB_PERSONAL_ACCESS_TOKEN"
    }
}

/// Ingests from any MCP server.
///
/// This is the connector that makes the other connectors unnecessary. The official registry
/// passed 9,652 servers in May 2026; rather than hand-writing an integration per service,
/// OpenCore speaks the protocol they already speak.
///
/// ## The tool policy, and why it is deliberately inconvenient
///
/// An MCP server advertises whatever tools it likes, and plenty of them **write**:
/// `send_message`, `create_issue`, `delete_file`. A sync that guessed wrong would not return
/// a bad answer, it would send an email.
///
/// So the policy is **default-deny with an explicit allowlist**, and there is no automatic
/// path around it:
///
/// - The server's `readOnlyHint` is *not* sufficient. The MCP specification states plainly
///   that annotations come from an untrusted server and must not drive safety decisions.
/// - Name heuristics are *not* sufficient. `get_message` reads; `get_approval` might send one.
/// - `MCPTool.readOnlyAdvisory` exists only to shorten a human's review list, and the call
///   path never consults it.
///
/// `opencore mcp-source discover` lists what a server offers with the advisory attached; a
/// person decides; `--tool` records the decision. That friction is the feature.
///
/// ## Content from a server is data, never instruction
///
/// Everything returned here is third-party text that OpenCore did not author. It enters at
/// `Authority.thirdPartyRecord`, below anything the user wrote themselves, and it is stored
/// as evidence to be cited rather than as anything to be acted on. Text inside a tool result
/// that looks like an instruction is simply text.
public struct MCPClientConnector: Connector {
    public let source: Source
    private let config: MCPServerConfig
    private let callTimeout: TimeInterval

    public init(config: MCPServerConfig, callTimeout: TimeInterval = 60) {
        self.config = config
        self.callTimeout = callTimeout
        self.source = Source(
            kind: .manual,
            handle: "mcp:" + config.name,
            displayName: "MCP · \(config.name)",
            defaultAuthority: config.authority,
            defaultDomain: config.domain
        )
    }

    public enum ClientError: Error, CustomStringConvertible {
        case noAllowedTools(String)
        case missingEnvironment([String])
        case toolNotOffered(String, offered: [String])
        case badEndpoint(name: String, url: String)
        case notSignedIn(String)

        public var description: String {
            switch self {
            case .noAllowedTools(let name):
                """
                MCP source '\(name)' has no allowed tools. Nothing is called by default, on \
                purpose: an MCP server can expose tools that send messages or delete data. \
                Run `opencore mcp-source discover \(name)` and add the read-only ones with --tool.
                """
            case .missingEnvironment(let names):
                "these environment variables are declared but not set: \(names.joined(separator: ", "))"
            case .toolNotOffered(let tool, let offered):
                "allowlisted tool '\(tool)' is not offered by this server. It offers: \(offered.joined(separator: ", "))"
            case .badEndpoint(let name, let url):
                "MCP source '\(name)' has an endpoint that is not an http(s) URL: '\(url)'"
            case .notSignedIn(let name):
                "not signed in to '\(name)'. Open Settings, MCP sources, and choose Sign in."
            }
        }
    }

    /// Connect and list tools without calling any. Backs `mcp-source discover`.
    public static func discover(config: MCPServerConfig) async throws -> (tools: [MCPTool], version: String?, serverName: String?) {
        let client = try await config.makeClient()
        defer { Task { await client.disconnect() } }

        try await client.connect()
        let tools = try await client.listTools()
        return (tools, await client.negotiatedVersion, await client.serverName)
    }

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        try await Telemetry.span("fetch mcp:\(config.name)", .ingest) { fetch in
        guard !config.allowedTools.isEmpty else {
            throw ClientError.noAllowedTools(config.name)
        }
        let missing = config.missingEnvironment
        guard missing.isEmpty else { throw ClientError.missingEnvironment(missing) }

        let client = try await config.makeClient()
        defer { Task { await client.disconnect() } }

        try await client.connect()
        let version = await client.negotiatedVersion ?? "unknown"
        log("connected to \(await client.serverName ?? config.command), protocol \(version)")

        let offered = try await client.listTools()
        let offeredNames = Set(offered.map(\.name))
        fetch.set("tools.offered", offered.count)
        fetch.set("tools.allowed", config.allowedTools.count)
        fetch.attribute("protocol", version)
        log("\(offered.count) tools offered, \(config.allowedTools.count) allowlisted")

        var objects: [CoreObject] = []

        for tool in config.allowedTools {
            guard offeredNames.contains(tool) else {
                // Loud, not silent. A renamed tool means this source has been quietly
                // returning less than the user thinks since the day it changed.
                Telemetry.event("tool.notOffered", .ingest, attributes: ["tool": tool, "server": config.name])
                log("SKIPPED '\(tool)': not offered by this server (renamed or removed?)")
                continue
            }

            let arguments = config.toolArguments[tool] ?? [:]

            do {
                try await Telemetry.span("tool \(tool)", .ingest, attributes: ["server": config.name]) { scope in
                    scope.set("arguments", arguments.count)
                    let outcome = try await client.callTool(tool, arguments: .object(arguments), timeout: callTimeout)

                    if outcome.isError {
                        scope.attribute("outcome", "error")
                        log("'\(tool)' returned an error: \(outcome.text.prefix(160))")
                        return
                    }
                    guard !outcome.text.isEmpty else {
                        scope.attribute("outcome", "empty")
                        scope.set("skippedBlocks", outcome.skippedBlocks)
                        log("'\(tool)' returned no text\(outcome.skippedBlocks > 0 ? " (\(outcome.skippedBlocks) non-text blocks skipped)" : "")")
                        return
                    }
                    if outcome.skippedBlocks > 0 {
                        scope.set("skippedBlocks", outcome.skippedBlocks)
                        log("'\(tool)': \(outcome.skippedBlocks) non-text block(s) skipped")
                    }

                    let produced = Self.fanOutObjects(
                        tool: tool,
                        rawText: outcome.text,
                        config: config,
                        sourceID: source.id,
                        offered: offered.first { $0.name == tool }
                    )
                    scope.set("objects", produced.count)
                    scope.set("characters", outcome.text.count)
                    scope.attribute("outcome", "ok")
                    objects.append(contentsOf: produced)
                    log("'\(tool)': \(outcome.text.count) characters -> \(produced.count) object(s)")
                }
            } catch {
                // One bad tool must not abort the sync. Everything else this server offers is
                // still worth having.
                log("'\(tool)' failed: \(error)")
            }
        }

        let stderr = await client.stderrOutput()
        if !stderr.isEmpty { log("server stderr: \(stderr.prefix(300))") }

        fetch.set("objects", objects.count)
        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
        }
    }

    // MARK: - Structured record fan-out

    /// Fan a tool's raw text response out into one `CoreObject` per logical record when the
    /// payload is a structured collection (JSON array, collection-wrapped JSON object such as
    /// Notion's `results` or REA's `records`, or JSON Lines), falling back to a single object
    /// when the response is prose or a single unstructured blob.
    ///
    /// Each fanned-out record gets a stable `externalID` (`<server>#<tool>#<recordID>`) keyed to
    /// the record's own identifier (or a deterministic digest of its canonical fields if the
    /// record carries no id), so re-syncing updates existing records in place rather than
    /// duplicating them or shifting identities when list order changes.
    public static func fanOutObjects(
        tool: String,
        rawText: String,
        config: MCPServerConfig,
        sourceID: SourceID,
        offered: MCPTool? = nil
    ) -> [CoreObject] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let records = extractRecordDictionaries(from: trimmed), !records.isEmpty {
            return records.enumerated().map { index, record in
                makeRecordObject(
                    record: record,
                    index: index,
                    tool: tool,
                    config: config,
                    sourceID: sourceID,
                    offered: offered
                )
            }
        }

        return [
            makeSingleObject(
                tool: tool,
                text: rawText,
                config: config,
                sourceID: sourceID,
                offered: offered
            )
        ]
    }

    private static let collectionKeys: [String] = [
        "results", "records", "items", "pages", "rows", "entries",
        "issues", "pull_requests", "channels", "messages", "documents", "data",
    ]

    private static func extractRecordDictionaries(from text: String) -> [[String: Any]]? {
        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: []) {
            if let array = parsed as? [[String: Any]], !array.isEmpty {
                return array
            }
            if let dict = parsed as? [String: Any] {
                for key in collectionKeys {
                    if let array = dict[key] as? [[String: Any]], !array.isEmpty {
                        return array
                    }
                    if let nested = dict[key] as? [String: Any] {
                        for innerKey in collectionKeys {
                            if let array = nested[innerKey] as? [[String: Any]], !array.isEmpty {
                                return array
                            }
                        }
                    }
                }
            }
        }

        // JSON Lines (2+ non-empty lines, every line a JSON object).
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count >= 2, lines.allSatisfy({ $0.hasPrefix("{") && $0.hasSuffix("}") }) {
            var objects: [[String: Any]] = []
            objects.reserveCapacity(lines.count)
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return nil }
                objects.append(obj)
            }
            return objects
        }

        return nil
    }

    private static func makeRecordObject(
        record: [String: Any],
        index: Int,
        tool: String,
        config: MCPServerConfig,
        sourceID: SourceID,
        offered: MCPTool?
    ) -> CoreObject {
        let canonicalData = (try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys, .prettyPrinted]
        )) ?? Data()
        let canonicalJSON = String(decoding: canonicalData, as: UTF8.self)

        let recordID = extractRecordIdentifier(from: record)
            ?? String(Digest.hex(canonicalJSON).prefix(16))
        let title = extractRecordTitle(from: record)
            ?? "\(config.name) · \(tool) · \(recordID)"
        let uri = extractString(from: record, keys: ["url", "html_url", "uri"])
        let authoredAt = extractDate(from: record)

        var metadata: [String: String] = [
            "mcp_server": config.name,
            "mcp_tool": tool,
            "mcp_command": config.command,
            "mcp_record_id": recordID,
            "mcp_record_index": String(index),
        ]
        if let hint = offered?.readOnlyHint { metadata["mcp_read_only_hint"] = String(hint) }
        if let description = offered?.description, !description.isEmpty {
            metadata["mcp_tool_description"] = String(description.prefix(500))
        }
        if let predicateType = record["predicate_type"] as? String, !predicateType.isEmpty {
            metadata["predicate_type"] = predicateType
        }
        if let evidenceID = record["evidence_id"] as? String, !evidenceID.isEmpty {
            metadata["evidence_id"] = evidenceID
        }

        let summaryHeader = extractRecordSummary(from: record, title: title)
        let body = summaryHeader.isEmpty ? canonicalJSON : "\(summaryHeader)\n\n\(canonicalJSON)"

        return CoreObject(
            sourceID: sourceID,
            kind: .document,
            externalID: "\(config.name)#\(tool)#\(recordID)",
            title: title,
            text: body,
            uri: uri,
            authoredAt: authoredAt,
            domain: config.domain,
            authority: config.authority,
            metadata: metadata
        )
    }

    private static func extractRecordIdentifier(from record: [String: Any]) -> String? {
        let idKeys = ["id", "evidence_id", "page_id", "uuid", "key", "slug", "sha", "number", "uri", "url"]
        for key in idKeys {
            if let str = record[key] as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let num = record[key] as? Int {
                return String(num)
            }
        }
        if let name = record["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractRecordTitle(from record: [String: Any]) -> String? {
        for key in ["title", "name", "headline", "summary"] {
            if let str = record[key] as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // REA analysis record: subject.name + normalized_result.procedure.name
        if let subject = record["subject"] as? [String: Any],
           let subjectName = subject["name"] as? String, !subjectName.isEmpty {
            if let norm = record["normalized_result"] as? [String: Any],
               let proc = norm["procedure"] as? [String: Any],
               let procName = proc["name"] as? String, !procName.isEmpty {
                return "\(subjectName) · \(procName)"
            }
            return subjectName
        }
        // Notion page properties: look for property of type "title" or named "Name" / "Title" / "Item"
        if let properties = record["properties"] as? [String: Any] {
            for (_, value) in properties {
                if let prop = value as? [String: Any],
                   (prop["type"] as? String) == "title",
                   let titleArray = prop["title"] as? [[String: Any]] {
                    let joined = titleArray.compactMap { $0["plain_text"] as? String }.joined()
                    if !joined.isEmpty { return joined }
                }
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return nil
    }

    private static func extractRecordSummary(from record: [String: Any], title: String) -> String {
        var lines: [String] = [title]
        for key in ["description", "text", "body", "content", "notes", "status"] {
            if let str = record[key] as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\(key): \(str)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func extractString(from record: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let str = record[key] as? String, !str.isEmpty { return str }
        }
        return nil
    }

    private static func extractDate(from record: [String: Any]) -> Date? {
        let dateKeys = ["authored_at", "created_time", "created_at", "last_edited_time", "updated_at", "timestamp", "date"]
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for key in dateKeys {
            if let str = record[key] as? String {
                if let d = isoFractional.date(from: str) ?? iso.date(from: str) {
                    return d
                }
            }
        }
        return nil
    }

    /// Fallback when a tool returns a single document or unstructured prose.
    private static func makeSingleObject(
        tool: String,
        text: String,
        config: MCPServerConfig,
        sourceID: SourceID,
        offered: MCPTool?
    ) -> CoreObject {
        var metadata: [String: String] = [
            "mcp_server": config.name,
            "mcp_tool": tool,
            "mcp_command": config.command,
        ]
        if let hint = offered?.readOnlyHint { metadata["mcp_read_only_hint"] = String(hint) }
        if let description = offered?.description, !description.isEmpty {
            metadata["mcp_tool_description"] = String(description.prefix(500))
        }

        return CoreObject(
            sourceID: sourceID,
            kind: .document,
            externalID: "\(config.name)#\(tool)",
            title: "\(config.name) · \(tool)",
            text: text,
            uri: nil,
            // The server does not tell us when this content was authored, and inventing a
            // timestamp would corrupt every temporal query that touches it. Left nil, which
            // scores 0 on the recency signal and is the honest answer.
            authoredAt: nil,
            domain: config.domain,
            authority: config.authority,
            metadata: metadata
        )
    }
}
