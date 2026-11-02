import CoreGraph
import CoreIngest
import CoreMCP
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import CoreTelemetry
import Foundation

// Argument parsing is hand-rolled to keep the package dependency-free. That is a real
// constraint of this project: OpenCore should build from a clean checkout with nothing
// but the Swift toolchain, because a personal knowledge store that stops building when a
// dependency moves is a personal knowledge store you lose.

let arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { arguments.contains("--" + name) }

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--" + name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// All values of a repeatable option, e.g. `--root A --root B`.
func options(_ name: String) -> [String] {
    var values: [String] = []
    for (index, argument) in arguments.enumerated() where argument == "--" + name {
        if index + 1 < arguments.count { values.append(arguments[index + 1]) }
    }
    return values
}

func positional(_ index: Int) -> String? {
    var cleaned: [String] = []
    var skipNext = false
    for argument in arguments {
        if skipNext { skipNext = false; continue }
        if argument.hasPrefix("--") {
            // Only value-taking options consume the next token.
            skipNext = !Self_booleanFlags.contains(String(argument.dropFirst(2)))
            continue
        }
        cleaned.append(argument)
    }
    return index < cleaned.count ? cleaned[index] : nil
}

let Self_booleanFlags: Set<String> = [
    "open", "include-forks", "help", "unsafe-expose-sensitive", "no-context", "verbose",
    "telemetry", "telemetry-summary", "fm", "no-fm", "apply",
]

func parseDuration(_ text: String) -> TimeInterval? {
    guard let unit = text.last, let value = Double(text.dropLast()) else { return nil }
    return switch unit {
    case "d": value * 86_400
    case "w": value * 7 * 86_400
    case "m": value * 30 * 86_400
    case "y": value * 365 * 86_400
    default: nil
    }
}

let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

func bar(_ value: Double, width: Int = 20) -> String {
    let filled = Int((value.isFinite ? max(0, min(1, value)) : 0) * Double(width))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

/// Progress goes to stderr so stdout stays clean for piping, and so `opencore mcp` can
/// never accidentally contaminate its JSON-RPC stream.
func progress(_ message: String) {
    FileHandle.standardError.write(Data(("  " + message + "\n").utf8))
}

// MARK: - Telemetry

/// `--telemetry` turns on measurement for this run; `OPENCORE_TELEMETRY` does the same for a
/// whole shell session. Off otherwise, so the default path pays one atomic load per span.
if flag("telemetry") || flag("telemetry-summary") { Telemetry.enable() }

/// Write the measured tree.
///
/// **stderr, always.** Never `print`. `opencore mcp` speaks JSON-RPC on stdout and a single
/// line of report text there corrupts the stream in a way that presents to the client as a
/// hang rather than an error.
func writeTelemetryReport() async {
    guard Telemetry.isEnabled else { return }
    let spans = await Telemetry.collected()
    let dropped = await Telemetry.recorder.droppedCount()

    var report = "\n"
    if !flag("telemetry-summary") {
        report += TelemetryReport.tree(spans, droppedCount: dropped) + "\n\n"
    }
    report += TelemetryReport.summary(spans) + "\n"

    if let path = option("telemetry-json") {
        do {
            try TelemetryReport.jsonl(spans).write(toFile: path, atomically: true, encoding: .utf8)
            report += "\n\(spans.count) span(s) written to \(path)\n"
        } catch {
            report += "\ncould not write \(path): \(error)\n"
        }
    }
    FileHandle.standardError.write(Data(report.utf8))
}

func usage() {
    print("""
    opencore — an evidence-native store for your own digital history

    SOURCES
      opencore sync github [--login NAME] [--commits N] [--include-forks]
      opencore sync files --root PATH [--domain project|personal|work|medical|financial]
                          (repeat --root/--domain in pairs)
      opencore sync calendar                 Apple Calendar via EventKit
      opencore sync reminders                Apple Reminders via EventKit
      opencore sync notes                    Apple Notes via AppleScript
      opencore sync mcp NAME                 a configured MCP server

    MCP SOURCES  (any of ~9,650 registry servers becomes a source)
      opencore mcp-source discover --command CMD    list tools, call nothing
      opencore mcp-source add NAME --command CMD --tool T   allowlist and record
      opencore mcp-source list | remove NAME

    RETRIEVAL
      opencore embed [--batch N]             build on-device vectors for every passage
      opencore search "TEXT"                 object-level hybrid retrieval, signals shown
      opencore passages "TEXT" [--no-context]  passage retrieval: dense + BM25, RRF, MMR
      opencore eval [--file F] [--k N] [--verbose]
                                                 retrieval quality per leg over a benchmark
      opencore ask "QUESTION" [--no-fm]      an answer assembled from claims + /usr/bin/fm synthesis
      opencore propose-claims [--entity NAME | --object ID | --limit N]
                                                 extract byte-verified modelInference claims via /usr/bin/fm

    KNOWLEDGE
      opencore claims [ENTITY]               current claims, observed vs inferred
      opencore contradictions [--open]       conflicts, and how each was settled
      opencore memory log [--since 30d]      what it learned or changed its mind about
      opencore memory checkout YYYY-MM-DD    what it believed on a past date
      opencore receipts [--limit N]
      opencore trace CODE                    the evidence behind one answer
      opencore chat "QUESTION"               grounded answer, written by the on-device model
      opencore timeline [--since 30d]        what happened, from every source
      opencore correct CLAIM --to VALUE      tell it that it is wrong
              --reason "..." [--because "..."]

    INFRASTRUCTURE
      opencore mcp [--unsafe-expose-sensitive]   serve MCP over stdio
      opencore daemon install|status|uninstall|run   scheduled background sync + embed
      opencore repair-agent-memory [--apply --backup PATH]   dry-run imported memory policy repair; --apply creates NEW backup
      opencore doctor                            database, credentials, coverage
      opencore rebuild [--work-dir DIR]          rehearse a rebuild on a copy and show the difference
      opencore rebuild --explain DIR             list every change in a rehearsal, by id and reason
      opencore rebuild --apply-rehearsal DIR     apply a reviewed rehearsal, in one transaction
      opencore export [--format jsonl|markdown] [--to DIR]
                                                 everything back out, in a format you own

    TELEMETRY  (append to any command; measurement goes to stderr, never stdout)
      --telemetry                  nested tree of every stage, with timings and counters
      --telemetry-summary          time by layer and the ten slowest spans, no tree
      --telemetry-json PATH        one span per line, for diffing two runs
      OPENCORE_TELEMETRY=1         same as --telemetry, for a whole shell session

    Objects are the floor. Everything above them is rebuildable.
    """)
}

// MARK: - Shared

func openStore() async throws -> Store {
    let path = option("db").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    return try await Store.open(at: path)
}

/// The embedding provider, or nil with the reason printed. Never fabricates a fallback:
/// a search that silently ran without its dense leg is not the same search.
func embedder(quiet: Bool = false) -> (any EmbeddingProvider)? {
    do {
        return try NLEmbeddingProvider()
    } catch {
        if !quiet { progress("no embedding provider: \(error)") }
        return nil
    }
}

func claimValue(_ claim: CoreClaim, in store: Store) async throws -> String {
    if let objectEntity = claim.objectEntity, let entity = try await store.entity(objectEntity) {
        return entity.canonicalName
    }
    return claim.literal ?? "∅"
}

func subjectName(_ claim: CoreClaim, in store: Store) async throws -> String {
    try await store.entity(claim.subject)?.canonicalName ?? String(claim.subject.value.prefix(8))
}

func report(_ outcome: IngestPipeline.Outcome) {
    print("objects     \(outcome.ingest.inserted) new, \(outcome.ingest.updated) changed, \(outcome.ingest.unchanged) unchanged")
    print("chunks      \(outcome.chunks)")
    print("entities    \(outcome.entities) resolved, \(outcome.aliases) aliases")
    print("claims      \(outcome.claims) from \(outcome.evidence) evidence spans")
    print("events      \(outcome.events)")
    print("beliefs     \(outcome.beliefs) written")
    print("conflicts   \(outcome.contradictions) found — \(outcome.contradictionsResolved) resolved, \(outcome.contradictionsOpen) left open")
    if outcome.documentSuccessions > 0 {
        print("revisions   \(outcome.documentSuccessions) replaced by a newer revision of their own document")
    }
    if outcome.chunks > 0 {
        print("\nnext: opencore embed   (passages are indexed lexically; vectors are separate)")
    }
}

// MARK: - Doctor

func doctor() async throws {
    let store = try await openStore()
    print("database    \(await store.database.path.path)")

    let objects = try await store.objectCount()
    let chunks = try await store.chunkCount()
    print("objects     \(objects)")
    print("chunks      \(chunks)")
    print("entities    \(try await store.entities().count)")
    print("claims      \(try await store.claimCount()) current")
    print("conflicts   \(try await store.contradictions(unresolvedOnly: true).count) unresolved")

    let sources = try await store.sources()
    if sources.isEmpty {
        print("sources     none — run: opencore sync github")
    } else {
        for source in sources {
            let synced = source.lastSyncedAt.map { dateFormatter.string(from: $0) } ?? "never"
            print("sources     \(source.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) last synced \(synced)")
        }
    }

    print(GitHubConnector.resolveToken() != nil
        ? "github      token available"
        : "github      NO TOKEN — set GITHUB_TOKEN or run: gh auth login")

    // Embedding coverage. Partial coverage is a correctness problem, not a progress bar:
    // the dense leg cannot see what it has not embedded.
    let runs = try await store.embeddingRuns()
    if runs.isEmpty {
        print("embeddings  none — run: opencore embed")
    } else {
        for run in runs {
            let coverage = chunks > 0 ? Double(run.chunksDone) / Double(chunks) : 0
            let warning = run.chunksDone < chunks ? "  ⚠ dense retrieval cannot see the remainder" : ""
            print("embeddings  \(run.model)")
            print("            \(bar(coverage)) \(run.chunksDone)/\(chunks)\(warning)")
        }
    }

    let kinds = try await store.objectCountsByKind()
    if !kinds.isEmpty {
        print("\nby kind")
        for (kind, count) in kinds {
            print("  \(kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(count)")
        }
    }
}

// MARK: - Sync

func syncGitHub() async throws {
    guard let token = GitHubConnector.resolveToken(explicit: option("token")) else {
        throw ConnectorError.missingCredential("set GITHUB_TOKEN, or run `gh auth login`")
    }

    var login = option("login")
    if login == nil {
        struct User: Decodable { let login: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        login = (try? JSONDecoder().decode(User.self, from: data))?.login
    }
    guard let login else { throw ConnectorError.missingCredential("could not determine GitHub login; pass --login") }

    let connector = GitHubConnector(
        login: login,
        token: token,
        commitsPerRepo: option("commits").flatMap(Int.init) ?? 100,
        includeForks: flag("include-forks")
    )
    try await runSync(connector, label: "github:\(login)")
}

func syncFiles() async throws {
    let rootPaths = options("root")
    guard !rootPaths.isEmpty else {
        print("usage: opencore sync files --root PATH [--domain DOMAIN] [--root PATH --domain DOMAIN ...]")
        print("\nDomain is per root, because a folder is the coarsest honest signal about")
        print("what is inside it. A root tagged medical is unreachable from a project query.")
        exit(1)
    }

    let domainNames = options("domain")
    var roots: [FilesystemConnector.Root] = []
    for (index, path) in rootPaths.enumerated() {
        let expanded = (path as NSString).expandingTildeInPath
        let domainName = index < domainNames.count ? domainNames[index] : "personal"
        guard let domain = Domain(rawValue: domainName) else {
            print("unknown domain '\(domainName)'. One of: \(Domain.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            print("no such path: \(expanded)")
            exit(1)
        }
        roots.append(FilesystemConnector.Root(url: URL(fileURLWithPath: expanded), domain: domain))
    }

    let handle = roots.map { $0.url.lastPathComponent }.joined(separator: "+")
    try await runSync(FilesystemConnector(handle: handle, roots: roots), label: "files")
}

func syncAgentMemory() async throws {
    if let problem = LocalPrivateNames.currentProblem {
        FileHandle.standardError.write(Data("note: \(problem.explanation)\n".utf8))
    }
    let memories = AgentMemoryPolicy.discoverMemories()
    let repositories = AgentMemoryPolicy.discoverRepositories()
    let roots = memories.roots + repositories.roots

    guard !roots.isEmpty else {
        print("no agent memory or repository anchor docs found")
        return
    }
    try await runSync(
        FilesystemConnector(handle: "Cross-Agent-Memory", roots: roots, knownUnread: memories.unread + repositories.unread),
        label: "Cross-Agent Memory & Repo Docs (\(roots.count) roots)"
    )
}

/// Defaults to a report only. Applying creates a consistent SQLite backup at a new path.
func repairAgentMemoryPolicy() async throws {
    if let problem = LocalPrivateNames.currentProblem {
        FileHandle.standardError.write(Data("note: \(problem.explanation)\n".utf8))
    }
    let store = try await openStore()
    let filesystemSources = Set(try await store.sources().filter {
        $0.kind == .filesystem && (["agent-memory", "files:agent-memory", "Claude-Memory", "Cross-Agent-Memory", "GitHub-Workspace"].contains($0.handle) || $0.handle.hasPrefix("Repo-"))
    }.map(\.id))
    let repairs = try await store.allObjects().compactMap { object -> Store.ObjectPolicyRepair? in
        guard filesystemSources.contains(object.sourceID),
              let policy = AgentMemoryPolicy.classification(for: URL(fileURLWithPath: object.externalID)) else { return nil }
        return Store.ObjectPolicyRepair(objectID: object.id, domain: policy.domain, authority: policy.authority, reason: "cross-agent import policy repair")
    }
    if flag("apply") {
        guard let backup = option("backup") else {
            throw StoreError.notFound("--apply requires --backup NEW_PATH; the command creates its own consistent backup")
        }
        let backupURL = URL(fileURLWithPath: (backup as NSString).expandingTildeInPath)
        try await store.createPolicyRepairBackup(at: backupURL)
        print("Created a private, consistent backup before policy repair.")
    }
    let report = try await store.reclassifyObjects(repairs, dryRun: !flag("apply"))
    print("\(flag("apply") ? "Applied" : "Dry run"): \(report.objectsChanged) floor policies, \(report.versionsChanged) historical policies, \(report.claimsQuarantined) backed claim rows quarantined.")
    if flag("apply") { print("Restricted legacy snapshots added: \(report.legacySnapshotsAdded)") }
    print("Pending reviewed replay: \(report.objectsPendingRebuild) object(s).")
    if report.requiresRebuild {
        print("Derived interpretations require an audited rebuild. Corrections and receipts were preserved; do not run the existing destructive rebuild blindly.")
    }
}

func syncApple(_ what: String) async throws {
    switch what {
    case "calendar":
        try await runSync(AppleEventKitConnector(scope: .calendar), label: "Apple Calendar")
    case "reminders":
        try await runSync(AppleEventKitConnector(scope: .reminders), label: "Apple Reminders")
    case "notes":
        try await runSync(AppleNotesConnector(), label: "Apple Notes")
    default:
        print("unknown Apple source: \(what)")
        exit(1)
    }
}

func runSync(_ connector: any Connector, label: String) async throws {
    let store = try await openStore()
    try await store.upsert(connector.source)

    print("syncing \(label)")
    let started = Date()

    // Incremental where the connector supports it: pick up where the last sync stopped.
    let result = try await SourceSync(store: store, pipeline: IngestPipeline(store: store)).run(
        connector.source.id,
        log: progress,
        phase: { phase in
            if case .fetching(let since?) = phase { progress("incremental since \(dateFormatter.string(from: since))") }
        },
        fetch: { since in try await connector.fetch(since: since, cursor: nil, log: progress) }
    )
    guard let outcome = result.derived else {
        print(result.heldBecause ?? "nothing new")
        return
    }

    report(outcome)
    if let held = result.heldBecause { print("\nincomplete: \(held)") }
    print("\ndone in \(Int(Date().timeIntervalSince(started)))s")
}

// MARK: - Embed

func embed() async throws {
    let store = try await openStore()
    guard let provider = embedder() else {
        print("No embedding provider available on this system.")
        exit(1)
    }

    let total = try await store.chunkCount()
    guard total > 0 else {
        print("No chunks to embed. Sync a source first.")
        return
    }

    print("model       \(provider.modelIdentifier)")
    print("dimensions  \(provider.dimensions)")
    print("chunks      \(total)")
    print("")

    let started = Date()
    let added = try await EmbeddingIndexer(store: store, provider: provider)
        .run(batchSize: option("batch").flatMap(Int.init) ?? 32, log: progress)

    let covered = try await store.embeddedChunkCount(model: provider.modelIdentifier)
    print("embedded    \(added) new, \(covered)/\(total) covered")
    print("done in \(Int(Date().timeIntervalSince(started)))s")
}

// MARK: - Retrieval

func runSearch(_ query: String) async throws {
    let store = try await openStore()
    let (domain, requested) = AdmissionPolicy.classifyDomain(query, knownEntitySurfaces: try await store.aliasSurfaces())
    let policy = AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested)
    let classification = QueryClassifier().classify(query)

    let outcome = try await HybridSearch(store: store).search(
        query: query,
        queryClass: classification.queryClass,
        policy: policy,
        limit: option("limit").flatMap(Int.init) ?? 10
    )

    print("class       \(classification.queryClass.rawValue) (\(classification.matchedOn))")
    print("domains     admitted \(policy.admitted.map(\.rawValue).sorted().joined(separator: ", "))")
    print("            blocked  \(policy.blocked.map(\.rawValue).sorted().joined(separator: ", "))")
    print("searched    \(outcome.objectsSearched) objects → \(outcome.candidatesConsidered) candidates → \(outcome.hits.count) hits")
    if outcome.blockedByDomain > 0 { print("            \(outcome.blockedByDomain) candidates withheld by domain policy") }
    for (signal, reason) in outcome.unavailableSignals.sorted(by: { $0.key < $1.key }) {
        print("unavailable \(signal): \(reason)")
    }
    print("")

    for (index, hit) in outcome.hits.enumerated() {
        let signals = hit.signals.sorted { $0.key < $1.key }
            .map { "\($0.key.prefix(3)) \(String(format: "%.2f", $0.value))" }
            .joined(separator: "  ")
        print("\(String(format: "%2d", index + 1)). \(bar(hit.score)) \(String(format: "%.3f", hit.score))  \(hit.object.title)")
        print("    \(hit.object.kind.rawValue) · \(hit.object.authority.label) · \(signals)")
        if let uri = hit.object.uri, !uri.isEmpty { print("    \(uri)") }
    }
}

func runPassages(_ query: String) async throws {
    let store = try await openStore()
    let (domain, requested) = AdmissionPolicy.classifyDomain(query, knownEntitySurfaces: try await store.aliasSurfaces())
    let policy = AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested)
    let classification = QueryClassifier().classify(query)

    let search = PassageSearch(store: store, embedder: embedder(quiet: true))
    let window = TemporalIntent.window(in: query)
    let searchText = window?.searchText ?? query
    let outcome = try await search.search(
        query: searchText,
        queryClass: classification.queryClass,
        policy: policy,
        limit: option("limit").flatMap(Int.init) ?? 8,
        expandContext: !flag("no-context"),
        window: window?.interval
    )

    print("class       \(classification.queryClass.rawValue)")
    if let window {
        print(try await store.windowReport(window, domains: policy.admitted, calendar: .current).text)
        if searchText.isEmpty { print("This names a span and no topic, so no passage was read. `opencore ask` answers it from the event log.") }
    }
    print("legs        lexical \(outcome.lexicalCandidates) · dense \(outcome.denseCandidates) → fused \(outcome.afterFusion)")
    print("timings     " + outcome.stageTimings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)ms" }.joined(separator: " · "))
    print("chunks      \(outcome.chunksSearched) searched, \(outcome.blockedByDomain) withheld by domain, \(outcome.droppedByDiversity) dropped by MMR")
    for (signal, reason) in outcome.unavailableSignals.sorted(by: { $0.key < $1.key }) {
        print("unavailable \(signal): \(reason)")
    }
    print("")

    for (index, hit) in outcome.hits.enumerated() {
        let legs = hit.ranks.sorted { $0.key < $1.key }.map { "\($0.key)#\($0.value)" }.joined(separator: " ")
        print("\(String(format: "%2d", index + 1)). \(bar(hit.score / max(0.0001, outcome.hits[0].score))) \(String(format: "%.4f", hit.score))  [\(legs.isEmpty ? "—" : legs)]")
        print("    \(hit.object.title) · \(hit.object.kind.rawValue) · \(hit.object.authority.label)")
        print("    \(hit.chunk.text.replacingOccurrences(of: "\n", with: " ").prefix(220))")
        if hit.context.count > 1 { print("    (+\(hit.context.count - 1) neighbouring passages available)") }
        print("")
    }
}

func ask(_ query: String) async throws {
    let store = try await openStore()
    // Passage-level, both legs, RRF and MMR. This used HybridSearch, the v0.1
    // object-level scorer, which meant `ask` never touched the dense index.
    let reasoner = Reasoner(store: store, embedder: embedder(quiet: true))
    let answer = try await reasoner.answer(query)
    // Chosen, not measured, and the same two limits `core_ask` prints with. The answer's ordering
    // is what makes a cut safe, so the question's own line is above it.
    let pointsShown = 12
    let passagesShown = 5

    print("Q: \(query)\n")

    if let counted = answer.counted {
        // No claim list follows, and that is the answer being honest rather than thin: a count
        // is computed over every admitted row and cites no passage by construction.
        print(counted.sentence + "\n")
        print("  computed over every admitted \(counted.breakdown.kind.rawValue) row, not from retrieved passages")
    } else if let insufficient = answer.insufficientEvidence {
        print("Not enough evidence.")
        print(insufficient)
    } else {
        print(answer.summary + "\n")
        if let activity = answer.activity, activity.totalEvents > 0 {
            print("Activity in this window, from the event log")
            for group in activity.groups {
                let upkeep = group.upkeep > 0 ? " and \(group.upkeep) upkeep" : ""
                print("  \(group.subject.canonicalName): \(group.events) \(group.verb)\(upkeep), latest \(dateFormatter.string(from: group.lastAt))")
                for event in group.latest {
                    print("    \(dateFormatter.string(from: event.occurredAt))  \(event.detail.replacingOccurrences(of: "\n", with: " ").prefix(100))")
                }
            }
            print("")
        }
        let printPassages = {
            print("\nMatching passages")
            for hit in answer.passages.prefix(passagesShown) {
                let date = hit.object.authoredAt.map { " · \(dateFormatter.string(from: $0))" } ?? ""
                print("  \(hit.object.title) [\(hit.object.kind.rawValue)\(date)]")
                print("    \(hit.chunk.text.replacingOccurrences(of: "\n", with: " ").prefix(160))")
            }
        }
        if answer.passagesLead {
            printPassages()
            if !answer.points.isEmpty { print("\nAlso known about where those came from") }
        }
        for point in answer.points.prefix(pointsShown) {
            print("\(point.derivation == .observed ? "•" : "~") \(point.statement)")
            print("  confidence \(String(format: "%.2f", point.confidence)) · \(point.authority.label) · \(point.derivation.rawValue)")
            for evidence in point.supporting.prefix(2) {
                print("  ← \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(110))")
            }
            for evidence in point.counter.prefix(2) {
                print("  ✗ counter: \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(110))")
            }
        }
        if answer.points.count > pointsShown {
            print("  (\(pointsShown) of \(answer.points.count) claims shown, most relevant first)")
        }
        if !answer.points.isEmpty { print("\n  • observed directly    ~ inferred") }
        // The summary says how many passages matched, and `--no-fm` used to show none of them.
        if !answer.passages.isEmpty, !answer.passagesLead { printPassages() }
    }

    if !answer.contradictions.isEmpty {
        print("\nContradictions touching this answer")
        for contradiction in answer.contradictions.prefix(5) {
            print("  \(contradiction.kind.rawValue) → \(contradiction.resolution.rawValue)")
            print("    \(contradiction.reason)")
        }
    }

    if answer.counted == nil, answer.agenda == nil, !flag("no-fm") {
        let (domain, requested) = AdmissionPolicy.classifyDomain(
            query,
            knownEntitySurfaces: try await store.aliasSurfaces()
        )
        let policy = AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested)
        let passageSearch = PassageSearch(store: store, embedder: embedder(quiet: true))
        // The text and window the answer used, so this summary cannot range over all of time
        // beneath an answer that says it read one week.
        if let outcome = try? await passageSearch.search(
            query: answer.searchedText ?? query,
            queryClass: answer.receipt.queryClass,
            policy: policy,
            limit: 5,
            window: answer.window?.interval
        ) {
            var sources: [GroundingSource] = []
            for hit in outcome.hits {
                sources.append(GroundingSource(
                    index: sources.count + 1,
                    title: hit.object.title,
                    text: hit.chunk.text,
                    objectID: hit.object.id,
                    authority: hit.object.authority,
                    uri: hit.object.uri
                ))
            }
            if !sources.isEmpty, let brief = await Conversation.synthesizeGroundedBrief(question: query, sources: sources) {
                let groundedCount = brief.verdicts.filter(\.isGrounded).count
                print("\n── supplemental passage summary (\(brief.modelName)); separate retrieval, no persisted receipt ──")
                print(brief.text)
                print("  grounding   \(groundedCount)/\(brief.verdicts.count) sentences passed citation and lexical-overlap checks")
                for src in brief.sources {
                    print("  [\(src.index)] \(src.title) (\(src.authority.label)); object: \(src.objectID.value); uri: \(src.uri ?? "none")")
                }
            }
        }
    }

    print("\nThe receipt below covers the claim answer, excluding the supplemental passage summary.")
    printReceipt(answer.receipt)
}

func proposeClaims() async throws {
    let store = try await openStore()
    let proposer = ModelClaimProposer(store: store)
    let limit = option("limit").flatMap(Int.init) ?? 4

    var outcomes: [ModelClaimProposer.ProposalOutcome] = []
    if let objectIDText = option("object") {
        guard let object = try await store.object(ObjectID(objectIDText)) else {
            print("no object with id '\(objectIDText)'")
            exit(1)
        }
        outcomes.append(try await proposer.propose(from: object))
    } else if let entityName = option("entity") ?? positional(1) {
        guard let entity = try await store.resolve(surface: entityName).first?.0 else {
            print("no entity known as '\(entityName)'")
            exit(1)
        }
        print("proposing byte-verified modelInference claims for \(entity.canonicalName) (\(entity.kind.rawValue))...")
        outcomes = try await proposer.proposeForEntity(entity.id, limit: limit)
    } else {
        let all = try await store.allObjects()
            .filter { $0.kind == .note || $0.kind == .document || $0.kind == .file }
            .prefix(limit)
        for object in all {
            outcomes.append(try await proposer.propose(from: object))
        }
    }

    guard !outcomes.isEmpty else {
        print("no matching objects found to propose claims from")
        return
    }

    var totalVerified = 0
    for outcome in outcomes {
        totalVerified += outcome.verifiedProposals.count
        print("\n\(outcome.objectTitle)  [\(outcome.modelName)]")
        print("  proposed \(outcome.candidatesProposed) · byte-verified \(outcome.verifiedProposals.count) · rejected (unverified span) \(outcome.rejectedUnverifiedSpan)")
        for prop in outcome.verifiedProposals {
            print("  ~ [modelInference] \(prop.subject) \(prop.predicate) → \(prop.value)")
            print("    quote: \"\(prop.verbatimQuote.prefix(120))\"")
        }
    }
    print("\n\(totalVerified) byte-verified modelInference claim(s) reconciled across \(outcomes.count) object(s)")
}

func printReceipt(_ receipt: Receipt) {
    print("""

    ── receipt \(receipt.shortCode) ──────────────────────
    class                 \(receipt.queryClass.rawValue)
    objects searched      \(receipt.objectsSearched)
    objects retrieved     \(receipt.objectsRetrieved)
    evidence admitted     \(receipt.evidenceAdmitted)
    claims consulted      \(receipt.claimsConsulted)
    contradictions        \(receipt.contradictionsSurfaced)
    domains blocked       \(receipt.domainsBlocked.map(\.rawValue).joined(separator: ", "))
    prose author          \(receipt.model ?? "no model author")
    outbound activity     \(receipt.outboundDescription)
    confidence            \(receipt.confidence.map { String(format: "%.2f", $0) } ?? "not measured")
    """)
    for stage in receipt.stages {
        let counters = stage.counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("    \(stage.name.padding(toLength: 20, withPad: " ", startingAt: 0))\(stage.milliseconds)ms  \(counters)")
    }
    print("    trace with: opencore trace \(receipt.shortCode)")
}

// MARK: - Knowledge

func listClaims(_ entityName: String?) async throws {
    let store = try await openStore()
    let asOfWorld = option("world").flatMap(dateFormatter.date(from:))
    let asOfKnowledge = option("as-of").flatMap(dateFormatter.date(from:))

    let claims: [CoreClaim]
    if let entityName {
        guard let entity = try await store.resolve(surface: entityName).first?.0 else {
            print("no entity known as '\(entityName)'")
            return
        }
        print("\(entity.canonicalName) (\(entity.kind.rawValue))\n")
        claims = try await store.claims(
            subject: entity.id,
            currentOnly: asOfWorld == nil && asOfKnowledge == nil,
            asOfWorld: asOfWorld,
            asOfKnowledge: asOfKnowledge
        )
    } else {
        claims = try await store.allClaims(limit: option("limit").flatMap(Int.init) ?? 60)
    }

    var printedHistoryKeys: Set<String> = []
    for claim in claims {
        let value = try await claimValue(claim, in: store)
        let subject = try await subjectName(claim, in: store)
        let validity = claim.validity.validFrom.map { " from \(dateFormatter.string(from: $0))" } ?? ""
        print("\(claim.derivation == .observed ? "•" : "~") \(subject) \(claim.predicate) \(value)")
        // The id prefix is printed so `opencore correct` has something to name.
        print("   \(claim.id.value.prefix(8))  conf \(String(format: "%.2f", claim.confidence)) · \(claim.authority.label)\(validity)")
        if printedHistoryKeys.insert(claim.claimKey).inserted {
            let history = try await store.beliefHistory(key: claim.claimKey)
            if history.count > 1 {
                for belief in history {
                    print("   v\(belief.version) (\(dateFormatter.string(from: belief.decidedAt))): \(belief.reason)")
                }
            }
        }
    }
    print("\n\(claims.count) claims  · observed  ~ inferred")
}

func listContradictions() async throws {
    let store = try await openStore()
    let items = try await store.contradictions(unresolvedOnly: flag("open"))

    guard !items.isEmpty else {
        print(flag("open") ? "no unresolved contradictions" : "no contradictions detected")
        return
    }

    for item in items {
        print("\(item.kind.rawValue) → \(item.resolution.rawValue)")
        print("  \(item.reason)")
        for id in [item.claimA, item.claimB] {
            guard let claim = try await store.claim(id) else { continue }
            let subject = try await subjectName(claim, in: store)
            let value = try await claimValue(claim, in: store)
            let mark = item.winner == id ? "kept   " : (item.resolution == .unresolved ? "open   " : "retired")
            print("  \(mark) \(subject) \(claim.predicate) \(value)  [\(claim.authority.label)]")
        }
        print("")
    }
    print("\(items.count) contradiction\(items.count == 1 ? "" : "s")")
}

func memoryLog() async throws {
    let store = try await openStore()
    let window = option("since").flatMap(parseDuration) ?? 30 * 86_400
    let beliefs = try await store.beliefsDecided(since: Date().addingTimeInterval(-window))

    guard !beliefs.isEmpty else {
        print("no belief changes in the last \(Int(window / 86_400)) days")
        return
    }

    for belief in beliefs {
        guard let claim = try await store.claim(belief.claimID) else { continue }
        let subject = try await subjectName(claim, in: store)
        let value = try await claimValue(claim, in: store)
        print("\(dateFormatter.string(from: belief.decidedAt))  \(belief.version == 1 ? "LEARNED" : "UPDATED")  v\(belief.version)")
        print("  \(subject) \(claim.predicate) → \(value)")
        print("  \(belief.reason)\n")
    }
    print("\(beliefs.count) belief change\(beliefs.count == 1 ? "" : "s")")
}

func memoryCheckout(_ dateText: String) async throws {
    guard let instant = dateFormatter.date(from: dateText) else {
        print("date must be YYYY-MM-DD")
        return
    }
    let world = option("world").flatMap(dateFormatter.date(from:))
    let store = try await openStore()
    let beliefs = try await store.beliefs(asOfKnowledge: instant, asOfWorld: world)

    print("what OpenCore believed on \(dateText)\n")
    guard !beliefs.isEmpty else {
        print("nothing — the store held no beliefs at that instant")
        return
    }
    for belief in beliefs {
        guard let claim = try await store.claim(belief.claimID) else { continue }
        let subject = try await subjectName(claim, in: store)
        let value = try await claimValue(claim, in: store)
        print("  \(subject) \(claim.predicate) → \(value)   (v\(belief.version), conf \(String(format: "%.2f", belief.confidence)))")
    }
    print("\n\(beliefs.count) belief\(beliefs.count == 1 ? "" : "s")")
}

func listReceipts() async throws {
    let store = try await openStore()
    let receipts = try await store.receipts(limit: option("limit").flatMap(Int.init) ?? 15)
    guard !receipts.isEmpty else {
        print("no receipts yet — run: opencore ask \"...\"")
        return
    }
    for receipt in receipts {
        print("\(receipt.shortCode)  \(dateFormatter.string(from: receipt.createdAt))  \(receipt.queryClass.rawValue)")
        print("  \(receipt.query)")
        print("  \(receipt.objectsRetrieved) retrieved · \(receipt.claimsConsulted) claims · \(receipt.evidenceAdmitted) evidence")
        print("  \(receipt.outboundDescription)")
    }
}

func trace(_ code: String) async throws {
    let store = try await openStore()
    guard let receipt = try await store.receipt(code: code) else {
        print("no receipt matching '\(code)'")
        return
    }

    print("\(receipt.shortCode)  \(receipt.query)\n")
    let rows = try await store.trace(receipt: receipt.id)
    guard !rows.isEmpty else {
        // Counted answers cite nothing by construction. Saying so distinguishes them from an
        // answer that genuinely had nothing behind it.
        if receipt.queryClass == .aggregate {
            print("computed count over \(receipt.objectsSearched) admitted rows; cites no evidence because none was read")
        } else if !receipt.answeredFromClaims, receipt.evidenceAdmitted > 0 {
            print("answered from \(receipt.evidenceAdmitted) passage(s) and read no claims, so it has no evidence rows to trace")
        } else {
            print("this receipt admitted no evidence")
        }
        printReceipt(receipt)
        return
    }

    for (index, entry) in rows.enumerated() {
        let (evidence, object, score) = entry
        print("\(index + 1). \(bar(score)) \(String(format: "%.3f", score))")
        print("   \(object.title)")
        print("   \(object.kind.rawValue) · \(object.authority.label) · \(object.authoredAt.map(dateFormatter.string(from:)) ?? "undated")")
        print("   \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(140))")
        if let uri = object.uri, !uri.isEmpty { print("   \(uri)") }
        print("")
    }
    printReceipt(receipt)
}

// MARK: - Chat

/// `opencore chat` — the same grounded conversation the app runs, one shot.
///
/// Exists so the engine can be exercised without clicking: retrieval, generation, and the
/// grounding check all run here exactly as they do in the app.
/// `opencore chats` — saved threads, most recently used first.
func listChats() async throws {
    let store = try await openStore()
    let threads = try await store.conversations()
    guard !threads.isEmpty else {
        print("no saved chats yet. `opencore chat \"question\"` starts one.")
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for thread in threads {
        // The id is printed in full because it is what `--resume` takes. A truncated id that
        // has to be completed by hand is a worse affordance than a long line.
        print("\(formatter.string(from: thread.updatedAt))  \(thread.turnCount) turns  \(thread.id)")
        print("  \(thread.title)\n")
    }
}

func chat(_ question: String, resuming: String? = nil) async throws {
    let readiness = Conversation.readiness()
    if !readiness.isReady {
        progress(readiness.message)
    }

    let store = try await openStore()
    let conversation = resuming.map {
        Conversation(store: store, embedder: embedder(quiet: true), id: $0)
    } ?? Conversation(store: store, embedder: embedder(quiet: true))

    if let resuming {
        let prior = try await conversation.restore()
        guard !prior.isEmpty else {
            print("no saved chat with id '\(resuming)'. `opencore chats` lists them.")
            exit(1)
        }
        // Printed so it is visible what the model has been handed, rather than the reader
        // having to trust that resuming did anything.
        print("resuming \(prior.count) prior turns\n")
        for turn in prior {
            print("\(turn.role == .you ? "you " : "core")  \(turn.text.prefix(160))")
        }
        print("")
    }

    var final: Turn?
    for await turn in conversation.send(question) {
        final = turn
    }
    guard let turn = final else { return }

    if let error = turn.error {
        progress("note: \(error)")
        if turn.text.isEmpty {
            print("error: \(error)")
            exit(1)
        }
    }

    print("\n\(turn.text)\n")

    if !turn.sources.isEmpty {
        print("sources")
        for source in turn.sources {
            print("  [\(source.index)] \(source.title)  ·  \(source.authority.label)")
        }
    }

    // Two signals, reported separately because one is a guarantee and the other is a guess.
    // Reporting a single "grounding" percentage is what let an answer about the wrong
    // repository read as fully supported.
    //
    // Skipped entirely when there is nothing to ground. A counted answer cites no passage by
    // construction, and printing "citations 0/0" under a correct count reads as a failed check
    // rather than an inapplicable one. The receipt still says how the answer was produced.
    let total = turn.verdicts.count
    if total > 0 {
        let resolved = turn.verdicts.filter(\.citationResolves).count
        let weak = turn.verdicts.filter { $0.citationResolves && $0.score < Grounding.overlapThreshold }
        print("")
        print("citations    \(resolved)/\(total) resolve to a source that was actually supplied")
        if weak.isEmpty {
            print("overlap      \(total)/\(total) sentences share vocabulary with the source they cite")
        } else {
            print("overlap      \(weak.count) of \(total) below \(String(format: "%.2f", Grounding.overlapThreshold)):")
            for verdict in weak {
                let cited = verdict.citedSource.map { "[\($0)]" } ?? "[uncited]"
                print("  \(String(format: "%.2f", verdict.score)) \(cited)  \(verdict.sentence.prefix(100))")
                if !verdict.unsupported.isEmpty {
                    print("        not in that source: \(verdict.unsupported.prefix(6).joined(separator: ", "))")
                }
            }
        }
    }
    if let model = turn.modelName { print("model        \(model)") }
    if let receipt = turn.receipt { print("receipt      \(receipt.shortCode)") }
    // Said out loud. The reader is about to close the terminal assuming this thread is on disk.
    if let failure = turn.persistenceError { print("WARNING      \(failure)") }
}

// MARK: - Timeline

/// `opencore timeline` — every event, from every source, in one ordering.
///
/// The store held 1,244 events and nothing displayed them. Events are what claims are not:
/// a claim says what is, an event says what happened, and for sources that yield no claims
/// (notes, files, most calendar entries) the timeline is the only thing they contribute.
func timeline() async throws {
    let store = try await openStore()
    let window = option("since").flatMap(parseDuration) ?? 90 * 86_400
    let since = Date().addingTimeInterval(-window)

    let events = try await store.events(from: since, to: Date(), limit: option("limit").flatMap(Int.init) ?? 60)
    guard !events.isEmpty else {
        print("no events in the last \(Int(window / 86_400)) days")
        return
    }

    var lastDay = ""
    for event in events {
        let day = dateFormatter.string(from: event.occurredAt)
        if day != lastDay {
            print("\n\(day)")
            lastDay = day
        }
        let subject = try await store.entity(event.subject)?.canonicalName ?? "?"
        let detail = event.detail.replacingOccurrences(of: "\n", with: " ")
        print("  \(event.verb.padding(toLength: 10, withPad: " ", startingAt: 0)) \(subject.padding(toLength: 22, withPad: " ", startingAt: 0)) \(detail.prefix(78))")
    }
    print("\n\(events.count) events")
}

// MARK: - Corrections

/// `opencore correct` — the feature the whole design document was built around, and the one
/// that had no way to be invoked.
///
/// A correction does not edit the wrong claim. It asserts a new one at directStatement
/// authority, retracts the old, and records **why the old belief was reachable**, which is
/// the part that lets the extractor be fixed rather than the symptom patched.
func correctClaim(_ prefix: String) async throws {
    let store = try await openStore()

    let matches = try await store.allClaims(currentOnly: true, limit: 5_000)
        .filter { $0.id.value.hasPrefix(prefix) }
    guard let wrong = matches.first, matches.count == 1 else {
        if matches.isEmpty {
            print("no current claim whose id starts with '\(prefix)'. Find one with: opencore claims")
        } else {
            print("'\(prefix)' matches \(matches.count) claims. Use more characters.")
        }
        exit(1)
    }

    guard let newValue = option("to") else {
        print("--to is required: the corrected value.")
        exit(1)
    }
    guard let reason = option("reason") else {
        print("--reason is required. A correction with no stated reason is indistinguishable from a typo.")
        exit(1)
    }

    let subject = try await subjectName(wrong, in: store)
    let oldValue = try await claimValue(wrong, in: store)

    // Resolve the new value to an entity if one exists, so the correction lands in the graph
    // rather than as a dangling string.
    let resolved = try await store.resolve(surface: newValue).first?.0

    let asserted = CoreClaim(
        subject: wrong.subject,
        predicate: wrong.predicate,
        objectEntity: resolved?.id,
        literal: resolved == nil ? newValue : nil,
        confidence: 1.0,
        authority: .directStatement,
        derivation: .corrected,
        validity: Validity(validFrom: wrong.validity.validFrom, observedAt: Date()),
        domain: wrong.domain
    )

    try await BeliefEngine(store: store).correct(
        supersedingClaim: wrong.id,
        with: asserted,
        reason: reason,
        priorFailure: option("because")
    )

    print("corrected   \(subject) \(wrong.predicate)")
    print("  was       \(oldValue)  [\(wrong.authority.label)]")
    print("  now       \(newValue)  [direct statement]")
    print("  reason    \(reason)")
    if let because = option("because") {
        print("  because   \(because)")
    } else {
        print("\n  Consider --because: recording WHY the old belief was reachable is what lets")
        print("  the extractor be fixed instead of the symptom patched.")
    }
    print("\n  The old claim is retracted, not deleted. `opencore memory log` shows the change.")
}

// MARK: - Rebuild

/// `opencore rebuild` rehearses on a copy and prints what would change. It never writes to the
/// store it was pointed at. `--apply-rehearsal DIR` is the separate, reviewed step.
func rebuild() async throws {
    if let rehearsal = option("explain") {
        printExplanation(try RebuildReport.load(from: URL(fileURLWithPath: (rehearsal as NSString).expandingTildeInPath)))
        return
    }
    let store = try await openStore()
    if let approved = option("apply-rehearsal") {
        let directory = URL(fileURLWithPath: (approved as NSString).expandingTildeInPath)
        let report = try RebuildReport.load(from: directory)
        printRehearsal(report)
        let outcome: RebuildApplyOutcome
        do {
            outcome = try await RebuildRehearsal(store: store).apply(report)
        } catch let refusal as RebuildSafetyError {
            FileHandle.standardError.write(Data("\n\(refusal.localizedDescription)\n".utf8))
            exit(1)
        }
        print("\napplied. The store as it was is in \(outcome.backupPath).")
        print("past answers traced after applying: \(outcome.receipts.filter { $0.outcome == .resolves }.count) resolve, \(outcome.receiptsBroken) broken, \(outcome.receipts.filter { $0.outcome == .noLinks }.count) had no links")
        try await reembed(store: store, because: "applying a rehearsal left passages without vectors")
        return
    }

    let directory = option("work-dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? RebuildRehearsal.defaultDirectory()
    print("rehearsing on a copy in \(directory.path)")
    print("the store itself is not touched\n")
    let report = try await RebuildRehearsal(store: store).rehearse(in: directory, log: progress)
    printRehearsal(report)
    if report.canApply {
        print("\nTo apply this after reading it:")
        print("  opencore rebuild --apply-rehearsal \"\(directory.path)\"")
    }
}

func printRehearsal(_ report: RebuildReport) {
    let diff = report.diff
    print(String(format: "rehearsal took %.0fs", report.seconds))
    print("")
    print("  table               before     after")
    for row in diff.counts {
        print("  \(row.table.padding(toLength: 18, withPad: " ", startingAt: 0))  \(String(format: "%6d    %6d", row.before, row.after))\(row.before == row.after ? "" : "   (\(row.after > row.before ? "+" : "")\(row.after - row.before))")")
    }
    print("")
    print("  claims retired          \(diff.claimsRetired)")
    print("  claim rows dropped      \(diff.claimRowsDropped)")
    print("  claims restored         \(diff.claimsRestored)")
    print("  claims added            \(diff.claimsAdded)")
    print("  domains raised          \(diff.domainsRaised)")
    print("  domains lowered         \(diff.domainsLowered)")
    print("  authority changed       \(diff.authorityChanged)")
    print("  held in quarantine      \(diff.quarantineHeld)")
    print("  beliefs changed         \(diff.beliefsChanged)")
    print("  beliefs added           \(diff.beliefsAdded)")
    print("  open contradictions     \(diff.openContradictionsBefore) -> \(diff.openContradictionsAfter)")
    print("  contradiction rows lost \(diff.contradictionRowsDropped)")
    print("  belief versions lost    \(diff.beliefVersionsDropped)")
    print("  receipts in store       \(diff.receiptsTotal)")
    print("    with evidence rows    \(diff.receiptsWithEvidence)")
    print("    with claim links      \(diff.receiptsWithClaims)")
    print("    trace resolves        \(diff.receiptsResolving)")
    print("    trace broken          \(diff.receiptsBroken)")
    print("    never had links       \(diff.receiptsWithoutLinks)")
    print("  receipt links kept      \(diff.receiptLinksKept) of \(diff.receiptLinksBefore)")
    print("  corrections kept        \(diff.correctionsKept) of \(diff.correctionsBefore)")
    print("  corrections undone      \(diff.correctionsUndone)")
    print("  passages needing vector \(diff.chunksWithoutVector)")
    let narrative = RebuildNarrative(report)
    print("\n\(narrative.headline)")
    for finding in narrative.findings {
        print("\n  \(finding.title): \(finding.summary)")
        finding.breakdown.forEach { print("    \($0)") }
    }
    print("\n  Every change, by id and reason: opencore rebuild --explain \"\((report.pristinePath as NSString).deletingLastPathComponent)\"")
    for (name, rows) in diff.samples.sorted(by: { $0.key < $1.key }) where !rows.isEmpty {
        print("\n  \(name), first \(rows.count):")
        for row in rows.prefix(8) {
            print("    \(row.subject) \(row.predicate) = \(row.value.prefix(70))\(row.note.map { "  (\($0.prefix(70)))" } ?? "")")
        }
    }
    if !report.warnings.isEmpty {
        print("\nWARNINGS")
        report.warnings.forEach { print("  \($0)") }
    }
    if !report.blockers.isEmpty {
        print("\nBLOCKED, this rehearsal cannot be applied")
        report.blockers.forEach { print("  \($0)") }
    }
}

/// Every row behind a rehearsal's totals. Prints the owner's own claims, so it stays a terminal
/// command and writes no file.
func printExplanation(_ report: RebuildReport) {
    let explanation = report.explanation
    print("claims (\(explanation.claims.count) changes, \(explanation.unexplained) unexplained)")
    for change in explanation.claims {
        let authority = change.authorityBefore.map { "\($0)" } ?? "-"
        print("  \(change.claimID)  \(change.kind.rawValue)  \(change.reason.rawValue)  authority \(authority)>\(change.authorityAfter)  domain \(change.domainBefore ?? "-")>\(change.domainAfter)\(change.heldAtEarlierDomain ? "  held" : "")\(change.relatedClaimID.map { "  see \($0)" } ?? "")")
        print("    \(change.subject) \(change.predicate) = \(change.value.prefix(90))")
    }
    print("\nbeliefs (\(explanation.beliefs.count))")
    for belief in explanation.beliefs {
        print("  \(belief.subject) \(belief.predicate)  \(belief.reason.rawValue)")
        print("    was \(belief.before.map { String($0.prefix(80)) } ?? "no belief") (\(belief.claimBefore ?? "-"))")
        print("    now \(belief.after.prefix(80)) (\(belief.claimAfter))")
    }
    print("\ncontradictions (\(explanation.contradictions.count))")
    for row in explanation.contradictions {
        print("  \(row.id)  \(row.fate.rawValue)  \(row.subject) \(row.predicate)  \(row.resolutionBefore ?? "-")>\(row.resolutionAfter)")
    }
    print("\nreceipts (\(explanation.receipts.count))")
    for receipt in explanation.receipts {
        print("  \(receipt.code)  \(receipt.outcome.rawValue)  \(receipt.detail)")
    }
}

/// Re-derive the dense leg, or say loudly that it is empty.
///
/// Never silently proceeds without vectors. A search that ran without its dense leg is not the
/// same search, and the difference is invisible in the output.
func reembed(store: Store, because reason: String) async throws {
    let total = try await store.chunkCount()
    guard total > 0 else { return }

    if flag("no-embed") {
        print("\n!  dense leg is EMPTY (\(reason)) and --no-embed was passed.")
        print("   Retrieval is lexical-only until `opencore embed` runs.")
        return
    }
    guard let provider = embedder() else {
        print("\n!  dense leg is EMPTY (\(reason)) and no embedding provider is available here.")
        print("   Retrieval is lexical-only. Nothing will say so at query time.")
        return
    }

    print("\nre-embedding \(total) chunks with \(provider.modelIdentifier)")
    _ = try await EmbeddingIndexer(store: store, provider: provider)
        .run(batchSize: option("batch").flatMap(Int.init) ?? 32, log: progress)

    let covered = try await store.embeddedChunkCount(model: provider.modelIdentifier)
    print("vectors     \(covered)/\(total) chunks embedded")
    if covered < total {
        print("!  \(total - covered) chunks have no vector. The dense leg cannot see them.")
    }
}

// MARK: - Export

func exportStore() async throws {
    let store = try await openStore()
    let name = option("format") ?? "jsonl"
    guard let format = Exporter.Format(rawValue: name) else {
        print("unknown format '\(name)'. One of: \(Exporter.Format.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(1)
    }

    let directory: URL
    if let path = option("to") {
        directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        let stamp = dateFormatter.string(from: Date())
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("opencore-export-\(stamp)", isDirectory: true)
    }

    print("exporting as \(format.rawValue)")
    let outcome = try await Exporter(store: store).export(to: directory, format: format, log: progress)

    for file in outcome.files.sorted(by: { $0.name < $1.name }) {
        print("  \(file.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(file.rows) rows, \(file.bytes / 1024)KB")
    }
    print("\n\(outcome.files.count) file(s), \(outcome.totalBytes / 1024)KB total")
    print(outcome.directory.path)
}

// MARK: - MCP

func serveMCP() async throws {
    let store = try await openStore()
    let server = MCPServer(
        store: store,
        embedder: embedder(quiet: true),
        // Opt-in, and named to be uncomfortable to type. An MCP client's query text is
        // written by a model, and a model asking about your diagnosis is not consent.
        sensitiveDomainsUnlockable: flag("unsafe-expose-sensitive") || SharedConfig.load().exposeSensitiveDomainsOverMCP
    )
    await server.run()
}

// MARK: - Background Daemon

enum DaemonCommands {
    static let label = "com.gunnar.opencore.sync"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/opencore-daemon.log")
    }

    static var binaryPath: String {
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/opencore").path
        if FileManager.default.isExecutableFile(atPath: localBin) {
            return localBin
        }
        return CommandLine.arguments.first ?? localBin
    }

    static func install() throws {
        let interval = option("interval").flatMap(Int.init) ?? 3600
        let plistDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "daemon", "run"],
            "StartInterval": interval,
            "RunAtLoad": false,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        let boot = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        print("installed   \(plistURL.path)")
        print("binary      \(binaryPath)")
        print("interval    every \(interval)s")
        print("log         \(logURL.path)")
        print("launchctl   \(boot == 0 ? "loaded" : "written (load with launchctl bootstrap)")")
    }

    static func uninstall() throws {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
            print("removed     \(plistURL.path)")
        } else {
            print("daemon is not installed")
        }
    }

    static func status() {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let uid = getuid()
        let loaded = runLaunchctl(["print", "gui/\(uid)/\(label)"]) == 0
        print("label       \(label)")
        print("plist       \(installed ? plistURL.path : "not installed")")
        print("state       \(loaded ? "loaded in launchd" : (installed ? "plist present, not loaded" : "inactive"))")
        print("log         \(logURL.path)")
    }

    static func run() async throws {
        print("[\(ISO8601DateFormatter().string(from: Date()))] opencore daemon run starting")
        try? await syncAgentMemory()
        if GitHubConnector.resolveToken() != nil {
            try? await syncGitHub()
        }
        try? await syncApple("notes")
        try? await embed()
        print("[\(ISO8601DateFormatter().string(from: Date()))] opencore daemon run finished")
    }

    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - Dispatch

do {
    // The whole command is one root span, so everything below it nests into a single tree
    // rather than arriving as a flat list of unrelated timings.
    try await Telemetry.span(
        [arguments.first, positional(1)].compactMap { $0 }.joined(separator: " "),
        .cli
    ) { _ in
    switch arguments.first {
    case "doctor":
        try await doctor()
    case "sync":
        switch positional(1) {
        case "github": try await syncGitHub()
        case "files": try await syncFiles()
        case "agent-memory", "workspace": try await syncAgentMemory()
        case "calendar", "reminders", "notes": try await syncApple(positional(1)!)
        case "mcp":
            guard let name = positional(2) else { print("usage: opencore sync mcp NAME"); exit(1) }
            try await MCPSourceCommands.sync(name)
        default:
            print("usage: opencore sync github | files | agent-memory | calendar | reminders | notes | mcp NAME")
            exit(1)
        }
    case "repair-agent-memory":
        try await repairAgentMemoryPolicy()
    case "mcp-source":
        switch positional(1) {
        case "discover": try await MCPSourceCommands.discover()
        case "oauth": try await MCPSourceCommands.oauth()
        case "add":
            guard let name = positional(2) else { print("usage: opencore mcp-source add NAME --command CMD --tool TOOL"); exit(1) }
            try await MCPSourceCommands.add(name)
        case "list": try await MCPSourceCommands.list()
        case "remove":
            guard let name = positional(2) else { print("usage: opencore mcp-source remove NAME"); exit(1) }
            try await MCPSourceCommands.remove(name)
        default: MCPSourceCommands.usage()
        }
    case "embed":
        try await embed()
    case "search":
        guard let query = positional(1) else { print("usage: opencore search \"TEXT\""); exit(1) }
        try await runSearch(query)
    case "passages":
        guard let query = positional(1) else { print("usage: opencore passages \"TEXT\""); exit(1) }
        try await runPassages(query)
    case "eval":
        try await Eval.run()
    case "ask":
        guard let query = positional(1) else { print("usage: opencore ask \"QUESTION\" [--no-fm]"); exit(1) }
        try await ask(query)
    case "propose-claims":
        try await proposeClaims()
    case "claims":
        try await listClaims(positional(1))
    case "contradictions":
        try await listContradictions()
    case "memory":
        switch positional(1) {
        case "log": try await memoryLog()
        case "checkout":
            guard let date = positional(2) else { print("usage: opencore memory checkout YYYY-MM-DD"); exit(1) }
            try await memoryCheckout(date)
        default: print("usage: opencore memory log | opencore memory checkout YYYY-MM-DD"); exit(1)
        }
    case "receipts":
        try await listReceipts()
    case "trace":
        guard let code = positional(1) else { print("usage: opencore trace CODE"); exit(1) }
        try await trace(code)
    case "chat":
        guard let question = positional(1) else {
            print("usage: opencore chat \"QUESTION\" [--resume ID]")
            exit(1)
        }
        try await chat(question, resuming: option("resume"))
    case "chats":
        try await listChats()
    case "timeline":
        try await timeline()
    case "correct":
        guard let claim = positional(1) else {
            print("usage: opencore correct CLAIM_ID --to VALUE --reason \"...\" [--because \"...\"]")
            exit(1)
        }
        try await correctClaim(claim)
    case "rebuild":
        try await rebuild()
    case "export":
        try await exportStore()
    case "mcp":
        try await serveMCP()
    case "daemon":
        switch positional(1) {
        case "install": try DaemonCommands.install()
        case "uninstall": try DaemonCommands.uninstall()
        case "status", nil: DaemonCommands.status()
        case "run": try await DaemonCommands.run()
        default:
            print("usage: opencore daemon install [--interval SECONDS] | status | uninstall | run")
            exit(1)
        }
    case "help", "--help", "-h", nil:
        usage()
    case let unknown?:
        print("unknown command: \(unknown)\n")
        usage()
        exit(1)
    }
    }
    await writeTelemetryReport()
} catch {
    // The report comes before the error line. A run that failed partway is exactly when the
    // tree is worth reading, and the failing span is in it.
    await writeTelemetryReport()
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
