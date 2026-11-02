import CoreModel
import CoreSearch
import CoreStore
import Foundation

/// A calendar or reminders answer, read from the objects rather than from claims or a model.
public struct AgendaAnswer: Sendable {
    public var sentence: String
    /// Everything that matched, which can be more than `sentence` lists.
    public var events: [AgendaItem]
    public var reminders: [AgendaItem]

    /// Shared by chat and `ask`, for the reason `AggregateAnswer.receipt` is. No model ran, and these
    /// sources have no evidence rows to link: the stage says which objects the lines came from.
    public func receipt(query: String, queryClass: QueryClass, domainsAdmitted: [Domain], domainsBlocked: [Domain],
                        milliseconds: Int) -> Receipt {
        Receipt(
            query: query,
            queryClass: queryClass,
            domainsAdmitted: domainsAdmitted,
            domainsBlocked: domainsBlocked,
            stages: [ReceiptStage(
                name: "agenda",
                counters: ["events": events.count, "reminders": reminders.count],
                milliseconds: milliseconds,
                note: "read from calendar and reminder objects by date and status, written by no model"
            )],
            objectsSearched: events.count + reminders.count,
            objectsRetrieved: events.count + reminders.count,
            evidenceAdmitted: 0,
            claimsConsulted: 0,
            contradictionsSurfaced: 0,
            model: nil,
            objectsTransmitted: 0,
            confidence: nil
        )
    }
}

/// Answers an `AgendaQuestion`. See `AgendaIntent` for why this does not go through claims.
///
/// Runs under the caller's admission like every other read: with no `.personal` it declines, so a
/// project-limited phone or an MCP caller gets the ordinary path and nothing from these sources.
public struct AgendaAnswering: Sendable {
    public let store: Store
    public init(store: Store) { self.store = store }

    /// How old a sync can be before an answer says so. **Chosen, not measured:** long enough that a
    /// Mac left closed for a day stays quiet, and short enough that a week of missing plans does not.
    static let staleAfterDays = 2
    /// **Chosen, not measured:** what reads as a list on a phone rather than as a dump.
    static let shownEvents = 40
    static let shownReminders = 30

    public func answer(_ question: AgendaQuestion, policy: AdmissionPolicy, now: Date, calendar: Calendar) async throws -> AgendaAnswer? {
        guard policy.admits(.personal) else { return nil }
        var events: [AgendaItem] = []
        var reminders: [AgendaItem] = []
        var sections: [String] = []

        if question.readsCalendar, let window = question.window {
            events = Self.distinct(try await store.agendaEvents(from: window.start, to: window.end, domains: policy.admitted)
                .filter { $0.matches(question.terms) }, calendar: calendar)
            sections.append(await calendarSection(events, window: window, now: now, calendar: calendar))
        }
        if question.readsReminders {
            reminders = try await readReminders(question, policy: policy, now: now)
            sections.append(await reminderSection(reminders, question: question, now: now, calendar: calendar))
        }
        return AgendaAnswer(sentence: sections.joined(separator: "\n\n"), events: events, reminders: reminders)
    }

    /// One line for one day's "Election Day", which two holiday calendars both carry.
    static func distinct(_ events: [AgendaItem], calendar: Calendar) -> [AgendaItem] {
        var seen = Set<String>()
        return events.filter { item in
            let day = item.when.map { TemporalIntent.day($0, in: calendar) } ?? ""
            return seen.insert("\(day)|\(item.title.lowercased())").inserted
        }
    }

    private func readReminders(_ question: AgendaQuestion, policy: AdmissionPolicy, now: Date) async throws -> [AgendaItem] {
        if question.wantsCompleted {
            return try await store.agendaReminders(completed: true, from: question.window?.start, to: question.window?.end,
                                                   domains: policy.admitted)
                .filter { $0.matches(question.terms) }
        }
        let open = try await store.agendaReminders(completed: false, domains: policy.admitted)
            .filter { $0.matches(question.terms) }
        // Soonest first, so what is overdue leads. A dated window keeps what is overdue too: it is
        // still due, and "what's due this week" that leaves out last week's is how it stays overdue.
        let dated = open.filter { item in
            guard let when = item.when else { return false }
            guard let window = question.window else { return true }
            return window.contains(when) || (when < now && window.contains(now))
        }.sorted { ($0.when ?? .distantFuture, $0.title) < ($1.when ?? .distantFuture, $1.title) }
        guard question.window == nil else { return dated }
        return dated + open.filter { $0.when == nil }.sorted { $0.title < $1.title }
    }

    private func calendarSection(_ events: [AgendaItem], window: QueryTimeWindow, now: Date, calendar: Calendar) async -> String {
        let span = window.span(in: calendar)
        let chosen = window.isChosen ? " (\(window.phrase), a chosen span)" : ""
        var lines = [events.isEmpty ? "Nothing on your calendar, \(span)\(chosen)."
                                    : "Your calendar, \(span)\(chosen): \(count(events.count, "event"))."]
        lines += events.prefix(Self.shownEvents).map { line(for: $0, calendar: calendar) }
        if events.count > Self.shownEvents { lines.append("  and \(events.count - Self.shownEvents) more") }
        lines += await staleLine("Apple Calendar", handle: "calendar", now: now, calendar: calendar)
        return lines.joined(separator: "\n")
    }

    private func reminderSection(_ items: [AgendaItem], question: AgendaQuestion, now: Date, calendar: Calendar) async -> String {
        let span = question.window.map { ", \($0.span(in: calendar))" } ?? ""
        var lines: [String]
        if question.wantsCompleted {
            lines = [items.isEmpty ? "No completed reminders\(span)." : "Completed reminders\(span): \(items.count)."]
        } else {
            let overdue = items.filter { ($0.when ?? .distantFuture) < now }.count
            let late = overdue > 0 ? ", \(overdue) overdue" : ""
            lines = [items.isEmpty ? "No open reminders\(span)." : "Open reminders\(span): \(items.count)\(late)."]
        }
        lines += items.prefix(Self.shownReminders).map { item in
            let late = !question.wantsCompleted && (item.when ?? .distantFuture) < now ? "OVERDUE " : ""
            return late + line(for: item, calendar: calendar)
        }
        if items.count > Self.shownReminders { lines.append("  and \(items.count - Self.shownReminders) more") }
        lines += await staleLine("Apple Reminders", handle: "reminders", now: now, calendar: calendar)
        return lines.joined(separator: "\n")
    }

    /// A list from a source that stopped syncing reads exactly like a quiet fortnight, unless it says.
    private func staleLine(_ name: String, handle: String, now: Date, calendar: Calendar) async -> [String] {
        let synced = (try? await store.agendaLastSynced(handle)) ?? nil
        guard let synced else { return ["\(name) has never synced, so this can be missing anything."] }
        guard let limit = calendar.date(byAdding: .day, value: -Self.staleAfterDays, to: now), synced < limit else { return [] }
        return ["\(name) last synced \(TemporalIntent.day(synced, in: calendar)), so anything added since is missing. Sync it from Sources."]
    }

    private func line(for item: AgendaItem, calendar: Calendar) -> String {
        let group = item.group.map { " (\($0))" } ?? ""
        guard let when = item.when else { return "  No date  \(item.title)\(group)" }
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekday = names[calendar.component(.weekday, from: when)]
        // A reminder due on a date has no time, and midnight is how that arrives.
        let parts = calendar.dateComponents([.hour, .minute], from: when)
        let dateOnly = item.isAllDay || (parts.hour == 0 && parts.minute == 0)
        let time = dateOnly ? "" : "  \(clock(when, calendar: calendar))"
        return "  \(weekday) \(TemporalIntent.day(when, in: calendar))\(time)  \(item.title)\(group)"
    }

    private func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, parts.minute ?? 0, hour < 12 ? "AM" : "PM")
    }

    private func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
}
