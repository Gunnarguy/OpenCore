import CoreModel
import Foundation
import Testing
@testable import CoreReason

// Original bug: synthesizeGroundedBrief computed failed verdicts and nevertheless printed
// every sentence as a grounded supplement beneath an unrelated claim-answer receipt.
@Test("briefs suppress failed or nonexistent citations and preserve real object provenance")
func supplementalBriefRejectsBadCitations() throws {
    let source = GroundingSource(index: 1, title: "real passage", text: "The repository uses Swift and SQLite.", objectID: ObjectID("real-object"), authority: .authoredArtifact, uri: "file:///real/source")
    let brief = try #require(Conversation.checkedBrief(sentences: [("The repository uses Swift and SQLite.", 1), ("The repository uses Swift and SQLite.", 99), ("Oranges grow submarines tomorrow.", 1)], sources: [source], modelName: "fixture"))
    #expect(brief.verdicts.count == 1)
    #expect(brief.verdicts.allSatisfy { $0.isGrounded })
    #expect(!brief.text.contains("99")); #expect(!brief.text.contains("Oranges"))
    #expect(brief.sources.first?.objectID == source.objectID)
    #expect(Conversation.checkedBrief(sentences: [("The repository uses Swift.", nil)], sources: [source], modelName: "fixture") == nil)
}
