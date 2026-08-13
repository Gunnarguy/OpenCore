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

// MARK: - What a receipt can actually trace

// Regression, 2026-08-12. The Receipts screen offered "Trace evidence" on every row and the
// sheet reported "This answer admitted no evidence" two inches under a counter reading 6.
//
// `evidenceAdmitted` counts two different things. `Reasoner` assembles from the claim graph and
// writes `receipt_evidence` rows, so its counter is claim evidence and a trace resolves it.
// Chat answers from passages, sets `evidenceAdmitted: sources.count`, and deliberately never
// reads the claim table (`claimsConsulted: 0`, with a comment saying it is genuinely zero and
// not a placeholder). So a chat receipt has a non-zero counter and nothing to trace, and the
// screen whose whole job is showing where an answer came from contradicted itself.
//
// The discriminator lives on the type rather than as a `claimsConsulted > 0` comparison in a
// view, so the two surfaces cannot disagree about it.

private func receipt(claimsConsulted: Int, evidenceAdmitted: Int) -> Receipt {
    Receipt(
        query: "q",
        queryClass: .factual,
        domainsAdmitted: [.project],
        domainsBlocked: [],
        stages: [],
        objectsSearched: 100,
        objectsRetrieved: 6,
        evidenceAdmitted: evidenceAdmitted,
        claimsConsulted: claimsConsulted,
        contradictionsSurfaced: 0,
        model: nil,
        objectsTransmitted: 0,
        confidence: nil
    )
}

@Test("a passage-answered receipt reports no claim evidence to trace, however many passages it admitted")
func passageAnsweredReceiptHasNothingToTrace() {
    // The exact shape chat writes: six passages admitted, claim table never read.
    let chat = receipt(claimsConsulted: 0, evidenceAdmitted: 6)

    #expect(!chat.answeredFromClaims)
    // And the counter is still six. The fix is not to zero it: the passages are real, they are
    // shown in chat's own receipt sheet, and blanking a measured count to make a button
    // consistent would be writing a plausible value into a receipt field.
    #expect(chat.evidenceAdmitted == 6)
}

@Test("a claim-answered receipt is traceable")
func claimAnsweredReceiptIsTraceable() {
    #expect(receipt(claimsConsulted: 4, evidenceAdmitted: 9).answeredFromClaims)
}
