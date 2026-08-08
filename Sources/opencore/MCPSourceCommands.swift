import CoreGraph
import CoreIngest
import CoreModel
import CoreStore
import Foundation

/// `opencore mcp-source ...` — manage MCP servers used as ingestion sources.
enum MCPSourceCommands {
    static func usage() {
        print("""
        opencore mcp-source — use any MCP server as a source

          discover --command CMD [--arg A ...] [--env NAME ...]
              Connect, list what the server offers, and print a read-only advisory for each
              tool. Calls nothing. Run this first.

          add NAME --command CMD [--arg A ...] [--env NAME ...]
                   --tool TOOL [--tool TOOL ...]
                   [--tool-arg TOOL:key=value ...]
                   [--domain personal|project|work|medical|financial|public]
              Record a server and the tools it is allowed to call.

          list                 configured MCP sources and their allowlists
          remove NAME          delete the source and everything derived from it

        Then: opencore sync mcp NAME

        Only allowlisted tools are ever called. An MCP server can expose tools that send
        messages or delete data, and its own read-only annotation is a hint from an untrusted
        peer, so nothing runs until you name it.

        --env passes variable NAMES, never values. The value is read from your environment at
        launch and is never written to the database.
        """)
    }

    // MARK: - discover

    static func discover() async throws {
        guard let command = option("command") else {
            print("usage: opencore mcp-source discover --command CMD [--arg A ...] [--env NAME ...]")
            exit(1)
        }

        let config = MCPServerConfig(
            name: "discover",
            command: command,
            arguments: options("arg"),
            environmentNames: options("env")
        )

        let missing = config.missingEnvironment
        if !missing.isEmpty {
            print("warning: declared but not set in your environment: \(missing.joined(separator: ", "))")
            print("         the server may fail to authenticate.\n")
        }

        print("connecting to \(command)...")
        let (tools, version, serverName) = try await MCPClientConnector.discover(config: config)

        print("server      \(serverName ?? "unnamed")")
        print("protocol    \(version ?? "unknown")")
        print("tools       \(tools.count)\n")

        guard !tools.isEmpty else {
            print("This server offers no tools, so there is nothing to ingest from it.")
            return
        }

        let width = min(34, tools.map(\.name.count).max() ?? 20)
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            let padded = tool.name.padding(toLength: max(width, tool.name.count), withPad: " ", startingAt: 0)
            print("  \(padded)  \(tool.readOnlyAdvisory)")
            if !tool.description.isEmpty {
                print("  \(String(repeating: " ", count: width))  \(tool.description.prefix(96))")
            }
            if !tool.requiredArguments.isEmpty {
                print("  \(String(repeating: " ", count: width))  requires: \(tool.requiredArguments.joined(separator: ", ")) (pass with --tool-arg)")
            }
        }

        print("""

        The advisory is a guess from the tool's name and the server's own annotation. It is
        not a safety check: `get_message` reads, `get_approval` might send one. Read the
        descriptions and decide yourself.

        Then: opencore mcp-source add NAME --command \(command) --tool <name> [--tool ...]
        """)
    }

    // MARK: - add

    static func add(_ name: String) async throws {
        guard let command = option("command") else {
            print("usage: opencore mcp-source add NAME --command CMD --tool TOOL [--tool TOOL ...]")
            exit(1)
        }
        let allowed = options("tool")
        guard !allowed.isEmpty else {
            print("At least one --tool is required.")
            print("Nothing is called by default: run `opencore mcp-source discover --command \(command)` first.")
            exit(1)
        }

        // --tool-arg TOOL:key=value
        var toolArguments: [String: [String: String]] = [:]
        for raw in options("tool-arg") {
            guard let colon = raw.firstIndex(of: ":"),
                  let equals = raw[raw.index(after: colon)...].firstIndex(of: "=")
            else {
                print("--tool-arg must look like TOOL:key=value, got '\(raw)'")
                exit(1)
            }
            let tool = String(raw[raw.startIndex..<colon])
            let key = String(raw[raw.index(after: colon)..<equals])
            let value = String(raw[raw.index(after: equals)...])
            toolArguments[tool, default: [:]][key] = value
        }

        let domainName = option("domain") ?? "personal"
        guard let domain = Domain(rawValue: domainName) else {
            print("unknown domain '\(domainName)'. One of: \(Domain.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }

        let config = MCPServerConfig(
            name: name,
            command: command,
            arguments: options("arg"),
            environmentNames: options("env"),
            allowedTools: allowed,
            toolArguments: toolArguments,
            domain: domain
        )

        let store = try await openStore()
        var source = MCPClientConnector(config: config).source
        source.config = try encode(config)
        try await store.upsert(source)

        print("added       \(name)")
        print("command     \(command) \(config.arguments.joined(separator: " "))")
        print("tools       \(allowed.joined(separator: ", "))")
        print("domain      \(domain.rawValue)  (reachable from: \(domain.readableDomains.map(\.rawValue).sorted().joined(separator: ", ")))")
        if !config.environmentNames.isEmpty {
            let missing = config.missingEnvironment
            print("env         \(config.environmentNames.joined(separator: ", "))\(missing.isEmpty ? " (all set)" : "  ⚠ not set: \(missing.joined(separator: ", "))")")
        }
        print("\nnext: opencore sync mcp \(name)")
    }

    // MARK: - list

    static func list() async throws {
        let store = try await openStore()
        let sources = try await store.sources().filter { $0.handle.hasPrefix("mcp:") }

        guard !sources.isEmpty else {
            print("No MCP sources. Start with: opencore mcp-source discover --command <cmd>")
            return
        }

        for source in sources {
            let config = source.config.flatMap(decode)
            print("\(source.displayName)")
            if let config {
                print("  command   \(config.command) \(config.arguments.joined(separator: " "))")
                print("  tools     \(config.allowedTools.joined(separator: ", "))")
                print("  domain    \(config.domain.rawValue)")
                let missing = config.missingEnvironment
                if !missing.isEmpty { print("  ⚠ env     not set: \(missing.joined(separator: ", "))") }
            } else {
                print("  ⚠ configuration missing or unreadable; re-add this source")
            }
            print("  synced    \(source.lastSyncedAt.map { dateFormatter.string(from: $0) } ?? "never")")
        }
    }

    // MARK: - remove

    static func remove(_ name: String) async throws {
        let store = try await openStore()
        guard let source = try await store.source(handle: "mcp:" + name, kind: .manual) else {
            print("no MCP source named '\(name)'")
            exit(1)
        }
        let removed = try await store.removeSource(source.id)
        print("removed \(name) and \(removed) object(s) derived from it")
    }

    // MARK: - sync

    static func sync(_ name: String) async throws {
        let store = try await openStore()
        guard let source = try await store.source(handle: "mcp:" + name, kind: .manual) else {
            print("no MCP source named '\(name)'. Add one with: opencore mcp-source add")
            exit(1)
        }
        guard let raw = source.config, let config = decode(raw) else {
            print("'\(name)' has no readable configuration. Re-add it.")
            exit(1)
        }

        print("syncing mcp:\(name)")
        let started = Date()

        let connector = MCPClientConnector(config: config)
        let batch = try await connector.fetch(since: source.lastSyncedAt, cursor: nil, log: progress)

        guard !batch.objects.isEmpty else {
            print("nothing returned")
            try await store.markSynced(source.id, at: Date(), cursor: batch.cursor)
            return
        }

        let outcome = try await IngestPipeline(store: store).run(objects: batch.objects, log: progress)
        try await store.markSynced(source.id, at: Date(), cursor: batch.cursor)

        report(outcome)
        print("\ndone in \(Int(Date().timeIntervalSince(started)))s")
    }

    // MARK: - Coding

    private static func encode(_ config: MCPServerConfig) throws -> String {
        let data = try JSONEncoder().encode(config)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ raw: String) -> MCPServerConfig? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MCPServerConfig.self, from: data)
    }
}
