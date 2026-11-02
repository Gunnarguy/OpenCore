import CoreModel
import CoreStore
import Foundation
import Testing
@testable import CoreReason

private let cloudSources = [
    GroundingSource(index: 1, title: "First", text: "Fixture source and its counter-record.", objectID: ObjectID("floor-a"),
                    authority: .authoredArtifact, representedObjectIDs: [ObjectID("floor-a"), ObjectID("floor-b")]),
    GroundingSource(index: 2, title: "Second passage", text: "Another passage from the same floor record.",
                    objectID: ObjectID("floor-a"), authority: .authoredArtifact),
    GroundingSource(index: 3, title: "Third passage", text: "A third passage from that floor record.",
                    objectID: ObjectID("floor-a"), authority: .authoredArtifact),
]

private func fixtureCloudRequest() throws -> URLRequest {
    try #require(GeminiRequest.make(apiKey: "fixture-token", body: Data(Conversation.prompt(question: "Fixture question", sources: cloudSources).utf8)))
}

private func cloudResponse(_ request: URLRequest, status: Int = 200) -> URLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func cloudEnvelope(_ text: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])
}

private func cloudReceipt(_ attempt: GeminiGenerationAttempt) -> Receipt {
    Receipt(query: "Fixture question", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: [attempt.stage], objectsSearched: 3, objectsRetrieved: 3, evidenceAdmitted: 0,
        claimsConsulted: 0, contradictionsSurfaced: 0, model: nil,
        objectsTransmitted: attempt.confirmedObjectCount, confidence: nil)
}

// sources.count counted duplicates and ignored extra floor objects quoted by a claim source.
@Test("cloud receipts count distinct represented floor objects rather than source entries")
func cloudCountsRepresentedObjectsOnce() async throws {
    let request = try fixtureCloudRequest()
    let data = try cloudEnvelope(#"{"insufficient":true,"sentences":[]}"#)
    let attempt = await GeminiGenerationAttempt.perform(request, sources: cloudSources) { request in
        (data, cloudResponse(request))
    }
    #expect(attempt.objects == [ObjectID("floor-a"), ObjectID("floor-b")])
    #expect(attempt.stage.counters["objects_submitted"] == 2)
    #expect(attempt.applicationAcknowledged)
    #expect(attempt.answer?.insufficient == true)
    #expect(attempt.confirmedObjectCount == 2)
    #expect(!cloudReceipt(attempt).hasUnconfirmedCloudDelivery)
    // Multiple source entries for one floor object remain one transmitted object.
    #expect(GroundingSource.floorObjects(in: Array(repeating: cloudSources[1], count: 3)).count == 1)
}

// A thrown/cancelled request used to disappear before deterministic fallback wrote a zero badge.
@Test("failed or cancelled submitted cloud requests remain explicitly unconfirmed")
func failedCloudSubmissionDoesNotBecomeZeroEgress() async throws {
    let request = try fixtureCloudRequest()
    struct FixtureFailure: Error {}
    for cancelled in [false, true] {
        let attempt = await GeminiGenerationAttempt.perform(request, sources: cloudSources) { _ in
            if cancelled { throw CancellationError() }
            throw FixtureFailure()
        }
        let receipt = cloudReceipt(attempt)
        #expect(attempt.submitted)
        #expect(attempt.answer == nil)
        #expect(attempt.stage.counters["http_status"] == nil)
        #expect(receipt.objectsTransmitted == 0, "an unconfirmed delivery cannot be invented as measured")
        #expect(receipt.hasOutboundActivity)
        #expect(receipt.hasUnconfirmedCloudDelivery)
        #expect(receipt.outboundStatusLabel == "CLOUD DELIVERY UNCONFIRMED")
        #expect(receipt.outboundDescription.contains("Cloud submission: 2 source objects; delivery unconfirmed."))
        #expect(receipt.confidence == nil)
    }
}

// HTTP contact, a provider acknowledgment, and answer decoding are three different observations.
@Test("cloud HTTP and decoding failures retain distinct receipt outcomes")
func cloudResponseFailuresRetainTheirStage() async throws {
    let request = try fixtureCloudRequest()
    for (status, data, acknowledged) in [
        (503, Data("unavailable".utf8), false),
        (200, Data("not JSON".utf8), false),
        (200, try cloudEnvelope("not a structured answer"), true),
        (200, Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8), true),
    ] {
        let attempt = await GeminiGenerationAttempt.perform(request, sources: cloudSources) { request in
            (data, cloudResponse(request, status: status))
        }
        #expect(attempt.submitted)
        #expect(attempt.httpStatus == status)
        #expect(attempt.applicationAcknowledged == acknowledged)
        #expect(attempt.answer == nil)
        #expect(attempt.stage.counters["answer_decoded"] == 0)
        #expect(cloudReceipt(attempt).hasUnconfirmedCloudDelivery == !acknowledged)
        #expect(cloudReceipt(attempt).hasOutboundActivity)
    }
}

@Test("cancellation before dispatch records no submitted request")
func preCancelledCloudAttemptDoesNotInvokeTransport() async throws {
    let request = try fixtureCloudRequest()
    let optional = await withTaskGroup(of: GeminiGenerationAttempt.self) { group in
        group.cancelAll()
        group.addTask {
            await GeminiGenerationAttempt.perform(request, sources: cloudSources) { _ in
                Issue.record("A cancelled request reached transport")
                throw CancellationError()
            }
        }
        return await group.next()
    }
    let attempt = try #require(optional)
    #expect(!attempt.submitted)
    #expect(attempt.stage.counters["request_submitted"] == 0)
    #expect(!cloudReceipt(attempt).hasOutboundActivity)
    #expect(cloudReceipt(attempt).outboundDescription == "Cloud request not submitted.")
}

// Phone history is deliberately disabled. Cloud activity must nevertheless survive no ACK,
// cancellation and fallback, with exact source provenance in a separate request audit.
@Test("submitted cloud requests persist independently of chat history and phone acknowledgment")
func cloudRequestAuditDoesNotWaitForPhoneAcknowledgment() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-independent-audit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .document, externalID: "fixture", title: "Fixture", text: "Fixture recorded passage.", domain: .project, authority: .authoredArtifact)
    try await store.ingest([object])
    let sources = [GroundingSource(index: 1, title: object.title, text: object.text, objectID: object.id, authority: object.authority)]
    let evidence = Evidence(objectID: object.id, range: 0..<object.text.count, snippet: object.text, authority: object.authority, reading: "fixture audit")
    let reading = Conversation.ClaimReading(passages: [(evidence, 0.01)])
    let conversation = Conversation(store: store, persistHistory: false)
    let request = try fixtureCloudRequest()
    let response = try cloudEnvelope(#"{"insufficient":true,"sentences":[]}"#)
    for succeeds in [false, true] {
        let attempt = await GeminiGenerationAttempt.perform(request, sources: sources) { request in
            if !succeeds { throw CancellationError() }
            return (response, cloudResponse(request))
        }
        // The audit must still be written when the requesting task was cancelled.
        let audit = await withTaskGroup(of: Conversation.CloudAuditResult.self) { group in
            group.cancelAll()
            group.addTask {
                await conversation.auditCloudAttempt(attempt, question: "Fixture question", queryClass: .factual,
                    policy: .init(queryDomain: .project), reading: reading, objectsSearched: 1, sources: sources)
            }
            return await group.next()
        }
        #expect(audit?.stage.counters["audit_saved"] == 1)
        #expect(audit?.persistenceError == nil)
    }
    let audits = try await store.receipts()
    #expect(audits.count == 2)
    for audit in audits {
        #expect(audit.isRequestAudit)
        #expect(!audit.stages.contains { $0.name == "companion.delivery" })
        #expect(audit.model == nil)
        #expect(audit.confidence == nil)
        let traced = try await store.trace(receipt: audit.id)
        #expect(traced.count == 1)
        #expect(traced.first?.0.snippet == object.text)
        #expect(traced.first?.2 == 0.01)
    }
    #expect(audits.contains { $0.hasUnconfirmedCloudDelivery })
    #expect(audits.contains { $0.objectsTransmitted == 1 })
}

private actor CloudAuditFailures {
    var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

@Test("failure to persist an independent cloud audit is reported rather than swallowed")
func cloudAuditPersistenceFailureRemainsVisible() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-audit-readonly-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("store.sqlite3")
    _ = try await Store.open(at: path)
    let readonly = try await Store.openReadOnly(at: path)
    let attempt = await GeminiGenerationAttempt.perform(try fixtureCloudRequest(), sources: cloudSources) { _ in throw CancellationError() }
    let failures = CloudAuditFailures()
    let conversation = Conversation(store: readonly, persistHistory: false, onAuditFailure: { await failures.record($0) })
    let result = await conversation.auditCloudAttempt(attempt,
        question: "fixture", queryClass: .factual, policy: .init(queryDomain: .project), reading: .none,
        objectsSearched: 0, sources: cloudSources)
    #expect(result.stage.counters["audit_saved"] == 0)
    #expect(result.persistenceError != nil)
    #expect(await failures.messages.count == 1, "the failure sink must be notified without a phone stream or ACK")
    #expect(try await readonly.receipts().isEmpty)
}

// Native streaming may have filled the draft before failing. Empty extraction must not leave
// that unverified prose displayed under a nil final author.
@Test("empty deterministic fallback discards a prior partial model draft")
func emptyDeterministicFallbackDiscardsPartialModelDraft() {
    let source = GroundingSource(index: 1, title: "Headings", text: "# Fixture\ntiny\n|---", objectID: ObjectID("fixture-headings"), authority: .authoredArtifact)
    var turn = Turn(role: .core, text: "PRIVATE_PARTIAL_DRAFT", sources: [source], modelName: "Failed fixture writer")
    turn.verdicts = [Grounding.Verdict(sentence: "PRIVATE_PARTIAL_DRAFT", citedSource: nil, citationResolves: false, score: 0, unsupported: ["draft"])]
    var stages: [ReceiptStage] = []
    var author: String? = "Failed fixture writer"
    Conversation.applyDeterministicFallback(reason: "Fixture model unavailable", generationStarted: DispatchTime.now().uptimeNanoseconds,
        turn: &turn, stages: &stages, modelName: &author)
    #expect(turn.text.isEmpty)
    #expect(turn.verdicts.isEmpty)
    #expect(author == nil)
    #expect(turn.modelName == nil)
    #expect(!stages.contains { $0.name == "synthesize_deterministic" })
}

// A deterministic answer after a failed model is a deliverable answer with a warning; neither
// its author's identity nor the previous cloud attempt may be misrepresented.
@Test("deterministic fallback preserves request accounting and has no model prose author")
func deterministicFallbackRetainsCloudWarningAndCanBeDelivered() async throws {
    let attempt = await GeminiGenerationAttempt.perform(try fixtureCloudRequest(), sources: cloudSources) { _ in throw CancellationError() }
    var turn = Turn(role: .core, sources: cloudSources, modelName: "Failed fixture writer")
    var stages = [attempt.stage]
    var author: String? = "Failed fixture writer"
    Conversation.applyDeterministicFallback(reason: "Fixture model unavailable", generationStarted: DispatchTime.now().uptimeNanoseconds,
        turn: &turn, stages: &stages, modelName: &author)
    #expect(author == nil)
    #expect(turn.modelName == nil)
    #expect(!turn.text.isEmpty)
    var receipt = cloudReceipt(attempt)
    receipt.stages = stages
    turn.receipt = receipt
    #expect(turn.hasDeliverableAnswer)
    #expect(receipt.hasUnconfirmedCloudDelivery)
    #expect(turn.error == "Fixture model unavailable")
    receipt.stages.removeAll { $0.name == "synthesize_deterministic" }
    turn.receipt = receipt
    #expect(!turn.hasDeliverableAnswer, "an arbitrary failed/partial draft is not a completed fallback")
}

// A later deterministic/phone result must not erase earlier unresolved cloud disclosure.
@Test("cloud uncertainty survives receipt persistence and a subsequent acknowledged phone delivery")
func cloudDisclosureSurvivesStorageAndPhoneAcknowledgment() async throws {
    let request = try fixtureCloudRequest()
    let attempt = await GeminiGenerationAttempt.perform(request, sources: cloudSources) { _ in throw CancellationError() }
    var receipt = cloudReceipt(attempt)
    receipt.stages.append(ReceiptStage(name: "synthesize_deterministic", milliseconds: 0))
    receipt.stages.append(ReceiptStage(name: "companion.delivery", counters: ["phone_objects": 2], milliseconds: 0))
    receipt.objectsTransmitted = 2
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-cloud-receipt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
    try await store.save(receipt)
    let restored = try #require(try await store.receipt(code: receipt.shortCode))
    #expect(restored.hasUnconfirmedCloudDelivery)
    #expect(restored.outboundDescription.contains("delivery unconfirmed"))
    #expect(restored.outboundDescription.contains("Phone delivery acknowledged: 2 source objects."))
    #expect(restored.outboundDescription == receipt.outboundDescription)
    #expect(restored.confidence == nil)
    var emptyPhone = receipt
    emptyPhone.objectsTransmitted = 0
    emptyPhone.stages = [ReceiptStage(name: "companion.delivery", counters: ["phone_objects": 0], milliseconds: 0)]
    #expect(emptyPhone.hasOutboundActivity, "question/answer bytes are not counted as floor objects")
    emptyPhone.stages = []
    #expect(emptyPhone.outboundDescription.contains("Attempt details unavailable"))
    #expect(!emptyPhone.outboundStatusLabel.contains("PROVEN"))
}
