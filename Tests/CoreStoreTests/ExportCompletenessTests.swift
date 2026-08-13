import CoreModel
import Foundation
import Testing

@testable import CoreStore

/// **The bug.** `Exporter.tables` was a hand-written list of 18 tables. Migration 4 added
/// `conversation` and `conversation_turn`, migration 5 added judgement columns to the second,
/// and the list was never updated. The JSONL export therefore omitted every saved chat, every
/// thumbs up/down verdict, and the receipt link that makes a chat answer traceable, while the
/// README written into the same directory said "Nothing else is omitted."
///
/// That combination is the worst case available in this project. Everything else in the export
/// is either an object or rebuildable from one, so losing it costs a `rebuild`. A conversation
/// is primary data and is deliberately outside `derivedTables` for exactly that reason: nothing
/// can reconstruct it. So export-then-wipe, the one workflow an archival format exists to make
/// safe, destroyed the only irreplaceable rows in the database and reported success.
///
/// The test asserts the invariant rather than the list. Comparing against a second hand-written
/// list would reproduce the original failure with an extra step; asking the live schema is what
/// makes the next migration fail loudly here instead of silently in someone's backup.

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-export-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

@Test("the export covers every table the schema has")
func exportCoversEverySchemaTable() async throws {
    let store = try await temporaryStore()
    let inSchema = Set(try await store.tableNames())
    let exported = Set(Exporter.tables)

    // `chunk_vector` is the one deliberate omission, and the README says so with its reason:
    // embeddings are recomputable from chunk text with `opencore embed`, and including them
    // would add hundreds of megabytes of base64 floats describing nothing the text does not
    // already say. Every other absence is a bug.
    //
    // `object_vector` is the second, and it is a different kind of exclusion: it is a v0.1
    // leftover that appears nowhere in the codebase except `schema.sql`. Nothing writes it,
    // nothing reads it, `rebuild` does not clear it because it is not in `derivedTables`, and
    // it is always empty. Exporting an always-empty file would suggest it means something.
    let missing = inSchema.subtracting(exported).subtracting(["chunk_vector", "object_vector"])
    #expect(missing.isEmpty, "not exported: \(missing.sorted().joined(separator: ", "))")
}

@Test("the export names no table the schema does not have")
func exportNamesNoPhantomTable() async throws {
    let store = try await temporaryStore()
    let inSchema = Set(try await store.tableNames())

    // The other direction, and not merely symmetry. A renamed table would leave a stale name
    // here, and the export would skip it while still reporting a row count per table, so the
    // total would look plausible and one table would quietly be absent.
    let phantom = Set(Exporter.tables).subtracting(inSchema)
    #expect(phantom.isEmpty, "exported but not in the schema: \(phantom.sorted().joined(separator: ", "))")
}

@Test("a saved conversation and its judgement survive a round trip through the export")
func savedChatsAreActuallyWritten() async throws {
    let store = try await temporaryStore()
    try await store.openConversation(id: "thread-1", title: "what is OpenClinic built with")
    try await store.append(StoredTurn(
        id: UUID().uuidString,
        conversationID: "thread-1",
        ordinal: 0,
        role: "core",
        text: "Swift, from its README."
    ))

    // Judged separately, because `append` deliberately does not write a verdict: a judgement
    // arrives when someone reads the answer, which is after the turn was saved.
    let saved = try #require(try await store.turns(conversationID: "thread-1").first)
    try await store.judge(turn: saved.id, as: .good)

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-export-out-\(UUID().uuidString)")
    let outcome = try await Exporter(store: store).export(to: directory, format: .jsonl)

    // Not just "the file exists": the verdict is the part that cannot be recomputed from
    // anything, and it is the seed of the eval corpus.
    let turns = try String(contentsOf: directory.appendingPathComponent("conversation_turn.jsonl"), encoding: .utf8)
    #expect(turns.contains("what is OpenClinic built with") == false)
    #expect(turns.contains("Swift, from its README."))
    #expect(turns.contains("good"))

    let threads = try String(contentsOf: directory.appendingPathComponent("conversation.jsonl"), encoding: .utf8)
    #expect(threads.contains("what is OpenClinic built with"))

    // And the manifest counts them, so a reader can tell the file is not an empty placeholder.
    let turnFile = outcome.files.first { $0.name.hasPrefix("conversation_turn") }
    #expect(turnFile?.rows == 1)
}
