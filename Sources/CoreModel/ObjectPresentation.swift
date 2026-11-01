import Foundation

/// Original non-body floor fields retained when a file changes title/time/container without
/// changing text. The text-hash-keyed object_version table cannot represent these transitions.
public struct ObjectPresentation: Sendable, Hashable, Codable {
    public static let metadataKey = "object_presentation_history"
    public static let legacyEventsKey = "classification_unproven_legacy_timeline_events"
    public var title: String
    public var authoredAt: Date?
    public var ingestedAt: Date
    public var uri: String?
    public var domain: Domain
    public var authority: Authority
    public var metadata: [String: String]

    public init(object: CoreObject) {
        title = object.title; authoredAt = object.authoredAt; ingestedAt = object.ingestedAt
        uri = object.uri; domain = object.domain; authority = object.authority
        metadata = object.metadata
        metadata.removeValue(forKey: Self.metadataKey)
        metadata.removeValue(forKey: Self.legacyEventsKey)
    }

    public static func history(in metadata: [String: String]) -> [ObjectPresentation] {
        metadata[metadataKey].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
    }

    public func restoring(on object: CoreObject) -> CoreObject {
        var result = object
        result.title = title; result.authoredAt = authoredAt; result.ingestedAt = ingestedAt
        result.uri = uri; result.domain = domain; result.authority = authority; result.metadata = metadata
        return result
    }

    /// A deterministic identity, shared by extraction and privacy repair. It is backed by
    /// original fields on the floor, including the container and authored instant.
    public static func timelineEvent(for object: CoreObject) -> CoreEvent? {
        guard [.note, .document, .file].contains(object.kind), let occurredAt = object.authoredAt else { return nil }
        let container = object.metadata["folder"] ?? object.metadata["list"] ?? object.metadata["root"].map { ($0 as NSString).lastPathComponent } ?? object.kind.rawValue
        let subject = CoreEntity(kind: .concept, canonicalName: container, domain: object.domain).id
        let verb = object.kind == .note ? "noted" : object.kind == .file ? "edited" : "wrote"
        return CoreEvent(subject: subject, verb: verb, detail: object.title, occurredAt: occurredAt, domain: object.domain, authority: object.authority)
    }

    public static func legacyEvents(in metadata: [String: String]) -> [CoreEvent] {
        metadata[legacyEventsKey].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([CoreEvent].self, from: $0) } ?? []
    }

    /// Replaying a stored presentation cannot bypass a subsequent quarantine/downgrade of
    /// its parent floor object. Uncertain legacy rows have no provable original object and
    /// stay explicitly restricted on every replay.
    public static func presentations(for object: CoreObject) -> [CoreObject] {
        (history(in: object.metadata).map { $0.restoring(on: object) } + [object]).map { item in
            var effective = item
            if object.domain == .restricted { effective.domain = .restricted }
            else if !effective.domain.isSensitive, object.domain != .project, object.domain != .publicRecord { effective.domain = object.domain }
            effective.authority = min(effective.authority, object.authority)
            return effective
        }
    }

    public static func timelineEvents(for object: CoreObject) -> [CoreEvent] {
        let presentations = presentations(for: object)
        var byID: [EventID: CoreEvent] = [:]
        for item in presentations {
            guard var event = timelineEvent(for: item) else { continue }
            if object.domain == .restricted { event.domain = .restricted }
            else if !event.domain.isSensitive, object.domain != .project, object.domain != .publicRecord { event.domain = object.domain }
            event.authority = min(event.authority, object.authority)
            byID[event.id] = event
        }
        for var event in legacyEvents(in: object.metadata) {
            event.domain = .restricted
            event.authority = min(event.authority, object.authority)
            byID[event.id] = event
        }
        return byID.values.sorted { $0.occurredAt < $1.occurredAt }
    }
}
