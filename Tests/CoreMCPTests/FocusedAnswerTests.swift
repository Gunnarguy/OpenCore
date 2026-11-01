import CoreGraph
import CoreJSONRPC
import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Testing

@testable import CoreMCP
@testable import CoreReason
@testable import CoreSearch
@testable import CoreStore

private func temporaryStore() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-focus-\(UUID().uuidString)/test.sqlite3"))
}

private func tool(_ server: MCPServer, _ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> String {
    let payload: JSONValue = .object([
        "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
        "params": .object(["name": .string(name), "arguments": .object(arguments)]),
    ])
    let request = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(payload))
    let result = try await server.handle(request)
    guard case .object(let dict) = result, case .array(let content)? = dict["content"],
          case .object(let first)? = content.first, case .string(let text)? = first["text"]
    else { Issue.record("unexpected result shape"); return "" }
    return text
}

private let github = Source(kind: .github, handle: "user", displayName: "GitHub", defaultAuthority: .authoredArtifact, defaultDomain: .project)
private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

private func repository(_ name: String, language: String = "Swift", pushed: Date) -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .repository, externalID: "user/\(name)", title: name,
        text: "user/\(name)\n\(name) is a clinical records project built for testing retrieval.",
        authoredAt: Date(timeIntervalSince1970: 1_600_000_000), domain: .project, authority: .authoredArtifact,
        metadata: ["language": language, "archived": "false", "pushed_at": stamp(pushed)]
    )
}

private func fleet(now: Date) async throws -> Store {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let recent = now.addingTimeInterval(-3 * 86_400)
    var objects = ["OpenClinicalA", "OpenClinicalB", "OpenClinicalC", "OpenClinicalD", "OpenClinicalE", "OpenClinicalF"].map { repository($0, pushed: recent) }
    // A passage in one repository that mentions another, so retrieval reaches a subject the
    // question did not name. That is how other repositories' claims got into the answer.
    objects[1].text += "\nIt shares its status page with OpenClinicalC."
    _ = try await IngestPipeline(store: store, now: now).run(objects: objects)
    return store
}

// The bug, on the real store: asking about OpenClinic's status returned twelve lines of language
// and commit claims from several repositories. `status=active` existed, at a low authority tier
// by honest design, so sorting on authority put it last and `.prefix(12)` cut it. Nothing favoured
// the entity the question named.
@Test("a question about one repository's status leads with that repository's status")
func namedEntityAndPredicateLead() async throws {
    let now = Date()
    let store = try await fleet(now: now)
    let answer = try await Reasoner(store: store).answer("What is the status of OpenClinicalC?", persistReceipt: false)

    let subject = CoreEntity(kind: .project, canonicalName: "OpenClinicalC", domain: .project).id
    #expect(answer.points.allSatisfy { $0.subject == subject })
    #expect(answer.points.first?.statement == "OpenClinicalC is active.")
}

// The bug: subjects came from a `Set` and the sort key tied at the same confidence, so an unchanged
// store gave different answers in different processes. A hash seed is per process, so running
// the question twice here proves nothing: the order has to be proved independent of the input.
@Test("points that tie on everything still have one order, whatever order they arrive in")
func rankingIsATotalOrder() {
    func point(_ statement: String, _ subject: String) -> AnswerPoint {
        AnswerPoint(statement: statement, supporting: [], counter: [], confidence: 0.99, authority: .authoredArtifact, derivation: .observed, claimID: ClaimID(statement), subject: EntityID(subject), predicate: Predicate.builtWith)
    }
    let points = [point("A is built with Swift.", "a"), point("B is built with Swift.", "b"), point("C is built with Swift.", "c"), point("D is built with Swift.", "d")]
    let expected = points.map(\.statement)
    for arrangement in [points, points.reversed(), [points[2], points[0], points[3], points[1]]] {
        #expect(Reasoner.ranked(arrangement, focus: .none).map(\.statement) == expected)
    }
}

@Test("the same store gives the same lines in the same order every time")
func answersAreDeterministic() async throws {
    let now = Date()
    let store = try await fleet(now: now)
    var renderings: Set<String> = []
    for _ in 0..<8 {
        let answer = try await Reasoner(store: store).answer("which clinical records projects exist", persistReceipt: false)
        renderings.insert(answer.points.map(\.statement).joined(separator: "\n"))
    }
    #expect(renderings.count == 1)
}

// The bug: `ClaimID` includes `validFrom`, so every push minted a new row for an unchanged value,
// and each became its own line. Measured 2026-10-30: 175 rows in 80 value groups.
@Test("re-observing a value adds evidence to one line, not a second line")
func duplicatesCollapseToOneLine() async throws {
    let now = Date()
    let store = try await temporaryStore()
    try await store.upsert(github)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-2 * 86_400))
        .run(objects: [repository("OpenClinicalA", pushed: now.addingTimeInterval(-3 * 86_400))])
    _ = try await IngestPipeline(store: store, now: now)
        .run(objects: [repository("OpenClinicalA", pushed: now.addingTimeInterval(-86_400))])

    let subject = CoreEntity(kind: .project, canonicalName: "OpenClinicalA", domain: .project).id
    let rows = try await store.claims(subject: subject).filter { $0.predicate == Predicate.status }
    #expect(rows.count > 1, "the fixture must hold repeated rows or this proves nothing")

    let answer = try await Reasoner(store: store).answer("status of OpenClinicalA", persistReceipt: false)
    let lines = answer.points.map(\.statement)
    #expect(lines.count == Set(lines).count)
    #expect(lines.filter { $0 == "OpenClinicalA is active." }.count == 1)
}

// The bug: `answer.passages` was computed and never printed, so `core_ask` dropped the text that
// matched, and a source that yields no claims looked like it held nothing.
@Test("core_ask shows the passages that matched")
func coreAskPrintsPassages() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let note = CoreObject(sourceID: github.id, kind: .document, externalID: "user/notes", title: "Design notes", text: "The quillberry cache is rebuilt on every launch.", authoredAt: Date(), domain: .project, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store).run(objects: [note])
    let text = try await tool(MCPServer(store: store), "core_ask", ["query": .string("quillberry cache")])
    #expect(text.contains("Matching passages:"))
    #expect(text.contains("The quillberry cache is rebuilt"))
}

// The bug: `Int(value)` on a JSON number traps, so one model-written argument ended the server
// for every client using it. A negative limit trapped later, in `hits.prefix(limit * 2)`.
@Test("hostile numeric arguments return an answer rather than ending the process")
func numericArgumentsCannotCrash() async throws {
    let store = try await temporaryStore()
    let server = MCPServer(store: store)
    _ = try await tool(server, "core_search", ["query": .string("anything"), "limit": .number(1e300)])
    _ = try await tool(server, "core_search", ["query": .string("anything"), "limit": .number(-5)])
    _ = try await tool(server, "core_changed", ["days": .number(1e300)])
    _ = try await tool(server, "core_timeline", ["days": .number(-1e300)])
    #expect(JSONValue.number(1e300).intValue == nil)
    #expect(JSONValue.number(2.5).intValue == nil)
    #expect(JSONValue.number(7).intValue == 7)

    let outcome = try await PassageSearch(store: store).search(query: "anything", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project), limit: -3)
    #expect(outcome.hits.isEmpty)
}

// The bug: a bad `as_of` parsed to nil and the tool answered with today's data under a question
// about another date, without saying so.
@Test("an unreadable as_of is refused rather than ignored")
func badAsOfIsRefused() async throws {
    let store = try await temporaryStore()
    let server = MCPServer(store: store)
    await #expect(throws: (any Error).self) {
        _ = try await tool(server, "core_ask", ["query": .string("anything"), "as_of": .string("last week")])
    }
}

// The bug: `blockedByDomain` counted real matches in blocked domains and was printed to the
// caller. A model searching for one rare word could read "1 withheld" as proof it exists.
@Test("an external caller learns nothing from what its search could not read")
func blockedCountIsNotAnOracle() async throws {
    let store = try await temporaryStore()
    let source = Source(kind: .manual, handle: "records", displayName: "Records", defaultAuthority: .authoredArtifact, defaultDomain: .medical)
    try await store.upsert(source)
    let secret = CoreObject(sourceID: source.id, kind: .note, externalID: "lab", title: "Lab", text: "zolpiquine dosage notes", authoredAt: Date(), domain: .medical, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store).run(objects: [secret])

    let server = MCPServer(store: store)
    let searched = try await tool(server, "core_search", ["query": .string("zolpiquine")])
    #expect(!searched.contains("withheld"))
    #expect(!searched.contains("zolpiquine dosage"))
    let asked = try await tool(server, "core_ask", ["query": .string("zolpiquine")])
    #expect(!asked.contains("withheld"))
    #expect(!asked.contains("zolpiquine dosage"))
}

/// A handoff document, which is where a repository's objective comes from. It sits at a higher
/// authority than the derived `status`, and that gap is the whole point of the fixture.
private func handoff(for project: String, objective: String, at date: Date) -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .file, externalID: "/repo/\(project)/STATE.md", title: "STATE.md",
        text: "# State\n\nProject: \(project)\nObjective: \(objective)\n", authoredAt: date,
        domain: .project, authority: .authoredArtifact,
        metadata: ["root": "/repo", "extension": "md", "relative_path": "\(project)/STATE.md"]
    )
}

private func statusFixture(now: Date) async throws -> Store {
    let store = try await fleet(now: now)
    let state = handoff(for: "OpenClinicalC", objective: "Close the chart import gap.", at: now.addingTimeInterval(-86_400))
    _ = try await IngestPipeline(store: store, now: now).run(objects: [state])
    return store
}

// The bug, on the real store: `objective` and `next_action` were asked for by the same word as
// `status` and sat at a higher authority, so "status of OpenClinic" opened with the objective and
// "is OpenCore active" put its status fourth. They tied on "asked", and authority broke the tie.
@Test("the predicate a question names outranks its relatives, whatever their authority")
func askedPredicateOutranksItsRelatives() async throws {
    let now = Date()
    let store = try await statusFixture(now: now)
    let asked = try await Reasoner(store: store).answer("What is the status of OpenClinicalC?", persistReceipt: false)

    let status = try #require(asked.points.first { $0.predicate == Predicate.status })
    let objective = try #require(asked.points.first { $0.predicate == Predicate.objective }, "the fixture must hold the higher-authority relative or this proves nothing")
    #expect(objective.authority.rawValue > status.authority.rawValue)
    #expect(asked.points.first?.statement == "OpenClinicalC is active.")

    let active = try await Reasoner(store: store).answer("is OpenClinicalC active", persistReceipt: false)
    #expect(active.points.first?.predicate == Predicate.status)
    // The same word order works the other way: asking for the objective leads with it.
    let goal = try await Reasoner(store: store).answer("what is the objective of OpenClinicalC", persistReceipt: false)
    #expect(goal.points.first?.predicate == Predicate.objective)
}

@Test("core_ask puts a named project's status in the first lines it prints")
func statusLeadsTheToolOutput() async throws {
    let now = Date()
    let store = try await statusFixture(now: now)
    let text = try await tool(MCPServer(store: store), "core_ask", ["query": .string("What is the status of OpenClinicalC?")])
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.prefix(2).contains("[inferred] OpenClinicalC is active."))
}

// The bug: a handoff's sentence keeps its own full stop, and the template added another, so an
// objective printed as "... the chart import gap..".
@Test("a value that is already a sentence does not gain a second full stop")
func statementsEndOnce() async throws {
    let now = Date()
    let store = try await statusFixture(now: now)
    let answer = try await Reasoner(store: store).answer("objective of OpenClinicalC", persistReceipt: false)
    #expect(answer.points.first?.statement == "OpenClinicalC's objective: Close the chart import gap.")
}

// The bug: naming an entity cut the subject list down to that entity, and a technology is the
// subject of nothing: every fact about it reads "OpenClinic is built with Swift". So "which
// projects use Swift" answered "No claims have been derived" over a store holding 53 of them.
@Test("a named technology finds the claims that point at it")
func namedValueFindsItsClaims() async throws {
    let now = Date()
    let store = try await fleet(now: now)
    let answer = try await Reasoner(store: store).answer("which projects use Swift", persistReceipt: false)
    let statements = answer.points.map(\.statement)
    #expect(statements.contains("OpenClinicalA is primarily written in Swift."))
    #expect(statements.contains("OpenClinicalF is primarily written in Swift."))
    #expect(answer.points.allSatisfy { $0.object != nil })
}

// The guard that came with the fix above. With both named, reading what points at Swift would
// pour every other Swift repository into a question about one.
@Test("a question naming a project and its technology stays on that project")
func namedSubjectStaysOnItself() async throws {
    let now = Date()
    let store = try await fleet(now: now)
    let answer = try await Reasoner(store: store).answer("does OpenClinicalB use Swift", persistReceipt: false)
    let subject = CoreEntity(kind: .project, canonicalName: "OpenClinicalB", domain: .project).id
    #expect(answer.points.allSatisfy { $0.subject == subject })
    #expect(answer.points.first?.statement == "OpenClinicalB is primarily written in Swift.")
}

// The bug: concepts come from commit scopes, so "graph", "sync" and "changes" are entities. A
// question merely containing one was read as being about it, and lost every other claim.
@Test("an ordinary word that happens to be a concept does not become the subject")
func conceptsDoNotCaptureTheQuestion() async throws {
    let now = Date()
    let store = try await fleet(now: now)
    let concept = CoreEntity(kind: .concept, canonicalName: "records", domain: .project)
    try await store.upsert([concept])
    try await store.addAliases([EntityAlias(entityID: concept.id, surface: "records", confidence: 1)])

    let answer = try await Reasoner(store: store).answer("which clinical records projects exist", persistReceipt: false)
    #expect(!answer.points.isEmpty)
}

// A new route to claims is a new route around the firewall. `store.claims(pointingAt:)` finds a
// row by its value, so a blocked subject pointing at a public technology is exactly what it would
// surface. Each route is asserted on its own: one test passing could not show another was deleted.
@Test("what points at a named entity stays behind the domain firewall")
func pointingClaimsObeyTheFirewall() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let records = Source(kind: .manual, handle: "records", displayName: "Records", defaultAuthority: .authoredArtifact, defaultDomain: .medical)
    try await store.upsert(records)

    let open = CoreObject(sourceID: github.id, kind: .document, externalID: "user/build", title: "Build notes", text: "The build uses a compiled language.", authoredAt: Date(), domain: .project, authority: .authoredArtifact)
    let closed = CoreObject(sourceID: records.id, kind: .note, externalID: "lab", title: "Lab", text: "Private build notes.", authoredAt: Date(), domain: .medical, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store).run(objects: [open, closed])

    let swift = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .publicRecord)
    let visible = CoreEntity(kind: .project, canonicalName: "HarborVisible", domain: .project)
    let blockedSubject = CoreEntity(kind: .project, canonicalName: "HarborSubject", domain: .medical)
    let blockedClaim = CoreEntity(kind: .project, canonicalName: "HarborClaim", domain: .project)
    let blockedEvidence = CoreEntity(kind: .project, canonicalName: "HarborEvidence", domain: .project)
    try await store.upsert([swift, visible, blockedSubject, blockedClaim, blockedEvidence])
    try await store.addAliases([EntityAlias(entityID: swift.id, surface: "swift", confidence: 1)])

    let openEvidence = Evidence(objectID: open.id, snippet: "The build uses a compiled language.", authority: .authoredArtifact)
    let closedEvidence = Evidence(objectID: closed.id, snippet: "Private build notes.", authority: .authoredArtifact)
    try await store.save([openEvidence, closedEvidence])

    func claim(_ subject: CoreEntity, domain: Domain) -> CoreClaim {
        CoreClaim(subject: subject.id, predicate: Predicate.builtWith, objectEntity: swift.id, confidence: 0.95, authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: domain)
    }
    let claims = [claim(visible, domain: .project), claim(blockedSubject, domain: .project), claim(blockedClaim, domain: .medical), claim(blockedEvidence, domain: .project)]
    try await store.save(claims)
    try await store.link(claim: claims[0].id, to: openEvidence.id, stance: .supports)
    try await store.link(claim: claims[1].id, to: openEvidence.id, stance: .supports)
    try await store.link(claim: claims[2].id, to: openEvidence.id, stance: .supports)
    try await store.link(claim: claims[3].id, to: closedEvidence.id, stance: .supports)

    let text = try await tool(MCPServer(store: store), "core_ask", ["query": .string("which projects use Swift")])
    #expect(text.contains("HarborVisible is built with Swift."), "the route must work or the rest proves nothing")
    #expect(!text.contains("HarborSubject"), "a subject in a blocked domain")
    #expect(!text.contains("HarborClaim"), "a claim in a blocked domain")
    #expect(!text.contains("HarborEvidence"), "a claim whose only evidence is in a blocked object")

    let chat = try await Conversation(store: store).retrieve(query: "which projects use Swift", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project), window: nil)
    let shown = chat.sources.map(\.text).joined(separator: "\n")
    #expect(shown.contains("HarborVisible is built with Swift."))
    #expect(!shown.contains("HarborSubject"))
    #expect(!shown.contains("HarborClaim"))
    #expect(!shown.contains("HarborEvidence"))
}

// The bug, on the real store: "which clinical records projects exist" returned 2 distinct outputs
// in 12 fresh processes on an unchanged copy. Identical text scores identically, the candidates
// came out of a `Dictionary`, and the sort looked only at the score, so a tie took its order from
// that process's hash seed. Asking twice in one process cannot show this, because the seed is
// fixed for the life of a process. So this asserts the order is the ids' own: any other outcome
// would need ten tied chunks to land in sorted order by chance.
@Test("passages with identical scores come back in one order, whatever the process")
func tiedPassagesHaveOneOrder() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let copies = (0..<10).map {
        CoreObject(sourceID: github.id, kind: .document, externalID: "user/copy-\($0)", title: "Ledger", text: "The quillberry ledger balances at close.", authoredAt: date, domain: .project, authority: .authoredArtifact)
    }
    _ = try await IngestPipeline(store: store).run(objects: copies)

    let candidates = try await store.lexicalChunks(match: "\"quillberry\"", limit: 10)
    #expect(candidates.count == copies.count)
    #expect(Set(candidates.map(\.rawScore)).count == 1, "the fixture must tie or this proves nothing")
    let ids = candidates.map(\.chunk.id.value)
    #expect(ids == ids.sorted())

    let outcome = try await PassageSearch(store: store).search(query: "quillberry", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project), limit: 10)
    #expect(outcome.hits.map(\.chunk.id.value) == ids)
}

// The same defect one stage later: `fused` is a `Dictionary` too, and with both legs running a
// chunk at ranks (1, 2) ties one at (2, 1) exactly. Reachable only with the dense leg on, which is
// off by default, so it is proved on the sort itself.
@Test("fused passages that tie on score still have one order")
func fusedTiesHaveOneOrder() async throws {
    let store = try await fleet(now: Date())
    var hits = try await PassageSearch(store: store).search(query: "clinical records", queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project), limit: 6).hits
    #expect(hits.count > 2)
    for index in hits.indices { hits[index].score = 0.03 }
    let expected = hits.map(\.chunk.id.value).sorted()
    for arrangement in [hits, hits.reversed(), Array(hits.dropFirst() + hits.prefix(1))] {
        #expect(PassageSearch.byScore(arrangement).map(\.chunk.id.value) == expected)
    }
}

// The bug: the passage list kept retrieval's order, so a repository whose README mentions the
// named project could open an answer about a different one.
@Test("passages about the named project come first and the rest keep their order")
func namedPassagesLead() async throws {
    let now = Date()
    let store = try await fleet(now: now)
    let policy = AdmissionPolicy(queryDomain: .project)
    let hits = try await PassageSearch(store: store).search(query: "clinical records", queryClass: .factual, policy: policy, limit: 6).hits
    let named = CoreEntity(kind: .project, canonicalName: "OpenClinicalC", domain: .project).id
    // Named object last, so a pass that changed nothing cannot satisfy this.
    let scrambled = hits.filter { $0.object.title != "OpenClinicalC" } + hits.filter { $0.object.title == "OpenClinicalC" }
    #expect(scrambled.last?.object.title == "OpenClinicalC", "the fixture must retrieve the named project")

    let ordered = try await Reasoner(store: store).aboutNamedFirst(scrambled, focus: QueryFocus(entities: [named], predicates: []), policy: policy)
    #expect(ordered.first?.object.title == "OpenClinicalC")
    #expect(ordered.dropFirst().map(\.chunk.id) == scrambled.dropLast().map(\.chunk.id))
    #expect(ordered.count == scrambled.count)
}

// The bug: `core_claims` printed one line per row, so `status → active` repeated once per push
// while `core_ask` and `core_dossier` collapsed the same rows.
@Test("core_claims prints a repeated fact once and says how many rows stand behind it")
func coreClaimsCollapsesRepeats() async throws {
    let now = Date()
    let store = try await temporaryStore()
    try await store.upsert(github)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-2 * 86_400))
        .run(objects: [repository("OpenClinicalA", pushed: now.addingTimeInterval(-3 * 86_400))])
    _ = try await IngestPipeline(store: store, now: now)
        .run(objects: [repository("OpenClinicalA", pushed: now.addingTimeInterval(-86_400))])

    let text = try await tool(MCPServer(store: store), "core_claims", ["entity": .string("OpenClinicalA")])
    let lines = text.split(separator: "\n").filter { $0.contains("status → active") }
    #expect(lines.count == 1)
    #expect(lines.first?.contains("×2") == true)
}

// The bug: chat took the top six passages whatever they were about and never read a claim, so
// `status`, which is derived and appears in no passage, could not reach the answer. `opencore ask`
// and chat could disagree about whether the store knew a project's status.
@Test("chat can answer a status question that no passage states")
func chatReadsWhatTheQuestionAsked() async throws {
    let now = Date()
    let store = try await statusFixture(now: now)
    let retrieved = try await Conversation(store: store).retrieve(
        query: "What is the status of OpenClinicalC?", queryClass: .factual,
        policy: AdmissionPolicy(queryDomain: .project), window: nil
    )
    let first = try #require(retrieved.sources.first)
    #expect(first.text.split(separator: "\n").first == "OpenClinicalC is active.")
    #expect(retrieved.claimsConsulted > 0)

    // It must stay citable and inspectable like any other source.
    #expect(try await store.object(first.objectID) != nil)
    #expect(retrieved.sources.count <= Conversation.sourceCount)
    #expect(retrieved.sources.map(\.index) == Array(1...retrieved.sources.count))

    // The passages behind it are about the project asked about.
    let firstPassage = try #require(retrieved.sources.first { $0.claimID == nil })
    #expect(firstPassage.title == "OpenClinicalC" || firstPassage.title == "STATE.md")

    // The receipt has to stop saying the claim table was not read.
    let receipt = Conversation.receipt(
        question: "q", queryClass: .factual, domain: .project, outcome: retrieved.outcome,
        sources: retrieved.sources, stages: [], model: nil, reading: retrieved.reading
    )
    #expect(receipt.claimsConsulted == retrieved.claimsConsulted)
}

@Test("chat reads no claims for a question that names no subject")
func chatStaysOnPassagesOtherwise() async throws {
    let store = try await fleet(now: Date())
    let retrieved = try await Conversation(store: store).retrieve(
        query: "clinical records", queryClass: .factual,
        policy: AdmissionPolicy(queryDomain: .project), window: nil
    )
    #expect(retrieved.claimsConsulted == 0)
    #expect(!retrieved.sources.isEmpty)
    #expect(!retrieved.sources.contains { $0.claimID != nil })
}

// The claim source's title decides what a follow-up searches for, because `priorSourceTitles.first`
// is the anchor. It has to anchor on the subject, or "and its language?" searches for the words
// "stored claims".
@Test("a follow-up after a claim source anchors on the subject")
func followUpAnchorsOnTheSubject() async throws {
    let store = try await statusFixture(now: Date())
    let retrieved = try await Conversation(store: store).retrieve(
        query: "What is the status of OpenClinicalC?", queryClass: .factual,
        policy: AdmissionPolicy(queryDomain: .project), window: nil
    )
    // The title the source really carries. A literal here would keep passing if it changed.
    let titles = retrieved.sources.map(\.title)
    let rewritten = Conversation.contextualizedQuery("what about its language", priorQuestions: [], priorSourceTitles: titles)
    #expect(rewritten.contains("OpenClinicalC"))
    #expect(!rewritten.contains("stored claim"))
}

// MARK: - What chat reads about a claim

private let clinicalC = CoreEntity(kind: .project, canonicalName: "OpenClinicalC", domain: .project).id
private let refutingText = "OpenClinicalC has had no maintainer since March."

private func retrieve(_ query: String, from store: Store) async throws -> Conversation.Retrieval {
    try await Conversation(store: store).retrieve(query: query, queryClass: .factual, policy: AdmissionPolicy(queryDomain: .project), window: nil)
}

private func receipt(for retrieved: Conversation.Retrieval) -> Receipt {
    Conversation.receipt(
        question: "q", queryClass: .factual, domain: .project, outcome: retrieved.outcome,
        sources: retrieved.sources, stages: [], model: nil, reading: retrieved.reading
    )
}

/// A status with evidence refuting it and an unresolved rival. Both are rows that exist, and both
/// are what chat used to drop.
private func contestedStatus(now: Date) async throws -> Store {
    let store = try await statusFixture(now: now)
    let status = try #require(try await store.claims(subject: clinicalC).first { $0.predicate == Predicate.status })
    let audit = CoreObject(sourceID: github.id, kind: .document, externalID: "user/audit", title: "Audit", text: refutingText, authoredAt: now, domain: .project, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store, now: now).run(objects: [audit])
    let refuting = Evidence(objectID: audit.id, snippet: refutingText, authority: .authoredArtifact)
    try await store.save([refuting])
    try await store.link(claim: status.id, to: refuting.id, stance: .refutes)

    let dormant = CoreClaim(subject: clinicalC, predicate: Predicate.status, literal: "dormant", confidence: 0.6, authority: status.authority, derivation: .inferred, validity: Validity(observedAt: now), domain: .project)
    try await store.save([dormant])
    try await store.link(claim: dormant.id, to: refuting.id, stance: .supports)
    try await store.save([Contradiction(claimA: status.id, claimB: dormant.id, kind: .directConflict, resolution: .unresolved, reason: "equal authority and no temporal ordering; both retained")])
    return store
}

// The bug: chat gave the model `AnswerPoint.statement` and nothing else, so a status with refuting
// evidence reached it as a flat fact, while `core_ask` printed the same claim with COUNTER-EVIDENCE
// and an [inferred] tag. Each caveat is asserted on its own: they are built separately, and one
// surviving could not show another was deleted.
@Test("a claim reaches chat with everything that stands against it")
func chatSeesCaveats() async throws {
    let store = try await contestedStatus(now: Date())
    let retrieved = try await retrieve("What is the status of OpenClinicalC?", from: store)
    let line = try #require(retrieved.sources.first { $0.text.hasPrefix("OpenClinicalC is active.") })
    #expect(line.text.contains("Inferred by OpenCore"), "status is derived, and the line must say so")
    #expect(line.text.contains("Counter-evidence: \(refutingText)"))
    // The stored reason names neither value, so the rival has to be stated or this says nothing.
    #expect(line.text.contains("Open contradiction: OpenClinicalC is dormant."))
    #expect(line.text.contains("both retained"))
}

// The bug: `contradictionsSurfaced` was a literal 0 on the chat path, on a receipt whose whole
// claim is that every field was observed.
@Test("a chat receipt counts the contradictions the model was shown")
func chatReceiptCountsContradictions() async throws {
    let contested = try await retrieve("What is the status of OpenClinicalC?", from: contestedStatus(now: Date()))
    // Two lines, one conflict between them: a count of lines would say 2, and the first run of
    // this test caught the third line wearing a conflict it had no part in.
    #expect(contested.sources.filter { $0.text.contains("Open contradiction") }.count == 2)
    #expect(receipt(for: contested).contradictionsSurfaced == 1)
    // The objective is about the same subject and has no part in the conflict. It stays clean.
    let objective = try #require(contested.sources.first { $0.text.hasPrefix("OpenClinicalC's objective:") })
    #expect(!objective.text.contains("contradiction"))

    let calm = try await retrieve("What is the status of OpenClinicalC?", from: statusFixture(now: Date()))
    #expect(receipt(for: calm).contradictionsSurfaced == 0)
}

// Which conflicts matter is a choice: 12 of the real store's 14 are settled, and most read
// "observed 2026-10-22, superseding 2026-10-21", which says nothing against the line that won.
@Test("a contradiction stands against a line unless that line won it or it was never a conflict")
func onlyLosingLinesCarryAContradiction() {
    let line = ClaimID("line")
    let rival = ClaimID("rival")
    func conflict(_ resolution: Resolution, winner: ClaimID?) -> Contradiction {
        Contradiction(claimA: line, claimB: rival, kind: .directConflict, resolution: resolution, winner: winner, reason: "fixture")
    }
    #expect(Reasoner.standsAgainst(conflict(.unresolved, winner: nil), rows: [line]))
    #expect(Reasoner.standsAgainst(conflict(.supersededByRecency, winner: rival), rows: [line]))
    #expect(!Reasoner.standsAgainst(conflict(.supersededByRecency, winner: line), rows: [line]))
    #expect(!Reasoner.standsAgainst(conflict(.coexistingIntervals, winner: nil), rows: [line]))
    #expect(!Reasoner.standsAgainst(conflict(.unresolved, winner: nil), rows: [ClaimID("elsewhere")]))
}

// The same defect, reachable with no model at all: the fallback kept each source's first line,
// so an unavailable model stated a disputed claim flat.
@Test("the fallback for an unavailable model keeps a claim's caveats")
func fallbackKeepsCaveats() async throws {
    let store = try await contestedStatus(now: Date())
    let retrieved = try await retrieve("What is the status of OpenClinicalC?", from: store)
    let synthesized = Conversation.deterministicSynthesis(from: retrieved.sources)
    #expect(synthesized.contains { $0.text.hasPrefix("Counter-evidence:") })
    #expect(synthesized.contains { $0.text.hasPrefix("Open contradiction:") })
    let verifier = Grounding()
    for sentence in synthesized {
        #expect(verifier.verify(sentence: sentence.text, citedSource: sentence.source, sources: retrieved.sources).isGrounded)
    }
}

// A claim's caveats are its last lines, so the cut that keeps `fm`'s prompt small would drop only
// them, and silently.
@Test("the cut for the fm prompt shortens passages and leaves a claim's caveats")
func cliClipKeepsCaveats() {
    let long = String(repeating: "word ", count: 400)
    let passage = GroundingSource(index: 1, title: "Passage", text: long, objectID: ObjectID("o"), authority: .authoredArtifact)
    let claim = GroundingSource(index: 2, title: "A · stored claim", text: long + "\nCounter-evidence: no.", objectID: ObjectID("o"), authority: .authoredArtifact, claimID: ClaimID("c"))
    let clipped = Conversation.clippedForCLI([passage, claim])
    #expect(clipped[0].text.count < long.count)
    #expect(clipped[1].text == claim.text)
    #expect(clipped[1].claimID == claim.claimID)
}

// A source can carry a caveat and the model can still write around it, so the rule has to be said.
@Test("the model is told not to state a disputed claim flat")
func instructionsCoverCaveats() {
    #expect(Conversation.instructions.contains("Never state such a statement flat"))
}

// MARK: - What a chat receipt reports

// The bug: `claimsConsulted` was every matching line, though only three reached the model, so
// "which projects use Swift" over-reported what chat read. It also counted lines where `Reasoner`
// counts rows, so one receipt column had two meanings.
@Test("a chat receipt counts the claim rows behind what the model was shown")
func chatCountsRowsItShowed() async throws {
    let now = Date()
    let wide = try await fleet(now: now)
    let question = "which projects are written in Swift"
    let shown = try await retrieve(question, from: wide)
    let lines = shown.sources.filter { $0.claimID != nil }
    #expect(lines.count == Conversation.askedClaimsShown)
    let everything = try await Reasoner(store: wide).answer(question, persistReceipt: false)
    #expect(everything.receipt.claimsConsulted > shown.claimsConsulted, "the fixture must match more than is shown or this proves nothing")
    #expect(Set(lines.compactMap(\.claimID)).isSubset(of: Set(shown.reading.claims)))

    // Rows, not lines. One fact observed twice is one line and two rows.
    let repeated = try await temporaryStore()
    try await repeated.upsert(github)
    _ = try await IngestPipeline(store: repeated, now: now.addingTimeInterval(-2 * 86_400))
        .run(objects: [repository("OpenClinicalA", pushed: now.addingTimeInterval(-3 * 86_400))])
    _ = try await IngestPipeline(store: repeated, now: now)
        .run(objects: [repository("OpenClinicalA", pushed: now.addingTimeInterval(-86_400))])
    let subject = CoreEntity(kind: .project, canonicalName: "OpenClinicalA", domain: .project).id
    let rows = try await repeated.claims(subject: subject).filter { $0.predicate == Predicate.status }
    #expect(rows.count > 1, "the fixture must hold repeated rows or this proves nothing")
    let collapsed = try await retrieve("status of OpenClinicalA", from: repeated)
    #expect(collapsed.sources.filter { $0.claimID != nil }.count == 1)
    #expect(collapsed.claimsConsulted == rows.count)
}

// The bug: the passage counters included the synthetic source, so the footer's "X of Y passages"
// counted something that is not a passage.
@Test("a chat receipt does not count a claim as a passage")
func claimsAreNotPassages() async throws {
    let retrieved = try await retrieve("What is the status of OpenClinicalC?", from: statusFixture(now: Date()))
    let filed = receipt(for: retrieved)
    let passages = retrieved.sources.filter { $0.claimID == nil }.count
    #expect(passages < retrieved.sources.count, "the fixture must hold a claim source or this proves nothing")
    #expect(filed.objectsRetrieved == passages)
    #expect(filed.answeredFromClaims)
    #expect(filed.evidenceAdmitted == retrieved.reading.evidence.count)
}

// The bug: `persist` saved the receipt with no links, so a chat turn reported N claims while
// `receipt_claim` held 0 rows and `core_trace` said it "admitted no evidence". This runs the real
// turn, because the links are dropped or kept at the save, past anything `retrieve` can show.
// Whichever model answers makes no difference here: it asserts only on what the receipt recorded.
@Test("a chat turn that read claims traces to what it read")
func chatTurnsAreTraceable() async throws {
    let store = try await contestedStatus(now: Date())
    var finished: Turn?
    for await turn in Conversation(store: store).send("What is the status of OpenClinicalC?") { finished = turn }
    let turn = try #require(finished)
    let filed = try #require(turn.receipt)
    #expect(turn.persistenceError == nil)
    #expect(filed.claimsConsulted > 0)
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM receipt_claim") == filed.claimsConsulted)

    let rows = try await store.trace(receipt: filed.id)
    #expect(rows.count == filed.evidenceAdmitted)
    #expect(rows.contains { $0.0.snippet == refutingText }, "the model saw the counter-evidence, so a trace must list it")

    let traced = try await tool(MCPServer(store: store), "core_trace", ["receipt": .string(filed.shortCode)])
    #expect(traced.contains("Evidence behind"))
    #expect(!traced.contains("admitted no evidence"))
}

// The other half of the same contradiction: a passage-only receipt has a counter of N and nothing
// to link, and "admitted no evidence" under that counter is the sentence that started this.
@Test("tracing a chat turn that read no claims says what it did read")
func passageOnlyTraceIsHonest() async throws {
    let store = try await fleet(now: Date())
    let retrieved = try await retrieve("clinical records", from: store)
    let filed = receipt(for: retrieved)
    #expect(!filed.answeredFromClaims)
    #expect(filed.evidenceAdmitted == retrieved.sources.count)
    try await store.save(filed)
    let traced = try await tool(MCPServer(store: store), "core_trace", ["receipt": .string(filed.shortCode)])
    #expect(traced.contains("answered from \(retrieved.sources.count) passage(s)"))
    #expect(!traced.contains("admitted no evidence"))
}

// MARK: - One source per claim

// The bug: the em dash in the source title reached the chip, the detail view and `sourcesJSON`.
@Test("a claim source's title has no em dash")
func claimTitlesAreClean() async throws {
    let retrieved = try await retrieve("What is the status of OpenClinicalC?", from: statusFixture(now: Date()))
    let line = try #require(retrieved.sources.first)
    #expect(line.title == "OpenClinicalC" + Conversation.claimTitleSuffix)
    #expect(!line.title.unicodeScalars.contains("\u{2014}"))
}

// The bug: one source held up to three lines and took its title, object and tier from the first,
// so three repositories sat under one repository's name.
@Test("each claim is cited under its own subject, with its own object")
func eachClaimHasItsOwnSource() async throws {
    let store = try await fleet(now: Date())
    let retrieved = try await retrieve("which projects are written in Swift", from: store)
    let lines = retrieved.sources.filter { $0.claimID != nil }
    #expect(Set(lines.map(\.title)).count == lines.count, "the fixture must span subjects or this proves nothing")
    for line in lines {
        let subject = try #require(line.title.components(separatedBy: Conversation.claimTitleSuffix).first)
        #expect(line.text.hasPrefix("\(subject) is primarily written in Swift."))
        #expect(try await store.object(line.objectID)?.title == subject, "a citation must open the object behind its own line")
    }
}

// The bug, on one subject: a higher-tier first line lent its label to a lower-tier line, and a
// sentence citing [1] for the third line passed `Grounding` against text pooled from all three.
@Test("a citation is checked against one line, under that line's authority")
func oneLineOneTier() async throws {
    let retrieved = try await retrieve("What is the status of OpenClinicalC?", from: statusFixture(now: Date()))
    let status = try #require(retrieved.sources.first { $0.text.hasPrefix("OpenClinicalC is active.") })
    let objective = try #require(retrieved.sources.first { $0.text.hasPrefix("OpenClinicalC's objective:") })
    #expect(objective.authority.rawValue > status.authority.rawValue, "the fixture must span tiers or this proves nothing")
    #expect(objective.objectID != status.objectID)

    let sentence = "OpenClinicalC's objective: Close the chart import gap."
    let verifier = Grounding()
    #expect(verifier.verify(sentence: sentence, citedSource: objective.index, sources: retrieved.sources).isGrounded)
    #expect(!verifier.verify(sentence: sentence, citedSource: status.index, sources: retrieved.sources).isGrounded)
}

// The bug: after "which projects use Swift", the follow-up "and their language?" anchored on the
// first title, an arbitrary repository, and `QueryFocus` then narrowed the turn to it.
@Test("a follow-up after claims about several subjects picks none of them")
func followUpDoesNotChooseASubject() async throws {
    let store = try await fleet(now: Date())
    let question = "which projects are written in Swift"
    let retrieved = try await retrieve(question, from: store)
    let titles = retrieved.sources.map(\.title)
    let lines = retrieved.sources.filter { $0.claimID != nil }.map(\.title)
    #expect(lines.count > 1, "the fixture must span subjects or this proves nothing")

    let rewritten = Conversation.contextualizedQuery("and their language?", priorQuestions: [question], priorSourceTitles: titles)
    #expect(!rewritten.contains("OpenClinical"))
    #expect(rewritten.lowercased().contains("swift"), "the prior question still carries over")

    // An ordinal is the reader choosing, so it still reaches the line they meant.
    let ordinal = Conversation.contextualizedQuery("what about the second one", priorQuestions: [question], priorSourceTitles: titles)
    let second = try #require(lines[1].components(separatedBy: Conversation.claimTitleSuffix).first)
    #expect(ordinal.contains(second))
}

// Threads saved before the title changed keep the old spelling in `sourcesJSON`.
@Test("a follow-up in a thread saved with the old title still anchors on its subject")
func oldTitlesStillAnchor() {
    let rewritten = Conversation.contextualizedQuery("what about its language", priorQuestions: [], priorSourceTitles: ["OpenClinicalC \u{2014} stored claims"])
    #expect(rewritten.contains("OpenClinicalC"))
    #expect(!rewritten.contains("stored claims"))
}

// `claimID` was added to a type already saved as JSON, and a failed decode shows a thread with no
// sources rather than an error.
@Test("a source saved before claims existed still decodes")
func oldSourcesDecode() throws {
    let source = GroundingSource(index: 1, title: "Notes", text: "text", objectID: ObjectID("o"), authority: .authoredArtifact)
    let saved = try JSONEncoder().encode(source)
    #expect(!String(decoding: saved, as: UTF8.self).contains("claimID"), "the fixture must match an old row or this proves nothing")
    #expect(try JSONDecoder().decode(GroundingSource.self, from: saved) == source)

    let claim = GroundingSource(index: 1, title: "A", text: "text", objectID: ObjectID("o"), authority: .authoredArtifact, claimID: ClaimID("c"))
    #expect(try JSONDecoder().decode(GroundingSource.self, from: JSONEncoder().encode(claim)).claimID == claim.claimID)
}

// MARK: - What a question names

private func toolchainFixture(now: Date) async throws -> Store {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let recent = now.addingTimeInterval(-3 * 86_400)
    var lantern = repository("Lantern", language: "Swift", pushed: recent)
    lantern.text += "\nThe shell script rotates the logs every night."
    var beacon = repository("Beacon", language: "Shell", pushed: recent)
    beacon.text += "\nThe swift build failed after the upgrade."
    _ = try await IngestPipeline(store: store, now: now).run(objects: [lantern, beacon])
    return store
}

// The bug: "how does the shell script work" named the technology Shell, which replaced the subjects
// its passages were about, and `claims(pointingAt:)` then filled the answer with every repository
// written in Shell. The concept version of this was fixed and this class was reported closed.
@Test("a technology named in passing does not take over the question")
func technologyDoesNotCaptureTheQuestion() async throws {
    let store = try await toolchainFixture(now: Date())
    let lantern = CoreEntity(kind: .project, canonicalName: "Lantern", domain: .project).id
    let beacon = CoreEntity(kind: .project, canonicalName: "Beacon", domain: .project).id

    let shell = try await Reasoner(store: store).answer("how does the shell script work", persistReceipt: false)
    #expect(shell.points.contains { $0.subject == lantern }, "the passage was about Lantern, so its claims belong here")
    #expect(!shell.points.contains { $0.statement == "Beacon is primarily written in Shell." })

    let swift = try await Reasoner(store: store).answer("why did the swift build fail", persistReceipt: false)
    #expect(swift.points.contains { $0.subject == beacon })
    #expect(!swift.points.contains { $0.statement == "Lantern is primarily written in Swift." })
}

// The guard that came with that fix: asking what points at a technology is the case the route is
// for, and dropping technologies outright would reopen "which projects use Swift returned nothing".
@Test("asking what points at a technology still reads it")
func askedTechnologyStillAnswers() async throws {
    let store = try await toolchainFixture(now: Date())
    let policy = AdmissionPolicy(queryDomain: .project)
    let swift = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .project).id

    for question in ["which projects use Swift", "what is written in swift", "what is built with swift", "what depends on swift"] {
        let focus = try await QueryFocus.read(from: question, store: store, policy: policy, externalCaller: false)
        #expect(focus.names(swift), "\(question)")
    }
    for question in ["why did the swift build fail", "where did the swift go", "describe swift", "status of swift"] {
        let focus = try await QueryFocus.read(from: question, store: store, policy: policy, externalCaller: false)
        #expect(focus.entities.isEmpty, "\(question)")
    }
}

// The bug: the tokenizer kept "." but the single-word gate required the word in `ftsTerms`, which
// splits on it and drops one-letter words. So no dotted or symbol-bearing name could be named, and
// for those "which projects use X" still returned no claims.
@Test("a language with punctuation in its name can be asked about")
func punctuatedNamesResolve() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let languages = ["C", "C++", "C#", "Node.js", ".NET"]
    let recent = Date().addingTimeInterval(-3 * 86_400)
    let objects = languages.enumerated().map { repository("Fixture\($0.offset)", language: $0.element, pushed: recent) }
    _ = try await IngestPipeline(store: store).run(objects: objects)

    for (index, language) in languages.enumerated() {
        let expected = "Fixture\(index) is primarily written in \(language)."
        for question in ["which projects are written in \(language)", "which projects are written in \(language)."] {
            let answer = try await Reasoner(store: store).answer(question, persistReceipt: false)
            #expect(answer.points.map(\.statement) == [expected], "\(question)")
        }
    }
}

@Test("a name keeps its punctuation and a sentence loses its own")
func wordsKeepNames() {
    #expect(QueryFocus.words(in: "Use node.js. Or C++, C#, .NET... #swift ...and +1") == ["use", "node.js", "or", "c++", "c#", ".net", "swift", "and", "1"])
}

// One letter is a name only for a language. Letting every letter through would make a repository
// called "x" the subject of anything mentioning "plan x".
@Test("one letter names a language and nothing else")
func oneLetterIsOnlyALanguage() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    _ = try await IngestPipeline(store: store).run(objects: [repository("X", language: "C", pushed: Date())])
    let policy = AdmissionPolicy(queryDomain: .project)

    let project = try await QueryFocus.read(from: "what is the status of plan x", store: store, policy: policy, externalCaller: false)
    #expect(project.entities.isEmpty)
    let language = try await QueryFocus.read(from: "which projects are written in c", store: store, policy: policy, externalCaller: false)
    #expect(language.entities == [CoreEntity(kind: .technology, canonicalName: "C", domain: .project).id])
}

// MARK: - Trace scores

// The bug: scores were `1 - offset / (points * 3)`, which assumes 3 evidence rows per line. Since
// repeated rows collapse into one line, a fact with many rows went negative, and `core_trace`
// printed `[-1.333]` into a receipt whose rule is that nothing in it is a plausible invention.
@Test("evidence scores stay in 0...1 and fall with rank, however many rows one line holds")
func evidenceScoresAreBounded() throws {
    let evidence = (0..<9).map { Evidence(objectID: ObjectID("o"), range: $0..<($0 + 1), snippet: "row \($0)", authority: .authoredArtifact) }
    let counter = Evidence(objectID: ObjectID("o"), range: 100..<101, snippet: "against", authority: .authoredArtifact)
    let point = AnswerPoint(statement: "A is active.", supporting: evidence, counter: [counter], confidence: 0.9, authority: .authoredArtifact, derivation: .observed, claimID: ClaimID("a"), subject: EntityID("a"), predicate: Predicate.status)
    // The same row under a second line must not get a second rank.
    let repeated = AnswerPoint(statement: "B is active.", supporting: [evidence[0]], counter: [], confidence: 0.9, authority: .authoredArtifact, derivation: .observed, claimID: ClaimID("b"), subject: EntityID("b"), predicate: Predicate.status)

    let ranked = Reasoner.rankedEvidence([point, repeated])
    #expect(ranked.map(\.0) == evidence.map(\.id) + [counter.id])
    #expect(ranked.allSatisfy { $0.1 > 0 && $0.1 <= 1 })
    #expect(ranked.map(\.1) == ranked.map(\.1).sorted(by: >))
    #expect(Reasoner.rankedEvidence([]).isEmpty)
}

// The same thing through the store: one fact on six rows, each with evidence of its own, which is
// how a value repeated across documents reaches a line.
@Test("core_trace prints no negative score for a fact observed many times")
func traceHasNoNegativeScores() async throws {
    let now = Date()
    let store = try await temporaryStore()
    try await store.upsert(github)
    let project = CoreEntity(kind: .project, canonicalName: "OpenClinicalA", domain: .project)
    try await store.upsert([project])
    try await store.addAliases([EntityAlias(entityID: project.id, surface: "openclinicala", confidence: 1)])
    for age in 1...6 {
        let date = now.addingTimeInterval(Double(-age) * 86_400)
        let text = "OpenClinicalA stayed active on day \(age)."
        let log = CoreObject(sourceID: github.id, kind: .document, externalID: "user/log-\(age)", title: "Log \(age)", text: text, authoredAt: date, domain: .project, authority: .authoredArtifact)
        _ = try await IngestPipeline(store: store, now: now).run(objects: [log])
        let evidence = Evidence(objectID: log.id, snippet: text, authority: .authoredArtifact)
        try await store.save([evidence])
        let claim = CoreClaim(subject: project.id, predicate: Predicate.status, literal: "active", confidence: 0.85, authority: .authoredArtifact, derivation: .inferred, validity: Validity(validFrom: date, observedAt: now), domain: .project)
        try await store.save([claim])
        try await store.link(claim: claim.id, to: evidence.id, stance: .supports)
    }
    let answer = try await Reasoner(store: store).answer("status of OpenClinicalA")
    let held = answer.points.reduce(0) { $0 + $1.supporting.count }
    #expect(held > answer.points.count * 3, "the fixture must exceed the old assumption or this proves nothing")

    let rows = try await store.trace(receipt: answer.receipt.id)
    #expect(rows.allSatisfy { $0.2 > 0 && $0.2 <= 1 })
    let traced = try await tool(MCPServer(store: store), "core_trace", ["receipt": .string(answer.receipt.shortCode)])
    #expect(!traced.contains("[-"))
}
