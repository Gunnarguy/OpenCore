import Foundation

/// Minimal JSON-RPC 2.0 types for MCP's stdio transport.
///
/// Hand-rolled rather than pulled from the official Swift SDK, to keep the package's
/// zero-dependency guarantee. The stdio transport is newline-delimited JSON-RPC and the
/// surface OpenCore needs is five methods, so the SDK would cost a dependency and a
/// version-pinning surface to save a few hundred lines.
public enum JSONValue: Sendable, Codable, Equatable {
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
    public var intValue: Int? { if case .number(let value) = self { return Int(value) }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    // MARK: - Builders

    public static func string(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    public static func double(_ value: Double?) -> JSONValue { value.map { .number($0) } ?? .null }
}

public struct RPCRequest: Decodable, Sendable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    /// A request with no `id` is a notification: it gets no response, ever. Replying to
    /// one is a protocol violation that some clients treat as a fatal error.
    public var isNotification: Bool { id == nil }
}

public struct RPCError: Error, Sendable {
    public let code: Int
    public let message: String

    public static func methodNotFound(_ method: String) -> RPCError { RPCError(code: -32601, message: "method not found: \(method)") }
    public static func invalidParams(_ detail: String) -> RPCError { RPCError(code: -32602, message: "invalid params: \(detail)") }
    public static func internalError(_ detail: String) -> RPCError { RPCError(code: -32603, message: "internal error: \(detail)") }
}

public struct RPCResponse: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: JSONValue
    public var result: JSONValue?
    public var error: ErrorBody?

    public struct ErrorBody: Encodable, Sendable {
        public let code: Int
        public let message: String
    }

    public static func success(id: JSONValue, result: JSONValue) -> RPCResponse {
        RPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: JSONValue, error: RPCError) -> RPCResponse {
        RPCResponse(id: id, result: nil, error: ErrorBody(code: error.code, message: error.message))
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
}
