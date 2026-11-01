import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreGraph
@testable import CoreIngest

private let source = AppleNotesConnector().source
private let field = "\u{1F}"
private let record = "\u{1E}"

private func reply(reported: Int, failed: Int, notes: [(id: String, title: String, modified: String)]) -> String {
    let header = ["OPENCORE_NOTES_V1", String(reported), String(failed)].joined(separator: field) + record
    return header + notes.map { [$0.id, $0.title, "Notes", $0.modified, "body"].joined(separator: field) + record }.joined()
}

// The bug: on 2026-08-14 an empty result set the sync date, the app reported "already up to date",
// and notes older than that date could never arrive. The per-note `try` swallowed every failure
// so a script that failed on every note looked like an empty library.
@Test("a reply with no readable notes is a failure, not an empty library")
func zeroNotesThrows() {
    #expect(throws: AppleNotesConnector.NotesError.self) {
        _ = try AppleNotesConnector.parse(reply(reported: 12, failed: 12, notes: []), sourceID: source.id, since: nil)
    }
    #expect(throws: AppleNotesConnector.NotesError.self) {
        _ = try AppleNotesConnector.parse(reply(reported: 0, failed: 0, notes: []), sourceID: source.id, since: nil)
    }
    #expect(throws: AppleNotesConnector.NotesError.self) {
        _ = try AppleNotesConnector.parse("", sourceID: source.id, since: nil)
    }
}

// Reading notes and finding none changed is a good outcome and must not read as a failure.
@Test("an incremental read that finds nothing newer is success")
func nothingNewerIsSuccess() throws {
    let raw = reply(reported: 1, failed: 0, notes: [("a", "Old note", "2026-01-01T09:00:00")])
    let parsed = try AppleNotesConnector.parse(raw, sourceID: source.id, since: Date())
    #expect(parsed.objects.isEmpty)
    #expect(parsed.reported == 1)
}

@Test("readable notes come through and unreadable ones are counted")
func partialReadIsReported() throws {
    let raw = reply(reported: 3, failed: 1, notes: [("a", "One", "2026-01-01T09:00:00"), ("b", "Two", "2026-02-01T09:00:00")])
    let parsed = try AppleNotesConnector.parse(raw, sourceID: source.id, since: nil)
    #expect(parsed.objects.count == 2)
    #expect(parsed.failed == 1)
    #expect(parsed.batch().unread.count == 1)
}

private func syncer(_ store: Store, clock: @escaping @Sendable () -> Date = { Date() }) -> SourceSync {
    SourceSync(store: store, pipeline: IngestPipeline(store: store), clock: clock)
}

private func heldStore() async throws -> (Store, Date) {
    let store = try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-fresh-\(UUID().uuidString)/store.sqlite3"))
    try await store.upsert(source)
    try await store.ingest([CoreObject(sourceID: source.id, kind: .note, externalID: "held", title: "held", text: "note", domain: .personal, authority: .authoredArtifact)])
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.markSynced(source.id, at: earlier, cursor: nil)
    return (store, earlier)
}

// The bug: only a reply with nothing in it was a failure. A read of 1 note out of 3,000 returned
// normally, `failed` reached only `log`, the app passes `{ _ in }` as log, and SourceSync moved the
// date. Every later sync then dropped the other 2,999 at `modified < since` until someone edited
// them, and the record said success.
@Test("a partial Notes read keeps what it read and leaves the sync date where it was")
func partialNotesReadHoldsTheDate() async throws {
    let (store, earlier) = try await heldStore()
    let raw = reply(reported: 3_000, failed: 2_999, notes: [("a", "The one that worked", "2026-06-01T09:00:00")])

    let report = try await syncer(store).run(source.id, fetch: { since in
        try AppleNotesConnector.parse(raw, sourceID: source.id, since: since).batch()
    })

    #expect(!report.advanced)
    #expect(report.read == 1, "what was read is still kept")
    #expect(report.changed == 1)
    #expect(try await store.sources().first { $0.id == source.id }?.lastSyncedAt == earlier)
    #expect(report.heldBecause?.contains("2999") == true)
}

// Separate from the test above: this path returns before the one that holds there. An incremental
// read that finds nothing newer but failed on notes it could not date must not read as "up to date".
@Test("a Notes read with failures and nothing newer holds the date too")
func failuresWithNothingNewerHoldTheDate() async throws {
    let (store, earlier) = try await heldStore()
    let raw = reply(reported: 2, failed: 1, notes: [("a", "Old", "2020-01-01T09:00:00")])

    let report = try await syncer(store).run(source.id, fetch: { since in
        try AppleNotesConnector.parse(raw, sourceID: source.id, since: since).batch()
    })

    #expect(report.read == 0)
    #expect(!report.advanced)
    #expect(try await store.sources().first { $0.id == source.id }?.lastSyncedAt == earlier)
}

// The design this needs: a locked note may fail on every read, so if locked notes held the date,
// one locked note would stop Notes advancing for good. They are counted apart and never read.
@Test("locked notes are left out and do not hold the sync date")
func lockedNotesDoNotHoldTheDate() async throws {
    let (store, _) = try await heldStore()
    let header = ["OPENCORE_NOTES_V1", "3", "0", "2"].joined(separator: field) + record
    let body = ["a", "Open", "Notes", "2026-06-01T09:00:00", "body"].joined(separator: field) + record
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let report = try await syncer(store, clock: { now }).run(source.id, fetch: { since in
        let parsed = try AppleNotesConnector.parse(header + body, sourceID: source.id, since: since)
        #expect(parsed.locked == 2)
        return parsed.batch()
    })

    #expect(report.advanced)
    #expect(report.heldBecause == nil)
    #expect(try await store.sources().first { $0.id == source.id }?.lastSyncedAt == now)
}

// A reply can be short without anything counting as a failure, and that is the same loss.
@Test("notes Notes reported that never arrived hold the date, and so do unparseable ones")
func missingNotesHoldTheDate() throws {
    let short = try AppleNotesConnector.parse(reply(reported: 5, failed: 0, notes: [("a", "One", "2026-01-01T09:00:00")]), sourceID: source.id, since: nil)
    #expect(short.batch().unread.contains { $0.contains("never arrived") })

    let garbled = reply(reported: 2, failed: 0, notes: [("a", "One", "2026-01-01T09:00:00")]) + "half a record" + record
    let parsed = try AppleNotesConnector.parse(garbled, sourceID: source.id, since: nil)
    #expect(parsed.skipped == 1)
    #expect(parsed.batch().unread.contains { $0.contains("parsed") })
}

@Test("a complete read reports nothing unread")
func completeReadIsComplete() throws {
    let parsed = try AppleNotesConnector.parse(reply(reported: 1, failed: 0, notes: [("a", "One", "2026-01-01T09:00:00")]), sourceID: source.id, since: nil)
    #expect(parsed.batch().unread.isEmpty)
}

// The bug: the message promised the next sync starts from the beginning. With a date and objects
// on the source it does not: `incrementalStart` returns the date and the next read filters by it.
@Test("the no-records message makes no promise about where the next sync starts")
func noRecordsMessageIsTrue() {
    let message = AppleNotesConnector.NotesError.noRecords(reported: 12, failed: 12, locked: 0).description
    #expect(!message.contains("from the beginning"))
    #expect(message.contains("did not move"))
}

// MARK: - Notes on the schedule

// The bug: sync.scheduled and sync.scheduledNotes both default to true and a never-run job is the
// most overdue of all, so the first Notes read of a whole personal library started 20 s after launch
// with no click, and raised an Automation prompt with nobody there.
@Test("Notes stays off the schedule until a read someone started has brought something back")
func notesWaitsForAPerson() {
    let now = Date()
    let jobs: [SyncSchedule.Job] = [.calendar, .notes]
    #expect(SyncSchedule.runnable(jobs, records: [:], includeNotes: true) == [.calendar])

    let failed = SyncSchedule.Record(lastAttempt: now, lastError: "denied")
    #expect(SyncSchedule.runnable(jobs, records: [.notes: failed], includeNotes: true) == [.calendar], "a failed first read must not put it on the schedule")

    var read = SyncSchedule.Record()
    read.record(.finished(read: 4, changed: 4), at: now)
    #expect(SyncSchedule.runnable(jobs, records: [.notes: read], includeNotes: true) == jobs)
    #expect(SyncSchedule.runnable(jobs, records: [.notes: read], includeNotes: false) == [.calendar], "the setting still has the last word")

    var partial = SyncSchedule.Record()
    partial.record(.held(read: 4, changed: 4, reason: "1 of 5 notes could not be read."), at: now)
    #expect(SyncSchedule.runnable(jobs, records: [.notes: partial], includeNotes: true) == jobs, "a partial read has already been through the prompt")

    var empty = SyncSchedule.Record()
    empty.record(.held(read: 0, changed: 0, reason: "It returned nothing."), at: now)
    #expect(SyncSchedule.runnable(jobs, records: [.notes: empty], includeNotes: true) == [.calendar])
}

// The bug: an empty pass still called `markSynced`, which set `since`, which hid everything older
// from every later sync.
@Test("an empty first sync does not start the clock")
func emptyFirstSyncDoesNotAdvance() {
    #expect(!Source.shouldAdvanceSync(previous: nil, fetched: 0))
    #expect(Source.shouldAdvanceSync(previous: nil, fetched: 3))
    #expect(Source.shouldAdvanceSync(previous: Date(), fetched: 0))
}

// A store already poisoned by that bug heals itself: the real Notes source reads this way.
@Test("a source with a sync date and no objects reads from the beginning")
func poisonedSinceIsIgnored() async throws {
    let store = try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-fresh-\(UUID().uuidString)/store.sqlite3"))
    try await store.upsert(source)
    try await store.markSynced(source.id, at: Date(), cursor: nil)
    #expect(try await store.incrementalStart(for: source.id) == nil)

    let note = CoreObject(sourceID: source.id, kind: .note, externalID: "n", title: "n", text: "note", domain: .personal, authority: .authoredArtifact)
    try await store.ingest([note])
    #expect(try await store.incrementalStart(for: source.id) != nil)
}

// The bug: `since` selected events by when they happen, so 450 of 565 events on the real store were
// never looked at again after 2026-08-14 and could not gain `attendees_accepted`.
@Test("a calendar sync always reads its whole window, and since filters by modification")
func calendarWindowIgnoresSince() {
    let now = Date()
    let window = AppleEventKitConnector.window(now: now, lookBack: 730 * 86_400, lookAhead: 180 * 86_400)
    #expect(window.start == now.addingTimeInterval(-730 * 86_400))
    #expect(window.end == now.addingTimeInterval(180 * 86_400))

    let since = now.addingTimeInterval(-86_400)
    #expect(AppleEventKitConnector.changed(lastModified: now, since: since))
    #expect(!AppleEventKitConnector.changed(lastModified: since.addingTimeInterval(-1), since: since))
    #expect(AppleEventKitConnector.changed(lastModified: nil, since: since), "an unknown date is re-read, not skipped")
    #expect(AppleEventKitConnector.changed(lastModified: since.addingTimeInterval(-1), since: nil), "a full resync reads everything")
}

@Test("a job that never ran is due first, and a recent one is not due")
func scheduleOrdersByOverdue() {
    let now = Date()
    let records: [SyncSchedule.Job: SyncSchedule.Record] = [
        .calendar: .init(lastAttempt: now.addingTimeInterval(-7_200), lastSuccess: now.addingTimeInterval(-7_200)),
        .reminders: .init(lastAttempt: now.addingTimeInterval(-60), lastSuccess: now.addingTimeInterval(-60)),
    ]
    let due = SyncSchedule.due([.calendar, .reminders, .notes], records: records, now: now)
    #expect(due == [.notes, .calendar])
}

// Without this a failing source would retry on every tick, starting Notes every half hour.
@Test("a failed job waits its interval before trying again, and keeps showing how stale it is")
func failureWaitsItsInterval() {
    let now = Date()
    let failed = SyncSchedule.Record(lastAttempt: now.addingTimeInterval(-60), lastSuccess: now.addingTimeInterval(-40 * 3_600), lastError: "denied")
    #expect(SyncSchedule.due([.notes], records: [.notes: failed], now: now).isEmpty)
    #expect(SyncSchedule.due([.notes], records: [.notes: failed], now: now.addingTimeInterval(7 * 3_600)) == [.notes])
}

@Test("the schedule keeps Apple's sources on a shorter interval than the slow ones")
func intervalsAreOrdered() {
    #expect(SyncSchedule.Job.calendar.interval < SyncSchedule.Job.notes.interval)
    #expect(SyncSchedule.Job.reminders.interval < SyncSchedule.Job.github.interval)
}

// The bug: private repository names were compiled into a public repository. The defaults must fail
// closed, because the file that holds them is not in the tree.
@Test("a repository the binary does not know stays restricted")
func unknownRepositoriesStayRestricted() {
    #expect(AgentMemoryPolicy.repositoryDomain(name: "some-private-thing", names: .empty) == .restricted)
    #expect(AgentMemoryPolicy.repositoryDomain(name: "OpenCore", names: .empty) == .project)
    #expect(AgentMemoryPolicy.repositoryDomain(name: "OpenClinic", names: .empty) == .medical)
}

@Test("the local list decides the compartment, and the stricter list wins")
func localNamesClassify() {
    let names = LocalPrivateNames(repositories: .init(project: ["example-tool", "both"], medical: ["example-health", "both"], personal: ["example-garden"]))
    #expect(AgentMemoryPolicy.repositoryDomain(name: "Example-Tool", names: names) == .project)
    #expect(AgentMemoryPolicy.repositoryDomain(name: "example-health", names: names) == .medical)
    #expect(AgentMemoryPolicy.repositoryDomain(name: "example-garden", names: names) == .personal)
    #expect(AgentMemoryPolicy.repositoryDomain(name: "both", names: names) == .medical)
}

@Test("a missing or malformed list loads as empty, and a partial one keeps what it has")
func privateNamesLoadSafely() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-names-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(LocalPrivateNames.load(from: folder.appendingPathComponent("absent.json")) == .empty)

    let malformed = folder.appendingPathComponent("bad.json")
    try Data("not json".utf8).write(to: malformed)
    #expect(LocalPrivateNames.load(from: malformed) == .empty)

    let partial = folder.appendingPathComponent("partial.json")
    try Data(#"{"peers":[{"alias":"example-host","role":"helper"}]}"#.utf8).write(to: partial)
    let loaded = LocalPrivateNames.load(from: partial)
    #expect(loaded.peers.first?.alias == "example-host")
    #expect(loaded.repositories == .unavailable)
}

@Test("the documented example file parses")
func exampleFileParses() throws {
    let example = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Docs/private-names.example.json")
    let names = try JSONDecoder().decode(LocalPrivateNames.self, from: Data(contentsOf: example))
    #expect(!names.repositories.medical.isEmpty)
    #expect(!names.operatorRepositories.isEmpty)
}
