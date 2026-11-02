import Foundation

struct HTTPReadLimits: Sendable {
    let maximumBytes: Int
    let diagnosticBytes: Int
    // Chosen application budgets, not protocol maxima or measured memory/peer limits.
    static let standard = HTTPReadLimits(maximumBytes: 8 * 1024 * 1024, diagnosticBytes: 400)
}

/// Incremental bounded UTF-8/SSE framing. It never hands a partial event to JSON decoding.
struct HTTPResponseDecoder {
    private let status: Int
    private let id: Int?
    private let limits: HTTPReadLimits
    private let sse: Bool
    private var count = 0
    private var body = Data()
    private var line = Data()
    private var event = Data()
    private var skipLF = false
    private var firstLine = true

    init(status: Int, contentType: String, id: Int?, limits: HTTPReadLimits) throws {
        self.status = status
        self.id = id
        self.limits = limits
        let type = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        sse = type == "text/event-stream"
        guard !(200..<300).contains(status) || type == "application/json" || sse else {
            throw HTTPTransportError.malformed("expected application/json or text/event-stream")
        }
    }

    mutating func append(_ byte: UInt8) throws -> JSONValue? {
        guard count < limits.maximumBytes else { throw HTTPTransportError.responseTooLarge(limit: limits.maximumBytes) }
        count += 1
        guard sse else { body.append(byte); return nil }
        if skipLF { skipLF = false; if byte == 0x0A { return nil } }
        if byte == 0x0D || byte == 0x0A {
            skipLF = byte == 0x0D
            return try consumeLine()
        }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> JSONValue {
        guard !sse else {
            // SSE dispatch requires a blank line. EOF must not invent a completed event.
            throw HTTPTransportError.malformed("stream ended before a complete response")
        }
        if !(200..<300).contains(status) {
            guard let envelope = try? decodeObject(body),
                  try isErrorEnvelope(envelope) else {
                throw HTTPTransportError.httpStatus(status,
                    body: String(decoding: body.prefix(max(0, limits.diagnosticBytes)), as: UTF8.self))
            }
            try correlate(envelope, allowUnidentifiedError: true)
            return envelope.value
        }
        let envelope = try decodeObject(body)
        guard try validate(envelope, notificationsAllowed: false) else {
            throw HTTPTransportError.malformed("expected a response")
        }
        return envelope.value
    }

    private mutating func consumeLine() throws -> JSONValue? {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(data: line, encoding: .utf8) else {
            throw HTTPTransportError.malformed("event stream was not UTF-8")
        }
        if text.isEmpty {
            guard !event.isEmpty else { return nil }
            event.removeLast() // SSE joins data fields with LF, removing its final LF on dispatch.
            let payload = event
            event.removeAll(keepingCapacity: true)
            let envelope = try decodeObject(payload)
            return try validate(envelope, notificationsAllowed: true) ? envelope.value : nil
        }
        guard !text.hasPrefix(":") else { return nil }
        let fields = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.first == "data" else { return nil }
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        event.append(contentsOf: value.utf8)
        event.append(0x0A)
        return nil
    }

    private func decodeObject(_ data: Data) throws -> RPCWireObject {
        guard let value = try? RPCWireObject.decode(data) else {
            throw HTTPTransportError.malformed("response was not one valid UTF-8 RPC object")
        }
        return value
    }

    private func isErrorEnvelope(_ wire: RPCWireObject) throws -> Bool {
        let value = wire.value
        guard value["jsonrpc"] == .string("2.0"), value["method"] == nil,
              value["result"] == nil, let error = value["error"]?.objectValue else { return false }
        return error["code"]?.intValue != nil && error["message"]?.stringValue != nil
    }

    private func validate(_ wire: RPCWireObject, notificationsAllowed: Bool) throws -> Bool {
        let value = wire.value
        guard value["jsonrpc"] == .string("2.0") else {
            throw HTTPTransportError.malformed("response did not declare JSON-RPC 2.0")
        }
        if value["method"] != nil {
            guard notificationsAllowed, value["method"]?.stringValue != nil,
                  wire.id == nil, value["result"] == nil, value["error"] == nil else {
                throw HTTPTransportError.malformed("unexpected request or ambiguous notification")
            }
            return false
        }
        let hasResult = value["result"] != nil, hasError = value["error"] != nil
        guard hasResult != hasError else {
            throw HTTPTransportError.malformed("response must contain exactly one result or error")
        }
        if hasError, !(try isErrorEnvelope(wire)) {
            throw HTTPTransportError.malformed("response error was not a code/message object")
        }
        // Unidentified errors are transport failures only on failed HTTP exchanges, never success.
        try correlate(wire, allowUnidentifiedError: !(200..<300).contains(status) && hasError)
        if !(200..<300).contains(status), !hasError {
            throw HTTPTransportError.malformed("failed HTTP exchange contained a successful result")
        }
        return true
    }

    private func correlate(_ wire: RPCWireObject, allowUnidentifiedError: Bool) throws {
        if allowUnidentifiedError, wire.id == nil || wire.id == .null { return }
        guard let id, wire.id == .int(id) else {
            throw HTTPTransportError.malformed("response id did not match the request")
        }
    }
}
