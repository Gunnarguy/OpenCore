import CoreModel
import Foundation
import Testing

@testable import CoreReason

/// The grounding path shipped with no tests at all, which is part of why its central flaw
/// went unnoticed: an answer about an entirely different repository reported "3 of 3
/// sentences supported".
///
/// Two causes, both covered here. The check pooled every supplied source into one haystack,
/// so a sentence could be scored against text it never claimed to come from; and citations
/// were `[n]` markers in prose rather than typed fields, so there was nothing to check a
/// sentence *against* in the first place.
@Suite("Grounding")
struct GroundingTests {
    static func source(_ index: Int, _ title: String, _ text: String) -> GroundingSource {
        GroundingSource(
            index: index,
            title: title,
            text: text,
            objectID: ObjectID("obj-\(index)"),
            authority: .authoredArtifact,
            uri: nil
        )
    }

    static let sources = [
        source(1, "OpenCore README", "OpenCore is an evidence-native store for personal history, written in Swift."),
        source(2, "WoWCA commit", "Rebranded the application and migrated the project to a Swift Package."),
    ]

    @Test("A sentence drawn from the source it cites is grounded")
    func citedSourceSupportsSentence() {
        let verdict = Grounding().verify(
            sentence: "OpenCore is an evidence-native store for personal history.",
            citedSource: 1,
            sources: Self.sources
        )
        #expect(verdict.citationResolves)
        #expect(verdict.score == 1.0)
        #expect(verdict.isGrounded)
        #expect(verdict.unsupported.isEmpty)
    }

    /// The original failure, reduced.
    ///
    /// This sentence is faithful to source 2 and cites source 1. Pooling both sources into one
    /// haystack scored it perfectly, which is exactly how prose about the wrong project passed
    /// the check. Scoring it against the source it actually cited fails it.
    @Test("A sentence may not borrow vocabulary from a source it did not cite")
    func vocabularyFromAnotherSourceDoesNotCount() {
        let verdict = Grounding().verify(
            sentence: "Rebranded the application and migrated to a Swift Package.",
            citedSource: 1,
            sources: Self.sources
        )
        #expect(verdict.citationResolves)
        #expect(!verdict.isGrounded)
        #expect(verdict.unsupported.contains("rebranded"))
        #expect(verdict.unsupported.contains("migrated"))

        // Pooling is what used to happen, and it is what made the sentence look supported.
        let pooled = Grounding().verifyUnattributed(
            answer: "Rebranded the application and migrated to a Swift Package.",
            against: Self.sources.map(\.text).joined(separator: "\n")
        )
        #expect(pooled.count == 1)
        #expect(pooled[0].score == 1.0)
    }

    @Test("A citation naming a source that was never supplied fails outright")
    func unresolvableCitationFails() {
        let verdict = Grounding().verify(
            sentence: "OpenCore is an evidence-native store for personal history.",
            citedSource: 9,
            sources: Self.sources
        )
        #expect(!verdict.citationResolves)
        #expect(!verdict.isGrounded)
        // Word-for-word from source 1, and still ungrounded: an unresolvable citation is a
        // hard failure, not something high overlap can rescue.
        #expect(verdict.score == 0)
    }

    @Test("A sentence with no citation is never grounded")
    func missingCitationFails() {
        let verdict = Grounding().verify(
            sentence: "OpenCore is an evidence-native store for personal history.",
            citedSource: nil,
            sources: Self.sources
        )
        #expect(!verdict.citationResolves)
        #expect(!verdict.isGrounded)
    }

    @Test("Text salvaged without attribution reads as ungrounded")
    func unattributedTextIsNeverGrounded() {
        let verdicts = Grounding().verifyUnattributed(
            answer: "OpenCore is an evidence-native store.",
            against: Self.sources.map(\.text).joined(separator: "\n")
        )
        #expect(verdicts.count == 1)
        // Perfect overlap, no citation, so it must not present as sourced.
        #expect(verdicts[0].score == 1.0)
        #expect(!verdicts[0].isGrounded)
    }

    @Test("A sentence of pure connective words is vacuous rather than ungrounded")
    func connectiveOnlySentencePasses() {
        let verdict = Grounding().verify(
            sentence: "But then, what of it?",
            citedSource: 1,
            sources: Self.sources
        )
        #expect(verdict.score == 1.0)
        #expect(verdict.isGrounded)
    }
}

@Suite("Answer rendering")
struct AnswerRenderingTests {
    @Test("Citation markers are produced from typed fields, not parsed from prose")
    func renderEmitsMarkers() {
        let rendered = Conversation.render([
            (text: "OpenCore stores objects.", source: 1),
            (text: "It runs no model of its own.", source: 3),
        ])
        #expect(rendered == "OpenCore stores objects. [1] It runs no model of its own. [3]")
    }

    @Test("A sentence that arrived without a source number carries no marker")
    func renderOmitsMissingSource() {
        let rendered = Conversation.render([(text: "Partial sentence.", source: nil)])
        #expect(rendered == "Partial sentence.")
    }

    /// The generation schema constrains the citation field to `1...maximumSourceNumber`, so
    /// this constant and `Conversation.sourceCount` drifting apart would let retrieval supply
    /// a source the model is forbidden to cite.
    @Test("The citation range covers every source retrieval may supply")
    func citationRangeMatchesSourceCount() {
        #expect(Conversation.sourceCount == AnswerLimits.maximumSourceNumber)
    }
}
