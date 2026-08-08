import CoreGraph
import CoreIngest
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation
import Observation

/// The app's single point of contact with the engine.
///
/// Everything below `Store` is already actor-isolated, so this exists to hold view state
/// and to keep SwiftUI off the concurrency details, not to add another layer of caching.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    private(set) var store: Store?
    var state: LoadState = .idle

    // Overview
    var objectCount = 0
    var entityCount = 0
    var claimCount = 0
    var openContradictionCount = 0
    var sources: [Source] = []
    var countsByKind: [(ObjectKind, Int)] = []

    // Browsing
    var claims: [ClaimRow] = []
    var beliefs: [BeliefRow] = []
    var contradictions: [ContradictionRow] = []
    var receipts: [Receipt] = []

    // Asking
    var answer: Answer?
    var traceRows: [TraceRow] = []

    struct ClaimRow: Identifiable, Sendable {
        let id: ClaimID
        let subject: String
        let predicate: String
        let value: String
        let claim: CoreClaim
    }

    struct BeliefRow: Identifiable, Sendable {
        let id: BeliefID
        let subject: String
        let predicate: String
        let value: String
        let belief: Belief
    }

    struct ContradictionRow: Identifiable, Sendable {
        let id: ContradictionID
        let contradiction: Contradiction
        let sides: [(label: String, text: String, kept: Bool)]
    }

    struct TraceRow: Identifiable, Sendable {
        let id: EvidenceID
        let evidence: Evidence
        let object: CoreObject
        let score: Double
    }

    // MARK: - Lifecycle

    func start() async {
        state = .working("opening store")
        do {
            store = try await Store.open()
            await refresh()
            state = .idle
        } catch {
            state = .failed("\(error)")
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            objectCount = try await store.objectCount()
            entityCount = try await store.entities().count
            claimCount = try await store.claimCount()
            openContradictionCount = try await store.contradictions(unresolvedOnly: true).count
            sources = try await store.sources()
            countsByKind = try await store.objectCountsByKind()
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Sync

    func syncGitHub() async {
        guard let store else { return }
        guard let token = GitHubConnector.resolveToken() else {
            state = .failed("No GitHub token. Set GITHUB_TOKEN or run `gh auth login` in Terminal.")
            return
        }

        state = .working("resolving account")
        do {
            struct User: Decodable { let login: String }
            var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let login = (try? JSONDecoder().decode(User.self, from: data))?.login else {
                state = .failed("Could not resolve the GitHub account for this token.")
                return
            }

            let connector = GitHubConnector(login: login, token: token, commitsPerRepo: 100)
            try await store.upsert(connector.source)

            state = .working("fetching from github:\(login)")
            let batch = try await connector.fetch(since: nil, cursor: nil) { _ in }

            state = .working("storing \(batch.objects.count) objects")
            try await store.ingest(batch.objects)

            state = .working("resolving entities")
            try await EntityResolver(store: store).resolve(objects: batch.objects)

            state = .working("extracting claims")
            try await ClaimExtractor(store: store).extract(from: batch.objects)

            state = .working("reconciling beliefs")
            try await BeliefEngine(store: store).reconcile()

            try await store.markSynced(connector.source.id, at: Date(), cursor: batch.cursor)
            await refresh()
            state = .idle
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Asking

    func ask(_ query: String) async {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state = .working("answering")
        do {
            let reasoner = Reasoner(store: store, search: HybridSearch(store: store))
            answer = try await reasoner.answer(query)
            traceRows = []
            state = .idle
        } catch {
            state = .failed("\(error)")
        }
    }

    func loadTrace(for receipt: Receipt) async {
        guard let store else { return }
        do {
            traceRows = try await store.trace(receipt: receipt.id).map {
                TraceRow(id: $0.0.id, evidence: $0.0, object: $0.1, score: $0.2)
            }
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Browsing

    func loadClaims() async {
        guard let store else { return }
        do {
            var rows: [ClaimRow] = []
            for claim in try await store.allClaims(limit: 400) {
                rows.append(ClaimRow(
                    id: claim.id,
                    subject: try await name(of: claim.subject, in: store),
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    value: try await value(of: claim, in: store),
                    claim: claim
                ))
            }
            claims = rows
        } catch {
            state = .failed("\(error)")
        }
    }

    func loadBeliefs() async {
        guard let store else { return }
        do {
            var rows: [BeliefRow] = []
            for belief in try await store.beliefsDecided(since: .distantPast) {
                guard let claim = try await store.claim(belief.claimID) else { continue }
                rows.append(BeliefRow(
                    id: belief.id,
                    subject: try await name(of: claim.subject, in: store),
                    predicate: claim.predicate.replacingOccurrences(of: "_", with: " "),
                    value: try await value(of: claim, in: store),
                    belief: belief
                ))
            }
            beliefs = rows
        } catch {
            state = .failed("\(error)")
        }
    }

    func loadContradictions() async {
        guard let store else { return }
        do {
            var rows: [ContradictionRow] = []
            for contradiction in try await store.contradictions() {
                var sides: [(String, String, Bool)] = []
                for id in [contradiction.claimA, contradiction.claimB] {
                    guard let claim = try await store.claim(id) else { continue }
                    let subject = try await name(of: claim.subject, in: store)
                    let value = try await value(of: claim, in: store)
                    let label: String
                    if contradiction.winner == id {
                        label = "kept"
                    } else if contradiction.resolution == .unresolved {
                        label = "open"
                    } else {
                        label = "retired"
                    }
                    sides.append((
                        label,
                        "\(subject) \(claim.predicate.replacingOccurrences(of: "_", with: " ")) \(value)  ·  \(claim.authority.label)",
                        contradiction.winner == id
                    ))
                }
                rows.append(ContradictionRow(id: contradiction.id, contradiction: contradiction, sides: sides))
            }
            contradictions = rows
        } catch {
            state = .failed("\(error)")
        }
    }

    func loadReceipts() async {
        guard let store else { return }
        do { receipts = try await store.receipts(limit: 100) } catch { state = .failed("\(error)") }
    }

    // MARK: - Naming

    private func name(of entity: EntityID, in store: Store) async throws -> String {
        try await store.entity(entity)?.canonicalName ?? String(entity.value.prefix(8))
    }

    private func value(of claim: CoreClaim, in store: Store) async throws -> String {
        if let objectEntity = claim.objectEntity, let resolved = try await store.entity(objectEntity) {
            return resolved.canonicalName
        }
        return claim.literal ?? "—"
    }
}
