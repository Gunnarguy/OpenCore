import CoreJSONRPC
import Foundation
import Testing

// Original bug: oversized complete lines escaped the cap; partial lines became a timeout.
@Test("oversized MCP messages report their protocol error with and without a final newline", arguments: [true, false])
func oversizedMCPMessageIsNotATimeout(newline: Bool) async throws {
    let script = "read request; /usr/bin/head -c 8388609 /dev/zero | /usr/bin/tr '\\000' x; " + (newline ? "printf '\\n'; " : "") + "sleep 2"
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c", script], environment: ProcessInfo.processInfo.environment)
    do {
        _ = try await transport.request("tools/list", timeout: 5)
        Issue.record("oversized message accepted")
    } catch StdioTransport.TransportError.oversizedMessage { }
    catch { let stderr = await transport.stderrOutput(); Issue.record("wrong error: \(error), stderr: \(stderr)") }
    await transport.shutdown()
}

@Test("stdio requests end in a real LF and preserve escaped newlines inside JSON strings")
func stdioFramingPreservesPayload() async throws {
    let script = "IFS= read -r line; printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":%s}\\n' \"$line\""
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c", script], environment: ProcessInfo.processInfo.environment)
    let text = "first line\nsecond line"
    let result = try await transport.request("echo", params: .object(["text": .string(text)]), timeout: 2)
    #expect(result["params"]?["text"]?.stringValue == text)
    await transport.shutdown()
}
