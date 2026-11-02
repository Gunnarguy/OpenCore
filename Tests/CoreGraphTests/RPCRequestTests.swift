import Foundation
import Testing
@testable import CoreJSONRPC

private func decodeRequest(_ object: JSONValue) throws -> RPCRequest {
    try RPCRequest.decode(JSONEncoder().encode(object))
}
private let requestEnvelope: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string("tools/list"), "id": .int(1)]

// The bug: synthesized decodeIfPresent treated an explicit null ID as an absent ID and
// classified that invalid request as a notification, silently skipping normal dispatch.
@Test("only an absent MCP request ID is a notification", arguments: [JSONValue.null, .bool(true), .array([]), .object([:]), .number(0.5), .number(-0.5)])
func rpcRequestRejectsInvalidID(id: JSONValue) throws {
    var object = requestEnvelope
    object["id"] = id
    #expect(throws: RPCError.self) { try decodeRequest(.object(object)) }
    object["id"] = nil
    let notification = try decodeRequest(.object(object))
    #expect(notification.id == nil)
    #expect(notification.isNotification)
}

@Test("MCP request IDs retain valid strings and finite integral numbers", arguments: [JSONValue.int(0), .number(-5), .number(1e100), .string("fixture-id"), .string("")])
func rpcRequestRetainsValidID(id: JSONValue) throws {
    var object = requestEnvelope; object["id"] = id
    let request = try decodeRequest(.object(object))
    #expect(try JSONDecoder().decode(JSONValue.self, from: RPCResponse.success(id: #require(request.id), result: .null).serialized())["id"] == id)
    #expect(!request.isNotification)
    #expect(request.jsonrpc == "2.0")
    #expect(request.method == "tools/list")
}

// The bug: the synthesized decoder accepted any protocol string and no envelope validation
// ran before MCPServer.handle dispatched the decoded method.
@Test("MCP requests require the literal JSON-RPC version and a method string", arguments: Array(0..<8))
func rpcRequestRejectsInvalidEnvelope(variant: Int) throws {
    var object = requestEnvelope
    switch variant {
    case 0: object["jsonrpc"] = .string("1.0")
    case 1: object["jsonrpc"] = nil
    case 2: object["jsonrpc"] = .null
    case 3: object["jsonrpc"] = .int(2)
    case 4: object["method"] = nil
    case 5: object["method"] = .null
    case 6: object["method"] = .array([])
    default: object["method"] = .int(4)
    }
    #expect(throws: RPCError.self) { try decodeRequest(.object(object)) }
}

// The bug: arbitrary JSON params (including null and positional arrays) passed the MCP
// request decoder even though MCP's schema only permits object params when present.
@Test("MCP request params must be an object when present", arguments: [JSONValue.null, .array([]), .bool(false), .number(1), .string("fixture")])
func rpcRequestRejectsInvalidParams(params: JSONValue) throws {
    var object = requestEnvelope; object["params"] = params
    #expect(throws: RPCError.self) { try decodeRequest(.object(object)) }
}

@Test("request metadata and unknown extension values are preserved without interpretation")
func rpcRequestPreservesParams() throws {
    let metadata = JSONValue.object([
        "io.modelcontextprotocol/protocolVersion": .string("fixture-future"),
        "io.modelcontextprotocol/clientCapabilities": .object(["fixture": .bool(true)]),
        "com.example/extension": .array([.null, .number(0.125)])])
    var object = requestEnvelope
    let params = JSONValue.object(["_meta": metadata, "cursor": .string("fixture-cursor"), "arbitrary": .null])
    object["params"] = params
    let request = try decodeRequest(.object(object))
    #expect(request.params == params)
    #expect(request.params?["_meta"] == metadata)
    object["params"] = nil
    #expect(try decodeRequest(.object(object)).params == nil)
    object["params"] = .object([:])
    #expect(try decodeRequest(.object(object)).params == .object([:]))
}

@Test("malformed request errors do not automatically include input payloads")
func rpcRequestFailureOmitsPayload() throws {
    let marker = "fixture-request-private-payload"
    for object in [JSONValue.object(["jsonrpc": .string(marker), "method": .string(marker)]),
                   .object(["jsonrpc": .string("2.0"), "method": .string(marker), "id": .object(["private": .string(marker)])]),
                   .object(["jsonrpc": .string("2.0"), "method": .string(marker), "params": .string(marker)])] {
        do { _ = try decodeRequest(object); Issue.record("malformed request accepted") }
        catch {
            #expect(rpcErrorCode(error) == -32600)
            #expect(!String(reflecting: error).contains(marker))
            #expect(!error.localizedDescription.contains(marker))
        }
    }
}

@Test("non-object MCP envelopes and non-JSON numeric IDs are refused")
func rpcRequestRejectsNonObjectAndNonfinite() throws {
    for object in [JSONValue.null, .array([]), .string("fixture"), .number(2)] {
        #expect(throws: RPCError.self) { try decodeRequest(object) }
    }
    for spelling in ["Infinity", "-Infinity", "NaN"] {
        let data = Data("{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":\(spelling)}".utf8)
        #expect(throws: RPCError.self) { try RPCRequest.decode(data) }
    }
}
