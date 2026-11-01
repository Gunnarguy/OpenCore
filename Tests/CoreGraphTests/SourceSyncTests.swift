import CoreModel
import CoreStore
import EventKit
import Foundation
import Testing

@testable import CoreGraph
@testable import CoreIngest

// `SourceSync` holds the decisions that used to sit in the app, which has no test target. Each of
// these failures is silent in use: the sync reports success and something older is hidden for good.

private func temporaryStore() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-sourcesync-\(UUID().uuidString)/store.sqlite3"))
}

private func temporaryFolder() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-sourcesync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
    try Data(text.utf8).write(to: url)
    if let modified {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}

private let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)

private func note(_ id: String, text: String = "a note", metadata: [String: String] = [:]) -> CoreObject {
    CoreObject(sourceID: source.id, kind: .note, externalID: id, title: id, text: text, domain: .project, authority: .authoredArtifact, metadata: metadata)
}

private func syncer(_ store: Store, clock: @escaping @Sendable () -> Date = { Date() }) -> SourceSync {
    SourceSync(store: store, pipeline: IngestPipeline(store: store), clock: clock)
}

private func lastSynced(_ store: Store, _ id: SourceID = source.id) async throws -> Date? {
    try await store.sources().first { $0.id == id }?.lastSyncedAt
}

private struct ReadFailed: Error {}

// MARK: - The sync date

// The bug: a failed read and an empty one looked the same to whatever kept the date. A Notes read
// that failed on every note reported "already up to date", and that date hid every older note.
@Test("a read that fails leaves the sync date where it was")
func failedReadKeepsTheDate() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    try await store.ingest([note("held")])
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.markSynced(source.id, at: earlier, cursor: "before")

    await #expect(throws: ReadFailed.self) {
        _ = try await syncer(store).run(source.id, fetch: { _ in throw ReadFailed() })
    }

    #expect(try await lastSynced(store) == earlier)
}

// The specific failure from the store: Notes answered and nothing usable came back. Runs the real
// parser, so this also fails if it stops throwing on an empty reply.
@Test("Notes returning no records reports a failure and starts no clock")
func notesReturningNothingStartsNoClock() async throws {
    let store = try await temporaryStore()
    let notes = AppleNotesConnector().source
    try await store.upsert(notes)

    await #expect(throws: AppleNotesConnector.NotesError.self) {
        _ = try await syncer(store).run(notes.id, fetch: { since in
            let parsed = try AppleNotesConnector.parse("OPENCORE_NOTES_V1\u{1F}12\u{1F}12\u{1E}", sourceID: notes.id, since: since)
            return SourceSync.Fetched(objects: parsed.objects)
        })
    }

    #expect(try await lastSynced(store, notes.id) == nil)
}

// The bug: an empty first pass set the date, which told every later pass to skip what existed.
@Test("an empty first sync leaves the source unsynced, and says so")
func emptyFirstSyncDoesNotMark() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let report = try await syncer(store).run(source.id, fetch: { _ in SourceSync.Fetched(objects: []) })

    #expect(!report.advanced)
    #expect(report.derived == nil)
    #expect(try await lastSynced(store) == nil)
}

// The bug: this returned `.finished(read: 0, changed: 0)` from the app, and said "a first read" on
// any full read, though `.everything` always has `since` nil. Re-read Whole Calendar returning 0 on
// a source with 565 objects reported a first read and recorded a success with the date unmoved.
@Test("a full read that returns nothing from a source with a date is held, and says so")
func emptyFullReadIsHeld() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    try await store.ingest([note("held")])
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.markSynced(source.id, at: earlier, cursor: nil)

    let report = try await syncer(store).run(source.id, reach: .everything, fetch: { _ in SourceSync.Fetched(objects: []) })

    #expect(!report.advanced)
    #expect(try await lastSynced(store) == earlier)
    let held = try #require(report.heldBecause)
    #expect(!held.contains("first"), "a source with objects has had its first read")
    #expect(SyncSchedule.Outcome(read: report.read, changed: report.changed, heldBecause: report.heldBecause) == .held(read: 0, changed: 0, reason: held))
}

@Test("a sync that moved the date comes out as finished, with nothing held")
func advancedReadIsFinished() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let report = try await syncer(store).run(source.id, fetch: { _ in SourceSync.Fetched(objects: [note("new")]) })

    #expect(report.heldBecause == nil)
    #expect(SyncSchedule.Outcome(read: report.read, changed: report.changed, heldBecause: report.heldBecause) == .finished(read: 1, changed: 1))
}

// MARK: - A read that fell short

@Test("a first read that falls short sets no date, so the next one starts from the beginning")
func shortFirstReadSetsNoDate() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let report = try await syncer(store).run(source.id, fetch: { _ in
        SourceSync.Fetched(objects: [note("first")], unread: ["something else could not be read"])
    })

    #expect(report.changed == 1)
    #expect(try await lastSynced(store) == nil)
    #expect(try await store.incrementalStart(for: source.id) == nil)
}

// The bug: a root on an unplugged volume was logged and skipped, and the read still moved the date,
// so on the day the volume came back everything on it older than that date was passed over.
@Test("a root that is not there holds the date, and its files arrive when it returns")
func missingRootHoldsTheDate() async throws {
    let store = try await temporaryStore()
    let here = try temporaryFolder()
    let away = try temporaryFolder()
    try write("always here", to: here.appendingPathComponent("here.md"))
    let stranded = away.appendingPathComponent("stranded.md")
    try write("written before the volume went", to: stranded, modified: Date().addingTimeInterval(-3_600))
    let parked = try temporaryFolder().appendingPathComponent("parked")
    try FileManager.default.moveItem(at: away, to: parked)

    let connector = FilesystemConnector(handle: "volumes", roots: [.init(url: here, domain: .project), .init(url: away, domain: .project)])
    try await store.upsert(connector.source)
    // Built from the 1970 value because that is what the column stores. A date from `Date()` lost its
    // last bit on the way back about half the time, which failed the `==` below on a date that never moved.
    let earlier = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 7_200)
    try await store.ingest([CoreObject(sourceID: connector.source.id, kind: .file, externalID: "seen", title: "seen", text: "seen", domain: .project, authority: .authoredArtifact)])
    try await store.markSynced(connector.source.id, at: earlier, cursor: nil)

    func read() async throws -> SourceSync.Report {
        try await syncer(store).run(connector.source.id, fetch: { since in try await connector.fetch(since: since, cursor: nil) { _ in } })
    }

    let gone = try await read()
    #expect(!gone.advanced)
    #expect(try await lastSynced(store, connector.source.id) == earlier)

    try FileManager.default.moveItem(at: parked, to: away)
    let back = try await read()
    #expect(back.advanced)
    #expect(try await store.allObjects().contains { $0.externalID.hasSuffix("stranded.md") })
}

// Guards the one above: a root that went on being present must still let the date move.
@Test("a folder read in full moves the date")
func fullFolderAdvances() async throws {
    let store = try await temporaryStore()
    let folder = try temporaryFolder()
    try write("readable", to: folder.appendingPathComponent("fine.md"))
    let connector = FilesystemConnector(handle: "fine", roots: [.init(url: folder, domain: .project)])
    try await store.upsert(connector.source)

    let report = try await syncer(store).run(connector.source.id, fetch: { since in try await connector.fetch(since: since, cursor: nil) { _ in } })

    #expect(report.advanced)
    #expect(report.unread.isEmpty)
}

// The bug: `try?` around the read counted a file that could not be opened as non-text, so a read
// that missed it reported success. A PDF as well, because that path has no error to read: without
// the check before it, a failure there looks the same as a PDF with no text in it.
@Test("a file that can't be opened is unread, and bytes that aren't text are not")
func unreadableIsNotBinary() async throws {
    let folder = try temporaryFolder()
    for name in ["locked.md", "locked.pdf"] {
        let locked = folder.appendingPathComponent(name)
        try write("no permission", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    }
    defer {
        for name in ["locked.md", "locked.pdf"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
    }

    let batch = try await FilesystemConnector(handle: "perm", roots: [.init(url: folder, domain: .project)]).fetch(since: nil, cursor: nil) { _ in }
    #expect(batch.unread.count == 1)
    #expect(batch.unread.first?.hasPrefix("2 ") == true)
    #expect(batch.unread.first?.contains("locked") == true)

    let notUTF8 = try temporaryFolder().appendingPathComponent("latin.md")
    try Data([0xFF, 0xFE, 0x80, 0x41]).write(to: notUTF8)
    let text = try await FilesystemConnector(handle: "bytes", roots: [.init(url: notUTF8, domain: .project)]).fetch(since: nil, cursor: nil) { _ in }
    #expect(text.unread.isEmpty, "these bytes will not change, so holding the date for them would hold it forever")
    #expect(text.objects.isEmpty)
}

@Test("the error for bytes that aren't text is told apart from one for a file that can't be read")
func notTextIsRecognised() throws {
    let bytes = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-bytes-\(UUID().uuidString).md")
    try Data([0xFF, 0xFE, 0x80, 0x41]).write(to: bytes)
    defer { try? FileManager.default.removeItem(at: bytes) }
    #expect(throws: (any Error).self) { _ = try String(contentsOf: bytes, encoding: .utf8) }
    do {
        _ = try String(contentsOf: bytes, encoding: .utf8)
    } catch {
        #expect(FilesystemConnector.isNotText(error))
    }
    do {
        _ = try String(contentsOf: bytes.appendingPathExtension("gone"), encoding: .utf8)
        Issue.record("a file that is not there read as text")
    } catch {
        #expect(!FilesystemConnector.isNotText(error))
    }
}

// The walk used to carry on past a folder it could not enter as though the folder were empty.
@Test("a folder the walk can't enter is unread")
func unenterableFolderIsUnread() async throws {
    let folder = try temporaryFolder()
    let shut = folder.appendingPathComponent("shut", isDirectory: true)
    try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
    try write("inside", to: shut.appendingPathComponent("inside.md"))
    try write("outside", to: folder.appendingPathComponent("outside.md"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: shut.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path) }

    let batch = try await FilesystemConnector(handle: "shut", roots: [.init(url: folder, domain: .project)]).fetch(since: nil, cursor: nil) { _ in }

    #expect(batch.objects.count == 1)
    #expect(batch.unread.first?.contains("shut") == true)
}

@Test("an empty incremental sync moves the date, because it looked and found nothing")
func emptyIncrementalAdvances() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    try await store.ingest([note("held")])
    try await store.markSynced(source.id, at: Date(timeIntervalSince1970: 1_700_000_000), cursor: nil)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let report = try await syncer(store, clock: { now }).run(source.id, fetch: { _ in SourceSync.Fetched(objects: []) })

    #expect(report.advanced)
    #expect(try await lastSynced(store) == now)
}

// The bug: the date was taken after the read and the derivation finished. Connectors skip
// `modified < since`, so a file changed behind the walker was older than the date and no later
// sync would ever pick it up. Notes can take minutes to answer, which makes this a wide window.
@Test("something changed while a read runs is picked up by the next sync")
func changeDuringTheReadIsNotLost() async throws {
    let store = try await temporaryStore()
    let folder = try temporaryFolder()
    let earlier = Date().addingTimeInterval(-3_600)
    try write("already there", to: folder.appendingPathComponent("first.md"), modified: earlier)
    let late = folder.appendingPathComponent("late.md")

    let connector = FilesystemConnector(handle: "race", roots: [.init(url: folder, domain: .project)])
    try await store.upsert(connector.source)

    let first = try await syncer(store).run(connector.source.id, fetch: { since in
        let batch = try await connector.fetch(since: since, cursor: nil) { _ in }
        // The walker has gone past. This lands while the sync is still working.
        try write("written during the read", to: late)
        return SourceSync.Fetched(objects: batch.objects, cursor: batch.cursor)
    })
    #expect(first.read == 1, "the first read must not have seen the late file, or this proves nothing")

    let second = try await syncer(store).run(connector.source.id, fetch: { since in
        let batch = try await connector.fetch(since: since, cursor: nil) { _ in }
        return SourceSync.Fetched(objects: batch.objects, cursor: batch.cursor)
    })

    #expect(second.read == 1)
    #expect(second.changed == 1)
}

@Test("the date recorded is when the read began")
func dateIsWhenTheReadBegan() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    let began = Date(timeIntervalSince1970: 1_800_000_000)

    let report = try await syncer(store, clock: { began }).run(source.id, fetch: { _ in SourceSync.Fetched(objects: [note("new")]) })

    #expect(report.startedAt == began)
    #expect(try await lastSynced(store) == began)
}

@Test("a full read starts from the beginning, however recent the last sync")
func everythingIgnoresTheDate() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    try await store.ingest([note("held")])
    try await store.markSynced(source.id, at: Date(), cursor: nil)

    let report = try await syncer(store).run(source.id, reach: .everything, fetch: { since in
        #expect(since == nil)
        return SourceSync.Fetched(objects: [])
    })
    #expect(report.since == nil)

    let incremental = try await syncer(store).run(source.id, fetch: { since in
        #expect(since != nil, "the same store with the default reach must be incremental")
        return SourceSync.Fetched(objects: [])
    })
    #expect(incremental.since != nil)
}

@Test("objects that come back identical do not count as a change")
func unchangedObjectsAreNotChanges() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    let object = note("same")

    let first = try await syncer(store).run(source.id, fetch: { _ in SourceSync.Fetched(objects: [object]) })
    let second = try await syncer(store).run(source.id, fetch: { _ in SourceSync.Fetched(objects: [object]) })

    #expect(first.changed == 1)
    #expect(second.read == 1)
    #expect(second.changed == 0)
}

@Test("the phases arrive in order, and each is awaited before work continues")
func phasesArriveInOrder() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    let seen = Seen()

    _ = try await syncer(store).run(
        source.id,
        phase: { await seen.add($0) },
        fetch: { _ in
            await seen.add(nil)
            return SourceSync.Fetched(objects: [note("one")])
        }
    )

    #expect(await seen.values == [.fetching(since: nil), nil, .deriving(objects: 1)])
}

private actor Seen {
    var values: [SourceSync.Phase?] = []
    func add(_ phase: SourceSync.Phase?) { values.append(phase) }
}

// The bug: `Store.ingest` rebuilt the stored date and compared it. A file's mtime is a `Date` built
// from seconds since 2001, and it does not survive the trip through the 1970-based column, so 33 of
// 102 real mtimes came back unequal. Those files read as changed on every re-read, and each one had
// presentation history written onto the floor though nothing had happened to it. Found because a
// test here dropped the same two files twice and one of them came back changed.
@Test("an unchanged object with a sub-second date stays unchanged, and gains no history")
func subSecondDatesDoNotReadAsChanges() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    let dated = (0..<64).map { index in
        CoreObject(
            sourceID: source.id, kind: .file, externalID: "file-\(index)", title: "file", text: "same text",
            authoredAt: Date(timeIntervalSinceReferenceDate: 700_000_000.123456789 + Double(index) * 0.000_137),
            domain: .project, authority: .authoredArtifact
        )
    }
    let lossy = dated.filter { Date(timeIntervalSince1970: $0.authoredAt!.timeIntervalSince1970) != $0.authoredAt }
    #expect(!lossy.isEmpty, "every date survives the round trip, so this proves nothing")

    try await store.ingest(dated)
    let again = try await store.ingest(dated)

    #expect(again.unchanged == dated.count)
    #expect(again.updated == 0)
    for object in dated {
        #expect(try await store.object(object.id)?.metadata[ObjectPresentation.metadataKey] == nil)
    }
}

// A real change must still register: this comparison exists to notice one.
@Test("a date that really moved still counts as a change")
func movedDateIsAChange() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)
    func object(_ date: Date?) -> CoreObject {
        CoreObject(sourceID: source.id, kind: .file, externalID: "moved", title: "file", text: "same text", authoredAt: date, domain: .project, authority: .authoredArtifact)
    }

    try await store.ingest([object(Date(timeIntervalSinceReferenceDate: 700_000_000.25))])

    #expect(try await store.ingest([object(Date(timeIntervalSinceReferenceDate: 700_000_001.25))]).updated == 1)
    #expect(try await store.ingest([object(nil)]).updated == 1)
}

// MARK: - A full calendar re-read

private let calendar = AppleEventKitConnector(scope: .calendar).source

private func event(accepted: [String]?) -> CoreObject {
    var metadata = ["attendees": "Ada\u{1F}Grace\u{1F}Alan", "attendee_count": "3"]
    if let accepted { metadata["attendees_accepted"] = accepted.joined(separator: "\u{1F}") }
    return CoreObject(
        sourceID: calendar.id, kind: .calendarEvent, externalID: "event:old",
        title: "Design review", text: "Design review\nInvited: 3",
        authoredAt: Date(timeIntervalSince1970: 1_754_000_000),
        domain: .personal, authority: .authoredArtifact, metadata: metadata
    )
}

// The bug: all 565 events on the real store were ingested before `attendees_accepted` existed, and
// the calendar's `since` meant 450 of them were never read again, so 0 attended claims existed.
// A re-read has identical text and differs only in metadata, which is the case a content hash
// alone would have thrown away. Asserts the whole trip: field on the floor, then a claim from it.
@Test("a full calendar re-read lands attendance on an event that is already stored")
func fullReadLandsAttendance() async throws {
    let store = try await temporaryStore()
    try await store.upsert(calendar)

    _ = try await syncer(store).run(calendar.id, fetch: { _ in SourceSync.Fetched(objects: [event(accepted: nil)]) })
    #expect(try await store.allClaims(currentOnly: true, limit: 100).allSatisfy { $0.predicate != Predicate.attended })

    let report = try await syncer(store).run(calendar.id, reach: .everything, fetch: { since in
        #expect(since == nil)
        return SourceSync.Fetched(objects: [event(accepted: ["Ada", "Grace"])])
    })

    #expect(report.changed == 1, "a metadata-only difference is a change")
    #expect(try await store.object(event(accepted: nil).id)?.metadata["attendees_accepted"] == "Ada\u{1F}Grace")
    let attended = try await store.allClaims(currentOnly: true, limit: 100).filter { $0.predicate == Predicate.attended }
    #expect(!attended.isEmpty)
}

// The bug: filtering by modification date alone. An event created months ago that has just entered
// the look-ahead was past the end of the window at the last sync, so it was never read, and its old
// modification date would keep it unread on every sync until someone edited it.
@Test("an old event that has just entered the look-ahead is read, though nothing modified it")
func eventEnteringTheWindowIsRead() {
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    let lookAhead: TimeInterval = 180 * 86_400
    let longAgo = since.addingTimeInterval(-300 * 86_400)
    let lastWindowEnd = since.addingTimeInterval(lookAhead)

    #expect(AppleEventKitConnector.shouldRead(lastModified: longAgo, start: lastWindowEnd.addingTimeInterval(3_600), since: since, lookAhead: lookAhead))
    #expect(AppleEventKitConnector.shouldRead(lastModified: longAgo, start: lastWindowEnd, since: since, lookAhead: lookAhead), "the edge of the window counts")
}

// Guards the test above: without this, reading everything would pass it.
@Test("an old event the last sync could already see is not read again")
func eventInsideTheOldWindowIsSkipped() {
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    let lookAhead: TimeInterval = 180 * 86_400
    let longAgo = since.addingTimeInterval(-300 * 86_400)

    #expect(!AppleEventKitConnector.shouldRead(lastModified: longAgo, start: since.addingTimeInterval(lookAhead - 3_600), since: since, lookAhead: lookAhead))
    #expect(!AppleEventKitConnector.shouldRead(lastModified: longAgo, start: longAgo, since: since, lookAhead: lookAhead))
    #expect(!AppleEventKitConnector.shouldRead(lastModified: longAgo, start: nil, since: since, lookAhead: lookAhead))
}

@Test("a modified event, an unknown date and a full read are all read")
func modifiedEventsAreRead() {
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    let start = since.addingTimeInterval(-86_400)

    #expect(AppleEventKitConnector.shouldRead(lastModified: since.addingTimeInterval(60), start: start, since: since, lookAhead: 0))
    #expect(AppleEventKitConnector.shouldRead(lastModified: nil, start: start, since: since, lookAhead: 0))
    #expect(AppleEventKitConnector.shouldRead(lastModified: since.addingTimeInterval(-60), start: start, since: nil, lookAhead: 0))
}

// MARK: - Files handed over

private func oldFile(in folder: URL, named name: String = "old.md") throws -> URL {
    let url = folder.appendingPathComponent(name)
    try write("written long ago", to: url, modified: Date().addingTimeInterval(-90 * 86_400))
    return url
}

// The bug: multi-file drops share the `dropped-files` source, so a file last modified before the
// previous drop was skipped and the screen said 0 new or modified items.
@Test("a dropped file older than the last drop is still read")
func droppedOldFileIsRead() async throws {
    let folder = try temporaryFolder()
    let files = [try oldFile(in: folder), try oldFile(in: folder, named: "older.md")]
    let connector = FilesystemConnector.handedOver(files: files, domain: .project)

    let batch = try await connector.fetch(since: Date(), cursor: nil) { _ in }

    #expect(batch.objects.count == 2)
}

// Guards the test above: this is the skip the drop has to get around, and it stays right for a
// scheduled sync of a folder that nobody touched.
@Test("an ordinary sync still skips a file older than its date")
func ordinarySyncHonoursTheDate() async throws {
    let folder = try temporaryFolder()
    let file = try oldFile(in: folder)
    let connector = FilesystemConnector(handle: "plain", roots: [.init(url: file, domain: .project)])

    let batch = try await connector.fetch(since: Date(), cursor: nil) { _ in }

    #expect(batch.objects.isEmpty)
}

@Test("a folder handed over is read in full, even one sharing a name with an earlier folder")
func handedOverFolderIgnoresTheDate() async throws {
    let folder = try temporaryFolder()
    _ = try oldFile(in: folder)

    let batch = try await FilesystemConnector.handedOver(folder: folder, domain: .project)
        .fetch(since: Date(), cursor: nil) { _ in }

    #expect(batch.objects.count == 1)
}

@Test("dropping the same file twice through a real sync reads it and changes nothing")
func redropChangesNothing() async throws {
    let store = try await temporaryStore()
    let folder = try temporaryFolder()
    let files = [try oldFile(in: folder), try oldFile(in: folder, named: "older.md")]
    let connector = FilesystemConnector.handedOver(files: files, domain: .project)
    try await store.upsert(connector.source)

    func drop() async throws -> SourceSync.Report {
        try await syncer(store).run(connector.source.id, fetch: { since in
            let batch = try await connector.fetch(since: since, cursor: nil) { _ in }
            return SourceSync.Fetched(objects: batch.objects, cursor: batch.cursor)
        })
    }

    #expect(try await drop().changed == 2)
    let again = try await drop()
    #expect(again.since != nil, "the second drop has a date to ignore, or this proves nothing")
    #expect(again.read == 2)
    #expect(again.changed == 0)
}

// MARK: - EventKit access

// The bug: a request raised by a scheduled tick does not return until someone answers it. With
// nobody at the Mac that held the sync lane, and every other source went stale behind it.
@Test("an unattended sync never raises a permission prompt")
func unattendedNeverPrompts() {
    for status in [EKAuthorizationStatus.notDetermined, .writeOnly] {
        #expect(throws: AppleEventKitConnector.AccessError.self) {
            _ = try AppleEventKitConnector.mustRequestAccess(status: status, scope: .calendar, unattended: true)
        }
    }
}

@Test("a sync someone started can ask, and full access needs no asking from anyone")
func attendedMayPrompt() throws {
    #expect(try AppleEventKitConnector.mustRequestAccess(status: .notDetermined, scope: .reminders, unattended: false))
    #expect(try AppleEventKitConnector.mustRequestAccess(status: .writeOnly, scope: .calendar, unattended: false))
    #expect(try !AppleEventKitConnector.mustRequestAccess(status: .fullAccess, scope: .calendar, unattended: true))
    #expect(try !AppleEventKitConnector.mustRequestAccess(status: .fullAccess, scope: .calendar, unattended: false))
}

@Test("a denied source fails whoever asks, and says it was denied")
func deniedFailsEveryone() {
    for status in [EKAuthorizationStatus.denied, .restricted] {
        for unattended in [true, false] {
            #expect {
                _ = try AppleEventKitConnector.mustRequestAccess(status: status, scope: .reminders, unattended: unattended)
            } throws: { error in
                guard case AppleEventKitConnector.AccessError.denied = error else { return false }
                return true
            }
        }
    }
}

// The bug: `reminders ?? []` turned EventKit's nil, which its header documents, into an empty
// list. A read that returned nothing reported success and moved the sync date.
@Test("a reminders read that returns no list is a failure, and an empty list is not")
func nilReadIsAFailure() throws {
    let unread: [Int]? = nil
    #expect(throws: AppleEventKitConnector.AccessError.self) {
        _ = try AppleEventKitConnector.requireRead(unread, scope: .reminders)
    }
    #expect(try AppleEventKitConnector.requireRead([Int](), scope: .reminders).isEmpty)
}
