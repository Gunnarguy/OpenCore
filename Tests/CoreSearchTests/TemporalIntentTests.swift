import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Testing

/// The bug: "recently" was a stopword and `.temporal` added at most 0.00015 to a score, so a
/// question about a stretch of time searched all of time. These fix what each phrase means.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2 // Monday
    return calendar
}()

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)!
}

// A Friday, so "this week" and "last week" differ from a rolling seven days.
private let now = date("2026-10-30T15:00:00Z")

@Test("recently means a chosen two weeks ending now")
func recentlyIsAWindow() throws {
    let window = try #require(TemporalIntent.window(in: "What was I working on recently?", now: now, calendar: calendar))
    #expect(window.start == date("2026-10-16T15:00:00Z"))
    #expect(window.end == now)
    #expect(window.phrase == "recently")
}

@Test("last week is the previous calendar week, not the last seven days")
func lastWeekIsCalendarWeek() throws {
    let window = try #require(TemporalIntent.window(in: "what did I do last week", now: now, calendar: calendar))
    #expect(window.start == date("2026-10-19T00:00:00Z"))
    #expect(window.end == date("2026-10-26T00:00:00Z"))
}

@Test("this week runs from the start of the week to now")
func thisWeekEndsNow() throws {
    let window = try #require(TemporalIntent.window(in: "what changed this week", now: now, calendar: calendar))
    #expect(window.start == date("2026-10-26T00:00:00Z"))
    #expect(window.end == now)
}

@Test("spelled-out spans read numbers and number words")
func rollingSpans() throws {
    let days = try #require(TemporalIntent.window(in: "commits in the last 3 days", now: now, calendar: calendar))
    #expect(days.start == date("2026-10-27T15:00:00Z"))
    let weeks = try #require(TemporalIntent.window(in: "the past two weeks", now: now, calendar: calendar))
    #expect(weeks.start == date("2026-10-16T15:00:00Z"))
}

@Test("n units ago means the unit it lands in")
func agoIsAUnit() throws {
    let window = try #require(TemporalIntent.window(in: "what happened 2 weeks ago", now: now, calendar: calendar))
    #expect(window.start == date("2026-10-12T00:00:00Z"))
    #expect(window.end == date("2026-10-19T00:00:00Z"))
}

@Test("a month with no year is its most recent occurrence")
func monthIsMostRecent() throws {
    let march = try #require(TemporalIntent.window(in: "what was I doing in March", now: now, calendar: calendar))
    #expect(march.start == date("2026-03-01T00:00:00Z"))
    let november = try #require(TemporalIntent.window(in: "what was I doing in November", now: now, calendar: calendar))
    #expect(november.start == date("2025-11-01T00:00:00Z"))
    let dated = try #require(TemporalIntent.window(in: "back in March 2024", now: now, calendar: calendar))
    #expect(dated.start == date("2024-03-01T00:00:00Z"))
}

@Test("a question with no time phrase has no window")
func noPhraseNoWindow() {
    #expect(TemporalIntent.window(in: "What is OpenCone?", now: now, calendar: calendar) == nil)
    #expect(TemporalIntent.window(in: "Which of my apps is written in Swift?", now: now, calendar: calendar) == nil)
    // A bare "since" is usually "because".
    #expect(TemporalIntent.window(in: "why did it fail since the fix landed", now: now, calendar: calendar) == nil)
    // Not the word "may".
    #expect(TemporalIntent.window(in: "what may break in this project", now: now, calendar: calendar) == nil)
}

@Test("time words leave the search text, and a question with no subject is known to have none")
func residualDropsTimeWords() throws {
    let framing = try #require(TemporalIntent.window(in: "What was I working on recently?", now: now, calendar: calendar))
    #expect(!framing.residualQuery.lowercased().contains("recently"))
    #expect(TemporalIntent.isSubjectless(framing.residualQuery))

    let topical = try #require(TemporalIntent.window(in: "what changed in retrieval last week", now: now, calendar: calendar))
    #expect(!topical.residualQuery.lowercased().contains("last week"))
    #expect(!TemporalIntent.isSubjectless(topical.residualQuery))
}

private func store() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-window-\(UUID().uuidString)/store.sqlite"))
}

// The bug: nothing in search looked at a date, so an old passage that matched the words outranked
// a new one that matched the question.
@Test("a date window keeps older passages out of retrieval, whatever they score")
func searchFiltersByWindow() async throws {
    let store = try await store()
    let source = Source(kind: .filesystem, handle: "docs", displayName: "Docs", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let old = CoreObject(sourceID: source.id, kind: .document, externalID: "old", title: "retrieval retrieval retrieval", text: "retrieval retrieval retrieval retrieval", authoredAt: date("2024-01-01T00:00:00Z"), domain: .project, authority: .authoredArtifact)
    let new = CoreObject(sourceID: source.id, kind: .document, externalID: "new", title: "notes", text: "a note that mentions retrieval once", authoredAt: date("2026-10-28T00:00:00Z"), domain: .project, authority: .authoredArtifact)
    let undated = CoreObject(sourceID: source.id, kind: .document, externalID: "undated", title: "undated", text: "retrieval with no date on it", domain: .project, authority: .authoredArtifact)
    try await store.ingest([old, new, undated])
    let chunker = Chunker()
    try await store.save([old, new, undated].flatMap { chunker.chunks(for: $0) })

    let search = PassageSearch(store: store)
    let policy = AdmissionPolicy(queryDomain: .project)
    let all = try await search.search(query: "retrieval", queryClass: .factual, policy: policy)
    #expect(all.hits.contains { $0.object.id == old.id })

    let window = DateInterval(start: date("2026-10-01T00:00:00Z"), end: now)
    let windowed = try await search.search(query: "retrieval", queryClass: .temporal, policy: policy, window: window)
    #expect(windowed.hits.map(\.object.id) == [new.id])
}

// MARK: - Absolute windows

// The bug: "since" read ISO dates only, so "since August" had no window and searched all of time.
@Test("since a month starts at that month's most recent first day and ends now")
func sinceMonth() throws {
    let august = try #require(TemporalIntent.window(in: "what changed since August", now: now, calendar: calendar))
    #expect(august.start == date("2026-08-01T00:00:00Z"))
    #expect(august.end == now)
    #expect(august.phrase == "since August")

    // Not yet this year, so it means last year's. A window that started next month holds nothing.
    let november = try #require(TemporalIntent.window(in: "since november", now: now, calendar: calendar))
    #expect(november.start == date("2025-11-01T00:00:00Z"))

    let dated = try #require(TemporalIntent.window(in: "since August 2025", now: now, calendar: calendar))
    #expect(dated.start == date("2025-08-01T00:00:00Z"))

    let year = try #require(TemporalIntent.window(in: "since 2025", now: now, calendar: calendar))
    #expect(year.start == date("2025-01-01T00:00:00Z"))
}

// The bug: "last week" matched inside it, so the window closed a week ago instead of running to now.
@Test("since last week runs to now, where last week alone stops at the end of that week")
func sinceAPeriod() throws {
    let since = try #require(TemporalIntent.window(in: "what happened since last week", now: now, calendar: calendar))
    #expect(since.start == date("2026-10-19T00:00:00Z"))
    #expect(since.end == now)

    let start = try #require(TemporalIntent.window(in: "since the start of this month", now: now, calendar: calendar))
    #expect(start.start == date("2026-10-01T00:00:00Z"))

    let yesterday = try #require(TemporalIntent.window(in: "since yesterday", now: now, calendar: calendar))
    #expect(yesterday.start == date("2026-10-29T00:00:00Z"))
    #expect(yesterday.end == now)
}

@Test("since a weekday means the last one before today, even on that weekday")
func sinceWeekday() throws {
    let friday = try #require(TemporalIntent.window(in: "since Monday", now: now, calendar: calendar))
    #expect(friday.start == date("2026-10-26T00:00:00Z"))

    let onAMonday = date("2026-10-26T15:00:00Z")
    let window = try #require(TemporalIntent.window(in: "since Monday", now: onAMonday, calendar: calendar))
    #expect(window.start == date("2026-10-19T00:00:00Z"))
}

@Test("in a year is that year, and a date beginning with one is not")
func inYear() throws {
    let year = try #require(TemporalIntent.window(in: "what did I ship in 2025", now: now, calendar: calendar))
    #expect(year.start == date("2025-01-01T00:00:00Z"))
    #expect(year.end == date("2026-01-01T00:00:00Z"))

    // This year so far, not a window running to January.
    let current = try #require(TemporalIntent.window(in: "during 2026", now: now, calendar: calendar))
    #expect(current.end == now)

    #expect(TemporalIntent.window(in: "the bug in 2025-10 builds", now: now, calendar: calendar) == nil)
}

// The bug: the first "in" ended the search, so the month in this question was never reached.
@Test("a month is found past an earlier in")
func monthPastAnotherIn() throws {
    let window = try #require(TemporalIntent.window(in: "what changed in the repo in March", now: now, calendar: calendar))
    #expect(window.start == date("2026-03-01T00:00:00Z"))
    #expect(window.residualQuery == "what changed in the repo")
    #expect(TemporalIntent.window(in: "in the repo back in Oct", now: now, calendar: calendar)?.start == date("2026-10-01T00:00:00Z"))
}

// The bug: the first "last" ended the search, so "last commit" hid the span after it.
@Test("a span is found past an earlier last")
func spanPastAnotherLast() throws {
    let window = try #require(TemporalIntent.window(in: "the last commit in the past 3 days", now: now, calendar: calendar))
    #expect(window.start == date("2026-10-27T15:00:00Z"))
    #expect(TemporalIntent.window(in: "the last couple of weeks", now: now, calendar: calendar)?.start == date("2026-10-16T15:00:00Z"))
    #expect(TemporalIntent.window(in: "a couple of weeks ago", now: now, calendar: calendar)?.start == date("2026-10-12T00:00:00Z"))
    #expect(TemporalIntent.window(in: "in the last 48 hours", now: now, calendar: calendar)?.start == date("2026-10-28T15:00:00Z"))
}

@Test("the question's own words are what leave the search text, whatever their case")
func residualKeepsTheRest() throws {
    let window = try #require(TemporalIntent.window(in: "What changed in RETRIEVAL Since August?", now: now, calendar: calendar))
    #expect(window.phrase == "Since August")
    #expect(window.residualQuery == "What changed in RETRIEVAL ?")
}

@Test("so far today leaves nothing of itself behind")
func soFarToday() throws {
    let window = try #require(TemporalIntent.window(in: "what happened so far today", now: now, calendar: calendar))
    #expect(window.phrase == "so far today")
    #expect(window.residualQuery == "what happened")
}

// MARK: - No window

@Test("nothing that merely looks like a time phrase makes a window", arguments: [
    "what is the last commit",
    "the last 3 commits",
    "why did it fail since the fix landed",
    "what may break in this project",
    "a long time ago",
    "how does the march of progress go",
    "since then what",
    "show me the week view",
    "what is the status of the app",
    "in the month view",
])
func noFalseWindow(question: String) {
    #expect(TemporalIntent.window(in: question, now: now, calendar: calendar) == nil)
}

@Test("a date that does not exist is not a window")
func impossibleDate() {
    #expect(TemporalIntent.window(in: "since 2026-02-31", now: now, calendar: calendar) == nil)
    #expect(TemporalIntent.window(in: "since 2026-13-01", now: now, calendar: calendar) == nil)
}

@Test("a period that has not happened yet is not a window")
func futurePeriod() {
    #expect(TemporalIntent.window(in: "since 2027-01-01", now: now, calendar: calendar) == nil)
    #expect(TemporalIntent.window(in: "in December 2026", now: now, calendar: calendar) == nil)
    #expect(TemporalIntent.window(in: "in 2030", now: now, calendar: calendar) == nil)
}

// MARK: - Chosen spans

// A chosen span printed like a defined one presents an arbitrary constant as a fact about the word.
@Test("a phrase with no edges of its own is marked chosen, and one with edges is not", arguments: [
    ("recently", true), ("lately", true), ("the last few days", true), ("three weeks ago", true),
    ("last week", false), ("this month", false), ("in March", false), ("since August", false),
    ("the last 3 days", false), ("the past two weeks", false), ("yesterday", false),
])
func chosenIsMarked(phrase: String, isChosen: Bool) throws {
    let window = try #require(TemporalIntent.window(in: phrase, now: now, calendar: calendar))
    #expect(window.isChosen == isChosen)
}

// MARK: - Time zones and daylight saving

private func zoned(_ identifier: String, firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    calendar.firstWeekday = firstWeekday
    return calendar
}

private let losAngeles = zoned("America/Los_Angeles")

// A commit late on Sunday evening in California is already Monday in UTC. Reading the window in
// the wrong zone puts it in the wrong week, and the same question answers differently on a server.
@Test("the edge of a week is where the owner is, not UTC")
func weekEdgeIsLocal() throws {
    let sundayNight = date("2026-10-26T06:30:00Z") // 23:30 Sunday in Los Angeles
    let local = try #require(TemporalIntent.window(in: "last week", now: now, calendar: losAngeles))
    #expect(local.contains(sundayNight))
    #expect(local.start == date("2026-10-19T07:00:00Z"))
    #expect(local.end == date("2026-10-26T07:00:00Z"))

    let utc = try #require(TemporalIntent.window(in: "last week", now: now, calendar: calendar))
    #expect(!utc.contains(sundayNight))
}

@Test("the edge of a month is where the owner is, not UTC")
func monthEdgeIsLocal() throws {
    let lastEvening = date("2026-04-01T06:30:00Z") // 23:30 on 31 March in Los Angeles
    let local = try #require(TemporalIntent.window(in: "in March", now: now, calendar: losAngeles))
    #expect(local.contains(lastEvening))
    let utc = try #require(TemporalIntent.window(in: "in March", now: now, calendar: calendar))
    #expect(!utc.contains(lastEvening))
}

// The bug: a formatter here used the machine's zone whatever calendar was passed in, so the same
// question moved by a day between two machines, and a test could not pin it down.
@Test("an ISO date is that date in the calendar's zone")
func isoDateIsLocal() throws {
    let local = try #require(TemporalIntent.window(in: "since 2026-10-01", now: now, calendar: losAngeles))
    #expect(local.start == date("2026-10-01T07:00:00Z"))
    let tokyo = try #require(TemporalIntent.window(in: "since 2026-10-01", now: now, calendar: zoned("Asia/Tokyo")))
    #expect(tokyo.start == date("2026-09-30T15:00:00Z"))
}

@Test("a week's first day comes from the calendar")
func firstWeekdayIsLocal() throws {
    let sundayFirst = try #require(TemporalIntent.window(in: "last week", now: now, calendar: zoned("UTC", firstWeekday: 1)))
    #expect(sundayFirst.start == date("2026-10-18T00:00:00Z"))
    #expect(sundayFirst.end == date("2026-10-25T00:00:00Z"))
}

// Fixed arithmetic of 86,400 seconds is wrong twice a year, and only around the change.
@Test("yesterday is 23 hours long when the clocks went forward")
func yesterdayOverSpringForward() throws {
    // 8 March 2026: clocks went from 02:00 PST to 03:00 PDT in Los Angeles.
    let monday = date("2026-03-09T19:00:00Z")
    let window = try #require(TemporalIntent.window(in: "yesterday", now: monday, calendar: losAngeles))
    #expect(window.start == date("2026-03-08T08:00:00Z"))
    #expect(window.end == date("2026-03-09T07:00:00Z"))
    #expect(window.end.timeIntervalSince(window.start) == 23 * 3_600)
}

@Test("yesterday is 25 hours long when the clocks went back, and keeps its last hour")
func yesterdayOverFallBack() throws {
    // 1 November 2026: clocks went from 02:00 PDT back to 01:00 PST in Los Angeles.
    let monday = date("2026-11-02T20:00:00Z")
    let window = try #require(TemporalIntent.window(in: "yesterday", now: monday, calendar: losAngeles))
    #expect(window.start == date("2026-11-01T07:00:00Z"))
    #expect(window.end == date("2026-11-02T08:00:00Z"))
    #expect(window.end.timeIntervalSince(window.start) == 25 * 3_600)
    // 23:30 PST on the 1st. A 24-hour day would have dropped it into the day before.
    #expect(window.contains(date("2026-11-02T07:30:00Z")))
}

@Test("a rolling span keeps the wall clock across a change, so recently is 14 calendar days")
func recentlyOverSpringForward() throws {
    let noon = date("2026-03-15T19:00:00Z") // 12:00 PDT
    let window = try #require(TemporalIntent.window(in: "recently", now: noon, calendar: losAngeles))
    #expect(window.start == date("2026-03-01T20:00:00Z")) // 12:00 PST
    #expect(window.end.timeIntervalSince(window.start) == 14 * 86_400 - 3_600)
}

@Test("this week and this month start at local midnight across a change")
func periodStartsOverFallBack() throws {
    // Tuesday 3 November 2026, after the change: the week began on Monday in PST.
    let tuesday = date("2026-11-03T20:00:00Z")
    let week = try #require(TemporalIntent.window(in: "this week", now: tuesday, calendar: losAngeles))
    #expect(week.start == date("2026-11-02T08:00:00Z"))
    // The month began on the 1st, before the change, in PDT.
    let month = try #require(TemporalIntent.window(in: "this month", now: tuesday, calendar: losAngeles))
    #expect(month.start == date("2026-11-01T07:00:00Z"))
}

// In Havana the clocks change at midnight, so 00:00 on this day does not exist.
@Test("a day that has no midnight starts when it does")
func dayWithNoMidnight() throws {
    let noon = date("2026-03-08T17:00:00Z")
    let window = try #require(TemporalIntent.window(in: "today", now: noon, calendar: zoned("America/Havana")))
    #expect(window.start == date("2026-03-08T05:00:00Z")) // 01:00 CDT, the first instant of the day
}

@Test("a calendar with other years still reads an English month in the Gregorian year")
func otherCalendars() throws {
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = TimeZone(identifier: "UTC")!
    let window = try #require(TemporalIntent.window(in: "in March 2025", now: now, calendar: buddhist))
    #expect(window.start == date("2025-03-01T00:00:00Z"))
    #expect(window.span(in: buddhist) == "2025-03-01 through 2025-03-31")
}

// MARK: - Printed span

// The bug: `end` is exclusive, so "last week" printed the Monday after it as its last day.
@Test("a printed span names the last day it includes")
func spanIsInclusive() throws {
    let week = try #require(TemporalIntent.window(in: "last week", now: now, calendar: calendar))
    #expect(week.span(in: calendar) == "2026-10-19 through 2026-10-25")

    let recent = try #require(TemporalIntent.window(in: "recently", now: now, calendar: calendar))
    #expect(recent.span(in: calendar) == "2026-10-16 through 2026-10-30")

    let yesterday = try #require(TemporalIntent.window(in: "yesterday", now: now, calendar: calendar))
    #expect(yesterday.span(in: calendar) == "2026-10-29")

    let local = try #require(TemporalIntent.window(in: "last week", now: now, calendar: losAngeles))
    #expect(local.span(in: losAngeles) == "2026-10-19 through 2026-10-25")
}

// MARK: - Search

@Test("a passage dated exactly at the end of a window is outside it, and at the start inside")
func searchBoundary() async throws {
    let store = try await store()
    let source = Source(kind: .filesystem, handle: "docs", displayName: "Docs", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let start = date("2026-10-19T00:00:00Z")
    let end = date("2026-10-26T00:00:00Z")
    let opening = CoreObject(sourceID: source.id, kind: .document, externalID: "opening", title: "opening", text: "boundary note one", authoredAt: start, domain: .project, authority: .authoredArtifact)
    let closing = CoreObject(sourceID: source.id, kind: .document, externalID: "closing", title: "closing", text: "boundary note two", authoredAt: end, domain: .project, authority: .authoredArtifact)
    try await store.ingest([opening, closing])
    let chunker = Chunker()
    try await store.save([opening, closing].flatMap { chunker.chunks(for: $0) })

    let found = try await PassageSearch(store: store).search(
        query: "boundary", queryClass: .temporal, policy: AdmissionPolicy(queryDomain: .project),
        window: DateInterval(start: start, end: end)
    )
    #expect(found.hits.map(\.object.id) == [opening.id])
}

// The bug: DateInterval.contains includes its end and the lexical SQL does not, and the dense leg
// filtered after its cap. `searchBoundary` above only ever ran the lexical leg, and `denseWeight` 0
// hid the rest, until Settings could set it.
@Test("the dense leg keeps a window ahead of its cap and shuts it at the same end as lexical")
func denseWindow() async throws {
    let store = try await store()
    let source = Source(kind: .filesystem, handle: "docs", displayName: "Docs", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let start = date("2026-10-19T00:00:00Z")
    let end = date("2026-10-26T00:00:00Z")
    // Nearest the query first. The older note and the one on the closing edge both outrank the one
    // inside the window, so a filter behind a cap of one finds nothing.
    let older = try await seeded(store, source, "older", at: date("2026-01-01T00:00:00Z"), vector: [1, 0, 0])
    let closing = try await seeded(store, source, "closing", at: end, vector: [0.99, 0.14, 0])
    let opening = try await seeded(store, source, "opening", at: start, vector: [0.1, 0.99, 0])

    var tuning = RetrievalTuning.default
    tuning.denseWeight = 1
    tuning.lexicalWeight = 0
    let embedder = FixedEmbedder()
    let search = PassageSearch(store: store, embedder: embedder, tuning: tuning)
    let policy = AdmissionPolicy(queryDomain: .project)
    let window = DateInterval(start: start, end: end)

    let capped = try await search.search(query: "anything", queryClass: .temporal, policy: policy, candidatesPerLeg: 1, window: window)
    #expect(capped.hits.map(\.object.id) == [opening.id])

    let wide = try await search.search(query: "anything", queryClass: .temporal, policy: policy, window: window)
    #expect(wide.hits.map(\.object.id) == [opening.id])
    #expect(!wide.hits.map(\.object.id).contains(closing.id))
    #expect(!wide.hits.map(\.object.id).contains(older.id))
}

// The bug: an answer from the event log passes no text, and the dense leg embedded the empty string
// and ranked the whole store by its distance from nothing.
@Test("an empty query embeds nothing and says the leg did not run")
func emptyQueryDoesNotEmbed() async throws {
    let store = try await store()
    let source = Source(kind: .filesystem, handle: "docs", displayName: "Docs", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    _ = try await seeded(store, source, "note", at: date("2026-10-20T00:00:00Z"), vector: [1, 0, 0])

    var tuning = RetrievalTuning.default
    tuning.denseWeight = 1
    let embedder = FixedEmbedder()
    let outcome = try await PassageSearch(store: store, embedder: embedder, tuning: tuning)
        .search(query: "", queryClass: .temporal, policy: AdmissionPolicy(queryDomain: .project))
    #expect(await embedder.calls == 0)
    #expect(outcome.hits.isEmpty)
    #expect(!outcome.denseLegRan)
    #expect(outcome.unavailableSignals[PassageOutcome.Signal.semantic] != nil)
}

// The bug: `chunksSearched` was `chunkCount()` on every path, so a search that looked at nothing
// and a search of one week both reported the whole store. Unmeasured stays nil, and a number that
// measures something else is worse than that.
@Test("chunks searched is what was in scope: nothing, the window's admitted chunks, or the store")
func chunksSearchedIsMeasured() async throws {
    let store = try await store()
    let source = Source(kind: .filesystem, handle: "docs", displayName: "Docs", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let inside = date("2026-10-20T00:00:00Z")
    let objects = [
        CoreObject(sourceID: source.id, kind: .document, externalID: "in", title: "in", text: "a note on retrieval", authoredAt: inside, domain: .project, authority: .authoredArtifact),
        CoreObject(sourceID: source.id, kind: .document, externalID: "out", title: "out", text: "a note on retrieval", authoredAt: date("2024-01-01T00:00:00Z"), domain: .project, authority: .authoredArtifact),
        CoreObject(sourceID: source.id, kind: .document, externalID: "undated", title: "undated", text: "a note on retrieval", domain: .project, authority: .authoredArtifact),
        // Inside the window and blocked: a per-window count holding this says it exists.
        CoreObject(sourceID: source.id, kind: .document, externalID: "blocked", title: "blocked", text: "a note on retrieval", authoredAt: inside, domain: .medical, authority: .authoredArtifact),
    ]
    try await store.ingest(objects)
    let chunker = Chunker()
    try await store.save(objects.flatMap { chunker.chunks(for: $0) })

    let search = PassageSearch(store: store)
    let policy = AdmissionPolicy(queryDomain: .project)
    let window = DateInterval(start: date("2026-10-19T00:00:00Z"), end: date("2026-10-26T00:00:00Z"))

    let nothing = try await search.search(query: "", queryClass: .temporal, policy: policy, window: window)
    #expect(nothing.chunksSearched == 0)
    let stopwords = try await search.search(query: "what was the", queryClass: .factual, policy: policy)
    #expect(stopwords.chunksSearched == 0)

    let dated = try await search.search(query: "retrieval", queryClass: .temporal, policy: policy, window: window)
    #expect(dated.chunksSearched == 1)

    let everything = try await search.search(query: "retrieval", queryClass: .factual, policy: policy)
    #expect(try await everything.chunksSearched == store.chunkCount())
}

// MARK: - Phrases that used to read wrong

// The bug: all four matched a shorter phrase inside them, so the Window line stated a span and the
// answer was about the wrong days. "In March last year" also left "in March" behind as search text.
@Test("a phrase is not read as a shorter phrase inside it", arguments: [
    ("the day before yesterday", "2026-10-28T00:00:00Z", "2026-10-29T00:00:00Z"),
    ("the last week of September", "2026-09-24T00:00:00Z", "2026-10-01T00:00:00Z"),
    ("the last month of 2025", "2025-12-01T00:00:00Z", "2026-01-01T00:00:00Z"),
    ("in March last year", "2025-03-01T00:00:00Z", "2025-04-01T00:00:00Z"),
    ("March of this year", "2026-03-01T00:00:00Z", "2026-04-01T00:00:00Z"),
    ("the first week of 2025", "2025-01-01T00:00:00Z", "2025-01-08T00:00:00Z"),
    ("the last day of March 2024", "2024-03-31T00:00:00Z", "2024-04-01T00:00:00Z"),
])
func narrowerPhrases(phrase: String, start: String, end: String) throws {
    let window = try #require(TemporalIntent.window(in: "what happened \(phrase)", now: now, calendar: calendar))
    #expect(window.start == date(start))
    #expect(window.end == date(end))
    #expect(window.residualQuery == "what happened")
}

@Test("the seven days at the edge of a month are chosen, and a whole day or month is not")
func partIsChosenOnlyForAWeek() throws {
    #expect(TemporalIntent.window(in: "the last week of September", now: now, calendar: calendar)?.isChosen == true)
    #expect(TemporalIntent.window(in: "the last month of 2025", now: now, calendar: calendar)?.isChosen == false)
}

// The bug: these named a stretch of something else and were read as the week or month just gone. A
// question this cannot place searches all of time, and the word stays in it.
@Test("a position inside something undated makes no window", arguments: [
    "the last week of the sprint",
    "the last month of the project",
    "my last year of college",
    "the last 3 days of the launch",
    "the last hour of the deploy",
    "the last month of March",
])
func positionMakesNoWindow(question: String) {
    #expect(TemporalIntent.window(in: question, now: now, calendar: calendar) == nil)
}

// The bug: each of these had no rule and appeared in no list of what is not read, so they searched
// all of time with nothing to say so.
@Test("common spans are read", arguments: [
    ("in the past year", "2025-10-30T15:00:00Z", "2026-10-30T15:00:00Z"),
    ("the past day", "2026-10-29T15:00:00Z", "2026-10-30T15:00:00Z"),
    ("the last hour", "2026-10-30T14:00:00Z", "2026-10-30T15:00:00Z"),
    ("the past hour", "2026-10-30T14:00:00Z", "2026-10-30T15:00:00Z"),
    ("last night", "2026-10-29T18:00:00Z", "2026-10-30T06:00:00Z"),
    ("this morning", "2026-10-30T00:00:00Z", "2026-10-30T12:00:00Z"),
    ("this afternoon", "2026-10-30T12:00:00Z", "2026-10-30T15:00:00Z"),
    ("last weekend", "2026-10-24T00:00:00Z", "2026-10-26T00:00:00Z"),
])
func commonSpans(phrase: String, start: String, end: String) throws {
    let window = try #require(TemporalIntent.window(in: phrase, now: now, calendar: weekendCalendar))
    #expect(window.start == date(start))
    #expect(window.end == date(end))
}

@Test("a part of the day is marked chosen, and a weekend, which the calendar defines, is not", arguments: [
    ("last night", true), ("this morning", true), ("this afternoon", true), ("last weekend", false), ("the past year", false),
])
func partOfDayIsChosen(phrase: String, isChosen: Bool) throws {
    #expect(try #require(TemporalIntent.window(in: phrase, now: now, calendar: weekendCalendar)).isChosen == isChosen)
}

@Test("this evening has not happened in the afternoon")
func eveningIsStillToCome() {
    #expect(TemporalIntent.window(in: "this evening", now: now, calendar: calendar) == nil)
}

/// `Calendar.nextWeekend` reads the locale, so a test of it has to name one.
private let weekendCalendar: Calendar = {
    var result = calendar
    result.locale = Locale(identifier: "en_US_POSIX")
    return result
}()

@Test("last weekend said during a weekend is the one before it")
func lastWeekendFromInsideOne() throws {
    let saturday = date("2026-10-31T15:00:00Z")
    let window = try #require(TemporalIntent.window(in: "last weekend", now: saturday, calendar: weekendCalendar))
    #expect(window.start == date("2026-10-24T00:00:00Z"))
    #expect(window.end == date("2026-10-26T00:00:00Z"))

    let sunday = date("2026-11-01T15:00:00Z")
    #expect(TemporalIntent.window(in: "last weekend", now: sunday, calendar: weekendCalendar)?.start == date("2026-10-24T00:00:00Z"))
}

@Test("last and a month name is the one before this month")
func lastMonthName() throws {
    #expect(TemporalIntent.window(in: "last March", now: now, calendar: calendar)?.start == date("2026-03-01T00:00:00Z"))
    #expect(TemporalIntent.window(in: "last October", now: now, calendar: calendar)?.start == date("2025-10-01T00:00:00Z"))
    #expect(TemporalIntent.window(in: "last November", now: now, calendar: calendar)?.start == date("2025-11-01T00:00:00Z"))
}

// "May" alone is a verb.
@Test("may with no preposition stays a verb")
func mayIsAVerb() {
    #expect(TemporalIntent.window(in: "it may last year round", now: now, calendar: calendar)?.phrase == "last year")
    #expect(TemporalIntent.window(in: "in May last year", now: now, calendar: calendar)?.start == date("2025-05-01T00:00:00Z"))
}

// The bug: the optional group had no "the", so the two most natural ways to say this found nothing.
@Test("since reaches the start of a period however it is said, and always ends now", arguments: [
    ("since the start of the year", "2026-01-01T00:00:00Z"),
    ("since the beginning of the month", "2026-10-01T00:00:00Z"),
    ("since the start of the week", "2026-10-26T00:00:00Z"),
    ("since the beginning of last month", "2026-09-01T00:00:00Z"),
    ("since the start of this month", "2026-10-01T00:00:00Z"),
    ("since the day before yesterday", "2026-10-28T00:00:00Z"),
    ("since March last year", "2025-03-01T00:00:00Z"),
    ("since last night", "2026-10-29T18:00:00Z"),
    ("since this morning", "2026-10-30T00:00:00Z"),
    ("since last weekend", "2026-10-24T00:00:00Z"),
])
func sinceEveryPhrase(phrase: String, start: String) throws {
    let window = try #require(TemporalIntent.window(in: phrase, now: now, calendar: weekendCalendar))
    #expect(window.start == date(start))
    #expect(window.end == now)
    #expect(window.residualQuery.isEmpty)
}

@Test("what is listed as not read is not read", arguments: [
    "on October 12",
    "next week",
    "tonight",
    "this weekend",
    "from March to May",
])
func notRead(question: String) {
    #expect(TemporalIntent.window(in: question, now: now, calendar: weekendCalendar) == nil)
}

// MARK: - What the question still asks

// The bug: `core_search` and the CLI used the residual, the app blanked a subjectless one, and the
// app's comment said the two must not disagree.
@Test("a span with no topic leaves nothing to search for, and a span with one keeps it")
func searchTextIsOneRule() throws {
    let framing = try #require(TemporalIntent.window(in: "what was I working on recently", now: now, calendar: calendar))
    #expect(framing.searchText == "")
    let topical = try #require(TemporalIntent.window(in: "what changed in retrieval last week", now: now, calendar: calendar))
    #expect(topical.searchText == "what changed in retrieval")
}

@Test("only a phrase that asks how things stand means now")
func meansNow() throws {
    #expect(try #require(TemporalIntent.window(in: "how many are archived these days", now: now, calendar: calendar)).meansNow)
    #expect(try !#require(TemporalIntent.window(in: "how many are archived recently", now: now, calendar: calendar)).meansNow)
    #expect(try !#require(TemporalIntent.window(in: "how many are archived this month", now: now, calendar: calendar)).meansNow)
}

@Test("the words left over are the ones no framing word or name accounts for")
func unplaced() {
    #expect(TemporalIntent.unplacedTerms(in: "how many meetings") == ["meetings"])
    #expect(TemporalIntent.unplacedTerms(in: "how many commits in Quiet", naming: ["quiet"]).isEmpty)
    #expect(TemporalIntent.unplacedTerms(in: "how many open pull requests") == ["open", "pull", "requests"])
}

// MARK: - Search fixtures

/// Answers every query with the same vector, and counts, so "did the leg run" is a fact.
private actor FixedEmbedder: EmbeddingProvider {
    nonisolated let modelIdentifier = "fixed-test-embedder"
    nonisolated let dimensions = 3
    private(set) var calls = 0

    func embed(_ text: String) async throws -> [Float] {
        calls += 1
        return [1, 0, 0]
    }

    func embed(batch: [String]) async throws -> [[Float]] {
        calls += batch.count
        return batch.map { _ in [1, 0, 0] }
    }
}

private func seeded(_ store: Store, _ source: Source, _ name: String, at authored: Date, vector: [Float]) async throws -> CoreObject {
    let object = CoreObject(sourceID: source.id, kind: .document, externalID: name, title: name, text: "text of \(name)", authoredAt: authored, domain: .project, authority: .authoredArtifact)
    try await store.ingest([object])
    let chunk = CoreChunk(objectID: object.id, ordinal: 0, text: object.text, range: 0..<object.text.count)
    try await store.save([chunk])
    try await store.save(vectors: [StoredVector(chunkID: chunk.id, model: "fixed-test-embedder", values: vector)], dimensions: 3)
    return object
}
