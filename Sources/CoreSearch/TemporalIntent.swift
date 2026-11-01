import Foundation

/// The stretch of time a question is about, when it names one.
public struct QueryTimeWindow: Sendable, Hashable, Codable {
    /// Inclusive.
    public var start: Date
    /// Exclusive.
    public var end: Date
    /// The words that produced this window, so an answer can say what it took them to mean.
    public var phrase: String
    /// The question with the time words taken out, which is what text search should look for.
    /// "last week" is a filter on the corpus, not two more words to match in it.
    public var residualQuery: String
    /// True when the span is this program's reading of a vague phrase rather than what the words
    /// define. "Last week" has edges. "Recently" has only the ones `TemporalIntent` picked, and
    /// an answer has to say so, or a chosen fourteen days reads as a fact about the word.
    public var isChosen: Bool

    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// What text search should look for: the residual, or nothing when the residual has no
    /// subject. One rule for every search surface. `core_search` and `opencore passages` kept the
    /// residual whole, so "what was I working on recently" still searched the word "working"
    /// while the app, reading the same store, searched nothing.
    public var searchText: String {
        TemporalIntent.isSubjectless(residualQuery) ? "" : residualQuery
    }

    /// True when the phrase asks about how things stand rather than about a stretch of time.
    /// "How many repositories are archived these days" asks for today's count, which the store
    /// holds, and no event in a window can give it. "Recently" and "lately" ask what changed.
    public var meansNow: Bool { phrase.caseInsensitiveCompare("these days") == .orderedSame }

    public init(start: Date, end: Date, phrase: String, residualQuery: String, isChosen: Bool = false) {
        self.start = start
        self.end = end
        self.phrase = phrase
        self.residualQuery = residualQuery
        self.isChosen = isChosen
    }

    /// The window as days in `calendar`, last day included.
    ///
    /// `end` is exclusive, so "last week" ends at midnight on the Monday after it. Printing that
    /// Monday told a reader the week had eight days and a Monday it did not contain.
    public func span(in calendar: Calendar) -> String {
        let first = TemporalIntent.day(start, in: calendar)
        let lastInstant = calendar.startOfDay(for: end) == end ? calendar.date(byAdding: .day, value: -1, to: end) ?? end : end
        let last = TemporalIntent.day(max(start, lastInstant), in: calendar)
        return first == last ? first : "\(first) through \(last)"
    }
}

/// Reads a time window out of a question, or reports that there is none.
///
/// **The defect this replaces.** "recently" was a stopword and `.temporal` only added a
/// tie-breaker of at most 0.00015 to a passage's score, less than one rank step, so "what was I
/// working on recently" searched for the word "working" across all of time and no path filtered
/// by date. A time word in a question is a constraint on the answer. Treating it as a ranking
/// hint is how a two-year-old README answers a question about this week.
///
/// Rule-based and deterministic, for the same reason as `QueryClassifier`: a transparent rule
/// that says what it matched beats an opaque guess, and the phrase travels with the answer. The
/// clock and calendar are arguments because every edge here is local: "yesterday" is 23 hours
/// long on the day the clocks change, and whether a commit at 23:30 was last week depends on
/// where its owner was standing.
///
/// Not read, so a question using them is searched across all of time: single dated days ("on
/// October 12", "last Monday"), future spans ("next week", "tonight", "this weekend"), ranges with
/// two ends ("from March to May"), and a position inside anything but a named month or year ("the
/// last week of the sprint"). `TemporalIntentTests` pins this list.
public enum TemporalIntent {
    /// How far back "recently" reaches.
    ///
    /// **Chosen, not measured.** Two weeks is long enough to span one interrupted stretch of
    /// work and short enough that the answer differs from "everything". Nothing has measured
    /// what people mean by the word.
    public static let recentDays = 14

    /// What "a few" counts as. **Chosen, not measured:** the word has no value of its own.
    static let fewCount = 3

    /// Where the parts of a day begin. **Chosen, not measured:** clock-face conventions, because
    /// nobody's morning ends at a time the words define. Every span built from these is marked
    /// chosen.
    static let noonHour = 12
    static let eveningHour = 18
    static let nightEndsHour = 6

    /// Words that only frame a time question. With the time phrase gone, a query left with
    /// nothing but these has no subject, so it should be answered from activity rather than
    /// from a text search for the word "working".
    static let framingTerms: Set<String> = [
        "working", "worked", "work", "doing", "done", "busy", "happening", "happened", "going",
        "get", "got", "getting", "change", "changed", "changes", "new", "activity", "touched",
        "touch", "shipped", "ship", "commit", "commits", "committed", "build", "built", "building",
        "make", "made", "making", "write", "wrote", "writing", "project", "projects", "repo",
        "repos", "repository", "repositories", "app", "apps", "code", "anything", "everything",
        "things", "stuff", "show", "tell", "list", "give", "see", "many", "much", "number",
        "count", "total", "events", "event", "timeline",
    ]

    /// The window `query` names, relative to `now`, or nil when it names none.
    public static func window(
        in query: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QueryTimeWindow? {
        let calendar = gregorian(matching: calendar)
        // "since last week" holds "last week", and it means something else: a window that ends
        // now. So this is read before the phrases it can contain.
        return sinceWindow(in: query, now: now, calendar: calendar)
            // These two hold "last week" and "last year" as well, and mean something narrower.
            ?? partWindow(in: query, now: now, calendar: calendar)
            ?? relativeMonthWindow(in: query, now: now, calendar: calendar)
            ?? fixedWindow(in: query, now: now, calendar: calendar)
            ?? rollingWindow(in: query, now: now, calendar: calendar)
            ?? agoWindow(in: query, now: now, calendar: calendar)
            ?? yearWindow(in: query, now: now, calendar: calendar)
            ?? monthWindow(in: query, now: now, calendar: calendar)
    }

    /// True when the question has no subject beyond its time phrase, framing words, and any
    /// `names` it spent on something the store knows.
    public static func isSubjectless(_ residualQuery: String, naming names: Set<String> = []) -> Bool {
        unplacedTerms(in: residualQuery, naming: names).isEmpty
    }

    /// The words of `residualQuery` that are neither framing nor one of `names`, in order. A
    /// count from the event log has to say so when these are what the question wanted counted.
    public static func unplacedTerms(in residualQuery: String, naming names: Set<String> = []) -> [String] {
        HybridSearch.ftsTerms(from: residualQuery).filter { !framingTerms.contains($0) && !names.contains($0) }
    }

    /// `query` with each of `phrases` taken out and its whitespace closed up.
    public static func residual(of query: String, removing phrases: [String]) -> String {
        var result = query
        for phrase in phrases {
            guard let range = result.range(of: phrase, options: .caseInsensitive) else { continue }
            result.replaceSubrange(range, with: " ")
        }
        return result
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// `date` as `yyyy-MM-dd` in `calendar`, whatever the machine's zone or era. Read from
    /// components rather than a formatter, so it needs no locale and cannot print year 8 of
    /// Reiwa into an answer about 2026.
    public static func day(_ date: Date, in calendar: Calendar) -> String {
        let parts = gregorian(matching: calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The caller's calendar with Gregorian months and years, keeping what makes it local.
    ///
    /// The phrases are English month names, and "in March 2025" written against a Buddhist or
    /// Japanese calendar's year numbering lands centuries away. Time zone and first weekday are
    /// the caller's, because those are what decide where a week or a day begins.
    private static func gregorian(matching calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        result.locale = calendar.locale
        result.firstWeekday = calendar.firstWeekday
        result.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return result
    }

    // MARK: - Fixed phrases

    private struct Rule {
        var phrases: [String]
        var start: Date
        var end: Date
        var isChosen = false
    }

    private static func shifted(_ component: Calendar.Component, by value: Int, from date: Date, in calendar: Calendar) -> Date {
        calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    private static func interval(_ component: Calendar.Component, containing date: Date, in calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// `hour` o'clock on `day`, through the calendar, so a day with a clock change keeps its noon.
    private static func hour(_ hour: Int, on day: Date, in calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// When last night began. It is yesterday's evening, whichever day the question falls on.
    private static func nightStart(now: Date, calendar: Calendar) -> Date {
        hour(eveningHour, on: shifted(.day, by: -1, from: calendar.startOfDay(for: now), in: calendar), in: calendar)
    }

    /// The last whole weekend, or nil in a calendar that has none. Asked on a Saturday this is the
    /// one before: the search starts from the opening of the weekend `now` is in, because
    /// `nextWeekend` (`.backward`, "strictly before the given date") only skips a weekend that
    /// began after the date it is given. Which days count is the calendar's and locale's.
    private static func lastWeekend(before now: Date, calendar: Calendar) -> DateInterval? {
        let anchor = calendar.dateIntervalOfWeekend(containing: now)?.start ?? now
        return calendar.nextWeekend(startingAfter: anchor, direction: .backward)
    }

    /// The whole period before the one `now` is in.
    private static func previous(_ component: Calendar.Component, before now: Date, in calendar: Calendar) -> DateInterval {
        let current = interval(component, containing: now, in: calendar)
        return interval(component, containing: shifted(.day, by: -1, from: current.start, in: calendar), in: calendar)
    }

    private static func rules(now: Date, calendar: Calendar) -> [Rule] {
        let today = calendar.startOfDay(for: now)
        let week = interval(.weekOfYear, containing: now, in: calendar)
        let lastWeek = previous(.weekOfYear, before: now, in: calendar)
        let month = interval(.month, containing: now, in: calendar)
        let lastMonth = previous(.month, before: now, in: calendar)
        let year = interval(.year, containing: now, in: calendar)
        let lastYear = previous(.year, before: now, in: calendar)
        let recent = shifted(.day, by: -recentDays, from: now, in: calendar)
        let yesterday = shifted(.day, by: -1, from: today, in: calendar)
        let tomorrow = shifted(.day, by: 1, from: today, in: calendar)
        let noon = hour(noonHour, on: today, in: calendar)
        let evening = hour(eveningHour, on: today, in: calendar)

        var rules = [
            // Longest phrases first, so "this past week" is not read as "past week" plus noise.
            Rule(phrases: ["last hour", "past hour"], start: shifted(.hour, by: -1, from: now, in: calendar), end: now),
            Rule(phrases: ["past day"], start: shifted(.day, by: -1, from: now, in: calendar), end: now),
            Rule(phrases: ["this past week", "past week"], start: shifted(.day, by: -7, from: now, in: calendar), end: now),
            Rule(phrases: ["this past month", "past month"], start: shifted(.month, by: -1, from: now, in: calendar), end: now),
            Rule(phrases: ["this past year", "past year"], start: shifted(.year, by: -1, from: now, in: calendar), end: now),
            Rule(phrases: ["last week"], start: lastWeek.start, end: lastWeek.end),
            Rule(phrases: ["this week"], start: week.start, end: now),
            Rule(phrases: ["last month"], start: lastMonth.start, end: lastMonth.end),
            Rule(phrases: ["this month"], start: month.start, end: now),
            Rule(phrases: ["last year"], start: lastYear.start, end: lastYear.end),
            Rule(phrases: ["this year"], start: year.start, end: now),
            // Ahead of "yesterday", which it contains.
            Rule(phrases: ["the day before yesterday", "day before yesterday"], start: shifted(.day, by: -2, from: today, in: calendar), end: yesterday),
            Rule(phrases: ["yesterday"], start: yesterday, end: today),
            Rule(phrases: ["last night"], start: nightStart(now: now, calendar: calendar), end: hour(nightEndsHour, on: today, in: calendar), isChosen: true),
            Rule(phrases: ["this morning"], start: today, end: noon, isChosen: true),
            Rule(phrases: ["this afternoon"], start: noon, end: evening, isChosen: true),
            Rule(phrases: ["this evening"], start: evening, end: tomorrow, isChosen: true),
            Rule(phrases: ["so far today", "today"], start: today, end: now),
            Rule(
                phrases: ["recently changed", "recently", "lately", "of late", "these days", "in recent days", "in recent weeks"],
                start: recent, end: now, isChosen: true
            ),
        ]
        if let weekend = lastWeekend(before: now, calendar: calendar) {
            rules.append(Rule(phrases: ["last weekend"], start: weekend.start, end: weekend.end))
        }
        return rules
    }

    /// Phrases that name a position when "of" follows them. "The last week of the sprint" is a
    /// week inside something this cannot date, and reading it as last week put the answer on the
    /// wrong days under a Window line that looked right.
    private static let positional: Set<String> = ["last hour", "last week", "last month", "last year"]

    private static func fixedWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        let lowered = query.lowercased()
        for rule in rules(now: now, calendar: calendar) {
            for phrase in rule.phrases where AdmissionPolicy.containsWord(phrase, in: lowered) {
                if positional.contains(phrase), lowered.contains("\(phrase) of ") { continue }
                // "This evening" asked at ten in the morning is still to come.
                let end = min(rule.end, now)
                guard rule.start <= end else { continue }
                return QueryTimeWindow(
                    start: rule.start, end: end, phrase: phrase,
                    residualQuery: residual(of: query, removing: [phrase]), isChosen: rule.isChosen
                )
            }
        }
        return nil
    }

    // MARK: - Spelled-out spans

    private static let units: [(names: [String], component: Calendar.Component)] = [
        (["hour", "hours"], .hour), (["day", "days"], .day), (["week", "weeks"], .weekOfYear),
        (["month", "months"], .month), (["year", "years"], .year),
    ]

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "couple": 2, "three": 3, "few": fewCount, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12,
    ]

    private static func number(from text: String) -> Int? {
        Int(text) ?? numberWords[text]
    }

    private static func unit(named text: String) -> Calendar.Component? {
        units.first(where: { $0.names.contains(text) })?.component
    }

    /// "last 3 days", "past two weeks", "the past few months", "last couple of weeks".
    ///
    /// Every match is tried, because the first can be a false start: "the last commit in the
    /// past 3 days" matches "last commit in" before it reaches the span.
    private static func rollingWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        for match in query.matches(of: /\b(last|past)\s+([a-z0-9]+)(?:\s+of)?\s+([a-z]+)\b(\s+of\b)?/.ignoresCase()) {
            let word = match.2.lowercased()
            guard let count = number(from: word), count > 0,
                  let component = unit(named: match.3.lowercased()),
                  let start = calendar.date(byAdding: component, value: -count, to: now)
            else { continue }
            // "The last 3 days of September" are not the last 3 days. See `positional`.
            if match.4 != nil, match.1.lowercased() == "last" { continue }
            let phrase = String(match.0.dropLast(match.4?.count ?? 0))
            return QueryTimeWindow(
                start: start, end: now, phrase: phrase,
                residualQuery: residual(of: query, removing: [phrase]), isChosen: word == "few"
            )
        }
        return nil
    }

    /// "three weeks ago" means the week it lands in, not a single instant.
    ///
    /// **Chosen, not measured.** An instant would match nothing, so some span is needed, and the
    /// calendar unit is the one that needs no new constant. Marked as chosen for that reason.
    private static func agoWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        for match in query.matches(of: /\b([a-z0-9]+)(?:\s+of)?\s+([a-z]+)\s+ago\b/.ignoresCase()) {
            guard let count = number(from: match.1.lowercased()), count > 0,
                  let component = unit(named: match.2.lowercased()),
                  let target = calendar.date(byAdding: component, value: -count, to: now),
                  let span = calendar.dateInterval(of: component, for: target)
            else { continue }
            let phrase = String(match.0)
            return QueryTimeWindow(
                start: span.start, end: min(span.end, now), phrase: phrase,
                residualQuery: residual(of: query, removing: [phrase]), isChosen: true
            )
        }
        return nil
    }

    // MARK: - Since

    private static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
        "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// A month with no year means its most recent occurrence, this month included.
    private static func monthStart(_ month: Int, year: Int?, now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.month = month
        components.day = 1
        if let year {
            components.year = year
        } else {
            let thisYear = calendar.component(.year, from: now)
            components.year = month <= calendar.component(.month, from: now) ? thisYear : thisYear - 1
        }
        return calendar.date(from: components)
    }

    /// `yyyy-MM-dd` as midnight in `calendar`. Assembled from components so the date means that
    /// day where the owner is. A formatter here used the machine's zone whatever calendar came
    /// in. `date(from:)` is lenient, so a "2026-02-31" has to be read back to be refused.
    private static func isoDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components
        else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// The most recent `weekday` strictly before today. "Since Monday", said on a Monday, means
    /// the one a week ago: the phrase is pointing back at a day, not at this morning.
    private static func previousWeekday(_ weekday: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let back = (calendar.component(.weekday, from: today) - weekday + 7) % 7
        return shifted(.day, by: -(back == 0 ? 7 : back), from: today, in: calendar)
    }

    /// Where "since …" starts, or nil when the word after it is not a date. A bare "since" is
    /// usually "because".
    private static func sinceAnchor(
        word: String, modifier: String?, year: Int?, startOfPeriod: Bool, now: Date, calendar: Calendar
    ) -> Date? {
        if let month = months[word] { return monthStart(month, year: year, now: now, calendar: calendar) }
        guard year == nil else { return nil }
        if word.hasSuffix("day before yesterday") {
            return shifted(.day, by: -2, from: calendar.startOfDay(for: now), in: calendar)
        }
        if let weekday = weekdays[word] { return previousWeekday(weekday, now: now, calendar: calendar) }
        if word == "yesterday", modifier == nil {
            return shifted(.day, by: -1, from: calendar.startOfDay(for: now), in: calendar)
        }
        if word.count == 10, word.contains("-"), modifier == nil { return isoDay(word, calendar: calendar) }
        if word.count == 4, let bareYear = Int(word), modifier == nil {
            return calendar.date(from: DateComponents(year: bareYear, month: 1, day: 1))
        }
        switch (modifier, word) {
        case ("this", "morning"): return calendar.startOfDay(for: now)
        case ("last", "night"): return nightStart(now: now, calendar: calendar)
        case ("last", "weekend"): return lastWeekend(before: now, calendar: calendar)?.start
        default: break
        }

        let period: Calendar.Component? = switch word {
        case "week": .weekOfYear
        case "month": .month
        case "year": .year
        default: nil
        }
        guard let period else { return nil }
        switch modifier {
        case "last": return previous(period, before: now, in: calendar).start
        case "this": return interval(period, containing: now, in: calendar).start
        // "Since the start of the year" says which year by leaving it out. A bare "since the year"
        // says nothing.
        default: return startOfPeriod ? interval(period, containing: now, in: calendar).start : nil
        }
    }

    /// "since August", "since August 2025", "since March last year", "since 2025", "since
    /// 2026-10-01", "since Monday", "since yesterday", "since last week", "since last night",
    /// "since the start of this month", "since the beginning of the year". Always ends now.
    ///
    /// The bare "the" was missing from the prefix, so "since the start of the year" matched
    /// nothing and searched all of time.
    private static func sinceWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        let pattern = /\bsince\s+(the\s+(?:start|beginning)\s+of\s+(?:the\s+)?)?(?:(last|this)\s+)?((?:the\s+)?day\s+before\s+yesterday|[a-z0-9-]+)(?:\s+(?:of\s+)?(?:(\d{4})|(last|this)\s+year))?\b/.ignoresCase()
        for match in query.matches(of: pattern) {
            let year = match.4.flatMap { Int($0) }
                ?? match.5.map { relativeYear($0.lowercased(), now: now, calendar: calendar) }
            guard let start = sinceAnchor(
                word: match.3.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " "),
                modifier: match.2.map { $0.lowercased() },
                year: year,
                startOfPeriod: match.1 != nil,
                now: now,
                calendar: calendar
            ), start < now else { continue }
            let phrase = String(match.0)
            return QueryTimeWindow(start: start, end: now, phrase: phrase, residualQuery: residual(of: query, removing: [phrase]))
        }
        return nil
    }

    // MARK: - Named periods

    /// The year "this" or "last" points at.
    private static func relativeYear(_ modifier: String, now: Date, calendar: Calendar) -> Int {
        calendar.component(.year, from: now) - (modifier == "last" ? 1 : 0)
    }

    /// "the last week of September", "the first month of 2025", "the last day of March 2024".
    ///
    /// **The defect.** These held "last week" and "last month", so they read as the week or month
    /// just gone: the right words in the Window line and the wrong days in the answer.
    ///
    /// A week here is seven days from the edge of the period, which is a choice: calendar weeks
    /// do not line up with months, and the words do not say which one was meant. So it is marked
    /// chosen. A day and a month are defined.
    private static func partWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        let pattern = /\b(?:the\s+)?(first|last)\s+(day|week|month)\s+of\s+(?:(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)(?:\s+(?:of\s+)?(\d{4}))?|((?:19|20)\d{2}))\b/.ignoresCase()
        for match in query.matches(of: pattern) {
            let unit = match.2.lowercased()
            let whole: DateInterval?
            if let name = match.3 {
                // "The last month of March" is not a stretch of time.
                guard unit != "month", let month = months[name.lowercased()] else { continue }
                whole = monthStart(month, year: match.4.flatMap { Int($0) }, now: now, calendar: calendar)
                    .flatMap { calendar.dateInterval(of: .month, for: $0) }
            } else {
                whole = match.5.flatMap { Int($0) }
                    .flatMap { calendar.date(from: DateComponents(year: $0, month: 1, day: 1)) }
                    .flatMap { calendar.dateInterval(of: .year, for: $0) }
            }
            guard let whole else { continue }

            let (component, count): (Calendar.Component, Int) = switch unit {
            case "day": (.day, 1)
            case "week": (.day, 7)
            default: (.month, 1)
            }
            let fromEnd = match.1.lowercased() == "last"
            let start = fromEnd ? shifted(component, by: -count, from: whole.end, in: calendar) : whole.start
            let end = fromEnd ? whole.end : shifted(component, by: count, from: whole.start, in: calendar)
            guard start < now else { continue }
            let phrase = String(match.0)
            return QueryTimeWindow(
                start: start, end: min(end, now), phrase: phrase,
                residualQuery: residual(of: query, removing: [phrase]), isChosen: unit == "week"
            )
        }
        return nil
    }

    /// "in March last year", "March of this year", "last March".
    ///
    /// **The defect.** "Last year" was read first, so "in March last year" gave the whole of last
    /// year and left "in March" behind as search text. "Last March" had no reading at all.
    ///
    /// "May" needs its preposition, or "it may last year round" would be a month.
    private static func relativeMonthWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        let named = /\b((?:back\s+in|in|during)\s+)?(?:the\s+month\s+of\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\s+(?:of\s+)?(last|this)\s+year\b/.ignoresCase()
        for match in query.matches(of: named) {
            guard let month = months[match.2.lowercased()],
                  match.1 != nil || month != months["may"]
            else { continue }
            let year = relativeYear(match.3.lowercased(), now: now, calendar: calendar)
            if let window = monthWindow(month, year: year, phrase: String(match.0), query: query, now: now, calendar: calendar) {
                return window
            }
        }
        for match in query.matches(of: /\blast\s+(january|february|march|april|may|june|july|august|september|october|november|december)\b(?!\s+of\b)/.ignoresCase()) {
            guard let month = months[match.1.lowercased()] else { continue }
            // The one before the month `now` is in. Said in October, "last October" is a year ago.
            let thisYear = calendar.component(.year, from: now)
            let year = month < calendar.component(.month, from: now) ? thisYear : thisYear - 1
            if let window = monthWindow(month, year: year, phrase: String(match.0), query: query, now: now, calendar: calendar) {
                return window
            }
        }
        return nil
    }

    private static func monthWindow(
        _ month: Int, year: Int, phrase: String, query: String, now: Date, calendar: Calendar
    ) -> QueryTimeWindow? {
        guard let start = monthStart(month, year: year, now: now, calendar: calendar), start < now,
              let span = calendar.dateInterval(of: .month, for: start)
        else { return nil }
        return QueryTimeWindow(start: span.start, end: min(span.end, now), phrase: phrase, residualQuery: residual(of: query, removing: [phrase]))
    }

    /// "in 2025", "during 2024". Not "in 2025-10", which is a date this does not read.
    private static func yearWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        for match in query.matches(of: /\b(?:back\s+in|in|during)\s+((?:19|20)\d{2})\b(?!-)/.ignoresCase()) {
            guard let year = Int(match.1),
                  let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  start < now,
                  let span = calendar.dateInterval(of: .year, for: start)
            else { continue }
            let phrase = String(match.0)
            return QueryTimeWindow(start: span.start, end: min(span.end, now), phrase: phrase, residualQuery: residual(of: query, removing: [phrase]))
        }
        return nil
    }

    /// "in March", "in March 2025", "back in Oct". A month with no year is its most recent
    /// occurrence.
    ///
    /// The months are in the pattern rather than checked after it. Matching any word and then
    /// looking it up stopped at the first "in", so "what changed in the repo in March" had no
    /// window at all.
    private static func monthWindow(in query: String, now: Date, calendar: Calendar) -> QueryTimeWindow? {
        let pattern = /\b(?:back\s+in|in|during)\s+(?:the\s+month\s+of\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)(?:\s+(?:of\s+)?(\d{4}))?\b/.ignoresCase()
        for match in query.matches(of: pattern) {
            guard let month = months[match.1.lowercased()],
                  let start = monthStart(month, year: match.2.flatMap { Int($0) }, now: now, calendar: calendar),
                  start < now,
                  let span = calendar.dateInterval(of: .month, for: start)
            else { continue }
            let phrase = String(match.0)
            return QueryTimeWindow(start: span.start, end: min(span.end, now), phrase: phrase, residualQuery: residual(of: query, removing: [phrase]))
        }
        return nil
    }
}
