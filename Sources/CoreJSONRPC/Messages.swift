import Foundation

/// Minimal JSON-RPC 2.0 types for MCP's stdio transport.
///
/// Hand-rolled rather than pulled from the official Swift SDK, to keep the package's
/// zero-dependency guarantee. The stdio transport is newline-delimited JSON-RPC and the
/// surface OpenCore needs is five methods, so the SDK would cost a dependency and a
/// version-pinning surface to save a few hundred lines.
public enum JSONValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognised JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Accessors

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    /// nil unless the number is a whole value an `Int` can hold.
    ///
    /// `Int(value)` traps on anything else, and this reads numbers from outside the process:
    /// `limit: 1e300` from an MCP caller, or `id: 1e300` from a server during a sync, ended the
    /// whole process rather than failing the one request.
    public var intValue: Int? { if case .number(let value) = self { return Int(exactly: value) }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    // MARK: - Builders

    public static func string(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    public static func double(_ value: Double?) -> JSONValue { value.map { .number($0) } ?? .null }

    /// Parse one JSON value from text, including bare fragments like `3` or `"a"`.
    ///
    /// Wraps the text in an array before decoding because top-level fragment support in
    /// `JSONDecoder` has varied across platform versions, and this parser has to behave the
    /// same everywhere it runs. The `count == 1` guard is what stops `1,2` from silently
    /// parsing as its first element.
    public static func parse(_ text: String) throws -> JSONValue {
        let values = try JSONDecoder().decode([JSONValue].self, from: Data("[\(text)]".utf8))
        guard values.count == 1, let only = values.first else {
            throw ParseError.notASingleValue(text)
        }
        return only
    }

    public enum ParseError: Error, CustomStringConvertible {
        case notASingleValue(String)

        public var description: String {
            switch self {
            case .notASingleValue(let text): "expected exactly one JSON value, got '\(text)'"
            }
        }
    }
}

public struct RPCRequest: Sendable {
    public let jsonrpc: String
    public let id: RPCID?
    public let method: String
    public let params: JSONValue?

    /// Decode the original wire bytes. A Foundation Decodable route would lose numeric IDs
    /// before validation, so this is the only inbound request constructor.
    public static func decode(_ data: Data) throws -> Self {
        let wire = try RPCWireObject.decode(data)
        guard wire.fields["jsonrpc"] == .string("2.0"),
              let method = wire.fields["method"]?.stringValue else {
            throw RPCError(code: -32600, message: "Invalid MCP request envelope")
        }
        guard wire.id != .null else { throw RPCError(code: -32600, message: "Invalid MCP request id") }
        if let params = wire.fields["params"], params.objectValue == nil {
            throw RPCError(code: -32600, message: "Invalid MCP request params")
        }
        return .init(jsonrpc: "2.0", id: wire.id, method: method, params: wire.fields["params"])
    }

    /// Only a valid request whose ID is absent is a notification.
    public var isNotification: Bool { id == nil }
}

public struct RPCError: Error, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
    public let code: Int
    public let message: String
    /// Protocol data is available to negotiation logic, never automatically to logs/descriptions.
    /// nil means omitted; .some(.null) preserves an explicit JSON null.
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = container.contains(.data) ? try container.decode(JSONValue.self, forKey: .data) : nil
    }

    public var description: String { "JSON-RPC error \(code): \(message)" }
    public var debugDescription: String { description }
    public var errorDescription: String? { description }

    /// Common mapping for recognized transport error envelopes. Keep existing code/message
    /// fallbacks; response validation belongs to the transport rather than this value mapper.
    static func remoteError(in envelope: JSONValue) -> RPCError? {
        guard let error = envelope["error"] else { return nil }
        return RPCError(code: error["code"]?.intValue ?? -1,
                        message: error["message"]?.stringValue ?? "unknown", data: error["data"])
    }

    private enum CodingKeys: String, CodingKey { case code, message, data }

    public static func methodNotFound(_ method: String) -> RPCError { RPCError(code: -32601, message: "method not found: \(method)") }
    public static func invalidParams(_ detail: String) -> RPCError { RPCError(code: -32602, message: "invalid params: \(detail)") }
    public static func internalError(_ detail: String) -> RPCError { RPCError(code: -32603, message: "internal error: \(detail)") }
}

public struct RPCResponse: Sendable {
    public let jsonrpc = "2.0"
    public let id: RPCID
    public let result: JSONValue?
    public let error: ErrorBody?

    public struct ErrorBody: Encodable, Sendable {
        public let code: Int
        public let message: String
        public let data: JSONValue?
    }

    public static func success(id: RPCID, result: JSONValue) -> RPCResponse {
        RPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: RPCID, error: RPCError) -> RPCResponse {
        RPCResponse(id: id, result: nil, error: ErrorBody(code: error.code, message: error.message, data: error.data))
    }

    /// ID tokens have already passed the strict codec. Everything else is JSONEncoder-escaped.
    /// Encoding directly through Foundation would round arbitrary numeric ID tokens.
    public func serialized() throws -> Data {
        var bytes = Data("{\"jsonrpc\":\"2.0\"".utf8)
        bytes.append(contentsOf: ",\"id\":".utf8); bytes.append(try id.encoded())
        if let result { bytes.append(contentsOf: ",\"result\":".utf8); bytes.append(try JSONEncoder().encode(result)) }
        if let error { bytes.append(contentsOf: ",\"error\":".utf8); bytes.append(try JSONEncoder().encode(error)) }
        bytes.append(0x7D)
        guard bytes.count <= RPCWireObject.maximumBytes else {
            throw RPCError(code: -32603, message: "RPC response exceeded the chosen byte budget")
        }
        return bytes
    }
}
