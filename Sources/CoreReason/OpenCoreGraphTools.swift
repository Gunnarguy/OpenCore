import CoreModel
import CoreSearch
import CoreStore
import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Read-only `FoundationModels.Tool` implementations (cited 2026-10-22 from `MacOSX27.0.sdk`
/// `FoundationModels.swiftmodule`) that let an on-device `LanguageModelSession` inspect the
/// non-sensitive `.project` fact graph and hybrid passage index.
///
/// Domain firewall invariant: every tool enforces `AdmissionPolicy(queryDomain: .project)`
/// and refuses `.medical`, `.financial`, and `.relationships` rows, matching `CoreMCP`.
@available(macOS 26.0, *)
public struct SearchPassagesTool: Tool {
    public let name = "search_passages"
    public let description = "Search project documents, commits, and agent memories using hybrid BM25 + 512-d vector RRF."

    private let search: PassageSearch

    public init(store: Store, embedder: (any EmbeddingProvider)? = nil, tuning: RetrievalTuning = .default) {
        self.search = PassageSearch(store: store, embedder: embedder, tuning: tuning)
    }

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Search query terms or topic to look up in project history.")
        public var query: String
    }

    public func call(arguments: Arguments) async throws -> String {
        let policy = AdmissionPolicy(queryDomain: .project, explicitlyRequested: [])
        let queryClass = QueryClassifier().classify(arguments.query).queryClass
        let outcome = try await search.search(
            query: arguments.query,
            queryClass: queryClass,
            policy: policy,
            limit: 4
        )
        guard !outcome.hits.isEmpty else {
            return "No matching project passages found for '\(arguments.query)'."
        }
        return outcome.hits.enumerated().map { idx, hit in
            "[\(idx + 1)] \(hit.object.title) (\(hit.object.authority.label)):\n\(String(hit.chunk.text.prefix(420)))"
        }.joined(separator: "\n\n")
    }
}

@available(macOS 26.0, *)
public struct ResolveEntityClaimsTool: Tool {
    public let name = "resolve_entity_claims"
    public let description = "Look up believed structured claims (status, objective, next_action, primary_language, last_verified_commit) for a project or entity."

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Canonical name or alias of the project, person, or tool.")
        public var entityName: String
    }

    public func call(arguments: Arguments) async throws -> String {
        let needle = arguments.entityName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entities = try await store.entities()
        guard let matched = entities.first(where: { $0.canonicalName.lowercased() == needle })
            ?? entities.first(where: { $0.canonicalName.lowercased().contains(needle) })
        else {
            return "No entity matching '\(arguments.entityName)' found."
        }
        let claims = try await store.claims(subject: matched.id, currentOnly: true)
            .filter { !$0.domain.isSensitive }
        guard !claims.isEmpty else {
            return "Entity '\(matched.canonicalName)' (\(matched.kind.rawValue)) has no non-sensitive believed claims."
        }
        var lines: [String] = ["Entity: \(matched.canonicalName) (\(matched.kind.rawValue))"]
        for claim in claims.prefix(12) {
            let val: String
            if let objEntity = claim.objectEntity, let resolved = try await store.entity(objEntity) {
                val = resolved.canonicalName
            } else {
                val = claim.literal ?? "unknown"
            }
            lines.append("- \(claim.predicate): \(val) [\(claim.authority.label), \(claim.derivation.rawValue)]")
        }
        return lines.joined(separator: "\n")
    }
}

@available(macOS 26.0, *)
public struct ListContradictionsTool: Tool {
    public let name = "list_contradictions"
    public let description = "List unresolved contradictions where two sources disagree on a functional predicate."

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "True to list only unresolved conflicts.")
        public var unresolvedOnly: Bool
    }

    public func call(arguments: Arguments) async throws -> String {
        let rows = try await store.contradictions(unresolvedOnly: arguments.unresolvedOnly)
        guard !rows.isEmpty else {
            return "0 contradictions found."
        }
        var out: [String] = []
        for row in rows.prefix(8) {
            guard let claimA = try await store.claim(row.claimA),
                  let claimB = try await store.claim(row.claimB),
                  !claimA.domain.isSensitive,
                  !claimB.domain.isSensitive
            else { continue }
            let subjectName = (try? await store.entity(claimA.subject)?.canonicalName) ?? claimA.subject.value
            let valA = claimA.literal ?? claimA.objectEntity?.value ?? "unknown"
            let valB = claimB.literal ?? claimB.objectEntity?.value ?? "unknown"
            out.append("- \(subjectName) · \(claimA.predicate): '\(valA)' vs '\(valB)' (\(row.resolution.rawValue))")
        }
        return out.isEmpty ? "0 non-sensitive contradictions found." : out.joined(separator: "\n")
    }
}
#endif
