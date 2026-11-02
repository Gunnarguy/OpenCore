import Foundation

/// The owner channel is deliberately separate from JSON-RPC and MCP. No write operation
/// exists in this first protocol. The phone imports this target, never the store or engine.
public enum CompanionSection: String, Codable, Sendable, CaseIterable, Identifiable {
    case home, chat, passages, graph, claims, beliefs, realityChecks, receipts, timeline, timeTravel, sources, corpus
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
        case .chat: "Grounded Chat"
        case .passages: "Passages"
        case .graph: "Knowledge Graph"
        case .claims: "Claims"
        case .beliefs: "Beliefs"
        case .realityChecks: "Reality Checks"
        case .receipts: "Receipts"
        case .timeline: "Timeline"
        case .timeTravel: "Time Travel"
        case .sources: "Sources"
        case .corpus: "Corpus"
        }
    }
    public var symbol: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left.and.text.bubble.right"
        case .passages: "text.quote"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .claims: "checkmark.seal"
        case .beliefs: "brain.head.profile"
        case .realityChecks: "arrow.triangle.branch"
        case .receipts: "receipt"
        case .timeline: "clock"
        case .timeTravel: "clock.arrow.circlepath"
        case .sources: "tray.full"
        case .corpus: "books.vertical"
        }
    }
}

public struct CompanionField: Codable, Sendable, Hashable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct CompanionRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var identityBytes: Data { Data(id.utf8) }
    public var title: String
    public var body: String
    public var domain: String?
    public var date: Date?
    public var fields: [CompanionField]
    public var objectID: String?
    public var links: [CompanionRecordLink]
    public init(id: String, title: String, body: String = "", domain: String? = nil, date: Date? = nil,
                fields: [CompanionField] = [], objectID: String? = nil, links: [CompanionRecordLink] = []) {
        self.id = id; self.title = title; self.body = body; self.domain = domain; self.date = date
        self.fields = fields; self.objectID = objectID
        self.links = links
    }

    public static func appendingDistinct(_ incoming: [Self], to existing: [Self]) -> [Self] {
        var seen = Set(existing.map(\.identityBytes))
        return existing + incoming.filter { seen.insert($0.identityBytes).inserted }
    }
}

public struct CompanionRecordLink: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case object, entity, claim, receipt }
    // ASCII encoding keeps SwiftUI identity byte-exact even when target IDs are canonically equivalent.
    public var id: String {
        kind.rawValue + ":" + Data(targetID.utf8).base64EncodedString()
    }
    public var kind: Kind
    public var targetID: String
    public var title: String
    public init(_ kind: Kind, _ targetID: String, _ title: String) { self.kind = kind; self.targetID = targetID; self.title = title }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.targetID.utf8.elementsEqual(rhs.targetID.utf8) && lhs.title.utf8.elementsEqual(rhs.title.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(Data(targetID.utf8))
        hasher.combine(Data(title.utf8))
    }
}

public enum CompanionAnswerMode: String, Codable, Sendable, CaseIterable { case chat, evidence }
public enum CompanionChatHistoryAction: String, Codable, Sendable { case list, open }

public struct CompanionPage: Codable, Sendable {
    public var title: String
    public var note: String
    public var records: [CompanionRecord]
    public var metrics: [CompanionField]
    public var nextOffset: Int?
    public var generatedAt: Date
    public var receiptID: String?
    /// Present only when the Mac understands saved-chat history and the indicated version.
    public var chatHistoryVersion: Int?
    public var chatThreadID: UUID?
    /// A list is also the capability probe; a thread marker there is ambiguous.
    public var supportsChatHistoryList: Bool { chatHistoryVersion == 1 && chatThreadID == nil }
    public func matchesChatHistory(thread: UUID) -> Bool {
        chatHistoryVersion == 1 && chatThreadID == thread
    }
    public init(title: String, note: String = "", records: [CompanionRecord] = [], metrics: [CompanionField] = [],
                nextOffset: Int? = nil, generatedAt: Date = Date(), receiptID: String? = nil,
                chatHistoryVersion: Int? = nil, chatThreadID: UUID? = nil) {
        self.title = title; self.note = note; self.records = records; self.metrics = metrics
        self.nextOffset = nextOffset; self.generatedAt = generatedAt; self.receiptID = receiptID
        self.chatHistoryVersion = chatHistoryVersion; self.chatThreadID = chatThreadID
    }
}

public struct CompanionRequest: Codable, Sendable {
    public var id: UUID
    public var section: CompanionSection
    public var query: String
    public var recordID: String?
    public var domain: String?
    public var asOf: Date?
    public var offset: Int
    public var answerMode: CompanionAnswerMode
    public var resumeID: UUID?
    public var chatHistoryAction: CompanionChatHistoryAction?
    public var chatThreadID: UUID?
    public init(section: CompanionSection, query: String = "", recordID: String? = nil,
                domain: String? = nil, asOf: Date? = nil, offset: Int = 0, answerMode: CompanionAnswerMode = .chat, resumeID: UUID? = nil,
                chatHistoryAction: CompanionChatHistoryAction? = nil, chatThreadID: UUID? = nil) {
        id = UUID(); self.section = section; self.query = query; self.recordID = recordID
        self.domain = domain; self.asOf = asOf; self.offset = offset
        self.answerMode = answerMode
        self.resumeID = resumeID
        self.chatHistoryAction = chatHistoryAction; self.chatThreadID = chatThreadID
    }
}

public enum CompanionResponsePhase: String, Codable, Sendable { case progress, prepared, committed }

public struct CompanionResponse: Codable, Sendable {
    public var requestID: UUID
    public var page: CompanionPage?
    public var error: String?
    public var phase: CompanionResponsePhase
    public init(requestID: UUID, page: CompanionPage? = nil, error: String? = nil, phase: CompanionResponsePhase = .prepared) {
        self.requestID = requestID; self.page = page; self.error = error
        self.phase = phase
    }
}

public struct CompanionInvitation: Codable, Sendable {
    public var version: Int = 1
    public var host: String
    public var port: UInt16
    public var hostPublicKey: Data
    public var code: String
    public var expiresAt: Date
    public init(host: String, port: UInt16, hostPublicKey: Data, code: String, expiresAt: Date) {
        self.host = host; self.port = port; self.hostPublicKey = hostPublicKey; self.code = code; self.expiresAt = expiresAt
    }
    public func encoded() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }
    public static func decode(_ text: String) throws -> Self {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count < 4096 else { throw CompanionError.invalidInvitation }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.port > 0, CompanionEndpoint.isTailnetAddress(value.host),
              value.hostPublicKey.count == 65, value.code.count == 64 else { throw CompanionError.invalidInvitation }
        return value
    }
}

public enum CompanionError: String, Error, LocalizedError, Sendable {
    case invalidInvitation = "This pairing code is invalid. Generate a fresh code on the Mac."
    case unauthorized = "This device is not authorized. Pair again on the Mac."
    case expired = "This session or pairing code expired. Unlock and connect again."
    case invalidFrame = "The companion connection could not be verified."
    case tooLarge = "This response exceeds the transfer limit. Narrow the search or open the next page."
    case disconnected = "The Mac is unreachable. It may be asleep, OpenCore may be closed, or Tailscale may need to sign in again."
    case busy = "Another request is running. Try again when it finishes."
    case resumeUnavailable = "That read cannot be resumed. Start the read again."
    public var errorDescription: String? { rawValue }
}

public enum CompanionEndpoint {
    /// Only literal tailnet IPv4 addresses. No DNS resolution, LAN binding, wildcards or
    /// subnet-router destinations are accepted by the owner listener.
    public static func isTailnetAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil && String(UInt8($0)!) == $0 }) else { return false }
        return UInt8(parts[0]) == 100 && (64...127).contains(Int(parts[1]) ?? -1)
    }
}
