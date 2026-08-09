import Foundation

// MARK: - Source

public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case github, filesystem, calendar, mail, manual
}

/// A configured connector instance. `github:Gunnarguy` is one source; a second account
/// would be a second source with its own authority and sync cursor.
public struct Source: Hashable, Sendable, Codable, Identifiable {
    public var id: SourceID
    public var kind: SourceKind
    /// Stable handle within the kind, e.g. a GitHub login or a folder path.
    public var handle: String
    public var displayName: String
    public var defaultAuthority: Authority
    public var defaultDomain: Domain
    public var lastSyncedAt: Date?
    /// Opaque per-connector resume token (an ETag, a cursor, a high-water timestamp).
    public var syncCursor: String?
    /// Connector-specific setup, as JSON. Shape is the connector's business.
    ///
    /// **Never a place for a credential.** Configuration records the *names* of environment
    /// variables to read; the values stay in the environment. The store is not encrypted.
    public var config: String?

    public init(
        kind: SourceKind,
        handle: String,
        displayName: String,
        defaultAuthority: Authority,
        defaultDomain: Domain,
        lastSyncedAt: Date? = nil,
        syncCursor: String? = nil,
        config: String? = nil
    ) {
        self.id = SourceID.derived(from: kind.rawValue, handle)
        self.kind = kind
        self.handle = handle
        self.displayName = displayName
        self.defaultAuthority = defaultAuthority
        self.defaultDomain = defaultDomain
        self.lastSyncedAt = lastSyncedAt
        self.syncCursor = syncCursor
        self.config = config
    }
}

// MARK: - Object

public enum ObjectKind: String, Sendable, Codable, CaseIterable {
    case repository, commit, issue, pullRequest, release, file, document, note, message, calendarEvent
}

/// Something ingested, stored as close to verbatim as the connector can manage.
///
/// Objects are the bottom of the trust stack: everything above them is recomputable, and
/// if the derived layers are ever wrong they get rebuilt from here rather than patched.
public struct CoreObject: Hashable, Sendable, Codable, Identifiable {
    public var id: ObjectID
    public var sourceID: SourceID
    public var kind: ObjectKind
    /// The id this thing has in its own system: a commit sha, a file path, a message id.
    public var externalID: String
    public var title: String
    /// The searchable body. Indexed into FTS5 verbatim.
    public var text: String
    /// A link back to the thing itself, so a citation is clickable rather than descriptive.
    public var uri: String?
    /// When the thing was made, per its source. Not when we read it.
    public var authoredAt: Date?
    public var ingestedAt: Date
    /// Hash of `text`. Re-ingest compares this before touching derived rows.
    public var contentHash: String
    public var domain: Domain
    public var authority: Authority
    /// Connector-specific fields, kept rather than discarded, as JSON.
    public var metadata: [String: String]

    public init(
        sourceID: SourceID,
        kind: ObjectKind,
        externalID: String,
        title: String,
        text: String,
        uri: String? = nil,
        authoredAt: Date? = nil,
        ingestedAt: Date = Date(),
        domain: Domain,
        authority: Authority,
        metadata: [String: String] = [:]
    ) {
        self.id = ObjectID.derived(from: sourceID.value, kind.rawValue, externalID)
        self.sourceID = sourceID
        self.kind = kind
        self.externalID = externalID
        self.title = title
        self.text = text
        self.uri = uri
        self.authoredAt = authoredAt
        self.ingestedAt = ingestedAt
        self.contentHash = Digest.hex(text)
        self.domain = domain
        self.authority = authority
        self.metadata = metadata
    }
}

// MARK: - Evidence

/// A specific span of a specific object, cited in support of (or against) a claim.
///
/// Evidence is not a copy of the text. It is a pointer plus a snippet for display, so the
/// full object stays the single source of truth and a citation can always be re-read at source.
public struct Evidence: Hashable, Sendable, Codable, Identifiable {
    public var id: EvidenceID
    public var objectID: ObjectID
    /// Byte offsets into `CoreObject.text`. `nil` means the whole object.
    public var range: Range<Int>?
    /// Display excerpt. Regenerable from the object; stored so listing evidence is one query.
    public var snippet: String
    public var authority: Authority

    public init(objectID: ObjectID, range: Range<Int>? = nil, snippet: String, authority: Authority) {
        let rangeKey = range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "whole"
        self.id = EvidenceID.derived(from: objectID.value, rangeKey)
        self.objectID = objectID
        self.range = range
        self.snippet = snippet
        self.authority = authority
    }
}

/// Whether a piece of evidence argues for or against the claim it is attached to.
///
/// Counter-evidence is a first-class row, not an absence. An answer that cannot show what
/// argues against it is not inspectable, it is just confident.
public enum Stance: String, Sendable, Codable {
    case supports, refutes
}

// MARK: - Entity

public enum EntityKind: String, Sendable, Codable, CaseIterable {
    case person, project, organization, technology, concept, place
}

public struct CoreEntity: Hashable, Sendable, Codable, Identifiable {
    public var id: EntityID
    public var kind: EntityKind
    public var canonicalName: String
    public var domain: Domain
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(kind: EntityKind, canonicalName: String, domain: Domain, firstSeenAt: Date = Date(), lastSeenAt: Date = Date()) {
        self.id = EntityID.derived(from: kind.rawValue, canonicalName.lowercased())
        self.kind = kind
        self.canonicalName = canonicalName
        self.domain = domain
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

/// A surface form that resolves to an entity. `OI`, `OpenIntelligence`, and
/// `Gunnarguy/OpenIntelligence` are three aliases of one entity.
public struct EntityAlias: Hashable, Sendable, Codable {
    public var entityID: EntityID
    public var surface: String
    public var confidence: Double

    public init(entityID: EntityID, surface: String, confidence: Double) {
        self.entityID = entityID
        self.surface = surface
        self.confidence = confidence
    }
}

// MARK: - Claim

/// Something believed about an entity, with its evidence, its confidence, and both of its
/// time axes attached.
///
/// The distinction this type exists to preserve: *"OpenIntelligence uses hybrid retrieval"*
/// (observed, from a commit) and *"Gunnar prefers hybrid retrieval"* (inferred, from a
/// pattern) are not the same kind of thing and must never be stored as if they were.
public struct CoreClaim: Hashable, Sendable, Codable, Identifiable {
    public var id: ClaimID
    public var subject: EntityID
    /// Controlled vocabulary. See `Predicate`.
    public var predicate: String
    /// The object of the claim when it is another entity.
    public var objectEntity: EntityID?
    /// The object of the claim when it is a value rather than a thing.
    public var literal: String?
    /// Evidence strength, 0...1. Not authority, and never multiplied by it.
    public var confidence: Double
    /// Highest authority among supporting evidence.
    public var authority: Authority
    public var derivation: Derivation
    public var validity: Validity
    public var domain: Domain

    /// Identity is (subject, predicate, object) plus the instant the fact became true.
    /// Two claims that disagree about the same slot therefore collide in `claimKey`
    /// but not in `id`, which is exactly what contradiction detection needs.
    public var claimKey: String { "\(subject.value)|\(predicate)" }

    public init(
        subject: EntityID,
        predicate: String,
        objectEntity: EntityID? = nil,
        literal: String? = nil,
        confidence: Double,
        authority: Authority,
        derivation: Derivation,
        validity: Validity,
        domain: Domain
    ) {
        let objectKey = objectEntity?.value ?? literal ?? "∅"
        let fromKey = validity.validFrom.map { String(Int($0.timeIntervalSince1970)) } ?? "∅"
        self.id = ClaimID.derived(from: subject.value, predicate, objectKey, fromKey)
        self.subject = subject
        self.predicate = predicate
        self.objectEntity = objectEntity
        self.literal = literal
        self.confidence = confidence
        self.authority = authority
        self.derivation = derivation
        self.validity = validity
        self.domain = domain
    }
}

/// The predicate vocabulary. Free-text predicates would make contradiction detection
/// impossible, because `uses` and `is_built_with` would never collide.
public enum Predicate {
    public static let uses = "uses"
    public static let builtWith = "built_with"
    public static let dependsOn = "depends_on"
    public static let authoredBy = "authored_by"
    public static let worksAt = "works_at"
    public static let status = "status"
    public static let describes = "describes"
    public static let prefers = "prefers"
    public static let releasedVersion = "released_version"
    public static let primaryLanguage = "primary_language"
    public static let metWith = "met_with"
    public static let attended = "attended"
    public static let partOf = "part_of"
    public static let contributedTo = "contributed_to"
    public static let hasComponent = "has_component"
    public static let organiser = "organised_by"

    /// Predicates where one subject may hold only one current value. These are the ones
    /// that can contradict; `uses` cannot, because a project genuinely uses many things.
    ///
    /// `metWith`, `attended` and `builtWith` are deliberately absent: you meet many people and
    /// attend many events, and treating a second one as a contradiction would manufacture
    /// conflict out of an ordinary calendar.
    public static let functional: Set<String> = [status, primaryLanguage, worksAt, releasedVersion, partOf]
}

// MARK: - Event

/// Something that happened at a time. Events are what make causal reconstruction possible:
/// claims say what is, events say what changed.
public struct CoreEvent: Hashable, Sendable, Codable, Identifiable {
    public var id: EventID
    public var subject: EntityID
    public var verb: String
    public var detail: String
    public var occurredAt: Date
    public var domain: Domain
    public var authority: Authority

    public init(subject: EntityID, verb: String, detail: String, occurredAt: Date, domain: Domain, authority: Authority) {
        self.id = EventID.derived(from: subject.value, verb, detail, String(Int(occurredAt.timeIntervalSince1970)))
        self.subject = subject
        self.verb = verb
        self.detail = detail
        self.occurredAt = occurredAt
        self.domain = domain
        self.authority = authority
    }
}
