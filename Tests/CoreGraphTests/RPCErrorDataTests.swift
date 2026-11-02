import Foundation
import Testing
@testable import CoreJSONRPC

private let detailMarker = "fixture-details-not-for-automatic-logs"
private let errorDetails: [JSONValue?] = [
    nil, .null, .bool(false), .number(0.125), .string(detailMarker), .array([]), .object([:]),
    .object(["supportedVersions": .array([.string("fixture-current"), .string("fixture-legacy")]),
             "requestedVersion": .string("fixture-future"), "nested": .array([.null, .bool(true), .string(detailMarker)])])
]

private func errorEnvelope(_ details: JSONValue?) -> JSONValue {
    var error: [String: JSONValue] = ["code": .int(-32022), "message": .string("fixture failure")]
    if let details { error["data"] = details }
    return .object(["jsonrpc": .string("2.0"), "id": .int(1), "error": .object(error)])
}

// The bug: error values and wire ErrorBody had no data field, so negotiation details could
// not survive encoding. Optional decodeIfPresent would additionally lose an explicit JSON null.
@Test("JSON-RPC errors preserve omitted null scalar and structured details", arguments: errorDetails)
func rpcErrorDataRoundTrips(details: JSONValue?) throws {
    let original = RPCError(code: -32022, message: "fixture failure", data: details)
    let bytes = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RPCError.self, from: bytes)
    #expect(decoded.code == -32022)
    #expect(decoded.message == "fixture failure")
    #expect(decoded.data == details)
    let object = try JSONDecoder().decode(JSONValue.self, from: bytes)
    #expect(object["data"] == details)
    let response = RPCResponse.failure(id: .string("fixture-id"), error: original)
    let wire = try JSONDecoder().decode(JSONValue.self, from: response.serialized())
    #expect(wire["id"] == .string("fixture-id"))
    #expect(wire["error"]?["data"] == details)
    #expect(wire["error"]?["code"]?.intValue == -32022)
    #expect(wire["result"] == nil)
}

@Test("existing RPC error constructors keep absent details and method-not-found fallback")
func rpcLegacyErrorsKeepTheirContract() throws {
    let errors = [RPCError.methodNotFound("fixture"), .invalidParams("fixture"), .internalError("fixture")]
    #expect(errors.map(\.code) == [-32601, -32602, -32603])
    for error in errors {
        #expect(error.data == nil)
        let wire = try JSONDecoder().decode(JSONValue.self, from: RPCResponse.failure(id: .int(1), error: error).serialized())
        #expect(wire["error"]?["data"] == nil)
    }
    let oldStdio = StdioTransport.TransportError.remote(code: -32601, message: "fixture")
    let oldHTTP = HTTPTransportError.remote(code: -32601, message: "fixture")
    #expect(rpcErrorCode(oldStdio) == -32601)
    #expect(rpcErrorCode(oldHTTP) == -32601)
    #expect(rpcError(oldStdio)?.data == nil)
    #expect(rpcError(oldHTTP)?.data == nil)
}

@Test("recognized HTTP JSON and SSE errors retain the same typed details", arguments: errorDetails)
func rpcHTTPErrorMappingRetainsData(details: JSONValue?) throws {
    let mapped = try #require(HTTPTransport.remoteError(in: errorEnvelope(details)))
    let decoded = try #require(rpcError(mapped))
    #expect(decoded.code == -32022)
    #expect(decoded.message == "fixture failure")
    #expect(decoded.data == details)
    #expect(rpcErrorCode(mapped) == -32022)
    #expect(HTTPTransport.remoteError(in: .object(["result": .object([:])])) == nil)
}

// The bug: StdioTransport stripped details while mapping a matched peer reply into its error.
// This child uses only pipes; no listener, inherited secrets, store or network service.
@Test("a stdio peer's matched error retains its protocol details", arguments: errorDetails)
func rpcStdioErrorRetainsData(details: JSONValue?) async throws {
    let bytes = try JSONEncoder().encode(errorEnvelope(details))
    let text = try #require(String(data: bytes, encoding: .utf8))
    let transport = try StdioTransport(command: "/bin/sh",
        arguments: ["-c", #"IFS= read -r request; printf '%s\n' "$1""#, "fixture", text],
        environment: ["PATH": "/usr/bin:/bin"])
    do {
        _ = try await transport.request("fixture", timeout: 5)
        await transport.shutdown()
        Issue.record("the peer error was accepted as success")
    } catch {
        await transport.shutdown()
        let decoded = try #require(rpcError(error))
        #expect(decoded.code == -32022)
        #expect(decoded.message == "fixture failure")
        #expect(decoded.data == details)
        #expect(rpcErrorCode(error) == -32022)
    }
}

// The bug: adding a stored payload to an Error without explicit formatting exposes it through
// reflection. Telemetry and app diagnostics format errors rather than inspecting structured data.
@Test("RPC and transport descriptions never automatically include structured error payloads")
func rpcErrorDescriptionsOmitData() {
    let payload = JSONValue.object(["privateFixture": .string(detailMarker)])
    let errors: [any Error] = [RPCError(code: -32022, message: "fixture failure", data: payload),
        StdioTransport.TransportError.remote(code: -32022, message: "fixture failure", data: payload),
        HTTPTransportError.remote(code: -32022, message: "fixture failure", data: payload),
        HTTPTransportError.httpStatus(400, body: detailMarker)]
    for error in errors {
        #expect(!String(describing: error).contains(detailMarker))
        #expect(!String(reflecting: error).contains(detailMarker))
        #expect(!error.localizedDescription.contains(detailMarker))
    }
    for error in errors.dropLast() {
        #expect(rpcError(error)?.data == payload, "redaction must not erase deliberate typed access")
    }
    #expect(rpcError(HTTPTransportError.httpStatus(400, body: "fixture")) == nil)
    #expect(rpcError(StdioTransport.TransportError.malformed("fixture")) == nil)
    #expect(rpcErrorCode(HTTPTransportError.unauthorized(resourceMetadata: nil)) == nil)
}
