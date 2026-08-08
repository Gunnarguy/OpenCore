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
