import CoreModel
import CoreSearch
import CoreStore
import Foundation

/// What an answer about a stretch of time has to say about itself: which days it read, whether
/// those days were chosen, and how far the store had got.
///
/// **The defect this exists for.** A question about this week was answered from what the store
/// held, and the store's newest sync was a week old, so "nothing much" and "nothing synced" read
/// the same. An empty answer named the newest event, and a thin one said nothing at all, which is
/// the worse of the two: three commits from a week the store only half saw looks complete.
///
/// One type, so `ask`, chat, `core_ask` and `core_search` print the same lines. Written in code
/// and never by a model, and it is appended to a model's prose rather than handed to it, so
/// nothing here is subject to the model getting it wrong. That includes a reopened thread: a saved
/// turn's text holds the prose and this together, and `Conversation.replayedExchanges` takes this
/// back off before the model reads its own earlier answers.
public struct WindowReport: Sendable {
    public var window: QueryTimeWindow
    public var freshness: StoreFreshness
    public var calendar: Calendar

    /// How far a source's last sync may trail the end of a window before the answer says so.
    ///
    /// **Chosen, not measured.** Four runs of the longest scheduled interval
    /// (`SyncSchedule.Job.interval`, six hours), so one missed run is not an alarm and a source
    /// that has stopped is.
    public static let staleAfter: TimeInterval = 24 * 3_600

    public init(window: QueryTimeWindow, freshness: StoreFreshness, calendar: Calendar) {
        self.window = window
        self.freshness = freshness
        self.calendar = calendar
    }

    /// Sources that stopped short of the window's end. For a window that closed before the last
    /// sync this is empty: a stale store can still answer fully about last year.
    public var behind: [SourceFreshness] {
        freshness.sources.filter { source in
            guard let synced = source.lastSyncedAt else { return true }
            return window.end.timeIntervalSince(synced) > Self.staleAfter
        }
    }

    private func synced(_ source: SourceFreshness) -> String {
        source.lastSyncedAt.map { "\(source.label) \(TemporalIntent.day($0, in: calendar))" }
            ?? "\(source.label) never"
    }

    public var lines: [String] {
        let chosen = window.isChosen ? ", a chosen span, not a measured one" : ""
        var lines = ["\(Self.opening)\(window.span(in: calendar)), read from '\(window.phrase)'\(chosen)."]

        let newest = freshness.newestEventAt.map { "The newest admitted event is from \(TemporalIntent.day($0, in: calendar))." }
            ?? "No admitted event is recorded."
        let sources = freshness.sources.isEmpty
            ? "No synced source holds anything readable here."
            : "Last synced: \(freshness.sources.map(synced).joined(separator: ", "))."
        lines.append("Store: \(newest) \(sources)")

        if !behind.isEmpty {
            lines.append("Stale: \(behind.map(synced).joined(separator: ", ")). "
                + "This window runs past that, so anything later is missing from the store, not quiet.")
        }
        return lines
    }

    public var text: String { lines.joined(separator: "\n") }

    /// How the first line opens, and what marks where a report begins in a saved turn.
    private static let opening = "Window: "

    /// `text` without the report on its end. A turn's prose is one paragraph of sentences or ends
    /// in one, so a blank line then this word is the join `Conversation` wrote.
    static func removed(from text: String) -> String {
        guard let join = text.range(of: "\n\n\(opening)", options: .backwards) else { return text }
        return String(text[..<join.lowerBound])
    }

    /// One line for a receipt stage, which `core_trace` prints.
    public var stageNote: String {
        var note = "'\(window.phrase)' read as \(window.span(in: calendar))"
        if window.isChosen { note += " (chosen)" }
        if !behind.isEmpty { note += "; stale: \(behind.map(synced).joined(separator: ", "))" }
        return note
    }
}

extension Store {
    /// The report for `window`, as far as a caller admitted to `domains` may know.
    public func windowReport(
        _ window: QueryTimeWindow,
        domains: Set<Domain>,
        calendar: Calendar
    ) async throws -> WindowReport {
        WindowReport(
            window: window,
            freshness: try await freshness(domains: domains, notAfter: window.end),
            calendar: calendar
        )
    }
}
