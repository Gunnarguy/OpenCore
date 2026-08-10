import Foundation
import Testing

@testable import CoreMCP

/// **The bug.** `initialize` answered `2025-11-25` to every client no matter which version it
/// asked for. The MCP spec says a client receiving a version it does not support should
/// disconnect, so a hardcoded reply turns "one spec behind" into "silently fails to connect",
/// and the symptom is a client listing no tools with nothing useful in any log.
///
/// Found 2026-08-10 while wiring the server into Claude Desktop, before it had a chance to
/// fail: the client's supported version could not be determined from its logs, so the fix was
/// to stop guessing and negotiate properly.
@Suite("MCP protocol negotiation")
struct ProtocolNegotiationTests {
    @Test("a version this server can speak is echoed back rather than overridden")
    func supportedVersionsAreEchoed() {
        for version in MCPServer.supportedProtocolVersions {
            #expect(MCPServer.negotiatedProtocolVersion(requested: version) == version)
        }
    }

    @Test("an unsupported version falls back to this server's own, leaving the client to decide")
    func unsupportedVersionsFallBack() {
        // Per spec the server does not refuse here. It states what it can do and the client
        // chooses whether to continue, which is why this returns a version rather than throwing.
        #expect(MCPServer.negotiatedProtocolVersion(requested: "2024-11-05") == MCPServer.protocolVersion)
        #expect(MCPServer.negotiatedProtocolVersion(requested: "not-a-version") == MCPServer.protocolVersion)
        #expect(MCPServer.negotiatedProtocolVersion(requested: nil) == MCPServer.protocolVersion)
    }

    @Test("the server never claims a revision it has not implemented")
    func doesNotClaimUnimplementedRevisions() {
        // 2026-07-28 removes the initialize handshake, makes server/discover mandatory and
        // changes every result shape. Claiming it without implementing it is the partial
        // migration .claude/rules/mcp.md forbids, and it would be worse than being a version
        // behind because the client would then expect shapes this server never sends.
        #expect(!MCPServer.supportedProtocolVersions.contains("2026-07-28"))
        #expect(MCPServer.negotiatedProtocolVersion(requested: "2026-07-28") == MCPServer.protocolVersion)

        // The advertised default must itself be one of the versions claimed as supported, or
        // the fallback answers something the same list says the server cannot speak.
        #expect(MCPServer.supportedProtocolVersions.contains(MCPServer.protocolVersion))
    }
}
