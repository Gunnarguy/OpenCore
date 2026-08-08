import CoreGraph
import CoreModel
import CoreSearch
import CoreStore
import Foundation

/// A cited statement in an answer.
public struct AnswerPoint: Sendable {
    public var statement: String
    public var supporting: [Evidence]
    public var counter: [Evidence]
    public var confidence: Double
    public var authority: Authority
    public var derivation: Derivation
    public var claimID: ClaimID?
}

public struct Answer: Sendable {
    public var summary: String
    public var points: [AnswerPoint]
    public var contradictions: [Contradiction]
    public var receipt: Receipt
    /// Populated when the retrieval floor was reached and the honest response is
    /// "not enough evidence" rather than a fluent paragraph built from three weak hits.
    public var insufficientEvidence: String?
}

/// Plans a query, gathers evidence, and assembles an answer.
///
/// No model is involved. The answer is built from claims and their evidence, which means
/// every sentence has a row behind it and the receipt's counters are measurements rather
/// than estimates. A language model can be added later to write the prose — it would enter
/// at `Authority.modelInference` and would not be permitted to introduce a claim that is
/// not already in the store.
public struct Reasoner: Sendable {
    private let store: Store
    private let search: HybridSearch
    private let classifier = QueryClassifier()

    /// Below this blended score, a hit is noise. Named rather than inlined, because a
    /// silent relevance floor is how a system ends up answering confidently from nothing.
    public static let relevanceFloor = 0.15

    public init(store: Store, search: HybridSearch) {
        self.store = store
        self.search = search
    }

    /// - Parameter externalCaller: `true` when the query text was written by something
    ///   other than the user — an MCP client, an automation. Naming a sensitive domain in
    ///   a query is treated as consent when a person types it and as nothing at all when a
    ///   model generates it, so an external caller can neither unlock a sensitive domain
    ///   nor be classified into one.
    public func answer(_ query: String, limit: Int = 12, externalCaller: Bool = false) async throws -> Answer {
        let recorder = ReceiptRecorder()

        let classification = classifier.classify(query)
        let (rawDomain, requested) = AdmissionPolicy.classifyDomain(
            query,
            knownEntitySurfaces: try await store.aliasSurfaces()
        )
        let domain = (externalCaller && rawDomain.isSensitive) ? .project : rawDomain
        let policy = AdmissionPolicy(
            queryDomain: domain,
            explicitlyRequested: externalCaller ? [] : requested
        )

        let outcome = try await recorder.record(
            "retrieve",
            note: "query class \(classification.queryClass.rawValue) via \(classification.matchedOn)"
        ) {
            let result = try await search.search(
                query: query,
                queryClass: classification.queryClass,
                policy: policy,
                limit: limit
            )
            return (result, [
                "objects_searched": result.objectsSearched,
                "candidates": result.candidatesConsidered,
                "blocked_by_domain": result.blockedByDomain,
                "retrieved": result.hits.count,
            ])
        }

        let relevant = outcome.hits.filter { $0.score >= Self.relevanceFloor }

        let (points, claimIDs) = try await recorder.record("assemble-claims") {
            let assembled = try await assemble(hits: relevant, policy: policy)
            return (assembled, ["claims_consulted": assembled.1.count, "points": assembled.0.count])
        }

        let contradictions = try await recorder.record("check-contradictions") {
            let all = try await store.contradictions()
            let relevantOnes = all.filter { claimIDs.contains($0.claimA) || claimIDs.contains($0.claimB) }
            return (relevantOnes, ["surfaced": relevantOnes.count, "unresolved": relevantOnes.filter { $0.resolution == .unresolved }.count])
        }

        let evidenceCount = points.reduce(0) { $0 + $1.supporting.count + $1.counter.count }

        let receipt = Receipt(
            query: query,
            queryClass: classification.queryClass,
            domainsAdmitted: policy.admitted.sorted { $0.rawValue < $1.rawValue },
            domainsBlocked: policy.blocked.sorted { $0.rawValue < $1.rawValue },
            stages: await recorder.allStages(),
            objectsSearched: outcome.objectsSearched,
            objectsRetrieved: relevant.count,
            evidenceAdmitted: evidenceCount,
            claimsConsulted: claimIDs.count,
            contradictionsSurfaced: contradictions.count,
            // No model ran. Recorded as absent rather than as a plausible name.
            model: nil,
            objectsTransmitted: 0,
            // No calibrated confidence exists for this pipeline yet. It stays nil, and
            // renders as "not measured", until an eval harness produces a real number.
            confidence: nil
        )

        let rankedEvidence = points
            .flatMap(\.supporting)
            .enumerated()
            .map { ($0.element.id, 1.0 - Double($0.offset) / Double(max(1, points.count * 3))) }

        try await store.save(receipt, evidence: rankedEvidence, claims: Array(claimIDs))

        var insufficient: String?
        if relevant.isEmpty {
            insufficient = outcome.hits.isEmpty
                ? "Nothing in the corpus matched. \(outcome.objectsSearched) objects searched."
                : "\(outcome.hits.count) objects matched but none cleared the relevance floor of \(Self.relevanceFloor). Answering would mean inventing the connection."
        }

        return Answer(
            summary: summarise(points: points, query: query, classification: classification),
            points: points,
            contradictions: contradictions,
            receipt: receipt,
            insufficientEvidence: insufficient
        )
    }

    // MARK: - Assembly

    private func assemble(hits: [SearchHit], policy: AdmissionPolicy) async throws -> ([AnswerPoint], Set<ClaimID>) {
        // Which entities the retrieved objects are about.
        var subjects: Set<EntityID> = []
        for hit in hits {
            let bareName = hit.object.metadata["repo"]?.split(separator: "/").last.map(String.init)
                ?? hit.object.externalID.split(separator: "/").last.map(String.init)
            if let bareName {
                subjects.insert(CoreEntity(kind: .project, canonicalName: bareName, domain: hit.object.domain).id)
            }
        }

        var points: [AnswerPoint] = []
        var claimIDs: Set<ClaimID> = []

        for subject in subjects {
            guard let entity = try await store.entity(subject), policy.admits(entity.domain) else { continue }

            for claim in try await store.claims(subject: subject, currentOnly: true) {
                let supporting = try await store.evidence(for: claim.id, stance: .supports).map(\.0)
                let counter = try await store.evidence(for: claim.id, stance: .refutes).map(\.0)
                guard !supporting.isEmpty else { continue }

                claimIDs.insert(claim.id)
                points.append(AnswerPoint(
                    statement: await phrase(claim: claim, subject: entity),
                    supporting: supporting,
                    counter: counter,
                    confidence: claim.confidence,
                    authority: claim.authority,
                    derivation: claim.derivation,
                    claimID: claim.id
                ))
            }
        }

        points.sort { ($0.authority.rawValue, $0.confidence) > ($1.authority.rawValue, $1.confidence) }
        return (points, claimIDs)
    }

    /// Render a claim as English. Deliberately dull and templated: the phrasing carries no
    /// information the claim row does not, so there is nothing for a reader to over-read.
    private func phrase(claim: CoreClaim, subject: CoreEntity) async -> String {
        let objectText: String
        if let objectEntity = claim.objectEntity, let resolved = try? await store.entity(objectEntity) {
            objectText = resolved.canonicalName
        } else {
            objectText = claim.literal ?? "unknown"
        }

        return switch claim.predicate {
        case Predicate.primaryLanguage: "\(subject.canonicalName) is primarily written in \(objectText)."
        case Predicate.builtWith: "\(subject.canonicalName) is built with \(objectText)."
        case Predicate.status: "\(subject.canonicalName) is \(objectText)."
        case Predicate.dependsOn: "\(subject.canonicalName) depends on \(objectText)."
        case Predicate.uses: "\(subject.canonicalName) uses \(objectText)."
        default: "\(subject.canonicalName) \(claim.predicate.replacingOccurrences(of: "_", with: " ")) \(objectText)."
        }
    }

    private func summarise(points: [AnswerPoint], query: String, classification: QueryClassifier.Classification) -> String {
        guard !points.isEmpty else { return "No claims in the store bear on this question." }

        let observed = points.filter { $0.derivation == .observed }.count
        let inferred = points.filter { $0.derivation == .inferred }.count
        var summary = "\(points.count) claim\(points.count == 1 ? "" : "s") bear on this"
        if inferred > 0 {
            summary += ": \(observed) read directly from source data, \(inferred) inferred"
        }
        summary += "."
        return summary
    }
}
