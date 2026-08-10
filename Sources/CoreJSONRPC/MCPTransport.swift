import Foundation

/// What `MCPClient` needs from a pipe, and nothing more.
///
/// This exists so a second transport can be added without the protocol logic knowing. MCP
/// began as stdio only, which is why `StdioTransport` was concrete; the ecosystem has since
/// moved to hosted servers speaking streamable HTTP with OAuth, and a client that can only
/// spawn a subprocess reaches a minority of it.
///
/// The requirements are `async` even though `StdioTransport` satisfies several of them with
/// synchronous methods. An actor's isolated methods satisfy `async` requirements, so both
/// transports conform without either being reshaped to suit the other.
public protocol MCPTransport: Sendable {
    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue?) async throws
    func shutdown() async
    /// Diagnostic output, when the transport has any. Empty for transports that do not.
    func stderrOutput() async -> String
}

/// Default arguments, which a protocol requirement cannot declare. Kept here so call sites
/// read the same whether they hold a concrete transport or an existential.
extension MCPTransport {
    public func request(_ method: String, timeout: TimeInterval = 30) async throws -> JSONValue {
        try await request(method, params: nil, timeout: timeout)
    }

    public func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        try await request(method, params: params, timeout: 30)
    }

    public func notify(_ method: String) async throws {
        try await notify(method, params: nil)
    }
}

extension StdioTransport: MCPTransport {}

/// Failures that only a network transport can have.
///
/// Deliberately separate from `StdioTransport.TransportError` rather than merged into it: a
/// subprocess cannot be rate limited and a URL cannot exit with a signal, and one enum
/// carrying both would have half its cases uninhabitable at any given moment.
public enum HTTPTransportError: Error, CustomStringConvertible {
    /// The server demands authorization. `resourceMetadata` is the URL from the
    /// `WWW-Authenticate` header, which is how the MCP authorization spec bootstraps
    /// discovery: an unauthenticated request is the documented way to find out where to
    /// authenticate.
    case unauthorized(resourceMetadata: URL?)
    case httpStatus(Int, body: String)
    case malformed(String)
    case timedOut(method: String, seconds: TimeInterval)
    case remote(code: Int, message: String)

    public var description: String {
        switch self {
        case .unauthorized(let url):
            "server requires authorization\(url.map { " (metadata at \($0.absoluteString))" } ?? "")"
        case .httpStatus(let code, let body):
            "server returned HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(300))")"
        case .malformed(let detail): "malformed response: \(detail)"
        case .timedOut(let method, let seconds): "'\(method)' did not respond within \(Int(seconds))s"
        case .remote(let code, let message): "server returned error \(code): \(message)"
        }
    }
}

/// The JSON-RPC error code from either transport's error type.
///
/// `MCPClient` probes for `-32601` (method not found) to tell a `2025-11-25` server from a
/// stateless `2026-07-28` one. That probe has to work the same over both transports, and
/// pattern-matching two unrelated enums at the call site is how it would silently stop
/// working over the newer one.
public func rpcErrorCode(_ error: any Error) -> Int? {
    if case StdioTransport.TransportError.remote(let code, _) = error { return code }
    if case HTTPTransportError.remote(let code, _) = error { return code }
    return nil
}
