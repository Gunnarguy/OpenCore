import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation
import Testing

// Imported personal objects were browseable but ordinary owner questions could not retrieve them.
@Test("owner scope retrieves personal passages while external callers and narrow grants stay closed")
func ownerQuestionsCanReadAdmittedPersonalPassages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-owner-scope-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .directStatement, defaultDomain: .personal)
    try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .document, externalID: "fixture-personal", title: "Journal fixture",
        text: "My journal records cobalt amaranth. OWNER_PERSONAL_SENTINEL", domain: .personal, authority: .directStatement)
    try await store.ingest([object])
    try await store.save([CoreChunk(objectID: object.id, ordinal: 0, text: object.text, range: 0..<object.text.count)])
    let reasoner = Reasoner(store: store)
    for (query, selected) in [("my journal cobalt", Domain?.none), ("cobalt", Domain?.some(.personal))] {
        let answer = try await reasoner.answer(query, persistReceipt: false, ownerDomain: selected)
        #expect(answer.passages.contains { $0.object.id == object.id })
        #expect(answer.receipt.domainsAdmitted.contains(.personal))
    }
    let external = try await reasoner.answer("my journal cobalt", externalCaller: true, persistReceipt: false, ownerDomain: .personal)
    #expect(external.passages.isEmpty)
    #expect(!external.receipt.domainsAdmitted.contains(.personal))
    let narrow = try await reasoner.answer("cobalt", persistReceipt: false, maximumDomains: [.project,.publicRecord], ownerDomain: .personal)
    #expect(narrow.passages.isEmpty)
    // Retrieval context must not turn yesterday's private conversation into consent today.
    let anchored = try await reasoner.answer("what about it", persistReceipt: false, retrievalQuery: "my journal cobalt")
    #expect(anchored.passages.isEmpty)
    #expect(!anchored.receipt.domainsAdmitted.contains(.personal))
    // No matching passages, so no model is invoked by these scope/receipt checks.
    let chat = Conversation(store: store, persistHistory: false, maximumDomains: [.project,.publicRecord])
    var last: Turn?
    for await turn in chat.send("xzxz-no-fixture", ownerDomain: .personal) { last = turn }
    #expect(last?.receipt?.domainsAdmitted.contains(.personal) == false)
}


// The structured follow-up dropped its named subject whenever the current question named a week.
@Test("a timed follow-up keeps its retrieval subject without treating that context as admission")
func ownerTimedFollowUpKeepsItsSubject() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-owner-window-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
    let first = CoreEntity(kind: .project, canonicalName: "Quillberry", domain: .project)
    let second = CoreEntity(kind: .project, canonicalName: "Dapplemint", domain: .project)
    try await store.upsert([first, second])
    try await store.addAliases([EntityAlias(entityID: first.id, surface: first.canonicalName, confidence: 1),
                                EntityAlias(entityID: second.id, surface: second.canonicalName, confidence: 1)])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
    let window = try #require(TemporalIntent.window(in: "last week", now: now, calendar: calendar))
    let at = window.start.addingTimeInterval(3600)
    try await store.save([
        CoreEvent(subject: first.id, verb: "worked", detail: "ALLOWED_SUBJECT", occurredAt: at, domain: .project, authority: .authoredArtifact),
        CoreEvent(subject: second.id, verb: "worked", detail: "OTHER_SUBJECT", occurredAt: at, domain: .project, authority: .authoredArtifact),
    ])
    let answer = try await Reasoner(store: store, now: now, calendar: calendar).answer(
        "what happened to it last week", persistReceipt: false, retrievalQuery: "what happened to it last week (Quillberry)")
    #expect(answer.activity?.totalSubjects == 1)
    #expect(answer.activity?.groups.first?.subject.id == first.id)
    #expect(answer.receipt.query == "what happened to it last week")
}
