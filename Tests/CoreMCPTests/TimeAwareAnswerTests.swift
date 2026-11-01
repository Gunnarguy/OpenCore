import CoreGraph
import CoreJSONRPC
import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Synchronization
import Testing

@testable import CoreMCP
@testable import CoreReason

private func temporaryStore() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-time-\(UUID().uuidString)/test.sqlite3"))
}

private let github = Source(kind: .github, handle: "user", displayName: "GitHub", defaultAuthority: .authoredArtifact, defaultDomain: .project)
private let calendar = Source(kind: .calendar, handle: "calendar", displayName: "Calendar", defaultAuthority: .authoredArtifact, defaultDomain: .personal)

private func commit(_ repo: String, _ message: String, at date: Date, author: String = "someone") -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .commit, externalID: "user/\(repo)@\(message)", title: message,
        text: "user/\(repo)\n\(message)", authoredAt: date, domain: .project, authority: .authoredArtifact,
        metadata: ["repo": "user/\(repo)", "author": author]
    )
}

private func repository(_ name: String, created: Date) -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .repository, externalID: "user/\(name)", title: name,
        text: "user/\(name)", authoredAt: created, domain: .project, authority: .authoredArtifact,
        metadata: ["archived": "false"]
    )
}

private func fixture(now: Date) async throws -> Store {
    let store = try await temporaryStore()
    try await store.upsert(github)
    try await store.upsert(calendar)
    let day: TimeInterval = 86_400
    let created = now.addingTimeInterval(-900 * day)
    let objects = [
        repository("Current", created: created),
        repository("Quiet", created: created),
        repository("Ancient", created: created),
        commit("Current", "Add the sync schedule", at: now.addingTimeInterval(-2 * day)),
        commit("Current", "Fix the belief ordering", at: now.addingTimeInterval(-3 * day)),
        commit("Quiet", "One small change", at: now.addingTimeInterval(-5 * day)),
        commit("Quiet", "chore(roadmap): sync latest roadmap from Notion", at: now.addingTimeInterval(-day), author: "github-actions[bot]"),
        commit("Quiet", "Another bot run [skip ci]", at: now.addingTimeInterval(-day / 2)),
        commit("Ancient", "Work from long ago", at: now.addingTimeInterval(-120 * day)),
    ]
    _ = try await IngestPipeline(store: store, now: now).run(objects: objects)
    return store
}

// The bug: "recently" was a stopword, no path filtered by date, and `core_ask` never reached the
// event log, so this question searched the word "working" across all of time.
@Test("recently returns only what happened in the window, and an older repository is excluded")
func recentlyFiltersByDate() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now).answer("What was I working on recently?", persistReceipt: false)

    let activity = try #require(answer.activity)
    let names = activity.groups.map(\.subject.canonicalName)
    #expect(names.contains("Current"))
    #expect(!names.contains("Ancient"))
    #expect(activity.totalEvents == 5)
    #expect(answer.window?.phrase == "recently")
    #expect(answer.insufficientEvidence == nil)
    // A question with no subject gets no claim list off a retrieved passage.
    #expect(answer.points.isEmpty)
}

// The bug this guards: a site that syncs a roadmap every night looks like the busiest project.
@Test("bot commits and docs-only pushes are counted as upkeep, not as work")
func upkeepDoesNotLead() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now).answer("what did I do recently", persistReceipt: false)
    let groups = try #require(answer.activity?.groups)
    #expect(groups.first?.subject.canonicalName == "Current")
    let quiet = try #require(groups.first { $0.subject.canonicalName == "Quiet" })
    #expect(quiet.events == 1)
    #expect(quiet.upkeep == 2)
    #expect(quiet.latest.first?.detail == "One small change")
}

@Test("a question that names a repository and a window stays on that repository")
func namedWindow() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now).answer("what did I change in Quiet this month", persistReceipt: false)
    #expect(answer.activity?.groups.map(\.subject.canonicalName) == ["Quiet"])
}

// An empty window and a store nobody has synced are different facts and read the same otherwise.
@Test("an empty window says when the newest admitted event was")
func emptyWindowNamesTheNewestEvent() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now.addingTimeInterval(365 * 86_400))
        .answer("what was I working on yesterday", persistReceipt: false)
    let message = try #require(answer.insufficientEvidence)
    #expect(message.contains("Nothing recorded"))
    #expect(message.contains("newest admitted event"))
}

@Test("as_of moves the window with the clock")
func asOfMovesTheWindow() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let back = now.addingTimeInterval(-118 * 86_400)
    let answer = try await Reasoner(store: store, now: now).answer("what was I working on recently", asOfWorld: back, asOfKnowledge: now, persistReceipt: false)
    #expect(answer.activity?.groups.map(\.subject.canonicalName) == ["Ancient"])
}

// A window must not become a way around the firewall: events are filtered by the policy, and a
// personal calendar entry never reaches an MCP caller however the question is worded.
@Test("activity over MCP holds to the domain policy")
func activityRespectsThePolicy() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let personal = CoreObject(sourceID: calendar.id, kind: .calendarEvent, externalID: "ev1", title: "Private appointment", text: "Private appointment", authoredAt: now.addingTimeInterval(-86_400), domain: .personal, authority: .authoredArtifact, metadata: ["calendar": "Home"])
    _ = try await IngestPipeline(store: store, now: now).run(objects: [personal])

    let payload: JSONValue = .object([
        "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
        "params": .object(["name": .string("core_ask"), "arguments": .object(["query": .string("what was I doing recently")])]),
    ])
    let request = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(payload))
    let result = try await MCPServer(store: store).handle(request)
    guard case .object(let dict) = result, case .array(let content)? = dict["content"],
          case .object(let first)? = content.first, case .string(let text)? = first["text"]
    else { Issue.record("unexpected result shape"); return }
    #expect(text.contains("Current"))
    #expect(!text.contains("Private appointment"))
    #expect(!text.contains("Home"))
}

// The trace of a time answer must explain itself, the way a counted answer does, rather than
// reading "admitted no evidence" as if the lookup failed.
@Test("tracing a time answer says it came from the event log")
func traceExplainsActivity() async throws {
    let now = Date()
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now).answer("what was I working on recently")
    let payload: JSONValue = .object([
        "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
        "params": .object(["name": .string("core_trace"), "arguments": .object(["receipt": .string(answer.receipt.shortCode)])]),
    ])
    let request = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(payload))
    let result = try await MCPServer(store: store).handle(request)
    guard case .object(let dict) = result, case .array(let content)? = dict["content"],
          case .object(let first)? = content.first, case .string(let text)? = first["text"]
    else { Issue.record("unexpected result shape"); return }
    #expect(text.contains("event log"))
}

// MARK: - Clock and calendar

/// A clock a test can move while a server holds it.
private final class MovingClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func move(to date: Date) { value.withLock { $0 = date } }
}

private func callTool(_ server: MCPServer, _ name: String, _ arguments: [String: JSONValue]) async throws -> String {
    let payload: JSONValue = .object([
        "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
        "params": .object(["name": .string(name), "arguments": .object(arguments)]),
    ])
    let request = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(payload))
    let result = try await server.handle(request)
    guard case .object(let dict) = result, case .array(let content)? = dict["content"],
          case .object(let first)? = content.first, case .string(let text)? = first["text"]
    else { Issue.record("unexpected result shape"); return "" }
    return text
}

/// The last state of a chat turn. These questions end in deterministic text, so no model runs.
private func chat(_ conversation: Conversation, _ question: String) async -> Turn {
    var last = Turn(role: .core)
    for await turn in await conversation.send(question) { last = turn }
    return last
}

private let day: TimeInterval = 86_400
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

// The bug: `Reasoner` captured `Date()` when it was built, and `MCPServer` builds one for the life
// of its process. Clients hold that process for days, so "recently" meant the fortnight before the
// server started. It looked right in every test, because a test's server is seconds old.
@Test("a long-running server reads the clock for each question, not once at launch")
func serverClockIsReadPerCall() async throws {
    let started = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: started)
    let clock = MovingClock(started)
    let server = MCPServer(store: store, now: clock.now, calendar: utc)

    let first = try await callTool(server, "core_ask", ["query": .string("what was I working on recently")])
    #expect(first.contains("Add the sync schedule"))

    // A month later, the same process and the same question: the window has moved past every commit.
    clock.move(to: started.addingTimeInterval(30 * day))
    let later = try await callTool(server, "core_ask", ["query": .string("what was I working on recently")])
    #expect(!later.contains("Add the sync schedule"))
    #expect(later.contains("2026-11-15 through 2026-11-29"))
}

// The bug: nothing passed a calendar to the parser in `Reasoner`, so an answer's day edges were
// whatever the machine's were and no test could reach them.
@Test("the calendar an answer is given decides which week a late commit is in")
func answerUsesItsCalendar() async throws {
    let now = instant("2026-10-30T22:00:00Z")
    let store = try await temporaryStore()
    try await store.upsert(github)
    let sundayNight = instant("2026-10-26T06:30:00Z") // 23:30 Sunday in Los Angeles, Monday in UTC
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        repository("Current", created: now.addingTimeInterval(-900 * day)),
        commit("Current", "Late on Sunday", at: sundayNight),
    ])
    let losAngeles = {
        var calendar = utc
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    let there = try await Reasoner(store: store, now: now, calendar: losAngeles).answer("what did I do last week", persistReceipt: false)
    #expect(there.activity?.totalEvents == 1)

    let here = try await Reasoner(store: store, now: now, calendar: utc).answer("what did I do last week", persistReceipt: false)
    #expect((here.activity?.totalEvents ?? 0) == 0)
}

// A question with no time phrase must behave exactly as it did. A window is the one change that
// silently removes evidence, so it must never appear uninvited.
@Test("a question with no time phrase gets no window, no report and no activity")
func noPhraseChangesNothing() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what is Current", persistReceipt: false)
    #expect(answer.window == nil)
    #expect(answer.report == nil)
    #expect(answer.activity == nil)
    #expect(answer.searchedText == nil)
    #expect(!answer.summary.contains("Window:"))
    #expect(!answer.receipt.stages.contains { $0.name == "window" || $0.name == "activity" })
}

// MARK: - Exclusion

@Test("an event exactly at the start of a window counts and one exactly at its end does not")
func activityBoundary() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await temporaryStore()
    try await store.upsert(github)
    let start = instant("2026-10-19T00:00:00Z")
    let end = instant("2026-10-26T00:00:00Z")
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        repository("Current", created: now.addingTimeInterval(-900 * day)),
        commit("Current", "Opening minute", at: start),
        commit("Current", "Closing minute", at: end),
        commit("Current", "One second early", at: start.addingTimeInterval(-1)),
    ])
    let summary = try await store.activity(from: start, to: end, domains: [.project])
    #expect(summary.totalEvents == 1)
    #expect(summary.groups.first?.latest.map(\.detail).contains("Opening minute") == true)
}

// The bug: "subjects" was filtered after the scan cap, so a quiet repository behind a busy one came
// back empty, which is the same defect `core_timeline` has after its 200-row cap.
@Test("a subject's events are found behind a busier subject's, whatever the cap")
func subjectFilterIsAheadOfTheCap() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await temporaryStore()
    try await store.upsert(github)
    let created = now.addingTimeInterval(-900 * day)
    var objects = [repository("Busy", created: created), repository("Quiet", created: created),
                   commit("Quiet", "The one quiet commit", at: now.addingTimeInterval(-2 * day))]
    for index in 0..<5 { objects.append(commit("Busy", "Busy work \(index)", at: now.addingTimeInterval(-Double(index + 1) * 3_600))) }
    _ = try await IngestPipeline(store: store, now: now).run(objects: objects)

    let quiet = try #require(try await store.resolve(surface: "Quiet").first?.0)
    let summary = try await store.activity(
        from: now.addingTimeInterval(-7 * day), to: now, domains: [.project], subjects: [quiet.id], scanLimit: 3
    )
    #expect(summary.totalEvents == 1)
}

// The bug: the summary printed `groups.count`, which stops at the display limit, so a busy month
// read "across 12 subjects" whatever the number was.
@Test("the subject count is every subject, not how many were shown, and a cut count says so")
func countsAreNotCaps() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await temporaryStore()
    try await store.upsert(github)
    let created = now.addingTimeInterval(-900 * day)
    var objects: [CoreObject] = []
    for index in 0..<4 {
        objects.append(repository("Repo\(index)", created: created))
        objects.append(commit("Repo\(index)", "Commit \(index)", at: now.addingTimeInterval(-Double(index + 1) * day)))
    }
    _ = try await IngestPipeline(store: store, now: now).run(objects: objects)

    let summary = try await store.activity(from: now.addingTimeInterval(-7 * day), to: now, domains: [.project], limit: 2)
    #expect(summary.groups.count == 2)
    #expect(summary.totalSubjects == 4)
    #expect(!summary.isTruncated)

    let capped = try await store.activity(from: now.addingTimeInterval(-7 * day), to: now, domains: [.project], scanLimit: 2)
    #expect(capped.isTruncated)
}

/// A fourth repository, because `Store.metadataKeys` ignores a key held by fewer than four objects,
/// and below that no facet exists for a count to match.
private func facetFixture(now: Date) async throws -> Store {
    let store = try await fixture(now: now)
    _ = try await IngestPipeline(store: store, now: now).run(objects: [repository("Fourth", created: now.addingTimeInterval(-900 * day))])
    return store
}

// The bug: `AggregateAnswering` counts every row ever. It declines a bare count with words it cannot
// place, so "how many commits this month" was safe, but a facet match gets through: this question
// returned the all-time figure with no mention of the month, in the flat voice of a computed fact.
@Test("a count that matches a facet is not the all-time figure when a time phrase is present")
func countRespectsTheWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await facetFixture(now: now)
    let reasoner = Reasoner(store: store, now: now, calendar: utc)

    let allTime = try await reasoner.answer("how many repositories are archived", persistReceipt: false)
    #expect(allTime.counted != nil)

    let month = try await reasoner.answer("how many repositories are archived this month", persistReceipt: false)
    #expect(month.counted == nil)
    #expect(month.activity?.totalEvents == 5)
    #expect(month.report != nil)
    #expect(month.points.isEmpty)
}

// Without this a count of something that is not a framing word became a topical search, and the
// next step is the original defect: a model counting the passages in front of it.
//
// The bug this test used to enshrine: the sentence read "5 events across 3 subjects" on a store with
// no meetings in it, the commits of three repositories, under a question that asked for meetings.
@Test("a count of anything with a time phrase comes from events and says what it did not count")
func countOfAnythingReadsEvents() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("how many meetings this month", persistReceipt: false)
    #expect(answer.activity?.totalEvents == 5)
    #expect(answer.passages.isEmpty)
    #expect(answer.searchedText == "")
    #expect(answer.summary.hasPrefix("Not a count of 'meetings':"))
    #expect(answer.summary.contains("5 events"))
}

@Test("a count of something the event log does hold has no such line")
func countOfCommitsIsPlain() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("how many commits this month", persistReceipt: false)
    #expect(answer.summary.hasPrefix("5 events"))
    let named = try await Reasoner(store: store, now: now, calendar: utc).answer("how many commits in Quiet this month", persistReceipt: false)
    #expect(!named.summary.contains("Not a count"))
}

// The bug: any window turned off `AggregateAnswering`, so a question about how things stand lost a
// correct count to a tally of unrelated events.
@Test("these days asks how things stand, so it keeps the count of how things stand")
func theseDaysKeepsTheFacetCount() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await facetFixture(now: now)
    let reasoner = Reasoner(store: store, now: now, calendar: utc)
    let answer = try await reasoner.answer("how many repositories are archived these days", persistReceipt: false)
    let counted = try #require(answer.counted)
    let plain = try await reasoner.answer("how many repositories are archived", persistReceipt: false)
    #expect(counted.sentence == plain.counted?.sentence)
    #expect(answer.activity == nil)

    let turn = await chat(Conversation(store: store, now: now, calendar: utc), "how many repositories are archived these days")
    #expect(turn.receipt?.stages.first?.name == "count")

    // "Recently" names a span. The all-time figure is still the wrong answer to it.
    let recent = try await reasoner.answer("how many repositories are archived recently", persistReceipt: false)
    #expect(recent.counted == nil)
}

// MARK: - Routing

@Test("a topical question reads passages from the window, not every repository's week")
func topicalReadsPassages() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let old = CoreObject(sourceID: github.id, kind: .document, externalID: "note-old", title: "Old note", text: "A decision about ordering from long ago", authoredAt: now.addingTimeInterval(-300 * day), domain: .project, authority: .authoredArtifact)
    let new = CoreObject(sourceID: github.id, kind: .document, externalID: "note-new", title: "New note", text: "A decision about ordering from this month", authoredAt: now.addingTimeInterval(-4 * day), domain: .project, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store, now: now).run(objects: [old, new])

    let answer = try await Reasoner(store: store, now: now, calendar: utc)
        .answer("what did I decide about ordering this month", persistReceipt: false)
    #expect(answer.activity == nil)
    #expect(answer.passages.map(\.object.id).contains(new.id))
    #expect(!answer.passages.map(\.object.id).contains(old.id))
    #expect(answer.searchedText == "what did I decide about ordering")
    #expect(answer.receipt.stages.contains { $0.name == "window" })
}

// The bug: subjects were pooled from the passages, so "what did I decide about retrieval this month"
// listed the language of every repository a passage touched. On the real store: 41 claims, led by
// a project's language.
@Test("a topical window lists claims its passages support, not everything those subjects had")
func topicalKeepsToItsPassages() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await temporaryStore()
    try await store.upsert(github)
    let repo = CoreObject(
        sourceID: github.id, kind: .repository, externalID: "user/Current", title: "Current", text: "user/Current",
        authoredAt: now.addingTimeInterval(-3 * day), domain: .project, authority: .authoredArtifact,
        metadata: ["archived": "false", "language": "Swift"]
    )
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        repo, commit("Current", "Decide the belief ordering", at: now.addingTimeInterval(-2 * day)),
    ])
    let named = try await Reasoner(store: store, now: now, calendar: utc).answer("what language is Current written in this month", persistReceipt: false)
    #expect(named.points.contains { $0.predicate == Predicate.primaryLanguage })

    let topical = try await Reasoner(store: store, now: now, calendar: utc).answer("what did I decide about ordering this month", persistReceipt: false)
    #expect(!topical.passages.isEmpty)
    #expect(!topical.points.contains { $0.predicate == Predicate.primaryLanguage })
}

// A caller doing its own retrieval reads this to stay inside the window. An empty string is how it
// learns there was nothing to look for.
@Test("an answer from the event log says no text was searched")
func subjectlessSearchesNothing() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)
    #expect(answer.searchedText == "")
    #expect(answer.passages.isEmpty)
}

// MARK: - The answer states its window and the store's freshness

private func syncedFixture(now: Date, syncedAt: Date) async throws -> Store {
    let store = try await fixture(now: now)
    try await store.markSynced(github.id, at: syncedAt, cursor: nil)
    return store
}

// The bug this whole type exists for. A store that stopped syncing a week ago answers "what happened
// this week" with a thin list that looks complete. Nothing said it had stopped looking.
@Test("a stale store cannot pass as a quiet week")
func staleStoreIsNamed() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)

    let report = try #require(answer.report)
    #expect(report.behind.map(\.kind) == [.github])
    #expect(answer.summary.contains("Stale: github 2026-10-23"))
    #expect(answer.summary.contains("missing from the store, not quiet"))
}

// The same defect with nothing to show for it, which is the case that reads most like a quiet week.
@Test("an empty window on a stale store says the store is stale, not that nothing happened")
func emptyStaleWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-20T12:00:00Z"))
    // Three weeks on, with nothing synced since.
    let later = now.addingTimeInterval(21 * day)
    let answer = try await Reasoner(store: store, now: later, calendar: utc).answer("what did I work on yesterday", persistReceipt: false)
    let message = try #require(answer.insufficientEvidence)
    #expect(message.contains("Nothing recorded from 2026-11-19"))
    #expect(message.contains("The newest admitted event is from 2026-10-30"))
    #expect(message.contains("Stale: github 2026-10-20"))
}

@Test("a store that synced today raises no alarm")
func freshStoreIsQuiet() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: now.addingTimeInterval(-3_600))
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)
    #expect(answer.report?.behind.isEmpty == true)
    #expect(!answer.summary.contains("Stale:"))
    #expect(answer.summary.contains("Last synced: github 2026-10-30"))
}

// A window that closed before the last sync is complete however old that sync is.
@Test("a window that closed before the last sync is not stale, however old the sync")
func closedWindowIsNotStale() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what did I do in September", persistReceipt: false)
    #expect(answer.report?.behind.isEmpty == true)
}

@Test("a source that has never synced is named as that, not given a date")
func neverSynced() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)
    #expect(answer.summary.contains("Last synced: github never"))
    #expect(answer.summary.contains("Stale: github never"))
}

@Test("the answer states the days it read and that recently is a chosen span")
func windowIsStated() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let reasoner = Reasoner(store: store, now: now, calendar: utc)

    let chosen = try await reasoner.answer("what was I working on recently", persistReceipt: false)
    #expect(chosen.summary.contains("Window: 2026-10-16 through 2026-10-30, read from 'recently', a chosen span"))

    let defined = try await reasoner.answer("what did I do this week", persistReceipt: false)
    #expect(defined.summary.contains("Window: 2026-10-26 through 2026-10-30, read from 'this week'."))
    #expect(!defined.summary.contains("chosen"))
}

@Test("the receipt records what the window was read as, so a trace can show it")
func receiptRecordsTheWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)
    let note = try #require(answer.receipt.stages.first { $0.name == "activity" }?.note)
    #expect(note.contains("2026-10-16 through 2026-10-30"))
    #expect(note.contains("(chosen)"))
    #expect(note.contains("stale: github 2026-10-23"))
}

// MARK: - Admission

// A sync date for a source the caller cannot read says that source exists. A handle is a folder or
// repository name, so a personal source must not appear to an MCP caller at all.
@Test("core_ask reports freshness only for sources the caller may read, and by kind")
func freshnessHoldsToThePolicy() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: now.addingTimeInterval(-3_600))
    let personal = CoreObject(sourceID: calendar.id, kind: .calendarEvent, externalID: "ev1", title: "Private appointment", text: "Private appointment", authoredAt: now.addingTimeInterval(-day), domain: .personal, authority: .authoredArtifact, metadata: ["calendar": "Home"])
    _ = try await IngestPipeline(store: store, now: now).run(objects: [personal])
    try await store.markSynced(calendar.id, at: instant("2026-08-14T12:00:00Z"), cursor: nil)

    let text = try await callTool(MCPServer(store: store, now: now, calendar: utc), "core_ask", ["query": .string("what was I working on recently")])
    #expect(text.contains("Last synced: github 2026-10-30"))
    #expect(!text.contains("calendar"))
    #expect(!text.contains("2026-08-14"))
    #expect(!text.contains("Stale:"))
    #expect(!text.contains("Private appointment"))

    // Blocked sources do not move the newest-event line either.
    let projectOnly = try await store.freshness(domains: [.project], notAfter: now)
    #expect(projectOnly.sources.map(\.kind) == [.github])
    #expect(projectOnly.newestEventAt == now.addingTimeInterval(-day / 2))
}

@Test("a caller admitted to nothing is told nothing about the store")
func freshnessWithNoDomains() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: now)
    let freshness = try await store.freshness(domains: [], notAfter: now)
    #expect(freshness.sources.isEmpty)
    #expect(freshness.newestEventAt == nil)
}

// An event in next February's calendar is not "the newest thing in the store". Measured on the real
// store on 2026-10-31: its newest personal event is dated 2027-02-10.
@Test("something dated after the window's end does not count as fresh")
func futureRowsAreNotFresh() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let freshness = try await store.freshness(domains: [.project], notAfter: now.addingTimeInterval(-2.5 * day))
    #expect(freshness.newestEventAt == now.addingTimeInterval(-3 * day))
}

@Test("a time window opens nothing the question would not otherwise reach")
func windowDoesNotWidenAdmission() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let personal = CoreObject(sourceID: calendar.id, kind: .calendarEvent, externalID: "ev2", title: "Doctor visit", text: "Doctor visit", authoredAt: now.addingTimeInterval(-day), domain: .medical, authority: .authoredArtifact, metadata: ["calendar": "Home"])
    _ = try await IngestPipeline(store: store, now: now).run(objects: [personal])

    for tool in ["core_ask", "core_search"] {
        let text = try await callTool(MCPServer(store: store, now: now, calendar: utc), tool, ["query": .string("what did my doctor say recently")])
        #expect(!text.contains("Doctor visit"))
    }
}

// MARK: - core_search

@Test("core_search filters to the window and states it")
func searchStatesItsWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let server = MCPServer(store: store, now: now, calendar: utc)

    let recent = try await callTool(server, "core_search", ["query": .string("schedule recently")])
    #expect(recent.contains("Add the sync schedule"))
    #expect(recent.contains("Window: 2026-10-16 through 2026-10-30"))
    #expect(recent.contains("Stale: github 2026-10-23"))

    let empty = try await callTool(server, "core_search", ["query": .string("schedule in 2024")])
    #expect(empty.contains("No passages matched"))
    #expect(empty.contains("Window: 2024-01-01 through 2024-12-31"))

    let plain = try await callTool(server, "core_search", ["query": .string("schedule")])
    #expect(!plain.contains("Window:"))
}

// The bug: `core_search` searched the residual whole, so this question looked for the word "working"
// in the window and returned unrelated passages under a Window line. The app blanked the same
// residual and their comment said they must not disagree.
@Test("core_search with a span and no topic returns no passages and points at core_ask")
func searchWithNoTopic() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: now)
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        commit("Current", "Working on the parser", at: now.addingTimeInterval(-2 * day)),
    ])
    let server = MCPServer(store: store, now: now, calendar: utc)

    let text = try await callTool(server, "core_search", ["query": .string("what was I working on recently")])
    #expect(!text.contains("Working on the parser"))
    #expect(text.contains("core_ask"))
    #expect(text.contains("Window: 2026-10-16 through 2026-10-30"))

    // The word still searches when it is the question.
    let topical = try await callTool(server, "core_search", ["query": .string("parser recently")])
    #expect(topical.contains("Working on the parser"))
}

// MARK: - Sources that sync but are not a source kind of their own

private func upsertedManual(_ store: Store, handle: String, domain: Domain = .project) async throws -> Source {
    let source = Source(kind: .manual, handle: handle, displayName: "A manual source", defaultAuthority: .authoredArtifact, defaultDomain: domain)
    try await store.upsert(source)
    return source
}

private func note(in source: Source, at date: Date, domain: Domain = .project) -> CoreObject {
    CoreObject(sourceID: source.id, kind: .document, externalID: "note-\(source.handle)", title: "Roadmap note", text: "A roadmap note", authoredAt: date, domain: domain, authority: .authoredArtifact)
}

// The bug: `s.kind != 'manual'` dropped every MCP source, and the comment said nothing syncs that
// kind. A stopped MCP source never reached a Stale line, so a window built from it read as quiet.
@Test("a stopped MCP source is named stale by kind, and its server's name stays out of the answer")
func stoppedMCPSourceIsStale() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await temporaryStore()
    let mcp = try await upsertedManual(store, handle: "mcp:made-up-server")
    _ = try await IngestPipeline(store: store, now: now).run(objects: [note(in: mcp, at: now.addingTimeInterval(-8 * day))])
    try await store.markSynced(mcp.id, at: now.addingTimeInterval(-7 * day), cursor: nil)

    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)
    let report = try #require(answer.report)
    #expect(report.behind.map(\.label) == ["mcp"])
    #expect(report.text.contains("Stale: mcp 2026-10-23"))
    #expect(!report.text.contains("made-up-server"))
}

// `.manual` holds three unlike things. Notes and Health sync. The ledger is written once by a repair
// and would read as stale forever.
@Test("freshness tells synced manual sources apart and leaves out the one nothing syncs")
func manualSourcesByHandle() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await temporaryStore()
    let notes = try await upsertedManual(store, handle: "apple-notes", domain: .personal)
    let ledger = try await upsertedManual(store, handle: "privacy-repair-ledger")
    let first = try await upsertedManual(store, handle: "mcp:one")
    let second = try await upsertedManual(store, handle: "mcp:two")
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        note(in: notes, at: now.addingTimeInterval(-day), domain: .personal),
        note(in: ledger, at: now.addingTimeInterval(-day)),
        note(in: first, at: now.addingTimeInterval(-day)),
        note(in: second, at: now.addingTimeInterval(-day)),
    ])
    try await store.markSynced(notes.id, at: now, cursor: nil)
    try await store.markSynced(first.id, at: instant("2026-10-01T00:00:00Z"), cursor: nil)
    try await store.markSynced(second.id, at: instant("2026-10-20T00:00:00Z"), cursor: nil)

    let everything = try await store.freshness(domains: [.project, .personal], notAfter: now)
    #expect(everything.sources.map(\.label) == ["mcp", "notes"])
    // Within a label the newest sync speaks, the same rule as folders.
    #expect(everything.sources.first?.lastSyncedAt == instant("2026-10-20T00:00:00Z"))

    // Notes hold personal text, so an MCP caller's report must not mention them.
    let projectOnly = try await store.freshness(domains: [.project], notAfter: now)
    #expect(projectOnly.sources.map(\.label) == ["mcp"])
}

// MARK: - Shortcuts

// The bug: `AskOpenCoreIntent` printed the model's brief in place of `summary` and
// `insufficientEvidence`, the two places a window's lines live, so a Shortcut's answer about one
// month did not say it was one, or that the store had stopped syncing.
@Test("a Shortcut's answer keeps its window lines however it is printed")
func shortcutKeepsTheReport() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let reasoner = Reasoner(store: store, now: now, calendar: utc)

    let bare = try await reasoner.answer("what did I do on the schedule this month", persistReceipt: false)
    let briefOnly = bare.shortcutText(brief: "A brief a model wrote.")
    #expect(briefOnly.hasPrefix("A brief a model wrote."))
    #expect(briefOnly.contains("Window: 2026-10-01 through 2026-10-30"))
    #expect(briefOnly.contains("Stale: github 2026-10-23"))
    #expect(briefOnly.contains("[receipt \(bare.receipt.shortCode)]"))

    var withClaims = bare
    withClaims.points = [AnswerPoint(
        statement: "Current is active.", supporting: [], counter: [], confidence: 0.9,
        authority: .authoredArtifact, derivation: .observed, subject: EntityID("made-up"), predicate: Predicate.status
    )]
    let claimed = withClaims.shortcutText(brief: "A brief a model wrote.")
    #expect(claimed.contains("Current is active."))
    #expect(claimed.contains("Window: 2026-10-01 through 2026-10-30"))

    // With no brief it comes from the text the answer already holds, and appears once.
    let plain = bare.shortcutText(brief: nil)
    #expect(plain.components(separatedBy: "Window:").count == 2)

    // A question with no time phrase prints no such line.
    let timeless = try await reasoner.answer("what is Current", persistReceipt: false)
    #expect(!timeless.shortcutText(brief: "A brief a model wrote.").contains("Window:"))
}

// MARK: - Receipts

// The bug: a question answered from the event log passed no text, so no leg searched anything, and
// the receipt still persisted every chunk in the store as `objects_searched`.
@Test("a receipt read from the event log counts the events it read, not the corpus")
func eventReceiptCountsEvents() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false)
    #expect(answer.receipt.objectsSearched == answer.activity?.totalEvents)
    let retrieve = try #require(answer.receipt.stages.first { $0.name == "retrieve" })
    #expect(retrieve.counters["chunks_searched"] == 0)
}

@Test("a topical window reports the chunks inside it, not the store")
func windowReceiptCountsTheWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let answer = try await Reasoner(store: store, now: now, calendar: utc).answer("what did I decide about ordering this month", persistReceipt: false)
    let total = try await store.chunkCount()
    #expect(answer.receipt.objectsSearched > 0)
    #expect(answer.receipt.objectsSearched < total)
}

// The bug: chat said "Nothing in your history matches that. N passages searched" with the store's
// total, though only the window's rows had been read, and it says how much was looked at.
@Test("chat's empty topical window counts only what was inside the window")
func chatEmptyWindowCount() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let turn = await chat(Conversation(store: store, now: now, calendar: utc), "what did I decide about ordering in 2024")
    let inside = try await store.chunkCount(
        authoredIn: DateInterval(start: instant("2024-01-01T00:00:00Z"), end: instant("2025-01-01T00:00:00Z")),
        domains: [.project]
    )
    let total = try await store.chunkCount()
    #expect(inside < total)
    #expect(turn.text.contains("\(inside) passages searched"))
    #expect(turn.receipt?.objectsSearched == inside)
}

// MARK: - Chat

@Test("chat answers an activity question from events, with the window and the store's freshness")
func chatActivity() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let conversation = Conversation(store: store, now: now, calendar: utc)
    let turn = await chat(conversation, "what was I working on recently")

    #expect(turn.text.contains("Current"))
    #expect(!turn.text.contains("Ancient"))
    #expect(turn.text.contains("Window: 2026-10-16 through 2026-10-30"))
    #expect(turn.text.contains("Stale: github 2026-10-23"))
    #expect(turn.modelName == nil)
    #expect(turn.receipt?.stages.first?.name == "activity")
}

// The bug: only a question with no subject at all was routed to events. Naming a repository sent
// it to a model over passages, so chat and `ask` answered the same question from different places.
@Test("chat answers about a named repository from its events, and only its events")
func chatNamedRepository() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let turn = await chat(Conversation(store: store, now: now, calendar: utc), "what did I change in Quiet this month")
    #expect(turn.text.contains("Quiet"))
    #expect(!turn.text.contains("Current"))
    #expect(turn.modelName == nil)
    #expect(turn.receipt?.stages.first?.name == "activity")
}

@Test("a chat count that matches a facet comes from the event log when a time phrase is present")
func chatCountRespectsTheWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await facetFixture(now: now)
    let allTime = await chat(Conversation(store: store, now: now, calendar: utc), "how many repositories are archived")
    #expect(allTime.receipt?.stages.first?.name == "count")

    let turn = await chat(Conversation(store: store, now: now, calendar: utc), "how many repositories are archived this month")
    #expect(turn.text.contains("5 events"))
    #expect(turn.receipt?.queryClass == .aggregate)
    #expect(turn.receipt?.stages.first?.name == "activity")
}

@Test("a chat count of anything with a time phrase never reaches a model")
func chatCountOfAnythingReadsEvents() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let turn = await chat(Conversation(store: store, now: now, calendar: utc), "how many meetings this month")
    #expect(turn.text.hasPrefix("Not a count of 'meetings':"))
    #expect(turn.text.contains("5 events"))
    #expect(turn.modelName == nil)
    #expect(turn.receipt?.stages.first?.name == "activity")
}

@Test("chat says what it searched when a topical window finds nothing")
func chatEmptyTopicalWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let turn = await chat(Conversation(store: store, now: now, calendar: utc), "what did I decide about ordering in 2024")
    #expect(turn.text.contains("Nothing in your history matches"))
    #expect(turn.text.contains("Window: 2024-01-01 through 2024-12-31"))
    // A window that closed long before the last sync, so nothing is missing from it.
    #expect(!turn.text.contains("Stale:"))
    #expect(turn.receipt?.stages.contains { $0.name == "window" } == true)
}

// The bug: anchors carried "last week" over as two search words, and a phrase left in the query
// text was read in preference to the one the person had just asked.
@Test("a follow-up's own time phrase beats the last question's")
func chatOwnPhraseWins() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let conversation = Conversation(store: store, now: now, calendar: utc)
    _ = await chat(conversation, "what did I do last week")
    let turn = await chat(conversation, "and what about this month")
    #expect(turn.text.contains("Window: 2026-10-01 through 2026-10-30, read from 'this month'"))
}

// The bug: "recently" is a stopword, so anchors never carried it and the follow-up searched all time.
@Test("a follow-up with no time phrase stays in the window it followed")
func chatFollowUpCarriesTheWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let conversation = Conversation(store: store, now: now, calendar: utc)
    _ = await chat(conversation, "what was I working on recently")
    let turn = await chat(conversation, "and in Quiet?")
    #expect(turn.text.contains("Window: 2026-10-16 through 2026-10-30"))
    #expect(turn.text.contains("Quiet"))
    #expect(!turn.text.contains("Current"))
}

@Test("a new question that is not a follow-up drops the last window")
func chatNewQuestionDropsTheWindow() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let conversation = Conversation(store: store, now: now, calendar: utc)
    _ = await chat(conversation, "what was I working on recently")
    // Nothing matches and no model runs. The receipt shows whether a window was read.
    let turn = await chat(conversation, "zebra quantum tarpaulin")
    #expect(turn.receipt?.stages.contains { $0.name == "window" } == false)
    #expect(!turn.text.contains("Window:"))
}

// MARK: - Follow-ups

// The bug: `searchText` took the last phrase out of the query text, which only works if the anchors
// kept it whole. "In March" reaches them as "march", because "in" is a stopword, and "last 3 days" as
// "last days", because one letter is dropped, so the leftover time word the comment said was fixed
// still reached retrieval.
@Test("the last question's time words do not become search terms", arguments: [
    ("what changed in March", ["march"]),
    ("what changed in the last 3 days", ["last", "days"]),
    ("what did I decide about ordering last week", ["last", "week"]),
])
func anchorsLeaveTimeWordsBehind(question: String, words: [String]) {
    let rewritten = Conversation.contextualizedQuery("and what about it", priorQuestions: [question], priorSourceTitles: [])
    let terms = Set(HybridSearch.ftsTerms(from: rewritten))
    for word in words { #expect(!terms.contains(word)) }
}

// The same, through retrieval. A note that says only "march" sits inside the window, so finding it
// means the old question's month was searched for. Finding nothing also means no model runs.
@Test("a follow-up searches its own topic and not the last question's month")
func followUpDoesNotSearchTheMonth() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let inMarch = instant("2026-03-10T12:00:00Z")
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        CoreObject(sourceID: github.id, kind: .document, externalID: "parade", title: "Parade", text: "The march route", authoredAt: inMarch, domain: .project, authority: .authoredArtifact),
    ])
    let conversation = Conversation(store: store, now: now, calendar: utc)
    _ = await chat(conversation, "what changed in March")
    let turn = await chat(conversation, "and what about tarpaulin")
    #expect(turn.text.contains("Nothing in your history matches"))
    #expect(turn.text.contains("Window: 2026-03-01 through 2026-03-31"))
}

// Follow-up-ness was inferred from whether anchors were added, and with the time words gone a prior
// question can have none. The window has to stay anyway.
@Test("a follow-up keeps its window when the last question left no anchors")
func followUpWithNoAnchors() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await fixture(now: now)
    let conversation = Conversation(store: store, now: now, calendar: utc)
    _ = await chat(conversation, "what did I do recently")
    let turn = await chat(conversation, "and in Quiet?")
    #expect(turn.text.contains("Window: 2026-10-16 through 2026-10-30"))
    #expect(!turn.text.contains("Current"))
}

// MARK: - Reopened threads

// The bug: `rebuildSession` replayed `turn.text`, which is the model's prose with the report on the
// end, or a whole summary no model ever saw, so a reopened thread told the model it had written
// Window, Store and Stale lines. The comment and `WindowReport` both said it never saw them.
@Test("a reopened thread gives the model only what a model wrote, without the report")
func replayLeavesTheReportOut() async throws {
    let now = instant("2026-10-30T12:00:00Z")
    let store = try await syncedFixture(now: now, syncedAt: instant("2026-10-23T12:00:00Z"))
    let conversation = Conversation(store: store, id: "thread-\(UUID().uuidString)", now: now, calendar: utc)
    // Deterministic, so a model never wrote or read it.
    let activity = await chat(conversation, "what was I working on recently")
    #expect(activity.text.contains("Window:"))

    let threadID = await conversation.id
    let report = try #require(try await Reasoner(store: store, now: now, calendar: utc).answer("what was I working on recently", persistReceipt: false).report)
    let prose = "You changed the schedule [1]."
    for (ordinal, turn) in [
        Turn(role: .you, text: "what did I decide this week"),
        Turn(role: .core, text: "\(prose)\n\n\(report.text)", modelName: "a-made-up-model"),
    ].enumerated() {
        try await store.append(StoredTurn(
            id: turn.id.uuidString, conversationID: threadID, ordinal: 2 + ordinal, role: turn.role.rawValue, text: turn.text,
            sourcesJSON: "[]", verdictsJSON: "[]", receiptID: nil, model: turn.modelName, error: nil
        ))
    }

    let restored = try await Conversation(store: store, id: threadID, now: now, calendar: utc).restore()
    // The thread still shows everything. Only the model's copy changes.
    #expect(restored.contains { $0.text.contains("Window:") })

    let exchanges = Conversation.replayedExchanges(restored)
    #expect(exchanges.map(\.question) == ["what did I decide this week"])
    #expect(exchanges.map(\.answer) == [prose])
    #expect(!exchanges.contains { $0.answer.contains("Window:") || $0.answer.contains("Stale:") || $0.answer.contains("Store:") })
}
