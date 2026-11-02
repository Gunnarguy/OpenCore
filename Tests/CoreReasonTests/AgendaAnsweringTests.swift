import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Testing
@testable import CoreReason

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private let now = date("2026-10-30T15:00:00Z")

private let events = Source(kind: .calendar, handle: "calendar", displayName: "Apple Calendar",
                            defaultAuthority: .authoredArtifact, defaultDomain: .personal)
private let reminders = Source(kind: .calendar, handle: "reminders", displayName: "Apple Reminders",
                               defaultAuthority: .authoredArtifact, defaultDomain: .personal)

private func event(_ title: String, at start: String, calendarName: String = "Home", allDay: Bool = false) -> CoreObject {
    CoreObject(sourceID: events.id, kind: .calendarEvent, externalID: "event:\(title):\(calendarName):\(start)", title: title,
               text: "\(title)\nStarts: \(start)", authoredAt: date(start), domain: .personal, authority: .authoredArtifact,
               metadata: ["calendar": calendarName, "all_day": String(allDay), "attendee_count": "0"])
}

private func reminder(_ title: String, due: String?, list: String = "Errands", completed: Bool = false) -> CoreObject {
    CoreObject(sourceID: reminders.id, kind: .note, externalID: "reminder:\(title)", title: title,
               text: "\(title)\nStatus: \(completed ? "completed" : "open")", authoredAt: due.map(date),
               domain: .personal, authority: .authoredArtifact,
               metadata: ["list": list, "priority": "0", "completed": String(completed)])
}

private struct Fixture {
    let store: Store
    let directory: URL
    var reasoner: Reasoner { Reasoner(store: store, now: now, calendar: calendar) }

    static func make(syncedAt synced: Date = now) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-agenda-\(UUID().uuidString)")
        let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
        try await store.upsert(events)
        try await store.upsert(reminders)
        try await store.markSynced(events.id, at: synced, cursor: nil)
        try await store.markSynced(reminders.id, at: synced, cursor: nil)
        _ = try await store.ingest([
            event("Dentist QUILLBERRY", at: "2026-10-31T17:00:00Z"),
            event("Election Day", at: "2026-10-31T00:00:00Z", calendarName: "US Holidays", allDay: true),
            event("Election Day", at: "2026-10-31T00:00:00Z", calendarName: "United States holidays", allDay: true),
            event("Long gone", at: "2026-01-05T17:00:00Z"),
            reminder("Pay the loan", due: "2026-10-20T00:00:00Z"),
            reminder("Buy salmon", due: nil, list: "Grocery"),
            reminder("Book flights", due: "2026-11-20T00:00:00Z"),
            reminder("Already sorted", due: "2026-10-29T00:00:00Z", completed: true),
        ])
        return Fixture(store: store, directory: directory)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

// The bug: objects are all these sources produce, and answers were built from claims. On the real
// store "what is on my calendar this week" answered with a project's last commit, and "what
// reminders do I have open" with 69 claims about repositories, with 565 events and 251 open
// reminders sitting in the store.
@Test("the owner's calendar answers from its events, including days that have not happened")
func calendarAnswersFromEvents() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What is on my calendar this week?", persistReceipt: false)
    let agenda = try #require(answer.agenda)
    #expect(agenda.events.map(\.title).contains("Dentist QUILLBERRY"))
    #expect(answer.summary.contains("Sat 2026-10-31  5:00 PM  Dentist QUILLBERRY"))
    #expect(!answer.summary.contains("Long gone"))
    #expect(answer.receipt.model == nil)
    #expect(answer.receipt.stages.map(\.name) == ["agenda"])
}

@Test("one day's holiday carried by two calendars is one line")
func repeatedHolidayIsOneLine() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What is on my calendar this week?", persistReceipt: false)
    #expect(try #require(answer.agenda).events.filter { $0.title == "Election Day" }.count == 1)
}

@Test("open reminders lead with what is overdue, keep undated ones, and leave out finished ones")
func remindersListOpenOnes() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What reminders do I have open?", persistReceipt: false)
    let agenda = try #require(answer.agenda)
    #expect(agenda.reminders.map(\.title) == ["Pay the loan", "Book flights", "Buy salmon"])
    #expect(answer.summary.contains("Open reminders: 3, 1 overdue."))
    #expect(answer.summary.contains("OVERDUE   Tue 2026-10-20  Pay the loan (Errands)"))
    // A due date has no time of its own, and midnight is how that arrives.
    #expect(!answer.summary.contains("12:00 AM"))
    #expect(!answer.summary.contains("Already sorted"))
}

@Test("a named list reads only that list")
func namedListFilters() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What's on my grocery list?", persistReceipt: false)
    #expect(try #require(answer.agenda).reminders.map(\.title) == ["Buy salmon"])
}

@Test("what is due this week keeps what is overdue and leaves out what is due later")
func dueWeekKeepsOverdue() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What's due this week?", persistReceipt: false)
    #expect(try #require(answer.agenda).reminders.map(\.title) == ["Pay the loan"])
}

@Test("finished reminders are asked for by name, and only then read")
func completedRemindersAreRead() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What reminders did I complete this week?", persistReceipt: false)
    #expect(try #require(answer.agenda).reminders.map(\.title) == ["Already sorted"])
}

// A list from a source that stopped syncing reads exactly like a quiet fortnight. The real calendar
// had last synced 80 days before the question.
@Test("a stale source says so under its list", arguments: [true, false])
func staleSourceSaysSo(stale: Bool) async throws {
    let fixture = try await Fixture.make(syncedAt: stale ? date("2026-08-14T12:00:00Z") : now); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What is on my calendar this week?", persistReceipt: false)
    #expect(answer.summary.contains("Apple Calendar last synced 2026-08-14") == stale)
}

// These sources are personal. A model's wording is not the owner's, however it is put.
@Test("an MCP caller gets no agenda and nothing from these sources")
func externalCallerIsRefused() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What is on my calendar this week?", externalCaller: true, persistReceipt: false)
    #expect(answer.agenda == nil)
    #expect(!answer.summary.contains("QUILLBERRY"))
    #expect(!answer.receipt.domainsAdmitted.contains(.personal))
}

@Test("a phone limited to project data gets no agenda", arguments: [true, false])
func domainCeilingHolds(chat: Bool) async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let ceiling: Set<Domain> = [.project, .publicRecord]
    if chat {
        let conversation = Conversation(store: fixture.store, now: now, calendar: calendar, persistHistory: false, maximumDomains: ceiling)
        var last: Turn?
        for await turn in conversation.send("What is on my calendar this week?") { last = turn }
        #expect(last?.text.contains("QUILLBERRY") == false)
    } else {
        let answer = try await fixture.reasoner.answer("What is on my calendar this week?", persistReceipt: false, maximumDomains: ceiling)
        #expect(answer.agenda == nil)
        #expect(!answer.summary.contains("QUILLBERRY"))
    }
}

@Test("an owner who chose the project scope is not read their calendar")
func chosenScopeWins() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let answer = try await fixture.reasoner.answer("What is on my calendar this week?", persistReceipt: false, ownerDomain: .project)
    #expect(answer.agenda == nil)
}

@Test("chat gives the owner the same list, with no model involved")
func chatAnswersFromEvents() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let conversation = Conversation(store: fixture.store, now: now, calendar: calendar, persistHistory: false)
    var last: Turn?
    for await turn in conversation.send("What is on my calendar this week?") { last = turn }
    let turn = try #require(last)
    #expect(turn.text.contains("Dentist QUILLBERRY"))
    #expect(turn.receipt?.model == nil)
    #expect(turn.receipt?.stages.map(\.name) == ["agenda"])
}

// The Ask screen opens on this, so it is the first thing the owner reads each day.
@Test("today splits today from tomorrow and what is due from what is overdue")
func todaySplitsItsParts() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    _ = try await fixture.store.ingest([event("Tonight", at: "2026-10-30T18:00:00Z"), reminder("Due tomorrow", due: "2026-10-31T09:00:00Z")])
    let owner = AdmissionPolicy(queryDomain: .personal)
    let today = try #require(try await AgendaAnswering(store: fixture.store).today(policy: owner, now: now, calendar: calendar))
    #expect(today.today.map(\.title) == ["Tonight"])
    #expect(today.tomorrow.map(\.title).contains("Dentist QUILLBERRY"))
    #expect(today.due.map(\.title) == ["Due tomorrow"])
    #expect(today.overdue.map(\.title) == ["Pay the loan"])
    #expect(today.notices.isEmpty)
}

@Test("today shows nothing to a surface without personal admission")
func todayRespectsAdmission() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let project = AdmissionPolicy(queryDomain: .project)
    #expect(try await AgendaAnswering(store: fixture.store).today(policy: project, now: now, calendar: calendar) == nil)
}
