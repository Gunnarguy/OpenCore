import CoreJSONRPC
import Foundation

/// A tool as advertised by an MCP server.
public struct MCPTool: Sendable, Hashable {
    public let name: String
    public let description: String
    /// The server's own claim that this tool does not modify anything.
    ///
    /// **Advisory only.** The MCP specification is explicit that annotations are hints from
    /// an untrusted server and must not be relied on for safety decisions. It is surfaced so
    /// a human can weigh it, and it is never sufficient on its own.
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    /// Names of required arguments, so the client can tell which tools it can call blind.
    public let requiredArguments: [String]

    public init(name: String, description: String, readOnlyHint: Bool?, destructiveHint: Bool?, requiredArguments: [String]) {
        self.name = name
        self.description = description
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.requiredArguments = requiredArguments
    }

    /// A *suggestion* for a human reviewing this tool. Never consulted by the call path.
    ///
    /// Verb heuristics are exactly the kind of guessing this project refuses to act on:
    /// `get_message` reads, `get_approval` might send one. The assessment exists to make a
    /// review list shorter, not to make a decision.
    public var readOnlyAdvisory: String {
        if destructiveHint == true { return "server says DESTRUCTIVE" }
        let lowered = name.lowercased()
        let readingVerbs = ["list", "get", "read", "search", "fetch", "query", "find", "describe", "show", "view"]
        let writingVerbs = ["send", "create", "update", "delete", "remove", "post", "write", "set", "add", "move", "archive", "close", "merge", "run", "execute"]

        // A writing verb wins even when the server claims read-only. The name is evidence the
        // server did not choose; the annotation is a claim it did.
        if writingVerbs.contains(where: { lowered.hasPrefix($0) || lowered.contains("_" + $0) }) {
            return readOnlyHint == true ? "name suggests WRITE (server disagrees)" : "name suggests WRITE"
        }
        if readingVerbs.contains(where: { lowered.hasPrefix($0) || lowered.contains("_" + $0) }) {
            return readOnlyHint == true ? "likely read-only (name and server agree)" : "name suggests read"
        }
        // Name says nothing. Report the server's claim as the server's claim rather than
        // discarding it: it is weak evidence, but "unclear" when an annotation exists throws
        // away the only signal available.
        switch readOnlyHint {
        case true: return "server says read-only (name unclear)"
        case false: return "server says NOT read-only"
        case nil: return "unclear, and the server does not say"
        }
    }
}

/// Speaks MCP to a server subprocess.
///
/// Handles both live protocol generations. `2025-11-25` and earlier open with an `initialize`
/// handshake; `2026-07-28` removed it entirely and made `server/discover` mandatory. Rather
/// than requiring the user to know which a server implements, this tries `initialize` and
/// falls back to `server/discover` when the server reports the method does not exist, which
/// the newer spec explicitly endorses as a compatibility probe on stdio.
public actor MCPClient {
    public static let preferredProtocolVersion = "2025-11-25"

    private let transport: StdioTransport
    private(set) public var negotiatedVersion: String?
    private(set) public var serverName: String?

    public init(command: String, arguments: [String], environment: [String: String]) throws {
        transport = try StdioTransport(command: command, arguments: arguments, environment: environment)
    }

    public func connect(timeout: TimeInterval = 30) async throws {
        do {
            let result = try await transport.request(
                "initialize",
                params: .object([
                    "protocolVersion": .string(Self.preferredProtocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("opencore"), "version": .string("0.3.0")]),
                ]),
                timeout: timeout
            )
            negotiatedVersion = result["protocolVersion"]?.stringValue
            serverName = result["serverInfo"]?["name"]?.stringValue
            // Required by the older spec; a server that never receives it may refuse to serve.
            try await transport.notify("notifications/initialized")
        } catch StdioTransport.TransportError.remote(let code, _) where code == -32601 {
            // No `initialize`: a 2026-07-28 stateless server.
            let result = try await transport.request("server/discover", timeout: timeout)
            negotiatedVersion = result["protocolVersions"]?.stringValue
                ?? result["protocolVersion"]?.stringValue
                ?? "2026-07-28"
            serverName = result["serverInfo"]?["name"]?.stringValue
        }
    }

    public func listTools(timeout: TimeInterval = 30) async throws -> [MCPTool] {
        let result = try await transport.request("tools/list", timeout: timeout)
        guard case .array(let raw)? = result["tools"] else { return [] }

        return raw.compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            var required: [String] = []
            if case .array(let items)? = entry["inputSchema"]?["required"] {
                required = items.compactMap(\.stringValue)
            }
            return MCPTool(
                name: name,
                description: entry["description"]?.stringValue ?? "",
                readOnlyHint: entry["annotations"]?["readOnlyHint"]?.boolValue,
                destructiveHint: entry["annotations"]?["destructiveHint"]?.boolValue,
                requiredArguments: required
            )
        }
    }

    /// Call a tool and flatten its content blocks into text.
    ///
    /// Only `text` blocks are read. Images and embedded resources are counted and reported
    /// rather than silently dropped, because "this tool returned nothing" and "this tool
    /// returned three images we cannot read" are different facts.
    public func callTool(_ name: String, arguments: JSONValue = .object([:]), timeout: TimeInterval = 60) async throws -> (text: String, skippedBlocks: Int, isError: Bool) {
        let result = try await transport.request(
            "tools/call",
            params: .object(["name": .string(name), "arguments": arguments]),
            timeout: timeout
        )

        var parts: [String] = []
        var skipped = 0
        if case .array(let blocks)? = result["content"] {
            for block in blocks {
                if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue {
                    parts.append(text)
                } else {
                    skipped += 1
                }
            }
        }
        return (parts.joined(separator: "\n\n"), skipped, result["isError"]?.boolValue ?? false)
    }

    public func stderrOutput() async -> String {
        await transport.stderrOutput()
    }

    public func disconnect() async {
        await transport.shutdown()
    }
}
