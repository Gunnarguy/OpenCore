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

/// Something that turns text into a vector. Optional by design.
public protocol EmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var dimensions: Int { get }
    func embed(_ text: String) async throws -> [Float]
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
        let stopwords: Set<String> = [
            "the", "a", "an", "of", "and", "or", "is", "are", "was", "were", "to", "in",
            "on", "for", "my", "i", "what", "why", "how", "when", "did", "do", "does", "me",
        ]
        let terms = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }

        guard !terms.isEmpty else { return "" }
        return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

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
