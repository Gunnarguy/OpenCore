import CoreModel
import CoreSearch
import CoreStore
import Foundation

/// What a question is about: the entities it names and the predicates it asks after.
///
/// Rule-based on purpose. It decides what an answer reads as well as how the answer is ordered:
/// a named entity replaces the subjects retrieval would have pulled in, opens
/// `Store.claims(pointingAt:)`, and picks the claims chat hands its model.
///
/// So this is a read route, and the firewall holds because of checks on that route rather than
/// because focus cannot reach a row. Names resolve through the same caller-appropriate lookup as
/// `core_claims`, an entity in a domain the policy does not admit is dropped here, and every
/// claim read because of focus still passes `Reasoner.isClaimAdmitted`. Lines are rendered from
/// rows, so focus can narrow an answer but cannot make it say something the store does not hold.
struct QueryFocus: Sendable {
    var entities: [EntityID]
    /// Most direct first: the order the question's words came in, and within one word the order
    /// `predicateWords` lists. "Is OpenCore active" asks for `status`, and `objective` is only a
    /// relative of that, so the two must not tie.
    var predicates: [String]
    /// The question's words that went on `entities`. "What did I change in OpenClinic last week"
    /// has no topic once its name is accounted for, which is what makes it a question about
    /// events and not a search for the word "openclinic". A word spent on a name this dropped
    /// does not count: "swift" in "what did I do in Swift last week" is still its topic.
    var namedWords: Set<String> = []

    static let none = QueryFocus(entities: [], predicates: [])

    func names(_ entity: EntityID) -> Bool { entities.contains(entity) }
    func asks(_ predicate: String) -> Bool { predicates.contains(predicate) }

    /// How directly the question asks for `predicate`. Higher is more direct, 0 is not asked.
    func askRank(_ predicate: String) -> Int {
        predicates.firstIndex(of: predicate).map { predicates.count - $0 } ?? 0
    }

    /// Query words and the predicates they ask about. **Chosen, not measured:** the phrasing is
    /// what the store's own predicates would be asked with, and no question log exists to test
    /// it against.
    ///
    /// `status` also reaches `objective` and `next_action` because a project's state, as its
    /// owner wrote it down, lives there. `status` itself only says active or dormant.
    static let predicateWords: [(words: [String], predicates: [String])] = [
        (["status", "state", "active", "dormant", "archived", "maintained", "alive", "doing"],
         [Predicate.status, Predicate.objective, Predicate.nextAction]),
        (["language", "languages", "written"], [Predicate.primaryLanguage, Predicate.builtWith]),
        (["built", "stack", "framework", "frameworks", "technology", "technologies", "tech"], [Predicate.builtWith, Predicate.uses]),
        (["depends", "dependency", "dependencies", "requires"], [Predicate.dependsOn]),
        (["uses", "use", "using"], [Predicate.uses, Predicate.builtWith]),
        (["objective", "goal", "goals", "focus", "purpose", "plan"], [Predicate.objective]),
        (["next", "todo"], [Predicate.nextAction]),
        (["verified", "commit", "commits"], [Predicate.lastVerifiedCommit]),
        (["verify", "test", "tests", "command"], [Predicate.verifyCommand]),
        (["describe", "description", "summary", "overview", "about"], [Predicate.describes]),
        (["components", "modules", "parts", "structure"], [Predicate.hasComponent]),
        (["contributors", "contributed", "authors", "author"], [Predicate.contributedTo, Predicate.authoredBy]),
        (["met", "meet", "attended"], [Predicate.metWith, Predicate.attended]),
    ]

    /// The longest name a query is scanned for, in words. **Chosen, not measured:** the longest
    /// name known to be worth finding is three words ("Local Automation Hub"), and each extra
    /// word adds one more alias lookup per position in the question.
    private static let longestName = 3

    /// What a technology can be the value of. **Chosen, not measured:** the first three are every
    /// predicate holding a technology on the real store on 2026-10-31 (`built_with` 225,
    /// `primary_language` 30, `uses` 1), and "what depends on X" asks the same kind of thing.
    ///
    /// A technology is the subject of nothing, so naming one only makes sense when the question
    /// asks what points at it. Swift is the topic of "which projects use Swift" and merely a
    /// word in "why did the swift build fail". Letting the second through replaced the
    /// repositories its passages were about with every repository written in Swift.
    private static let predicatesReachingTechnology: Set<String> = [
        Predicate.primaryLanguage, Predicate.builtWith, Predicate.uses, Predicate.dependsOn,
    ]

    /// The words of a query as names are written. `HybridSearch.ftsTerms` is not this: it splits
    /// on punctuation, so "node.js" and "c++" reach it as "node", "js" and "c".
    static func words(in query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && !"-_.+#".contains($0) })
            .map { word in
                var name = word
                // A sentence's full stop is not part of a name, and neither is an ellipsis or a
                // hashtag. One leading dot stays, because that is how ".net" is spelled.
                while name.hasSuffix(".") { name.removeLast() }
                if name.hasPrefix("..") { name = name.drop { $0 == "." } }
                return String(name.drop { $0 == "+" || $0 == "#" })
            }
            .filter { !$0.isEmpty }
    }

    static func read(
        from query: String,
        store: Store,
        policy: AdmissionPolicy,
        externalCaller: Bool
    ) async throws -> QueryFocus {
        let tokens = words(in: query)

        var found: [EntityID] = []
        var technologies = Set<EntityID>()
        var consumed = Set<Int>()
        var wordsNaming: [EntityID: Set<String>] = [:]
        for length in stride(from: longestName, through: 1, by: -1) where tokens.count >= length {
            for start in 0...(tokens.count - length) {
                let span = Array(start..<(start + length))
                guard consumed.isDisjoint(with: span) else { continue }
                // A single word must be a content word. A repository named "work" should not
                // turn every question containing that word into a question about it.
                if length == 1, HybridSearch.isStopword(tokens[start]) || HybridSearch.framingWords.contains(tokens[start]) { continue }
                let surface = span.map { tokens[$0] }.joined(separator: " ")
                let matches = externalCaller
                    ? try await store.resolveForExternalCaller(surface: surface)
                    : try await store.resolve(surface: surface)
                // A concept is not something a question names. They come from commit scopes, so
                // "sync", "changes", "general" and "graph" are all entities: 167 of them on the
                // real store, 1 with a claim of its own, measured 2026-10-31. Treating one as the
                // subject turned "how does graph retrieval work" into a question about nothing.
                let isLetter = length == 1 && tokens[start].count == 1
                let admitted = matches.map(\.0).filter { entity in
                    // One letter names only a language: C and R are real answers, and a project
                    // called "x" should not capture "plan x".
                    entity.kind != .concept && policy.admits(entity.domain) && (!isLetter || entity.kind == .technology)
                }
                guard !admitted.isEmpty else { continue }
                consumed.formUnion(span)
                for entity in admitted {
                    wordsNaming[entity.id, default: []].formUnion(span.map { tokens[$0] })
                    guard !found.contains(entity.id) else { continue }
                    found.append(entity.id)
                    if entity.kind == .technology { technologies.insert(entity.id) }
                }
            }
        }

        // Words spent on a name are not also asking about a predicate: a project called
        // Status should not read as a status question.
        let remaining = tokens.indices.filter { !consumed.contains($0) }.map { tokens[$0] }
        var predicates: [String] = []
        for word in remaining {
            for (words, mapped) in predicateWords where words.contains(word) {
                predicates += mapped.filter { !predicates.contains($0) }
            }
        }
        let asksWhatPoints = predicates.contains(where: predicatesReachingTechnology.contains)
        let entities = asksWhatPoints ? found : found.filter { !technologies.contains($0) }
        return QueryFocus(
            entities: entities,
            predicates: predicates,
            namedWords: entities.reduce(into: []) { $0.formUnion(wordsNaming[$1] ?? []) }
        )
    }
}
