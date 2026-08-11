import CoreModel
import Foundation

/// Everything the store holds about one entity, gathered in one pass.
///
/// **Why this type exists.** Claims, beliefs, contradictions, evidence and events were each
/// reachable, and each had a screen, so the app shipped six tables and asked the reader to join
/// them by hand. A person does not think "I would like to browse the belief layer"; they think
/// "what do I know about OpenClinic". This is the shape of that question.
///
/// Notably it is the shape the MCP server has offered outside callers all along, through
/// `core_claims(entity:)`. The app gave an external model a better lens on this data than it
/// gave its own user.
public struct EntityDossier: Sendable {
    public var entity: CoreEntity
    /// What is believed, one row per distinct statement.
    public var claims: [DossierClaim]
    /// Contradictions touching this entity's claims, unresolved first.
    public var contradictions: [Contradiction]
    /// What happened, newest first.
    public var events: [CoreEvent]
    /// Other surface forms that resolve here.
    public var aliases: [String]

    public var isEmpty: Bool {
        claims.isEmpty && events.isEmpty && contradictions.isEmpty
    }
}

/// One statement about an entity, ready to render.
public struct DossierClaim: Sendable, Identifiable {
    public var claim: CoreClaim
    public var id: ClaimID { claim.id }

    /// The object, as a person would read it.
    ///
    /// **Resolved, never raw.** A claim whose object is another entity stores an `EntityID`,
    /// which is a content hash, so rendering `objectEntity?.value` puts
    /// `contributed to 6230ffec402a22386b2ff7a36d1b4e5` on screen. That is the database talking
    /// to itself. Looked up here rather than in the view because the view has no store.
    public var value: String

    /// How many identical claims this row stands for.
    ///
    /// The graph records `contributed_to` once per commit, so a real entity carries the same
    /// statement hundreds of times. Listing each is not detail, it is noise that buries every
    /// other statement about the thing. The count keeps the fact that there were many.
    public var occurrences: Int

    /// Versions this slot has been through, when it has changed its mind. `nil` when it has
    /// only ever been decided once, so the UI shows the affordance only where there is history.
    public var revisions: Int?

    /// The belief now standing in this slot.
    public var belief: Belief?
}

extension Store {
    /// Assemble one entity's dossier.
    ///
    /// One method rather than six calls from the view, because the joins are the store's
    /// business and a view that assembles them will drift from any other view that does the
    /// same. It also keeps the SQL where `.claude/rules/store.md` requires it.
    public func dossier(for id: EntityID, eventLimit: Int = 100) async throws -> EntityDossier? {
        guard let entity = try await entity(id) else { return nil }

        let raw = try await claims(subject: id, currentOnly: true)

        // Names for every entity a claim points at, in one query rather than one per claim.
        // The first version of this asked per slot and took thirty seconds on an entity with
        // 477 claims, which is the same N+1 shape already tracked on the answer path, written
        // fresh. At 135 entities loading all of them is cheaper than any batching cleverness.
        var names: [EntityID: String] = [:]
        if raw.contains(where: { $0.objectEntity != nil }) {
            for entity in try await entities() { names[entity.id] = entity.canonicalName }
        }

        let summaries = try await beliefSummaries(keys: Array(Set(raw.map(\.claimKey))))

        // Collapse identical statements. Keyed on what is actually shown, so two claims that
        // read the same on screen become one row with a count rather than two rows a reader
        // has to compare character by character.
        var order: [String] = []
        var grouped: [String: DossierClaim] = [:]
        for claim in raw {
            let value = claim.literal
                ?? claim.objectEntity.map { names[$0] ?? $0.value }
                ?? "(no value)"
            let key = "\(claim.predicate)\u{1F}\(value)"
            if var existing = grouped[key] {
                existing.occurrences += 1
                // Keep the most confident instance as the representative, so the row's
                // confidence is the best evidence for the statement rather than whichever
                // copy happened to sort first.
                if claim.confidence > existing.claim.confidence { existing.claim = claim }
                grouped[key] = existing
            } else {
                order.append(key)
                let summary = summaries[claim.claimKey]
                grouped[key] = DossierClaim(
                    claim: claim,
                    value: value,
                    occurrences: 1,
                    revisions: (summary?.versions ?? 0) > 1 ? summary?.versions : nil,
                    belief: summary?.current
                )
            }
        }
        // Written out rather than as a tuple comparison. `(Double, Int) > (Double, Int)` sends
        // the type checker looking for a generic tuple operator and it does not come back
        // quickly; the same shape stalled a build for the better part of an hour.
        let claims = order.compactMap { grouped[$0] }.sorted { first, second in
            if first.claim.confidence != second.claim.confidence {
                return first.claim.confidence > second.claim.confidence
            }
            return first.occurrences > second.occurrences
        }

        let claimIDs = Set(raw.map(\.id))
        let contradictions = try await contradictions()
            .filter { claimIDs.contains($0.claimA) || claimIDs.contains($0.claimB) }
            // Unresolved first: a conflict nobody settled is the one worth a reader's attention,
            // and a settled one is history.
            .sorted { ($0.resolution == .unresolved ? 0 : 1) < ($1.resolution == .unresolved ? 0 : 1) }

        return EntityDossier(
            entity: entity,
            claims: claims,
            contradictions: contradictions,
            events: try await events(subject: id, limit: eventLimit),
            aliases: try await aliases(for: id)
        )
    }

    /// Current belief and version count for many slots, in one query.
    ///
    /// Replaces two queries per slot. On an entity with hundreds of claims that was roughly a
    /// thousand round trips to render one screen.
    public func beliefSummaries(keys: [String]) async throws -> [String: (current: Belief, versions: Int)] {
        guard !keys.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let rows = try await database.query(
            "SELECT * FROM belief WHERE claim_key IN (\(placeholders)) ORDER BY claim_key ASC, version ASC",
            keys.map { .text($0) }
        ).map(Belief.init(row:))

        var result: [String: (current: Belief, versions: Int)] = [:]
        for belief in rows {
            // Ascending version order means the last one seen for a key is the current one.
            let versions = (result[belief.claimKey]?.versions ?? 0) + 1
            result[belief.claimKey] = (belief, versions)
        }
        return result
    }

    /// One entity's events, newest first.
    ///
    /// Separate from `events(from:to:)`, which answers "what happened in this window" across
    /// everything. Filtering that in memory would mean loading the whole timeline to show one
    /// repository's history.
    public func events(subject: EntityID, limit: Int = 100) async throws -> [CoreEvent] {
        try await database.query(
            "SELECT * FROM event WHERE subject = ? ORDER BY occurred_at DESC LIMIT ?",
            [.text(subject.value), .integer(Int64(limit))]
        ).map(CoreEvent.init(row:))
    }

    /// Surface forms that resolve to this entity, excluding its own canonical name.
    public func aliases(for id: EntityID) async throws -> [String] {
        try await database.query(
            "SELECT surface FROM entity_alias WHERE entity_id = ? ORDER BY confidence DESC, surface ASC",
            [.text(id.value)]
        ).map { $0.requireString("surface") }
    }

    /// Entities that have something to show, most active first.
    ///
    /// Ordered by claim count rather than alphabetically, because an entity resolved once from a
    /// stray token and an entity the store knows twenty things about should not be equally
    /// prominent in a picker.
    public func entitiesByActivity(limit: Int = 500) async throws -> [(CoreEntity, Int)] {
        let counts = try await database.query(
            """
            SELECT subject, COUNT(*) AS n FROM claim WHERE retracted_at IS NULL
            GROUP BY subject ORDER BY n DESC LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
        var result: [(CoreEntity, Int)] = []
        for row in counts {
            if let entity = try await entity(EntityID(row.requireString("subject"))) {
                result.append((entity, row.requireInt("n")))
            }
        }
        return result
    }
}
