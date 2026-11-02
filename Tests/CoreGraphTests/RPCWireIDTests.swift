import Foundation
import Testing
@testable import CoreJSONRPC

private func rawWireID(_ token: String) throws -> RPCID? {
    try RPCWireObject.decode(Data("{\"jsonrpc\":\"2.0\",\"id\":\(token),\"method\":\"fixture\"}".utf8)).id
}

// The bug: Double conversion rounded a raw fractional ID to an integer and changed large IDs.
@Test("exact integer ID tokens survive the wire without floating point conversion", arguments: [
    "0", "-0", "1.0", "100e-2", "9007199254740993", "-9007199254740993",
    "123456789012345678901234567890123456789012345678901234567890",
    "1e1000", "1e99999999999999999999999999999999999999999999",
    "-0.000e-99999999999999999999999999999999999999999"
])
func rpcWireIDPreservesRawIntegers(token: String) throws {
    let id = try #require(try rawWireID(token))
    let bytes = try RPCWireObject.encode(id: id, fields: ["jsonrpc": .string("2.0"), "result": .null])
    #expect(bytes.starts(with: Data("{\"id\":\(token),".utf8)))
    #expect(try RPCWireObject.decode(bytes).id == id)
}

@Test("raw fractional IDs remain invalid even when Double would round them", arguments: [
    "1.0000000000000001", "9007199254740993.1", "0.000000000000000000000000000000000000000001",
    "1e-1000", "10e-2", "-0.5", "1e-99999999999999999999999999999999999999999999"
])
func rpcWireIDRejectsExactFractions(token: String) throws {
    do { _ = try rawWireID(token); Issue.record("fractional ID accepted") }
    catch { #expect(rpcErrorCode(error) == -32600) }
}

@Test("numeric ID equality and hashing use exact mathematical integer identity")
func rpcWireIDExactEquality() throws {
    #expect(try RPCID.number("9007199254740993") != RPCID.number("9007199254740992"))
    #expect(try RPCID.number("100e-2") == .int(1))
    #expect(try RPCID.number("1.000") == .int(1))
    #expect(try RPCID.number("10e-1") == .int(1))
    #expect(try RPCID.number("-0.0e-999999999999999999999") == .int(0))
    #expect(try Set([RPCID.number("100e-2"), .number("1.000"), .int(1)]).count == 1)
    #expect(try RPCID.number("10e999999999999999999999999") == .number("1e1000000000000000000000000"))
    #expect(try RPCID.number("100000000000000000000e-20") == .int(1))
    #expect(RPCID.string("1") != .int(1))
    #expect(RPCID.string("") != .null)
}

// Swift String equality normalizes Unicode; JSON string IDs must retain their code points.
@Test("string ID identity uses decoded UTF8 instead of Swift Unicode normalization")
func rpcWireIDStringIdentity() throws {
    let composed = RPCID.string("\u{E9}"), decomposed = RPCID.string("e\u{301}")
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(try rawWireID(#""\u0061""#) == .string("a"))
    for id in [composed, decomposed, .string("\"},\"id\":4,\"fixture\":\"\n\t\\")] {
        let bytes = try RPCWireObject.encode(id: id, fields: ["result": .null])
        #expect(try RPCWireObject.decode(bytes).id == id)
        #expect(!bytes.contains(0x0A))
    }
}

@Test("missing and explicit null IDs stay separate at the wire boundary")
func rpcWireIDPresence() throws {
    #expect(try RPCWireObject.decode(Data("{\"method\":\"fixture\"}".utf8)).id == nil)
    #expect(try rawWireID("null") == .null)
    #expect(try RPCWireObject.encode(id: nil, fields: [:]) == Data("{}".utf8))
    #expect(try RPCWireObject.encode(id: .null, fields: [:]) == Data("{\"id\":null}".utf8))
}

@Test("ID extraction ignores nested fields and quoted braces and recognizes escaped keys")
func rpcWireIDScansOnlyTopLevel() throws {
    let raw = #"{"params":{"id":19,"text":"\"id\":2,} ]","array":[{"id":3}]},"\u0069d":9007199254740993,"method":"fixture"}"#
    let object = try RPCWireObject.decode(Data(raw.utf8))
    #expect(object.id == (try .number("9007199254740993")))
    #expect(object.fields["id"] == nil)
    #expect(object.fields["params"]?["id"] == .int(19))
}

@Test("ambiguous duplicate top-level fields are invalid envelopes", arguments: [
    #"{"id":1,"id":2}"#, #"{"id":1,"\u0069d":2}"#,
    #"{"method":"a","method":"b"}"#,
    #"{"id":1e999999999999999999999,"id":2e999999999999999999999}"#
])
func rpcWireIDRejectsDuplicates(raw: String) {
    do { _ = try RPCWireObject.decode(Data(raw.utf8)); Issue.record("ambiguous envelope accepted") }
    catch { #expect(rpcErrorCode(error) == -32600) }
}

// Masking an ID must never sanitize malformed syntax or hide a parse error elsewhere.
@Test("JSON syntax errors outrank semantic ID errors", arguments: [
    #"{"id":0.5,"bad":tru}"#, #"{"id":null, BAD}"#, #"{"id":true,"bad":]}"#,
    #"{"id":1,"id":2,"bad":tru}"#, #"{"id":1e+}"#,
    #"{"id":"\uD800"}"#, #"{"id":"\q"}"#, #"{"id":00}"#,
    #"{"id":1.}"#, #"{"id":.5}"#, #"{"id":NaN}"#,
    #"{"id":1}{}"#, #"{"id":1,"params":[1,]}"#, #"{"id":1,}"#,
    #"{"id":1,"params":["fixture""#, #"{"id":1,"params":{"key":"fixture""#
])
func rpcWireIDSyntaxPrecedesSemantics(raw: String) {
    do { _ = try RPCWireObject.decode(Data(raw.utf8)); Issue.record("malformed JSON accepted") }
    catch { #expect(rpcErrorCode(error) == -32700) }
}

@Test("raw numeric ID creation and serialization cannot inject JSON fields")
func rpcWireIDSealsSerialization() throws {
    for token in ["1,\"result\":4", "1\n", "0e+", "+1", "-", "01", "1e2 "] {
        #expect(throws: RPCError.self) { try RPCID.number(token) }
    }
    #expect(throws: RPCError.self) { try RPCWireObject.encode(id: .int(1), fields: ["id": .int(2)]) }
    let marker = "fixture-private-id"
    let id = RPCID.string(marker)
    #expect(!String(reflecting: id).contains(marker))
}

@Test("wrong-kind ID errors are not reclassified by numeric payload decoding", arguments: [
    #"{"id":{"x":1e1000}}"#, #"{"id":[1e1000]}"#, #"{"id":true}"#
])
func rpcWireIDInvalidKindsAfterSyntax(raw: String) {
    do { _ = try RPCWireObject.decode(Data(raw.utf8)); Issue.record("invalid ID kind accepted") }
    catch { #expect(rpcErrorCode(error) == -32600) }
}

@Test("wire decoding rejects invalid UTF8 trailing tokens and over-depth input")
func rpcWireIDBoundsAndEncoding() {
    for bytes in [Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]), Data("{} false".utf8),
        Data(("{\"params\":" + String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130) + "}").utf8)] {
        #expect(throws: RPCError.self) { try RPCWireObject.decode(bytes) }
    }
}

// This exercises the actual request/response APIs, not just the token helper. The old
// Foundation Decodable/Encodable route changed the large ID before a handler could echo it.
@Test("RPC request and response APIs echo the original exact integer ID", arguments: [
    "9007199254740993", "-9007199254740993", "1e1000", "100e-2", "-0e-999999999999999999"
])
func rpcWireIDRequestResponseRoundTrip(token: String) throws {
    let request = try RPCRequest.decode(Data("{\"jsonrpc\":\"2.0\",\"method\":\"fixture\",\"id\":\(token)}".utf8))
    let id = try #require(request.id)
    let success = try RPCResponse.success(id: id, result: .null).serialized()
    #expect(success == Data("{\"jsonrpc\":\"2.0\",\"id\":\(token),\"result\":null}".utf8))
    let failure = try RPCResponse.failure(id: id, error: RPCError(code: -32022, message: "fixture", data: .null)).serialized()
    #expect(String(decoding: failure, as: UTF8.self).contains("\"id\":\(token),"))
    #expect(try RPCWireObject.decode(failure).id == id)
    #expect(!request.isNotification)
}

@Test("raw request fractions are refused and response omission remains distinct from null")
func rpcWireIDRequestValidationAndUnidentifiedError() throws {
    #expect(throws: RPCError.self) {
        try RPCRequest.decode(Data(#"{"jsonrpc":"2.0","method":"fixture","id":1.0000000000000001}"#.utf8))
    }
    #expect(throws: RPCError.self) {
        try RPCRequest.decode(Data(#"{"jsonrpc":"2.0","method":"fixture","id":null}"#.utf8))
    }
    let error = RPCError(code: -32600, message: "fixture")
    // Deliberately unidentified transport errors use the generic codec. An ordinary response
    // builder always requires explicit identity, with .null for a legacy unknown-ID error.
    let omitted = try RPCWireObject.decode(RPCWireObject.encode(id: nil,
        fields: ["error": .object(["code": .int(-32600), "message": .string("fixture")])]))
    let null = try RPCWireObject.decode(RPCResponse.failure(id: .null, error: error).serialized())
    #expect(omitted.id == nil)
    #expect(null.id == .null)
    #expect(try RPCRequest.decode(Data(#"{"jsonrpc":"2.0","method":"fixture"}"#.utf8)).isNotification)
    let integer = Int.max - 1
    let encoded = try RPCWireObject.encode(id: .int(integer), fields: ["method": .string("fixture")])
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"id\":\(integer),"))
    let wideCode = try RPCResponse.failure(id: .int(1), error: RPCError(code: integer, message: "fixture")).serialized()
    #expect(String(decoding: wideCode, as: UTF8.self).contains("\"code\":\(integer)"))
}

// The old stdio matcher compared rounded Double IDs; the first reply below stole request1.
@Test("stdio ignores a rounded fractional ID and waits for its exact reply")
func rpcWireIDStdioCorrelation() async throws {
    let wrong = #"{"jsonrpc":"2.0","id":1.0000000000000001,"result":"wrong"}"#
    let right = #"{"jsonrpc":"2.0","id":1e0,"result":"right"}"#
    let transport = try StdioTransport(command: "/bin/sh", arguments: ["-c",
        #"IFS= read -r request; printf '%s\n' "$1" "$2""#, "fixture", wrong, right], environment: ["PATH": "/usr/bin:/bin"])
    do {
        let result = try await transport.request("fixture", timeout: 3)
        await transport.shutdown()
        #expect(result == .string("right"))
    } catch { await transport.shutdown(); throw error }
}
