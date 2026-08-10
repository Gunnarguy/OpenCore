import Foundation
import Synchronization

/// Measurement of what the system actually did, as it did it.
///
/// This exists because OpenCore had exactly three `FileHandle.standardError.write` calls and a
/// `log: (String) -> Void` callback carrying prose. Prose cannot answer "where did the twelve
/// seconds go" or "how many rows did that query touch", so those questions were unanswerable
/// without a debugger.
///
/// ## Nesting comes from a task-local, not from a parameter
///
/// `currentSpanID` is a `@TaskLocal`, so a span opened inside another span becomes its child
/// with no argument threaded through the call chain. That is the only reason this can reach
/// into `CoreStore`'s query methods and `PassageSearch`'s legs without rewriting every
/// signature between here and there.
///
/// ## Nothing here can ever reach stdout
///
/// `opencore mcp` speaks JSON-RPC on stdout, and one stray line corrupts the stream in a way
/// that presents as a client hanging rather than as an error anyone can find. There is
/// deliberately **no stdout sink** and no option to add one: the constraint is enforced by the
/// type not existing, not by a rule someone has to remember.
///
/// ## Off by default
///
/// Disabled unless `OPENCORE_TELEMETRY` is set or `Telemetry.enable()` is called, and when
/// disabled `span` is a closure call plus one atomic load.
public enum Telemetry {

    // MARK: - Enablement

    /// An atomic rather than a plain `var` because spans open from whichever task is running,
    /// and Swift 6 will not let a mutable global be read across isolation domains.
    private static let enabled = Atomic<Bool>(ProcessInfo.processInfo.environment["OPENCORE_TELEMETRY"] != nil)

    public static var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    public static func enable() { enabled.store(true, ordering: .relaxed) }
    public static func disable() { enabled.store(false, ordering: .relaxed) }

    // MARK: - The open span

    /// The span a new span becomes a child of. Task-local, so it follows `async` calls into
    /// other modules and restores itself automatically when the scope ends.
    @TaskLocal public static var currentSpanID: UInt64?

    public static let recorder = TelemetryRecorder()

    // MARK: - Recording

    /// Run `body` as a measured span.
    ///
    /// The scope is handed to the body rather than having the body return counters, because
    /// the interesting counts are usually known partway through rather than at the return.
    ///
    /// `isolation: #isolation` makes this inherit the caller's actor. Without it, a span
    /// opened inside an actor (`Database`, `HTTPTransport`, every connector) fails Swift 6's
    /// region check, because the body would be a non-`Sendable` closure crossing an isolation
    /// boundary. Inheriting means it never crosses one.
    @discardableResult
    public static func span<T>(
        _ name: String,
        _ category: TelemetryCategory,
        attributes: [String: String] = [:],
        isolation: isolated (any Actor)? = #isolation,
        body: (TelemetryScope) async throws -> T
    ) async rethrows -> T {
        guard isEnabled else { return try await body(.disabled) }

        let scope = TelemetryScope(attributes: attributes)
        let id = recorder.openSync(category: category, name: name, parent: currentSpanID)

        do {
            let value = try await Telemetry.$currentSpanID.withValue(id) { try await body(scope) }
            recorder.closeSync(id: id, scope: scope, failure: nil)
            return value
        } catch {
            // A failed span is still a measurement, and usually the most interesting one.
            // Recording it before rethrowing is what makes a partial run readable.
            recorder.closeSync(id: id, scope: scope, failure: String(describing: error))
            throw error
        }
    }

    /// Synchronous variant, for paths that are not `async` at all.
    ///
    /// Records into the same tree. It cannot nest *async* children under itself, because the
    /// task-local binding ends with the closure, which is the correct behaviour rather than a
    /// limitation to work around.
    @discardableResult
    public static func spanSync<T>(
        _ name: String,
        _ category: TelemetryCategory,
        attributes: [String: String] = [:],
        body: (TelemetryScope) throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body(.disabled) }

        let scope = TelemetryScope(attributes: attributes)
        let id = recorder.openSync(category: category, name: name, parent: currentSpanID)

        do {
            let value = try Telemetry.$currentSpanID.withValue(id) { try body(scope) }
            recorder.closeSync(id: id, scope: scope, failure: nil)
            return value
        } catch {
            recorder.closeSync(id: id, scope: scope, failure: String(describing: error))
            throw error
        }
    }

    /// A point in time with no duration: a decision taken, a threshold crossed, a thing
    /// skipped. Skips matter most, because a silently skipped stage and a stage that found
    /// nothing look identical afterwards.
    public static func event(
        _ name: String,
        _ category: TelemetryCategory,
        attributes: [String: String] = [:]
    ) {
        guard isEnabled else { return }
        recorder.recordEvent(
            TelemetrySpan(
                id: recorder.nextID(),
                parentID: currentSpanID,
                category: category,
                name: name,
                startedAt: Date(),
                elapsedNanoseconds: 0,
                counters: [:],
                attributes: attributes,
                failure: nil,
                isEvent: true
            )
        )
    }

    // MARK: - Reading back

    public static func collected() async -> [TelemetrySpan] { await recorder.spans() }

    public static func reset() async { await recorder.reset() }
}

// MARK: - Categories

/// Which layer emitted a span. Kept to the module names so a tree can be read against the
/// architecture without a legend.
public enum TelemetryCategory: String, Sendable, Codable, CaseIterable {
    case cli
    case app
    case store
    case ingest
    case graph
    case search
    case reason
    case mcp
    case http
}

// MARK: - One span

public struct TelemetrySpan: Sendable, Codable, Identifiable, Hashable {
    public let id: UInt64
    public let parentID: UInt64?
    public let category: TelemetryCategory
    public let name: String
    public let startedAt: Date
    /// `nil` while the span is still open. An unclosed span renders as such rather than being
    /// given an invented duration, for the same reason a receipt leaves unmeasured fields nil.
    public var elapsedNanoseconds: UInt64?
    public var counters: [String: Int]
    public var attributes: [String: String]
    public var failure: String?
    /// Point-in-time markers render without a duration column.
    public var isEvent: Bool

    public init(
        id: UInt64,
        parentID: UInt64?,
        category: TelemetryCategory,
        name: String,
        startedAt: Date,
        elapsedNanoseconds: UInt64?,
        counters: [String: Int],
        attributes: [String: String],
        failure: String?,
        isEvent: Bool = false
    ) {
        self.id = id
        self.parentID = parentID
        self.category = category
        self.name = name
        self.startedAt = startedAt
        self.elapsedNanoseconds = elapsedNanoseconds
        self.counters = counters
        self.attributes = attributes
        self.failure = failure
        self.isEvent = isEvent
    }

    public var milliseconds: Double? {
        elapsedNanoseconds.map { Double($0) / 1_000_000 }
    }
}

// MARK: - The mutable side of an open span

/// Handed to a span's body so it can attach counts and attributes as it learns them.
///
/// A final class with a mutex rather than an actor: it is written from inside a synchronous
/// closure as often as an async one, and making it an actor would force `await` on every
/// count.
public final class TelemetryScope: Sendable {
    private struct Payload {
        var counters: [String: Int] = [:]
        var attributes: [String: String] = [:]
    }

    private let payload: Mutex<Payload>
    /// The scope handed to a body when telemetry is off. Every method is a no-op, so
    /// instrumentation costs nothing when disabled.
    public static let disabled = TelemetryScope(attributes: [:], isActive: false)
    private let isActive: Bool

    init(attributes: [String: String], isActive: Bool = true) {
        self.payload = Mutex(Payload(counters: [:], attributes: attributes))
        self.isActive = isActive
    }

    /// Add to a counter. Additive rather than assigning, so a loop body can call it per
    /// iteration without the caller keeping a running total.
    public func count(_ key: String, _ amount: Int = 1) {
        guard isActive else { return }
        payload.withLock { $0.counters[key, default: 0] += amount }
    }

    /// Record a measured count, replacing any previous value. For totals that are known once.
    public func set(_ key: String, _ value: Int) {
        guard isActive else { return }
        payload.withLock { $0.counters[key] = value }
    }

    public func attribute(_ key: String, _ value: String) {
        guard isActive else { return }
        payload.withLock { $0.attributes[key] = value }
    }

    func snapshot() -> (counters: [String: Int], attributes: [String: String]) {
        payload.withLock { ($0.counters, $0.attributes) }
    }
}

// MARK: - The store of spans

/// Holds the spans for the current process.
///
/// Bounded: a long `sync` can open tens of thousands of spans, and an unbounded buffer would
/// turn observability into a memory leak. Past the cap the recorder stops *adding* and counts
/// what it dropped, so the tree says it is incomplete rather than silently being wrong.
public final class TelemetryRecorder: Sendable {
    private struct State {
        var spans: [UInt64: TelemetrySpan] = [:]
        var order: [UInt64] = []
        var nextID: UInt64 = 1
        var dropped: Int = 0
    }

    /// Chosen, not measured. Large enough for a full GitHub sync at roughly one span per
    /// object, small enough to stay a few megabytes.
    private static let capacity = 50_000

    private let state = Mutex(State())

    public init() {}

    func nextID() -> UInt64 {
        state.withLock { current in
            defer { current.nextID += 1 }
            return current.nextID
        }
    }

    func openSync(category: TelemetryCategory, name: String, parent: UInt64?) -> UInt64 {
        state.withLock { current in
            let id = current.nextID
            current.nextID += 1
            guard current.order.count < Self.capacity else {
                current.dropped += 1
                return id
            }
            current.spans[id] = TelemetrySpan(
                id: id,
                parentID: parent,
                category: category,
                name: name,
                startedAt: Date(),
                elapsedNanoseconds: nil,
                counters: [:],
                attributes: [:],
                failure: nil
            )
            current.order.append(id)
            return id
        }
    }

    func closeSync(id: UInt64, scope: TelemetryScope, failure: String?) {
        let (counters, attributes) = scope.snapshot()
        state.withLock { current in
            guard var span = current.spans[id] else { return }
            let elapsed = Date().timeIntervalSince(span.startedAt)
            span.elapsedNanoseconds = UInt64(max(0, elapsed) * 1_000_000_000)
            span.counters = counters
            span.attributes.merge(attributes) { _, new in new }
            span.failure = failure
            current.spans[id] = span
        }
    }

    func recordEvent(_ span: TelemetrySpan) {
        state.withLock { current in
            guard current.order.count < Self.capacity else {
                current.dropped += 1
                return
            }
            current.spans[span.id] = span
            current.order.append(span.id)
        }
    }

    public func spans() async -> [TelemetrySpan] {
        state.withLock { current in current.order.compactMap { current.spans[$0] } }
    }

    public func droppedCount() async -> Int {
        state.withLock { $0.dropped }
    }

    public func reset() async {
        state.withLock { $0 = State() }
    }
}
