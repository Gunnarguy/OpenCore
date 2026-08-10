import CoreModel
import Foundation

/// Checks that a generated sentence is actually answerable from the source it claims.
///
/// Two independent signals, deliberately kept apart because one is a guarantee and the other
/// is a guess:
///
/// 1. **Citation resolution** — structural, and the one with teeth. The model emits a typed
///    source number under a constrained range (`CitedSentence`), and this checks it against
///    the sources actually supplied. A sentence attributed to nothing, or to a source outside
///    the supplied set, fails outright. Constrained decoding makes this nearly always pass;
///    it is checked anyway, because "nearly" is not a guarantee and the receipt says it is.
///
/// 2. **Source overlap** — heuristic. What fraction of the sentence's content words appear in
///    *the specific source it cited*, rather than anywhere in the whole context. That change
///    matters: the previous version pooled all six sources into one haystack, so a sentence
///    fusing two unrelated passages scored perfectly.
///
/// **What overlap is not.** It is lexical, not entailment. It catches a sentence about
/// something absent from the cited source; it does not catch a sentence that inverts the
/// meaning of something present. A low score means "paraphrased, or unsupported" and this
/// test cannot tell you which. Report it as what it is.
///
/// **A correction to the previous design.** The instructions used to tell the model to prefer
/// the words in the sources *because the answer would be checked against them*. That coached
/// the model to pass this exact test, so a high score measured compliance rather than
/// grounding, which is why an answer about the wrong repository once scored 3 of 3. The
/// instruction is gone. Scores are lower now and mean more.
public struct Grounding: Sendable {
    /// Fraction of a sentence's content words that must appear in the cited source.
    ///
    /// 0.5 is chosen, not measured, and was lowered from 0.55 when the instruction that
    /// inflated the metric was removed: honest paraphrase scores lower than coached copying.
    /// Like every other constant here it is a candidate for the eval harness to replace.
    public static let overlapThreshold = 0.5

    /// Words that carry no evidence signal. Counting them would let a fluent sentence pass on
    /// grammar alone.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has", "had", "was", "were",
        "are", "you", "your", "which", "their", "there", "then", "than", "into", "over", "about",
        "been", "being", "would", "could", "should", "these", "those", "some", "also", "when",
        "what", "where", "while", "them", "they", "its", "it's", "but", "not", "can", "may",
    ]

    public struct Verdict: Sendable, Hashable, Codable {
        public let sentence: String
        /// The source number the model attributed this sentence to. `nil` when the answer was
        /// produced without typed citations, which on this path means generation failed part
        /// way through.
        public let citedSource: Int?
        /// Whether `citedSource` names a source that was actually supplied.
        public let citationResolves: Bool
        /// Fraction of content words present in the cited source.
        public let score: Double
        /// Content words that appear nowhere in the cited source. The specific reason a
        /// sentence failed, so a reader can judge the judgement.
        public let unsupported: [String]

        /// Both signals must hold. An unresolvable citation is a hard failure regardless of
        /// how well the words happen to overlap.
        public var isGrounded: Bool { citationResolves && score >= Grounding.overlapThreshold }

        public init(
            sentence: String,
            citedSource: Int?,
            citationResolves: Bool,
            score: Double,
            unsupported: [String]
        ) {
            self.sentence = sentence
            self.citedSource = citedSource
            self.citationResolves = citationResolves
            self.score = score
            self.unsupported = unsupported
        }
    }

    public init() {}

    /// Score one attributed sentence against the source it cited.
    ///
    /// `sources` is the set actually handed to the model, so an out-of-range citation is
    /// detectable here even though constrained decoding should have prevented it.
    public func verify(
        sentence: String,
        citedSource: Int?,
        sources: [GroundingSource]
    ) -> Verdict {
        guard let cited = citedSource, let source = sources.first(where: { $0.index == cited }) else {
            return Verdict(
                sentence: sentence,
                citedSource: citedSource,
                citationResolves: false,
                score: 0,
                unsupported: []
            )
        }

        let words = Self.contentWords(sentence)
        guard !words.isEmpty else {
            // Nothing to check. A sentence of pure connective words is vacuous rather than
            // ungrounded, and failing it would be noise.
            return Verdict(
                sentence: sentence,
                citedSource: cited,
                citationResolves: true,
                score: 1.0,
                unsupported: []
            )
        }

        let missing = words.subtracting(Self.contentWords(source.text))
        return Verdict(
            sentence: sentence,
            citedSource: cited,
            citationResolves: true,
            score: 1.0 - Double(missing.count) / Double(words.count),
            unsupported: missing.sorted()
        )
    }

    /// Score free text that carries no citations, against the pooled context.
    ///
    /// Only reachable when structured generation failed and the raw text was salvaged. Every
    /// verdict is marked as having no resolvable citation, because it genuinely has none, and
    /// so the whole answer reads as ungrounded. That is the correct outcome: text that lost
    /// its attribution should not be presented as sourced.
    public func verifyUnattributed(answer: String, against context: String) -> [Verdict] {
        let haystack = Self.contentWords(context)
        return Self.sentences(in: answer).map { sentence in
            let words = Self.contentWords(sentence)
            let missing = words.subtracting(haystack)
            let score = words.isEmpty ? 1.0 : 1.0 - Double(missing.count) / Double(words.count)
            return Verdict(
                sentence: sentence,
                citedSource: nil,
                citationResolves: false,
                score: score,
                unsupported: missing.sorted()
            )
        }
    }

    static func contentWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    /// Split on sentence terminators, keeping the terminator so the reassembled answer reads
    /// normally when it is displayed sentence by sentence.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 1 { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 1 { result.append(tail) }
        return result
    }
}
