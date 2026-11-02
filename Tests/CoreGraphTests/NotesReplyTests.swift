import CoreModel
import CoreStore
import CoreTelemetry
import Foundation
import Synchronization
import Testing
@testable import CoreIngest
@testable import CoreGraph

private let notesSource = AppleNotesConnector().source
private let fs = "\u{1F}", rs = "\u{1E}", esc = "\u{1D}"
private let noteDate = "2026-01-02T03:04:05"
private func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: esc, with: esc + "E")
        .replacingOccurrences(of: fs, with: esc + "F").replacingOccurrences(of: rs, with: esc + "R")
}
private func row(_ id: String = "note-a", date: String = noteDate, body: String = "body") -> String {
    [id, "Title", "Notes", date, body].map(escaped).joined(separator: fs) + rs
}
private func frame(_ records: String, reported: String = "1", failed: String = "0", locked: String = "0", timeouts: String = "0", denied: String = "0") -> String {
    ["OPENCORE_NOTES_V2", reported, failed, locked, timeouts, denied].joined(separator: fs) + rs + records
}
private func parse(_ raw: String, since: Date? = nil) throws -> AppleNotesConnector.Parsed {
    try AppleNotesConnector.parse(raw, sourceID: notesSource.id, since: since)
}

// The bug: the reader assumed control separators could not occur in Notes text. A field byte
// truncated the body, and a record byte made parts of that body look like other notes.
@Test("Notes AppleScript framing preserves control bytes and Unicode in every field")
func notesWireRoundTrip() throws {
    let title = "Café 🧪\n" + esc + "E" + fs + rs
    let folder = "Personal " + fs + "🗒️" + rs + esc
    let body = "a\nb\rc\t\"\\" + fs + rs + esc + "EFR" + " e\u{301}"
    // Run the actual production handlers, with synthetic literals only. Never tell Notes or
    // request Automation, access a library, or send any event to an application.
    func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = AppleNotesConnector.wireHandlers + "\n"
        + "set syntheticDate to current date\nset month of syntheticDate to January\nset day of syntheticDate to 2\nset year of syntheticDate to 2026\nset time of syntheticDate to (3 * hours + 4 * minutes + 5)\n"
        + "set wireDate to syntheticDate as «class isot» as string\n"
        + "set recordText to my wireRecord({\(literal("id" + fs + rs + esc)), \(literal(title)), \(literal(folder)), wireDate, \(literal(body))})\n"
        + "return my wireReply(1, 0, 0, 0, 0, {recordText})"
    // Chosen fixture budget; this checks framing, not latency under concurrent test load.
    let result = try BoundedProcess.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 15, maximumOutputBytes: 16_384)
    #expect(result.status == 0, "synthetic handlers must execute: \(result.stderrText)")
    #expect(!result.timedOut)
    let parsed = try parse(AppleNotesConnector.processReply(status: result.status, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut, limit: 16_384))
    let object = try #require(parsed.objects.first)
    #expect(object.externalID == "id" + fs + rs + esc)
    #expect(object.title == title)
    #expect(object.metadata["folder"] == folder)
    #expect(object.text == title + "\n\n" + body)
    #expect(object.domain == .personal)
    #expect(parsed.batch().unread.isEmpty)
}

// The bug: a missing header or invalid/negative counter became zero; surplus rows or overflow
// could therefore be presented as a complete read and let SourceSync advance the date.
@Test("Notes rejects missing headers and malformed or inconsistent accounting")
func notesInvalidAccounting() throws {
    let invalid = [row(), "OPENCORE_NOTES_V3" + fs + "1" + rs + row(),
                   frame(row(), reported: "no"), frame(row(), reported: "-1"), frame(row(), failed: "invalid"),
                   frame(row(), reported: "+1"), frame(row(), reported: "1 "),
                   frame(row(), reported: String(Int.max) + "0"),
                   frame(row(), reported: "0"), frame(row(), failed: "2"),
                   frame(row(), failed: "1", locked: "1"),
                   frame(row(), failed: "1", timeouts: "1", denied: "1"),
                   frame(row(), failed: "0", timeouts: "1"),
                   frame(row(), failed: "0", denied: "1"),
                   frame(row(), reported: "1") + row("note-b"),
                   frame(row()).replacingOccurrences(of: "OPENCORE_NOTES_V2", with: "OPENCORE_NOTES_V2" + fs + "0"),
                   String(frame(row()).dropLast())]
    for raw in invalid {
        #expect(throws: AppleNotesConnector.NotesError.self) { _ = try parse(raw) }
    }
    // Valid huge counts remain incomplete without doing an overflowing addition.
    let huge = try parse(frame(row(), reported: String(Int.max)))
    #expect(!huge.batch().unread.isEmpty)
    #expect(throws: AppleNotesConnector.NotesError.self) {
        _ = try parse(frame(row(), reported: String(Int.max), failed: String(Int.max), locked: "1"))
    }
}

@Test("duplicate Notes identifiers cannot certify a complete library")
func notesDuplicateRows() throws {
    #expect(throws: AppleNotesConnector.NotesError.self) { _ = try parse(frame(row() + row(), reported: "2")) }
}

// The bug: >5 fields silently lost text, invalid dates counted as read, and an undecodable row
// could move the source date. Prove both the exact body shape and the independent date guard.
@Test("malformed Notes rows remain unread and hold both date and cursor")
func notesMalformedRowsHoldFreshness() async throws {
    let malformed = [row("bad", date: "not-a-date"), row("bad", date: "2026-02-30T03:04:05"),
                     row("bad", date: "2026-1-2T03:04:05"),
                     ["bad", "T", "Notes", noteDate, "bad" + esc + "Q"].joined(separator: fs) + rs,
                     ["bad", "T", "Notes", noteDate, "bad" + esc].joined(separator: fs) + rs,
                     ["bad", "T", "Notes", noteDate, "first", "lost"].joined(separator: fs) + rs,
                     ["bad", "T", "Notes", noteDate].joined(separator: fs) + rs]
    let store = try await Store.open(at: FileManager.default.temporaryDirectory.appendingPathComponent("notes-framing-\(UUID().uuidString)/store.sqlite3"))
    try await store.upsert(notesSource)
    try await store.ingest([CoreObject(sourceID: notesSource.id, kind: .note, externalID: "existing", title: "Existing", text: "existing", domain: .personal, authority: .authoredArtifact)])
    let earlier = Date(timeIntervalSince1970: 1_600_000_000)
    try await store.markSynced(notesSource.id, at: earlier, cursor: "previous")
    for bad in malformed {
        let raw = frame(row() + bad, reported: "2")
        let parsed = try parse(raw)
        #expect(parsed.read == 1)
        #expect(parsed.skipped == 1)
        let report = try await SourceSync(store: store, pipeline: IngestPipeline(store: store)).run(notesSource.id, fetch: { since in
            try parse(raw, since: since).batch(cursor: "incomplete")
        })
        #expect(!report.advanced)
        let source = try #require(try await store.sources().first { $0.id == notesSource.id })
        #expect(source.lastSyncedAt == earlier)
        #expect(source.syncCursor == "previous")
    }
}

@Test("V1 Notes replies with extra fields fail conservatively instead of truncating")
func notesLegacyDoesNotTruncate() throws {
    let good = row()
    let bad = ["bad", "T", "Notes", noteDate, "a", "b"].joined(separator: fs) + rs
    let parsed = try parse(["OPENCORE_NOTES_V1", "2", "0"].joined(separator: fs) + rs + good + bad)
    #expect(parsed.skipped == 1)
    #expect(parsed.objects.count == 1)
    #expect(!parsed.batch().unread.isEmpty)
}

@Test("Notes diagnostics distinguish per-note event timeouts and Automation denial")
func notesEventFailureAccounting() throws {
    let parsed = try parse(frame(row(), reported: "5", failed: "2", locked: "2", timeouts: "1", denied: "1"))
    #expect(parsed.locked == 2)
    #expect(parsed.batch().unread.contains { $0.contains("timed out") })
    #expect(parsed.batch().unread.contains { $0.contains("denied Automation") })
    #expect(!parsed.batch().unread.contains { $0.contains("never arrived") })
    do {
        _ = try parse(frame("", reported: "2", failed: "2", timeouts: "1", denied: "1"))
        Issue.record("all-failed read must throw")
    } catch let error as AppleNotesConnector.NotesError {
        #expect(error.description.contains("timeouts: 1"))
        #expect(error.description.contains("denials: 1"))
    }
}

// The bug: the process budget did not set Apple Event timeout, and invalid timeouts could trap
// during integer conversion. No real Notes event is sent in this test.
@Test("Notes validates its overall budget before constructing bounded Apple Events")
func notesTimeoutConfiguration() throws {
    for timeout in [Double.nan, .infinity, -.infinity, 0, -1, Double(Int32.max) + 1] {
        #expect(throws: AppleNotesConnector.NotesError.self) { _ = try AppleNotesConnector.readerScript(includeBodies: true, timeout: timeout) }
    }
    #expect(try AppleNotesConnector.readerScript(includeBodies: false, timeout: 2.5).contains("with timeout of 3 seconds"))
    #expect(try AppleNotesConnector.readerScript(includeBodies: false, timeout: 0.1).contains("with timeout of 1 seconds"))
}

// The bug: a saturated stdout with a nonzero exit was only a generic script failure, and invalid
// UTF-8 was silently replaced. Raw error text could also contain note content or an unrelated code.
@Test("Notes process failures preserve limits and error categories without copying note text")
func notesProcessClassification() throws {
    func failure(status: Int32 = 1, output: Data = Data(), message: String = "", timeout: Bool = false) -> AppleNotesConnector.NotesError? {
        do { _ = try AppleNotesConnector.processReply(status: status, stdout: output, stderr: Data(message.utf8), timedOut: timeout, limit: 16); return nil }
        catch { return error as? AppleNotesConnector.NotesError }
    }
    guard case .replyTooLarge(16)? = failure(output: Data(repeating: 65, count: 16)) else { Issue.record("saturated output must fail as too large"); return }
    guard case .timedOut? = failure(timeout: true) else { Issue.record("overall deadline must stay separate"); return }
    guard case .automationDenied? = failure(message: "execution error: denied (-1743)\n") else { Issue.record("denial category lost"); return }
    guard case .eventTimedOut? = failure(message: "execution error: timeout (-1712)\n") else { Issue.record("event deadline category lost"); return }
    let privateMessage = "a synthetic note mentioned -1743 but failed differently (-1700)"
    let error = try #require(failure(message: privateMessage))
    guard case .scriptFailed = error else { Issue.record("a note mentioning an error code is not Automation denial"); return }
    #expect(!error.description.contains("synthetic note"))
    guard case .invalidReply? = failure(status: 0, output: Data([0xFF])) else { Issue.record("invalid UTF-8 must fail"); return }
}

@Test("cancelled Notes work cannot publish a completed batch")
func notesCancellationReachesReader() async throws {
    let started = Mutex(false)
    let cancelledReader = Mutex(false)
    let task = Task {
        try await AppleNotesConnector.readOffMain(sourceID: notesSource.id, since: nil) {
            started.withLock { $0 = true }
            let deadline = Date().addingTimeInterval(2) // Chosen fixture escape hatch if propagation regresses.
            while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            cancelledReader.withLock { $0 = Task.isCancelled }
            return frame(row())
        }
    }
    while !started.withLock({ $0 }) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(cancelledReader.withLock { $0 })
}

// The bug: Notes serializes modification dates to whole seconds, while SourceSync records a
// fractional start date. A later edit in that same second fell behind every future cutoff.
@Test("incremental Notes reads retain the fractional sync boundary second")
func notesIncrementalPrecision() throws {
    let date = try #require(try parse(frame(row())).objects.first?.authoredAt)
    let sameSecond = try parse(frame(row()), since: date.addingTimeInterval(0.5))
    #expect(sameSecond.objects.count == 1)
    let earlierSecond = try parse(frame(row()), since: date.addingTimeInterval(1.5))
    #expect(earlierSecond.objects.isEmpty)
    #expect(earlierSecond.read == 1)
    #expect(earlierSecond.batch().unread.isEmpty)
}
