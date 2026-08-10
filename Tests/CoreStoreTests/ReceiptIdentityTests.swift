import CoreModel
import Foundation
import Testing

@testable import CoreStore

/// **The bug.** `Receipt.id` was `derived(from: query, milliseconds)`, so two answers to the
/// same question inside the same millisecond produced the same id. `Reasoner` saves with
/// `try await store.save(receipt)`, so the second insert failed the primary key and the whole
/// call threw: the user waited for an answer and got `UNIQUE constraint failed: receipt.id`.
///
/// Measured 2026-08-10 by a regression test for something else that happened to ask one
/// question twice. Reachable by a double-clicked Ask button or an MCP client retrying a call.
///
/// Content-addressing is right for an *object*, where re-ingesting the same bytes should update
/// one row. A receipt is the opposite: it records that an answer *happened*, so asking the same
/// question twice is two events with two audit trails.
@Suite("Receipt identity")
struct ReceiptIdentityTests {
    private static func temporaryStore() async throws -> Store {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3")
        return try await Store.open(at: path)
    }

    private static func receipt(_ query: String, at date: Date) -> Receipt {
        Receipt(
            query: query, queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
            stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0,
            claimsConsulted: 0, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0,
            confidence: nil, createdAt: date
        )
    }

    @Test("the same question asked twice in the same instant produces two receipts, not a crash")
    func identicalQueriesDoNotCollide() async throws {
        let store = try await Self.temporaryStore()
        // The exact same timestamp, not merely a close one. Under the old scheme this is the
        // collision, and anything less than identical would let the test pass by luck.
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        let first = Self.receipt("what am I building", at: instant)
        let second = Self.receipt("what am I building", at: instant)
        #expect(first.id != second.id)

        // The original failure was a throw, so this saving at all is the assertion.
        try await store.save(first)
        try await store.save(second)
        #expect(try await store.receipts(limit: 10).count == 2)
    }

    @Test("a receipt's id survives a round trip through the database rather than being recomputed")
    func idIsReadNotRederived() async throws {
        let store = try await Self.temporaryStore()
        let original = Self.receipt("what am I building", at: Date(timeIntervalSince1970: 1_800_000_000.5))
        try await store.save(original)

        // The old decoder rebuilt the id from the query plus a millisecond timestamp and
        // depended on the stored Double reproducing exactly. When it did not, the receipt was
        // still in the table but `opencore trace` could never find it again.
        let fetched = try await store.receipt(code: original.shortCode)
        #expect(fetched?.id == original.id)
        #expect(fetched?.shortCode == original.shortCode)
    }

    @Test("a short code stays unique enough to identify one receipt among many")
    func shortCodesDoNotCollideInPractice() {
        // `shortCode` is the first six hex characters, which is what a person actually types
        // into `opencore trace`. Six hex characters is 16.7M values; this asserts the id is
        // random enough that they do not repeat, which a timestamp-derived id would not be for
        // queries issued close together.
        let codes = Set((0..<500).map { _ in
            Self.receipt("same question every time", at: Date(timeIntervalSince1970: 1_800_000_000)).shortCode
        })
        #expect(codes.count == 500)
    }
}
