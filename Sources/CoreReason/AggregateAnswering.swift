import CoreModel
import CoreStore
import Foundation

/// Answers a counting question by computing over the whole store rather than over a window of
/// retrieved passages.
///
/// **The defect this exists for**, measured 2026-08-10: asked "how many of my apps are built
/// with Swift", the chat path retrieved six passages, the model counted the Swift ones among
/// those six, and answered **2** against a true **12**. Every stage worked as designed. The
/// receipt was valid, the citations were real, the grounding check passed, and the answer was
/// wrong by six times. That is the worst failure shape available to a system whose entire
/// claim is that its answers are auditable, because nothing in the output looks wrong.
///
/// The window is not a tunable here. `AnswerLimits.maximumSourceNumber` is welded to the
/// citation field of the guided-generation schema, so widening it to fit a corpus is not
/// available and would not be a fix if it were: the next question counts something larger.
///
/// So a count never goes to the model. It is a `GROUP BY` over every row, and the sentence is
/// assembled in code. Nothing here asks a model to paraphrase a number.
public struct AggregateAnswering: Sendable {
    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    /// Nouns that name a countable population, mapped to what they are stored as.
    ///
    /// Deliberately small, and an unrecognised noun declines instead of guessing. A wrong
    /// mapping does not fail loudly: it silently answers a different question than the one
    /// asked, which is the same class of defect this whole type exists to remove.
    private static let populations: [(terms: [String], kind: ObjectKind)] = [
        (["app", "apps", "application", "applications", "project", "projects",
          "repo", "repos", "repository", "repositories", "codebase", "codebases"], .repository),
        (["note", "notes", "reminder", "reminders", "todo", "todos", "task", "tasks"], .note),
        (["meeting", "meetings", "event", "events", "appointment", "appointments"], .calendarEvent),
        (["commit", "commits"], .commit),
        (["file", "files"], .file),
        (["document", "documents", "doc", "docs"], .document),
    ]

    /// Resolve and answer, or return `nil` to let the caller fall through to retrieval.
    ///
    /// Returning `nil` is a real outcome, not a failure path: "how often do I feel burnt out"
    /// is a counting question over something the store does not hold as a countable field, and
    /// passage retrieval is the honest way to approach it.
    ///
    /// `admitting` is the caller's `AdmissionPolicy.admitted` and is not optional. **A count is
    /// a disclosure.** Answering "14" to "how many appointments do I have with my cardiologist"
    /// discloses the thing the domain firewall exists to withhold, while retrieving zero
    /// passages and therefore tripping none of the checks that guard the passage path. This
    /// path has to enforce the same policy itself.
    public func answer(_ question: String, admitting: Set<Domain>) async throws -> AggregateAnswer? {
        let lowered = question.lowercased()

        guard let population = Self.populations.first(where: { population in
            population.terms.contains { lowered.containsWord($0) }
        }) else { return nil }

        let kind = population.kind
        let total = try await store.objectCount(kind: kind, domains: admitting)
        guard total > 0 else { return nil }

        // Find the facet the question is asking about by checking what the store actually
        // holds, rather than against a list of fields in code. "Swift" resolves to `language`,
        // "private" to `visibility`, "archived" to `archived`, and none of those three words
        // appears anywhere in this file. A connector that learns to record a new field makes
        // new questions answerable with no change here.
        //
        // Two shapes, because metadata comes in two shapes. For a field like `language` the
        // question names a **value** ("...built with Swift"). For a yes/no field like
        // `archived` the question names the **key**, and the value it means is `true`.
        for key in try await store.metadataKeys(kind: kind, domains: admitting) {
            let breakdown = try await store.objectCountsByMetadata(kind: kind, key: key, domains: admitting)

            if breakdown.isBoolean {
                guard Self.namesKey(key, in: lowered) else { continue }
                // Negation flips the bucket rather than being ignored. Ignoring it would answer
                // the exact opposite of the question with a confident number, which is the
                // failure mode this file exists to remove, reintroduced one level down.
                let negated = ["not", "aren't", "arent", "isn't", "isnt", "never", "yet"]
                    .contains { lowered.containsWord($0) }
                let bucket = negated ? "false" : "true"
                return AggregateAnswer(
                    breakdown: breakdown,
                    focus: negated ? "not \(Self.humanised(key))" : Self.humanised(key),
                    count: breakdown.count(matching: bucket),
                    matchedOn: "\(kind.rawValue).\(key) == \(bucket)"
                )
            }

            // Purely numeric values are skipped here: a bare number in a question ("how many of
            // my 3 apps...") is far more often incidental than a facet, and `stars` would
            // happily match it.
            if let match = breakdown.counts.first(where: {
                !$0.value.allSatisfy(\.isNumber) && lowered.containsWord($0.value.lowercased())
            }) {
                return AggregateAnswer(
                    breakdown: breakdown,
                    focus: match.value,
                    count: match.count,
                    matchedOn: "'\(match.value)' under \(kind.rawValue).\(key)"
                )
            }

            // The key itself was named but no particular value was: "what languages do I use"
            // wants the whole breakdown, not one bucket.
            if Self.namesKey(key, in: lowered) {
                return AggregateAnswer(
                    breakdown: breakdown, focus: nil, count: breakdown.total,
                    matchedOn: "\(kind.rawValue).\(key), whole breakdown"
                )
            }
        }

        // The population was recognised but no facet was.
        //
        // A bare "how many apps do I have" is a complete question and the total is its complete
        // answer. A question carrying a qualifier this resolver could not place is **not**, and
        // answering it with the total would silently substitute a different question for the one
        // asked. That is the same defect as counting six passages, so it declines instead and
        // lets retrieval try.
        let residue = lowered
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !Self.filler.contains($0) && !population.terms.contains($0) }
        guard residue.isEmpty else { return nil }

        return AggregateAnswer(
            breakdown: MetadataBreakdown(kind: kind, key: "", counts: [], total: total),
            focus: nil,
            count: total,
            matchedOn: "population '\(kind.rawValue)', no facet named"
        )
    }

    /// Words that carry no facet meaning, so what is left over is the part that would have to
    /// be understood before a total could honestly be reported.
    private static let filler: Set<String> = [
        "how", "many", "much", "number", "count", "total", "of", "do", "does", "did", "i",
        "have", "has", "my", "mine", "the", "a", "an", "any", "are", "is", "was", "were",
        "there", "in", "all", "got", "own",
    ]

    private static func humanised(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    /// Whether the question names this metadata key, by its raw name or its readable form.
    ///
    /// The trailing `s` is the whole of the pluralisation handled here, deliberately. Keys are
    /// connector-authored identifiers (`language`, `topics`, `all_day`), not arbitrary English,
    /// and a real stemmer would be a large dependency-free thing to maintain for the two forms
    /// that actually occur. A key this misses declines rather than answers wrongly.
    private static func namesKey(_ key: String, in lowered: String) -> Bool {
        [key, humanised(key)].contains {
            lowered.containsWord($0) || lowered.containsWord($0 + "s")
                || ($0.hasSuffix("s") && lowered.containsWord(String($0.dropLast())))
        }
    }
}

/// A counted answer and everything needed to state it without overclaiming.
public struct AggregateAnswer: Sendable, Hashable {
    public var breakdown: MetadataBreakdown
    /// The value the question named, when it named one. `nil` means it asked for the whole
    /// population, and `count` is that total.
    public var focus: String?
    public var count: Int
    public var matchedOn: String

    public init(breakdown: MetadataBreakdown, focus: String?, count: Int, matchedOn: String) {
        self.breakdown = breakdown
        self.focus = focus
        self.count = count
        self.matchedOn = matchedOn
    }

    /// The answer as a sentence, assembled in code.
    ///
    /// It carries its own denominator ("12 of 22") because a bare "12" invites the reader to
    /// supply a denominator themselves and they will supply the wrong one. Where objects
    /// carried no value for the field, that shortfall is stated rather than folded into the
    /// total: an unmeasured field is not a zero, and this is the one place a plausible-looking
    /// number would be indistinguishable from a measured one.
    public var sentence: String {
        let noun = breakdown.kind.plural

        // A yes/no field reads as a predicate, not as a category: "3 of 22 repositories are
        // archived", never "3 of 22 repositories — archived, the rest: false 19".
        if breakdown.isBoolean, let focus {
            return "\(count) of \(breakdown.total) \(noun) are \(focus)."
                + unaccountedClause.map { " " + $0 }.orEmpty
        }

        guard let focus else {
            // No particular value was named. With groups in hand the breakdown *is* the answer;
            // without them the population total is.
            guard !breakdown.counts.isEmpty else { return "\(count) \(noun)." }
            return "\(breakdown.total) \(noun), by \(breakdown.key):\n\n"
                + breakdown.counts.map { "  \($0.value) — \($0.count)" }.joined(separator: "\n")
                + unaccountedClause.map { "\n\n" + $0 }.orEmpty
        }

        var text = "\(count) of \(breakdown.total) \(noun) — \(focus)."
            + unaccountedClause.map { " " + $0 }.orEmpty
        let others = breakdown.counts.filter { $0.value != focus }
        if !others.isEmpty {
            text += "\n\nThe rest: " + others.map { "\($0.value) \($0.count)" }.joined(separator: ", ") + "."
        }
        return text
    }

    /// Objects the field was never recorded for, stated rather than folded into the total.
    ///
    /// This is the one place a plausible number would be indistinguishable from a measured one:
    /// silently counting "no value recorded" as "does not match" turns an absence of data into
    /// evidence of absence, and the resulting figure looks exactly as solid as a real one.
    private var unaccountedClause: String? {
        guard breakdown.unclassified > 0 else { return nil }
        let n = breakdown.unclassified
        return "\(n) recorded no \(breakdown.key), so \(n) " + (n == 1 ? "is" : "are")
            + " unaccounted for rather than counted as not matching."
    }
}

extension AggregateAnswer {
    /// The receipt for an answer that was counted rather than retrieved.
    ///
    /// Deliberately a different shape from the retrieval receipt, because claiming the
    /// retrieval shape here would be a lie in the exact place the counting fix exists to
    /// correct. `objectsRetrieved` and `evidenceAdmitted` are 0 and `model` is `nil` because no
    /// passage was read and no model was called: the number came from a `GROUP BY`. A reader
    /// who sees "6 sources, on-device model" on a count is looking at the old defect.
    ///
    /// Shared by every path that can produce a count, so the honesty of this shape cannot drift
    /// between chat and `ask`. Two copies is how one of them quietly starts reporting sources
    /// it never read.
    public func receipt(
        query: String,
        domainsAdmitted: [Domain],
        domainsBlocked: [Domain],
        milliseconds: Int
    ) -> Receipt {
        var counters = ["objectsCounted": breakdown.total, "groups": breakdown.counts.count]
        // Only present when there was something to be unaccounted for. A 0 here would read as
        // a measurement rather than as an absence of one.
        if breakdown.unclassified > 0 { counters["unclassified"] = breakdown.unclassified }
        return Receipt(
            query: query,
            queryClass: .aggregate,
            domainsAdmitted: domainsAdmitted,
            domainsBlocked: domainsBlocked,
            stages: [ReceiptStage(
                name: "count",
                counters: counters,
                milliseconds: milliseconds,
                note: "computed in SQL over every admitted row; matched on \(matchedOn)"
            )],
            objectsSearched: breakdown.total,
            objectsRetrieved: 0,
            evidenceAdmitted: 0,
            claimsConsulted: 0,
            contradictionsSurfaced: 0,
            model: nil,
            objectsTransmitted: 0,
            confidence: nil
        )
    }
}

extension ObjectKind {
    /// For counted prose. A count reads badly against a raw enum case.
    var plural: String {
        switch self {
        case .repository: "repositories"
        case .commit: "commits"
        case .note: "notes"
        case .calendarEvent: "calendar events"
        case .file: "files"
        case .document: "documents"
        default: "\(rawValue) objects"
        }
    }
}

extension String {
    /// Whole-word containment, so a two-letter language like `Go` does not match "going" and
    /// a question about apps does not match every object whose metadata says `app`.
    ///
    /// Values here can contain spaces (`Jupyter Notebook`), so this is a boundary check around
    /// a substring rather than a split on whitespace.
    func containsWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchStart = startIndex
        while let range = self.range(of: word, options: [.caseInsensitive], range: searchStart..<endIndex) {
            let beforeOK = range.lowerBound == startIndex
                || !self[index(before: range.lowerBound)].isLetterOrDigit
            let afterOK = range.upperBound == endIndex
                || !self[range.upperBound].isLetterOrDigit
            if beforeOK && afterOK { return true }
            searchStart = index(after: range.lowerBound)
            if searchStart >= endIndex { break }
        }
        return false
    }
}

extension Character {
    fileprivate var isLetterOrDigit: Bool { isLetter || isNumber }
}

extension Optional where Wrapped == String {
    fileprivate var orEmpty: String { self ?? "" }
}
