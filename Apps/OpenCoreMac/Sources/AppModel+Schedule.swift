import CoreIngest
import Foundation

/// Keeps the store fresh while the app runs.
///
/// Uses `NSBackgroundActivityScheduler` rather than a timer, per Apple's documentation (Foundation,
/// read 2026-10-31): it lets the system pick an efficient moment by energy, thermal state and CPU,
/// and it is the class Apple names for work every 10 minutes or more. The scheduler ticks every 30
/// minutes and `SyncSchedule` decides what is actually due, so a tick with nothing due costs
/// nothing. Both the block and its completion handler are `NS_SWIFT_SENDABLE` in the macOS 27 SDK
/// header, so hopping to the main actor below is correct and the closure inherits no isolation.
extension AppModel {
    /// How often the scheduler wakes to ask what is due. **Chosen, not measured:** half the
    /// shortest job interval. Apple's guidance is that this class suits work every 10 minutes
    /// or more.
    private static let scheduleTick: TimeInterval = 30 * 60

    private static let recordsKey = "sync.schedule.records"

    /// Reverse DNS, and constant across launches: the system uses it to learn how this activity
    /// behaves.
    private static let activityIdentifier = "com.gunndamental.OpenCore.scheduledSync"

    /// What a scheduled pass may run.
    var scheduledJobs: [SyncSchedule.Job] {
        SyncSchedule.runnable(reportedJobs, records: scheduleRecords, includeNotes: settings.scheduledSyncIncludesNotes)
    }

    /// What the Sources screen reports on. Notes stays here with the schedule leaving it out,
    /// because it can still be synced by hand and that result belongs somewhere.
    var reportedJobs: [SyncSchedule.Job] {
        SyncSchedule.Job.allCases.filter { $0 != .github || githubTokenAvailable }
    }

    func loadScheduleRecords() -> [SyncSchedule.Job: SyncSchedule.Record] {
        guard let data = UserDefaults.standard.data(forKey: Self.recordsKey),
              let decoded = try? JSONDecoder().decode([String: SyncSchedule.Record].self, from: data)
        else { return [:] }
        var records: [SyncSchedule.Job: SyncSchedule.Record] = [:]
        for (key, value) in decoded {
            if let job = SyncSchedule.Job(rawValue: key) { records[job] = value }
        }
        return records
    }

    private func saveScheduleRecords() {
        let keyed = Dictionary(uniqueKeysWithValues: scheduleRecords.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(keyed) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }

    /// Keep a sync's result, whoever started it. Returns the outcome so a call can stay one line.
    func noting(_ outcome: SyncSchedule.Outcome, for job: SyncSchedule.Job) -> SyncSchedule.Outcome {
        var record = scheduleRecords[job] ?? SyncSchedule.Record()
        record.record(outcome, at: Date())
        scheduleRecords[job] = record
        saveScheduleRecords()
        return outcome
    }

    /// Off the main thread, because a first answer can mean starting `gh`.
    @discardableResult
    func checkGitHubToken() async -> Bool {
        let available = await Task.detached { GitHubConnector.resolveToken() != nil }.value
        githubTokenAvailable = available
        return available
    }

    /// Run `work` if nothing else is syncing. A refusal someone caused gets said out loud; a
    /// refused background tick just waits for the next one.
    func exclusively<Value>(
        _ label: String,
        unattended: Bool = false,
        refused: (_ holder: String) -> Value,
        _ work: @MainActor () async -> Value
    ) async -> Value {
        await syncCoordinator.exclusively(label, unattended: unattended, refused: { holder in
            if !unattended {
                let message = "\(label) did not start, because \(holder) is still running. Try again when it finishes."
                failure = AppFailure(message: message, at: Date())
                ActionFeedbackCenter.shared.record(button: label, command: "SyncCoordinator.exclusively", outcome: message, status: .noOpExplained)
            }
            return refused(holder)
        }, work)
    }

    func startScheduledSync() {
        scheduleRecords = loadScheduleRecords()
        scheduledSyncSettingChanged()
        // Catch up on launch. The system decides when a repeating activity first fires, and a
        // store that went stale while the app was closed should not wait for that.
        Task { [weak self] in
            await self?.checkGitHubToken()
            try? await Task.sleep(for: .seconds(20))
            await self?.runDueSyncs()
        }
    }

    func scheduledSyncSettingChanged() {
        syncActivity?.invalidate()
        syncActivity = nil
        guard settings.scheduledSyncEnabled else { return }

        let activity = NSBackgroundActivityScheduler(identifier: Self.activityIdentifier)
        activity.repeats = true
        activity.interval = Self.scheduleTick
        // Apple's docs recommend the default `.background` for most activities and say anything
        // above it is scheduled more aggressively. **Chosen, not measured:** an hourly source
        // should not slip behind its own interval, and this is still low-priority work whose
        // moment the system picks.
        activity.qualityOfService = .utility
        activity.schedule { completion in
            Task { @MainActor in
                let deferred = await AppModel.shared.runDueSyncs(mayDefer: true)
                completion(deferred ? .deferred : .finished)
            }
        }
        syncActivity = activity
    }

    /// Run whatever is due, one source at a time. Returns true when the pass should come back
    /// later: the system asked it to defer, or something else was running.
    @discardableResult
    func runDueSyncs(mayDefer: Bool = false) async -> Bool {
        guard settings.scheduledSyncEnabled, store != nil else { return false }
        await checkGitHubToken()

        // The scheduler's own activity covers the block, and this block returns at once. This
        // one covers the pass, and the launch catch-up that no scheduler started. `.background`
        // does not hold the Mac awake (NSActivityBackground in the macOS 27 SDK header).
        let activity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Scheduled OpenCore sync")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        return await exclusively("Scheduled sync", unattended: true, refused: { _ in true }) {
            var changedAnything = false
            var comeBack = false
            for job in SyncSchedule.due(scheduledJobs, records: scheduleRecords) {
                guard settings.scheduledSyncEnabled else { break }
                if mayDefer, syncActivity?.shouldDefer == true { comeBack = true; break }
                // Vector builds are not in the lane. Stop rather than run underneath one.
                if case .working = state { comeBack = true; break }

                let failureBefore = failure
                let previous = scheduleRecords[job]
                let outcome = await run(job)
                changedAnything = changedAnything || outcome.changedAnything
                // A background failure should not re-raise the banner every six hours once
                // someone has dismissed it. The record keeps it, and Sources shows it.
                if failureBefore == nil, previous?.repeats(outcome) == true {
                    failure = nil
                    state = .idle
                }
            }
            // Only when a sync brought something: a build still loads the embedding model and
            // takes over the status line, which is no way to report that nothing happened.
            if changedAnything { await buildEmbeddings() }
            return comeBack
        }
    }

    private func run(_ job: SyncSchedule.Job) async -> SyncSchedule.Outcome {
        switch job {
        case .calendar: await syncCalendar(unattended: true)
        case .reminders: await syncReminders(unattended: true)
        case .notes: await syncNotes()
        case .repositories: await syncLocalGitHubWorkspace()
        case .memories: await syncCrossAgentMemories()
        case .github: await syncGitHub()
        }
    }
}
