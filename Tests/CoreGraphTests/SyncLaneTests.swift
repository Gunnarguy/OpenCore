import Foundation
import Testing

@testable import CoreIngest

// The bug: a scheduled pass asked `guard !isRunning` once, at its start, and nothing else asked at
// all. A click during a pass ran on top of it, Sync All pressed twice ran twice, and whichever sync
// finished first set the shared status to idle while the other was still working.

// MARK: - The lane

@Test("a second pass is refused and told who holds the lane")
func secondPassIsRefused() {
    var lane = SyncLane()
    let first = SyncLane.Pass(label: "Scheduled sync", unattended: true)

    #expect(lane.enter(first) == .entered)
    #expect(lane.enter(SyncLane.Pass(label: "Calendar")) == .busy("Scheduled sync"))
    #expect(lane.holder == first)
}

@Test("a sync already inside the pass joins it")
func insideThePassJoins() {
    var lane = SyncLane()
    let pass = SyncLane.Pass(label: "Sync All")
    _ = lane.enter(pass)

    #expect(lane.enter(SyncLane.Pass(label: "Calendar"), inherited: pass) == .joined)
    #expect(lane.holder == pass, "joining must not change who holds it")
}

// A task can outlive the pass it started in and still carry that pass's task local. Holding that
// must not let it walk into whoever holds the lane now.
@Test("a pass that has ended lets nobody in on its name")
func staleInheritanceDoesNotJoin() {
    var lane = SyncLane()
    let ended = SyncLane.Pass(label: "Sync All")
    _ = lane.enter(ended)
    lane.leave(ended)
    _ = lane.enter(SyncLane.Pass(label: "Notes"))

    #expect(lane.enter(SyncLane.Pass(label: "Calendar"), inherited: ended) == .busy("Notes"))
}

@Test("only the holder can free the lane")
func onlyTheHolderLeaves() {
    var lane = SyncLane()
    let holder = SyncLane.Pass(label: "Notes")
    _ = lane.enter(holder)

    lane.leave(SyncLane.Pass(label: "Calendar"))
    #expect(lane.holder == holder)

    lane.leave(holder)
    #expect(lane.holder == nil)
}

// MARK: - Real overlapping tasks

/// Holds a pass open until the test lets it finish, so overlap is arranged rather than hoped for.
@MainActor
private final class Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private func yieldUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        await Task.yield()
    }
}

@MainActor
@Test("a click during a scheduled pass does not run on top of it")
func clickDuringPassIsRefused() async {
    let coordinator = SyncCoordinator()
    let latch = Latch()
    var ran: [String] = []

    let pass = Task { @MainActor in
        await coordinator.exclusively("Scheduled sync", unattended: true, refused: { _ in }) {
            ran.append("scheduled")
            await latch.wait()
        }
    }
    await yieldUntil { !ran.isEmpty }

    var refusedBy: String?
    await coordinator.exclusively("Calendar", refused: { refusedBy = $0 }) { ran.append("click") }

    #expect(refusedBy == "Scheduled sync")
    #expect(ran == ["scheduled"])

    latch.open()
    await pass.value
}

@MainActor
@Test("however many syncs start at once, only one runs")
func manyStartsRunOne() async {
    let coordinator = SyncCoordinator()
    let latch = Latch()
    var running = 0
    var mostAtOnce = 0
    var started = 0
    var refused = 0

    let tasks = (0..<8).map { index in
        Task { @MainActor in
            await coordinator.exclusively("sync \(index)", refused: { _ in refused += 1 }) {
                started += 1
                running += 1
                mostAtOnce = max(mostAtOnce, running)
                await latch.wait()
                running -= 1
            }
        }
    }
    await yieldUntil { started + refused == 8 }
    latch.open()
    for task in tasks { await task.value }

    #expect(mostAtOnce == 1)
    #expect(started == 1)
    #expect(refused == 7)
}

@MainActor
@Test("the syncs inside a pass run, in order, without giving up the lane")
func nestedSyncsJoinThePass() async {
    let coordinator = SyncCoordinator()
    var ran: [String] = []

    await coordinator.exclusively("Sync All", refused: { _ in ran.append("refused") }) {
        for name in ["repositories", "calendar", "notes"] {
            await coordinator.exclusively(name, refused: { _ in ran.append("refused") }) { ran.append(name) }
            #expect(coordinator.lane.holder?.label == "Sync All", "a joined sync must not release the pass")
        }
    }

    #expect(ran == ["repositories", "calendar", "notes"])
    #expect(coordinator.lane.holder == nil)
}

// The reason this is a task local and not a flag: a flag saying "a pass is running" lets a click
// in as if it belonged to that pass.
@MainActor
@Test("a click during a pass is not mistaken for part of it")
func outsiderDoesNotJoin() async {
    let coordinator = SyncCoordinator()
    let latch = Latch()
    var inside = false
    var joined = false

    let pass = Task { @MainActor in
        await coordinator.exclusively("Sync All", refused: { _ in }) {
            inside = true
            await latch.wait()
        }
    }
    await yieldUntil { inside }

    // Started from the test's task, not from inside the pass.
    await coordinator.exclusively("Calendar", refused: { _ in }) { joined = true }
    #expect(!joined)

    latch.open()
    await pass.value
}

@MainActor
@Test("the lane frees when the work finishes, so the next sync can run")
func laneFreesAfterwards() async {
    let coordinator = SyncCoordinator()
    var count = 0

    await coordinator.exclusively("first", refused: { _ in }) { count += 1 }
    await coordinator.exclusively("second", refused: { _ in }) { count += 1 }

    #expect(count == 2)
    #expect(coordinator.lane.holder == nil)
}

// MARK: - What a sync leaves on record

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test("a success clears the old error and says what it found")
func successClearsTheError() {
    var record = SyncSchedule.Record(lastAttempt: now.addingTimeInterval(-60), lastError: "denied")

    record.record(.finished(read: 40, changed: 3), at: now)

    #expect(record.lastError == nil)
    #expect(record.lastSuccess == now)
    #expect(record.lastResult == "3 changed of 40 read")
}

@Test("a sync that found nothing reads as that, not as a count of nothing")
func nothingNewReadsPlainly() {
    var record = SyncSchedule.Record()
    record.record(.finished(read: 0, changed: 0), at: now)
    #expect(record.lastResult == "nothing new")
}

@Test("a failure keeps the last good result and date, so staleness stays visible")
func failureKeepsTheLastGoodResult() {
    let worked = now.addingTimeInterval(-86_400)
    var record = SyncSchedule.Record(lastAttempt: worked, lastSuccess: worked, lastResult: "1 changed of 1 read")

    record.record(.failed("Notes did not respond"), at: now)

    #expect(record.lastError == "Notes did not respond")
    #expect(record.lastAttempt == now)
    #expect(record.lastSuccess == worked)
    #expect(record.lastResult == "1 changed of 1 read")
}

// The bug this prevents: the attempt was stamped before the sync ran, so a tick that never got to
// read anything would have pushed the source back a whole interval.
@Test("a refused sync records nothing, so its source stays due")
func refusedChangesNothing() {
    var record = SyncSchedule.Record(lastError: "denied")
    let before = record

    record.record(.refused("Sync All"), at: now)

    #expect(record == before)
    #expect(SyncSchedule.due([.calendar], records: [.calendar: record], now: now) == [.calendar])
}

// The bug: only the scheduled path wrote records, so a source synced by hand a minute ago was read
// again on the next tick, and an error it had just recovered from stayed on screen.
@Test("a sync by hand counts: the source is no longer due and its error is gone")
func handSyncCounts() {
    var record = SyncSchedule.Record(lastAttempt: now.addingTimeInterval(-86_400), lastError: "denied")
    #expect(SyncSchedule.due([.calendar], records: [.calendar: record], now: now) == [.calendar])

    record.record(.finished(read: 2, changed: 2), at: now)

    #expect(SyncSchedule.due([.calendar], records: [.calendar: record], now: now.addingTimeInterval(60)).isEmpty)
    #expect(record.lastError == nil)
}

@Test("the same failure repeats quietly and a new one does not")
func repeatedFailureIsRecognised() {
    let record = SyncSchedule.Record(lastError: "denied")
    #expect(record.repeats(.failed("denied")))
    #expect(!record.repeats(.failed("timed out")))
    #expect(!record.repeats(.finished(read: 1, changed: 1)))
    #expect(!SyncSchedule.Record().repeats(.failed("denied")))
}

// `lastResult` is newer than the records already saved in UserDefaults. A strict decode would drop
// every source's history on the first launch after this shipped.
@Test("a record saved before the result field existed still loads")
func olderRecordDecodes() throws {
    let saved = Data(#"{"lastAttempt":700000000,"lastSuccess":700000000}"#.utf8)
    let record = try JSONDecoder().decode(SyncSchedule.Record.self, from: saved)
    #expect(record.lastSuccess != nil)
    #expect(record.lastResult == nil)
}

@Test("a record survives being saved and loaded")
func recordRoundTrips() throws {
    var record = SyncSchedule.Record()
    record.record(.finished(read: 4, changed: 1), at: now)
    record.record(.failed("denied"), at: now.addingTimeInterval(60))

    let loaded = try JSONDecoder().decode(SyncSchedule.Record.self, from: JSONEncoder().encode(record))

    #expect(loaded == record)
}

// The bug: `overdue` is negative for a date in the future, so a Mac whose clock had been wrong kept
// a source from running until real time caught up with it.
@Test("a last-run date in the future reads as never run")
func futureDateIsDue() {
    let record = SyncSchedule.Record(lastAttempt: now.addingTimeInterval(86_400))
    #expect(SyncSchedule.due([.notes], records: [.notes: record], now: now) == [.notes])
}

// The bug: a first read or a full re-read that returned nothing came back as `.finished(0, 0)`, so
// the source's record stored a success and "nothing new" although `last_synced` had not moved.
@Test("a read that held the date is not a success, and keeps the last real one")
func heldReadIsNoSuccess() {
    let worked = now.addingTimeInterval(-86_400)
    var record = SyncSchedule.Record(lastAttempt: worked, lastSuccess: worked, lastResult: "1 changed of 1 read")

    record.record(.held(read: 0, changed: 0, reason: "It returned nothing."), at: now)

    #expect(record.lastSuccess == worked)
    #expect(record.lastAttempt == now)
    #expect(record.lastError == "It returned nothing.")
    #expect(record.lastResult == "1 changed of 1 read", "nothing was read, so the last result stands")
    #expect(SyncSchedule.due([.calendar], records: [.calendar: record], now: now.addingTimeInterval(60)).isEmpty, "it waits its interval like a failure")
}

@Test("a read that held the date still says what it read, and a clean read clears it")
func heldReadKeepsWhatItRead() {
    var record = SyncSchedule.Record()
    record.record(.held(read: 3, changed: 3, reason: "1 of 4 notes could not be read."), at: now)
    #expect(record.lastResult == "3 changed of 3 read")
    #expect(record.lastSuccess == nil)

    record.record(.finished(read: 4, changed: 1), at: now.addingTimeInterval(60))
    #expect(record.lastError == nil)
    #expect(record.lastSuccess != nil)
}

@Test("the same shortfall repeats quietly and a new one does not")
func heldReadRepeats() {
    let record = SyncSchedule.Record(lastError: "1 of 4 notes could not be read.")
    #expect(record.repeats(.held(read: 3, changed: 0, reason: "1 of 4 notes could not be read.")))
    #expect(!record.repeats(.held(read: 3, changed: 0, reason: "2 of 4 notes could not be read.")))
}

@Test("only a sync that changed something counts as having changed anything")
func changedAnythingMeansChanged() {
    #expect(SyncSchedule.Outcome.finished(read: 5, changed: 1).changedAnything)
    #expect(!SyncSchedule.Outcome.finished(read: 5, changed: 0).changedAnything)
    #expect(SyncSchedule.Outcome.held(read: 5, changed: 1, reason: "short").changedAnything, "what a partial read brought still needs embedding")
    #expect(!SyncSchedule.Outcome.failed("denied").changedAnything)
    #expect(!SyncSchedule.Outcome.refused("Sync All").changedAnything)
}
