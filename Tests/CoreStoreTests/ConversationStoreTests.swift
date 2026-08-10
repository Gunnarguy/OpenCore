import CoreModel
import Foundation
import Testing

@testable import CoreStore

/// Saved chat threads, added 2026-08-10 because chat was entirely ephemeral: turns lived in a
/// SwiftUI `@State` array, the model's own `Transcript` held the continuity, and closing the
/// tab destroyed both.
///
/// The guarantees worth protecting here are not "rows round-trip". They are the two that would
/// quietly destroy a user's history if they regressed: **`rebuild` must not delete a saved
/// conversation**, because a conversation is primary data that nothing can reconstruct, and a
/// thread's ordering must survive being written out of order.
@Suite("Saved conversations")
struct ConversationStoreTests {
    private static func temporaryStore() async throws -> Store {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3")
        return try await Store.open(at: path)
    }

    @Test("a rebuild drops every derived layer and leaves saved conversations untouched")
    func rebuildDoesNotDestroyConversations() async throws {
        let store = try await Self.temporaryStore()
        try await store.openConversation(id: "thread-1", title: "what am I building")
        try await store.append(StoredTurn(
            conversationID: "thread-1", ordinal: 0, role: "you", text: "what am I building"
        ))
        try await store.append(StoredTurn(
            conversationID: "thread-1", ordinal: 1, role: "core", text: "An evidence store."
        ))

        try await store.dropDerivedLayers()

        // The project's first non-negotiable is that objects are the floor and nothing derived
        // may be the only copy of anything. A conversation is the inverse case: it is primary,
        // no object graph can reconstruct the user's own questions, so `rebuild` must not be
        // allowed anywhere near it. Listing these tables in `derivedTables` would make
        // `opencore rebuild` silently delete a user's entire chat history.
        #expect(try await store.turns(conversationID: "thread-1").count == 2)
        #expect(try await store.conversations().count == 1)
    }

    @Test("turns come back in the order they happened, not the order they were written")
    func turnsAreOrderedByOrdinal() async throws {
        let store = try await Self.temporaryStore()
        try await store.openConversation(id: "t", title: "ordering")

        // Written back to front on purpose. Ordering by a timestamp would be at the mercy of
        // two turns landing inside the same millisecond, and an answer displayed above its
        // question is unreadable.
        for ordinal in [2, 0, 1] {
            try await store.append(StoredTurn(
                conversationID: "t", ordinal: ordinal, role: "core", text: "turn \(ordinal)"
            ))
        }

        let turns = try await store.turns(conversationID: "t")
        #expect(turns.map(\.ordinal) == [0, 1, 2])
        #expect(turns.map(\.text) == ["turn 0", "turn 1", "turn 2"])
    }

    @Test("appending a turn marks its thread as recently used")
    func appendingMovesTheThreadToTheTop() async throws {
        let store = try await Self.temporaryStore()
        let old = Date(timeIntervalSince1970: 1_000_000)
        try await store.openConversation(id: "older", title: "older", at: old)
        try await store.openConversation(id: "newer", title: "newer", at: old.addingTimeInterval(60))

        // A resume list sorted by creation date buries the thread you were just in, which is
        // the one you are most likely to want back.
        try await store.append(StoredTurn(
            conversationID: "older", ordinal: 0, role: "you", text: "still going",
            createdAt: old.addingTimeInterval(3600)
        ))

        #expect(try await store.conversations().first?.id == "older")
    }

    @Test("opening an existing thread twice does not reset it")
    func openingIsIdempotent() async throws {
        let store = try await Self.temporaryStore()
        try await store.openConversation(id: "t", title: "first title")
        try await store.append(StoredTurn(conversationID: "t", ordinal: 0, role: "you", text: "hi"))

        // The chat path calls this before every single append rather than tracking whether it
        // has saved yet. A second call must not wipe the turns or rename the thread.
        try await store.openConversation(id: "t", title: "a different title")

        #expect(try await store.turns(conversationID: "t").count == 1)
        #expect(try await store.conversation(id: "t")?.title == "first title")
    }

    @Test("deleting a thread takes its turns and leaves its receipts")
    func deletingCascadesToTurnsButNotReceipts() async throws {
        let store = try await Self.temporaryStore()
        let receipt = Receipt(
            query: "q", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
            stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1,
            claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0,
            confidence: nil
        )
        try await store.save(receipt)
        try await store.openConversation(id: "t", title: "t")
        try await store.append(StoredTurn(
            conversationID: "t", ordinal: 0, role: "core", text: "answer", receiptID: receipt.id
        ))

        try await store.deleteConversation(id: "t")

        #expect(try await store.turns(conversationID: "t").isEmpty)
        // The receipt is evidence about an answer that was really given, reachable by
        // `opencore trace` and referenced by receipt_evidence. The turn's foreign key is
        // ON DELETE SET NULL rather than CASCADE precisely so forgetting a conversation does
        // not silently delete an audit trail.
        #expect(try await store.receipt(code: receipt.shortCode) != nil)
    }
}
