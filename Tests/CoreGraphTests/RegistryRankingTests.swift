import Foundation
import Testing

@testable import CoreIngest

/// The MCP store listed 9,000 servers in raw registry order, which is alphabetical by
/// reverse-DNS name, with no indication of which ones had a verified publisher, which were
/// deprecated, or which this app could actually add. Everything was present and nothing was
/// findable.
///
/// There is no `verified: true` field to read. The **namespace is the proof**: the registry will
/// not publish a name until the publisher demonstrates control of the matching GitHub account
/// or DNS domain, so the prefix is a real signal rather than a reputation score invented here.
@Suite("Registry ranking")
struct RegistryRankingTests {
    private static func server(
        name: String,
        title: String = "a server",
        package: RegistryServer.Package? = .init(
            registryType: "npm", identifier: "thing", runtimeHint: "npx",
            runtimeArguments: [], environment: [], transport: "stdio"
        ),
        remotes: [RegistryServer.Remote] = [],
        isDeprecated: Bool = false
    ) -> RegistryServer {
        RegistryServer(
            name: name, title: title, description: "", version: "1.0.0", repositoryURL: nil,
            package: package, remotes: remotes, isLatest: true, isDeprecated: isDeprecated
        )
    }

    @Test("a reverse-DNS namespace is domain verified and io.github is not")
    func trustComesFromTheNamespace() {
        #expect(Self.server(name: "com.stripe/mcp").trust == .domain)
        #expect(Self.server(name: "ac.inference.sh/mcp").trust == .domain)
        #expect(Self.server(name: "io.github.someone/thing").trust == .github)

        // Both are genuinely verified, and the labels must not imply one is unverified. What
        // differs is what was proved: a domain ties to an organisation, a GitHub account is
        // free to create.
        #expect(RegistryServer.PublisherTrust.domain.label == "domain verified")
        #expect(RegistryServer.PublisherTrust.github.label == "github")
    }

    @Test("deprecated sinks below everything, however well published it is")
    func deprecatedAlwaysSinks() {
        let best = Self.server(name: "com.stripe/mcp")
        let deprecated = Self.server(name: "com.stripe/old", isDeprecated: true)
        #expect(deprecated.priority < best.priority)

        // Specifically below an unverified, credential-hungry but current server: being current
        // matters more than being well published, because a deprecated server is a dead end
        // whatever its provenance.
        let scruffy = Self.server(
            name: "io.github.nobody/thing",
            package: .init(
                registryType: "npm", identifier: "t", runtimeHint: "npx", runtimeArguments: [],
                environment: [.init(name: "TOKEN", description: "", isRequired: true, isSecret: true, defaultValue: nil)],
                transport: "stdio"
            )
        )
        #expect(deprecated.priority < scruffy.priority)
    }

    @Test("what the app cannot reach at all outranks nothing")
    func unreachableSinksBelowUsable() {
        // `sse` is the older two-endpoint protocol and a different client, so it stays
        // unreachable and says so rather than being offered and then failing at sync.
        let sseOnly = Self.server(
            name: "com.stripe/mcp", package: nil,
            remotes: [.init(type: "sse", url: "https://example.com/sse")]
        )
        let launchableUnverified = Self.server(name: "io.github.nobody/thing")

        #expect(!sseOnly.reachability.isUsable)
        #expect(launchableUnverified.priority > sseOnly.priority)
    }

    @Test("a hosted server is reachable, and its endpoint is the streamable-http one")
    func hostedServersAreReachable() {
        // This is the change: a server published as an endpoint rather than a package used to
        // be written off entirely, which discarded roughly 60% of the catalogue for a reason
        // that stopped being true the day streamable HTTP and OAuth landed.
        let hosted = Self.server(
            name: "com.stripe/mcp", package: nil,
            remotes: [
                .init(type: "sse", url: "https://example.com/sse"),
                .init(type: "streamable-http", url: "https://example.com/mcp"),
            ]
        )
        #expect(hosted.reachability.isUsable)
        #expect(hosted.reachability.isHosted)
        // Picked by transport, not by position. The sse entry is listed first here on purpose.
        #expect(hosted.endpoint == "https://example.com/mcp")
    }

    @Test("a package is preferred when a server publishes both")
    func packagesWinOverEndpoints() {
        // Launching a subprocess needs no account and no network round trip, and the hosted
        // equivalent will usually want an OAuth sign-in first. Offering the heavier path when a
        // lighter one exists is a worse default even though both work.
        let both = Self.server(
            name: "com.stripe/mcp",
            remotes: [.init(type: "streamable-http", url: "https://example.com/mcp")]
        )
        #expect(!both.reachability.isHosted)
        if case .launch = both.reachability {} else { Issue.record("expected a launch, got \(both.reachability)") }
    }

    @Test("among equals, a verified publisher wins")
    func trustBreaksTiesBetweenUsableServers() {
        let domain = Self.server(name: "com.stripe/mcp")
        let github = Self.server(name: "io.github.someone/mcp")
        #expect(domain.priority > github.priority)
    }

    @Test("a status the registry has not published is not treated as deprecated")
    func absentStatusIsNotDeprecated() throws {
        // Defaulting the other way would bury every entry with incomplete metadata, which reads
        // to the user as the catalogue being broken rather than as a missing field.
        let json = """
        {"servers":[{"server":{"name":"com.example/thing","description":"d","version":"1.0.0"},
        "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":true}}}],
        "metadata":{}}
        """
        let decoded = try JSONDecoder().decode(MCPRegistry.Wire.Response.self, from: Data(json.utf8))
        let server = RegistryServer(wire: try #require(decoded.servers.first))
        #expect(!server.isDeprecated)

        let deprecatedJSON = """
        {"servers":[{"server":{"name":"com.example/thing","description":"d","version":"1.0.0"},
        "_meta":{"io.modelcontextprotocol.registry/official":{"status":"deprecated","isLatest":true}}}],
        "metadata":{}}
        """
        let second = try JSONDecoder().decode(MCPRegistry.Wire.Response.self, from: Data(deprecatedJSON.utf8))
        #expect(RegistryServer(wire: try #require(second.servers.first)).isDeprecated)
    }
}
