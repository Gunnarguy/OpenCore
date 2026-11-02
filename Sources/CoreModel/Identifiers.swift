import Foundation

/// A typed identifier. The phantom `Scope` costs nothing at runtime and makes it a
/// compile error to hand an `ObjectID` to something expecting a `ClaimID`.
public struct ID<Scope>: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) { self.value = value }
    public init(stringLiteral value: String) { self.value = value }

    // SQLite's default BINARY identity distinguishes UTF-8 byte sequences. Swift String
    // equality uses Unicode canonical equivalence, so synthesized Hashable would collapse
    // distinct stored rows in sets and dictionaries.
    public static func == (lhs: ID<Scope>, rhs: ID<Scope>) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 { hasher.combine(byte) }
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// Deterministic identity. The same input always yields the same id, so re-ingesting
    /// a source updates rows instead of duplicating them.
    public static func derived(from parts: String...) -> ID<Scope> {
        ID(Digest.hex(parts.joined(separator: "\u{1F}")))
    }
}

public enum SourceScope: Sendable {}
public enum ObjectScope: Sendable {}
public enum EvidenceScope: Sendable {}
public enum EntityScope: Sendable {}
public enum ClaimScope: Sendable {}
public enum EventScope: Sendable {}
public enum BeliefScope: Sendable {}
public enum ContradictionScope: Sendable {}
public enum ReceiptScope: Sendable {}
public enum CorrectionScope: Sendable {}

public typealias SourceID = ID<SourceScope>
public typealias ObjectID = ID<ObjectScope>
public typealias EvidenceID = ID<EvidenceScope>
public typealias EntityID = ID<EntityScope>
public typealias ClaimID = ID<ClaimScope>
public typealias EventID = ID<EventScope>
public typealias BeliefID = ID<BeliefScope>
public typealias ContradictionID = ID<ContradictionScope>
public typealias ReceiptID = ID<ReceiptScope>
public typealias CorrectionID = ID<CorrectionScope>
