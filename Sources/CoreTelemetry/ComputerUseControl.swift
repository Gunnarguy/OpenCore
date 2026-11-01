import Foundation

// Computer Use Studio's decisions, kept out of the app so they can be tested. The app has no test
// target, and each decision here is one where a wrong answer sends a real click, leaves a run
// going with no way to stop it, or arms live control the owner did not ask for.

// MARK: - Dry run or live

public enum ComputerExecutionMode: Sendable, Equatable {
    case dryRun
    case live
}

/// Whether input events may be sent. Nothing here remembers the session's switch: a relaunch starts
/// again from the saved default.
public enum ComputerLiveArming {
    public struct Launch: Sendable, Equatable {
        public let mode: ComputerExecutionMode
        /// Why the saved default was not followed, when it was not.
        public let notice: String?

        public init(mode: ComputerExecutionMode, notice: String?) {
            self.mode = mode
            self.notice = notice
        }
    }

    public enum SwitchDecision: Sendable, Equatable {
        /// Going back to dry run never asks.
        case returnToDryRun
        case askFirst(title: String, message: String)
        case refuse(reason: String)
        case nothingToDo
    }

    /// `defaultDryRun` is the saved setting. A stored `false` is honoured only with the confirmation
    /// that goes with it: the setting could be turned off with no dialog before the dialog existed,
    /// so a bare `false` is not evidence that anyone agreed to start live.
    public static func launch(defaultDryRun: Bool, liveDefaultConfirmed: Bool) -> Launch {
        if defaultDryRun { return Launch(mode: .dryRun, notice: nil) }
        if liveDefaultConfirmed { return Launch(mode: .live, notice: nil) }
        return Launch(
            mode: .dryRun,
            notice: "Started on dry run. The saved default says live, but it was never confirmed. Turn the default on and off again in Settings to confirm it.")
    }

    public static func request(_ target: ComputerExecutionMode, from current: ComputerExecutionMode,
                               runningTitle: String?) -> SwitchDecision {
        guard target != current else { return .nothingToDo }
        if target == .dryRun { return .returnToDryRun }
        if let runningTitle {
            return .refuse(reason: "\(runningTitle) is running. Stop it or let it finish before arming live control.")
        }
        return .askFirst(
            title: "Arm live control?",
            message: "Click Now, Click Element and Move Cursor will send real input to this Mac, and scoped tasks and routines will run in Local Hub. This lasts until you switch back or quit.")
    }

    public static let liveDefaultTitle = "Start in live mode on every launch?"
    public static let liveDefaultMessage = "OpenCore will open with live control armed from the next launch, with no question at launch. This session's switch does not change."
}

// MARK: - What one planned step does

public enum ComputerPointerAction: String, Sendable, Equatable, CaseIterable {
    case click
    case doubleClick = "double_click"
    case move
}

public enum ComputerStepDecision: Sendable, Equatable {
    /// Live: send this action, and only this action.
    case perform(ComputerPointerAction, title: String)
    /// Dry run: move the reticle and log. Sends nothing.
    case preview(title: String)
    case unavailable(title: String, reason: String)

    public var title: String {
        switch self {
        case .perform(_, let title), .preview(let title), .unavailable(let title, _): title
        }
    }

    public var isEnabled: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var reason: String? {
        if case .unavailable(_, let reason) = self { return reason }
        return nil
    }
}

public enum ComputerStepPolicy {
    /// What the preview can show. Wider than what can be sent, because a right click can be drawn
    /// but this app has no way to send one.
    public static let previewable: Set<String> = ["click", "double_click", "right_click", "move"]

    /// One button, one step. Regression: the button called `executeClick` whatever `action` said,
    /// so a planned `move` or `double_click` arrived as a single click.
    public static func decide(action: String, x: Double, y: Double, screenWidth: Double, screenHeight: Double,
                              mode: ComputerExecutionMode, inputPermitted: Bool, runningTitle: String?) -> ComputerStepDecision {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < screenWidth, y < screenHeight else {
            return .unavailable(title: "Off Screen", reason: "This point is outside the screen. Scan the screen and plan again.")
        }
        switch mode {
        case .dryRun:
            guard previewable.contains(action) else { return .unavailable(title: "Not Available", reason: unsupported(action)) }
            return .preview(title: "Test Reticle")
        case .live:
            guard let pointer = ComputerPointerAction(rawValue: action) else {
                return .unavailable(title: "Not Available", reason: unsupported(action))
            }
            if let runningTitle {
                return .unavailable(title: liveTitle(pointer), reason: "\(runningTitle) is running. Stop it or let it finish first.")
            }
            guard inputPermitted else {
                return .unavailable(title: liveTitle(pointer), reason: "OpenCore has no Accessibility permission. Allow it in System Settings, Privacy & Security, Accessibility.")
            }
            return .perform(pointer, title: liveTitle(pointer))
        }
    }

    private static func liveTitle(_ action: ComputerPointerAction) -> String {
        switch action {
        case .click: "Click Now"
        case .doubleClick: "Double-Click Now"
        case .move: "Move Cursor Now"
        }
    }

    private static func unsupported(_ action: String) -> String {
        switch action {
        case "type", "scroll":
            "This screen can't \(action). Run it as a scoped task in Local Hub, which knows the field or window."
        case "right_click":
            "This screen can't send a right click. Run it as a scoped task in Local Hub."
        default:
            "This screen doesn't know the action \"\(action)\", so it sends nothing. Plan the step again."
        }
    }
}

// MARK: - What is running, and stopping it

public struct ComputerRunToken: Hashable, Sendable {
    public let value: Int
}

public enum ComputerRunKind: String, Sendable, CaseIterable {
    case screenPlanPreview = "Screen plan preview"
    case replayPreview = "Replay preview"
    case screenPlanning = "Screen planning"
    case textAssistance = "Apple model request"
    case hubTask = "Scoped task"
    case hubRoutine = "Saved routine"

    public var usesHub: Bool { self == .hubTask || self == .hubRoutine }
}

public struct ComputerRunEntry: Sendable, Equatable {
    public let token: ComputerRunToken
    public let kind: ComputerRunKind
    /// Set once Local Hub has accepted the run. From then on Stop has to reach the Hub.
    public var hubRunID: String?
    public var stopRequested = false
}

public struct ComputerRunStopPlan: Sendable, Equatable {
    /// Local work to cancel. A run the Hub already holds is left out, because its watcher has to
    /// keep going to report how the stop ended.
    public let cancel: [ComputerRunToken]
    public let postHubStop: Bool
    /// A start request may be on its way. The Hub can begin a run after the app gave up on the
    /// reply, so the first stop may reach it too early.
    public let hubStartInFlight: Bool
}

public enum ComputerRunStart: Sendable, Equatable {
    case started(ComputerRunToken)
    case refused(reason: String)
}

/// What a Hub start asks between one awaited request and the next.
public enum ComputerHubStartCheck: Sendable, Equatable {
    case proceed
    case halted(reason: String)
}

/// Everything the Studio has running. One run at a time, because two sequences acting on one Mac
/// cannot both know what is on screen.
public struct ComputerRunLedger: Sendable, Equatable {
    public private(set) var runs: [ComputerRunEntry] = []
    private var nextToken = 0

    public init() {}

    public var isActive: Bool { !runs.isEmpty }
    public var isStopping: Bool { runs.contains(where: \.stopRequested) }
    public var usesHub: Bool { runs.contains { $0.kind.usesHub } }
    public var runningTitle: String? { runs.first?.kind.rawValue }

    public var statusLine: String? {
        guard let first = runs.first else { return nil }
        return isStopping ? "Stopping \(first.kind.rawValue.lowercased())..." : "\(first.kind.rawValue) is running."
    }

    public mutating func begin(_ kind: ComputerRunKind) -> ComputerRunStart {
        if let first = runs.first {
            let verb = isStopping ? "is stopping" : "is running"
            return .refused(reason: "\(first.kind.rawValue) \(verb). Wait for it to end before starting something else.")
        }
        return .started(add(kind, hubRunID: nil))
    }

    public mutating func attachHubRun(_ id: String, to token: ComputerRunToken) {
        guard let index = runs.firstIndex(where: { $0.token == token }) else { return }
        runs[index].hubRunID = id
    }

    /// A run the Hub reports that nothing here started, such as one from its own window or from
    /// before a relaunch. It gets a Stop too. A start still in flight is left alone, because that
    /// is this same run and its starter will attach it.
    public mutating func adoptHubRun(_ id: String) -> ComputerRunToken? {
        guard !runs.contains(where: { $0.hubRunID == id || ($0.kind.usesHub && $0.hubRunID == nil) }) else { return nil }
        return add(.hubTask, hubRunID: id)
    }

    /// Every queued step asks this before it goes ahead.
    public func mayContinue(_ token: ComputerRunToken) -> Bool {
        runs.contains { $0.token == token && !$0.stopRequested }
    }

    public static let stoppedBeforeStart = "Stopped before the run started. Nothing further was sent to Local Hub."
    public static let dryRunBeforeStart = "Back on dry run before the run started, so no task was sent to Local Hub."

    /// Regression: live was read once, before the model load, and only Stop was checked after it.
    /// Going back to dry run while the model loaded logged that no input would be sent, and the task
    /// was posted anyway. Stop and the mode are separate reasons, because neither implies the other.
    public func hubStartCheck(_ token: ComputerRunToken, mode: ComputerExecutionMode) -> ComputerHubStartCheck {
        guard mayContinue(token) else { return .halted(reason: Self.stoppedBeforeStart) }
        guard mode == .live else { return .halted(reason: Self.dryRunBeforeStart) }
        return .proceed
    }

    public mutating func requestStop() -> ComputerRunStopPlan {
        for index in runs.indices { runs[index].stopRequested = true }
        return ComputerRunStopPlan(
            cancel: runs.filter { $0.hubRunID == nil }.map(\.token),
            postHubStop: runs.contains { $0.kind.usesHub },
            hubStartInFlight: runs.contains { $0.kind.usesHub && $0.hubRunID == nil })
    }

    public mutating func finish(_ token: ComputerRunToken) {
        runs.removeAll { $0.token == token }
    }

    private mutating func add(_ kind: ComputerRunKind, hubRunID: String?) -> ComputerRunToken {
        let token = ComputerRunToken(value: nextToken)
        nextToken += 1
        runs.append(ComputerRunEntry(token: token, kind: kind, hubRunID: hubRunID))
        return token
    }
}

// MARK: - Watching a Hub run to its end

public enum ComputerHubRunUpdate: Sendable, Equatable {
    case keepWatching
    case finished(status: String)
    /// The run may still be going, so the watch goes on and Stop stays up. The message says what to do.
    case unconfirmed(message: String)
    /// Local Hub answered that nothing is running, and no final receipt exists. Only this answer
    /// ends a watch without a receipt.
    case endedWithoutReceipt(message: String)
}

public enum ComputerHubRunWatch {
    public static let openStatuses: Set<String> = ["running", "paused", "stopping"]
    /// Chosen, not measured. Two checks, so one slow reply from a busy Hub isn't reported as a problem.
    public static let checksBeforeReporting = 2
    /// Chosen, not measured. Long enough for the Hub to close a window and write its receipt.
    public static let stopConfirmationSeconds = 30.0
    public static let answeringAgain = "Local Hub is answering again. This run is still being watched."

    /// Regression: the app stopped looking after 14 seconds and called that "still running", so a
    /// longer run went on with no Stop on screen. The watch now ends only on a final receipt or on
    /// the Hub saying nothing is running.
    ///
    /// Regression: failed checks and an unconfirmed stop ended the watch too, after about 17 and 30
    /// seconds. Silence doesn't show a run ended, so a Hub that was slow and recovered kept acting
    /// with no Stop, no global shortcut, and Click Now enabled.
    public static func update(receiptStatus: String?, failedStatusChecks: Int, idleStatusChecks: Int,
                              secondsSinceStop: Double?) -> ComputerHubRunUpdate {
        if let receiptStatus, !openStatuses.contains(receiptStatus) { return .finished(status: receiptStatus) }
        if failedStatusChecks >= checksBeforeReporting {
            return .unconfirmed(message: "Local Hub stopped answering, so this run may still be going. Stop stays available and OpenCore keeps checking. Open Local Hub and check the Mac.")
        }
        if idleStatusChecks >= checksBeforeReporting {
            return .endedWithoutReceipt(message: "Local Hub reports nothing running, but this run has no final receipt. Check Run History before relying on the result.")
        }
        if let secondsSinceStop, secondsSinceStop >= stopConfirmationSeconds {
            return .unconfirmed(message: "Local Hub has not confirmed the stop after \(Int(stopConfirmationSeconds)) seconds, so this run may still be going. Choose Stop Again, or open Local Hub and stop the run there.")
        }
        return .keepWatching
    }
}

// MARK: - What is wrong, and what to do

public struct ComputerStudioNotice: Sendable, Equatable {
    public let problem: String
    public let action: String

    public init(problem: String, action: String) {
        self.problem = problem
        self.action = action
    }

    public var text: String { "\(problem) \(action)" }
}

public enum ComputerStudioDiagnosis {
    public enum HubProbe: Sendable, Equatable {
        case notConfigured
        case wrongService
        case notRunning
    }

    /// `nil` once the Hub is connected or while it is being started.
    public static func hub(probe: HubProbe?, appInstalled: Bool, isOnline: Bool, isStarting: Bool, lastError: String?) -> ComputerStudioNotice? {
        if isOnline || isStarting { return nil }
        switch probe ?? .notRunning {
        case .notConfigured:
            return ComputerStudioNotice(
                problem: "Local Hub isn't set up here: private-names.json has no Hub identity, so OpenCore won't trust whatever answers on its port.",
                action: "Install private-names.json beside the store and relaunch.")
        case .wrongService:
            return ComputerStudioNotice(
                problem: "Something is answering on Local Hub's port, but it isn't Local Hub, so no token was requested.",
                action: "Quit whatever is using port 8765, then choose Start Hub.")
        case .notRunning:
            guard appInstalled else {
                return ComputerStudioNotice(
                    problem: "Local Hub isn't running, and Local Hub.app isn't in ~/Applications.",
                    action: "Install Local Hub, then choose Start Hub.")
            }
            let detail = lastError.map { " Last error: \($0)" } ?? ""
            return ComputerStudioNotice(
                problem: "Local Hub isn't running, so scoped tasks and routines can't run.\(detail)",
                action: "Choose Start Hub. Previews in this window still work.")
        }
    }

    public static func screenScanDenied() -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "The screen could not be captured.",
            action: "Allow OpenCore in System Settings, Privacy & Security, Screen & System Audio Recording, then choose Scan Screen Now.")
    }

    public static func screenScanEmpty() -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "The scan worked but found no text on screen.",
            action: "Bring the window you want into view, then choose Scan Screen Now.")
    }

    public static func plannerFailed(_ error: String) -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "Planning failed: \(error)",
            action: "Check that Apple Intelligence is on and ready, then try again.")
    }

    public static func plannerEmpty() -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "The planner returned no click, double click or move, so there is nothing to preview.",
            action: "Name one visible control in the goal, such as \"Click Sync All\". Typing and scrolling need a scoped task.")
    }

    public static func noRoutines(hubOnline: Bool) -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "No saved routines.",
            action: hubOnline ? "Run a scoped task that passes its check, then save it as a routine in Local Hub."
                : "Routines are saved by Local Hub, so start it first, then save one from a task that passes its check.")
    }

    public static func noRuns(hubOnline: Bool) -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "No run receipts yet.",
            action: hubOnline ? "Run a scoped task with Live Execution armed, and its receipt appears here."
                : "Start Local Hub and run a scoped task, and its receipt appears here.")
    }

    public static func noRecordedSteps() -> ComputerStudioNotice {
        ComputerStudioNotice(
            problem: "No recorded steps, and desktop recording is switched off here.",
            action: "Record a browser demonstration in Local Hub, then use it from Saved Routines.")
    }
}

// MARK: - Eject

public struct ComputerVolumeUse: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notInUse
        case inUse(processes: [String])
        case unknown(reason: String)
    }

    public let state: State

    public init(state: State) { self.state = state }

    /// Reads `lsof -Fpc <mount>`. lsof exits 1 with no output when nothing is open, and also exits
    /// 1 when it failed, so only a silent exit counts as "not in use". A failed check is not a
    /// clean one.
    public static func parse(stdout: String, stderr: String, status: Int32, timedOut: Bool) -> ComputerVolumeUse {
        if timedOut { return ComputerVolumeUse(state: .unknown(reason: "The check timed out.")) }
        let names = stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("c") else { return nil }
            let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        if !names.isEmpty { return ComputerVolumeUse(state: .inUse(processes: Array(Set(names)).sorted())) }
        if status == 0 || (status == 1 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return ComputerVolumeUse(state: .notInUse)
        }
        return ComputerVolumeUse(state: .unknown(reason: "The check failed with status \(status)."))
    }
}

public struct ComputerEjectReview: Sendable, Equatable {
    public let title: String
    public let warnings: [String]
    public let confirmTitle: String

    /// A nil `use` means the check hasn't finished, and the eject button waits for it.
    public static func make(volumeName: String, use: ComputerVolumeUse?, otherMountedVolumes: [String]) -> ComputerEjectReview {
        var warnings: [String] = []
        var confirm = "Eject \(volumeName)"
        switch use?.state {
        case .none, .notInUse:
            break
        case .inUse(let processes):
            let shown = processes.prefix(6).joined(separator: ", ")
            let rest = processes.count > 6 ? " and \(processes.count - 6) more" : ""
            warnings.append("\(volumeName) is in use by \(shown)\(rest). Close those first. macOS may refuse, and unsaved work could be lost.")
            confirm = "Try to Eject \(volumeName)"
        case .unknown(let reason):
            warnings.append("OpenCore could not tell whether \(volumeName) is in use. \(reason) Close anything using it first.")
            confirm = "Try to Eject \(volumeName)"
        }
        if !otherMountedVolumes.isEmpty {
            warnings.append("Other volumes on this disk may unmount too: \(otherMountedVolumes.joined(separator: ", ")).")
        }
        return ComputerEjectReview(title: "Eject \(volumeName)?", warnings: warnings, confirmTitle: confirm)
    }
}
