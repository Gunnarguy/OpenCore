import CoreModel
import CoreStore
import Dispatch
import Foundation
import Testing
@testable import CoreReason

private struct RestoreFixture {
    let directory: URL
    let store: Store
    let scope: CompanionHistoryScope
    let thread: UUID
    let questionID: UUID
    let answerID: UUID
    let question: String
    let answer: String
    let source: GroundingSource
    let receipt: Receipt

    static func make(malformed: String? = nil) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-phone-restore-\(UUID().uuidString)")
        let store = try await Store.open(at: directory.appendingPathComponent("fixture.sqlite3"))
        let scope = CompanionHistoryScope(deviceID: UUID(), grantID: UUID(), domains: [.project, .publicRecord], selectedDomain: nil)
        let thread = UUID(), questionID = UUID(), answerID = UUID()
        let question = "What is the fixture?", answer = "The fixture is written in Swift."
        let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
        try await store.upsert(source)
        let object = CoreObject(sourceID: source.id, kind: .document, externalID: "fixture", title: "Fixture",
            text: answer, domain: .project, authority: .authoredArtifact)
        try await store.ingest([object])
        let grounding = GroundingSource(index: 1, title: "Fixture", text: answer, objectID: object.id, authority: .authoredArtifact)
        let receipt = Receipt(query: question, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [.medical],
            stages: [ReceiptStage(name: "companion.delivery", milliseconds: 0,
                note: "Acknowledged by paired device \(scope.deviceID.uuidString) (Fixture phone). Grant \(scope.grantID.uuidString).")],
            objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0, claimsConsulted: 0,
            contradictionsSurfaced: 0, model: "Fixture model", objectsTransmitted: 1, confidence: nil,
            id: Store.companionReceiptID(for: questionID))
        let encodedSources: String
        if malformed == "source" {
            encodedSources = "[{\"objectID\":\"\(object.id.value)\"}]"
        } else {
            encodedSources = String(decoding: try JSONEncoder().encode([grounding]), as: UTF8.self)
        }
        let verdict = Grounding().verify(sentence: answer, citedSource: 1, sources: [grounding])
        let verdicts = malformed == "verdict" ? "not-json" : String(decoding: try JSONEncoder().encode([verdict]), as: UTF8.self)
        let turn = StoredTurn(id: answerID.uuidString, conversationID: scope.conversationID(for: thread), ordinal: 0,
            role: "core", text: answer, sourcesJSON: encodedSources, verdictsJSON: verdicts, receiptID: receipt.id, model: "Fixture model")
        _ = try await store.saveCompanionExchange(scope: scope, thread: thread, request: questionID,
            requestDigest: String(repeating: "a", count: 64), question: question, answer: turn, receipt: receipt, expectedRevision: .empty)
        return Self(directory: directory, store: store, scope: scope, thread: thread, questionID: questionID,
            answerID: answerID, question: question, answer: answer, source: grounding, receipt: receipt)
    }

    func conversation(id: String? = nil, domains: Set<Domain>? = nil, persistHistory: Bool = false) -> Conversation {
        Conversation(store: store, id: id ?? scope.conversationID(for: thread), persistHistory: persistHistory,
                     maximumDomains: domains ?? scope.domains)
    }
}

@Test("phone restore uses the validated snapshot, preserving turns, sources, receipt and replay context")
func companionRestoreKeepsValidatedContext() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let conversation = fixture.conversation()
    let turns = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread)
    try #require(turns.count == 2)
    #expect(turns.map(\.role) == [.you, .core])
    #expect(turns.map(\.id) == [fixture.questionID, fixture.answerID])
    #expect(turns.map(\.text) == [fixture.question, fixture.answer])
    #expect(turns[1].sources == [fixture.source])
    #expect(turns[1].receipt?.id == fixture.receipt.id)
    #expect(turns[1].verdicts.count == 1)
    let replay = Conversation.replayedExchanges(turns)
    #expect(replay.count == 1 && replay.first?.question == fixture.question && replay.first?.answer == fixture.answer)
    let followUp = "What is it built with?"
    #expect(await conversation.contextualizedQueryForNextQuestion(followUp) != followUp)
}

@Test("phone restore returns the revision of its replayed turns for a later save")
func companionRestoreKeepsReplayedRevision() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let conversation = fixture.conversation()
    let restored = try await conversation.restoreCompanionHistoryWithRevision(scope: fixture.scope, thread: fixture.thread)
    let initial = try #require(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread))
    #expect(restored.turns.map(\.id) == [fixture.questionID, fixture.answerID])
    #expect(restored.revision == initial.revision)

    func saveFollowUp(_ question: String, expected: CompanionHistoryRevision) async throws {
        let request = UUID()
        var receipt = fixture.receipt
        receipt.id = Store.companionReceiptID(for: request)
        receipt.query = question
        let answer = StoredTurn(conversationID: fixture.scope.conversationID(for: fixture.thread), ordinal: 0,
            role: "core", text: "Another fixture answer.", receiptID: receipt.id)
        _ = try await fixture.store.saveCompanionExchange(scope: fixture.scope, thread: fixture.thread, request: request,
            requestDigest: String(repeating: "c", count: 64), question: question, answer: answer, receipt: receipt,
            expectedRevision: expected)
    }

    try await saveFollowUp("A concurrent question", expected: restored.revision)
    let updated = try #require(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread))
    #expect(updated.revision != restored.revision)
    do {
        try await saveFollowUp("A delayed question", expected: restored.revision)
        Issue.record("a reply based on the older replayed context was saved")
    } catch CompanionHistoryError.staleConversation { }
    catch { Issue.record("expected stale conversation, got \(error)") }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread)?.exchanges.count == 2)
}

@Test("phone restore rejects a different thread, domain ceiling, or persistent Mac conversation",
      arguments: ["thread", "domains", "persistent"])
func companionRestoreRejectsWrongActorScope(kind: String) async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let conversation = fixture.conversation(id: kind == "thread" ? UUID().uuidString : nil,
        domains: kind == "domains" ? [.project] : nil, persistHistory: kind == "persistent")
    do { _ = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread); Issue.record("wrong actor scope restored") }
    catch CompanionConversationRestoreError.scopeMismatch { }
    catch { Issue.record("expected scope mismatch, got \(error)") }
}

@Test("phone restore refuses incomplete source or verdict models", arguments: ["source", "verdict"])
func companionRestoreRejectsMalformedModels(kind: String) async throws {
    let fixture = try await RestoreFixture.make(malformed: kind)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    // The store's narrower source-identity decoder admits the reference, while this boundary
    // requires the complete CoreReason source/verdict model before any turn is returned.
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil)
    do { _ = try await fixture.conversation().restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread); Issue.record("malformed history restored") }
    catch CompanionConversationRestoreError.malformedHistory { }
    catch { Issue.record("expected malformed history, got \(error)") }
}

@Test("phone restore fetches a fresh authorized snapshot instead of reopening later Mac turns")
func companionRestoreRejectsLaterUnlabelledTurns() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil)
    try await fixture.store.append(StoredTurn(conversationID: fixture.scope.conversationID(for: fixture.thread), ordinal: 2,
        role: "you", text: "PRIVATE_MAC_FIXTURE"))
    do { _ = try await fixture.conversation().restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread); Issue.record("unlabelled turn restored") }
    catch CompanionConversationRestoreError.unavailable { }
    catch { Issue.record("expected unavailable history, got \(error)") }
}

@Test("a cancelled phone restore returns no turns and releases its conversation")
func companionRestoreHonorsCancellation() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let conversation = fixture.conversation()
    let (gate, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        for await _ in gate { }
        return try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread)
    }
    task.cancel(); continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread).count == 2)
}

@Test("a failed phone re-restore discards previously admitted follow-up context")
func companionRestoreDropsContextAfterAdmissionChanges() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let conversation = fixture.conversation()
    _ = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread)
    let followUp = "What is it built with?"
    #expect(await conversation.contextualizedQueryForNextQuestion(followUp) != followUp)
    try await fixture.store.database.execute("UPDATE object SET domain = ? WHERE id = ?", [.text("medical"), .text(fixture.source.objectID.value)])
    do { _ = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread); Issue.record("blocked source restored") }
    catch CompanionConversationRestoreError.unavailable { }
    catch { Issue.record("expected unavailable history, got \(error)") }
    #expect(await conversation.contextualizedQueryForNextQuestion(followUp) == followUp)
}

@Test("a scoped phone conversation cannot use the unfiltered Mac restore")
func companionRestoreCannotUseUnfilteredMacRestore() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let phone = fixture.conversation()
    do { _ = try await phone.restore(); Issue.record("scoped actor used unfiltered restore") }
    catch CompanionConversationRestoreError.scopeMismatch { }
    catch { Issue.record("expected scope mismatch, got \(error)") }
    let mac = Conversation(store: fixture.store, id: fixture.scope.conversationID(for: fixture.thread))
    #expect(try await mac.restore().count == 2)
}

@Test("mixed admission scopes remain visible but are not restored into follow-up context")
func companionRestoreDoesNotReplayMixedScopes() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let request = UUID(), question = "What is public?"
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: request); receipt.query = question; receipt.domainsAdmitted = [.publicRecord]
    let answer = StoredTurn(conversationID: fixture.scope.conversationID(for: fixture.thread), ordinal: 0,
        role: "core", text: "Public fixture.", receiptID: receipt.id, model: "Fixture model")
    let prior = try #require(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread))
    _ = try await fixture.store.saveCompanionExchange(scope: fixture.scope, thread: fixture.thread, request: request,
        requestDigest: String(repeating: "b", count: 64), question: question, answer: answer, receipt: receipt, expectedRevision: prior.revision)
    let conversation = fixture.conversation()
    let turns = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread)
    #expect(turns.count == 4)
    let followUp = "What is it built with?"
    #expect(await conversation.contextualizedQueryForNextQuestion(followUp) == followUp)
}

private enum RestoreBusyFixtureError: Error { case timedOut }

@Test("an active phone restore refuses overlapping restores and sends")
func companionRestoreRejectsConcurrentWork() async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let holdStore = Task {
        try await fixture.store.database.read { connection in
            _ = try connection.query("SELECT 1")
            ready.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw RestoreBusyFixtureError.timedOut }
        }
    }
    let held = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: ready.wait(timeout: .now() + 5) == .success) }
    }
    #expect(held)
    guard held else { release.signal(); _ = try? await holdStore.value; return }
    let conversation = fixture.conversation()
    let restoring = Task { try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread) }
    // Observe the actual busy response; the timer is only a watchdog for a broken fixture.
    let busy = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !Task.isCancelled {
                do { _ = try await conversation.restore() }
                catch CompanionConversationRestoreError.busy { return true }
                catch CompanionConversationRestoreError.scopeMismatch { await Task.yield(); continue }
                catch { return false }
            }
            return false
        }
        group.addTask { do { try await Task.sleep(for: .seconds(3)) } catch { }; return false }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
    #expect(busy)
    if busy {
        let overlapping = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread); return "accepted" }
                catch CompanionConversationRestoreError.busy { return "busy" }
                catch { return "other error" }
            }
            group.addTask { do { try await Task.sleep(for: .seconds(3)) } catch { return "cancelled" }; release.signal(); return "timed out" }
            let result = await group.next() ?? "missing"
            group.cancelAll(); return result
        }
        #expect(overlapping == "busy")
        if overlapping == "busy" {
            let sendResult = await withTaskGroup(of: String.self) { group in
                group.addTask {
                    var iterator = conversation.send("zxqv fixture not found").makeAsyncIterator()
                    return await iterator.next()?.error ?? "not busy"
                }
                group.addTask { do { try await Task.sleep(for: .seconds(3)) } catch { return "cancelled" }; release.signal(); return "timed out" }
                let result = await group.next() ?? "missing"
                group.cancelAll(); return result
            }
            #expect(sendResult == "Another answer is already running in this conversation.")
        }
    }
    release.signal()
    _ = try await holdStore.value
    #expect(try await restoring.value.count == 2)
}

@Test("phone restore clears an earlier time window on success or failed admission", arguments: [false, true])
func companionRestoreClearsPreviousWindow(failAdmission: Bool) async throws {
    let fixture = try await RestoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let conversation = fixture.conversation()
    // Subjectless activity uses the deterministic event path, so no model is called.
    let last = await withTaskGroup(of: Turn?.self) { group in
        group.addTask {
            var latest: Turn?
            for await turn in conversation.send("What was I working on last week?") { latest = turn }
            return latest
        }
        group.addTask { do { try await Task.sleep(for: .seconds(5)) } catch { }; return nil }
        let result = await group.next() ?? nil
        group.cancelAll(); return result
    }
    #expect(last?.receipt?.stages.contains { $0.name == "activity" } == true)
    let followUp = "And what about it?"
    #expect(await conversation.inheritedWindowForNextQuestion(followUp) != nil)
    if failAdmission {
        try await fixture.store.database.execute("UPDATE object SET domain = ? WHERE id = ?", [.text("medical"), .text(fixture.source.objectID.value)])
        do { _ = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread); Issue.record("blocked source restored") }
        catch CompanionConversationRestoreError.unavailable { }
        catch { Issue.record("expected unavailable history, got \(error)") }
    } else {
        _ = try await conversation.restoreCompanionHistory(scope: fixture.scope, thread: fixture.thread)
    }
    #expect(await conversation.inheritedWindowForNextQuestion(followUp) == nil)
}
