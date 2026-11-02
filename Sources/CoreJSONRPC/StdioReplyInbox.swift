import Foundation

struct StdioReplyRegistration: Sendable, Equatable {
    let id: RPCID
    let token: UUID
    let receiptFloor: Int
    let deadline: Date
}

/// Value state protected by the line reader's mutex. Decode outside that mutex, then publish
/// only to an owner whose immutable receipt sequence/deadline still qualifies the frame.
struct StdioReplyInbox {
    // Chosen application budgets, not protocol maxima or measured memory guarantees.
    static let defaultMaximumRequests = 128
    static let defaultMaximumBytes = 16 * 1024 * 1024
    private struct Entry {
        let registration: StdioReplyRegistration
        var reply: RPCWireObject?
        var bytes = 0
        var consumed = false
    }
    private var entries: [RPCID: Entry] = [:]
    private(set) var bufferedBytes = 0
    private let maximumRequests: Int
    private let maximumBytes: Int

    init(maximumRequests: Int = defaultMaximumRequests, maximumBytes: Int = defaultMaximumBytes) {
        self.maximumRequests = maximumRequests; self.maximumBytes = maximumBytes
    }

    mutating func register(id: RPCID, receiptFloor: Int, deadline: Date) throws -> StdioReplyRegistration {
        guard id != .null, entries[id] == nil else { throw StdioTransport.TransportError.malformed("duplicate or null active request id") }
        guard entries.count < maximumRequests else { throw StdioTransport.TransportError.tooManyRequests }
        let registration = StdioReplyRegistration(id: id, token: UUID(), receiptFloor: receiptFloor, deadline: deadline)
        entries[id] = Entry(registration: registration)
        return registration
    }

    mutating func receive(_ wire: RPCWireObject, receipt: Int, receivedAt: Date, byteCount: Int) throws {
        guard let id = wire.id, var entry = entries[id], !entry.consumed, entry.reply == nil,
              receipt >= entry.registration.receiptFloor, receivedAt <= entry.registration.deadline else { return }
        guard byteCount >= 0, byteCount <= maximumBytes - bufferedBytes else {
            throw StdioTransport.TransportError.backlogLimit
        }
        entry.reply = wire; entry.bytes = byteCount
        bufferedBytes += byteCount; entries[id] = entry
    }

    func isRegistered(_ registration: StdioReplyRegistration) -> Bool {
        entries[registration.id]?.registration == registration
    }

    mutating func take(_ registration: StdioReplyRegistration) -> RPCWireObject? {
        guard var entry = entries[registration.id], entry.registration == registration,
              let reply = entry.reply else { return nil }
        // First reply wins, including while the caller resumes before unregistering.
        bufferedBytes -= entry.bytes; entry.bytes = 0; entry.reply = nil; entry.consumed = true
        entries[registration.id] = entry
        return reply
    }

    mutating func unregister(_ registration: StdioReplyRegistration) {
        guard let entry = entries[registration.id], entry.registration == registration else { return }
        bufferedBytes -= entry.bytes; entries[registration.id] = nil
    }

    mutating func clear() { entries.removeAll(); bufferedBytes = 0 }
}
