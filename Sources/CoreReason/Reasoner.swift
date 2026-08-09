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
    /// The passages retrieval actually surfaced.
    ///
    /// Carried alongside the claims because the two answer different questions. A claim says
    /// what the store believes; a passage shows the text it was believed from, including for
    /// sources that produce no claims at all. Without this, asking about a calendar event
    /// returned nothing even though the event was sitting in the index.
    public var passages: [PassageHit]
    public var contradictions: [Contradiction]
    public var receipt: Receipt
    public var insufficientEvidence: String?
}

/// Plans a query, gathers evidence, and assembles an answer.
///
/// Runs on `PassageSearch`: both retrieval legs, RRF fusion, MMR. It previously used the
/// object-level `HybridSearch`, which meant the app built embeddings it then never searched
/// and the whole dense path was unreachable from the primary surface.
///
/// No model is involved. Claims are rendered from rows, and passages are quoted verbatim, so
/// every line has something behind it and the receipt's counters are measurements. A language
/// model can be added later to write the prose; it would enter at `Authority.modelInference`
/// and would not be permitted to introduce a claim that is not already in the store.
public struct Reasoner: Sendable {
    private let store: Store
    private let search: PassageSearch
    private let classifier = QueryClassifier()

    /// Below this blended score a hit is noise. Named rather than inlined, because a silent
    /// relevance floor is how a system ends up answering confidently from nothing.
    ///
    /// Tuned for RRF output, which is small: a single-leg top hit contributes ~0.016 and
    /// appearing at the top of both contributes ~0.033. The object-level scorer this replaced
    /// produced 0...1 scores and used 0.15, which would have rejected everything here.
    public static let relevanceFloor = 0.005

    public init(store: Store, search: PassageSearch) {
        self.store = store
        self.search = search
    }

    /// Convenience for callers that have not built a `PassageSearch` themselves.
    public init(store: Store, embedder: (any EmbeddingProvider)? = nil, tuning: RetrievalTuning = .default) {
        self.init(store: store, search: PassageSearch(store: store, embedder: embedder, tuning: tuning))
    }

    /// - Parameter externalCaller: `true` when the query text was written by something other
    ///   than the user. Naming a sensitive domain is consent when a person types it and
    ///   nothing at all when a model generates it, so an external caller can neither unlock a
    ///   sensitive domain nor be classified into one.
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
            note: "\(classification.queryClass.rawValue) via \(classification.matchedOn)"
        ) {
            let result = try await search.search(
                query: query,
                queryClass: classification.queryClass,
                policy: policy,
                limit: limit
            )
            return (result, [
                "chunks_searched": result.chunksSearched,
                "lexical": result.lexicalCandidates,
                "dense": result.denseCandidates,
                "fused": result.afterFusion,
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
            let touching = all.filter { claimIDs.contains($0.claimA) || claimIDs.contains($0.claimB) }
            return (touching, ["surfaced": touching.count, "unresolved": touching.filter { $0.resolution == .unresolved }.count])
        }

        let evidenceCount = points.reduce(0) { $0 + $1.supporting.count + $1.counter.count }

        let receipt = Receipt(
            query: query,
            queryClass: classification.queryClass,
            domainsAdmitted: policy.admitted.sorted { $0.rawValue < $1.rawValue },
            domainsBlocked: policy.blocked.sorted { $0.rawValue < $1.rawValue },
            stages: await recorder.allStages(),
            objectsSearched: outcome.chunksSearched,
            objectsRetrieved: relevant.count,
            evidenceAdmitted: evidenceCount,
            claimsConsulted: claimIDs.count,
            contradictionsSurfaced: contradictions.count,
            // No model ran. Recorded as absent rather than as a plausible name.
            model: nil,
            objectsTransmitted: 0,
            // No calibrated confidence exists for this pipeline. Stays nil, renders as
            // "not measured", until an eval harness produces a real number.
            confidence: nil
        )

        let rankedEvidence = points
            .flatMap(\.supporting)
            .enumerated()
            .map { ($0.element.id, 1.0 - Double($0.offset) / Double(max(1, points.count * 3))) }

        try await store.save(receipt, evidence: rankedEvidence, claims: Array(claimIDs))

        var insufficient: String?
        if relevant.isEmpty && points.isEmpty {
            insufficient = outcome.hits.isEmpty
                ? "Nothing matched. \(outcome.chunksSearched) passages searched."
                : "\(outcome.hits.count) passages matched but none cleared the relevance floor of \(Self.relevanceFloor)."
            if outcome.blockedByDomain > 0 {
                insufficient! += " \(outcome.blockedByDomain) were withheld by domain policy."
            }
        }

        return Answer(
            summary: summarise(points: points, passages: relevant, outcome: outcome),
            points: points,
            passages: relevant,
            contradictions: contradictions,
            receipt: receipt,
            insufficientEvidence: insufficient
        )
    }

    // MARK: - Assembly

    private func assemble(hits: [PassageHit], policy: AdmissionPolicy) async throws -> ([AnswerPoint], Set<ClaimID>) {
        // Entities the retrieved passages are about. Repo metadata first, then the object's
        // own external id, then the title, so a calendar event or a note resolves too rather
        // than only a GitHub object.
        var subjects: Set<EntityID> = []
        for hit in hits {
            for surface in Self.candidateSurfaces(for: hit.object) {
                for (entity, _) in try await store.resolve(surface: surface) where policy.admits(entity.domain) {
                    subjects.insert(entity.id)
                }
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

    /// Names worth trying against the entity index for one object.
    static func candidateSurfaces(for object: CoreObject) -> [String] {
        var surfaces: [String] = []
        if let repo = object.metadata["repo"] {
            surfaces.append(repo)
            if let bare = repo.split(separator: "/").last { surfaces.append(String(bare)) }
        }
        surfaces.append(object.externalID)
        if let bare = object.externalID.split(separator: "/").last { surfaces.append(String(bare)) }
        if let calendar = object.metadata["calendar"] { surfaces.append(calendar) }
        if let folder = object.metadata["folder"] { surfaces.append(folder) }
        surfaces.append(object.title)
        return surfaces.filter { $0.count > 2 }
    }

    /// Render a claim as English. Deliberately dull and templated: the phrasing carries no
    /// information the row does not, so there is nothing for a reader to over-read.
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
        case Predicate.metWith: "\(subject.canonicalName) met with \(objectText)."
        case Predicate.attended: "\(subject.canonicalName) attended \(objectText)."
        case Predicate.partOf: "\(subject.canonicalName) is part of \(objectText)."
        default: "\(subject.canonicalName) \(claim.predicate.replacingOccurrences(of: "_", with: " ")) \(objectText)."
        }
    }

    private func summarise(points: [AnswerPoint], passages: [PassageHit], outcome: PassageOutcome) -> String {
        if points.isEmpty && !passages.isEmpty {
            // The honest case for a source that produces no claims: there is text, and the
            // store has concluded nothing from it. Saying so beats saying nothing.
            return "\(passages.count) passage\(passages.count == 1 ? "" : "s") match. No claims have been derived from them."
        }
        guard !points.isEmpty else { return "No claims in the store bear on this question." }

        let observed = points.filter { $0.derivation == .observed }.count
        let inferred = points.filter { $0.derivation == .inferred }.count
        var summary = "\(points.count) claim\(points.count == 1 ? "" : "s") bear on this"
        if inferred > 0 { summary += ": \(observed) read directly from source data, \(inferred) inferred" }
        summary += ", from \(passages.count) matching passage\(passages.count == 1 ? "" : "s")."
        return summary
    }
}
