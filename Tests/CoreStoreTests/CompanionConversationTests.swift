import CoreModel
import Dispatch
import Foundation
import Testing
@testable import CoreStore

@Test("typed IDs preserve SQLite's byte-distinct Unicode identities")
func typedIDIdentityUsesExactUTF8Bytes() throws {
    let composed = ObjectID("\u{00E9}"), decomposed = ObjectID("e\u{0301}")
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    var values: [ObjectID: Int] = [:]
    values[composed] = 1; values[decomposed] = 2
    #expect(values.count == 2 && values[composed] == 1 && values[decomposed] == 2)
    let encoded = try JSONEncoder().encode([composed, decomposed])
    let decoded = try JSONDecoder().decode([ObjectID].self, from: encoded)
    #expect(decoded == [composed, decomposed])
    let sameBytes = ObjectID(String(decoding: Array(composed.value.utf8), as: UTF8.self))
    #expect(sameBytes == composed && Set([sameBytes, composed]).count == 1)
    #expect(ObjectID("a\u{0}b") != ObjectID("a"))
}

private struct CompanionHistoryFixture {
    let directory: URL
    let store: Store
    let scope: CompanionHistoryScope
    let thread: UUID
    let request: UUID
    let question: String
    let answer: StoredTurn
    let receipt: Receipt

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-phone-history-\(UUID().uuidString)")
        let store = try await Store.open(at: directory.appendingPathComponent("fixture.sqlite3"))
        let scope = CompanionHistoryScope(deviceID: UUID(), grantID: UUID(), domains: [.project, .publicRecord], selectedDomain: nil)
        let thread = UUID(), request = UUID(), question = "What is the fixture project?"
        let receipt = Receipt(query: question, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [.medical],
            stages: [ReceiptStage(name: "companion.delivery", milliseconds: 0,
                note: "Acknowledged by paired device \(scope.deviceID.uuidString) (Fixture phone). Grant \(scope.grantID.uuidString).")],
            objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0, claimsConsulted: 0,
            contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil,
            id: Store.companionReceiptID(for: request))
        let answer = StoredTurn(conversationID: scope.conversationID(for: thread), ordinal: 99,
            role: "core", text: "Fixture answer.", sourcesJSON: "[\"fixture\"]", receiptID: receipt.id)
        return Self(directory: directory, store: store, scope: scope, thread: thread, request: request,
                    question: question, answer: answer, receipt: receipt)
    }

    func save(request: UUID? = nil, answer: StoredTurn? = nil, receipt: Receipt? = nil,
              digest: String = String(repeating: "a", count: 64),
              evidence: [(EvidenceID, Double)] = [], claims: [ClaimID] = [],
              additionalEvidence: [Evidence] = []) async throws -> Receipt {
        try await store.saveCompanionExchange(scope: scope, thread: thread, request: request ?? self.request,
            requestDigest: digest, question: question, answer: answer ?? self.answer, receipt: receipt ?? self.receipt,
            evidence: evidence, claims: claims, additionalEvidence: additionalEvidence, enforceCurrentAdmission: false)
    }
}

@Test("phone history lookup distinguishes a new thread from an untrusted existing one")
func companionHistoryLookupDistinguishesNewFromUnavailable() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: fixture.thread) {
    case .missing: break
    default: Issue.record("a new thread was not missing")
    }
    var answer = fixture.answer
    answer.sourcesJSON = "[]"
    _ = try await fixture.save(answer: answer)
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: fixture.thread) {
    case .admitted(let snapshot): #expect(snapshot.exchanges.count == 1)
    default: Issue.record("the valid exchange was not admitted")
    }
    let otherGrant = CompanionHistoryScope(deviceID: fixture.scope.deviceID, grantID: UUID(),
        domains: fixture.scope.domains, selectedDomain: fixture.scope.selectedDomain)
    switch try await fixture.store.companionHistoryLookup(scope: otherGrant, thread: fixture.thread) {
    case .missing: break
    default: Issue.record("another grant could see this thread")
    }
    let emptyThread = UUID()
    try await fixture.store.openConversation(id: fixture.scope.conversationID(for: emptyThread), title: "Unlabelled empty thread")
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: emptyThread) {
    case .unavailable: break
    default: Issue.record("an existing unlabelled empty thread could start empty")
    }
    let id = fixture.scope.conversationID(for: fixture.thread)
    try await fixture.store.append(StoredTurn(conversationID: id, ordinal: 2, role: "you", text: "Unlabelled fixture"))
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: fixture.thread) {
    case .unavailable: break
    default: Issue.record("an untrusted existing thread could start empty")
    }
}

@Test("orphaned turns do not let a phone start an existing thread as empty")
func companionHistoryLookupRejectsOrphanedTurns() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let thread = UUID(), id = fixture.scope.conversationID(for: thread)
    // Simulate an already-corrupt synthetic store; ordinary writes enforce this foreign key.
    try await fixture.store.database.execute("PRAGMA foreign_keys = OFF")
    try await fixture.store.database.execute(
        "INSERT INTO conversation_turn (id, conversation_id, ordinal, role, text, sources, verdicts, created_at) VALUES (?, ?, 0, 'you', 'orphan', '[]', '[]', 1)",
        [.text(UUID().uuidString), .text(id)])
    try await fixture.store.database.execute("PRAGMA foreign_keys = ON")
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: thread) {
    case .unavailable: break
    default: Issue.record("orphaned turns were treated as a new thread")
    }
}

@Test("byte-identical BLOB thread IDs are unavailable rather than new", arguments: ["conversation", "orphan", "duplicate", "stray-turn"])
func companionHistoryLookupRejectsBlobIdentifiers(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let thread = ["duplicate", "stray-turn"].contains(kind) ? fixture.thread : UUID()
    let id = fixture.scope.conversationID(for: thread)
    if ["duplicate", "stray-turn"].contains(kind) {
        var answer = fixture.answer
        answer.sourcesJSON = "[]"
        _ = try await fixture.save(answer: answer)
    }
    if kind == "conversation" || kind == "duplicate" {
        try await fixture.store.database.execute(
            "INSERT INTO conversation (id, title, started_at, updated_at) VALUES (?, 'BLOB fixture', 1, 1)",
            [.blob(Data(id.utf8))])
    } else {
        try await fixture.store.database.execute("PRAGMA foreign_keys = OFF")
        try await fixture.store.database.execute(
            "INSERT INTO conversation_turn (id, conversation_id, ordinal, role, text, sources, verdicts, created_at) VALUES (?, ?, 0, 'you', 'orphan', '[]', '[]', 1)",
            [.text(UUID().uuidString), .blob(Data(id.utf8))])
        try await fixture.store.database.execute("PRAGMA foreign_keys = ON")
    }
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: thread) {
    case .unavailable: break
    default: Issue.record("a byte-identical BLOB identifier was not refused")
    }
    if ["duplicate", "stray-turn"].contains(kind) {
        if try await fixture.store.companionHistory(scope: fixture.scope, thread: thread) != nil {
            Issue.record("the direct history read accepted a byte-identical BLOB alias")
        }
        let page = try await fixture.store.companionHistoryPage(scope: fixture.scope)
        #expect(!page.threads.contains { $0.id == thread })
    }
    // The conflicting rows may arrive after lookup and before the phone ACK. The write
    // transaction must independently reject them instead of trusting the earlier read.
    let request = UUID()
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: request)
    var answer = fixture.answer
    answer.id = UUID().uuidString
    answer.conversationID = id
    answer.sourcesJSON = "[]"
    answer.receiptID = receipt.id
    do {
        _ = try await fixture.store.saveCompanionExchange(scope: fixture.scope, thread: thread, request: request,
            requestDigest: String(repeating: "b", count: 64), question: fixture.question, answer: answer, receipt: receipt, expectedRevision: .empty)
        Issue.record("the write accepted a byte-identical BLOB identifier")
    } catch CompanionHistoryError.untrustedConversation { }
    catch { Issue.record("expected an untrusted conversation, got \(error)") }
}

@Test("a BLOB identifier with an extra NUL is not the same thread", arguments: [false, true])
func companionHistoryLookupKeepsDistinctIdentifierBytes(existing: Bool) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let thread = existing ? fixture.thread : UUID(), id = fixture.scope.conversationID(for: thread)
    if existing {
        var answer = fixture.answer
        answer.sourcesJSON = "[]"
        _ = try await fixture.save(answer: answer)
    }
    var bytes = Data(id.utf8)
    bytes.append(0)
    try await fixture.store.database.execute(
        "INSERT INTO conversation (id, title, started_at, updated_at) VALUES (?, 'NUL fixture', 1, 1)", [.blob(bytes)])
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: thread) {
    case .missing where !existing: break
    case .admitted where existing:
        #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: thread)?.exchanges.count == 1)
        let page = try await fixture.store.companionHistoryPage(scope: fixture.scope)
        #expect(page.threads.contains { $0.id == thread })
    default: Issue.record("distinct identifier bytes were treated as the same thread")
    }
}

@Test("a failed phone-thread deletion rolls back its tombstone")
func companionThreadDeletionRollsBackTombstone() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer
    answer.sourcesJSON = "[]"
    _ = try await fixture.save(answer: answer)
    let id = fixture.scope.conversationID(for: fixture.thread)
    try await fixture.store.database.execute("""
        CREATE TEMP TRIGGER reject_phone_delete BEFORE DELETE ON conversation
        BEGIN SELECT RAISE(ABORT, 'synthetic delete failure'); END
        """)
    do { try await fixture.store.deleteConversation(id: id); Issue.record("the injected delete failure did not happen") }
    catch { #expect(String(describing: error).contains("synthetic delete failure")) }
    #expect(try await fixture.store.database.scalarInt("SELECT COUNT(*) FROM companion_thread_tombstone") == 0)
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread)?.exchanges.count == 1)
}

@Test("recreated deleted phone turns remain unavailable to all history reads")
func companionDeletedHistoryStaysHiddenAfterRecreation() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer
    answer.sourcesJSON = "[]"
    _ = try await fixture.save(answer: answer)
    let id = fixture.scope.conversationID(for: fixture.thread)
    let priorTurns = try await fixture.store.turns(conversationID: id)
    try #require(priorTurns.count == 2)
    try await fixture.store.deleteConversation(id: id)

    // An older writer or a generic Mac API can recreate the row and identical turns.
    // The retained receipt must not make that deleted content visible to the phone.
    try await fixture.store.openConversation(id: id, title: "Recreated fixture")
    for turn in priorTurns { try await fixture.store.append(turn) }
    if try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil {
        Issue.record("the direct history read exposed a recreated deleted thread")
    }
    let page = try await fixture.store.companionHistoryPage(scope: fixture.scope)
    #expect(!page.threads.contains { $0.id == fixture.thread })
    switch try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: fixture.thread) {
    case .unavailable: break
    default: Issue.record("a recreated deleted thread was available to the phone")
    }
}

@Test("a phone exchange cannot reuse byte-identical BLOB operation IDs", arguments: ["question", "answer", "receipt"])
func companionExchangeRejectsBlobOperationIdentifiers(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer
    answer.sourcesJSON = "[]"
    if kind == "receipt" {
        try await fixture.store.save(fixture.receipt)
        try await fixture.store.database.execute("UPDATE receipt SET id = ? WHERE id = ?",
            [.blob(Data(fixture.receipt.id.value.utf8)), .text(fixture.receipt.id.value)])
    } else {
        let other = "unrelated-fixture"
        try await fixture.store.openConversation(id: other, title: "Fixture")
        let conflictingID = kind == "question" ? fixture.request.uuidString : answer.id
        try await fixture.store.database.execute(
            "INSERT INTO conversation_turn (id, conversation_id, ordinal, role, text, sources, verdicts, created_at) VALUES (?, ?, 0, 'you', 'BLOB fixture', '[]', '[]', 1)",
            [.blob(Data(conflictingID.utf8)), .text(other)])
    }
    do {
        _ = try await fixture.save(answer: answer)
        Issue.record("a byte-identical BLOB operation ID was accepted")
    } catch CompanionHistoryError.duplicateOperation { }
    catch { Issue.record("expected duplicate operation, got \(error)") }
}

@Test("an acknowledged phone exchange saves its question, answer and receipt together")
func companionExchangeIsStoredTogether() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    #expect(try await fixture.store.conversations().isEmpty)
    let delivered = try await fixture.save()
    let id = fixture.scope.conversationID(for: fixture.thread)
    let turns = try await fixture.store.turns(conversationID: id)
    try #require(turns.count == 2)
    #expect(turns.map(\.role) == ["you", "core"])
    #expect(turns.map(\.ordinal) == [0, 1])
    #expect(turns.map(\.text) == [fixture.question, fixture.answer.text])
    #expect(turns[0].id == fixture.request.uuidString)
    #expect(turns[0].receiptID == delivered.id && turns[1].receiptID == delivered.id)
    #expect(turns[1].sourcesJSON == fixture.answer.sourcesJSON)
    let saved = try #require(try await fixture.store.receipt(code: delivered.id.value))
    #expect(saved.stages.contains { $0.name == "companion.delivery" })
    #expect(saved.stages.contains { $0.name == "companion.operation" })
    #expect(saved.confidence == nil)
}

@Test("a trusted phone thread accepts a follow-up after an owner judgement")
func companionExchangeAcceptsTrustedFollowUp() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.save()
    try await fixture.store.judge(turn: fixture.answer.id, as: .good)
    let request = UUID()
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: request)
    var answer = fixture.answer
    answer.id = UUID().uuidString; answer.receiptID = receipt.id; answer.text = "A second answer."
    _ = try await fixture.save(request: request, answer: answer, receipt: receipt)
    let turns = try await fixture.store.turns(conversationID: fixture.scope.conversationID(for: fixture.thread))
    try #require(turns.count == 4)
    #expect(turns.map(\.ordinal) == [0, 1, 2, 3])
    #expect(turns[1].judgement == .good)
    #expect(turns[3].text == "A second answer.")
    #expect(try await fixture.store.receipts().count == 2)
}

@Test("a trace or answer insert failure rolls back the entire phone exchange", arguments: ["trace", "answer"])
func companionExchangeRollsBackOnFailure(failure: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    if failure == "answer" {
        // Fail after the receipt and question have been inserted, not in an earlier
        // duplicate-ID preflight. TEMP confines the fault to this synthetic connection.
        try await fixture.store.database.execute("""
            CREATE TEMP TRIGGER companion_fixture_reject_answer BEFORE INSERT ON conversation_turn
            WHEN NEW.role = 'core' BEGIN SELECT RAISE(ABORT, 'synthetic answer insert failure'); END
            """)
    }
    let evidence: [(EvidenceID, Double)] = failure == "trace" ? [(EvidenceID("missing-fixture-evidence"), 0.5)] : []
    do {
        _ = try await fixture.save(evidence: evidence)
        Issue.record("the injected transaction failure did not happen")
    } catch {
        if failure == "answer" { #expect(String(describing: error).contains("synthetic answer insert failure")) }
    }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.turns(conversationID: fixture.scope.conversationID(for: fixture.thread)).isEmpty)
    #expect(try await !fixture.store.conversations().contains { $0.id == fixture.scope.conversationID(for: fixture.thread) })
}

@Test("a phone thread with a Mac-added unlabelled turn cannot receive another phone exchange")
func companionExchangeRejectsUnlabelledMacTurns() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.save()
    let id = fixture.scope.conversationID(for: fixture.thread)
    try await fixture.store.append(StoredTurn(conversationID: id, ordinal: 2, role: "you", text: "PRIVATE_MAC_FIXTURE"))
    let request = UUID()
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: request)
    var answer = fixture.answer
    answer.id = UUID().uuidString
    answer.receiptID = receipt.id
    do { _ = try await fixture.save(request: request, answer: answer, receipt: receipt); Issue.record("unlabelled Mac turn was accepted") }
    catch CompanionHistoryError.untrustedConversation { }
    catch { Issue.record("expected an untrusted conversation, got \(error)") }
    #expect(try await fixture.store.receipts().count == 1)
    #expect(try await fixture.store.turns(conversationID: id).count == 3)
}

@Test("deleting a phone thread does not permit the same operation to create a second receipt")
func companionDeletedThreadDoesNotForgetOperation() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.save()
    try await fixture.store.deleteConversation(id: fixture.scope.conversationID(for: fixture.thread))
    var nextReceipt = fixture.receipt
    nextReceipt.id = ReceiptID(UUID().uuidString)
    var nextAnswer = fixture.answer
    nextAnswer.id = UUID().uuidString; nextAnswer.receiptID = nextReceipt.id
    await #expect(throws: CompanionHistoryError.self) { try await fixture.save(answer: nextAnswer, receipt: nextReceipt) }
    do { _ = try await fixture.save(); Issue.record("a deleted thread forgot the prior operation") }
    catch CompanionHistoryError.duplicateOperation { }
    catch { Issue.record("expected duplicate operation, got \(error)") }
    #expect(try await fixture.store.receipts().count == 1)
    #expect(try await fixture.store.conversations().isEmpty)
}

@Test("a Mac edit of a saved phone answer cannot inherit its old receipt's authorization",
      arguments: ["text", "sources", "verdicts", "model", "model-empty", "error"])
func companionExchangeRejectsOverwrittenAnswer(field: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.save()
    let id = fixture.scope.conversationID(for: fixture.thread)
    var changed = try #require(try await fixture.store.turns(conversationID: id).last)
    switch field {
    case "text": changed.text = "PRIVATE_MAC_FIXTURE"
    case "sources": changed.sourcesJSON = "[\"changed source\"]"
    case "verdicts": changed.verdictsJSON = "[\"changed verdict\"]"
    case "model": changed.model = "another author"
    case "model-empty": changed.model = ""
    default: changed.error = "changed warning"
    }
    try await fixture.store.append(changed)
    let request = UUID()
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: request)
    var answer = fixture.answer
    answer.id = UUID().uuidString; answer.receiptID = receipt.id
    do { _ = try await fixture.save(request: request, answer: answer, receipt: receipt); Issue.record("overwritten answer was accepted") }
    catch CompanionHistoryError.untrustedConversation { }
    catch { Issue.record("expected an untrusted conversation, got \(error)") }
    #expect(try await fixture.store.receipts().count == 1)
    #expect(try await fixture.store.turns(conversationID: id).count == 2)
}

@Test("a moved phone exchange cannot inherit the authorization of a different read scope")
func companionExchangeRejectsMovedScope() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.save()
    let oldID = fixture.scope.conversationID(for: fixture.thread)
    let oldTurns = try await fixture.store.turns(conversationID: oldID)
    try await fixture.store.deleteConversation(id: oldID)
    let narrower = CompanionHistoryScope(deviceID: fixture.scope.deviceID, grantID: fixture.scope.grantID,
        domains: fixture.scope.domains, selectedDomain: .project)
    let newID = narrower.conversationID(for: fixture.thread)
    try await fixture.store.openConversation(id: newID, title: "Moved fixture")
    for var turn in oldTurns { turn.conversationID = newID; try await fixture.store.append(turn) }
    let request = UUID()
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: request)
    var answer = fixture.answer
    answer.id = UUID().uuidString; answer.conversationID = newID; answer.receiptID = receipt.id
    do {
        _ = try await fixture.store.saveCompanionExchange(scope: narrower, thread: fixture.thread, request: request,
            requestDigest: String(repeating: "b", count: 64), question: fixture.question, answer: answer, receipt: receipt, expectedRevision: .empty)
        Issue.record("moved exchange was accepted under another scope")
    } catch CompanionHistoryError.untrustedConversation { }
    catch { Issue.record("expected an untrusted conversation, got \(error)") }
    #expect(try await fixture.store.receipts().count == 1)
    #expect(try await fixture.store.turns(conversationID: newID).count == 2)
}

@Test("a request identity can be committed only once even by separate store connections")
func companionExchangeHasDurableUniqueRequestIdentity() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let other = try await Store.open(at: fixture.directory.appendingPathComponent("fixture.sqlite3"))
    var secondAnswer = fixture.answer
    secondAnswer.id = UUID().uuidString
    async let first: String = {
        do { _ = try await fixture.save(); return "saved" }
        catch CompanionHistoryError.duplicateOperation { return "duplicate" }
        catch { return "other error" }
    }()
    async let second: String = {
        do {
            _ = try await other.saveCompanionExchange(scope: fixture.scope, thread: fixture.thread, request: fixture.request,
                requestDigest: String(repeating: "a", count: 64), question: fixture.question,
                answer: secondAnswer, receipt: fixture.receipt, enforceCurrentAdmission: false)
            return "saved"
        } catch CompanionHistoryError.duplicateOperation { return "duplicate" }
        catch { return "other error" }
    }()
    let results = await [first, second]
    #expect(results.sorted() == ["duplicate", "saved"])
    #expect(try await fixture.store.receipts().count == 1)
    #expect(try await fixture.store.turns(conversationID: fixture.scope.conversationID(for: fixture.thread)).count == 2)
}

@Test("phone history refuses bad grant, scope, digest and question metadata",
      arguments: ["grant", "scope", "digest", "question"])
func companionExchangeRejectsInvalidMetadata(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var receipt = fixture.receipt
    if kind == "grant" {
        receipt.stages = [ReceiptStage(name: "companion.delivery", milliseconds: 0,
            note: "Acknowledged by paired device \(fixture.scope.deviceID.uuidString) (Fixture phone). Grant \(UUID().uuidString).")]
    }
    if kind == "scope" { receipt.domainsAdmitted = [.medical] }
    if kind == "question" { receipt.query = "A different question" }
    let digest = kind == "digest" ? "not-a-digest" : String(repeating: "a", count: 64)
    await #expect(throws: CompanionHistoryError.self) { try await fixture.save(receipt: receipt, digest: digest) }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.conversations().isEmpty)
}

@Test("phone answer identifiers must retain the canonical form used when restoring a turn")
func companionExchangeRejectsNoncanonicalAnswerID() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer
    answer.id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    await #expect(throws: CompanionHistoryError.self) { try await fixture.save(answer: answer) }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.conversations().isEmpty)
}

@Test("a phone receipt identity belongs to its random request UUID")
func companionExchangeRejectsDifferentReceiptID() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var receipt = fixture.receipt
    receipt.id = Store.companionReceiptID(for: UUID())
    var answer = fixture.answer
    answer.receiptID = receipt.id
    do { _ = try await fixture.save(answer: answer, receipt: receipt); Issue.record("another request's receipt ID was accepted") }
    catch CompanionHistoryError.invalidExchange { }
    catch { Issue.record("expected invalid exchange, got \(error)") }
    #expect(try await fixture.store.receipts().isEmpty)
    #expect(try await fixture.store.conversations().isEmpty)
}

@Test("phone operation and payload identities use stable versioned UTF-8 framing")
func companionHistoryStablePayloadVector() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-phone-vector-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("fixture.sqlite3"))
    let device = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
    let grant = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
    let thread = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000003"))
    let request = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000004"))
    let answerID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000005"))
    let scope = CompanionHistoryScope(deviceID: device, grantID: grant, domains: [.project, .publicRecord], selectedDomain: nil)
    let question = "Question Ω\u{0}fixture"
    let receipt = Receipt(query: question, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: [ReceiptStage(name: "companion.delivery", milliseconds: 0,
            note: "Acknowledged by paired device \(device.uuidString) (Fixture phone). Grant \(grant.uuidString).")],
        objectsSearched: 0, objectsRetrieved: 0, evidenceAdmitted: 0, claimsConsulted: 0,
        contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil,
        id: Store.companionReceiptID(for: request))
    let answer = StoredTurn(id: answerID.uuidString, conversationID: scope.conversationID(for: thread), ordinal: 0,
        role: "core", text: "Answer🙂", receiptID: receipt.id)
    let saved = try await store.saveCompanionExchange(scope: scope, thread: thread, request: request,
        requestDigest: String(repeating: "a", count: 64), question: question, answer: answer, receipt: receipt, expectedRevision: .empty)
    #expect(saved.id.value == "8aef30ed4f56b23d396ceb8ba5bd570b")
    #expect(saved.stages.first { $0.name == "companion.operation" }?.note?.hasSuffix("Payload v1:a3f57767a5bc88d9858f910c3d9389e0") == true)
    let history = try #require(try await store.companionHistory(scope: scope, thread: thread))
    #expect(history.exchanges.first?.question.text == question)
}

@Test("phone history exposes only the current grant and derives its title from the validated question")
func companionHistoryIsScopedAndIgnoresMacTitle() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer
    answer.sourcesJSON = "[]"
    _ = try await fixture.save(answer: answer)
    let id = fixture.scope.conversationID(for: fixture.thread)
    try await fixture.store.renameConversation(id: id, title: "PRIVATE_MAC_TITLE")
    let history = try #require(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread))
    #expect(history.exchanges.first?.question.text == fixture.question)
    #expect(history.exchanges.first?.answer.text == answer.text)
    let page = try await fixture.store.companionHistoryPage(scope: fixture.scope)
    #expect(page.threads.map(\.title) == [fixture.question])
    #expect(page.nextOffset == nil)
    let otherGrant = CompanionHistoryScope(deviceID: fixture.scope.deviceID, grantID: UUID(),
        domains: fixture.scope.domains, selectedDomain: nil)
    #expect(try await fixture.store.companionHistory(scope: otherGrant, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: otherGrant).threads.isEmpty)
    let narrowed = CompanionHistoryScope(deviceID: fixture.scope.deviceID, grantID: fixture.scope.grantID,
        domains: fixture.scope.domains, selectedDomain: .project)
    #expect(try await fixture.store.companionHistory(scope: narrowed, thread: fixture.thread) == nil)
}

@Test("untrusted phone threads do not consume visible history pages")
func companionHistoryPaginatesAfterAdmission() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    for index in 0..<45 {
        let thread = UUID(), request = UUID(), question = "Fixture question \(index)"
        var receipt = fixture.receipt
        receipt.id = Store.companionReceiptID(for: request); receipt.query = question
        let answer = StoredTurn(conversationID: fixture.scope.conversationID(for: thread), ordinal: 0,
            role: "core", text: "Fixture answer", receiptID: receipt.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        _ = try await fixture.store.saveCompanionExchange(scope: fixture.scope, thread: thread, request: request,
            requestDigest: String(repeating: "a", count: 64), question: question, answer: answer, receipt: receipt, expectedRevision: .empty)
    }
    for index in 0..<45 {
        let id = fixture.scope.conversationID(for: UUID())
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        try await fixture.store.openConversation(id: id, title: "PRIVATE_MAC_TITLE", at: date)
        try await fixture.store.append(StoredTurn(conversationID: id, ordinal: 0, role: "you", text: "PRIVATE_MAC_QUESTION", createdAt: date))
    }
    let first = try await fixture.store.companionHistoryPage(scope: fixture.scope, offset: 0, limit: 20)
    let second = try await fixture.store.companionHistoryPage(scope: fixture.scope, offset: 20, limit: 20)
    let third = try await fixture.store.companionHistoryPage(scope: fixture.scope, offset: 40, limit: 20)
    #expect(first.threads.count == 20 && second.threads.count == 20 && third.threads.count == 5)
    #expect(first.nextOffset == 20 && second.nextOffset == 40 && third.nextOffset == nil)
    let all = first.threads + second.threads + third.threads
    #expect(Set(all.map(\.id)).count == 45)
    #expect(all.allSatisfy { $0.title.hasPrefix("Fixture question ") })
}

@Test("malformed saved phone history stays hidden rather than crashing or losing its scope",
      arguments: ["sources", "ordinal", "receipt-count", "receipt-domain", "receipt-stages"])
func companionHistoryRejectsMalformedRows(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer
    answer.sourcesJSON = kind == "sources" ? "not-json" : "[]"
    _ = try await fixture.save(answer: answer)
    switch kind {
    case "ordinal":
        try await fixture.store.database.execute("UPDATE conversation_turn SET ordinal = ? WHERE id = ?", [.real(1e100), .text(answer.id)])
    case "receipt-count":
        try await fixture.store.database.execute("UPDATE receipt SET objects_searched = ? WHERE id = ?", [.real(1e100), .text(fixture.receipt.id.value)])
    case "receipt-domain":
        try await fixture.store.database.execute("UPDATE receipt SET domains_admitted = ? WHERE id = ?", [.text("project,future_fixture"), .text(fixture.receipt.id.value)])
    case "receipt-stages":
        try await fixture.store.database.execute("UPDATE receipt SET stages = ? WHERE id = ?", [.text("invalid-json"), .text(fixture.receipt.id.value)])
    default: break
    }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: fixture.scope).threads.isEmpty)
}

@Test("an unknown stored domain stays hidden even from a full-grant phone")
func companionHistoryRejectsUnknownDomainForFullGrant() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let scope = CompanionHistoryScope(deviceID: fixture.scope.deviceID, grantID: fixture.scope.grantID,
        domains: Set(Domain.allCases), selectedDomain: nil)
    var answer = fixture.answer
    answer.conversationID = scope.conversationID(for: fixture.thread); answer.sourcesJSON = "[]"
    _ = try await fixture.store.saveCompanionExchange(scope: scope, thread: fixture.thread, request: fixture.request,
        requestDigest: String(repeating: "a", count: 64), question: fixture.question, answer: answer, receipt: fixture.receipt, expectedRevision: .empty)
    #expect(try await fixture.store.companionHistory(scope: scope, thread: fixture.thread) != nil)
    try await fixture.store.database.execute("UPDATE receipt SET domains_admitted = ? WHERE id = ?",
        [.text("project,future_fixture"), .text(fixture.receipt.id.value)])
    #expect(try await fixture.store.companionHistory(scope: scope, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: scope).threads.isEmpty)
}

private struct FixtureSourceReferences: Encodable {
    let objectID: ObjectID
    let representedObjectIDs: [ObjectID]?
    let claimID: ClaimID?
}

@Test("phone history rejects canonically equivalent IDs when one source is restricted")
func companionHistoryRejectsCanonicallyEquivalentObjectIDs() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await fixture.store.upsert(source)
    var admitted = CoreObject(sourceID: source.id, kind: .document, externalID: "allowed", title: "Allowed",
        text: "Allowed fixture", domain: .project, authority: .authoredArtifact)
    var blocked = CoreObject(sourceID: source.id, kind: .document, externalID: "blocked", title: "Blocked",
        text: "PRIVATE_FIXTURE", domain: .medical, authority: .authoredArtifact)
    admitted.id = ObjectID("\u{00E9}")
    blocked.id = ObjectID("e\u{0301}")
    _ = try await fixture.store.ingest([admitted, blocked])
    let reference = FixtureSourceReferences(objectID: admitted.id, representedObjectIDs: [blocked.id], claimID: nil)
    var answer = fixture.answer
    answer.sourcesJSON = String(decoding: try JSONEncoder().encode([reference]), as: UTF8.self)
    _ = try await fixture.save(answer: answer)
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: fixture.scope).threads.isEmpty)
}

@Test("phone history rechecks the current domains of every source, trace and claim",
      arguments: ["primary", "represented", "trace", "claim"])
func companionHistoryRechecksCurrentSourceAdmission(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await fixture.store.upsert(source)
    let admitted = CoreObject(sourceID: source.id, kind: .document, externalID: "admitted", title: "Admitted",
        text: "Admitted fixture", domain: .project, authority: .authoredArtifact)
    let blocked = CoreObject(sourceID: source.id, kind: .document, externalID: "blocked", title: "Blocked",
        text: "PRIVATE_FIXTURE", domain: .medical, authority: .authoredArtifact)
    try await fixture.store.ingest([admitted, blocked])
    let entity = CoreEntity(kind: .concept, canonicalName: "Fixture concept", domain: .medical)
    try await fixture.store.upsert([entity])
    let claim = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "fixture", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .medical)
    try await fixture.store.save([claim])
    let support = Evidence(objectID: admitted.id, snippet: "Admitted fixture", authority: .authoredArtifact)
    try await fixture.store.save([support]); try await fixture.store.link(claim: claim.id, to: support.id, stance: .supports)
    let trace = Evidence(objectID: blocked.id, snippet: "PRIVATE_FIXTURE", authority: .authoredArtifact)
    let reference = FixtureSourceReferences(objectID: kind == "primary" ? blocked.id : admitted.id,
        representedObjectIDs: kind == "represented" ? [blocked.id] : [], claimID: kind == "claim" ? claim.id : nil)
    var answer = fixture.answer
    answer.sourcesJSON = String(decoding: try JSONEncoder().encode([reference]), as: UTF8.self)
    _ = try await fixture.save(answer: answer, evidence: kind == "trace" ? [(trace.id, 0.5)] : [],
        additionalEvidence: kind == "trace" ? [trace] : [])
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: fixture.scope).threads.isEmpty)

    if kind == "claim" {
        try await fixture.store.database.execute("UPDATE entity SET domain = ? WHERE id = ?", [.text("project"), .text(entity.id.value)])
        try await fixture.store.database.execute("UPDATE claim SET domain = ? WHERE id = ?", [.text("project"), .text(claim.id.value)])
    } else {
        try await fixture.store.database.execute("UPDATE object SET domain = ? WHERE id = ?", [.text("project"), .text(blocked.id.value)])
    }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil)
    if kind == "claim" {
        try await fixture.store.database.execute("UPDATE claim SET domain = ? WHERE id = ?", [.text("medical"), .text(claim.id.value)])
    } else {
        try await fixture.store.database.execute("UPDATE object SET domain = ? WHERE id = ?", [.text("medical"), .text(blocked.id.value)])
    }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) == nil)
}

private enum CompanionSnapshotFixtureError: Error { case timedOut, deliberate }

@Test("phone history validation reads one database snapshot across another connection's commit")
func companionHistoryUsesConsistentReadSnapshot() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.store.openConversation(id: "fixture-snapshot", title: "before")
    let writer = try await Store.open(at: fixture.directory.appendingPathComponent("fixture.sqlite3"))
    let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let reading = Task {
        try await fixture.store.database.read { connection in
            try Store.withCompanionSnapshot(connection: connection) {
                let before = try connection.query("SELECT title FROM conversation WHERE id = ?", [.text("fixture-snapshot")]).first?.string("title")
                ready.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw CompanionSnapshotFixtureError.timedOut }
                let during = try connection.query("SELECT title FROM conversation WHERE id = ?", [.text("fixture-snapshot")]).first?.string("title")
                return (before, during)
            }
        }
    }
    let observed = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: ready.wait(timeout: .now() + 5) == .success) }
    }
    if observed { try await writer.renameConversation(id: "fixture-snapshot", title: "after") }
    release.signal()
    let (before, during) = try await reading.value
    #expect(observed)
    #expect(before == "before" && during == "before")
    #expect(try await writer.conversation(id: "fixture-snapshot")?.title == "after")

    await #expect(throws: CompanionSnapshotFixtureError.self) {
        try await fixture.store.database.read { connection in
            try Store.withCompanionSnapshot(connection: connection) { throw CompanionSnapshotFixtureError.deliberate }
        }
    }
    // BEGIN IMMEDIATE must succeed on the same connection after rollback.
    try await fixture.store.database.write { connection in
        try connection.execute("UPDATE conversation SET title = ? WHERE id = ?", [.text("usable"), .text("fixture-snapshot")])
    }
    #expect(try await fixture.store.conversation(id: "fixture-snapshot")?.title == "usable")
}

@Test("a cancelled phone history read returns no private snapshot and leaves the store usable",
      arguments: ["detail", "list", "lookup"])
func companionHistoryHonorsCancellation(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var answer = fixture.answer; answer.sourcesJSON = "[]"
    _ = try await fixture.save(answer: answer)
    let (gate, continuation) = AsyncStream<Void>.makeStream()
    let reading = Task {
        for await _ in gate { }
        if kind == "detail" { return try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil }
        if kind == "lookup" {
            if case .admitted = try await fixture.store.companionHistoryLookup(scope: fixture.scope, thread: fixture.thread) { return true }
            return false
        }
        return try await !fixture.store.companionHistoryPage(scope: fixture.scope).threads.isEmpty
    }
    reading.cancel()
    continuation.finish()
    await #expect(throws: CancellationError.self) { try await reading.value }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil)
}

@Test("cancelling an active history snapshot rolls back and leaves the connection usable")
func companionHistoryCancellationRollsBackActiveSnapshot() async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.store.openConversation(id: "cancel-fixture", title: "before")
    let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let reading = Task {
        try await fixture.store.database.read { connection in
            try Store.withCompanionSnapshot(connection: connection) {
                let title = try connection.query("SELECT title FROM conversation WHERE id = ?", [.text("cancel-fixture")]).first?.string("title")
                ready.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw CompanionSnapshotFixtureError.timedOut }
                return title
            }
        }
    }
    let entered = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: ready.wait(timeout: .now() + 5) == .success) }
    }
    #expect(entered)
    reading.cancel(); release.signal()
    await #expect(throws: CancellationError.self) { try await reading.value }
    try await fixture.store.database.write { connection in
        try connection.execute("UPDATE conversation SET title = ? WHERE id = ?", [.text("usable"), .text("cancel-fixture")])
    }
    #expect(try await fixture.store.conversation(id: "cancel-fixture")?.title == "usable")
}

@Test("a claim with a malformed linked ID cannot authorize phone history",
      arguments: ["subject-nul", "subject-blob", "target-nul", "target-blob", "evidence-nul", "evidence-blob",
                  "object-nul", "object-blob", "receipt-subject-nul", "receipt-evidence-blob"])
func companionHistoryRejectsMalformedClaimEntity(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await fixture.store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .document, externalID: "allowed", title: "Allowed",
        text: "Fixture", domain: .project, authority: .authoredArtifact)
    try await fixture.store.ingest([object])
    let entity = CoreEntity(kind: .concept, canonicalName: "Allowed entity", domain: .project)
    try await fixture.store.upsert([entity])
    let claim = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "fixture", confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    try await fixture.store.save([claim])
    let support = Evidence(objectID: object.id, snippet: "Fixture", authority: .authoredArtifact)
    try await fixture.store.save([support]); try await fixture.store.link(claim: claim.id, to: support.id, stance: .supports)
    let viaReceipt = kind.hasPrefix("receipt-")
    let ref = FixtureSourceReferences(objectID: object.id, representedObjectIDs: [], claimID: viaReceipt ? nil : claim.id)
    var answer = fixture.answer
    answer.sourcesJSON = String(decoding: try JSONEncoder().encode([ref]), as: UTF8.self)
    _ = try await fixture.save(answer: answer, claims: viaReceipt ? [claim.id] : [])
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil)

    let badID: SQLValue = kind.hasSuffix("nul") ? .text("linked\u{0}fixture") : .blob(Data("linked-fixture".utf8))
    if kind.contains("subject") || kind.contains("target") {
        try await fixture.store.database.execute(
            "INSERT INTO entity (id, kind, canonical_name, domain, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
            [badID, .text("concept"), .text("Malformed fixture"), .text("project"), .real(1), .real(1)]
        )
        let column = kind.contains("subject") ? "subject" : "object_entity"
        try await fixture.store.database.execute("UPDATE claim SET \(column) = ? WHERE id = ?", [badID, .text(claim.id.value)])
    } else if kind.contains("evidence") {
        try await fixture.store.database.execute("DELETE FROM claim_evidence WHERE claim_id = ?", [.text(claim.id.value)])
        try await fixture.store.database.execute("INSERT INTO evidence (id, object_id, snippet, authority) VALUES (?, ?, ?, ?)",
            [badID, .text(object.id.value), .text("Fixture"), .integer(Int64(Authority.authoredArtifact.rawValue))])
        try await fixture.store.database.execute("INSERT INTO claim_evidence (claim_id, evidence_id, stance, weight) VALUES (?, ?, ?, ?)",
            [.text(claim.id.value), badID, .text("supports"), .real(1)])
    } else {
        try await fixture.store.database.execute(
            """
            INSERT INTO object (id, source_id, kind, external_id, title, text, ingested_at, content_hash, domain, authority, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [badID, .text(source.id.value), .text("document"), .text("malformed"), .text("Fixture"), .text("Fixture"),
                   .real(1), .text("fixture"), .text("project"), .integer(Int64(Authority.authoredArtifact.rawValue)), .text("{}")])
        try await fixture.store.database.execute("UPDATE evidence SET object_id = ? WHERE id = ?", [badID, .text(support.id.value)])
    }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: fixture.scope).threads.isEmpty)
}

@Test("every claim admission component is checked independently for saved phone history",
      arguments: ["claim", "subject", "target", "support", "receipt-claim"])
func companionHistoryChecksEachClaimComponent(kind: String) async throws {
    let fixture = try await CompanionHistoryFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await fixture.store.upsert(source)
    let displayed = CoreObject(sourceID: source.id, kind: .document, externalID: "displayed", title: "Displayed",
        text: "Fixture", domain: .project, authority: .authoredArtifact)
    let supporting = CoreObject(sourceID: source.id, kind: .document, externalID: "support", title: "Support",
        text: "Support fixture", domain: .project, authority: .authoredArtifact)
    try await fixture.store.ingest([displayed, supporting])
    let subject = CoreEntity(kind: .concept, canonicalName: "Subject fixture", domain: .project)
    let target = CoreEntity(kind: .concept, canonicalName: "Target fixture", domain: .project)
    try await fixture.store.upsert([subject, target])
    let claim = CoreClaim(subject: subject.id, predicate: Predicate.uses, objectEntity: target.id, confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    try await fixture.store.save([claim])
    let evidence = Evidence(objectID: supporting.id, snippet: "Support fixture", authority: .authoredArtifact)
    try await fixture.store.save([evidence]); try await fixture.store.link(claim: claim.id, to: evidence.id, stance: .supports)
    let ref = FixtureSourceReferences(objectID: displayed.id, representedObjectIDs: [], claimID: kind == "receipt-claim" ? nil : claim.id)
    var answer = fixture.answer
    answer.sourcesJSON = String(decoding: try JSONEncoder().encode([ref]), as: UTF8.self)
    var receipt = fixture.receipt; receipt.claimsConsulted = 1
    _ = try await fixture.save(answer: answer, receipt: receipt, claims: [claim.id])
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) != nil)
    switch kind {
    case "subject":
        try await fixture.store.database.execute("UPDATE entity SET domain = ? WHERE id = ?", [.text("medical"), .text(subject.id.value)])
    case "target":
        try await fixture.store.database.execute("UPDATE entity SET domain = ? WHERE id = ?", [.text("medical"), .text(target.id.value)])
    case "support":
        try await fixture.store.database.execute("UPDATE object SET domain = ? WHERE id = ?", [.text("medical"), .text(supporting.id.value)])
    default:
        try await fixture.store.database.execute("UPDATE claim SET domain = ? WHERE id = ?", [.text("medical"), .text(claim.id.value)])
    }
    #expect(try await fixture.store.companionHistory(scope: fixture.scope, thread: fixture.thread) == nil)
    #expect(try await fixture.store.companionHistoryPage(scope: fixture.scope).threads.isEmpty)
}
