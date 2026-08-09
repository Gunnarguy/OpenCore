import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Ceiling on how many sources a single answer may be shown, and therefore the largest
/// citation number the model is permitted to emit.
///
/// This must stay equal to `Conversation.sourceCount`. It is spelled as a literal in the
/// `@Guide` below because a guide is baked into the generation schema, and `Conversation`
/// validates every citation against the sources actually supplied, so a drift between the two
/// degrades to a rejected citation rather than a wrong one.
enum AnswerLimits {
    static let maximumSourceNumber = 6
    /// Chosen, not measured. Long answers over six passages are where the model starts
    /// stitching unrelated sources into a narrative, which is the failure this design exists
    /// to make visible.
    static let maximumSentences = 5
}

#if canImport(FoundationModels)

/// The shape an answer must take.
///
/// This is the load-bearing change over asking for `[2]` markers in prose. A citation is no
/// longer a substring the model was asked politely to include and that we hope to parse back
/// out. It is a typed field with a constrained range, so constrained decoding makes an answer
/// that cites nothing, or cites source 9 of 6, *unrepresentable* rather than merely unlikely.
///
/// What this still cannot do: it constrains where the model says a sentence came from, not
/// whether the sentence is true to that source. `Grounding` handles the second question, and
/// is honest about being a heuristic.
@available(macOS 26.0, *)
@Generable(description: """
    An answer about one person's own recorded history, written only from the numbered sources \
    supplied with the question.
    """)
struct GroundedAnswer {
    @Guide(description: """
        True when the supplied sources do not contain enough to answer the question. \
        When true, give no sentences at all.
        """)
    var insufficient: Bool

    @Guide(
        description: """
            The answer. One complete sentence per element, each attributed to the single \
            source it came from. Three or fewer is usually right.
            """,
        .maximumCount(AnswerLimits.maximumSentences)
    )
    var sentences: [CitedSentence]
}

/// One sentence, and the source it is answerable from.
@available(macOS 26.0, *)
@Generable(description: "A single sentence of an answer, with the source it came from.")
struct CitedSentence {
    @Guide(description: """
        One complete sentence stating something the cited source says. No speculation, and no \
        information from outside the sources.
        """)
    var text: String

    @Guide(
        description: "The number of the source this sentence is drawn from.",
        .range(1...AnswerLimits.maximumSourceNumber)
    )
    var source: Int
}

#endif
