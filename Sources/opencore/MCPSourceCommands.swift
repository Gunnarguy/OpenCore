import CoreGraph
import CoreIngest
import CoreJSONRPC
import CoreModel
import CoreStore
import Foundation

/// `opencore mcp-source ...` — manage MCP servers used as ingestion sources.
enum MCPSourceCommands {
    static func usage() {
        print("""
        opencore mcp-source — use any MCP server as a source

          oauth --url URL
              Does this hosted server support signing in? Checks discovery, PKCE, and
              dynamic client registration. Unauthenticated, so it works before you have
              any credential at all.

          discover (--command CMD [--arg A ...] [--env NAME ...] | --url URL)
              Connect, list what the server offers, and print a read-only advisory for each
              tool. Calls nothing. Run this first.

          add NAME (--command CMD [--arg A ...] [--env NAME ...] | --url URL)
                   --tool TOOL [--tool TOOL ...]
                   [--tool-arg TOOL:key=value ...]
                   [--tool-arg-json TOOL:key=<json> ...]
                   [--domain personal|project|work|medical|financial|public]
              Record a server and the tools it is allowed to call.
              --tool-arg values are always strings. Use --tool-arg-json when the tool's
              parameter is an object, an array, a number or a boolean.

          list                 configured MCP sources and their allowlists
          remove NAME          delete the source and everything derived from it

        Then: opencore sync mcp NAME

        Only allowlisted tools are ever called. An MCP server can expose tools that send
        messages or delete data, and its own read-only annotation is a hint from an untrusted
        peer, so nothing runs until you name it.

        --env passes variable NAMES, never values. The value is read from your environment at
        launch and is never written to the database.

        --url is a hosted server over streamable HTTP. Those authenticate with OAuth instead
        of an environment variable: add the source, then sign in from the app (the browser
        sheet needs a window, so the CLI cannot present it). The token lands in the keychain
        and `sync` reads it from there.
        """)
    }

    // MARK: - oauth

    /// `opencore mcp-source oauth --url URL` — check what a hosted server needs to sign in.
    ///
    /// Everything here is unauthenticated by design, so it can be run against any server
    /// without holding a credential. It answers the only question that decides whether a
    /// "Sign in" button is possible at all: does the server support **dynamic client
    /// registration**? With it, OpenCore registers itself at runtime and the user approves a
    /// browser sheet. Without it, somebody has to create a client in a developer portal first.
    static func oauth() async throws {
        guard let raw = option("url"), let url = URL(string: raw) else {
            print("usage: opencore mcp-source oauth --url https://mcp.example.com/mcp")
            exit(1)
        }

        print("endpoint    \(url.absoluteString)")
        let metadata = try await MCPOAuth.discover(endpoint: url)
        print("issuer      \(metadata.issuer)")
        print("authorize   \(metadata.authorizationEndpoint.absoluteString)")
        print("token       \(metadata.tokenEndpoint.absoluteString)")
        print("PKCE S256   \(metadata.supportsS256 ? "yes" : "NO — OAuth 2.1 requires it; refusing to downgrade")")

        guard let registration = metadata.registrationEndpoint else {
            print("register    not offered")
            print("\nThis server needs a client id configured by hand. No sign-in button is possible.")
            return
        }
        print("register    \(registration.absoluteString)")

        // Registering is the real test. Discovery only proves a document exists; this proves
        // the server will actually accept OpenCore as a client.
        let client = try await MCPOAuth.register(metadata, redirectURI: Self.redirectURI)
        print("client id   \(client.clientID.prefix(8))… (registered just now, no setup required)")

        let pkce = MCPOAuth.PKCE()
        let authorize = try MCPOAuth.authorizationURL(
            metadata, client: client, pkce: pkce,
            redirectURI: Self.redirectURI, state: UUID().uuidString, resource: url
        )
        print("\nSign-in is available. The app opens this in a browser sheet:")
        print("  \(authorize.absoluteString.prefix(120))…")
    }

    /// Custom scheme rather than a loopback port: `ASWebAuthenticationSession` hands the
    /// callback straight back to the app, so no local listener is opened and nothing else on
    /// the machine can race for the port.
    static let redirectURI = "opencore://oauth/callback"

    // MARK: - discover

    static func discover() async throws {
        let hosted = option("url")
        guard let command = option("command") ?? hosted.map({ _ in "" }) else {
            print("usage: opencore mcp-source discover (--command CMD | --url URL)")
            exit(1)
        }

        // A hosted server needs the token from whichever source row already signed in, so
        // discovery is named after it rather than using the throwaway "discover" name.
        let config = MCPServerConfig(
            name: option("as") ?? (hosted != nil ? "notion" : "discover"),
            url: hosted,
            command: command,
            arguments: options("arg"),
            environmentNames: options("env")
        )

        let missing = config.missingEnvironment
        if !missing.isEmpty {
            print("warning: declared but not set in your environment: \(missing.joined(separator: ", "))")
            print("         the server may fail to authenticate.\n")
        }

        print("connecting to \(hosted ?? command)...")
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

        Then: opencore mcp-source add NAME \(hosted.map { "--url \($0)" } ?? "--command \(command)") --tool <name> [--tool ...]
        """)
    }

    // MARK: - add

    static func add(_ name: String) async throws {
        let hosted = option("url")
        guard let command = option("command") ?? hosted.map({ _ in "" }) else {
            print("usage: opencore mcp-source add NAME (--command CMD | --url URL) --tool TOOL [--tool TOOL ...]")
            exit(1)
        }
        let allowed = options("tool")
        // A hosted server's tool list cannot be read until someone has signed in, so the row
        // has to be creatable before the allowlist is known. The safety property is unchanged:
        // `fetch` still throws `noAllowedTools`, so an empty allowlist cannot sync. It only
        // moves when the allowlist is chosen, not whether it is required.
        if allowed.isEmpty && hosted == nil {
            print("At least one --tool is required.")
            print("Nothing is called by default: run `opencore mcp-source discover --command \(command)` first.")
            exit(1)
        }

        // --tool-arg TOOL:key=value            value is always a string
        // --tool-arg-json TOOL:key=<json>      value is parsed as JSON
        //
        // Two flags rather than one that guesses. A tool taking `{"limit": "10"}` and one
        // taking `{"limit": 10}` are both real, and no rule inferred from the text can tell
        // which the server wants without reading its schema.
        var toolArguments: [String: [String: JSONValue]] = [:]
        func split(_ raw: String, flag: String) -> (tool: String, key: String, value: String) {
            guard let colon = raw.firstIndex(of: ":"),
                  let equals = raw[raw.index(after: colon)...].firstIndex(of: "=")
            else {
                print("--\(flag) must look like TOOL:key=value, got '\(raw)'")
                exit(1)
            }
            return (
                String(raw[raw.startIndex..<colon]),
                String(raw[raw.index(after: colon)..<equals]),
                String(raw[raw.index(after: equals)...])
            )
        }

        for raw in options("tool-arg") {
            let (tool, key, value) = split(raw, flag: "tool-arg")
            toolArguments[tool, default: [:]][key] = .string(value)
        }

        for raw in options("tool-arg-json") {
            let (tool, key, value) = split(raw, flag: "tool-arg-json")
            do {
                toolArguments[tool, default: [:]][key] = try JSONValue.parse(value)
            } catch {
                // A hard stop, not a fallback to string. Silently storing malformed JSON as
                // text would surface later as the server rejecting the call, which reads as
                // the server being broken rather than as a typo here.
                print("--tool-arg-json \(tool):\(key) is not valid JSON: \(value)")
                exit(1)
            }
        }

        let domainName = option("domain") ?? "personal"
        guard let domain = Domain(rawValue: domainName) else {
            print("unknown domain '\(domainName)'. One of: \(Domain.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }

        let config = MCPServerConfig(
            name: name,
            url: hosted,
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
        if let hosted {
            print("endpoint    \(hosted)  (streamable HTTP, OAuth)")
        } else {
            print("command     \(command) \(config.arguments.joined(separator: " "))")
        }
        print("tools       \(allowed.joined(separator: ", "))")
        print("domain      \(domain.rawValue)  (reachable from: \(domain.readableDomains.map(\.rawValue).sorted().joined(separator: ", ")))")
        if !config.environmentNames.isEmpty {
            let missing = config.missingEnvironment
            print("env         \(config.environmentNames.joined(separator: ", "))\(missing.isEmpty ? " (all set)" : "  ⚠ not set: \(missing.joined(separator: ", "))")")
        }
        if hosted != nil && allowed.isEmpty {
            print("\nnext: open the app, Settings -> MCP sources, and choose Sign in.")
            print("      then `opencore mcp-source discover --url \(hosted!)` to pick tools.")
            print("      sync refuses to run until at least one tool is allowlisted.")
        } else {
            print("\nnext: opencore sync mcp \(name)")
        }
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
                if let url = config.url {
                    let state = MCPOAuth.stored(server: config.name) != nil ? "signed in" : "NOT signed in"
                    print("  endpoint  \(url)")
                    print("  auth      OAuth, \(state)")
                } else {
                    print("  command   \(config.command) \(config.arguments.joined(separator: " "))")
                }
                print("  tools     \(config.allowedTools.isEmpty ? "none yet — sync will refuse" : config.allowedTools.joined(separator: ", "))")
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
