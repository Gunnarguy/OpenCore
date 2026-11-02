import CoreTelemetry
import Foundation
import Testing

private let snapshotTime = Date(timeIntervalSince1970: 1_800_000_000)

// Fleet []/failure used to leave old cards in place while JARVIS assigned a new "live" timestamp.
@Test("a failed operator collection preserves the old capture and reports the new failure")
func failedOperatorReadDoesNotCertifyCachedValues() {
    var cache = OperatorSnapshotCache<[String]>()
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime.addingTimeInterval(2), outcome: .complete(["fixture"])))
    let failed = OperatorSnapshotRead<[String]>(attemptedAt: snapshotTime.addingTimeInterval(10), finishedAt: snapshotTime.addingTimeInterval(12), outcome: .failed("Reader failed; no usable cards."))
    cache.record(failed)
    #expect(cache.value == ["fixture"])
    #expect(cache.lastCapture?.capturedAt == snapshotTime.addingTimeInterval(2))
    #expect(cache.lastAttempt?.capturedAt == nil)
    #expect(cache.lastAttempt?.issues == ["Reader failed; no usable cards."])
    #expect(cache.lastAttempt?.isComplete == false)
}

// Valid extras surviving a failed primary inventory must not become an all-complete fleet.
@Test("partial operator captures retain warnings and cannot certify complete coverage")
func partialOperatorReadKeepsItsIssues() {
    var cache = OperatorSnapshotCache<[String]>()
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime.addingTimeInterval(1), outcome: .partial(["extra fixture"], issues: ["Primary inventory failed."])))
    #expect(cache.value == ["extra fixture"])
    #expect(cache.lastCapture?.isComplete == false)
    #expect(cache.lastCapture?.issues == ["Primary inventory failed."])
    #expect(cache.lastCapture?.capturedAt == snapshotTime.addingTimeInterval(1))
}

// A slow older request could overwrite a newer completed reading in shared snapshot consumers.
@Test("late older operator results cannot replace a newer reading")
func oldOperatorResultCannotReplaceNewerCapture() {
    var cache = OperatorSnapshotCache<String>()
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime.addingTimeInterval(10), finishedAt: snapshotTime.addingTimeInterval(12), order: 2, outcome: .complete("new")))
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime.addingTimeInterval(20), order: 1, outcome: .complete("old")))
    #expect(cache.value == "new")
    #expect(cache.lastAttempt?.attemptedAt == snapshotTime.addingTimeInterval(10))
    // A wall-clock correction must not block a genuinely later request.
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime.addingTimeInterval(-100), finishedAt: snapshotTime, order: 3, outcome: .complete("after clock correction")))
    #expect(cache.value == "after clock correction")
}

// Refreshing one repository must not make every other card look newly collected.
@Test("a single-row amendment retains the fleet collection's capture time")
func operatorAmendmentDoesNotRedateWholeFleet() {
    var cache = OperatorSnapshotCache<[String]>()
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, order: 1, outcome: .partial(["old"], issues: ["Partial inventory."])))
    cache.amendCapturedValue(["updated row"], rowKey: "fixture", order: 2)
    #expect(cache.value == ["updated row"])
    #expect(cache.lastCapture?.capturedAt == snapshotTime)
    #expect(cache.lastCapture?.issues == ["Partial inventory."])
    #expect(cache.lastAttempt?.value == ["old"])
}

// A single-repository failure was silently discarded, leaving a complete/clean fleet label.
@Test("row refresh failures remain attached to a retained partial capture")
func rowFailureDoesNotCertifyACompleteFleet() {
    var cache = OperatorSnapshotCache<[String]>()
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, order: 1, outcome: .complete(["old row"])))
    cache.amendCapturedValue(["old row"], rowKey: "fixture", order: 2, issues: ["Row refresh failed."])
    #expect(cache.lastCapture?.isComplete == false)
    #expect(cache.lastCapture?.issues == ["Row refresh failed."])
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime.addingTimeInterval(5), finishedAt: snapshotTime.addingTimeInterval(6), order: 3, outcome: .failed("Whole refresh failed.")))
    #expect(cache.lastCapture?.issues == ["Row refresh failed."])
    #expect(cache.lastAttempt?.issues == ["Whole refresh failed."])
    #expect(cache.lastCapture?.capturedAt == snapshotTime)
}

// Slow row reads could replace newer row/full captures or attach stale failure warnings.
@Test("overlapping row and whole-inventory results cannot overwrite newer observations")
func staleRowReadsCannotReplaceNewerFleetData() {
    var cache = OperatorSnapshotCache<[String]>()
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, order: 1, outcome: .complete(["initial"])))
    let newRowAccepted = cache.amendCapturedValue(["new row"], rowKey: "fixture", order: 3)
    #expect(newRowAccepted)
    let oldRowAccepted = cache.amendCapturedValue(["old row"], rowKey: "fixture", order: 2, issues: ["Old failure."])
    #expect(!oldRowAccepted)
    #expect(cache.value == ["new row"])
    #expect(cache.lastCapture?.isComplete == true)
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, order: 2, outcome: .complete(["old whole inventory"])))
    #expect(cache.value == ["new row"])
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, order: 2, outcome: .failed("Full reader failed.")))
    #expect(cache.value == ["new row"])
    #expect(cache.lastAttempt?.issues == ["Full reader failed."])
    cache.record(OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, order: 4, outcome: .complete(["new whole inventory"])))
    let staleRowAccepted = cache.amendCapturedValue(["stale row"], rowKey: "fixture", order: 3, issues: ["Stale failure."])
    #expect(!staleRowAccepted)
    #expect(cache.value == ["new whole inventory"])
    #expect(cache.lastCapture?.issues.isEmpty == true)
}

// Missing JSON fields defaulted dirty=0, so a failed or unmeasured repository became "clean".
@Test("only an actual nonnegative Git status measurement can establish a clean tree")
func unmeasuredRepositoryStatusIsNotClean() {
    #expect(RepositoryStatusObservation(isGit: true, dirtyCount: 0, hasError: false, isMissing: false).dirtyCount == 0)
    for value in [RepositoryStatusObservation(isGit: true, dirtyCount: nil, hasError: false, isMissing: false),
                  RepositoryStatusObservation(isGit: true, dirtyCount: 0, hasError: true, isMissing: false),
                  RepositoryStatusObservation(isGit: true, dirtyCount: 0, hasError: false, isMissing: true),
                  RepositoryStatusObservation(isGit: false, dirtyCount: 0, hasError: false, isMissing: false),
                  RepositoryStatusObservation(isGit: true, dirtyCount: -1, hasError: false, isMissing: false)] {
        #expect(!value.isMeasured)
        #expect(value.dirtyCount == nil)
    }
}

// Foundation numeric bridging can turn JSON false into integer zero; absence also defaulted to 0.
@Test("repository Git status parsing rejects missing boolean and malformed counts")
func malformedGitCountsCannotBecomeCleanTrees() throws {
    let valid = try RepositoryStatusObservation(json: Data(#"{"git":true,"dirty":0}"#.utf8))
    #expect(valid.isClean)
    #expect(valid.summary == "clean")
    for payload in [#"{"git":true}"#, #"{"git":true,"dirty":false}"#, #"{"git":true,"dirty":-1}"#,
                    #"{"git":true,"dirty":0,"error":"read failed"}"#, #"{"git":false,"dirty":0}"#] {
        let status = try? RepositoryStatusObservation(json: Data(payload.utf8))
        #expect(status?.isClean != true)
        #expect(status?.isMeasured != true)
        if let status { #expect(status.summary == "not measured") }
    }
}

// Reading a stored ecosystem snapshot performed new filesystem IO under the old timestamp.
@Test("shared skill links are resolved during capture and stay fixed in the saved observation")
func skillInventoryDoesNotChangeDuringRendering() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-skill-fixture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first.appendingPathComponent("sample"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let link = second.appendingPathComponent("sample")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first.appendingPathComponent("sample"))
    let count = SharedSkillInventory.sameSourceCount(firstNames: ["sample"], secondNames: ["sample"], firstRoot: first, secondRoot: second)
    let snapshot = OperatorSnapshotRead(attemptedAt: snapshotTime, finishedAt: snapshotTime, outcome: .complete(count))
    #expect(snapshot.value == 1)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
    #expect(SharedSkillInventory.sameSourceCount(firstNames: ["sample"], secondNames: ["sample"], firstRoot: first, secondRoot: second) == 0)
    #expect(snapshot.value == 1)
}

// A skipped probe or bounded/failed filename scan was presented as a successful complete check.
@Test("operator component labels distinguish skipped failed and bounded checks")
func operatorComponentLabelsKeepTheirLimits() {
    #expect(OperatorSnapshotFormatting.peers(requested: false, reachable: []) == "Tailnet not checked")
    #expect(OperatorSnapshotFormatting.peers(requested: true, reachable: []) == "No reachable remote peer recorded")
    #expect(OperatorSnapshotFormatting.numberedFiles(count: 20, reachedLimit: true, error: nil).hasPrefix("At least 20"))
    #expect(OperatorSnapshotFormatting.numberedFiles(count: 0, reachedLimit: false, error: "Scan unavailable.") == "Scan unavailable.")
    #expect(OperatorSnapshotFormatting.numberedFiles(count: -1, reachedLimit: false, error: nil) == "Numbered-file count not measured.")
}

// A scan with no matching filenames had no traversal limit and could keep the briefing busy.
@Test("filesystem scan work stops at entry time and cancellation limits without matching files")
func filenameTraversalDoesNotDependOnFindingMatches() {
    var entries = CooperativeScanBudget(startedAt: 10, maximumNanoseconds: 100, maximumEntries: 2)
    let first = entries.admit(now: 11, cancelled: false)
    let second = entries.admit(now: 12, cancelled: false)
    let third = entries.admit(now: 13, cancelled: false)
    #expect(first)
    #expect(second)
    #expect(!third)
    var time = CooperativeScanBudget(startedAt: 10, maximumNanoseconds: 2, maximumEntries: 100)
    let expired = time.admit(now: 12, cancelled: false)
    #expect(!expired)
    var cancelled = CooperativeScanBudget(startedAt: 10, maximumNanoseconds: 100, maximumEntries: 100)
    let afterCancellation = cancelled.admit(now: 11, cancelled: true)
    #expect(!afterCancellation)
}
