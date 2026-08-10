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
/// A `Mcp-Session-Id` header returned on the first response is echoed on every later request.
/// Stateless servers omit it and nothing is sent, which is exactly what they expect.
public actor HTTPTransport: MCPTransport {
    private let endpoint: URL
    private let session: URLSession
    private var accessToken: String?
    private var sessionID: String?
    private var nextID = 1

    public init(endpoint: URL, accessToken: String? = nil) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "opencore/0.3.0"]
        self.session = URLSession(configuration: configuration)
    }

    /// Swap the bearer token in place, so a refresh does not require rebuilding the client
    /// and losing the negotiated session id.
    public func setAccessToken(_ token: String?) {
        accessToken = token
    }

    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        let id = nextID
        nextID += 1

        var message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { message["params"] = params }

        // The method name only. Params can carry a page id, a search string, or anything else
        // the user's own data put there, and telemetry is written to a file the user may hand
        // to someone else.
        return try await Telemetry.span("rpc \(method)", .http, attributes: ["id": String(id)]) { scope in
            guard let envelope = try await post(.object(message), awaitingID: id, method: method, timeout: timeout) else {
                throw HTTPTransportError.malformed("no response to '\(method)'")
            }
            if let error = envelope["error"] {
                let code = error["code"]?.intValue ?? -1
                scope.attribute("rpcError", String(code))
                throw HTTPTransportError.remote(
                    code: code,
                    message: error["message"]?.stringValue ?? "unknown"
                )
            }
            return envelope["result"] ?? .null
        }
    }

    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        // A notification has no id, so a compliant server replies 202 with no body. Nothing to
        // wait for and nothing to parse.
        _ = try await post(.object(message), awaitingID: nil, method: method, timeout: 15)
    }

    public func shutdown() {
        session.invalidateAndCancel()
    }

    /// Nothing to report. HTTP has no second channel, and returning the response body here
    /// would be inventing a stderr that does not exist.
    public func stderrOutput() -> String { "" }

    // MARK: - The one request path

    private func post(
        _ message: JSONValue,
        awaitingID id: Int?,
        method: String,
        timeout: TimeInterval
    ) async throws -> JSONValue? {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, because the server picks. Offering only one is how a client ends up unable to
        // read a perfectly valid reply.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.malformed("no HTTP response")
        }

        if let returned = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !returned.isEmpty {
            sessionID = returned
        }

        guard http.statusCode != 401 else {
            throw HTTPTransportError.unauthorized(resourceMetadata: Self.resourceMetadataURL(from: http))
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in stream.lines where body.count < 400 { body += line }
            throw HTTPTransportError.httpStatus(http.statusCode, body: body)
        }
        guard let id else { return nil }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return contentType.contains("text/event-stream")
            ? try await readEventStream(stream, awaitingID: id, method: method, timeout: timeout)
            : try await readSingleJSON(stream, method: method)
    }

    private func readSingleJSON(
        _ stream: URLSession.AsyncBytes,
        method: String
    ) async throws -> JSONValue {
        var data = Data()
        for try await byte in stream { data.append(byte) }
        guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw HTTPTransportError.malformed("'\(method)' returned a body that is not JSON")
        }
        return envelope
    }

    /// Read SSE `data:` lines until one carries our id.
    ///
    /// Anything else on the stream is a notification or a response to a different request.
    /// Skipped rather than treated as an error, exactly as the stdio transport skips lines
    /// whose id does not match.
    private func readEventStream(
        _ stream: URLSession.AsyncBytes,
        awaitingID id: Int,
        method: String,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        for try await line in stream.lines {
            if Date() > deadline {
                throw HTTPTransportError.timedOut(method: method, seconds: timeout)
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }
            if envelope["id"]?.intValue == id { return envelope }
        }
        throw HTTPTransportError.malformed("stream ended before '\(method)' was answered")
    }

    // MARK: - Details

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
