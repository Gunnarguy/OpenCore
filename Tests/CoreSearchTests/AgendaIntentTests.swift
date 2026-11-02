import CoreSearch
import Foundation
import Testing

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2 // Monday
    return calendar
}()

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

// A Friday afternoon, so a week has both a past and a future.
private let now = date("2026-10-30T15:00:00Z")

private func read(_ question: String) -> AgendaQuestion? { AgendaIntent.read(question, now: now, calendar: calendar) }

@Test("a calendar week runs to its end, because a calendar holds what has not happened yet")
func calendarWeekReachesAhead() throws {
    let question = try #require(read("What is on my calendar this week?"))
    #expect(question.readsCalendar)
    #expect(!question.readsReminders)
    #expect(question.window?.start == date("2026-10-26T00:00:00Z"))
    #expect(question.window?.end == date("2026-11-02T00:00:00Z"))
    #expect(question.terms.isEmpty)
}

@Test("spans ahead of today read as the days they name", arguments: [
    ("what's on my calendar today", "2026-10-30T00:00:00Z", "2026-10-31T00:00:00Z"),
    ("what's on my calendar tomorrow", "2026-10-31T00:00:00Z", "2026-11-01T00:00:00Z"),
    ("what's on my calendar next week", "2026-11-02T00:00:00Z", "2026-11-09T00:00:00Z"),
    ("what's on my calendar next month", "2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z"),
    ("what's on my calendar next Tuesday", "2026-11-03T00:00:00Z", "2026-11-04T00:00:00Z"),
    ("what's on my calendar on Friday", "2026-10-30T00:00:00Z", "2026-10-31T00:00:00Z"),
    ("what's on my calendar on November 5th", "2026-11-05T00:00:00Z", "2026-11-06T00:00:00Z"),
    ("what's on my calendar in the next 3 days", "2026-10-30T00:00:00Z", "2026-11-02T00:00:00Z"),
])
func forwardSpans(question: String, start: String, end: String) throws {
    let window = try #require(read(question)?.window)
    #expect(window.start == date(start))
    #expect(window.end == date(end))
}

@Test("a calendar question naming no date looks a chosen fortnight ahead, and says it chose")
func noDateIsAChosenSpan() throws {
    let window = try #require(read("what's on my schedule")?.window)
    #expect(window.start == date("2026-10-30T00:00:00Z"))
    #expect(window.end == date("2026-11-13T00:00:00Z"))
    #expect(window.isChosen)
}

@Test("a past phrase on a calendar question still reads backwards")
func pastPhraseStillWorks() throws {
    let window = try #require(read("what was on my calendar last week")?.window)
    #expect(window.start == date("2026-10-19T00:00:00Z"))
    #expect(window.end == date("2026-10-26T00:00:00Z"))
}

@Test("open reminders with no date named are all of them, not a window")
func remindersHaveNoDefaultWindow() throws {
    let question = try #require(read("What reminders do I have open?"))
    #expect(question.readsReminders)
    #expect(!question.readsCalendar)
    #expect(question.window == nil)
    #expect(question.terms.isEmpty)
    #expect(!question.wantsCompleted)
}

@Test("a named list becomes the word to match, and the frame around it does not")
func namedListIsATerm() throws {
    let question = try #require(read("What's on my grocery list?"))
    #expect(question.readsReminders)
    #expect(question.terms == ["grocery"])
}

@Test("a birthday question needs no first person, and the words left must all match an event")
func birthdayNeedsNoFirstPerson() throws {
    let question = try #require(read("When is Nathan's birthday?"))
    #expect(question.readsCalendar)
    #expect(question.terms == ["nathan", "birthday"])
    #expect((question.window?.end ?? now) > date("2027-10-01T00:00:00Z"))
}

@Test("a dentist appointment keeps dentist, and a plural finds a singular title")
func topicsAreKept() throws {
    #expect(read("when is my dentist appointment")?.terms == ["dentist"])
    #expect(read("what birthdays are coming up this week")?.terms == ["birthday"])
}

@Test("what's due has no first person and still reads reminders")
func dueReadsReminders() throws {
    let question = try #require(read("What's due this week?"))
    #expect(question.readsReminders)
    #expect(question.window != nil)
}

@Test("a question about finished reminders is not a question about open ones")
func completedIsRead() throws {
    #expect(read("what reminders did I complete last week")?.wantsCompleted == true)
}

// These reached the owner's reminders while a project was what they asked about, or would have.
@Test("questions about software or projects are left to ordinary retrieval", arguments: [
    "How does OpenCore sync reminders?",
    "Why did I add the calendar connector?",
    "Which project handles appointments?",
    "What did I decide about retrieval?",
    "What is the status of OpenClinic?",
    "What have I been working on lately?",
    "does the calendar have a bug",
])
func softwareQuestionsAreNotAgenda(question: String) {
    #expect(read(question) == nil)
}

// The bug: neither phrase had a reading, so "what did I do last Tuesday" searched all of time and
// answered with a repository's language.
@Test("last Tuesday is the most recent Tuesday, one whole day")
func lastWeekdayIsADay() throws {
    let window = try #require(TemporalIntent.window(in: "what did I do last Tuesday", now: now, calendar: calendar))
    #expect(window.start == date("2026-10-27T00:00:00Z"))
    #expect(window.end == date("2026-10-28T00:00:00Z"))
    #expect(window.residualQuery == "what did I do")
}

@Test("the last Monday of something is a position, not last Monday")
func lastWeekdayOfIsNotRead() {
    #expect(TemporalIntent.window(in: "the last Monday of the sprint", now: now, calendar: calendar) == nil)
}
