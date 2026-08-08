import Foundation

/// How much weight a source's say-so carries, independent of how much evidence there is.
///
/// This is deliberately an **ordinal tier, not a probability**. The temptation is to write
/// `authority: 0.98` and then, somewhere downstream, `score = confidence * authority`. That
/// multiplication is meaningless: 0.98 was never measured against anything, and multiplying
/// an unmeasured constant into a calibrated number launders the guess into the result.
///
/// Tiers compare and they break ties. They do not multiply. `Comparable` is the only
/// arithmetic this type offers, and that is the point.
public enum Authority: Int, Sendable, Codable, Comparable, CaseIterable {
    /// A model said so and nothing else backs it.
    case modelInference = 0
    /// Derived from a pattern across other records rather than stated anywhere.
    case derivedPattern = 1
    /// A generated summary of something the system read.
    case generatedSummary = 2
    /// A third party wrote it: someone else's email, a web page, an issue comment.
    case thirdPartyRecord = 3
    /// The user authored it, but incidentally: a commit message, a note, a doc.
    case authoredArtifact = 4
    /// The user stated it directly to OpenCore, about themselves.
    case directStatement = 5

    public static func < (lhs: Authority, rhs: Authority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .modelInference: "model inference"
        case .derivedPattern: "derived pattern"
        case .generatedSummary: "generated summary"
        case .thirdPartyRecord: "third-party record"
        case .authoredArtifact: "authored artifact"
        case .directStatement: "direct statement"
        }
    }
}

/// How a claim came to exist. Kept separate from `Authority` because they answer different
/// questions: authority is *who said it*, derivation is *how OpenCore got it*.
public enum Derivation: String, Sendable, Codable, CaseIterable {
    /// Read straight out of structured source data. No interpretation.
    case observed
    /// Concluded by OpenCore from other claims or patterns.
    case inferred
    /// The user asserted it.
    case asserted
    /// The user corrected an earlier belief. Carries a `Correction`.
    case corrected
}
