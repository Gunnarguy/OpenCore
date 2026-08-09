import CoreModel
import CoreStore
import Foundation

/// Turns objects into entities and aliases.
///
/// Resolution here is deliberately conservative and rule-based. A wrong merge is far more
/// expensive than a missed one: two entities that should be one can be joined later with
/// full history intact, while one entity that was actually two has already contaminated
/// every claim attached to it and there is no record of where the seam was.
public struct EntityResolver: Sendable {
    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    public struct Outcome: Sendable {
        public var entities: Int = 0
        public var aliases: Int = 0
    }

    @discardableResult
    public func resolve(objects: [CoreObject]) async throws -> Outcome {
        var entities: [EntityID: CoreEntity] = [:]
        var aliases: Set<EntityAlias> = []

        for object in objects {
            switch object.kind {
            case .repository:
                let (entity, entityAliases) = projectEntity(from: object)
                merge(entity, into: &entities)
                aliases.formUnion(entityAliases)

                // The primary language is a technology entity in its own right, so
                // "what do I keep building with" becomes a graph question rather than
                // a string scan across metadata.
                if let language = object.metadata["language"] {
                    let technology = CoreEntity(
                        kind: .technology,
                        canonicalName: language,
                        domain: .publicRecord,
                        firstSeenAt: object.authoredAt ?? object.ingestedAt,
                        lastSeenAt: object.ingestedAt
                    )
                    merge(technology, into: &entities)
                    aliases.insert(EntityAlias(entityID: technology.id, surface: language, confidence: 1.0))
                }

            case .file where object.externalID.hasSuffix("#languages"):
                for key in object.metadata.keys where key.hasPrefix("lang_") {
                    let language = String(key.dropFirst(5))
                    let technology = CoreEntity(
                        kind: .technology,
                        canonicalName: language,
                        domain: .publicRecord,
                        firstSeenAt: object.authoredAt ?? object.ingestedAt,
                        lastSeenAt: object.ingestedAt
                    )
                    merge(technology, into: &entities)
                    aliases.insert(EntityAlias(entityID: technology.id, surface: language, confidence: 1.0))
                }

            case .calendarEvent:
                // The calendar is a context ("Work", "Family"), and every named attendee is a
                // person. Both must exist before ClaimExtractor writes met_with and attended,
                // because claim.subject is a foreign key onto entity.
                let calendarName = object.metadata["calendar"] ?? "Calendar"
                let calendar = CoreEntity(
                    kind: .concept,
                    canonicalName: calendarName,
                    domain: object.domain,
                    firstSeenAt: object.authoredAt ?? object.ingestedAt,
                    lastSeenAt: object.authoredAt ?? object.ingestedAt
                )
                merge(calendar, into: &entities)
                aliases.insert(EntityAlias(entityID: calendar.id, surface: calendarName, confidence: 1.0))

                for name in (object.metadata["attendees"] ?? "").split(separator: "\u{1F}") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard trimmed.count > 1 else { continue }
                    let person = CoreEntity(
                        kind: .person,
                        canonicalName: trimmed,
                        // People from a calendar are personal regardless of which calendar
                        // they came from. A colleague met at a work event is still a person.
                        domain: .personal,
                        firstSeenAt: object.authoredAt ?? object.ingestedAt,
                        lastSeenAt: object.authoredAt ?? object.ingestedAt
                    )
                    merge(person, into: &entities)
                    aliases.insert(EntityAlias(entityID: person.id, surface: trimmed, confidence: 0.95))
                }

            case .note, .document, .file:
                // The container, so a timeline groups by folder or list rather than scattering.
                let container = object.metadata["folder"]
                    ?? object.metadata["list"]
                    ?? object.metadata["root"].map { ($0 as NSString).lastPathComponent }
                    ?? object.kind.rawValue
                let entity = CoreEntity(
                    kind: .concept,
                    canonicalName: container,
                    domain: object.domain,
                    firstSeenAt: object.authoredAt ?? object.ingestedAt,
                    lastSeenAt: object.ingestedAt
                )
                merge(entity, into: &entities)
                aliases.insert(EntityAlias(entityID: entity.id, surface: container, confidence: 0.9))

            case .commit:
                // A Conventional Commit scope names a component of the repository. The entity
                // must exist before ClaimExtractor writes has_component against it.
                if let scope = ClaimExtractor.conventionalCommitScope(object.title) {
                    let component = CoreEntity(
                        kind: .concept,
                        canonicalName: scope,
                        domain: object.domain,
                        firstSeenAt: object.authoredAt ?? object.ingestedAt,
                        lastSeenAt: object.authoredAt ?? object.ingestedAt
                    )
                    merge(component, into: &entities)
                    aliases.insert(EntityAlias(entityID: component.id, surface: scope, confidence: 0.9))
                }
                if let name = object.metadata["author"], name != "unknown" {
                    let person = CoreEntity(
                        kind: .person,
                        canonicalName: name,
                        domain: .personal,
                        firstSeenAt: object.authoredAt ?? object.ingestedAt,
                        lastSeenAt: object.ingestedAt
                    )
                    merge(person, into: &entities)
                    aliases.insert(EntityAlias(entityID: person.id, surface: name, confidence: 1.0))
                }

            default:
                break
            }
        }

        try await store.upsert(Array(entities.values))
        try await store.addAliases(Array(aliases))
        return Outcome(entities: entities.count, aliases: aliases.count)
    }

    /// A repository becomes a project entity, with its bare name and owner/name form as aliases.
    private func projectEntity(from object: CoreObject) -> (CoreEntity, Set<EntityAlias>) {
        let fullName = object.externalID
        let bareName = fullName.split(separator: "/").last.map(String.init) ?? fullName

        let entity = CoreEntity(
            kind: .project,
            canonicalName: bareName,
            domain: object.domain,
            firstSeenAt: object.authoredAt ?? object.ingestedAt,
            lastSeenAt: object.ingestedAt
        )

        var aliases: Set<EntityAlias> = [
            EntityAlias(entityID: entity.id, surface: bareName, confidence: 1.0),
            EntityAlias(entityID: entity.id, surface: fullName, confidence: 1.0),
        ]

        // CamelCase split: "OpenIntelligence" also answers to "open intelligence".
        let spaced = bareName.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        if spaced != bareName {
            aliases.insert(EntityAlias(entityID: entity.id, surface: spaced, confidence: 0.9))
        }

        return (entity, aliases)
    }

    private func merge(_ entity: CoreEntity, into entities: inout [EntityID: CoreEntity]) {
        if var existing = entities[entity.id] {
            existing.firstSeenAt = min(existing.firstSeenAt, entity.firstSeenAt)
            existing.lastSeenAt = max(existing.lastSeenAt, entity.lastSeenAt)
            entities[entity.id] = existing
        } else {
            entities[entity.id] = entity
        }
    }
}

extension EntityAlias: Hashable {}
