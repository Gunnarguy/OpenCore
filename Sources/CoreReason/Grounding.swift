import CoreModel
import Foundation

/// Checks that a generated sentence is actually supported by the text it was given.
///
/// This is the gate `DECISIONS.md` said becomes mandatory the moment a model writes prose.
/// Until now every sentence OpenCore produced was rendered from a claim row, so provenance
/// was structural. A model can write a fluent sentence about nothing, and a receipt that says
/// "assembled from claims" while displaying that sentence would be lying about the answer's
/// origin.
///
/// **What this is not.** It is lexical overlap, not entailment. It catches a sentence about
/// something absent from the context; it does not catch a sentence that inverts the meaning of
/// something present. That limit is real and is reported rather than papered over: a passing
/// grade here means "the words came from your data", not "this is true".
public struct Grounding: Sendable {
    /// Fraction of a sentence's content words that must appear in the supplied context.
    ///
    /// 0.55 is chosen, not measured. It tolerates the connective words a model adds while
    /// rejecting a sentence built mostly from vocabulary that is not in the evidence. Like
    /// every other constant here it is a candidate for the eval harness to replace.
    public static let threshold = 0.55

    /// Words that carry no evidence signal. Counting them would let a fluent sentence pass on
    /// grammar alone.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has", "had", "was", "were",
        "are", "you", "your", "which", "their", "there", "then", "than", "into", "over", "about",
        "been", "being", "would", "could", "should", "these", "those", "some", "also", "when",
        "what", "where", "while", "them", "they", "its", "it's", "but", "not", "can", "may",
    ]

    public struct Verdict: Sendable, Hashable {
        public let sentence: String
        public let score: Double
        public var isGrounded: Bool { score >= Grounding.threshold }
        /// Content words that appear nowhere in the context. The specific reason a sentence
        /// failed, so a reader can judge the judgement.
        public let unsupported: [String]
    }

    public init() {}

    /// Score every sentence of `answer` against `context`.
    public func verify(answer: String, against context: String) -> [Verdict] {
        let haystack = Self.contentWords(context)
        return Self.sentences(in: answer).map { sentence in
            let words = Self.contentWords(sentence)
            guard !words.isEmpty else {
                // Nothing to check. A sentence of pure connective words is vacuous rather
                // than ungrounded, and failing it would be noise.
                return Verdict(sentence: sentence, score: 1.0, unsupported: [])
            }
            let missing = words.subtracting(haystack)
            let score = 1.0 - Double(missing.count) / Double(words.count)
            return Verdict(sentence: sentence, score: score, unsupported: missing.sorted())
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
