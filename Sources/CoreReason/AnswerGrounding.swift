import CoreModel
import CoreSearch
import CoreStore
import Foundation

extension Reasoner {
    /// Stable passage provenance shared by local answers, chat and acknowledged phone delivery.
    public static func passageEvidence(_ hits: [PassageHit]) -> [(Evidence, Double)] {
        hits.map { hit in
            (Evidence(objectID: hit.object.id, range: hit.chunk.range, snippet: hit.chunk.text,
                      authority: hit.object.authority, reading: "passage-citation:" + Digest.hex(hit.chunk.text)), hit.score)
        }
    }

    public static func linkedEvidence(_ claims: [(EvidenceID, Double)], passages: [(Evidence, Double)]) -> [(EvidenceID, Double)] {
        var seen = Set<EvidenceID>()
        return (claims + passages.map { ($0.0.id, $0.1) }).filter { seen.insert($0.0).inserted }
    }

    static func rankEvidenceIDs(_ ids: [EvidenceID]) -> [(EvidenceID, Double)] {
        var seen = Set<EvidenceID>()
        let rows = ids.filter { seen.insert($0).inserted }
        // Ordinal display position, not calibrated relevance or confidence.
        return rows.enumerated().map { ($0.element, 1 - Double($0.offset) / Double(rows.count)) }
    }

    struct ClaimSources {
        var sources: [GroundingSource] = []
        var claims: [ClaimID] = []
        var evidence: [Evidence] = []
        var contradictions = 0
    }

    /// One real claim per source, with its own authority and everything that qualifies it.
    /// Only admitted stored evidence is quoted. Operator snapshots never enter this path.
    func claimSources(from points: [AnswerPoint], policy: AdmissionPolicy) async throws -> ClaimSources {
        var result = ClaimSources()
        var surfaced = Set<ContradictionID>()
        var consulted = Set<ClaimID>()
        let touching = try await contradictions(touching: Set(points.flatMap { $0.claimRows + ($0.claimID.map { [$0] } ?? []) }), policy: policy)

        func quoted(_ text: String) -> String {
            String(text.replacingOccurrences(of: "\n", with: " ").prefix(Conversation.caveatLength))
        }

        for point in points {
            guard let primaryID = point.claimID, let primary = try await store.claim(primaryID),
                  try await ClaimAdmission.admits(primary, policy: policy, store: store) else { continue }
            let rows = Set(point.claimRows + [primaryID])
            var support: [Evidence] = []
            var counter: [Evidence] = []
            for id in rows.sorted(by: { $0.value < $1.value }) {
                guard let claim = try await store.claim(id),
                      try await ClaimAdmission.admits(claim, policy: policy, store: store) else { continue }
                consulted.insert(id)
                for (evidence, stance, _) in try await store.evidence(for: id) {
                    guard let object = try await store.object(evidence.objectID), policy.admits(object.domain) else { continue }
                    if stance == .supports { support.append(evidence) }
                    else if stance == .refutes { counter.append(evidence) }
                }
            }
            // Preserve the answer's support ordering, while resolving every row to stored text.
            let orderedSupport = point.supporting.compactMap { original in support.first { $0.id == original.id } }
            guard let evidence = orderedSupport.first else { continue }
            var represented: Set<ObjectID> = [evidence.objectID]
            result.evidence += orderedSupport
            var lines = [point.statement]
            if point.derivation == .inferred {
                lines.append("Inferred by OpenCore from other records. No source states this.")
            }
            for evidence in point.counter.compactMap({ original in counter.first { $0.id == original.id } }).prefix(Conversation.caveatsShown) {
                lines.append("Counter-evidence: \(quoted(evidence.snippet))")
                represented.insert(evidence.objectID)
                result.evidence.append(evidence)
            }
            let standing = touching.filter { Self.standsAgainst($0, rows: rows) }.sorted {
                ($0.resolution == .unresolved ? 0 : 1, $0.id.value) < ($1.resolution == .unresolved ? 0 : 1, $1.id.value)
            }
            for contradiction in standing.prefix(Conversation.caveatsShown) {
                let other = rows.contains(contradiction.claimA) ? contradiction.claimB : contradiction.claimA
                guard let rival = try await rivalStatement(in: contradiction, against: rows) else { continue }
                surfaced.insert(contradiction.id)
                consulted.insert(other)
                let label = contradiction.resolution == .unresolved ? "Open contradiction" : "Overruled"
                lines.append("\(label): \(rival) (\(quoted(contradiction.reason)))")
                for (support, _, _) in try await store.evidence(for: other, stance: .supports) {
                    if let object = try await store.object(support.objectID), policy.admits(object.domain) {
                        represented.insert(object.id)
                        result.evidence.append(support)
                        break
                    }
                }
            }
            let subject = try await store.entity(point.subject)?.canonicalName ?? point.subject.value
            result.sources.append(GroundingSource(index: result.sources.count + 1,
                title: subject + Conversation.claimTitleSuffix, text: lines.joined(separator: "\n"),
                objectID: evidence.objectID, authority: point.authority, claimID: primaryID,
                representedObjectIDs: represented.sorted { $0.value < $1.value }))
        }
        result.claims = consulted.sorted { $0.value < $1.value }
        result.contradictions = surfaced.count
        return result
    }

    public struct SupplementedAnswer: Sendable {
        public var answer: Answer
        public var brief: Conversation.GroundedBrief?
    }

    /// Automated system surfaces get model-facing admission and one retrieval/receipt.
    public func systemAnswer(_ query: String) async throws -> SupplementedAnswer {
        let answer = try await answer(query, externalCaller: true, persistReceipt: false)
        return try await supplement(answer) { question, sources in
            await Conversation.synthesizeBriefWithTrace(question: question, sources: sources)
        }
    }

    /// Injection keeps receipt and provenance regression tests independent of a real model.
    func supplement(_ original: Answer,
                    synthesize: @Sendable (String, [GroundingSource]) async -> Conversation.BriefSynthesis) async throws -> SupplementedAnswer {
        var answer = original
        try Task.checkCancellation()
        let start = DispatchTime.now().uptimeNanoseconds
        let policy = AdmissionPolicy.forQuestion(answer.receipt.query, externalCaller: true,
                                                 maximumDomains: Set(answer.receipt.domainsAdmitted))
        let claims = try await claimSources(from: Array(answer.points.prefix(Conversation.askedClaimsShown)), policy: policy)
        var sources = claims.sources
        for hit in answer.passages where sources.count < Conversation.sourceCount && policy.admits(hit.object.domain) {
            guard let object = try await store.object(hit.object.id), policy.admits(object.domain) else { continue }
            // Admission is current; provenance describes the reading actually retrieved.
            sources.append(GroundingSource(index: sources.count + 1, title: hit.object.title, text: hit.chunk.text,
                objectID: hit.object.id, authority: hit.object.authority, uri: hit.object.uri))
        }
        let synthesis = answer.counted == nil && !sources.isEmpty
            ? await synthesize(answer.receipt.query, sources)
            : Conversation.BriefSynthesis(outcome: "No supplemental writer requested.")
        let brief = synthesis.brief
        try Task.checkCancellation()
        answer.receipt.model = brief.flatMap { $0.modelName == "Deterministic Passage Synthesis" ? nil : $0.modelName }
        answer.receipt.stages.append(ReceiptStage(name: "grounded-supplement",
            counters: ["sources_supplied": sources.count, "sentences_returned": brief?.verdicts.count ?? 0,
                       "local_writer_requested": synthesis.requestedModel == nil ? 0 : 1],
            milliseconds: Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000),
            note: [synthesis.requestedModel, synthesis.outcome].compactMap { $0 }.joined(separator: ". ")))
        let passages = Self.passageEvidence(answer.passages)
        let evidence = Self.linkedEvidence(Self.rankedEvidence(answer.points) + Self.rankEvidenceIDs(claims.evidence.map(\.id)), passages: passages)
        let claimIDs = Set(answer.points.flatMap { $0.claimRows + ($0.claimID.map { [$0] } ?? []) } + claims.claims)
        answer.receipt.evidenceAdmitted = evidence.count
        answer.receipt.claimsConsulted = claimIDs.count
        try await store.save(answer.receipt, evidence: evidence, claims: claimIDs.sorted { $0.value < $1.value }, additionalEvidence: passages.map(\.0))
        return SupplementedAnswer(answer: answer, brief: brief)
    }
}
