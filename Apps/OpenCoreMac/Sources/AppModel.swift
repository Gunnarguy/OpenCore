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
    /// Owned here so there is one instance, injected into the environment by OpenCoreApp.
    let settings = AppSettings()
    var state: LoadState = .idle

    // Overview
    var objectCount = 0
    var entityCount = 0
    var claimCount = 0
    var openContradictionCount = 0
    var sources: [Source] = []
    var countsByKind: [(ObjectKind, Int)] = []
    /// Shown in Settings so it is obvious the app and the CLI share one file.
    var storePath: String?

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
            let opened = try await Store.open()
            store = opened
            storePath = await opened.database.path.path
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
            chunkCount = try await store.chunkCount()
            if let run = try await store.embeddingRuns().first {
                embeddingModel = run.model
                embeddedCount = run.chunksDone
            } else {
                embeddedCount = 0
            }
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Sync

    var chunkCount = 0
    var embeddedCount = 0
    var embeddingModel: String?

    func syncGitHub() async {
        guard let token = GitHubConnector.resolveToken() else {
            state = .failed("No GitHub token. Set GITHUB_TOKEN or run `gh auth login` in Terminal.")
            return
        }
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
            await sync(GitHubConnector(login: login, token: token, commitsPerRepo: settings.githubCommitsPerRepo, includeForks: settings.githubIncludeForks), label: "github:\(login)")
        } catch {
            state = .failed("\(error)")
        }
    }

    func syncCalendar() async { await sync(AppleEventKitConnector(scope: .calendar, lookBackDays: settings.calendarLookBackDays, lookAheadDays: settings.calendarLookAheadDays), label: "Calendar") }
    func syncReminders() async { await sync(AppleEventKitConnector(scope: .reminders), label: "Reminders") }
    func syncNotes() async { await sync(AppleNotesConnector(), label: "Notes") }

    func syncFolder(_ url: URL, domain: Domain) async {
        let connector = FilesystemConnector(
            handle: url.lastPathComponent,
            roots: [FilesystemConnector.Root(url: url, domain: domain)]
        )
        await sync(connector, label: "\(url.lastPathComponent) [\(domain.rawValue)]")
    }

    /// One sync path for every connector, so the app cannot drift from the CLI.
    private func sync(_ connector: any Connector, label: String) async {
        guard let store else { return }
        state = .working("connecting to \(label)")
        do {
            try await store.upsert(connector.source)
            let since = try await store.sources().first { $0.id == connector.source.id }?.lastSyncedAt

            state = .working("fetching from \(label)")
            let batch = try await connector.fetch(since: since, cursor: nil) { _ in }

            guard !batch.objects.isEmpty else {
                try await store.markSynced(connector.source.id, at: Date(), cursor: batch.cursor)
                await refresh()
                state = .idle
                return
            }

            state = .working("deriving from \(batch.objects.count) objects")
            _ = try await IngestPipeline(store: store, chunker: settings.chunker).run(objects: batch.objects)
            try await store.markSynced(connector.source.id, at: Date(), cursor: batch.cursor)

            await refresh()
            state = .idle
        } catch {
            state = .failed("\(label): \(error)")
        }
    }

    /// Build vectors for every passage that lacks one. Resumable: interrupting it and
    /// running again continues rather than restarting.
    func buildEmbeddings() async {
        guard let store else { return }
        do {
            let provider = try NLEmbeddingProvider()
            embeddingModel = provider.modelIdentifier
            state = .working("preparing \(provider.modelIdentifier)")

            let indexer = EmbeddingIndexer(store: store, provider: provider)
            _ = try await indexer.run(batchSize: 32) { [weak self] message in
                Task { @MainActor in self?.state = .working(message) }
            }
            await refresh()
            state = .idle
        } catch {
            state = .failed("embedding: \(error)")
        }
    }

    // MARK: - Asking

    func ask(_ query: String) async {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state = .working("answering")
        do {
            // Passage-level retrieval with the settings the user actually chose.
            let reasoner = Reasoner(store: store, embedder: try? NLEmbeddingProvider(), tuning: settings.tuning)
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
