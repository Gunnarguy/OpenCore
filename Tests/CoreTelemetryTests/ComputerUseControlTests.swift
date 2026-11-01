import Testing
@testable import CoreTelemetry

@Suite("Computer Use Studio decisions")
struct ComputerUseControlTests {
    private func decide(_ action: String, mode: ComputerExecutionMode = .live, x: Double = 10, y: Double = 10,
                        permitted: Bool = true, running: String? = nil) -> ComputerStepDecision {
        ComputerStepPolicy.decide(action: action, x: x, y: y, screenWidth: 100, screenHeight: 100,
                                  mode: mode, inputPermitted: permitted, runningTitle: running)
    }

    // Regression: Click Now called executeClick whatever step.action said, so a planned move or
    // double click reached the Mac as a single click.
    @Test("live step performs its own action") func liveStepPerformsItsOwnAction() {
        #expect(decide("click") == .perform(.click, title: "Click Now"))
        #expect(decide("double_click") == .perform(.doubleClick, title: "Double-Click Now"))
        #expect(decide("move") == .perform(.move, title: "Move Cursor Now"))
    }

    @Test("a step that cannot be sent is disabled with areason and never becomes aclick") func aStepThatCannotBeSentIsDisabledWithAReasonAndNeverBecomesAClick() {
        for action in ["type", "scroll", "right_click", "drag", ""] {
            let decision = decide(action)
            #expect(!decision.isEnabled, "\(action)")
            #expect(decision.reason?.isEmpty == false, "\(action)")
            if case .perform = decision { Issue.record("\(action) would send input") }
        }
    }

    @Test("dry run never performs") func dryRunNeverPerforms() {
        for action in ["click", "double_click", "move", "right_click"] {
            #expect(decide(action, mode: .dryRun) == .preview(title: "Test Reticle"))
        }
        #expect(!decide("type", mode: .dryRun).isEnabled)
    }

    @Test("live needs permission areal point and nothing else running") func liveNeedsPermissionARealPointAndNothingElseRunning() {
        #expect(!decide("click", permitted: false).isEnabled)
        #expect(decide("click", permitted: false).reason?.contains("Accessibility") == true)
        #expect(!decide("click", running: "Scoped task").isEnabled)
        for (x, y) in [(-1.0, 5.0), (5.0, 100.0), (100.0, 5.0), (Double.nan, 5.0), (5.0, Double.infinity)] {
            #expect(!decide("click", x: x, y: y).isEnabled)
            #expect(!decide("click", mode: .dryRun, x: x, y: y).isEnabled)
        }
    }

    // Regression: the manager always started from `true`, so the saved default was read by nothing.
    @Test("launch follows the saved default") func launchFollowsTheSavedDefault() {
        #expect(ComputerLiveArming.launch(defaultDryRun: true, liveDefaultConfirmed: false).mode == .dryRun)
        #expect(ComputerLiveArming.launch(defaultDryRun: true, liveDefaultConfirmed: true).mode == .dryRun)
        let live = ComputerLiveArming.launch(defaultDryRun: false, liveDefaultConfirmed: true)
        #expect(live.mode == .live)
        #expect(live.notice == nil)
    }

    @Test("a stored live default nobody confirmed starts dry and says so") func aStoredLiveDefaultNobodyConfirmedStartsDryAndSaysSo() {
        let launch = ComputerLiveArming.launch(defaultDryRun: false, liveDefaultConfirmed: false)
        #expect(launch.mode == .dryRun)
        #expect(launch.notice?.isEmpty == false)
    }

    // Regression: turning the switch off armed live control at once.
    @Test("arming asks and disarming does not") func armingAsksAndDisarmingDoesNot() {
        guard case .askFirst = ComputerLiveArming.request(.live, from: .dryRun, runningTitle: nil) else {
            Issue.record("arming must ask"); return
        }
        #expect(ComputerLiveArming.request(.dryRun, from: .live, runningTitle: nil) == .returnToDryRun)
        #expect(ComputerLiveArming.request(.dryRun, from: .live, runningTitle: "Scoped task") == .returnToDryRun)
        #expect(ComputerLiveArming.request(.dryRun, from: .dryRun, runningTitle: nil) == .nothingToDo)
        guard case .refuse = ComputerLiveArming.request(.live, from: .dryRun, runningTitle: "Replay preview") else {
            Issue.record("arming mid-run must be refused"); return
        }
    }

    private func started(_ ledger: inout ComputerRunLedger, _ kind: ComputerRunKind) throws -> ComputerRunToken {
        guard case .started(let token) = ledger.begin(kind) else { throw Refused() }
        return token
    }
    private struct Refused: Error {}

    @Test("one run at atime and afinished run frees the slot") func oneRunAtATimeAndAFinishedRunFreesTheSlot() throws {
        var ledger = ComputerRunLedger()
        #expect(!ledger.isActive)
        let token = try started(&ledger, .replayPreview)
        #expect(ledger.isActive)
        guard case .refused = ledger.begin(.hubTask) else { Issue.record("second run started"); return }
        ledger.finish(token)
        #expect(!ledger.isActive)
        _ = try started(&ledger, .hubTask)
    }

    // Regression: Stop only cleared a flag, so a model load in progress went on to start the task.
    @Test("stop cancels what is queued") func stopCancelsWhatIsQueued() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .screenPlanPreview)
        #expect(ledger.mayContinue(token))
        let plan = ledger.requestStop()
        #expect(!ledger.mayContinue(token))
        #expect(plan.cancel == [token])
        #expect(!plan.postHubStop)
        #expect(ledger.isStopping)
        #expect(ledger.statusLine?.hasPrefix("Stopping") == true)
    }

    @Test("a stopped run stays visible until it has ended") func aStoppedRunStaysVisibleUntilItHasEnded() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .replayPreview)
        _ = ledger.requestStop()
        #expect(ledger.isActive)
        guard case .refused = ledger.begin(.replayPreview) else { Issue.record("started during stop"); return }
        ledger.finish(token)
        #expect(!ledger.isStopping)
    }

    // Regression: startHubTask read the mode once, before /api/settings and /api/models/load, and
    // its later checkpoints asked only about Stop. Returning to dry run during the model load logged
    // "No input events will be sent", and /api/tasks/run was posted anyway.
    @Test("returning to dry run halts a start that was not stopped") func returningToDryRunHaltsAStartThatWasNotStopped() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .hubTask)
        #expect(ledger.hubStartCheck(token, mode: .live) == .proceed)
        #expect(ledger.mayContinue(token))
        #expect(ledger.hubStartCheck(token, mode: .dryRun) == .halted(reason: ComputerRunLedger.dryRunBeforeStart))
    }

    @Test("stop halts a start that is still live") func stopHaltsAStartThatIsStillLive() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .hubTask)
        _ = ledger.requestStop()
        #expect(ledger.hubStartCheck(token, mode: .live) == .halted(reason: ComputerRunLedger.stoppedBeforeStart))
    }

    @Test("a run no longer in the ledger never proceeds") func aRunNoLongerInTheLedgerNeverProceeds() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .hubTask)
        ledger.finish(token)
        #expect(ledger.hubStartCheck(token, mode: .live) != .proceed)
    }

    @Test("a run the hub holds is stopped at the hub and its watcher is kept") func aRunTheHubHoldsIsStoppedAtTheHubAndItsWatcherIsKept() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .hubTask)
        ledger.attachHubRun("run-1", to: token)
        let plan = ledger.requestStop()
        #expect(plan.postHubStop)
        #expect(!plan.hubStartInFlight)
        #expect(plan.cancel.isEmpty)
    }

    @Test("a start still in flight is cancelled and the hub is told twice") func aStartStillInFlightIsCancelledAndTheHubIsToldTwice() throws {
        var ledger = ComputerRunLedger()
        let token = try started(&ledger, .hubRoutine)
        let plan = ledger.requestStop()
        #expect(plan.cancel == [token])
        #expect(plan.postHubStop)
        #expect(plan.hubStartInFlight)
    }

    @Test("a hub run nothing here started still gets astop") func aHubRunNothingHereStartedStillGetsAStop() throws {
        var ledger = ComputerRunLedger()
        let adopted = ledger.adoptHubRun("run-9")
        let token = try #require(adopted)
        #expect(ledger.isActive)
        let again = ledger.adoptHubRun("run-9")
        #expect(again == nil)
        let plan = ledger.requestStop()
        #expect(plan.postHubStop)
        ledger.finish(token)
        #expect(!ledger.isActive)
    }

    @Test("a run being started is not adopted as asecond run") func aRunBeingStartedIsNotAdoptedAsASecondRun() throws {
        var ledger = ComputerRunLedger()
        _ = try started(&ledger, .hubTask)
        let adopted = ledger.adoptHubRun("run-2")
        #expect(adopted == nil)
        #expect(ledger.runs.count == 1)
    }

    // Regression: the watch ended after 20 polls, about 14 seconds, whatever the run was doing.
    @Test("a long run is watched until its receipt is final") func aLongRunIsWatchedUntilItsReceiptIsFinal() {
        for status in ["running", "paused", "stopping", nil] as [String?] {
            #expect(ComputerHubRunWatch.update(receiptStatus: status, failedStatusChecks: 0, idleStatusChecks: 0, secondsSinceStop: nil) == .keepWatching)
        }
        #expect(ComputerHubRunWatch.update(receiptStatus: "completed", failedStatusChecks: 0, idleStatusChecks: 0, secondsSinceStop: nil) == .finished(status: "completed"))
        #expect(ComputerHubRunWatch.update(receiptStatus: "canceled", failedStatusChecks: 9, idleStatusChecks: 9, secondsSinceStop: 99) == .finished(status: "canceled"))
    }

    // Regression: two failed status checks ended the watch, about 17 s, with the receipt still
    // saying running. Nothing had shown the run ended, the ledger emptied, and Stop, its global
    // shortcut and the block on Click Now all went away. A Hub that was slow and recovered kept
    // acting, and no later check ran until someone chose Refresh Hub.
    @Test("a hub that goes quiet never ends the watch") func aHubThatGoesQuietNeverEndsTheWatch() {
        #expect(ComputerHubRunWatch.update(receiptStatus: "running", failedStatusChecks: 1, idleStatusChecks: 0, secondsSinceStop: nil) == .keepWatching)
        for status in ["running", "paused", "stopping", nil] as [String?] {
            for failed in [2, 3, 1_000] {
                let update = ComputerHubRunWatch.update(receiptStatus: status, failedStatusChecks: failed, idleStatusChecks: 0, secondsSinceStop: nil)
                guard case .unconfirmed(let message) = update else { Issue.record("watch ended: \(update)"); continue }
                #expect(message.contains("Stop"))
            }
        }
    }

    // Regression: 30 s after Stop the watch ended, though the run could still be in "stopping".
    @Test("an unconfirmed stop keeps the run and offers stop again") func anUnconfirmedStopKeepsTheRunAndOffersStopAgain() {
        for seconds in [30.0, 3_600] {
            let update = ComputerHubRunWatch.update(receiptStatus: "stopping", failedStatusChecks: 0, idleStatusChecks: 0, secondsSinceStop: seconds)
            guard case .unconfirmed(let message) = update else { Issue.record("watch ended: \(update)"); continue }
            #expect(message.contains("Stop Again"))
        }
    }

    @Test("a hub that answers again goes back to watching") func aHubThatAnswersAgainGoesBackToWatching() {
        #expect(ComputerHubRunWatch.update(receiptStatus: "running", failedStatusChecks: 0, idleStatusChecks: 0, secondsSinceStop: nil) == .keepWatching)
    }

    @Test("only the hub saying nothing runs ends awatch with no receipt") func onlyTheHubSayingNothingRunsEndsAWatchWithNoReceipt() {
        let update = ComputerHubRunWatch.update(receiptStatus: "running", failedStatusChecks: 0, idleStatusChecks: 2, secondsSinceStop: nil)
        guard case .endedWithoutReceipt(let message) = update else { Issue.record("expected an end"); return }
        #expect(message.contains("Run History"))
        // A Hub that has stopped answering can't be reporting nothing running.
        guard case .unconfirmed = ComputerHubRunWatch.update(receiptStatus: "running", failedStatusChecks: 2, idleStatusChecks: 2, secondsSinceStop: nil) else {
            Issue.record("silence outranked by a stale idle count"); return
        }
    }

    @Test("each hub state says what is wrong and what to do") func eachHubStateSaysWhatIsWrongAndWhatToDo() throws {
        #expect(ComputerStudioDiagnosis.hub(probe: nil, appInstalled: true, isOnline: true, isStarting: false, lastError: "x") == nil)
        #expect(ComputerStudioDiagnosis.hub(probe: .notRunning, appInstalled: true, isOnline: false, isStarting: true, lastError: nil) == nil)
        let cases: [(ComputerStudioDiagnosis.HubProbe, Bool, String)] = [
            (.notConfigured, true, "private-names.json"),
            (.wrongService, true, "port 8765"),
            (.notRunning, false, "Install Local Hub"),
            (.notRunning, true, "Start Hub"),
        ]
        for (probe, installed, expected) in cases {
            let notice = try #require(ComputerStudioDiagnosis.hub(probe: probe, appInstalled: installed, isOnline: false, isStarting: false, lastError: nil))
            #expect(notice.text.contains(expected))
            #expect(!notice.action.isEmpty)
        }
        let withError = try #require(ComputerStudioDiagnosis.hub(probe: .notRunning, appInstalled: true, isOnline: false, isStarting: false, lastError: "refused"))
        #expect(withError.problem.contains("refused"))
    }

    @Test("no message uses an em dash") func noMessageUsesAnEmDash() throws {
        typealias Diagnosis = ComputerStudioDiagnosis
        let notices = [
            Diagnosis.screenScanDenied(), Diagnosis.screenScanEmpty(), Diagnosis.plannerFailed("e"), Diagnosis.plannerEmpty(),
            Diagnosis.noRoutines(hubOnline: true), Diagnosis.noRoutines(hubOnline: false),
            Diagnosis.noRuns(hubOnline: true), Diagnosis.noRuns(hubOnline: false), Diagnosis.noRecordedSteps(),
        ]
        for notice in notices { #expect(!notice.text.contains("\u{2014}")) }
        #expect(!ComputerLiveArming.liveDefaultMessage.contains("\u{2014}"))
        let updates = [
            ComputerHubRunWatch.update(receiptStatus: nil, failedStatusChecks: 2, idleStatusChecks: 0, secondsSinceStop: nil),
            ComputerHubRunWatch.update(receiptStatus: nil, failedStatusChecks: 0, idleStatusChecks: 2, secondsSinceStop: nil),
            ComputerHubRunWatch.update(receiptStatus: nil, failedStatusChecks: 0, idleStatusChecks: 0, secondsSinceStop: 30),
        ]
        var messages = [ComputerHubRunWatch.answeringAgain, ComputerRunLedger.stoppedBeforeStart, ComputerRunLedger.dryRunBeforeStart]
        for update in updates {
            switch update {
            case .unconfirmed(let message), .endedWithoutReceipt(let message): messages.append(message)
            default: Issue.record("expected a message")
            }
        }
        for message in messages { #expect(!message.contains("\u{2014}")) }
    }

    // lsof -Fpc output, one field per line.
    @Test("volume use reads process names") func volumeUseReadsProcessNames() {
        let use = ComputerVolumeUse.parse(stdout: "p123\ncFinder\nfcwd\np456\ncmdworker\nf3\np789\ncFinder\nftxt\n", stderr: "", status: 0, timedOut: false)
        #expect(use.state == .inUse(processes: ["Finder", "mdworker"]))
    }

    @Test("lsof exit one with silence means not in use but noisy failure does not") func lsofExitOneWithSilenceMeansNotInUseButNoisyFailureDoesNot() {
        #expect(ComputerVolumeUse.parse(stdout: "", stderr: "", status: 1, timedOut: false).state == .notInUse)
        guard case .unknown = ComputerVolumeUse.parse(stdout: "", stderr: "lsof: status error", status: 1, timedOut: false).state else {
            Issue.record("a failed check read as clean"); return
        }
        guard case .unknown = ComputerVolumeUse.parse(stdout: "", stderr: "", status: 0, timedOut: true).state else {
            Issue.record("a timeout read as clean"); return
        }
    }

    // Regression: Eject acted on one click, with no dialog and no word about who had files open.
    @Test("eject names the volume and warns when it is in use") func ejectNamesTheVolumeAndWarnsWhenItIsInUse() {
        let clean = ComputerEjectReview.make(volumeName: "Backup", use: ComputerVolumeUse(state: .notInUse), otherMountedVolumes: [])
        #expect(clean.title == "Eject Backup?")
        #expect(clean.warnings.isEmpty)
        #expect(clean.confirmTitle == "Eject Backup")

        let busy = ComputerEjectReview.make(volumeName: "Backup", use: ComputerVolumeUse(state: .inUse(processes: ["Finder"])), otherMountedVolumes: [])
        #expect(busy.warnings.first?.contains("Finder") == true)
        #expect(busy.confirmTitle == "Try to Eject Backup")

        let unknown = ComputerEjectReview.make(volumeName: "Backup", use: ComputerVolumeUse(state: .unknown(reason: "The check timed out.")), otherMountedVolumes: [])
        #expect(unknown.warnings.first?.contains("could not tell") == true)
    }

    @Test("eject lists long process lists briefly and names other volumes") func ejectListsLongProcessListsBrieflyAndNamesOtherVolumes() {
        let processes = (1...8).map { "p\($0)" }
        let review = ComputerEjectReview.make(volumeName: "Backup", use: ComputerVolumeUse(state: .inUse(processes: processes)), otherMountedVolumes: ["Photos"])
        #expect(review.warnings[0].contains("and 2 more"))
        #expect(review.warnings[1].contains("Photos"))
    }
}
