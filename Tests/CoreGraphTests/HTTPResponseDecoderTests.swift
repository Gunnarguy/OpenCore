import Foundation
import Testing
@testable import CoreJSONRPC

private func decodeHTTP(_ bytes: Data, status: Int = 200, type: String = "application/json",
                        maximum: Int = 4096) throws -> JSONValue {
    var decoder = try HTTPResponseDecoder(status: status, contentType: type, id: 1,
        limits: .init(maximumBytes: maximum, diagnosticBytes: 7))
    for byte in bytes { if let value = try decoder.append(byte) { return value } }
    return try decoder.finish()
}
private func jsonHTTP(_ object: [String: JSONValue]) throws -> Data {
    try JSONEncoder().encode(JSONValue.object(object))
}
private let decoderResult: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .int(1), "result": .null]
private let decoderError: JSONValue = .object(["code": .int(-32022), "message": .string("fixture"), "data": .null])

@Test("HTTP response IDs and JSON-RPC envelope shape are validated", arguments: Array(0..<11))
func httpDecoderRejectsMalformedEnvelope(variant: Int) throws {
    var value = decoderResult
    switch variant {
    case 0: value["id"] = .int(2)
    case 1: value["id"] = nil
    case 2: value["id"] = .null
    case 3: value["id"] = .string("1")
    case 4: value["jsonrpc"] = .string("1.0")
    case 5: value["error"] = decoderError
    case 6: value["result"] = nil
    case 7: value["result"] = nil; value["error"] = .string("fixture")
    case 8: value["result"] = nil; value["error"] = .object(["code": .number(1.5), "message": .string("fixture")])
    case 9: value["result"] = nil; value["error"] = .object(["code": .int(-1), "message": .int(4)])
    default: value["method"] = .string("server/request")
    }
    let bytes = try jsonHTTP(value)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(bytes) }
    let stream = Data("data: \(String(decoding: bytes, as: UTF8.self))\n\n".utf8)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(stream, type: "text/event-stream") }
}

@Test("unidentified errors are accepted only on failed HTTP exchanges", arguments: [false, true])
func httpDecoderUnidentifiedFailure(nullID: Bool) throws {
    var value: [String: JSONValue] = ["jsonrpc": .string("2.0"), "error": decoderError]
    if nullID { value["id"] = .null }
    let bytes = try jsonHTTP(value)
    #expect(try decodeHTTP(bytes, status: 400)["error"] == decoderError)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(bytes) }
    value["id"] = .int(2)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(try jsonHTTP(value), status: 400) }
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(try jsonHTTP(decoderResult), status: 400) }
}

// The bug: the old loop parsed each data line as a response rather than framing an SSE event.
@Test("SSE frames multiline JSON with BOM comments notifications and all line endings", arguments: ["\n", "\r", "\r\n"])
func httpDecoderSSEFraming(newline: String) throws {
    let lines = ["\u{FEFF}: fixture comment", "event: ignored", "id: ignored", "retry: 5", "",
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/fixture\"}", "",
        "data: {", "data: \"jsonrpc\":\"2.0\",", "data:\"id\":1,", "data: \"result\":\"fixture ✓\"}", "", ""]
    let bytes = Data(lines.joined(separator: newline).utf8)
    #expect(try decodeHTTP(bytes, type: "Text/Event-Stream; charset=utf-8")["result"] == .string("fixture ✓"))
}

@Test("SSE does not dispatch a complete JSON data line until the event's blank line")
func httpDecoderSSEWaitsForBlankLine() throws {
    var decoder = try HTTPResponseDecoder(status: 200, contentType: "text/event-stream", id: 1, limits: .standard)
    let json = String(decoding: try jsonHTTP(decoderResult), as: UTF8.self)
    for byte in "data: \(json)\n".utf8 { #expect(try decoder.append(byte) == nil) }
    #expect(throws: HTTPTransportError.self) { try decoder.finish() }
    #expect(try decoder.append(0x0A)?["result"] == .null)
}

@Test("incomplete SSE EOF and invalid UTF-8 cannot produce a response", arguments: Array(0..<6))
func httpDecoderSSERejectsPrematureOrInvalid(variant: Int) throws {
    let json = String(decoding: try jsonHTTP(decoderResult), as: UTF8.self)
    let bytes: Data
    switch variant {
    case 0: bytes = Data("data: \(json)".utf8)
    case 1: bytes = Data("data: \(json)\n".utf8)
    case 2: bytes = Data("data: \(json)\r".utf8)
    case 3: bytes = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"server/request\",\"id\":8}\n\n".utf8)
    case 4: bytes = Data("DATA: \(json)\n\n".utf8) // Fields are case-sensitive.
    default: bytes = Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0x0A, 0x0A])
    }
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(bytes, type: "text/event-stream") }
}

@Test("HTTP JSON requires UTF-8 one object and a supported successful content type")
func httpDecoderJSONEncodingAndContentType() throws {
    let bytes = try jsonHTTP(decoderResult)
    #expect(try decodeHTTP(bytes, type: " Application/JSON; charset=utf-8 ")["result"] == .null)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(bytes, type: "text/plain") }
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(Data("[]".utf8)) }
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(bytes + bytes) }
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(Data([0xFF])) }
    let text = try #require(String(data: bytes, encoding: .utf8))
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(try #require(text.data(using: .utf16))) }
}

@Test("response byte cap accepts exactly its budget and rejects the next byte")
func httpDecoderExactByteBudget() throws {
    let bytes = try jsonHTTP(decoderResult)
    #expect(try decodeHTTP(bytes, maximum: bytes.count)["result"] == .null)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(bytes, maximum: bytes.count - 1) }
    let json = String(decoding: bytes, as: UTF8.self)
    let sse = Data("data: \(json)\n\n".utf8)
    #expect(try decodeHTTP(sse, type: "text/event-stream", maximum: sse.count)["result"] == .null)
    #expect(throws: HTTPTransportError.self) { try decodeHTTP(sse, type: "text/event-stream", maximum: sse.count - 1) }
}

@Test("unrecognized HTTP failure retains only a bounded diagnostic prefix and no automatic body logging")
func httpDecoderFailureDiagnosticBudget() throws {
    do {
        _ = try decodeHTTP(Data("fixture-private-body".utf8), status: 503, type: "text/plain")
        Issue.record("plain HTTP failure succeeded")
    } catch {
        guard case HTTPTransportError.httpStatus(let status, let body) = error else { Issue.record("lost HTTP status"); return }
        #expect(status == 503)
        #expect(body == "fixture")
        #expect(!String(reflecting: error).contains("fixture"))
    }
}
