import Foundation

/// Coalesces a drag into its newest unsent value while preserving other controls.
public struct DisplayControlUpdateQueue: Sendable {
    public struct Update: Equatable, Sendable {
        public let id: UUID
        public let generation: UUID
        public let code: Int
        public let value: Int
    }
    private var generation = UUID()
    private var order: [Int] = []
    private var values: [Int: Update] = [:]
    public init() {}
    public var isEmpty: Bool { values.isEmpty }
    public func contains(_ code: Int) -> Bool { values[code] != nil }
    public func value(for code: Int) -> Int? { values[code]?.value }
    @discardableResult public mutating func enqueue(code: Int, value: Int) -> Update {
        let update = Update(id: UUID(), generation: generation, code: code, value: value)
        if values[code] == nil { order.append(code) }
        values[code] = update
        return update
    }
    public mutating func takeNext() -> Update? {
        guard !order.isEmpty else { return nil }
        return values.removeValue(forKey: order.removeFirst())
    }
    public func isCurrent(_ update: Update) -> Bool { update.generation == generation }
    public mutating func removeAll() { generation = UUID(); order.removeAll(); values.removeAll() }
}

public struct DisplayControlFeedback: Equatable, Sendable {
    public enum State: Equatable, Sendable { case queued, sending, verified, notApplied, unavailable }
    public let state: State
    public let message: String
    public init(_ state: State, _ message: String) { self.state = state; self.message = message }
    public static func readback(code: Int, requested: Int, actual: Int?) -> Self {
        guard let actual else { return .init(.unavailable, "Sent \(requested), but the monitor did not return a readable value. Completion is unverified.") }
        if code == 0xD6, !(1...4).contains(actual) {
            return .init(.unavailable, "Power query returned raw code \(actual), which is not a readable standard power state. Command completion is unverified.")
        }
        if actual == requested || (code == 0xD6 && requested == 5 && actual == 4) {
            return .init(.verified, "Monitor readback verified: \(actual).")
        }
        return .init(.notApplied, "Requested \(requested); monitor still reports \(actual). The change is not confirmed. A picture preset or monitor restriction may be overriding it.")
    }
}
