import CoreModel
import Foundation

/// Sorts a question into the shape that determines its retrieval plan.
///
/// Rule-based, and it reports when it is guessing. Getting this wrong costs a bad weight
/// profile, not a wrong answer, so a transparent rule beats an opaque classifier here.
public struct QueryClassifier: Sendable {
    public init() {}

    public struct Classification: Sendable {
        public var queryClass: QueryClass
        public var confidence: Double
        public var matchedOn: String
    }

    private static let markers: [(QueryClass, [String])] = [
        // First on purpose. A counting question routinely carries another class's marker
        // ("how many projects use X *across* my repos" is also `.analytical`), and losing the
        // count to that match is what produces the failure this class exists to stop: the
        // model counting the six passages in front of it and reporting the total as fact.
        // Being first costs nothing against `.causal`, whose markers are disjoint from these:
        // "how come" contains no aggregate marker and still classifies as causal.
        (.aggregate, ["how many", "how much", "number of", "count of", "how often", "total number"]),
        (.causal, ["why", "what caused", "what led", "reason for", "because", "how come", "what made"]),
        (.differential, ["what changed", "what's new", "whats new", "since last", "diff", "this week", "recently changed"]),
        (.temporal, ["when", "what was i", "back in", "in march", "last year", "six months ago", "at the time", "history of"]),
        (.analytical, ["pattern", "across", "trend", "keep", "recurring", "common", "compare", "over time"]),
        (.epistemic, ["what do you know", "what do you believe", "how confident", "why do you think", "how sure", "what makes you"]),
    ]

    public func classify(_ query: String) -> Classification {
        let lowered = query.lowercased()

        for (queryClass, keywords) in Self.markers {
            if let matched = keywords.first(where: lowered.contains) {
                return Classification(queryClass: queryClass, confidence: 0.9, matchedOn: "'\(matched)'")
            }
        }
        return Classification(queryClass: .factual, confidence: 0.5, matchedOn: "no marker matched; defaulted to factual")
    }
}
