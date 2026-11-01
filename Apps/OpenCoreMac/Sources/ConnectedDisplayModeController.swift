import Combine
import CoreGraphics
import CoreTelemetry
import Foundation

private func connectedDisplayModeChanged(_ displayID: CGDirectDisplayID,
                                         _ flags: CGDisplayChangeSummaryFlags,
                                         _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let controller = Unmanaged<ConnectedDisplayModeController>.fromOpaque(context).takeUnretainedValue()
    let observed = ContinuousClock.now
    // Quartz can call this synchronously from inside a configuration transaction.
    // Only enqueue a notification; never reconfigure from a reconfiguration callback.
    Task { @MainActor in controller.noteReconfiguration(displayID, flags: flags, observed: observed) }
}

@MainActor
final class ConnectedDisplayModeController: ObservableObject {
    static let shared = ConnectedDisplayModeController()

    @Published private(set) var pendingDisplayID: UInt32?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false

    // Chosen confirmation period, not a hardware measurement. The controller owns
    // the task so changing views cannot cancel the automatic restoration.
    private let confirmationSeconds = 15
    private var countdown: Task<Void, Never>?
    private var pending: Preview?
    private var callbackError: CGError?

    private struct CapturedDisplay {
        let identity: DisplayConnectionIdentity
        let mode: CGDisplayMode
        let choice: ConnectedDisplayModeChoice
        let main: Bool
        let x: Int32
        let y: Int32
    }

    private struct Preview {
        let token: UUID
        let displayID: CGDirectDisplayID
        let name: String
        let selected: ConnectedDisplayModeChoice
        let originals: [CapturedDisplay]
        var applied: [CapturedDisplay]
        let started: ContinuousClock.Instant
        var confirmation: DisplayModeConfirmationWindow?
        var invalidation: String?
        var sessionCommitAttempted = false
    }

    private struct Failure: LocalizedError {
        let explanation: String
        var mayHaveChanged = false
        var errorDescription: String? { explanation }
    }

    private init() {
        let result = CGDisplayRegisterReconfigurationCallback(
            connectedDisplayModeChanged, Unmanaged.passUnretained(self).toOpaque())
        if result != .success {
            callbackError = result
            message = "Display changes cannot be watched safely (macOS error \(result.rawValue)). Mode previews are unavailable."
        }
    }

    func preview(display: ConnectedDisplay, choiceID: String) {
        guard !BetterDisplayClient.shared.isMutating else { message = "Wait for the BetterDisplay control change to finish before previewing a mode."; return }
        guard !isBusy else { return }
        guard pending == nil else { message = "Keep or revert the current preview before trying another mode."; return }
        guard callbackError == nil else {
            message = "Mode preview is unavailable because macOS display-change monitoring failed. Restart OpenCore to try again."
            return
        }
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            let originals = try captureConfiguration()
            guard let original = originals.first(where: { $0.identity.displayID == display.id }),
                  original.identity == display.connectionIdentity else {
                throw Failure(explanation: "This display connection changed. Refresh the display list before choosing a mode.")
            }
            let liveModes = ConnectedDisplayInventory.copyModes(display.id)
            let catalog = Dictionary(liveModes.map { (ConnectedDisplayModeChoice($0).id, $0) },
                                     uniquingKeysWith: { first, _ in first })
            guard Set(catalog.keys) == Set(display.modeChoices.map(\.id)),
                  original.choice.id == display.currentModeKey else {
                throw Failure(explanation: "The available or current modes changed. Refresh the display list and choose again.")
            }
            guard let mode = catalog[choiceID], display.modeChoices.contains(where: { $0.id == choiceID }) else {
                throw Failure(explanation: "That exact mode is no longer offered by this connection.")
            }
            let choice = ConnectedDisplayModeChoice(mode)
            guard choice.usableForDesktop, choice.width > 0, choice.height > 0,
                  choice.pixelWidth > 0, choice.pixelHeight > 0 else {
                throw Failure(explanation: "macOS does not mark this mode as usable for the desktop. It can be inspected but cannot be previewed here.")
            }
            guard choice.id != original.choice.id else { message = "That exact mode is already active."; return }

            let now = ContinuousClock.now
            pending = Preview(token: UUID(), displayID: display.id, name: display.title,
                              selected: choice, originals: originals, applied: [], started: now)
            do {
                try configure(modes: [(display.id, mode)], origins: [], option: .forAppOnly)
            } catch let failure as Failure where !failure.mayHaveChanged {
                clearPending()
                throw failure
            }
            let applied = try captureConfiguration()
            guard sameConnections(originals, applied),
                  applied.first(where: { $0.identity.displayID == display.id })?.choice.id == choice.id else {
                throw Failure(explanation: "macOS did not report the selected mode after the change.", mayHaveChanged: true)
            }
            // A mode change may move neighbouring displays. Record the exact result
            // so rollback cannot silently overwrite a later change from another app.
            pending?.applied = applied
            // Applying/verifying a mode can take time. Give the user the full
            // chosen confirmation period after that work has actually succeeded.
            pending?.confirmation = DisplayModeConfirmationWindow(
                verifiedAt: .now, duration: .seconds(confirmationSeconds))
            pendingDisplayID = display.id
            remainingSeconds = confirmationSeconds
            message = "Previewing \(choice.title) on \(display.title). Keep it within \(confirmationSeconds) seconds or the previous modes and layout will return."
            startCountdown()
            ConnectedDisplayInventory.shared.refresh()
        } catch {
            if pending != nil { restore(reason: error.localizedDescription) }
            else { message = error.localizedDescription }
        }
    }

    func keep() {
        guard !isBusy, var preview = pending else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let confirmation = preview.confirmation else {
                throw Failure(explanation: "The mode preview has not been verified and cannot be kept.")
            }
            if ContinuousClock.now >= confirmation.deadline {
                restore(reason: "The confirmation period expired.")
                return
            }
            _ = try validatePending(preview)
            let current = try captureConfiguration()
            guard sameConfiguration(current, preview.applied),
                  let target = current.first(where: { $0.identity.displayID == preview.displayID }),
                  target.choice.id == preview.selected.id else {
                throw Failure(explanation: "The preview changed outside OpenCore, so it cannot be kept.")
            }
            let available = ConnectedDisplayInventory.copyModes(preview.displayID)
            guard let exactMode = available.first(where: { ConnectedDisplayModeChoice($0).id == preview.selected.id }) else {
                throw Failure(explanation: "The previewed mode is no longer offered. It cannot be kept.")
            }
            preview.sessionCommitAttempted = true
            pending = preview
            try configure(modes: [(preview.displayID, exactMode)], origins: [], option: .forSession)
            let kept = try captureConfiguration()
            guard sameConfiguration(kept, current) else {
                throw Failure(explanation: "macOS did not preserve the confirmed configuration.", mayHaveChanged: true)
            }
            clearPending()
            message = "Kept \(preview.selected.title) on \(preview.name) for this login session."
            ConnectedDisplayInventory.shared.refresh()
        } catch {
            restore(reason: error.localizedDescription)
        }
    }

    func revert() {
        guard !isBusy, pending != nil else { return }
        isBusy = true
        defer { isBusy = false }
        restore(reason: "Preview cancelled.")
    }

    fileprivate func noteReconfiguration(_ id: CGDirectDisplayID,
                                          flags: CGDisplayChangeSummaryFlags,
                                          observed: ContinuousClock.Instant) {
        guard var preview = pending, observed >= preview.started else { return }
        if !flags.intersection([.addFlag, .removeFlag, .enabledFlag, .disabledFlag,
                                .mirrorFlag, .unMirrorFlag]).isEmpty {
            preview.invalidation = "A display was connected, disconnected, enabled or mirrored during the preview (display \(id))."
            pending = preview
        }
    }

    private func startCountdown() {
        countdown?.cancel()
        guard let token = pending?.token else { return }
        countdown = Task { [weak self] in
            // Chosen 200 ms polling interval keeps the deadline responsive without
            // tying restoration to a view's lifetime or to a wall-clock adjustment.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                guard let self, self.pending?.token == token else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let preview = pending, let confirmation = preview.confirmation, !isBusy else { return }
        remainingSeconds = confirmation.remainingSeconds(at: .now)
        if preview.invalidation != nil || remainingSeconds == 0 {
            isBusy = true
            restore(reason: preview.invalidation ?? "The confirmation period expired.")
            isBusy = false
        }
    }

    private func restore(reason: String) {
        guard let preview = pending else { return }
        do {
            let liveConnections = try validatePending(preview)
            var current: [CapturedDisplay]?
            var currentReadError: String?
            if !preview.applied.isEmpty {
                do { current = try captureConfiguration() }
                catch { currentReadError = error.localizedDescription }
            }
            let decision = DisplayModeRollbackDecision.evaluate(
                originalConnections: preview.originals.map(\.identity), liveConnections: liveConnections,
                previewWasVerified: !preview.applied.isEmpty,
                currentMatchesPreview: current.map { sameConfiguration($0, preview.applied) },
                currentMatchesOriginal: current.map { sameConfiguration($0, preview.originals) })
            switch decision {
            case .connectionsChanged:
                throw Failure(explanation: "The connected displays changed, so the captured configuration cannot be restored safely.")
            case .alreadyRestored:
                clearPending()
                message = "\(reason) The original modes and layout are already restored."
                ConnectedDisplayInventory.shared.refresh()
                return
            case .changedOutsidePreview:
                throw Failure(explanation: "Another app changed the display configuration. OpenCore did not overwrite that change with its captured layout.")
            case .currentConfigurationUnavailable:
                throw Failure(explanation: currentReadError ?? "The current configuration could not be checked for changes outside OpenCore.")
            case .restore:
                break
            }
            try configure(modes: preview.originals.map { ($0.identity.displayID, $0.mode) },
                          origins: preview.originals,
                          option: preview.sessionCommitAttempted ? .forSession : .forAppOnly)
            let restored = try captureConfiguration()
            guard sameConfiguration(restored, preview.originals) else {
                throw Failure(explanation: "macOS did not report the exact captured modes and positions after restoration.")
            }
            clearPending()
            message = "\(reason) Restored the previous display modes and layout."
        } catch {
            clearPending()
            message = "\(reason) Automatic restoration was not completed: \(error.localizedDescription) Use macOS Display Settings to recover. The preview did not write permanent settings."
        }
        ConnectedDisplayInventory.shared.refresh()
    }

    private func validatePending(_ preview: Preview) throws -> [DisplayConnectionIdentity] {
        if let invalidation = preview.invalidation { throw Failure(explanation: invalidation) }
        let current = try captureConnections()
        guard current == preview.originals.map(\.identity) else {
            throw Failure(explanation: "The display identities changed during the preview.")
        }
        return current
    }

    /// Online identity and mirroring can be checked even when a failed mode is
    /// inactive or unreadable. This is deliberately independent of mode capture.
    private func captureConnections() throws -> [DisplayConnectionIdentity] {
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &count), operation: "read connected displays")
        guard count > 0 else { throw Failure(explanation: "No online displays are available.") }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetOnlineDisplayList(count, &ids, &count), operation: "read connected displays")
        var finalCount: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &finalCount), operation: "verify connected displays")
        guard count == finalCount else {
            throw Failure(explanation: "The connected display list changed while it was being read. Try again after the connection settles.")
        }
        let identities = ids.prefix(Int(count)).map {
            DisplayConnectionIdentity(displayID: $0, vendorID: CGDisplayVendorNumber($0),
                                      productID: CGDisplayModelNumber($0), serialNumber: CGDisplaySerialNumber($0),
                                      builtIn: CGDisplayIsBuiltin($0) != 0)
        }
        for identity in identities {
            let id = identity.displayID
            guard CGDisplayIsOnline(id) != 0 else {
                throw Failure(explanation: "A captured display is no longer online.")
            }
            guard CGDisplayIsInMirrorSet(id) == 0 else {
                throw Failure(explanation: "Mode preview is unavailable while displays are mirrored. Turn off mirroring in Display Settings first.")
            }
            guard identity.isUnambiguous(in: identities) else {
                throw Failure(explanation: "Two connected displays have an ambiguous hardware identity. Mode preview is unavailable to avoid changing the wrong monitor.")
            }
        }
        return identities.sorted { $0.displayID < $1.displayID }
    }

    private func captureConfiguration() throws -> [CapturedDisplay] {
        try captureConnections().map { identity in
            let id = identity.displayID
            guard CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0 else {
                throw Failure(explanation: "Every connected display must be awake and active to capture a restorable configuration.")
            }
            guard let mode = CGDisplayCopyDisplayMode(id) else {
                throw Failure(explanation: "macOS did not return a restorable current mode for display \(id).")
            }
            let origin = CGDisplayBounds(id).origin
            guard let x = Int32(exactly: origin.x), let y = Int32(exactly: origin.y) else {
                throw Failure(explanation: "The display position could not be captured exactly.")
            }
            return CapturedDisplay(identity: identity, mode: mode,
                                   choice: ConnectedDisplayModeChoice(mode), main: CGDisplayIsMain(id) != 0,
                                   x: x, y: y)
        }.sorted { $0.identity.displayID < $1.identity.displayID }
    }

    private func configure(modes: [(CGDirectDisplayID, CGDisplayMode)],
                           origins: [CapturedDisplay], option: CGConfigureOption) throws {
        var configuration: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&configuration), operation: "begin a display change")
        guard let configuration else { throw Failure(explanation: "macOS did not create a display configuration.") }
        do {
            for (id, mode) in modes {
                try check(CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil), operation: "select the exact mode for display \(id)")
            }
            for original in origins {
                try check(CGConfigureDisplayOrigin(configuration, original.identity.displayID, original.x, original.y),
                          operation: "restore the position of display \(original.identity.displayID)")
            }
        } catch {
            let cancellation = CGCancelDisplayConfiguration(configuration)
            if cancellation != .success {
                throw Failure(explanation: "\(error.localizedDescription) macOS also could not cancel the transaction (error \(cancellation.rawValue)).")
            }
            throw error
        }
        // Completion consumes the configuration even on failure. Do not cancel it
        // afterward or call CGRestorePermanentDisplayConfiguration.
        let result = CGCompleteDisplayConfiguration(configuration, option)
        if result != .success {
            throw Failure(explanation: "macOS could not apply the display configuration (error \(result.rawValue)).", mayHaveChanged: true)
        }
    }

    private func check(_ result: CGError, operation: String) throws {
        guard result == .success else {
            throw Failure(explanation: "macOS could not \(operation) (error \(result.rawValue)).")
        }
    }

    private func sameConnections(_ lhs: [CapturedDisplay], _ rhs: [CapturedDisplay]) -> Bool {
        lhs.map(\.identity) == rhs.map(\.identity)
    }

    private func sameConfiguration(_ lhs: [CapturedDisplay], _ rhs: [CapturedDisplay]) -> Bool {
        sameConnections(lhs, rhs) && zip(lhs, rhs).allSatisfy {
            $0.choice.id == $1.choice.id && $0.main == $1.main && $0.x == $1.x && $0.y == $1.y
        }
    }

    private func clearPending() {
        countdown?.cancel()
        countdown = nil
        pending = nil
        pendingDisplayID = nil
        remainingSeconds = 0
    }
}
