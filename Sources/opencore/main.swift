import CoreGraph
import CoreIngest
import CoreMCP
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
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

    RETRIEVAL
      opencore embed [--batch N]             build on-device vectors for every passage
      opencore search "TEXT"                 object-level hybrid retrieval, signals shown
      opencore passages "TEXT" [--no-context]  passage retrieval: dense + BM25, RRF, MMR
      opencore ask "QUESTION"                an answer assembled from claims, with a receipt

    KNOWLEDGE
      opencore claims [ENTITY]               current claims, observed vs inferred
      opencore contradictions [--open]       conflicts, and how each was settled
      opencore memory log [--since 30d]      what it learned or changed its mind about
      opencore memory checkout YYYY-MM-DD    what it believed on a past date
      opencore receipts [--limit N]
      opencore trace CODE                    the evidence behind one answer

    INFRASTRUCTURE
      opencore mcp [--unsafe-expose-sensitive]   serve MCP over stdio
      opencore doctor                            database, credentials, coverage
      opencore rebuild                           re-derive everything from objects

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
    let since = try await store.sources().first { $0.id == connector.source.id }?.lastSyncedAt
    if let since { progress("incremental since \(dateFormatter.string(from: since))") }

    let batch = try await connector.fetch(since: since, cursor: nil, log: progress)
    guard !batch.objects.isEmpty else {
        print("nothing new")
        try await store.markSynced(connector.source.id, at: Date(), cursor: batch.cursor)
        return
    }

    let outcome = try await IngestPipeline(store: store).run(objects: batch.objects, log: progress)
    try await store.markSynced(connector.source.id, at: Date(), cursor: batch.cursor)

    report(outcome)
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
    let outcome = try await search.search(
        query: query,
        queryClass: classification.queryClass,
        policy: policy,
        limit: option("limit").flatMap(Int.init) ?? 8,
        expandContext: !flag("no-context")
    )

    print("class       \(classification.queryClass.rawValue)")
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
    let reasoner = Reasoner(store: store, search: HybridSearch(store: store))
    let answer = try await reasoner.answer(query)

    print("Q: \(query)\n")

    if let insufficient = answer.insufficientEvidence {
        print("Not enough evidence.")
        print(insufficient)
    } else {
        print(answer.summary + "\n")
        for point in answer.points.prefix(12) {
            print("\(point.derivation == .observed ? "•" : "~") \(point.statement)")
            print("  confidence \(String(format: "%.2f", point.confidence)) · \(point.authority.label) · \(point.derivation.rawValue)")
            for evidence in point.supporting.prefix(2) {
                print("  ← \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(110))")
            }
            for evidence in point.counter.prefix(2) {
                print("  ✗ counter: \(evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(110))")
            }
        }
        print("\n  • observed directly    ~ inferred")
    }

    if !answer.contradictions.isEmpty {
        print("\nContradictions touching this answer")
        for contradiction in answer.contradictions.prefix(5) {
            print("  \(contradiction.kind.rawValue) → \(contradiction.resolution.rawValue)")
            print("    \(contradiction.reason)")
        }
    }

    printReceipt(answer.receipt)
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
    model                 \(receipt.model ?? "none — assembled from claims")
    objects transmitted   \(receipt.objectsTransmitted)
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

    let claims: [CoreClaim]
    if let entityName {
        guard let entity = try await store.resolve(surface: entityName).first?.0 else {
            print("no entity known as '\(entityName)'")
            return
        }
        print("\(entity.canonicalName) (\(entity.kind.rawValue))\n")
        claims = try await store.claims(subject: entity.id)
    } else {
        claims = try await store.allClaims(limit: option("limit").flatMap(Int.init) ?? 60)
    }

    for claim in claims {
        let value = try await claimValue(claim, in: store)
        let subject = try await subjectName(claim, in: store)
        let validity = claim.validity.validFrom.map { " from \(dateFormatter.string(from: $0))" } ?? ""
        print("\(claim.derivation == .observed ? "•" : "~") \(subject) \(claim.predicate) \(value)")
        print("   conf \(String(format: "%.2f", claim.confidence)) · \(claim.authority.label)\(validity)")
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
    let store = try await openStore()
    let beliefs = try await store.beliefs(asOfKnowledge: instant)

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
        print("this receipt admitted no evidence")
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

// MARK: - Rebuild

func rebuild() async throws {
    let store = try await openStore()
    let objectCount = try await store.objectCount()
    print("re-deriving from \(objectCount) objects (objects themselves are not touched)")

    // Proof that the trust stack holds. Vectors go too: they are derived from chunk text,
    // and a chunk whose boundaries moved has a vector that describes text that no longer
    // exists. Re-embed with `opencore embed`.
    for table in ["claim", "evidence", "contradiction", "belief", "event", "edge", "chunk_vector", "chunk", "embedding_run"] {
        try await store.database.execute("DELETE FROM \(table)")
    }

    var offset = 0
    var all: [CoreObject] = []
    while true {
        let rows = try await store.database.query("SELECT id FROM object LIMIT 500 OFFSET ?", [.integer(Int64(offset))])
        if rows.isEmpty { break }
        all.append(contentsOf: try await store.objects(ids: rows.map { ObjectID($0.requireString("id")) }))
        offset += 500
    }

    let outcome = try await IngestPipeline(store: store).run(objects: all, storeObjects: false, log: progress)
    report(outcome)
}

// MARK: - MCP

func serveMCP() async throws {
    let store = try await openStore()
    let server = MCPServer(
        store: store,
        embedder: embedder(quiet: true),
        // Opt-in, and named to be uncomfortable to type. An MCP client's query text is
        // written by a model, and a model asking about your diagnosis is not consent.
        sensitiveDomainsUnlockable: flag("unsafe-expose-sensitive")
    )
    await server.run()
}

// MARK: - Dispatch

do {
    switch arguments.first {
    case "doctor":
        try await doctor()
    case "sync":
        switch positional(1) {
        case "github": try await syncGitHub()
        case "files": try await syncFiles()
        case "calendar", "reminders", "notes": try await syncApple(positional(1)!)
        default:
            print("usage: opencore sync github | files | calendar | reminders | notes")
            exit(1)
        }
    case "embed":
        try await embed()
    case "search":
        guard let query = positional(1) else { print("usage: opencore search \"TEXT\""); exit(1) }
        try await runSearch(query)
    case "passages":
        guard let query = positional(1) else { print("usage: opencore passages \"TEXT\""); exit(1) }
        try await runPassages(query)
    case "ask":
        guard let query = positional(1) else { print("usage: opencore ask \"QUESTION\""); exit(1) }
        try await ask(query)
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
    case "rebuild":
        try await rebuild()
    case "mcp":
        try await serveMCP()
    case "help", "--help", "-h", nil:
        usage()
    case let unknown?:
        print("unknown command: \(unknown)\n")
        usage()
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
