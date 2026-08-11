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
        for variable in environmentNames {
            // Process environment first, so a one-off shell override still works, then the
            // keychain, which is the only source the app has when launched from Finder.
            if let value = parent[variable], !value.isEmpty {
                child[variable] = value
            } else if let stored = Keychain.read(account: Keychain.mcpAccount(server: name, variable: variable)), !stored.isEmpty {
                child[variable] = stored
            }
        }
        return child
    }

    public var missingEnvironment: [String] {
        let parent = ProcessInfo.processInfo.environment
        return environmentNames.filter { variable in
            if let value = parent[variable], !value.isEmpty { return false }
            let stored = Keychain.read(account: Keychain.mcpAccount(server: name, variable: variable))
            return (stored ?? "").isEmpty
        }
    }

    /// Where each declared variable's value is currently coming from, for display. Never
    /// returns a value, only its origin.
    public func environmentOrigins() -> [(variable: String, origin: String)] {
        let parent = ProcessInfo.processInfo.environment
        return environmentNames.map { variable in
            if let value = parent[variable], !value.isEmpty { return (variable, "environment") }
            if let stored = Keychain.read(account: Keychain.mcpAccount(server: name, variable: variable)), !stored.isEmpty {
                return (variable, "keychain")
            }
            return (variable, "not set")
        }
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

                    // One object per call is the known-wrong granularity for a list-shaped
                    // response: `objects` incrementing by exactly one per tool regardless of
                    // how many records came back is the signature of that bug, and this
                    // counter is what makes it visible without reading the store.
                    scope.set("objects", 1)
                    scope.set("characters", outcome.text.count)
                    scope.attribute("outcome", "ok")
                    objects.append(makeObject(tool: tool, text: outcome.text, offered: offered.first { $0.name == tool }))
                    log("'\(tool)': \(outcome.text.count) characters")
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

    /// One object per tool call.
    ///
    /// `externalID` is the server name plus the tool name, deliberately excluding the result
    /// content, so a re-sync of the same tool *updates* one object rather than accumulating a
    /// new one every run. Content-hash comparison in the store then makes an unchanged result
    /// free.
    private func makeObject(tool: String, text: String, offered: MCPTool?) -> CoreObject {
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
            sourceID: source.id,
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
