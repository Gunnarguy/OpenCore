import CoreGraph
import CoreIngest
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

func positional(_ index: Int) -> String? {
    let values = arguments.filter { !$0.hasPrefix("--") }
    let skipped = arguments.enumerated().compactMap { offset, value -> String? in
        guard offset > 0, arguments[offset - 1].hasPrefix("--") else { return nil }
        return value
    }
    let cleaned = values.filter { !skipped.contains($0) }
    return index < cleaned.count ? cleaned[index] : nil
}

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

func usage() {
    print("""
    opencore — an evidence-native store for your own digital history

    USAGE
      opencore doctor                        check the database and credentials
      opencore sync github [--login NAME]    ingest repositories, commits, READMEs, languages
                           [--commits N]     commits per repository (default 100)
                           [--include-forks]
      opencore search "TEXT"                 hybrid retrieval over objects, with signals
      opencore ask "QUESTION"                assemble an answer from claims, with a receipt
      opencore claims [ENTITY]               current claims, optionally for one entity
      opencore contradictions [--open]       detected conflicts and how they were settled
      opencore memory log [--since 30d]      belief changes over a window
      opencore memory checkout YYYY-MM-DD    what OpenCore believed at a past instant
      opencore receipts [--limit N]          recent answer receipts
      opencore trace CODE                    the evidence behind one answer
      opencore rebuild                       drop derived layers and re-derive from objects

    Objects are the floor. Everything above them is rebuildable.
    """)
}

// MARK: - Commands

func openStore() async throws -> Store {
    let path = option("db").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    return try await Store.open(at: path)
}

/// Render a claim's object side: an entity's name if it points at one, otherwise its literal.
func claimValue(_ claim: CoreClaim, in store: Store) async throws -> String {
    if let objectEntity = claim.objectEntity, let entity = try await store.entity(objectEntity) {
        return entity.canonicalName
    }
    return claim.literal ?? "∅"
}

func subjectName(_ claim: CoreClaim, in store: Store) async throws -> String {
    try await store.entity(claim.subject)?.canonicalName ?? String(claim.subject.value.prefix(8))
}

func doctor() async throws {
    let store = try await openStore()
    print("database    \(await store.database.path.path)")

    let objects = try await store.objectCount()
    let claims = try await store.claimCount()
    let entities = try await store.entities().count
    let unresolved = try await store.contradictions(unresolvedOnly: true).count

    print("objects     \(objects)")
    print("entities    \(entities)")
    print("claims      \(claims) current")
    print("conflicts   \(unresolved) unresolved")

    let sources = try await store.sources()
    if sources.isEmpty {
        print("sources     none — run: opencore sync github")
    } else {
        for source in sources {
            let synced = source.lastSyncedAt.map { dateFormatter.string(from: $0) } ?? "never"
            print("sources     \(source.displayName)  last synced \(synced)")
        }
    }

    if GitHubConnector.resolveToken() != nil {
        print("github      token available")
    } else {
        print("github      NO TOKEN — set GITHUB_TOKEN or run: gh auth login")
    }

    if !(try await store.objectCountsByKind()).isEmpty {
        print("\nby kind")
        for (kind, count) in try await store.objectCountsByKind() {
            print("  \(kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(count)")
        }
    }
}

func syncGitHub() async throws {
    guard let token = GitHubConnector.resolveToken(explicit: option("token")) else {
        throw ConnectorError.missingCredential("set GITHUB_TOKEN, or run `gh auth login`")
    }

    var login = option("login")
    if login == nil {
        // Ask GitHub who the token belongs to rather than making the user repeat it.
        struct User: Decodable { let login: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        login = (try? JSONDecoder().decode(User.self, from: data))?.login
    }
    guard let login else { throw ConnectorError.missingCredential("could not determine GitHub login; pass --login") }

    let store = try await openStore()
    let connector = GitHubConnector(
        login: login,
        token: token,
        commitsPerRepo: option("commits").flatMap(Int.init) ?? 100,
        includeForks: flag("include-forks")
    )
    try await store.upsert(connector.source)

    print("syncing github:\(login)")
    let started = Date()
    let batch = try await connector.fetch(since: nil, cursor: nil) { message in
        FileHandle.standardError.write(Data(("  " + message + "\n").utf8))
    }

    let ingest = try await store.ingest(batch.objects)
    print("objects     \(ingest.inserted) new, \(ingest.updated) changed, \(ingest.unchanged) unchanged")

    let entities = try await EntityResolver(store: store).resolve(objects: batch.objects)
    print("entities    \(entities.entities) resolved, \(entities.aliases) aliases")

    let extraction = try await ClaimExtractor(store: store).extract(from: batch.objects)
    print("claims      \(extraction.claims) extracted from \(extraction.evidence) evidence spans")
    print("events      \(extraction.events)")

    let reconciled = try await BeliefEngine(store: store).reconcile()
    print("beliefs     \(reconciled.beliefsWritten) written")
    print("conflicts   \(reconciled.contradictionsFound) found — \(reconciled.resolved) resolved, \(reconciled.unresolved) left open")

    try await store.markSynced(connector.source.id, at: Date(), cursor: batch.cursor)
    print("\ndone in \(Int(Date().timeIntervalSince(started)))s")
}

func runSearch(_ query: String) async throws {
    let store = try await openStore()
    let (domain, requested) = AdmissionPolicy.classifyDomain(
        query,
        knownEntitySurfaces: try await store.aliasSurfaces()
    )
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
    if outcome.blockedByDomain > 0 {
        print("            \(outcome.blockedByDomain) candidates withheld by domain policy")
    }
    for (signal, reason) in outcome.unavailableSignals.sorted(by: { $0.key < $1.key }) {
        print("unavailable \(signal): \(reason)")
    }
    print("")

    for (index, hit) in outcome.hits.enumerated() {
        let signals = hit.signals
            .sorted { $0.key < $1.key }
            .map { "\($0.key.prefix(3)) \(String(format: "%.2f", $0.value))" }
            .joined(separator: "  ")
        print("\(String(format: "%2d", index + 1)). \(bar(hit.score)) \(String(format: "%.3f", hit.score))  \(hit.object.title)")
        print("    \(hit.object.kind.rawValue) · \(hit.object.authority.label) · \(signals)")
        if let uri = hit.object.uri, !uri.isEmpty { print("    \(uri)") }
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
            let marker = point.derivation == .observed ? "•" : "~"
            print("\(marker) \(point.statement)")
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

func listClaims(_ entityName: String?) async throws {
    let store = try await openStore()

    let claims: [CoreClaim]
    if let entityName {
        let matches = try await store.resolve(surface: entityName)
        guard let entity = matches.first?.0 else {
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
        let marker = claim.derivation == .observed ? "•" : "~"
        let validity = claim.validity.validFrom.map { " from \(dateFormatter.string(from: $0))" } ?? ""
        print("\(marker) \(subject) \(claim.predicate) \(value)")
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
        let verb = belief.version == 1 ? "LEARNED" : "UPDATED"
        print("\(dateFormatter.string(from: belief.decidedAt))  \(verb)  v\(belief.version)")
        print("  \(subject) \(claim.predicate) → \(value)")
        print("  \(belief.reason)")
        print("")
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

func rebuild() async throws {
    let store = try await openStore()
    let objectCount = try await store.objectCount()
    print("re-deriving from \(objectCount) objects (objects themselves are not touched)")

    // Proof that the trust stack holds: everything below `object` is disposable.
    try await store.database.execute("DELETE FROM claim")
    try await store.database.execute("DELETE FROM evidence")
    try await store.database.execute("DELETE FROM contradiction")
    try await store.database.execute("DELETE FROM belief")
    try await store.database.execute("DELETE FROM event")
    try await store.database.execute("DELETE FROM edge")

    var offset = 0
    var all: [CoreObject] = []
    while true {
        let rows = try await store.database.query("SELECT id FROM object LIMIT 500 OFFSET ?", [.integer(Int64(offset))])
        if rows.isEmpty { break }
        let ids = rows.map { ObjectID($0.requireString("id")) }
        all.append(contentsOf: try await store.objects(ids: ids))
        offset += 500
    }

    let entities = try await EntityResolver(store: store).resolve(objects: all)
    let extraction = try await ClaimExtractor(store: store).extract(from: all)
    let reconciled = try await BeliefEngine(store: store).reconcile()

    print("entities    \(entities.entities)")
    print("claims      \(extraction.claims)")
    print("events      \(extraction.events)")
    print("beliefs     \(reconciled.beliefsWritten)")
    print("conflicts   \(reconciled.contradictionsFound)")
}

// MARK: - Dispatch

do {
    switch arguments.first {
    case "doctor":
        try await doctor()
    case "sync":
        guard positional(1) == "github" else { print("only `sync github` exists so far"); exit(1) }
        try await syncGitHub()
    case "search":
        guard let query = positional(1) else { print("usage: opencore search \"TEXT\""); exit(1) }
        try await runSearch(query)
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
