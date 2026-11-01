import CoreModel
import CoreStore
import Foundation

public struct SearchHit: Sendable {
    public var object: CoreObject
    public var score: Double
    /// Per-signal contributions, kept so a result can explain its own rank instead of
    /// arriving as an unexplained number.
    public var signals: [String: Double]

    public init(object: CoreObject, score: Double, signals: [String: Double]) {
        self.object = object
        self.score = score
        self.signals = signals
    }
}

public struct SearchOutcome: Sendable {
    public var hits: [SearchHit]
    public var objectsSearched: Int
    public var candidatesConsidered: Int
    public var blockedByDomain: Int
    /// Signals that did not run this query and why, so a missing contribution is visible
    /// rather than silently scoring zero.
    public var unavailableSignals: [String: String]
}

/// Lexical + temporal + authority + graph scoring over objects, weighted by query class.
///
/// The semantic signal is optional and its absence is reported rather than defaulted. A
/// hybrid searcher that scores 0 for a signal it never computed produces the same number
/// as one that computed it and found nothing, and those are not the same result.
public struct HybridSearch: Sendable {
    private let store: Store
    private let embedder: (any EmbeddingProvider)?

    public init(store: Store, embedder: (any EmbeddingProvider)? = nil) {
        self.store = store
        self.embedder = embedder
    }

    public func search(
        query: String,
        queryClass: QueryClass,
        policy: AdmissionPolicy,
        limit: Int = 20,
        candidateLimit: Int = 200
    ) async throws -> SearchOutcome {
        let weights = queryClass.weights
        let totalObjects = try await store.objectCount()

        var unavailable: [String: String] = [:]
        if embedder == nil {
            unavailable["semantic"] = "no embedding provider configured; lexical and graph signals carry this query"
        }

        let candidates = try await lexicalCandidates(query: query, limit: candidateLimit)
        let blocked = candidates.filter { !policy.admits($0.0.domain) }.count
        let admitted = candidates.filter { policy.admits($0.0.domain) }

        // Graph proximity: entities the query names pull their neighbourhood up.
        let anchors = try await anchorEntities(in: query)
        var proximity: [EntityID: Int] = [:]
        for anchor in anchors {
            for (entity, hops) in try await store.neighbourhood(of: anchor, hops: 2) {
                proximity[entity] = min(proximity[entity] ?? Int.max, hops)
            }
        }
        if anchors.isEmpty {
            unavailable["graph"] = "no known entity named in the query"
        }

        let now = Date()
        var hits: [SearchHit] = []

        for (object, bm25) in admitted {
            var signals: [String: Double] = [:]

            // FTS5 bm25() is negative, better matches more negative. Map to 0...1 with a
            // soft curve so one outlier cannot dominate the blend.
            let lexical = 1.0 - (1.0 / (1.0 + max(0, -bm25)))
            signals["lexical"] = lexical

            let temporal: Double
            if let authoredAt = object.authoredAt {
                let ageInDays = max(0, now.timeIntervalSince(authoredAt) / 86_400)
                // Half-life of one year. Old is not wrong, only less likely to be what
                // "recently" or "now" means.
                temporal = pow(0.5, ageInDays / 365.0)
            } else {
                temporal = 0
            }
            signals["temporal"] = temporal

            // Authority tier normalised to 0...1 *for blending only*. It is never
            // multiplied into confidence, and the raw tier stays on the row.
            let authority = Double(object.authority.rawValue) / Double(Authority.directStatement.rawValue)
            signals["authority"] = authority

            var graph = 0.0
            if !proximity.isEmpty {
                let bareName = object.metadata["repo"]?.split(separator: "/").last.map(String.init)
                    ?? object.externalID.split(separator: "/").last.map(String.init)
                if let bareName {
                    let entity = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id
                    if let hops = proximity[entity] {
                        graph = hops == 0 ? 1.0 : 1.0 / Double(hops + 1)
                    }
                }
            }
            signals["graph"] = graph

            var score =
                weights.lexical * lexical
                + weights.temporal * temporal
                + weights.authority * authority
                + weights.graph * graph

            if let embedder {
                // Placeholder for the vector leg. It is wired but unmeasured, so it is
                // recorded as such rather than reported as a contribution.
                unavailable["semantic"] = "provider '\(embedder.modelIdentifier)' configured but object vectors are not yet built"
                score += 0
            }

            hits.append(SearchHit(object: object, score: score, signals: signals))
        }

        hits.sort { $0.score > $1.score }
        return SearchOutcome(
            hits: Array(hits.prefix(limit)),
            objectsSearched: totalObjects,
            candidatesConsidered: candidates.count,
            blockedByDomain: blocked,
            unavailableSignals: unavailable
        )
    }

    // MARK: - Lexical

    private func lexicalCandidates(query: String, limit: Int) async throws -> [(CoreObject, Double)] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty else { return [] }
        return try await store.lexicalCandidates(match: match, limit: limit).map { ($0.object, $0.bm25) }
    }

    /// Build an FTS5 MATCH expression from free text.
    ///
    /// Every term is double-quoted, which both escapes FTS5's operator characters and
    /// stops a stray `"` or `*` in a user's question from becoming a syntax error or an
    /// accidental prefix search across the whole corpus.
    public static func ftsQuery(from query: String) -> String {
        let rawTerms = ftsTerms(from: query)
        guard !rawTerms.isEmpty else { return "" }
        let specificTerms = rawTerms.filter { !framingWords.contains($0) }
        let baseTerms = specificTerms.isEmpty ? rawTerms : specificTerms

        var expressions: [String] = []
        var seen = Set<String>()
        func addExact(_ term: String) {
            guard term.count > 1, term.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
            let expr = "\"\(term)\""
            if seen.insert(expr).inserted { expressions.append(expr) }
        }

        // **No synonym table here, on purpose.** This function carried hand-written bridges
        // (one question's word mapped to the words of the README that answered it), each of
        // which lined up with one row of `Benchmarks/rag_eval_v1.jsonl`, and one of which put an
        // employer's name in a public repository. They raised the score and taught the system
        // nothing about any question not in the file. `Docs/ai/DECISIONS.md` has the before and
        // after. A rule belongs here only if it is about English, never about a document.
        for term in baseTerms {
            addExact(term)
            guard term.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            if term.hasSuffix("ies") && term.count > 4 {
                addExact(String(term.dropLast(3)) + "y")
            } else if term.hasSuffix("ing") && term.count > 5 {
                let root = String(term.dropLast(3))
                addExact(root)
                addExact(root + "e")
            } else if term.hasSuffix("ed") && term.count > 4 {
                addExact(String(term.dropLast(2)))
                addExact(String(term.dropLast(1)))
            } else if term.hasSuffix("s") && !term.hasSuffix("ss") && term.count > 4 {
                addExact(String(term.dropLast()))
            }
        }

        return expressions.joined(separator: " OR ")
    }

    /// The words of a query that survive the stopword list, lowercased and in order.
    public static func ftsTerms(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    /// Whether a lowercased word carries no meaning of its own.
    public static func isStopword(_ word: String) -> Bool { stopwords.contains(word) }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "is", "are", "was", "were", "to", "in",
        "on", "for", "my", "i", "what", "why", "how", "when", "did", "do", "does", "me",
        "have", "has", "had", "having", "been", "be", "being", "which", "where", "who",
        "whom", "whose", "with", "from", "into", "about", "that", "this", "these", "those",
        "it", "its", "you", "your", "we", "our", "they", "them", "their", "can", "could",
        "would", "should", "will", "shall", "may", "might", "must", "not", "no", "but",
        "if", "as", "at", "by", "up", "out", "so", "than", "too", "very", "just", "now",
        "then", "like", "some", "any", "all", "both", "each", "more", "most", "other",
        "such", "only", "own", "same", "also", "there", "here", "recently", "lately",
    ]

    // Generic framing words ("which project...", "what did I make...", "what have I been
    // building...") match Makefile snippets (`make run`) and boilerplate commit messages
    // (`Auto-sync project documentation`) across the whole corpus. Dropped only when the query
    // carries at least one more specific content term.
    public static let framingWords: Set<String> = [
        "project", "projects", "repository", "repositories", "repo", "repos",
        "app", "apps", "make", "made", "making", "build", "built", "building",
        "difference", "between", "stopped", "describe", "using", "helps", "keep", "track",
        "works", "work", "finding",
    ]

    private func anchorEntities(in query: String) async throws -> [EntityID] {
        var found: [EntityID] = []
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "-" }).map(String.init)

        for word in words where word.count > 2 {
            let matches = try await store.resolve(surface: word)
            if let best = matches.first { found.append(best.0.id) }
        }
        return found
    }
}
