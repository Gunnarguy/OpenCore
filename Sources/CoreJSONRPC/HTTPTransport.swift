import CoreTelemetry
import Foundation

/// MCP over streamable HTTP.
///
/// One `POST` per outgoing message. The server may answer in either of two ways and the spec
/// allows it to choose per request, so both are handled:
///
/// - `application/json` — a single JSON-RPC response in the body.
/// - `text/event-stream` — an SSE stream that may carry notifications and progress before the
///   response we are waiting for. Read until the id matches, then stop.
///
/// Legacy sessions are captured only from a complete successful initialize reply. Modern-era
/// header/metadata selection is handled separately during the full protocol migration.
public actor HTTPTransport: MCPTransport {
    private let endpoint: URL
    private let session: URLSession
    private var accessToken: String?
    private var sessionID: String?
    private var nextID = 1
    private let limits: HTTPReadLimits
    private let ownsSession: Bool
    private var closed = false
    private var initializing = false
    private var active: [UUID: HTTPRequestExecution] = [:]

    public init(endpoint: URL, accessToken: String? = nil) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        limits = .standard
        ownsSession = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "opencore/0.3.0"]
        self.session = URLSession(configuration: configuration)
    }

    /// Fixture sessions never fall back to production networking and remain caller-owned.
    init(endpoint: URL, accessToken: String? = nil, session: URLSession, limits: HTTPReadLimits = .standard) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        self.session = session
        self.limits = limits
        ownsSession = false
    }

    /// Swap the bearer token in place, so a refresh does not require rebuilding the client
    /// and losing the negotiated session id.
    public func setAccessToken(_ token: String?) {
        accessToken = token
    }

    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw HTTPTransportError.closed }
        guard method != "initialize" || !initializing else {
            throw HTTPTransportError.malformed("initialize is already in progress")
        }
        let execution = try HTTPRequestExecution(method: method, timeout: timeout)
        // Actor reentrancy must not let an older initializer overwrite a newer session.
        if method == "initialize" { initializing = true }
        defer { if method == "initialize" { initializing = false } }
        guard nextID < Int.max else { throw HTTPTransportError.malformed("request id space exhausted") }
        let id = nextID
        nextID += 1

        var message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { message["params"] = params }
        let payload = JSONValue.object(message)
        let token = UUID()
        active[token] = execution
        defer { active[token] = nil }
        let endpoint = self.endpoint, session = self.session, accessToken = self.accessToken, sessionID = self.sessionID, limits = self.limits

        // The method name only. Params can carry a page id, a search string, or anything else
        // the user's own data put there, and telemetry is written to a file the user may hand
        // to someone else.
        let reply: HTTPTransferResult = try await Telemetry.span("rpc \(method)", .http, attributes: ["id": String(id)]) { scope in
            let reply = try await execution.value { owner in
                try await Self.transfer(payload, endpoint: endpoint, session: session, accessToken: accessToken,
                    sessionID: sessionID, id: id, timeout: timeout, limits: limits, owner: owner)
            }
            try Task.checkCancellation()
            guard let envelope = reply.envelope else {
                throw HTTPTransportError.malformed("no response to '\(method)'")
            }
            if let error = Self.remoteError(in: envelope) {
                scope.attribute("rpcError", String(rpcErrorCode(error) ?? -1))
                if !(200..<300).contains(reply.statusCode), let rpc = rpcError(error) {
                    throw HTTPTransportError.remoteHTTP(status: reply.statusCode, error: rpc)
                }
                throw error
            }
            return reply
        }
        try Task.checkCancellation()
        guard !closed else { throw HTTPTransportError.closed }
        if method == "initialize", let returned = reply.sessionID { self.sessionID = returned }
        return reply.envelope?["result"] ?? .null
    }

    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        try Task.checkCancellation()
        guard !closed else { throw HTTPTransportError.closed }
        let execution = try HTTPRequestExecution(method: method, timeout: 15)
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        // A notification has no id, so a compliant server replies 202 with no body. Nothing to
        // wait for and nothing to parse.
        let payload = JSONValue.object(message)
        let token = UUID()
        active[token] = execution
        defer { active[token] = nil }
        let endpoint = self.endpoint, session = self.session, accessToken = self.accessToken, sessionID = self.sessionID, limits = self.limits
        let reply = try await execution.value { owner in
            try await Self.transfer(payload, endpoint: endpoint, session: session, accessToken: accessToken,
                sessionID: sessionID, id: nil, timeout: 15, limits: limits, owner: owner)
        }
        try Task.checkCancellation()
        guard !closed else { throw HTTPTransportError.closed }
        if let envelope = reply.envelope, let error = RPCError.remoteError(in: envelope) {
            throw HTTPTransportError.remoteHTTP(status: reply.statusCode, error: error)
        }
    }

    public func shutdown() {
        closed = true
        for execution in active.values { execution.cancel() }
        if ownsSession { session.invalidateAndCancel() }
    }

    /// Nothing to report. HTTP has no second channel, and returning the response body here
    /// would be inventing a stderr that does not exist.
    public func stderrOutput() -> String { "" }

    // MARK: - The one request path

    private static func transfer(
        _ message: JSONValue,
        endpoint: URL, session: URLSession, accessToken: String?, sessionID: String?, id: Int?,
        timeout: TimeInterval, limits: HTTPReadLimits, owner: HTTPRequestExecution
    ) async throws -> HTTPTransferResult {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        guard let fields = message.objectValue else { throw HTTPTransportError.malformed("outgoing request was not an object") }
        request.httpBody = try RPCWireObject.encode(id: id.map { .int($0) }, fields: fields)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, because the server picks. Offering only one is how a client ends up unable to
        // read a perfectly valid reply.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        try Task.checkCancellation()
        let (stream, response) = try await session.bytes(for: request, delegate: owner)
        owner.register(stream.task)
        defer { stream.task.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.malformed("no HTTP response")
        }

        guard http.statusCode != 401 else {
            throw HTTPTransportError.unauthorized(resourceMetadata: Self.resourceMetadataURL(from: http))
        }
        // Authorization refusals must never become protocol-era evidence.
        guard http.statusCode != 403 else { throw HTTPTransportError.httpStatus(403, body: "") }
        if id == nil, (200..<300).contains(http.statusCode) {
            guard http.statusCode == 202 else {
                throw HTTPTransportError.malformed("notification was not accepted with HTTP 202")
            }
            return HTTPTransferResult(envelope: nil, statusCode: http.statusCode, sessionID: nil)
        }
        var decoder = try HTTPResponseDecoder(status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", id: id, limits: limits)
        let returned = http.value(forHTTPHeaderField: "Mcp-Session-Id").flatMap { $0.isEmpty ? nil : $0 }
        for try await byte in stream {
            try Task.checkCancellation()
            if let envelope = try decoder.append(byte) {
                return HTTPTransferResult(envelope: envelope, statusCode: http.statusCode, sessionID: returned)
            }
        }
        try Task.checkCancellation()
        return HTTPTransferResult(envelope: try decoder.finish(), statusCode: http.statusCode, sessionID: returned)
    }

    // MARK: - Details

    /// Shared by the recognized JSON and SSE response paths; no network or logging here.
    static func remoteError(in envelope: JSONValue) -> HTTPTransportError? {
        guard let error = RPCError.remoteError(in: envelope) else { return nil }
        return .remote(code: error.code, message: error.message, data: error.data)
    }

    static let protocolVersion = "2025-11-25"

    /// Pull the `resource_metadata` URL out of a `WWW-Authenticate` challenge.
    ///
    /// Format is `Bearer resource_metadata="https://.../.well-known/oauth-protected-resource"`.
    /// This is the documented bootstrap: a client with no token learns where to authenticate
    /// by being refused once.
    static func resourceMetadataURL(from response: HTTPURLResponse) -> URL? {
        guard let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let range = challenge.range(of: "resource_metadata=")
        else { return nil }
        let tail = challenge[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let unquoted = tail.hasPrefix("\"")
            ? String(tail.dropFirst().prefix(while: { $0 != "\"" }))
            : String(tail.prefix(while: { $0 != "," && $0 != " " }))
        return URL(string: unquoted)
    }
}
