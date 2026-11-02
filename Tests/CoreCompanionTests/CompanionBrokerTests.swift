import CoreCompanion
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation
import Testing
@testable import CoreCompanionHost

// Independent request audits have no phone-delivery stage, so visibility needs authenticated
// request ownership without confusing it with an ACK or restoring a former grant's history.
@Test("a phone sees only its current grant's independent cloud audits before delivery")
func phoneRequestAuditsStayBoundToTheirCurrentGrant() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone()
    let receipt = Receipt(query: "PRIVATE_AUDIT_QUESTION", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: CompanionBroker.requestAuditContext(for: phone) + [ReceiptStage(name: "cloud.request-audit", milliseconds: 0),
            ReceiptStage(name: "cloud.request", counters: ["request_submitted": 1, "objects_submitted": 1, "application_acknowledged": 0], milliseconds: 0)],
        objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await fixture.store.save(receipt)
    let broker = CompanionBroker(store: fixture.store)
    let own = try await broker.prepare(CompanionRequest(section: .receipts), device: phone).page
    #expect(own.records.contains { $0.id == receipt.id.value })
    for other in [fixturePhone(), fixturePhone(id: phone.id)] {
        let page = try await broker.prepare(CompanionRequest(section: .receipts), device: other).page
        #expect(!page.records.contains { $0.id == receipt.id.value })
    }
    #expect(!receipt.stages.contains { $0.name == "companion.delivery" })
}

// A completed fallback warning used to be rejected as fatal. Delivery must retain that warning
// and the earlier unconfirmed cloud request, without treating the attempted model as prose author.
@Test("phone acknowledgement preserves cloud uncertainty and shares the same receipt disclosure")
func phoneAcknowledgmentKeepsCloudAttemptDisclosure() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let cloud = ReceiptStage(name: "cloud.request", counters: ["request_submitted": 1, "objects_submitted": 1,
        "application_acknowledged": 0, "answer_decoded": 0], milliseconds: 0)
    let receipt = Receipt(query: "fixture", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: [cloud, ReceiptStage(name: "synthesize_deterministic", milliseconds: 0)], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0,
        claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    let source = GroundingSource(index: 1, title: "Fixture", text: fixture.publicObject.text,
        objectID: fixture.publicObject.id, authority: fixture.publicObject.authority)
    let turn = Turn(role: .core, text: source.text, sources: [source],
        verdicts: [Grounding().verify(sentence: source.text, citedSource: 1, sources: [source])],
        receipt: receipt, error: "Fixture model unavailable")
    let prepared = try await CompanionBroker(store: fixture.store).prepareChatDelivery(turn,
        device: fixturePhone(), domains: [.project, .publicRecord])
    #expect(try await fixture.store.receipts().isEmpty)
    let page = try await prepared.acknowledge()
    let saved = try #require(try await fixture.store.receipt(code: receipt.shortCode))
    #expect(saved.objectsTransmitted == 1)
    #expect(saved.hasUnconfirmedCloudDelivery)
    #expect(saved.outboundDescription.contains("Phone delivery acknowledged: 1 source objects."))
    let record = try #require(page.records.first { $0.id == receipt.id.value })
    #expect(record.fields.contains { $0.label == "Outbound activity" && $0.value == saved.outboundDescription })
    #expect(page.records.first?.fields.contains { $0.label == "Generation warning" && $0.value == "Fixture model unavailable" } == true)
}

// An empty represented-ID list must not omit the source's primary object from domain admission.
@Test("an empty represented-object list cannot bypass the phone's primary source admission")
func emptyRepresentedListCannotHideBlockedPrimarySource() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = Receipt(query: "fixture", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: [], objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    let source = GroundingSource(index: 1, title: "Blocked fixture", text: fixture.privateObject.text,
        objectID: fixture.privateObject.id, authority: fixture.privateObject.authority, representedObjectIDs: [])
    let turn = Turn(role: .core, text: source.text, sources: [source], receipt: receipt)
    await #expect(throws: (any Error).self) {
        try await CompanionBroker(store: fixture.store).prepareChatDelivery(turn, device: fixturePhone(), domains: [.project, .publicRecord])
    }
}

private struct BrokerFixture {
    let store: Store
    let directory: URL
    let publicObject: CoreObject
    let privateObject: CoreObject
    let project: CoreEntity
    let privateEntity: CoreEntity

    // These preconstructed synthetic turns do not run generation. Capture their baseline
    // explicitly; production callers must carry the revision from their restored context.
    func prepareSavedChatFixture(_ broker: CompanionBroker, _ turn: Turn, request: CompanionRequest,
                                 device: CompanionDevice, domains: Set<Domain>,
                                 expectedRevision: CompanionHistoryRevision? = nil) async throws -> CompanionPreparedPage {
        let revision: CompanionHistoryRevision
        if let expectedRevision { revision = expectedRevision }
        else if let thread = request.chatThreadID {
            let scope = CompanionHistoryScope(deviceID: device.id, grantID: device.grantID, domains: domains,
                selectedDomain: request.domain.flatMap(Domain.init(rawValue:)))
            switch try await store.companionHistoryLookup(scope: scope, thread: thread) {
            case .missing: revision = .empty
            case .unavailable: throw CompanionError.unauthorized
            case .admitted(let snapshot): revision = snapshot.revision
            }
        } else { revision = .empty }
        return try await broker.prepareSavedChatDelivery(turn, request: request, device: device,
                                                          domains: domains, expectedRevision: revision)
    }
}

private func brokerFixture() async throws -> BrokerFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-companion-test-\(UUID().uuidString)")
    let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture source", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let project = CoreEntity(kind: .project, canonicalName: "Quillberry", domain: .project)
    let privateEntity = CoreEntity(kind: .concept, canonicalName: "MEDICAL_SENTINEL", domain: .medical)
    try await store.upsert([project, privateEntity])
    let publicObject = CoreObject(sourceID: source.id, kind: .document, externalID: "public", title: "Quillberry",
        text: "Quillberry is built with Swift. PROJECT_SENTINEL", domain: .project, authority: .authoredArtifact)
    let privateObject = CoreObject(sourceID: source.id, kind: .document, externalID: "private", title: "Private fixture",
        text: "MEDICAL_SENTINEL", domain: .medical, authority: .directStatement)
    try await store.ingest([publicObject, privateObject])
    try await store.save([publicObject, privateObject].map { CoreChunk(objectID: $0.id, ordinal: 0, text: $0.text, range: 0..<$0.text.count) })
    let claim = CoreClaim(subject: project.id, predicate: Predicate.status, literal: "active", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date(timeIntervalSince1970: 1_800_000_000)), domain: .project)
    try await store.save([claim])
    let evidence = Evidence(objectID: publicObject.id, snippet: publicObject.text, authority: .authoredArtifact)
    try await store.save([evidence]); try await store.link(claim: claim.id, to: evidence.id, stance: .supports)
    return BrokerFixture(store: store, directory: directory, publicObject: publicObject, privateObject: privateObject, project: project, privateEntity: privateEntity)
}

private func fixturePhone(domains: Set<String> = ["project","public"], id: UUID = UUID(), pairedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CompanionDevice {
    CompanionDevice(id: id, name: "Fixture phone", signingKey: Data(), domains: domains, pairedAt: pairedAt)
}

private actor PhoneDeliveryFailureRecorder {
    private(set) var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

private actor PhoneProgressRecorder {
    private(set) var count = 0
    private(set) var attempts = 0
    func record() { count += 1 }
    func attempt() { attempts += 1 }
}

@Test("evidence links keep byte-distinct target identities")
func companionRecordLinksKeepExactTargetBytes() throws {
    let first = CompanionRecordLink(.object, "\u{00E9}", "Fixture")
    let second = CompanionRecordLink(.object, "e\u{0301}", "Fixture")
    #expect(first != second)
    #expect(Set([first, second]).count == 2)
    #expect(first.id != second.id)
    let identical = CompanionRecordLink(.object, String(decoding: Array(first.targetID.utf8), as: UTF8.self), "Fixture")
    #expect(first == identical && Set([first, identical]).count == 1 && first.id == identical.id)
    #expect(first.id != CompanionRecordLink(.claim, first.targetID, "Fixture").id)
    let renamed = CompanionRecordLink(.object, first.targetID, "Another title")
    #expect(first != renamed && first.id == renamed.id)
    let distinct = CompanionBroker.distinctLinks([first, renamed, second])
    #expect(distinct.count == 2 && distinct.first?.title == "Fixture" && distinct.last == second)
    let data = try JSONEncoder().encode([first, second])
    let decoded = try JSONDecoder().decode([CompanionRecordLink].self, from: data)
    #expect(decoded == [first, second])
    #expect(Set(decoded.map(\.id)).count == 2)
}

@Test("phone Evidence answers retain byte-distinct source links")
func phoneEvidenceAnswerKeepsCanonicallyEquivalentLinks() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var first = fixture.publicObject, second = fixture.publicObject
    first.id = ObjectID("\u{00E9}"); first.externalID = "link-fixture-one"
    second.id = ObjectID("e\u{0301}"); second.externalID = "link-fixture-two"
    _ = try await fixture.store.ingest([first, second])
    let firstEvidence = Evidence(objectID: first.id, snippet: "First source", authority: first.authority)
    let repeatedEvidence = Evidence(objectID: first.id, range: 0..<1, snippet: "Repeated source", authority: first.authority)
    let secondEvidence = Evidence(objectID: second.id, snippet: "Second source", authority: second.authority)
    try await fixture.store.save([firstEvidence, repeatedEvidence, secondEvidence])
    let claim = CoreClaim(subject: fixture.project.id, predicate: Predicate.status, literal: "Link fixture", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    try await fixture.store.save([claim])
    try await fixture.store.link(claim: claim.id, to: firstEvidence.id, stance: .supports)
    try await fixture.store.link(claim: claim.id, to: repeatedEvidence.id, stance: .supports)
    try await fixture.store.link(claim: claim.id, to: secondEvidence.id, stance: .supports)
    let broker = CompanionBroker(store: fixture.store)
    let page = try await broker.prepare(
        CompanionRequest(section: .chat, query: "What is Quillberry?", answerMode: .evidence), device: fixturePhone()).page
    let targets = Set(page.records.flatMap(\.links).map { Data($0.targetID.utf8) })
    #expect(targets.contains(Data(first.id.value.utf8)))
    #expect(targets.contains(Data(second.id.value.utf8)))
    let detail = try await broker.prepare(CompanionRequest(section: .claims, recordID: claim.id.value), device: fixturePhone()).page
    let links = try #require(detail.records.first?.links)
    #expect(links.count == 2 && Set(links.map(\.id)).count == 2)
}

private func savedPhoneAnswer(_ fixture: BrokerFixture, question: String) async throws -> (Turn, EvidenceID) {
    let receipt = Receipt(query: question, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [.medical],
        stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    let source = GroundingSource(index: 1, title: "Fixture", text: fixture.publicObject.text,
        objectID: fixture.publicObject.id, authority: fixture.publicObject.authority)
    let evidence = Evidence(objectID: fixture.publicObject.id, snippet: fixture.publicObject.text, authority: fixture.publicObject.authority)
    try await fixture.store.save([evidence])
    var turn = Turn(role: .core, text: "Fixture answer.", sources: [source], receipt: receipt)
    turn.receiptEvidence = [(evidence.id, 0.75)]
    return (turn, evidence.id)
}

@Test("a generated phone chat is saved only on acknowledgement and can be resumed")
func phoneSavedChatGenerationResumesAfterAcknowledgement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-phone-generation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("empty.sqlite3"))
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: store)
    let request = CompanionRequest(section: .chat, query: "What is the fixture?", chatThreadID: thread)
    let pending = try await broker.prepare(request, device: phone)
    #expect(pending.page.chatHistoryVersion == nil && pending.page.chatThreadID == nil)
    #expect(try await store.receipts().isEmpty)
    #expect(try await store.conversations().isEmpty)
    let completed = try await pending.acknowledge()
    #expect(completed.matchesChatHistory(thread: thread))
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID,
        domains: [.project, .publicRecord], selectedDomain: nil)
    let initial = try #require(try await store.companionHistory(scope: scope, thread: thread))
    #expect(initial.exchanges.count == 1 && initial.exchanges[0].question.text == request.query)
    #expect(initial.exchanges[0].receipt.id == Store.companionReceiptID(for: request.id))

    let followUp = CompanionRequest(section: .chat, query: "What about it?", chatThreadID: thread)
    let next = try await broker.prepare(followUp, device: phone)
    #expect(try await store.companionHistory(scope: scope, thread: thread)?.exchanges.count == 1)
    _ = try await next.acknowledge()
    let history = try #require(try await store.companionHistory(scope: scope, thread: thread))
    #expect(history.exchanges.map(\.question.text) == [request.query, followUp.query])
    let reopened = try await broker.prepare(CompanionRequest(section: .chat, chatHistoryAction: .open, chatThreadID: thread), device: phone).page
    #expect(reopened.matchesChatHistory(thread: thread))
    #expect(reopened.records.contains { $0.body == followUp.query })
}

@Test("generated phone replies based on the same history cannot both be saved")
func phoneSavedChatGenerationRejectsStaleReply() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-phone-generation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("empty.sqlite3"))
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: store)
    let seed = try await broker.prepare(CompanionRequest(section: .chat, query: "Initial fixture?", chatThreadID: thread), device: phone)
    _ = try await seed.acknowledge()
    let first = try await broker.prepare(CompanionRequest(section: .chat, query: "First follow-up?", chatThreadID: thread), device: phone)
    let second = try await broker.prepare(CompanionRequest(section: .chat, query: "Second follow-up?", chatThreadID: thread), device: phone)
    _ = try await first.acknowledge()
    do { _ = try await second.acknowledge(); Issue.record("a reply based on the old history was saved") }
    catch CompanionHistoryError.staleConversation { }
    catch { Issue.record("expected stale conversation, got \(error)") }
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID,
        domains: [.project, .publicRecord], selectedDomain: nil)
    let history = try #require(try await store.companionHistory(scope: scope, thread: thread))
    #expect(history.exchanges.map(\.question.text) == ["Initial fixture?", "First follow-up?"])
    #expect(try await store.receipts().count == 2)
}

@Test("saved chat does not disclose a reply after its restored source is restricted", arguments: ["draft", "final"])
func phoneSavedChatGenerationRechecksRestoredSources(timing: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let store = fixture.store, priorObject = fixture.publicObject, recorder = PhoneProgressRecorder()
    let broker = CompanionBroker(store: store, chatGenerator: { request, _, emit in
        var restricted = priorObject
        restricted.domain = .medical
        _ = try await store.ingest([restricted])
        if timing == "draft" {
            await recorder.attempt()
            try await emit(CompanionPage(title: "Draft", records: [CompanionRecord(id: "draft", title: "Draft", body: "PRIOR_FIXTURE_SENTINEL")]))
        }
        let receipt = Receipt(query: request.query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
            stages: [], objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
            contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
        // Simulate a writer echoing prior context without citing it as a new source.
        return Turn(role: .core, text: "PRIOR_FIXTURE_SENTINEL", receipt: receipt)
    })
    let request = CompanionRequest(section: .chat, query: "What about it?", chatThreadID: thread)
    do {
        _ = try await broker.prepare(request, device: phone, progress: { _ in await recorder.record() })
        Issue.record("a reply based on newly restricted history was prepared")
    } catch { }
    #expect(try await store.object(priorObject.id)?.domain == .medical)
    #expect(await recorder.attempts == (timing == "draft" ? 1 : 0))
    #expect(await recorder.count == 0)
    #expect(try await store.receipts().count == 1)
}

@Test("saved chat rechecks new source and trace admission before disclosure",
      arguments: ["object", "evidence", "passage", "claim"], [false, true])
func phoneSavedChatGenerationRechecksNewSourcesBeforeDisclosure(kind: String, restrict: Bool) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let store = fixture.store
    let object = CoreObject(sourceID: fixture.publicObject.sourceID, kind: .document, externalID: "new-fixture",
        title: "New fixture", text: "NEW_SOURCE_SENTINEL", domain: .project, authority: .authoredArtifact)
    _ = try await store.ingest([object])
    let evidence = Evidence(objectID: object.id, snippet: object.text, authority: object.authority)
    let passage = Evidence(objectID: object.id, range: 0..<3, snippet: "NEW", authority: object.authority)
    try await store.save([evidence])
    let subject = fixture.project.id
    let claim = CoreClaim(subject: subject, predicate: Predicate.status, literal: "new fixture", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    try await store.save([claim])
    try await store.link(claim: claim.id, to: evidence.id, stance: .supports)
    let broker = CompanionBroker(store: store, chatGenerator: { request, _, _ in
        let receipt = Receipt(query: request.query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
            stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0, claimsConsulted: 0,
            contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
        let source = GroundingSource(index: 1, title: object.title, text: object.text, objectID: object.id,
            authority: object.authority)
        var turn = Turn(role: .core, text: object.text, sources: kind == "object" ? [source] : [], receipt: receipt)
        if kind == "evidence" { turn.receiptEvidence = [(evidence.id, 0.5)] }
        if kind == "passage" { turn.receiptPassages = [(passage, 0.5)] }
        if kind == "claim" { turn.receiptClaims = [claim.id] }
        return turn
    }, afterChatPreparation: {
        if !restrict { return }
        if kind == "claim" {
            try await store.database.execute("UPDATE entity SET domain = ? WHERE id = ?", [.text("medical"), .text(subject.value)])
        } else {
            var restricted = object
            restricted.domain = .medical
            _ = try await store.ingest([restricted])
        }
    })
    let request = CompanionRequest(section: .chat, query: "A new fixture?", chatThreadID: thread)
    if restrict {
        await #expect(throws: (any Error).self) { try await broker.prepare(request, device: phone) }
        if kind == "claim" { #expect(try await store.entity(subject)?.domain == .medical) }
        else { #expect(try await store.object(object.id)?.domain == .medical) }
        #expect(try await store.receipts().count == 1)
    } else {
        let prepared = try await broker.prepare(request, device: phone)
        let page = try await prepared.acknowledge()
        #expect(page.matchesChatHistory(thread: thread))
        #expect(try await store.receipts().count == 2)
    }
}

@Test("canonically equivalent source IDs cannot hide a restricted represented object")
func phoneSavedChatRejectsCanonicallyEquivalentObjectIDs() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var admitted = fixture.publicObject, blocked = fixture.privateObject
    admitted.id = ObjectID("\u{00E9}")
    blocked.id = ObjectID("e\u{0301}")
    admitted.externalID = "normalization-allowed"
    blocked.externalID = "normalization-blocked"
    _ = try await fixture.store.ingest([admitted, blocked])
    let phone = fixturePhone(), request = CompanionRequest(section: .chat, query: "Fixture?", chatThreadID: UUID())
    let receipt = Receipt(query: request.query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [.medical],
        stages: [], objectsSearched: 2, objectsRetrieved: 2, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    let source = GroundingSource(index: 1, title: "Fixture", text: "PRIVATE_FIXTURE", objectID: admitted.id,
        authority: admitted.authority, representedObjectIDs: [blocked.id])
    let turn = Turn(role: .core, text: "PRIVATE_FIXTURE", sources: [source], receipt: receipt)
    await #expect(throws: CompanionError.self) {
        try await CompanionBroker(store: fixture.store).prepareSavedChatDelivery(turn, request: request,
            device: phone, domains: [.project, .publicRecord], expectedRevision: .empty)
    }
    #expect(try await fixture.store.receipts().isEmpty)
}

@Test("saved chat disclosure validation follows source restrictions before and after ACK", arguments: ["prepared", "committed"])
func phoneSavedChatReplayValidatorRechecksSources(phase: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let store = fixture.store
    let object = CoreObject(sourceID: fixture.publicObject.sourceID, kind: .document, externalID: "replay-fixture",
        title: "Replay fixture", text: "REPLAY_SENTINEL", domain: .project, authority: .authoredArtifact)
    _ = try await store.ingest([object])
    let broker = CompanionBroker(store: store, chatGenerator: { request, _, _ in
        let receipt = Receipt(query: request.query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
            stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0, claimsConsulted: 0,
            contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
        let source = GroundingSource(index: 1, title: object.title, text: object.text, objectID: object.id, authority: object.authority)
        return Turn(role: .core, text: object.text, sources: [source], receipt: receipt)
    })
    let request = CompanionRequest(section: .chat, query: "Follow-up?", chatThreadID: thread)
    let prepared = try await broker.prepare(request, device: phone)
    try await prepared.validateDisclosure()
    if phase == "committed" {
        _ = try await prepared.acknowledge()
        try await prepared.validateDisclosure()
    }
    var restricted = object
    restricted.domain = .medical
    _ = try await store.ingest([restricted])
    await #expect(throws: CompanionError.self) { try await prepared.validateDisclosure() }
    #expect(try await store.receipts().count == (phase == "committed" ? 2 : 1))
}

@Test("a cached saved reply stops validating after its thread is deleted or advances", arguments: ["deleted", "advanced"])
func phoneSavedChatReplayValidatorRejectsChangedHistory(change: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let store = fixture.store
    let broker = CompanionBroker(store: store, chatGenerator: { request, _, _ in
        let receipt = Receipt(query: request.query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
            stages: [], objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
            contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
        return Turn(role: .core, text: "Fixture answer.", receipt: receipt)
    })
    let first = try await broker.prepare(CompanionRequest(section: .chat, query: "First follow-up?", chatThreadID: thread), device: phone)
    _ = try await first.acknowledge()
    try await first.validateDisclosure()
    if change == "deleted" {
        let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID,
            domains: [.project, .publicRecord], selectedDomain: nil)
        try await store.deleteConversation(id: scope.conversationID(for: thread))
    } else {
        let next = try await broker.prepare(CompanionRequest(section: .chat, query: "Another follow-up?", chatThreadID: thread), device: phone)
        _ = try await next.acknowledge()
    }
    await #expect(throws: CompanionError.self) { try await first.validateDisclosure() }
}

@Test("a saved phone answer and its trace are committed only after acknowledgement")
func phoneSavedAnswerCommitsOnlyAfterAcknowledgement() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), question = "What is Quillberry?"
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: thread)
    var (turn, evidence) = try await savedPhoneAnswer(fixture, question: question)
    turn.persistenceError = "Synthetic outbound audit warning"
    let failures = PhoneDeliveryFailureRecorder()
    let broker = CompanionBroker(store: fixture.store, onDeliveryFailure: { await failures.record($0) })
    let prepared = try await fixture.prepareSavedChatFixture(broker, turn, request: request, device: phone, domains: [.project, .publicRecord])
    let receiptID = Store.companionReceiptID(for: request.id)
    #expect(prepared.page.receiptID == receiptID.value)
    #expect(prepared.page.chatHistoryVersion == nil && prepared.page.chatThreadID == nil)
    #expect(try await fixture.store.receipts().isEmpty)
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    if case .missing = try await fixture.store.companionHistoryLookup(scope: scope, thread: thread) { }
    else { Issue.record("history existed before phone acknowledgement") }
    let completed = try await prepared.acknowledge()
    #expect(completed.matchesChatHistory(thread: thread))
    let snapshot = try #require(try await fixture.store.companionHistory(scope: scope, thread: thread))
    let exchange = try #require(snapshot.exchanges.first)
    #expect(exchange.question.text == question && exchange.answer.text == turn.text)
    #expect(exchange.answer.id == turn.id.uuidString && exchange.receipt.id == receiptID)
    #expect(exchange.receipt.stages.contains { $0.name == "companion.delivery" })
    #expect(exchange.receipt.stages.contains { $0.name == "companion.operation" })
    #expect(exchange.receipt.stages.contains { $0.name == "companion.operation" && $0.note?.contains(CompanionChatFingerprint.hex(request)) == true })
    #expect(exchange.answer.error?.contains("Synthetic outbound audit warning") == true)
    #expect(completed.records.contains { $0.id == receiptID.value })
    #expect(completed.records.first?.fields.contains { $0.label == "Audit warning" && $0.value == "Synthetic outbound audit warning" } == true)
    let reopened = try await broker.prepare(CompanionRequest(section: .chat, chatHistoryAction: .open, chatThreadID: thread), device: phone).page
    #expect(reopened.records.contains { $0.fields.contains { $0.label == "Warning" && $0.value.contains("Synthetic outbound audit warning") } })
    let trace = try await fixture.store.trace(receipt: receiptID)
    #expect(trace.count == 1 && trace.first?.0.id == evidence && trace.first?.2 == 0.75)
    #expect(await failures.messages.isEmpty)
}

@Test("a saved phone delivery refuses claims outside its admitted scope", arguments: ["source", "trace"])
func phoneSavedAnswerRejectsBlockedClaims(location: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), question = "Fixture question"
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: UUID())
    let (initial, _) = try await savedPhoneAnswer(fixture, question: question)
    let blocked = CoreClaim(subject: fixture.privateEntity.id, predicate: Predicate.status, literal: "fixture", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .medical)
    try await fixture.store.save([blocked])
    var turn = initial
    if location == "source" {
        turn.sources = [GroundingSource(index: 1, title: "Fixture", text: fixture.publicObject.text,
            objectID: fixture.publicObject.id, authority: fixture.publicObject.authority, claimID: blocked.id)]
    } else { turn.receiptClaims = [blocked.id] }
    await #expect(throws: CompanionError.self) {
        try await fixture.prepareSavedChatFixture(CompanionBroker(store: fixture.store), turn, request: request,
            device: phone, domains: [.project, .publicRecord])
    }
    #expect(try await fixture.store.receipts().isEmpty)
}

@Test("an untrusted thread appearing before acknowledgement prevents a saved phone delivery")
func phoneSavedAnswerRechecksThreadAtAcknowledgement() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), question = "Fixture question"
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: thread)
    let (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    let prepared = try await fixture.prepareSavedChatFixture(CompanionBroker(store: fixture.store), turn, request: request,
        device: phone, domains: [.project, .publicRecord])
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    try await fixture.store.openConversation(id: scope.conversationID(for: thread), title: "Unlabelled")
    try await fixture.store.append(StoredTurn(conversationID: scope.conversationID(for: thread), ordinal: 0, role: "you", text: "Unlabelled"))
    await #expect(throws: CompanionHistoryError.self) { try await prepared.acknowledge() }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.turns(conversationID: scope.conversationID(for: thread)).count == 1)
}

@Test("concurrent saved phone replies cannot commit against the same prior context", arguments: ["new", "existing"])
func phoneSavedAnswerRejectsStaleThreadRevision(initial: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: fixture.store)
    if initial == "existing" {
        let question = "Prior fixture"
        let (turn, _) = try await savedPhoneAnswer(fixture, question: question)
        let first = try await fixture.prepareSavedChatFixture(broker, turn,
            request: CompanionRequest(section: .chat, query: question, chatThreadID: thread),
            device: phone, domains: [.project, .publicRecord])
        _ = try await first.acknowledge()
    }
    let firstQuestion = "Concurrent first", secondQuestion = "Concurrent second"
    let (firstTurn, _) = try await savedPhoneAnswer(fixture, question: firstQuestion)
    let (secondTurn, _) = try await savedPhoneAnswer(fixture, question: secondQuestion)
    let first = try await fixture.prepareSavedChatFixture(broker, firstTurn,
        request: CompanionRequest(section: .chat, query: firstQuestion, chatThreadID: thread),
        device: phone, domains: [.project, .publicRecord])
    let second = try await fixture.prepareSavedChatFixture(broker, secondTurn,
        request: CompanionRequest(section: .chat, query: secondQuestion, chatThreadID: thread),
        device: phone, domains: [.project, .publicRecord])
    _ = try await first.acknowledge()
    do { _ = try await second.acknowledge(); Issue.record("a stale reply was saved") }
    catch CompanionHistoryError.staleConversation { }
    catch { Issue.record("expected stale conversation, got \(error)") }
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    let history = try #require(try await fixture.store.companionHistory(scope: scope, thread: thread))
    #expect(history.exchanges.count == (initial == "existing" ? 2 : 1))
    #expect(history.exchanges.last?.question.text == firstQuestion)
    #expect(try await fixture.store.receipts().count == (initial == "existing" ? 2 : 1))
}

@Test("a deleted phone thread cannot be recreated by an older pending answer")
func phoneSavedAnswerDoesNotResurrectDeletedThread() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: fixture.store)
    let questionA = "First pending fixture", questionB = "Second pending fixture"
    let (turnA, _) = try await savedPhoneAnswer(fixture, question: questionA)
    let (turnB, _) = try await savedPhoneAnswer(fixture, question: questionB)
    let a = try await fixture.prepareSavedChatFixture(broker, turnA,
        request: CompanionRequest(section: .chat, query: questionA, chatThreadID: thread), device: phone, domains: [.project, .publicRecord])
    let b = try await fixture.prepareSavedChatFixture(broker, turnB,
        request: CompanionRequest(section: .chat, query: questionB, chatThreadID: thread), device: phone, domains: [.project, .publicRecord])
    _ = try await a.acknowledge()
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    try await fixture.store.deleteConversation(id: scope.conversationID(for: thread))
    do { _ = try await b.acknowledge(); Issue.record("an old pending answer recreated the deleted thread") }
    catch CompanionHistoryError.staleConversation { }
    catch { Issue.record("expected stale conversation, got \(error)") }
    if case .unavailable = try await fixture.store.companionHistoryLookup(scope: scope, thread: thread) { }
    else { Issue.record("a deleted phone thread was available for reuse") }
    #expect(try await fixture.store.receipts().count == 1)
}

@Test("a same-sized changed phone history is not the prior revision")
func phoneSavedAnswerRejectsSameCountDifferentRevision() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: fixture.store)
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    let firstQuestion = "First history"
    let (firstTurn, _) = try await savedPhoneAnswer(fixture, question: firstQuestion)
    let first = try await fixture.prepareSavedChatFixture(broker, firstTurn,
        request: CompanionRequest(section: .chat, query: firstQuestion, chatThreadID: thread), device: phone, domains: [.project, .publicRecord])
    _ = try await first.acknowledge()
    let old = try #require(try await fixture.store.companionHistory(scope: scope, thread: thread))
    // Simulate a different valid thread with the same number of exchanges. Its revision
    // must not authorize a follow-up generated using the first one's context.
    let otherThread = UUID(), secondQuestion = "Different history"
    let (secondTurn, _) = try await savedPhoneAnswer(fixture, question: secondQuestion)
    let second = try await fixture.prepareSavedChatFixture(broker, secondTurn,
        request: CompanionRequest(section: .chat, query: secondQuestion, chatThreadID: otherThread), device: phone, domains: [.project, .publicRecord])
    _ = try await second.acknowledge()
    let newer = try #require(try await fixture.store.companionHistory(scope: scope, thread: otherThread))
    #expect(old.exchanges.count == newer.exchanges.count)
    #expect(old.revision != newer.revision)
    let question = "Stale follow-up"
    let (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    let prepared = try await fixture.prepareSavedChatFixture(broker, turn,
        request: CompanionRequest(section: .chat, query: question, chatThreadID: otherThread),
        device: phone, domains: [.project, .publicRecord], expectedRevision: old.revision)
    do { _ = try await prepared.acknowledge(); Issue.record("a same-sized different history was accepted") }
    catch CompanionHistoryError.staleConversation { }
    catch { Issue.record("expected stale conversation, got \(error)") }
    #expect(try await fixture.store.companionHistory(scope: scope, thread: otherThread)?.exchanges.count == 1)
}

@Test("a rolled-back phone answer does not make another pending answer stale")
func phoneSavedAnswerRollbackKeepsRevision() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: fixture.store)
    let (turnA, _) = try await savedPhoneAnswer(fixture, question: "First fixture")
    let (turnB, _) = try await savedPhoneAnswer(fixture, question: "Second fixture")
    let first = try await fixture.prepareSavedChatFixture(broker, turnA,
        request: CompanionRequest(section: .chat, query: "First fixture", chatThreadID: thread), device: phone, domains: [.project, .publicRecord])
    let second = try await fixture.prepareSavedChatFixture(broker, turnB,
        request: CompanionRequest(section: .chat, query: "Second fixture", chatThreadID: thread), device: phone, domains: [.project, .publicRecord])
    try await fixture.store.database.execute("""
        CREATE TEMP TRIGGER reject_first_answer BEFORE INSERT ON conversation_turn
        WHEN NEW.role = 'core' BEGIN SELECT RAISE(ABORT, 'synthetic first failure'); END
        """)
    do { _ = try await first.acknowledge(); Issue.record("the injected failure was not raised") }
    catch { #expect(String(describing: error).contains("synthetic first failure")) }
    try await fixture.store.database.execute("DROP TRIGGER reject_first_answer")
    let completed = try await second.acknowledge()
    #expect(completed.matchesChatHistory(thread: thread))
    #expect(try await fixture.store.receipts().count == 1)
}

@Test("saved phone delivery rechecks source admission at acknowledgement", arguments: ["current", "prior"])
func phoneSavedAnswerRechecksSourceAtAcknowledgement(which: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), broker = CompanionBroker(store: fixture.store)
    let firstQuestion = "First fixture question"
    let (firstTurn, _) = try await savedPhoneAnswer(fixture, question: firstQuestion)
    if which == "prior" {
        let firstRequest = CompanionRequest(section: .chat, query: firstQuestion, chatThreadID: thread)
        let first = try await fixture.prepareSavedChatFixture(broker, firstTurn, request: firstRequest, device: phone, domains: [.project, .publicRecord])
        _ = try await first.acknowledge()
    }
    let question = "Second fixture question"
    var (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    if which == "prior" { turn.sources = []; turn.receiptEvidence = [] }
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: thread)
    let prepared = try await fixture.prepareSavedChatFixture(broker, turn, request: request, device: phone, domains: [.project, .publicRecord])
    var restricted = fixture.publicObject
    restricted.domain = .medical
    _ = try await fixture.store.ingest([restricted])
    await #expect(throws: (any Error).self) { try await prepared.acknowledge() }
    #expect(try await fixture.store.receipts().count == (which == "prior" ? 1 : 0))
}

@Test("saved phone delivery rejects forged scope and ambiguous request fields")
func phoneSavedAnswerRejectsForgedRequest() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), question = "Fixture question"
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: UUID())
    let (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    let broker = CompanionBroker(store: fixture.store)
    await #expect(throws: CompanionError.self) {
        try await fixture.prepareSavedChatFixture(broker, turn, request: request, device: phone, domains: [.project, .medical])
    }
    var variants: [CompanionRequest] = []
    var bad = request; bad.section = .home; variants.append(bad)
    bad = request; bad.answerMode = .evidence; variants.append(bad)
    bad = request; bad.chatHistoryAction = .list; variants.append(bad)
    bad = request; bad.recordID = "unexpected"; variants.append(bad)
    bad = request; bad.asOf = Date(timeIntervalSince1970: 1); variants.append(bad)
    bad = request; bad.offset = 1; variants.append(bad)
    bad = request; bad.resumeID = UUID(); variants.append(bad)
    bad = request; bad.chatThreadID = nil; variants.append(bad)
    bad = request; bad.query = "A different question"; variants.append(bad)
    for variant in variants {
        await #expect(throws: CompanionError.self) {
            try await fixture.prepareSavedChatFixture(broker, turn, request: variant, device: phone, domains: [.project, .publicRecord])
        }
    }
    let userTurn = Turn(role: .you, text: turn.text, receipt: turn.receipt)
    await #expect(throws: CompanionError.self) {
        try await fixture.prepareSavedChatFixture(broker, userTurn, request: request, device: phone, domains: [.project, .publicRecord])
    }
    #expect(try await fixture.store.receipts().isEmpty)
}

@Test("a saved phone answer retains an explicitly selected admitted domain")
func phoneSavedAnswerHonorsSelectedDomain() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), question = "Fixture question"
    let request = CompanionRequest(section: .chat, query: question, domain: "project", chatThreadID: thread)
    let (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    let domains = Set(phone.domains.compactMap(Domain.init(rawValue:))).intersection(Domain.project.readableDomains)
    let prepared = try await fixture.prepareSavedChatFixture(CompanionBroker(store: fixture.store), turn, request: request, device: phone, domains: domains)
    let completed = try await prepared.acknowledge()
    #expect(completed.matchesChatHistory(thread: thread))
    let selected = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: domains, selectedDomain: .project)
    let automatic = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: domains, selectedDomain: nil)
    #expect(try await fixture.store.companionHistory(scope: selected, thread: thread)?.exchanges.count == 1)
    #expect(try await fixture.store.companionHistory(scope: automatic, thread: thread) == nil)
}

@Test("phone passage provenance rejects an existing conflicting evidence ID", arguments: ["before", "after"])
func phoneSavedAnswerRejectsConflictingPassageEvidence(timing: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), question = "Fixture question"
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: UUID())
    var (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    let passage = Evidence(objectID: fixture.publicObject.id, range: 0..<5, snippet: "Public fixture", authority: .authoredArtifact)
    var conflict = Evidence(objectID: fixture.privateObject.id, range: 0..<5, snippet: "Private original", authority: .directStatement)
    conflict.id = passage.id
    turn.receiptEvidence = []
    turn.receiptPassages = [(passage, 0.8)]
    let broker = CompanionBroker(store: fixture.store)
    if timing == "before" {
        try await fixture.store.save([conflict])
        await #expect(throws: (any Error).self) {
            try await fixture.prepareSavedChatFixture(broker, turn, request: request, device: phone, domains: [.project, .publicRecord])
        }
    } else {
        let prepared = try await fixture.prepareSavedChatFixture(broker, turn, request: request, device: phone, domains: [.project, .publicRecord])
        try await fixture.store.save([conflict])
        await #expect(throws: (any Error).self) { try await prepared.acknowledge() }
    }
    #expect(try await fixture.store.receipts().isEmpty)
    let existing = try #require(try await fixture.store.evidence(id: passage.id))
    #expect(existing.objectID == fixture.privateObject.id && existing.snippet == "Private original")
}

@Test("phone evidence compatibility checks every stored provenance field", arguments: ["object", "range", "authority", "snippet", "blob"])
func phoneEvidenceCompatibilityRejectsDifferentProvenance(field: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let passage = Evidence(objectID: fixture.publicObject.id, range: 0..<5, snippet: "fixture", authority: .authoredArtifact)
    try await fixture.store.save([passage])
    #expect(try await fixture.store.companionAdditionalEvidenceIsCompatible([passage, passage]))
    var changed = passage
    switch field {
    case "object": changed.objectID = fixture.privateObject.id
    case "range": changed.range = 1..<5
    case "authority": changed.authority = .modelInference
    case "snippet": changed.snippet = "different"
    default:
        try await fixture.store.database.execute("UPDATE evidence SET id = ? WHERE id = ?",
            [.blob(Data(passage.id.value.utf8)), .text(passage.id.value)])
    }
    #expect(try await !fixture.store.companionAdditionalEvidenceIsCompatible([changed]))
    if field != "blob" {
        #expect(try await !fixture.store.companionAdditionalEvidenceIsCompatible([passage, changed]))
    }
}

@Test("legacy phone chat rechecks evidence identity at acknowledgement")
func phoneLegacyAnswerRejectsLateEvidenceConflict() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let (initial, _) = try await savedPhoneAnswer(fixture, question: "Fixture question")
    let passage = Evidence(objectID: fixture.publicObject.id, range: 0..<5, snippet: "Public fixture", authority: .authoredArtifact)
    var conflict = Evidence(objectID: fixture.privateObject.id, range: 0..<5, snippet: "Private original", authority: .directStatement)
    conflict.id = passage.id
    var turn = initial
    turn.receiptEvidence = []; turn.receiptPassages = [(passage, 0.8)]
    let prepared = try await CompanionBroker(store: fixture.store).prepareChatDelivery(turn, device: fixturePhone(), domains: [.project, .publicRecord])
    try await fixture.store.save([conflict])
    await #expect(throws: (any Error).self) { try await prepared.acknowledge() }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.evidence(id: passage.id)?.snippet == "Private original")
}

@Test("legacy and Evidence phone answers recheck displayed sources at acknowledgement", arguments: ["chat", "evidence"])
func phoneLegacyAnswerRechecksSourceAtAcknowledgement(mode: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), failures = PhoneDeliveryFailureRecorder()
    let broker = CompanionBroker(store: fixture.store, onDeliveryFailure: { await failures.record($0) })
    let prepared: CompanionPreparedPage
    if mode == "chat" {
        var (turn, _) = try await savedPhoneAnswer(fixture, question: "Fixture question")
        // A displayed source must be checked even if it is absent from the receipt trace.
        turn.receiptEvidence = []; turn.receiptPassages = []
        prepared = try await broker.prepareChatDelivery(turn, device: phone, domains: [.project, .publicRecord])
    } else {
        prepared = try await broker.prepare(CompanionRequest(section: .chat, query: "PROJECT_SENTINEL", answerMode: .evidence), device: phone)
    }
    var restricted = fixture.publicObject
    restricted.domain = .medical
    _ = try await fixture.store.ingest([restricted])
    await #expect(throws: (any Error).self) { try await prepared.acknowledge() }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(await failures.messages == ["An iPhone answer was acknowledged, but its receipt could not be saved."])
}

@Test("legacy phone chat rechecks a displayed claim even when it has no receipt claim link")
func phoneLegacyAnswerRechecksDisplayedClaimAtAcknowledgement() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let (initial, _) = try await savedPhoneAnswer(fixture, question: "Fixture question")
    let claim = CoreClaim(subject: fixture.project.id, predicate: Predicate.status, literal: "fixture", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    try await fixture.store.save([claim])
    let evidence = Evidence(objectID: fixture.publicObject.id, snippet: fixture.publicObject.text, authority: .authoredArtifact)
    try await fixture.store.save([evidence]); try await fixture.store.link(claim: claim.id, to: evidence.id, stance: .supports)
    var turn = initial
    turn.sources = [GroundingSource(index: 1, title: "Fixture", text: fixture.publicObject.text,
        objectID: fixture.publicObject.id, authority: fixture.publicObject.authority, claimID: claim.id)]
    turn.receiptClaims = []; turn.receiptEvidence = []; turn.receiptPassages = []
    let prepared = try await CompanionBroker(store: fixture.store).prepareChatDelivery(turn, device: fixturePhone(), domains: [.project, .publicRecord])
    try await fixture.store.database.execute("UPDATE claim SET domain = ? WHERE id = ?", [.text("medical"), .text(claim.id.value)])
    await #expect(throws: (any Error).self) { try await prepared.acknowledge() }
    #expect(try await fixture.store.receipts().isEmpty)
}

@Test("phone receipt checks displayed and trace admission independently", arguments: ["displayed-object", "displayed-claim", "trace-only", "trace-claim"])
func phoneReceiptIndependentlyRechecksReferences(kind: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone()
    let (turn, evidenceID) = try await savedPhoneAnswer(fixture, question: "Fixture question")
    let receipt = try #require(turn.receipt)
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    var objects = Set<ObjectID>(), claims = Set<ClaimID>(), receiptClaims: [ClaimID] = [], trace: [(EvidenceID, Double)] = []
    if kind == "displayed-claim" || kind == "trace-claim" {
        let claim = CoreClaim(subject: fixture.project.id, predicate: Predicate.status, literal: "fixture", confidence: 0.9,
            authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
        try await fixture.store.save([claim]); try await fixture.store.link(claim: claim.id, to: evidenceID, stance: .supports)
        if kind == "displayed-claim" { claims.insert(claim.id) } else { receiptClaims.append(claim.id) }
        try await fixture.store.database.execute("UPDATE claim SET domain = ? WHERE id = ?", [.text("medical"), .text(claim.id.value)])
    } else {
        if kind == "displayed-object" { objects.insert(fixture.publicObject.id) }
        else { trace = [(evidenceID, 0.75)] }
        var restricted = fixture.publicObject
        restricted.domain = .medical
        _ = try await fixture.store.ingest([restricted])
    }
    await #expect(throws: CompanionHistoryError.self) {
        try await fixture.store.saveCompanionReceipt(receipt, scope: scope, representedObjects: objects,
            referencedClaims: claims, evidence: trace, claims: receiptClaims)
    }
    #expect(try await fixture.store.receipts().isEmpty)
}

@Test("phone Evidence answers recheck passage identity before and after preparation", arguments: ["before", "after"])
func phoneEvidenceAnswerRejectsPassageConflict(timing: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let query = "PROJECT_SENTINEL", now = Date(timeIntervalSince1970: 1_800_000_001)
    let expected = try await Reasoner(store: fixture.store, now: now).answer(query, persistReceipt: false, maximumDomains: [.project, .publicRecord])
    let passage = try #require(Reasoner.passageEvidence(expected.passages).first?.0)
    var conflict = Evidence(objectID: fixture.privateObject.id, range: passage.range, snippet: "Private original", authority: .directStatement)
    conflict.id = passage.id
    let broker = CompanionBroker(store: fixture.store, now: { now })
    let request = CompanionRequest(section: .chat, query: query, answerMode: .evidence)
    if timing == "before" {
        try await fixture.store.save([conflict])
        await #expect(throws: (any Error).self) { try await broker.prepare(request, device: fixturePhone()) }
    } else {
        let prepared = try await broker.prepare(request, device: fixturePhone())
        try await fixture.store.save([conflict])
        await #expect(throws: (any Error).self) { try await prepared.acknowledge() }
    }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.evidence(id: passage.id)?.snippet == "Private original")
}

@Test("a failed acknowledged phone save rolls back the answer and receipt")
func phoneSavedAnswerRollsBackOnAcknowledgementFailure() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), thread = UUID(), question = "Fixture question"
    let request = CompanionRequest(section: .chat, query: question, chatThreadID: thread)
    let (turn, _) = try await savedPhoneAnswer(fixture, question: question)
    let failures = PhoneDeliveryFailureRecorder()
    let broker = CompanionBroker(store: fixture.store, onDeliveryFailure: { await failures.record($0) })
    let prepared = try await fixture.prepareSavedChatFixture(broker, turn, request: request,
        device: phone, domains: [.project, .publicRecord])
    try await fixture.store.database.execute("""
        CREATE TEMP TRIGGER companion_broker_reject_answer BEFORE INSERT ON conversation_turn
        WHEN NEW.role = 'core' BEGIN SELECT RAISE(ABORT, 'fixture delivery failure'); END
        """)
    do { _ = try await prepared.acknowledge(); Issue.record("the acknowledgement unexpectedly saved") }
    catch { #expect(String(describing: error).contains("fixture delivery failure")) }
    #expect(try await fixture.store.receipts().isEmpty)
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID, domains: [.project, .publicRecord], selectedDomain: nil)
    if case .missing = try await fixture.store.companionHistoryLookup(scope: scope, thread: thread) { }
    else { Issue.record("a failed acknowledgement left a conversation") }
    #expect(await failures.messages == ["An iPhone answer was acknowledged, but its conversation and receipt could not be saved."])
}

private func savePhoneHistoryFixture(_ fixture: BrokerFixture, phone: CompanionDevice,
                                     sourcesJSON: String? = nil, verdictsJSON: String = "[]",
                                     createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) async throws -> (UUID, ReceiptID) {
    let scope = CompanionHistoryScope(deviceID: phone.id, grantID: phone.grantID,
        domains: [.project, .publicRecord], selectedDomain: nil)
    let thread = UUID(), request = UUID(), question = "What is Quillberry?"
    let receipt = Receipt(query: question, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: [ReceiptStage(name: "companion.delivery", milliseconds: 0,
            note: "Acknowledged by paired device \(phone.id.uuidString) (Fixture phone). Grant \(phone.grantID.uuidString).")],
        objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 1, confidence: nil,
        id: Store.companionReceiptID(for: request))
    let source = GroundingSource(index: 1, title: "Fixture", text: fixture.publicObject.text,
        objectID: fixture.publicObject.id, authority: fixture.publicObject.authority)
    let encoded = String(decoding: try JSONEncoder().encode([source]), as: UTF8.self)
    let answer = StoredTurn(conversationID: scope.conversationID(for: thread), ordinal: 1, role: "core",
        text: "Quillberry is built with Swift.", sourcesJSON: sourcesJSON ?? encoded, verdictsJSON: verdictsJSON,
        receiptID: receipt.id, createdAt: createdAt)
    _ = try await fixture.store.saveCompanionExchange(scope: scope, thread: thread, request: request,
        requestDigest: String(repeating: "a", count: 64), question: question, answer: answer, receipt: receipt, expectedRevision: .empty)
    return (thread, receipt.id)
}

@Test("saved phone history opens with its question, answer, sources and receipt only for its grant")
func phoneHistoryBrokerListsAndOpensWithinGrant() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), broker = CompanionBroker(store: fixture.store)
    let (thread, receiptID) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let listRequest = CompanionRequest(section: .chat, chatHistoryAction: .list)
    let list = try await broker.prepare(listRequest, device: phone).page
    #expect(list.chatHistoryVersion == 1)
    #expect(list.records.map(\.id) == [thread.uuidString])
    #expect(list.records.first?.title == "What is Quillberry?")
    let open = CompanionRequest(section: .chat, chatHistoryAction: .open, chatThreadID: thread)
    let page = try await broker.prepare(open, device: phone).page
    #expect(page.chatHistoryVersion == 1 && page.chatThreadID == thread)
    #expect(page.records.map(\.title).prefix(3) == ["You", "OpenCore", "[1] Fixture"])
    #expect(page.records.first?.body == "What is Quillberry?")
    #expect(page.records.contains { $0.objectID == fixture.publicObject.id.value })
    #expect(page.records.contains { $0.id == receiptID.value })
    for other in [fixturePhone(), fixturePhone(id: phone.id)] {
        #expect(try await broker.prepare(listRequest, device: other).page.records.isEmpty)
        await #expect(throws: CompanionError.self) { try await broker.prepare(open, device: other) }
    }
    let changedScope = CompanionRequest(section: .chat, domain: "project", chatHistoryAction: .list)
    #expect(try await broker.prepare(changedScope, device: phone).page.records.isEmpty)
}

@Test("saved history pages revalidate their sources before replay", arguments: ["list", "open"])
func phoneHistoryPagesRecheckDisclosure(kind: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), broker = CompanionBroker(store: fixture.store)
    let (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let request = kind == "list"
        ? CompanionRequest(section: .chat, chatHistoryAction: .list)
        : CompanionRequest(section: .chat, chatHistoryAction: .open, chatThreadID: thread)
    let prepared = try await broker.prepare(request, device: phone)
    #expect(!prepared.page.records.isEmpty)
    try await prepared.validateDisclosure()
    var restricted = fixture.publicObject
    restricted.domain = .medical
    _ = try await fixture.store.ingest([restricted])
    await #expect(throws: CompanionError.self) { try await prepared.validateDisclosure() }
}

@Test("saved phone history rejects malformed full models even when their source references are admissible",
      arguments: ["source", "verdict"])
func phoneHistoryBrokerRejectsMalformedModels(kind: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), broker = CompanionBroker(store: fixture.store)
    let source = GroundingSource(index: 1, title: "Fixture", text: fixture.publicObject.text,
        objectID: fixture.publicObject.id, authority: fixture.publicObject.authority)
    let data = try JSONEncoder().encode([source])
    var objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    objects[0].removeValue(forKey: "title")
    let malformedSource = String(decoding: try JSONSerialization.data(withJSONObject: objects), as: UTF8.self)
    let (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone,
        sourcesJSON: kind == "source" ? malformedSource : nil, verdictsJSON: kind == "verdict" ? "[{}]" : "[]")
    let page = try await broker.prepare(CompanionRequest(section: .chat, chatHistoryAction: .list), device: phone).page
    #expect(page.records.isEmpty)
    await #expect(throws: CompanionError.self) {
        try await broker.prepare(CompanionRequest(section: .chat, chatHistoryAction: .open, chatThreadID: thread), device: phone)
    }
}

@Test("saved phone history rejects ambiguous request shapes")
func phoneHistoryBrokerRejectsAmbiguousRequests() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let broker = CompanionBroker(store: fixture.store), phone = fixturePhone(), thread = UUID()
    let (existingThread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    let requests = [
        CompanionRequest(section: .home, chatHistoryAction: .list),
        CompanionRequest(section: .chat, query: "question", chatHistoryAction: .list),
        CompanionRequest(section: .chat, recordID: "irrelevant", chatHistoryAction: .list),
        CompanionRequest(section: .chat, asOf: Date(timeIntervalSince1970: 1), chatHistoryAction: .list),
        CompanionRequest(section: .chat, answerMode: .evidence, chatHistoryAction: .list),
        CompanionRequest(section: .chat, chatHistoryAction: .list, chatThreadID: thread),
        CompanionRequest(section: .chat, query: "new thread", answerMode: .evidence, chatThreadID: thread),
        CompanionRequest(section: .chat, chatThreadID: thread),
        CompanionRequest(section: .chat, query: "new thread", recordID: "irrelevant", chatThreadID: thread),
        CompanionRequest(section: .chat, query: "new thread", asOf: Date(timeIntervalSince1970: 1), chatThreadID: thread),
        CompanionRequest(section: .chat, query: "new thread", offset: 1, chatThreadID: thread),
        CompanionRequest(section: .chat, query: "new thread", resumeID: UUID(), chatThreadID: thread),
        CompanionRequest(section: .chat, offset: 1, chatHistoryAction: .open, chatThreadID: existingThread),
        CompanionRequest(section: .chat, chatHistoryAction: .open)
    ]
    for request in requests {
        await #expect(throws: CompanionError.self) { try await broker.prepare(request, device: phone) }
    }
}

@Test("a source reclassified after saving removes the phone history from list and open")
func phoneHistoryBrokerRechecksCurrentSourceDomain() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), broker = CompanionBroker(store: fixture.store)
    let (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
    var changed = fixture.publicObject
    changed.domain = .medical
    _ = try await fixture.store.ingest([changed])
    let object = try #require(try await fixture.store.object(changed.id))
    #expect(object.domain == .medical)
    let page = try await broker.prepare(CompanionRequest(section: .chat, chatHistoryAction: .list), device: phone).page
    #expect(page.records.isEmpty)
    await #expect(throws: CompanionError.self) {
        try await broker.prepare(CompanionRequest(section: .chat, chatHistoryAction: .open, chatThreadID: thread), device: phone)
    }
    await #expect(throws: (any Error).self) {
        try await broker.prepare(CompanionRequest(section: .chat, query: "A follow-up", chatThreadID: thread), device: phone)
    }
}

@Test("saved phone history retains pagination when some candidate models are malformed")
func phoneHistoryBrokerPaginatesPastMalformedModels() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone(), broker = CompanionBroker(store: fixture.store)
    var expected = Set<String>()
    for _ in 0..<41 {
        let (thread, _) = try await savePhoneHistoryFixture(fixture, phone: phone)
        expected.insert(thread.uuidString)
    }
    for _ in 0..<41 {
        _ = try await savePhoneHistoryFixture(fixture, phone: phone, verdictsJSON: "[{}]",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100))
    }
    var offset = 0, actual = Set<String>()
    var pageCounts: [Int] = []
    for _ in 0..<3 {
        let page = try await broker.prepare(CompanionRequest(section: .chat, offset: offset, chatHistoryAction: .list), device: phone).page
        pageCounts.append(page.records.count)
        actual.formUnion(page.records.map(\.id))
        guard let next = page.nextOffset else { break }
        #expect(next > offset)
        offset = next
    }
    #expect(actual == expected)
    #expect(pageCounts == [40, 1])
}

@Test("every owner read filters blocked objects and direct object and graph lookups fail closed")
func companionReadsRespectThePairedDeviceScope() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let broker = CompanionBroker(store: fixture.store)
    for section in CompanionSection.allCases where section != .chat {
        let result = try await broker.prepare(CompanionRequest(section: section), device: fixturePhone())
        let json = String(decoding: try JSONEncoder().encode(result.page), as: UTF8.self)
        #expect(!json.contains("MEDICAL_SENTINEL"), "\(section) leaked a blocked row")
    }
    for request in [CompanionRequest(section: .corpus, recordID: fixture.privateObject.id.value),
                    CompanionRequest(section: .graph, recordID: fixture.privateEntity.id.value),
                    CompanionRequest(section: .corpus, domain: "medical")] {
        await #expect(throws: (any Error).self) { try await broker.prepare(request, device: fixturePhone()) }
    }
}

// The subject check used to happen after LIMIT, creating an empty terminal page.
@Test("blocked subjects cannot consume a phone timeline page")
func companionTimelineAdmitsSubjectsBeforeItsLimit() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var events = (0..<50).map { index in
        CoreEvent(subject: fixture.privateEntity.id, verb: "fixture-\(index)", detail: "MEDICAL_SENTINEL",
            occurredAt: now.addingTimeInterval(-Double(index)), domain: .project, authority: .authoredArtifact)
    }
    events.append(CoreEvent(subject: fixture.project.id, verb: "fixture", detail: "ALLOWED_EVENT",
        occurredAt: now.addingTimeInterval(-100), domain: .project, authority: .authoredArtifact))
    try await fixture.store.save(events)
    let page = try await CompanionBroker(store: fixture.store).prepare(CompanionRequest(section: .timeline, asOf: now), device: fixturePhone()).page
    #expect(page.records.map(\.body) == ["ALLOWED_EVENT"])
}

@Test("the phone evidence answer uses the Mac Reasoner and records delivery only after acknowledgement")
func evidenceAnswerMatchesMacAndAcknowledgesDelivery() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_001)
    let query = "What is Quillberry's status?"
    let mac = try await Reasoner(store: fixture.store, now: now).answer(query, persistReceipt: false, maximumDomains: [.project,.publicRecord])
    let broker = CompanionBroker(store: fixture.store, now: { now })
    let prepared = try await broker.prepare(CompanionRequest(section: .chat, query: query, answerMode: .evidence), device: fixturePhone())
    #expect(prepared.page.records.first?.body == mac.summary)
    #expect(try await fixture.store.receipts().isEmpty)
    let page = try await prepared.acknowledge()
    let receiptID = try #require(page.receiptID)
    let receipt = try #require(try await fixture.store.receipt(code: receiptID))
    #expect(receipt.confidence == nil)
    #expect(receipt.claimsConsulted == mac.receipt.claimsConsulted)
    #expect(receipt.domainsAdmitted == mac.receipt.domainsAdmitted)
    #expect(receipt.objectsTransmitted == 1)
    #expect(receipt.stages.last?.name == "companion.delivery")
    #expect(try await !fixture.store.trace(receipt: receipt.id).isEmpty)
}

// Passage-only phone chat had no stored turn and therefore lost its entire trace.
@Test("passage delivery preserves exact citations and retrieval scores atomically with its receipt")
func phonePassageReceiptsKeepTheirTrace() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let passage = Evidence(objectID: fixture.publicObject.id, range: 0..<fixture.publicObject.text.count,
        snippet: fixture.publicObject.text, authority: .authoredArtifact, reading: "fixture-passage")
    var turn = Turn(role: .core, text: "A fixture answer [1].", sources: [GroundingSource(index: 1, title: "Fixture", text: passage.snippet,
        objectID: passage.objectID, authority: passage.authority)], receipt: Receipt(query: "fixture", queryClass: .factual,
            domainsAdmitted: [.project,.publicRecord], domainsBlocked: [.medical], stages: [], objectsSearched: 1, objectsRetrieved: 1,
            evidenceAdmitted: 1, claimsConsulted: 0, contradictionsSurfaced: 0, model: "Fixture", objectsTransmitted: 0, confidence: nil))
    turn.receiptPassages = [(passage,0.75)]
    let failures = PhoneDeliveryFailureRecorder()
    let broker = CompanionBroker(store: fixture.store, onDeliveryFailure: { await failures.record($0) })
    let prepared = try await broker.prepareChatDelivery(turn, device: fixturePhone(), domains: [.project,.publicRecord])
    #expect(try await fixture.store.evidence(id: passage.id) == nil)
    #expect(try await fixture.store.receipts().isEmpty)
    let page = try await prepared.acknowledge()
    let receiptID = try #require(page.receiptID)
    let receipt = try #require(try await fixture.store.receipt(code: receiptID))
    let trace = try await fixture.store.trace(receipt: receipt.id)
    #expect(trace.count == 1)
    #expect(trace.first?.0.snippet == passage.snippet)
    #expect(trace.first?.2 == 0.75)
    #expect(receipt.objectsTransmitted == 1)
    #expect(await failures.messages.isEmpty)
}

// Re-pairing a device UUID with fewer domains previously reused the wider conversation.
@Test("re-pairing the same phone with fewer domains discards the previous chat ceiling")
func narrowerPairingCannotReuseAWiderConversation() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let broker = CompanionBroker(store: fixture.store)
    let id = UUID(), instant = Date(timeIntervalSince1970: 1_800_000_000)
    // No passage contains these terms, so Conversation returns without invoking any model.
    let request = CompanionRequest(section: .chat, query: "diagnosis zymqvpx")
    let wide = try await broker.prepare(request, device: fixturePhone(domains: Set(Domain.allCases.map(\.rawValue)), id: id, pairedAt: instant))
    _ = try await wide.acknowledge()
    let narrow = try await broker.prepare(request, device: fixturePhone(id: id, pairedAt: instant.addingTimeInterval(1)))
    let page = try await narrow.acknowledge()
    let receiptID = try #require(page.receiptID)
    let receipt = try #require(try await fixture.store.receipt(code: receiptID))
    #expect(!receipt.domainsAdmitted.contains(.medical))
    #expect(receipt.domainsBlocked.contains(.medical))
}

@Test("a read-only store refuses writes and performs no migration")
func companionCopyInspectionCannotMutateItsStore() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let readOnly = try await Store.openReadOnly(at: fixture.directory.appendingPathComponent("store.sqlite3"))
    #expect(try await readOnly.objectCount() == 2)
    await #expect(throws: (any Error).self) { try await readOnly.upsert(Source(kind: .manual, handle: "blocked", displayName: "Blocked", defaultAuthority: .authoredArtifact, defaultDomain: .project)) }
}

// Retrieved domains labelled the evidence, not the raw question and arbitrary stage notes.
@Test("a limited phone cannot browse another caller's unlabelled receipt text")
func companionReceiptsDoNotLeakUnlabelledQueries() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = Receipt(query: "MEDICAL_SENTINEL", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [.medical],
        stages: [], objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await fixture.store.save(receipt)
    let broker = CompanionBroker(store: fixture.store)
    let page = try await broker.prepare(CompanionRequest(section: .receipts), device: fixturePhone()).page
    #expect(page.records.isEmpty)
    await #expect(throws: (any Error).self) {
        try await broker.prepare(CompanionRequest(section: .receipts, recordID: receipt.id.value), device: fixturePhone())
    }
    let owner = fixturePhone(domains: Set(Domain.allCases.map(\.rawValue)))
    let full = try await broker.prepare(CompanionRequest(section: .receipts, recordID: receipt.id.value), device: owner).page
    #expect(full.records.first?.body == receipt.query)
}

// A revoked grant must not regain its old raw questions by reusing the same device UUID.
@Test("re-pairing a phone does not restore receipts from its former authorization")
func companionReceiptsAreBoundToThePairingGrant() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = fixturePhone(domains: Set(Domain.allCases.map(\.rawValue)))
    let broker = CompanionBroker(store: fixture.store)
    let prepared = try await broker.prepare(CompanionRequest(section: .chat, query: "Quillberry", answerMode: .evidence), device: original)
    let delivered = try await prepared.acknowledge()
    let receiptID = try #require(delivered.receiptID)
    let repaired = CompanionDevice(id: original.id, name: original.name, signingKey: original.signingKey,
        domains: ["project","public"], pairedAt: original.pairedAt)
    await #expect(throws: (any Error).self) {
        try await broker.prepare(CompanionRequest(section: .receipts, recordID: receiptID), device: repaired)
    }
    let matching = CompanionDevice(id: original.id, name: original.name, signingKey: original.signingKey,
        domains: ["project","public"], pairedAt: original.pairedAt, grantID: original.grantID)
    let visible = try await broker.prepare(CompanionRequest(section: .receipts, recordID: receiptID), device: matching).page
    #expect(!visible.records.isEmpty)
}

// Unknown stored receipt domains used to be dropped while decoding, so a limited phone could
// read a receipt whose future or malformed scope had silently become project-only.
@Test("an unknown stored receipt domain remains restricted for a limited phone",
      arguments: ["project,future_fixture", "project,,public", "project, ", "project\u{0},future_fixture"])
func companionUnknownReceiptDomainFailsClosed(rawDomain: String) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixturePhone()
    let receipt = Receipt(query: "UNKNOWN_SCOPE_SENTINEL", queryClass: .factual,
        domainsAdmitted: [.project], domainsBlocked: [.medical],
        stages: CompanionBroker.requestAuditContext(for: phone),
        objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await fixture.store.save(receipt)
    // This corruption fixture is a fresh synthetic database, never the owner's store.
    try await fixture.store.database.execute(
        "UPDATE receipt SET domains_admitted = CAST(? AS TEXT), domains_blocked = ? WHERE id = ?",
        [.blob(Data(rawDomain.utf8)), .text("medical,future_fixture"), .text(receipt.id.value)]
    )
    let decoded = try #require(try await fixture.store.receipt(code: receipt.id.value))
    #expect(decoded.domainsAdmitted.contains(.restricted))
    #expect(decoded.domainsBlocked.contains(.restricted))
    let broker = CompanionBroker(store: fixture.store)
    let list = try await broker.prepare(CompanionRequest(section: .receipts), device: phone).page
    #expect(!list.records.contains { $0.id == receipt.id.value })
    await #expect(throws: (any Error).self) {
        try await broker.prepare(CompanionRequest(section: .receipts, recordID: receipt.id.value), device: phone)
    }
}

@Test("an empty stored receipt domain list stays empty")
func companionEmptyReceiptDomainsStayEmpty() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = Receipt(query: "fixture", queryClass: .factual, domainsAdmitted: [], domainsBlocked: [],
        stages: [], objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await fixture.store.save(receipt)
    let decoded = try #require(try await fixture.store.receipt(code: receipt.id.value))
    #expect(decoded.domainsAdmitted.isEmpty)
    #expect(decoded.domainsBlocked.isEmpty)
}

// Deterministic evidence answers once recorded only claim provenance and lost passage hits.
@Test("a passage-only evidence answer retains every passage and exact score in its trace")
func companionEvidencePassagesKeepTheirTrace() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let query = "PROJECT_SENTINEL"
    let now = Date(timeIntervalSince1970: 1_800_000_001)
    let expected = try await Reasoner(store: fixture.store, now: now).answer(query, persistReceipt: false, maximumDomains: [.project,.publicRecord])
    #expect(!expected.passages.isEmpty)
    let failures = PhoneDeliveryFailureRecorder()
    let prepared = try await CompanionBroker(store: fixture.store, now: { now }, onDeliveryFailure: { await failures.record($0) }).prepare(
        CompanionRequest(section: .chat, query: query, answerMode: .evidence), device: fixturePhone())
    #expect(try await fixture.store.receipts().isEmpty)
    let page = try await prepared.acknowledge()
    let receiptID = try #require(page.receiptID)
    let receipt = try #require(try await fixture.store.receipt(code: receiptID))
    let trace = try await fixture.store.trace(receipt: receipt.id)
    for hit in expected.passages {
        #expect(trace.contains { $0.0.snippet == hit.chunk.text && $0.1.id == hit.object.id && $0.2 == hit.score })
    }
    #expect(await failures.messages.isEmpty)
}

// A selected phone scope only narrowed the ceiling; the engine still classified a neutral
// question as project and returned an empty admission set for sensitive/personal selections.
@Test("both phone answer modes honor explicit owner scope without exceeding a pairing grant")
func companionAnswerSelectionHonorsItsGrant() async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let broker = CompanionBroker(store: fixture.store)
    let phone = fixturePhone(domains: ["medical", "public"])
    for mode in CompanionAnswerMode.allCases {
        let request = CompanionRequest(section: .chat, query: "zymqvpx no matching fixture", domain: "medical", answerMode: mode)
        let prepared = try await broker.prepare(request, device: phone)
        let page = try await prepared.acknowledge()
        let id = try #require(page.receiptID)
        let receipt = try #require(try await fixture.store.receipt(code: id))
        #expect(receipt.domainsAdmitted == [.medical])
        #expect(receipt.domainsBlocked.contains(.personal))
        await #expect(throws: (any Error).self) {
            try await broker.prepare(request, device: fixturePhone())
        }
    }
}

// The owner's calendar is objects with no claims, so the phone's two answer paths have to carry it
// themselves, and a project-limited grant has to get nothing from it.
@Test("the phone reads the owner's calendar in both answer modes, and a limited grant does not", arguments: [
    (CompanionAnswerMode.chat, true), (CompanionAnswerMode.evidence, true), (CompanionAnswerMode.chat, false), (CompanionAnswerMode.evidence, false),
])
func phoneReadsCalendarWithinItsGrant(mode: CompanionAnswerMode, fullAccess: Bool) async throws {
    let fixture = try await brokerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let calendar = Source(kind: .calendar, handle: "calendar", displayName: "Apple Calendar",
                          defaultAuthority: .authoredArtifact, defaultDomain: .personal)
    try await fixture.store.upsert(calendar)
    try await fixture.store.markSynced(calendar.id, at: Date(), cursor: nil)
    _ = try await fixture.store.ingest([CoreObject(
        sourceID: calendar.id, kind: .calendarEvent, externalID: "event:CALENDAR_SENTINEL", title: "CALENDAR_SENTINEL",
        text: "CALENDAR_SENTINEL", authoredAt: Date().addingTimeInterval(3600), domain: .personal, authority: .authoredArtifact,
        metadata: ["calendar": "Home", "all_day": "false"]
    )])
    let device = fixturePhone(domains: fullAccess ? ["project", "public", "personal"] : ["project", "public"])
    let page = try await CompanionBroker(store: fixture.store).prepare(
        CompanionRequest(section: .chat, query: "What's on my calendar in the next 2 days?", answerMode: mode), device: device).page
    let text = ([page.title, page.note] + page.records.map { "\($0.title) \($0.body)" }).joined(separator: " ")
    #expect(text.contains("CALENDAR_SENTINEL") == fullAccess)
}
