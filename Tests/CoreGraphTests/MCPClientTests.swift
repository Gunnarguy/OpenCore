import CoreJSONRPC
import CoreModel
import Foundation
import Testing

@testable import CoreIngest

// MARK: - Credentials never reach the store

@Test("configuration carries environment variable names, never their values")
func configurationStoresNamesNotValues() throws {
    let config = MCPServerConfig(
        name: "slack",
        command: "slack-mcp",
        environmentNames: ["OPENCORE_TEST_TOKEN"],
        allowedTools: ["list_channels"]
    )

    let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    #expect(encoded.contains("OPENCORE_TEST_TOKEN"))

    // The serialised form is what lands in the database. A value must never appear in it,
    // whatever is set in the environment.
    setenv("OPENCORE_TEST_TOKEN", "super-secret-value", 1)
    defer { unsetenv("OPENCORE_TEST_TOKEN") }

    let reEncoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    #expect(!reEncoded.contains("super-secret-value"))

    // It is resolved only at launch, into the child process environment.
    #expect(config.resolvedEnvironment()["OPENCORE_TEST_TOKEN"] == "super-secret-value")
}

@Test("only declared variables are forwarded to the server")
func environmentIsNotInheritedWholesale() throws {
    setenv("OPENCORE_TEST_DECLARED", "yes", 1)
    setenv("OPENCORE_TEST_UNDECLARED", "leaked", 1)
    defer {
        unsetenv("OPENCORE_TEST_DECLARED")
        unsetenv("OPENCORE_TEST_UNDECLARED")
    }

    let config = MCPServerConfig(name: "s", command: "c", environmentNames: ["OPENCORE_TEST_DECLARED"])
    let child = config.resolvedEnvironment()

    #expect(child["OPENCORE_TEST_DECLARED"] == "yes")
    // A server gets what it was granted and nothing else. Passing the whole environment
    // would hand every unrelated credential on the machine to a third-party subprocess.
    #expect(child["OPENCORE_TEST_UNDECLARED"] == nil)
    // PATH still comes through, or the server cannot start.
    #expect(child["PATH"] != nil)
}

@Test("a declared but unset variable is reported, not silently passed as empty")
func missingEnvironmentIsReported() throws {
    unsetenv("OPENCORE_TEST_ABSENT")
    let config = MCPServerConfig(name: "s", command: "c", environmentNames: ["OPENCORE_TEST_ABSENT"])

    #expect(config.missingEnvironment == ["OPENCORE_TEST_ABSENT"])
    // Empty is worse than absent: it produces a confusing auth failure instead of an obvious
    // missing-variable one.
    #expect(config.resolvedEnvironment()["OPENCORE_TEST_ABSENT"] == nil)
}

// MARK: - Default-deny

@Test("a source with no allowlisted tools refuses to sync")
func defaultDenyBlocksSync() async throws {
    let config = MCPServerConfig(name: "unvetted", command: "/usr/bin/true", allowedTools: [])
    let connector = MCPClientConnector(config: config)

    // Must fail before launching anything. An MCP server can expose tools that send messages
    // or delete data, so "call whatever it offers" is never the default.
    await #expect(throws: MCPClientConnector.ClientError.self) {
        _ = try await connector.fetch(since: nil, cursor: nil, log: { _ in })
    }
}

@Test("MCP objects enter at third-party authority and a restrictive default domain")
func mcpContentIsThirdPartyByDefault() throws {
    let config = MCPServerConfig(name: "somewhere", command: "c", allowedTools: ["list_things"])
    let source = MCPClientConnector(config: config).source

    // Content from an MCP server was not authored by the user and is not testimony about
    // them. It must never outrank something they wrote.
    #expect(source.defaultAuthority == .thirdPartyRecord)
    #expect(source.defaultAuthority < Authority.authoredArtifact)
    #expect(source.defaultAuthority < Authority.directStatement)

    // Default domain is personal, which a project query cannot read.
    #expect(source.defaultDomain == .personal)
    #expect(!Domain.project.readableDomains.contains(.personal))
}

// MARK: - The advisory is advisory

@Test("a server's destructive annotation overrides a reassuring name")
func destructiveHintWinsOverName() throws {
    let tool = MCPTool(
        name: "list_and_purge",
        description: "",
        readOnlyHint: true,
        destructiveHint: true,
        requiredArguments: []
    )
    // The name starts with a reading verb and the server also claims readOnly. Destructive
    // must still dominate: when a server contradicts itself, believe the dangerous half.
    #expect(tool.readOnlyAdvisory == "server says DESTRUCTIVE")
}

@Test("the advisory declines to guess when the name is uninformative")
func advisoryAdmitsUncertainty() throws {
    let opaque = MCPTool(name: "core_ask", description: "", readOnlyHint: nil, destructiveHint: nil, requiredArguments: [])
    #expect(opaque.readOnlyAdvisory == "unclear, and the server does not say")

    // An uninformative name plus an annotation must not collapse to "unclear": that discards
    // the only signal available. Report it as the server's claim.
    let annotated = MCPTool(name: "core_ask", description: "", readOnlyHint: true, destructiveHint: nil, requiredArguments: [])
    #expect(annotated.readOnlyAdvisory == "server says read-only (name unclear)")

    let writing = MCPTool(name: "send_message", description: "", readOnlyHint: true, destructiveHint: nil, requiredArguments: [])
    // Even with the server claiming read-only, a writing verb is surfaced as a write. The
    // annotation comes from an untrusted peer and does not get to overrule the obvious.
    #expect(writing.readOnlyAdvisory == "name suggests WRITE (server disagrees)")

    let reading = MCPTool(name: "list_channels", description: "", readOnlyHint: true, destructiveHint: nil, requiredArguments: [])
    #expect(reading.readOnlyAdvisory.contains("read-only"))
}

// MARK: - Tool arguments carry arbitrary JSON

// Regression: `toolArguments` was `[String: [String: String]]`, so an argument could only ever
// be a string. Every MCP tool taking an object or an array was therefore unconfigurable, not
// merely awkward. The case that exposed it was Notion's `notion-query-data-sources`, whose
// parameters are `{data: {data_source_urls: [...], query: "..."}}`: without this, the Notion
// source could fetch a database's schema but never its rows.
@Test("a tool argument may be an object or an array, not only a string")
func toolArgumentsCarryArbitraryJSON() throws {
    let nested = JSONValue.object([
        "data": .object([
            "data_source_urls": .array([.string("collection://abc")]),
            "query": .string("SELECT * FROM x"),
            "page_size": .int(25),
        ])
    ])
    let config = MCPServerConfig(
        name: "notion",
        url: "https://mcp.notion.com/mcp",
        command: "",
        allowedTools: ["notion-query-data-sources"],
        toolArguments: ["notion-query-data-sources": ["data": nested]]
    )

    // The guarantee is about what survives the database, not what the initialiser accepts:
    // `config` is persisted as JSON on the source row and read back on every sync.
    let restored = try JSONDecoder().decode(
        MCPServerConfig.self,
        from: try JSONEncoder().encode(config)
    )
    let argument = restored.toolArguments["notion-query-data-sources"]?["data"]
    #expect(argument == nested)

    // Shape, not just equality: a value that degraded to a string would still be non-nil.
    #expect(argument?["data"]?["page_size"]?.intValue == 25)
    #expect(argument?["data"]?["data_source_urls"] == .array([.string("collection://abc")]))
}

// The second, independent guard. Widening the value type must not orphan the sources already
// on disk: those rows were written when the value was a bare JSON string, and a config that
// fails to decode makes the whole source vanish from the list rather than erroring visibly.
@Test("a config written by the string-only version still decodes")
func stringValuedToolArgumentsStillDecode() throws {
    let legacy = """
    {"name":"notion","command":"","arguments":[],"environmentNames":[],
     "allowedTools":["notion-fetch"],
     "toolArguments":{"notion-fetch":{"id":"some-page-id"}},
     "domain":"project","authority":3}
    """

    let config = try JSONDecoder().decode(MCPServerConfig.self, from: Data(legacy.utf8))

    #expect(config.toolArguments["notion-fetch"]?["id"] == .string("some-page-id"))
    #expect(config.allowedTools == ["notion-fetch"])
}

@Test("tool identity is stable across syncs so re-running updates rather than accumulates")
func objectIdentityIsStable() throws {
    let config = MCPServerConfig(name: "s", command: "c", allowedTools: ["t"], domain: .work)
    let source = MCPClientConnector(config: config).source

    // externalID deliberately excludes result content: including it would mint a new object
    // on every sync and the store would grow without bound.
    let first = CoreObject(
        sourceID: source.id, kind: .document, externalID: "s#t",
        title: "s · t", text: "result one", domain: .work, authority: .thirdPartyRecord
    )
    let second = CoreObject(
        sourceID: source.id, kind: .document, externalID: "s#t",
        title: "s · t", text: "result two, later", domain: .work, authority: .thirdPartyRecord
    )
    #expect(first.id == second.id)
    #expect(first.contentHash != second.contentHash)
}
