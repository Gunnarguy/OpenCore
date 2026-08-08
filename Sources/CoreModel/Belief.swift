import Foundation

/// Why two claims cannot both stand.
public enum ContradictionKind: String, Sendable, Codable {
    /// Same slot, different values, and one is strictly later. The later one usually wins.
    case temporalSupersession
    /// Same slot, different values, no usable ordering. Nothing wins automatically.
    case directConflict
    /// Same slot and value, but the validity intervals disagree.
    case validityDisagreement
}

/// How a contradiction was settled, if it was.
public enum Resolution: String, Sendable, Codable {
    /// Later evidence supersedes earlier. Recorded, not deleted.
    case supersededByRecency
    /// A higher-authority source overrode a lower one.
    case supersededByAuthority
    /// The user said which is right.
    case resolvedByCorrection
    /// Both hold, over different intervals. Not actually a conflict once time is respected.
    case coexistingIntervals
    /// Genuinely unresolved. The system reports both and says so.
    case unresolved
}

public struct Contradiction: Hashable, Sendable, Codable, Identifiable {
    public var id: ContradictionID
    public var claimA: ClaimID
    public var claimB: ClaimID
    public var kind: ContradictionKind
    public var resolution: Resolution
    /// The claim that won, if one did.
    public var winner: ClaimID?
    public var detectedAt: Date
    public var reason: String

    public init(
        claimA: ClaimID,
        claimB: ClaimID,
        kind: ContradictionKind,
        resolution: Resolution,
        winner: ClaimID? = nil,
        detectedAt: Date = Date(),
        reason: String
    ) {
        // Order-independent so the same pair is never recorded twice.
        let pair = [claimA.value, claimB.value].sorted()
        self.id = ContradictionID.derived(from: pair[0], pair[1])
        self.claimA = claimA
        self.claimB = claimB
        self.kind = kind
        self.resolution = resolution
        self.winner = winner
        self.detectedAt = detectedAt
        self.reason = reason
    }
}

/// The system's current answer for one `claimKey`, versioned.
///
/// Beliefs are append-only. Changing your mind writes version N+1 with `supersedes` pointing
/// at N; it never updates a row. That append-only history is what `memory log`,
/// `memory diff`, and `memory checkout` read, and it is the difference between a system
/// that remembers and one that can show how its mind changed.
public struct Belief: Hashable, Sendable, Codable, Identifiable {
    public var id: BeliefID
    /// `subject|predicate`. The slot this belief fills.
    public var claimKey: String
    public var version: Int
    /// The claim currently believed for this slot.
    public var claimID: ClaimID
    public var confidence: Double
    public var authority: Authority
    public var validity: Validity
    public var supersedes: BeliefID?
    public var reason: String
    public var decidedAt: Date

    public init(
        claimKey: String,
        version: Int,
        claimID: ClaimID,
        confidence: Double,
        authority: Authority,
        validity: Validity,
        supersedes: BeliefID? = nil,
        reason: String,
        decidedAt: Date = Date()
    ) {
        self.id = BeliefID.derived(from: claimKey, String(version))
        self.claimKey = claimKey
        self.version = version
        self.claimID = claimID
        self.confidence = confidence
        self.authority = authority
        self.validity = validity
        self.supersedes = supersedes
        self.reason = reason
        self.decidedAt = decidedAt
    }
}

/// A user correction, kept as a record rather than applied as an overwrite.
///
/// The interesting field is `priorFailure`. Storing only the new value teaches nothing;
/// storing *why the old belief was reachable* is what lets the extractor be fixed instead
/// of the symptom being patched.
public struct Correction: Hashable, Sendable, Codable, Identifiable {
    public var id: CorrectionID
    public var supersededClaim: ClaimID?
    public var assertedClaim: ClaimID
    public var authority: Authority
    public var reason: String
    /// The diagnosis: what made the wrong belief look right at the time.
    public var priorFailure: String?
    public var createdAt: Date

    public init(
        supersededClaim: ClaimID?,
        assertedClaim: ClaimID,
        authority: Authority = .directStatement,
        reason: String,
        priorFailure: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = CorrectionID.derived(from: supersededClaim?.value ?? "∅", assertedClaim.value, String(Int(createdAt.timeIntervalSince1970)))
        self.supersededClaim = supersededClaim
        self.assertedClaim = assertedClaim
        self.authority = authority
        self.reason = reason
        self.priorFailure = priorFailure
        self.createdAt = createdAt
    }
}
