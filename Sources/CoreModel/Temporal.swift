import Foundation

/// Bitemporal validity: two independent time axes, which is the whole reason this project
/// can answer "what did you believe about me in March?" separately from "what was true in March?"
///
/// - **Valid time** (`validFrom`/`validTo`) is when the fact held *in the world*.
/// - **Transaction time** (`observedAt`/`retractedAt`) is when *OpenCore* held it.
///
/// Collapsing these into one timestamp is the single most common modelling mistake in
/// memory systems, and it makes both questions unanswerable. A claim learned today about
/// something true last year has `validFrom` last year and `observedAt` today.
public struct Validity: Hashable, Sendable, Codable {
    /// When the fact started being true. `nil` means unknown, not "always".
    public var validFrom: Date?
    /// When the fact stopped being true. `nil` means still true as far as anyone knows.
    public var validTo: Date?
    /// When OpenCore first had evidence for it.
    public var observedAt: Date
    /// When OpenCore stopped believing it. `nil` means currently believed.
    /// A retracted claim is never deleted: retraction is how the system shows it changed its mind.
    public var retractedAt: Date?

    public init(validFrom: Date? = nil, validTo: Date? = nil, observedAt: Date, retractedAt: Date? = nil) {
        self.validFrom = validFrom
        self.validTo = validTo
        self.observedAt = observedAt
        self.retractedAt = retractedAt
    }

    /// Believed right now.
    public var isCurrent: Bool { retractedAt == nil }

    /// True if the fact held in the world at `instant`.
    public func heldInWorld(at instant: Date) -> Bool {
        if let validFrom, instant < validFrom { return false }
        if let validTo, instant >= validTo { return false }
        return true
    }

    /// True if OpenCore believed this at `instant` — regardless of whether it was correct.
    public func wasBelieved(at instant: Date) -> Bool {
        guard instant >= observedAt else { return false }
        if let retractedAt, instant >= retractedAt { return false }
        return true
    }

    /// Both axes at once. This is what `opencore memory checkout <date>` uses.
    public func asOf(world: Date, knowledge: Date) -> Bool {
        heldInWorld(at: world) && wasBelieved(at: knowledge)
    }
}
