import Foundation

/// What a question wants from the owner's own calendar and reminders.
public struct AgendaQuestion: Sendable, Hashable {
    public var readsCalendar: Bool
    public var readsReminders: Bool
    /// The days being asked about. Nil only for reminders with no date named, which means all of them.
    public var window: QueryTimeWindow?
    /// Words left once the framing is gone, "dentist" or "grocery". Every one has to match an item.
    public var terms: [String]
    public var wantsCompleted: Bool

    public init(readsCalendar: Bool, readsReminders: Bool, window: QueryTimeWindow?, terms: [String], wantsCompleted: Bool) {
        self.readsCalendar = readsCalendar
        self.readsReminders = readsReminders
        self.window = window
        self.terms = terms
        self.wantsCompleted = wantsCompleted
    }
}

/// Reads "what's on my calendar this week" and "what reminders do I have open".
///
/// **The defect.** Calendar and reminders produce objects and no claims, and an answer was built from
/// claims. On the real store on 2026-11-02, with 565 events and 251 open reminders in it, "what is on
/// my calendar this week" answered with OpenCore's last commit, and "what reminders do I have open"
/// with 69 claims about repositories. Retrieval could not fix that either: "open reminders" is a
/// question about a date and a flag, and no passage says which reminders are still open.
///
/// Rule-based for the reason `TemporalIntent` is, and separate from it: that one reads back from now,
/// because the store records what happened. A calendar is the one thing here that holds the future.
///
/// **Chosen, not measured:** the phrases below. No question log exists to test them against, so they
/// lean towards missing a question, which falls through to ordinary retrieval, over taking one that
/// was about the software.
public enum AgendaIntent {
    /// How far ahead "what's on my calendar" looks when no date is named.
    ///
    /// **Chosen, not measured.** Long enough to hold the next fortnight's plans, and short enough to
    /// read through. The answer says it chose this.
    public static let lookAheadDays = 14

    /// How far ahead a topic is looked for. **Chosen, not measured:** "when is my dentist appointment"
    /// names no date, and the connector reads 180 days ahead, so a year holds everything it can have.
    static let topicLookAheadDays = 365

    private static let calendarPhrases = [
        "my calendar", "on the calendar", "my schedule", "my agenda", "appointment", "appointments",
        "my meetings", "any meetings", "what meetings", "my events", "any events", "am i free", "am i busy",
    ]
    /// Nobody asks about a birthday in software, so "when is Sam's birthday" needs no "my" or "I".
    private static let birthdayPhrases = ["birthday", "birthdays"]
    private static let reminderPhrases = [
        "reminder", "reminders", "my to-do", "my todo", "my to do", "to-do list", "todo list", "my tasks",
        "on my list", "overdue", "need to do", "have to do",
    ]
    /// Nobody asks these about software, so they need no "my" or "I" beside them.
    private static let duePhrases = ["due today", "due tomorrow", "due this week", "due next week", "what's due", "whats due", "what is due"]
    private static let bothPhrases = [
        "what's coming up", "whats coming up", "what is coming up", "do i have today", "do i have tomorrow",
        "do i have tonight", "do i have this week", "do i have next week", "do i have this weekend", "do i have on",
    ]
    private static let softwareWords = [
        "connector", "sync", "syncing", "synced", "code", "bug", "permission", "permissions", "api", "eventkit",
        "feature", "implement", "implemented", "screen", "tab",
    ]
    private static let completedPhrases = ["completed", "finished", "checked off", "i finish", "i complete"]

    private static let framing: Set<String> = [
        "calendar", "calendars", "schedule", "scheduled", "agenda", "appointment", "appointments", "meeting",
        "meetings", "event", "events", "reminder", "reminders", "todo", "to-do", "task", "tasks", "list", "lists",
        "open", "due", "overdue", "upcoming", "coming", "today", "tomorrow", "tonight", "free", "busy", "need",
        "needs", "going", "got", "get", "next", "week", "weekend", "month", "day", "days", "completed", "complete",
        "finish", "finished", "done", "left", "still", "pending", "outstanding", "remaining", "anything",
        "everything", "things", "stuff", "show", "tell", "give", "see", "soon", "happening", "much", "many",
        "else", "am", "plans", "planned", "checked", "off", "today's", "tomorrow's", "s",
    ]

    /// The agenda question in `query`, or nil when it is not one.
    public static func read(_ query: String, now: Date = Date(), calendar: Calendar = .current) -> AgendaQuestion? {
        let lowered = query.lowercased().replacingOccurrences(of: "’", with: "'")
        let has: (String) -> Bool = { AdmissionPolicy.containsWord($0, in: lowered) }
        // "How does OpenCore sync reminders" and "which project handles appointments" are about software.
        guard !AdmissionPolicy.projectContextMarkers.contains(where: has), !softwareWords.contains(where: has),
              !lowered.hasPrefix("why "), !lowered.hasPrefix("how does "), !lowered.hasPrefix("how do ")
        else { return nil }

        let firstPerson = ["my", "i", "me"].contains(where: has)
        let namesList = lowered.contains(/\bmy\s+[a-z\/-]+(?:\s+[a-z\/-]+)?\s+list\b/)
        let both = bothPhrases.contains(where: has)
        let readsCalendar = both || birthdayPhrases.contains(where: has) || (firstPerson && calendarPhrases.contains(where: has))
        let readsReminders = both || duePhrases.contains(where: has) || namesList
            || (firstPerson && reminderPhrases.contains(where: has))
        guard readsCalendar || readsReminders else { return nil }

        let dated = forward(in: lowered, query: query, now: now, calendar: calendar)
            ?? TemporalIntent.window(in: query, now: now, calendar: calendar)
        let terms = terms(in: dated?.residualQuery ?? query)
        let window = dated ?? (readsCalendar ? ahead(hasTopic: !terms.isEmpty, query: query, now: now, calendar: calendar) : nil)
        return AgendaQuestion(
            readsCalendar: readsCalendar, readsReminders: readsReminders, window: window, terms: terms,
            wantsCompleted: completedPhrases.contains(where: has)
        )
    }

    /// The words an item has to contain. "Birthdays" finds "Birthday", which is all the stemming
    /// this needs: an item's text is short, and each word has to be there.
    static func terms(in text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "’s", with: " ").replacingOccurrences(of: "'s", with: " ")
        return HybridSearch.ftsTerms(from: cleaned)
            .filter { !framing.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    }

    private static func ahead(hasTopic: Bool, query: String, now: Date, calendar: Calendar) -> QueryTimeWindow {
        let today = calendar.startOfDay(for: now)
        let days = hasTopic ? topicLookAheadDays : lookAheadDays
        return QueryTimeWindow(
            start: today, end: calendar.date(byAdding: .day, value: days, to: today) ?? today,
            phrase: "the next \(days) days", residualQuery: query, isChosen: true
        )
    }

    /// Spans that reach ahead of now. Whole days, because "today" on a calendar includes this evening.
    private static func forward(in lowered: String, query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        func span(_ phrase: String, _ start: Date, _ end: Date, chosen: Bool = false) -> QueryTimeWindow {
            QueryTimeWindow(start: start, end: end, phrase: phrase,
                            residualQuery: TemporalIntent.residual(of: query, removing: [phrase]), isChosen: chosen)
        }
        func day(_ phrase: String, _ date: Date) -> QueryTimeWindow {
            span(phrase, date, calendar.date(byAdding: .day, value: 1, to: date) ?? date)
        }

        // "next 3 days" and "coming two weeks" before "next week", which neither of them contains.
        for match in lowered.matches(of: /\b(?:next|coming)\s+([a-z0-9]+)\s+(days?|weeks?|months?)\b/) {
            guard let count = TemporalIntent.number(from: String(match.1)), count > 0,
                  let component = TemporalIntent.unit(named: String(match.2)),
                  let end = calendar.date(byAdding: component, value: count, to: today)
            else { continue }
            return span(String(match.0), today, end)
        }
        // **Chosen.** "Next Tuesday" is the first one after today. People also use it to skip the
        // one this week, and the words do not settle which, so the answer shows the date it read.
        for match in lowered.matches(of: /\bnext\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b/) {
            guard let weekday = TemporalIntent.weekdays[String(match.1)] else { continue }
            return day(String(match.0), upcoming(weekday, from: tomorrow, calendar: calendar))
        }
        for match in lowered.matches(of: /\b(?:on|this)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b/) {
            guard let weekday = TemporalIntent.weekdays[String(match.1)] else { continue }
            return day(String(match.0), upcoming(weekday, from: today, calendar: calendar))
        }
        for match in lowered.matches(of: /\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\s+(\d{1,2})(?:st|nd|rd|th)?\b/) {
            guard let month = TemporalIntent.months[String(match.1)], let number = Int(match.2) else { continue }
            let year = calendar.component(.year, from: today)
            // A date with no year is its next occurrence, because a calendar question looks ahead.
            for candidate in [year, year + 1] {
                let parts = DateComponents(year: candidate, month: month, day: number)
                guard let date = calendar.date(from: parts),
                      calendar.dateComponents([.year, .month, .day], from: date) == parts
                else { break }
                if date >= today { return day(String(match.0), date) }
            }
        }

        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        let thisWeekend = calendar.dateIntervalOfWeekend(containing: now) ?? calendar.nextWeekend(startingAfter: now)
        let rules: [(String, () -> QueryTimeWindow?)] = [
            ("day after tomorrow", { day("day after tomorrow", calendar.date(byAdding: .day, value: 2, to: today) ?? today) }),
            ("tomorrow", { day("tomorrow", tomorrow) }),
            ("tonight", {
                let evening = calendar.date(bySettingHour: TemporalIntent.eveningHour, minute: 0, second: 0, of: today) ?? today
                return span("tonight", evening, tomorrow, chosen: true)
            }),
            ("today", { day("today", today) }),
            ("this weekend", { thisWeekend.map { span("this weekend", $0.start, $0.end) } }),
            ("next weekend", {
                thisWeekend.flatMap { calendar.nextWeekend(startingAfter: $0.end) }.map { span("next weekend", $0.start, $0.end) }
            }),
            ("this week", { week.map { span("this week", $0.start, $0.end) } }),
            ("next week", {
                week.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0.end) }.map { span("next week", $0.start, $0.end) }
            }),
            ("this month", { month.map { span("this month", $0.start, $0.end) } }),
            ("next month", {
                month.flatMap { calendar.dateInterval(of: .month, for: $0.end) }.map { span("next month", $0.start, $0.end) }
            }),
        ]
        for (phrase, rule) in rules where AdmissionPolicy.containsWord(phrase, in: lowered) {
            if let window = rule() { return window }
        }
        return nil
    }

    /// The first `weekday` on or after `date`.
    private static func upcoming(_ weekday: Int, from date: Date, calendar: Calendar) -> Date {
        let forward = (weekday - calendar.component(.weekday, from: date) + 7) % 7
        return calendar.date(byAdding: .day, value: forward, to: date) ?? date
    }
}
