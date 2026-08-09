import CoreJSONRPC
import CoreModel
import Foundation

/// Configuration for one MCP server used as a source.
///
/// Persisted as JSON on the `source` row. **Contains no secret values, ever** — only the
/// *names* of environment variables to forward. A server needing `SLACK_TOKEN` records the
/// string `SLACK_TOKEN`; the value is read from the process environment at launch and never
/// touches the database, a log line, or the repository.
public struct MCPServerConfig: Sendable, Codable, Hashable {
    public var name: String
    public var command: String
    public var arguments: [String]
    /// Environment variable names to forward from the current process.
    public var environmentNames: [String]
    /// **The allowlist.** Only these tools are ever called. See `MCPClientConnector` for why
    /// this is not derived automatically.
    public var allowedTools: [String]
    /// Fixed arguments per tool, for tools that require them.
    public var toolArguments: [String: [String: String]]
    public var domain: Domain
    public var authority: Authority

    public init(
        name: String,
        command: String,
        arguments: [String] = [],
        environmentNames: [String] = [],
        allowedTools: [String] = [],
        toolArguments: [String: [String: String]] = [:],
        domain: Domain = .personal,
        authority: Authority = .thirdPartyRecord
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environmentNames = environmentNames
        self.allowedTools = allowedTools
        self.toolArguments = toolArguments
        self.domain = domain
        self.authority = authority
    }

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
            }
        }
    }

    /// Connect and list tools without calling any. Backs `mcp-source discover`.
    public static func discover(config: MCPServerConfig) async throws -> (tools: [MCPTool], version: String?, serverName: String?) {
        let client = try MCPClient(
            command: config.command,
            arguments: config.arguments,
            environment: config.resolvedEnvironment()
        )
        defer { Task { await client.disconnect() } }

        try await client.connect()
        let tools = try await client.listTools()
        return (tools, await client.negotiatedVersion, await client.serverName)
    }

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        guard !config.allowedTools.isEmpty else {
            throw ClientError.noAllowedTools(config.name)
        }
        let missing = config.missingEnvironment
        guard missing.isEmpty else { throw ClientError.missingEnvironment(missing) }

        let client = try MCPClient(
            command: config.command,
            arguments: config.arguments,
            environment: config.resolvedEnvironment()
        )
        defer { Task { await client.disconnect() } }

        try await client.connect()
        let version = await client.negotiatedVersion ?? "unknown"
        log("connected to \(await client.serverName ?? config.command), protocol \(version)")

        let offered = try await client.listTools()
        let offeredNames = Set(offered.map(\.name))
        log("\(offered.count) tools offered, \(config.allowedTools.count) allowlisted")

        var objects: [CoreObject] = []

        for tool in config.allowedTools {
            guard offeredNames.contains(tool) else {
                // Loud, not silent. A renamed tool means this source has been quietly
                // returning less than the user thinks since the day it changed.
                log("SKIPPED '\(tool)': not offered by this server (renamed or removed?)")
                continue
            }

            var arguments: [String: JSONValue] = [:]
            for (key, value) in config.toolArguments[tool] ?? [:] {
                arguments[key] = .string(value)
            }

            do {
                let outcome = try await client.callTool(tool, arguments: .object(arguments), timeout: callTimeout)

                if outcome.isError {
                    log("'\(tool)' returned an error: \(outcome.text.prefix(160))")
                    continue
                }
                guard !outcome.text.isEmpty else {
                    log("'\(tool)' returned no text\(outcome.skippedBlocks > 0 ? " (\(outcome.skippedBlocks) non-text blocks skipped)" : "")")
                    continue
                }
                if outcome.skippedBlocks > 0 {
                    log("'\(tool)': \(outcome.skippedBlocks) non-text block(s) skipped")
                }

                objects.append(makeObject(tool: tool, text: outcome.text, offered: offered.first { $0.name == tool }))
                log("'\(tool)': \(outcome.text.count) characters")
            } catch {
                // One bad tool must not abort the sync. Everything else this server offers is
                // still worth having.
                log("'\(tool)' failed: \(error)")
            }
        }

        let stderr = await client.stderrOutput()
        if !stderr.isEmpty { log("server stderr: \(stderr.prefix(300))") }

        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
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
