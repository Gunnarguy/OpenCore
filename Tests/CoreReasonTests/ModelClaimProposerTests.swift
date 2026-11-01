import CoreGraph
import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreReason

@Test("A fabricated model quote cannot be rescued by a source line mentioning its value")
func fabricatedQuoteCannotBorrowAnUnrelatedLine() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("opencore-proposer-\(UUID().uuidString).sqlite3")
    let store = try await Store.open(at: path)
    let source = Source(kind: .filesystem, handle: "proposer-regression", displayName: "Regression",
                        defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let object = CoreObject(
        sourceID: source.id, kind: .note, externalID: "quote-regression",
        title: "ProjectA policy", text: "Do not use Redis.\nProjectA is written in Swift.",
        domain: .project, authority: .authoredArtifact
    )
    _ = try await store.ingest([object])
    // The old proposer substituted "Do not use Redis" for a hallucinated positive claim.
    let fabricated = ProposedClaimRecord(
        subject: "ProjectA", subjectKind: .project, predicate: Predicate.uses,
        value: "Redis", valueKind: .technology, verbatimQuote: "ProjectA uses Redis", confidence: 0.9
    )
    let accepted = ProposedClaimRecord(
        subject: "ProjectA", subjectKind: .project, predicate: Predicate.primaryLanguage,
        value: "Swift", valueKind: nil, verbatimQuote: "ProjectA is written in Swift.", confidence: 0.8
    )
    let result = try await ModelClaimProposer(store: store)
        .propose(from: object, customCandidates: [fabricated, accepted])
    #expect(result.rejectedUnverifiedSpan == 1)
    #expect(result.verifiedProposals.contains { $0.value == "Swift" })
    #expect(!result.verifiedProposals.contains { $0.value == "Redis" })
    let persisted = try await store.object(object.id)
    #expect(!ClaimExtractor.decodedModelProposals(from: try #require(persisted)).contains { $0.value == "Redis" })
}
