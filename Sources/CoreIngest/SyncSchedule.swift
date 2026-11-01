import Foundation

/// Which sources are due, decided in one pure place so it can be tested.
///
/// **Why this is in the app and not a daemon.** The store went stale because nothing ran. The
/// `opencore` CLI cannot read calendars or reminders at all: EventKit reads usage strings from the
/// calling binary's Info.plist and a SwiftPM executable has none, so a launchd job could never
/// keep them fresh. Only the app bundle can, which means only while the app is running.
public enum SyncSchedule {
    public enum Job: String, Sendable, CaseIterable, Codable {
        case calendar, reminders, notes, repositories, memories, github

        /// How stale a source may get.
        ///
        /// **Chosen, not measured.** An hour for sources that change through a day and are cheap
        /// to read locally. Six hours for the rest: Notes starts Notes and walks every note by
        /// AppleScript, GitHub spends API quota, and repository documents rarely change hourly.
        public var interval: TimeInterval {
            switch self {
            case .calendar, .reminders: 3_600
            case .notes, .repositories, .memories, .github: 6 * 3_600
            }
        }

        /// The label the app shows.
        public var label: String {
            switch self {
            case .calendar: "Calendar"
            case .reminders: "Reminders"
            case .notes: "Notes"
            case .repositories: "Repository documents"
            case .memories: "Agent memories"
            case .github: "GitHub"
            }
        }
    }

    /// What one sync of one source came to.
    public enum Outcome: Sendable, Equatable {
        case finished(read: Int, changed: Int)
        /// It ran and the source's sync date stayed, so the next pass covers the same span. What
        /// it read is kept, but this is not a success: the record used to say "nothing new" about
        /// a read that returned nothing and moved nothing.
        case held(read: Int, changed: Int, reason: String)
        case failed(String)
        /// It never ran, because another sync held the lane. This says nothing about the source.
        case refused(String)

        /// What a read that finished came to.
        /// - Parameter reason: `SourceSync.Report.heldBecause`. `CoreIngest` can't see that type.
        public init(read: Int, changed: Int, heldBecause reason: String?) {
            if let reason {
                self = .held(read: read, changed: changed, reason: reason)
            } else {
                self = .finished(read: read, changed: changed)
            }
        }

        public var changedAnything: Bool {
            switch self {
            case .finished(_, let changed), .held(_, let changed, _): changed > 0
            case .failed, .refused: false
            }
        }
    }

    /// One job's history. `lastAttempt` counts failures too, so a source that fails is retried
    /// on its own interval rather than on every tick, while `lastSuccess` keeps showing how
    /// stale it really is.
    ///
    /// Every sync writes here, by hand or on schedule. Only the schedule did, so clicking a
    /// source that had failed left the old error on screen after it worked, and a source just
    /// synced by hand was read again on the next tick.
    public struct Record: Sendable, Hashable, Codable {
        public var lastAttempt: Date?
        public var lastSuccess: Date?
        public var lastError: String?
        /// What the last read found, in words, including one that held the date. Optional so a
        /// record saved before this field existed still decodes.
        public var lastResult: String?

        public init(lastAttempt: Date? = nil, lastSuccess: Date? = nil, lastError: String? = nil, lastResult: String? = nil) {
            self.lastAttempt = lastAttempt
            self.lastSuccess = lastSuccess
            self.lastError = lastError
            self.lastResult = lastResult
        }

        /// Whether any read has brought something back, which is what `SyncSchedule.runnable` asks
        /// of Notes.
        public var hasRead: Bool { lastSuccess != nil || lastResult != nil }

        /// Fold one outcome in. `refused` changes nothing: nothing was tried, so the job stays
        /// due and the last real result stays on screen.
        public mutating func record(_ outcome: Outcome, at date: Date) {
            switch outcome {
            case .finished(let read, let changed):
                lastAttempt = date
                lastSuccess = date
                lastError = nil
                lastResult = Self.describe(read: read, changed: changed)
            case .held(let read, let changed, let reason):
                lastAttempt = date
                lastError = reason
                if read > 0 { lastResult = Self.describe(read: read, changed: changed) }
            case .failed(let message):
                lastAttempt = date
                lastError = message
            case .refused:
                break
            }
        }

        /// Whether this is the failure already on record, so a background retry can stay quiet
        /// about something a person has seen and dismissed.
        public func repeats(_ outcome: Outcome) -> Bool {
            switch outcome {
            case .failed(let message), .held(_, _, let message): message == lastError
            case .finished, .refused: false
            }
        }

        static func describe(read: Int, changed: Int) -> String {
            guard read > 0 else { return "nothing new" }
            return "\(changed) changed of \(read) read"
        }
    }

    /// The jobs a pass may start with nobody there.
    ///
    /// **Notes waits for a person.** Calendar and Reminders can check their permission first and
    /// refuse quietly. Notes can't: its first read raises an Automation prompt that holds the lane
    /// for up to five minutes, and it takes a whole personal library through a folder-name guess.
    /// A never-run job is the most overdue of all, so the first of those used to start 20 s after
    /// launch with no click. It joins the schedule once a read someone started has brought
    /// something back, and only a person can start that read, so a failed one keeps it out.
    public static func runnable(_ jobs: [Job], records: [Job: Record], includeNotes: Bool) -> [Job] {
        jobs.filter { $0 != .notes || (includeNotes && records[.notes]?.hasRead == true) }
    }

    /// The jobs due at `now`, most overdue first, in a stable order. A job that has never run
    /// is the most overdue of all.
    public static func due(
        _ jobs: [Job],
        records: [Job: Record],
        now: Date = Date()
    ) -> [Job] {
        func reference(_ job: Job) -> Date? {
            let record = records[job]
            return [record?.lastAttempt, record?.lastSuccess].compactMap { $0 }.max()
        }
        func overdue(_ job: Job) -> TimeInterval {
            // A date in the future means the clock moved. Waiting for it to arrive could stop a
            // source for as long as the clock was wrong, so it reads as never run.
            guard let last = reference(job), last <= now else { return .infinity }
            return now.timeIntervalSince(last) - job.interval
        }
        return jobs
            .filter { overdue($0) >= 0 }
            .sorted { (overdue($0), $1.rawValue) > (overdue($1), $0.rawValue) }
    }
}
