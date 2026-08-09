import CoreModel
import CoreStore
import Foundation

/// Derives claims and events from objects, with evidence attached to every one.
///
/// Extraction is rule-based and deterministic. That is not a placeholder for "LLM later":
/// it is the design. A claim produced by a rule has a `derivation` you can audit and a
/// confidence that means something, and it is reproducible — rerun it on the same objects
/// and you get the same claims. A model in this position produces claims nobody can
/// reproduce or attribute, which is the failure mode the whole project exists to avoid.
///
/// A model may later *propose* claims. It enters at `Authority.modelInference`, the bottom
/// tier, and is outranked by every rule here.
public struct ClaimExtractor: Sendable {
    private let store: Store
    private let now: Date

    public init(store: Store, now: Date = Date()) {
        self.store = store
        self.now = now
    }

    public struct Outcome: Sendable {
        public var claims: Int = 0
        public var events: Int = 0
        public var evidence: Int = 0
    }

    /// A repository with no pushes in this long is called dormant rather than active.
    /// Named because it is a judgement call, not a fact, and it belongs somewhere findable.
    public static let dormantAfter: TimeInterval = 180 * 24 * 3600

    @discardableResult
    public func extract(from objects: [CoreObject]) async throws -> Outcome {
        var claims: [CoreClaim] = []
        var events: [CoreEvent] = []
        var evidence: [Evidence] = []
        var links: [(ClaimID, EvidenceID, Stance, Double)] = []

        for object in objects {
            switch object.kind {
            case .repository:
                try await extractRepositoryClaims(object, into: &claims, &events, &evidence, &links)
            case .file where object.externalID.hasSuffix("#languages"):
                try await extractLanguageClaims(object, into: &claims, &evidence, &links)
            case .commit:
                try await extractCommitEvent(object, into: &events)
            case .calendarEvent:
                try await extractCalendarClaims(object, into: &claims, &events, &evidence, &links)
            case .note, .document, .file:
                // Notes, reminders and local documents yield a timeline but no claims. Their
                // content is prose, and inferring facts from prose without a model is exactly
                // the guessing this extractor refuses to do. They stay retrievable.
                try await extractTimelineEvent(object, into: &events)
            default:
                break
            }
        }

        try await store.save(evidence)
        try await store.save(claims)
        try await store.save(events)
        for link in links {
            try await store.link(claim: link.0, to: link.1, stance: link.2, weight: link.3)
        }

        // Edges mirror entity-to-entity claims so graph traversal does not have to
        // re-interpret claim rows on every hop.
        for claim in claims {
            if let target = claim.objectEntity {
                try await store.addEdge(from: claim.subject, relation: claim.predicate, to: target, weight: claim.confidence, claim: claim.id)
            }
        }

        return Outcome(claims: claims.count, events: events.count, evidence: evidence.count)
    }

    // MARK: - Repository

    private func extractRepositoryClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ events: inout [CoreEvent],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        let bareName = object.externalID.split(separator: "/").last.map(String.init) ?? object.externalID
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        let item = Evidence(
            objectID: object.id,
            snippet: String(object.text.prefix(280)),
            authority: object.authority
        )
        evidence.append(item)

        // primary_language. Functional: a repo has exactly one at a time, so when GitHub
        // reports a different one later, that is a genuine contradiction with a real
        // temporal resolution rather than two facts sitting side by side.
        if let language = object.metadata["language"] {
            let languageEntity = CoreEntity(kind: .technology, canonicalName: language, domain: .publicRecord).id
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.primaryLanguage,
                objectEntity: languageEntity,
                confidence: 0.98,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, item.id, .supports, 1.0))
        }

        // status. Derived, not observed, and its confidence says so.
        let pushedAt = object.metadata["pushed_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
        let archived = object.metadata["archived"] == "true"
        let statusValue: String
        let statusConfidence: Double
        if archived {
            statusValue = "archived"
            statusConfidence = 1.0
        } else if let pushedAt, now.timeIntervalSince(pushedAt) > Self.dormantAfter {
            statusValue = "dormant"
            statusConfidence = 0.75
        } else {
            statusValue = "active"
            statusConfidence = 0.85
        }

        let statusClaim = CoreClaim(
            subject: subject,
            predicate: Predicate.status,
            literal: statusValue,
            confidence: statusConfidence,
            authority: archived ? object.authority : .derivedPattern,
            derivation: archived ? .observed : .inferred,
            validity: Validity(validFrom: pushedAt, observedAt: now),
            domain: object.domain
        )
        claims.append(statusClaim)
        links.append((statusClaim.id, item.id, .supports, 1.0))

        if let createdAt = object.authoredAt {
            events.append(CoreEvent(
                subject: subject,
                verb: "created",
                detail: "Repository \(object.externalID) created",
                occurredAt: createdAt,
                domain: object.domain,
                authority: object.authority
            ))
        }
    }

    // MARK: - Languages

    private func extractLanguageClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        guard let repo = object.metadata["repo"] else { return }
        let bareName = repo.split(separator: "/").last.map(String.init) ?? repo
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        let byteCounts = object.metadata
            .filter { $0.key.hasPrefix("lang_") }
            .compactMap { key, value -> (String, Int)? in
                guard let count = Int(value) else { return nil }
                return (String(key.dropFirst(5)), count)
            }
        let total = max(1, byteCounts.reduce(0) { $0 + $1.1 })

        let item = Evidence(objectID: object.id, snippet: String(object.text.prefix(280)), authority: object.authority)
        evidence.append(item)

        for (language, bytes) in byteCounts {
            let share = Double(bytes) / Double(total)
            // Below 5% is usually a config file or a vendored script, not a thing the
            // project is built with. Recorded as a threshold rather than silently applied.
            guard share >= 0.05 else { continue }

            let languageEntity = CoreEntity(kind: .technology, canonicalName: language, domain: .publicRecord).id
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.builtWith,
                objectEntity: languageEntity,
                // Confidence tracks the measured share. A 90% language is a stronger claim
                // about what the project is than a 6% one, and this is the one place in
                // the extractor where a number is genuinely derived rather than chosen.
                confidence: min(0.99, 0.5 + share / 2),
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, item.id, .supports, share))
        }
    }

    // MARK: - Calendar

    /// Calendar is the richest non-GitHub source, and the only one that yields real claims
    /// without a model: an attendee list is structured data, not prose.
    ///
    /// What it produces: a person entity per named attendee, a `met_with` claim from the
    /// calendar owner to each of them, an `attended` claim from each attendee to the event's
    /// calendar, and an event on the timeline.
    ///
    /// What it deliberately does not produce: anything about *why* you met, how often, or what
    /// it means. Frequency across events is a pattern, and a pattern is an inference this
    /// extractor has no business making at `observed` authority.
    private func extractCalendarClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ events: inout [CoreEvent],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        guard let occurredAt = object.authoredAt else { return }

        let calendarName = object.metadata["calendar"] ?? "Calendar"
        // The calendar itself is the subject anchor: "Work" and "Family" are meaningfully
        // different contexts and worth being separate entities.
        let calendar = CoreEntity(kind: .concept, canonicalName: calendarName, domain: object.domain).id

        events.append(CoreEvent(
            subject: calendar,
            verb: "attended",
            detail: object.title,
            occurredAt: occurredAt,
            domain: object.domain,
            authority: object.authority
        ))

        // ASCII 31 separated, matching what the connector wrote. A comma would split names
        // containing one.
        let attendees = (object.metadata["attendees"] ?? "")
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }

        // Evidence only once there is a claim to attach it to. Creating it unconditionally
        // left 558 orphaned rows on the first run of this code: a solo calendar event
        // produces a timeline entry and no claims, so its evidence pointed at nothing.
        guard !attendees.isEmpty else { return }

        let item = Evidence(objectID: object.id, snippet: String(object.text.prefix(280)), authority: object.authority)
        evidence.append(item)

        for name in attendees {
            let person = CoreEntity(kind: .person, canonicalName: name, domain: .personal).id

            let attended = CoreClaim(
                subject: person,
                predicate: Predicate.attended,
                objectEntity: calendar,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: occurredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(attended)
            links.append((attended.id, item.id, .supports, 1.0))

            let met = CoreClaim(
                subject: calendar,
                predicate: Predicate.metWith,
                objectEntity: person,
                confidence: 0.9,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: occurredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(met)
            links.append((met.id, item.id, .supports, 1.0))

            events.append(CoreEvent(
                subject: person,
                verb: "met",
                detail: object.title,
                occurredAt: occurredAt,
                domain: object.domain,
                authority: object.authority
            ))
        }
    }

    // MARK: - Notes, reminders, local documents

    /// A timeline entry and nothing more.
    ///
    /// These are prose. Without a model there is no honest way to turn "buy milk" or a design
    /// note into a claim, and inventing one at `observed` authority would be worse than
    /// leaving the source claim-free: it would put a guess in the same table as a fact read
    /// out of structured data.
    private func extractTimelineEvent(_ object: CoreObject, into events: inout [CoreEvent]) async throws {
        guard let occurredAt = object.authoredAt else { return }

        // Group under the folder, list, or root that contains it, so a timeline reads as
        // "Medical, Projects, Work" rather than as a thousand unrelated titles.
        let container = object.metadata["folder"]
            ?? object.metadata["list"]
            ?? object.metadata["root"].map { ($0 as NSString).lastPathComponent }
            ?? object.kind.rawValue
        let subject = CoreEntity(kind: .concept, canonicalName: container, domain: object.domain).id

        let verb = switch object.kind {
        case .note: "noted"
        case .file: "edited"
        default: "wrote"
        }

        events.append(CoreEvent(
            subject: subject,
            verb: verb,
            detail: object.title,
            occurredAt: occurredAt,
            domain: object.domain,
            authority: object.authority
        ))
    }

    // MARK: - Commits

    private func extractCommitEvent(_ object: CoreObject, into events: inout [CoreEvent]) async throws {
        guard let repo = object.metadata["repo"], let occurredAt = object.authoredAt else { return }
        let bareName = repo.split(separator: "/").last.map(String.init) ?? repo
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        events.append(CoreEvent(
            subject: subject,
            verb: "committed",
            detail: object.title,
            occurredAt: occurredAt,
            domain: object.domain,
            authority: object.authority
        ))
    }
}
