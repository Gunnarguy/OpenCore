import Testing
@testable import CoreTelemetry

@Suite("Live monitor controls")
struct DisplayControlUpdateTests {
    // Original failure: dragging only staged a local value; later edits also required a full reload.
    // The live path must coalesce to the newest unsent value without erasing another control.
    @Test("a slider burst sends its newest value and preserves independent controls")
    func latestValueWins() {
        var queue = DisplayControlUpdateQueue()
        queue.enqueue(code: 0x10, value: 95)
        queue.enqueue(code: 0x12, value: 70)
        queue.enqueue(code: 0x10, value: 85)
        let first = queue.takeNext()
        #expect(first?.code == 0x10 && first?.value == 85)
        let second = queue.takeNext()
        #expect(second?.code == 0x12 && second?.value == 70)
        #expect(queue.isEmpty)
    }

    @Test("edits during an admitted request remain available for the following request")
    func subsequentDragIsNotLost() {
        var queue = DisplayControlUpdateQueue()
        let old = queue.enqueue(code: 0x10, value: 90)
        let taken = queue.takeNext()
        #expect(taken == old)
        let newest = queue.enqueue(code: 0x10, value: 80)
        #expect(newest.id != old.id)
        #expect(queue.value(for: 0x10) == 80)
        let next = queue.takeNext()
        #expect(next == newest)
    }

    @Test("leaving the screen discards unsent edits without inventing a command cancellation")
    func discardQueuedEdits() {
        var queue = DisplayControlUpdateQueue()
        queue.enqueue(code: 0x10, value: 90)
        let posted = queue.takeNext()
        queue.enqueue(code: 0x10, value: 80)
        queue.removeAll()
        let next = queue.takeNext()
        #expect(queue.isEmpty && next == nil)
        #expect(posted?.value == 90)
        #expect(posted.map { !queue.isCurrent($0) } == true)
    }

    // Original UI hid mismatches below the complete control list. A successful send must not
    // become a green verified result when the monitor still reports its previous value.
    // Original lifecycle bug: a taken edit could finish preflight and post after its view closed.
    @Test("a taken preflight edit is invalid after the live session stops")
    func preflightStopsBeforePosting() throws {
        var queue = DisplayControlUpdateQueue()
        queue.enqueue(code: 0x10, value: 90)
        let pending = queue.takeNext()
        let taken = try #require(pending)
        #expect(queue.isCurrent(taken))
        queue.removeAll()
        let nextSession = queue.enqueue(code: 0x10, value: 70)
        #expect(!queue.isCurrent(taken))
        #expect(queue.isCurrent(nextSession))
    }

    @Test("command acceptance is distinct from matching monitor readback")
    func readbackDecidesOutcome() {
        #expect(DisplayControlFeedback.readback(code: 0x10, requested: 80, actual: 80).state == .verified)
        #expect(DisplayControlFeedback.readback(code: 0x10, requested: 80, actual: 100).state == .notApplied)
        #expect(DisplayControlFeedback.readback(code: 0x10, requested: 80, actual: nil).state == .unavailable)
    }

    @Test("the write-only power-off command can read back the standard off state")
    func powerCommandAndStateDiffer() {
        #expect(DisplayControlFeedback.readback(code: 0xD6, requested: 5, actual: 4).state == .verified)
        #expect(DisplayControlFeedback.readback(code: 0x10, requested: 5, actual: 4).state == .notApplied)
        #expect(DisplayControlFeedback.readback(code: 0xD6, requested: 5, actual: 1).state == .notApplied)
    }

    @Test("live picture adjustment excludes input power presets and resets")
    func liveAndDisruptiveControlsDiffer() {
        #expect(MonitorControlGuide.liveCodes.contains(0x10))
        #expect(MonitorControlGuide.liveCodes.contains(0x16))
        for code in [0x60, 0xD6, 0xDC, 0x14, 0x04] { #expect(!MonitorControlGuide.liveCodes.contains(code)) }
        #expect(MonitorControlGuide.needsConfirmation(0x60))
        #expect(MonitorControlGuide.needsConfirmation(0xD6))
    }

    @Test("standard enum meanings do not invent a vendor mapping for unknown values")
    func enumMeaningIsQualified() {
        #expect(MonitorControlGuide.option(code: 0xDC, value: 3).contains("Movie"))
        #expect(MonitorControlGuide.option(code: 0xDC, value: 24).contains("Unmapped"))
        #expect(MonitorControlGuide.option(code: 0x60, value: 5).contains("Unmapped"))
        #expect(MonitorControlGuide.option(code: 0x60, value: 17).contains("HDMI 1"))
        #expect(MonitorControlGuide.ddc(0xDC, name: "displayApplication").effect.contains("content"))
    }

    @Test("unknown vendor diagnostics remain inspection-only with no invented effect")
    func unknownDiagnosticsStayUnknown() {
        let unknown = MonitorControlGuide.ddc(0xFD, name: "VCP 0xFD")
        #expect(unknown.effect.contains("Inspection only"))
        #expect(unknown.limits.contains("has not been established"))
        let reset = MonitorControlGuide.ddc(0x04, name: "restoreFactoryDefaults")
        #expect(reset.limits.contains("custom calibration"))
    }
    // Original live path used Int(raw), bypassing the strict capability parser.
    @Test("live readings reject invalid levels while preserving real enum quirks")
    func liveReadingsKeepCapabilityBounds() {
        let continuous = BetterDisplayDDCFeature(id: 0x10, name: "luminance", current: 50, maximum: 100, acceptedValues: [], readFailed: false, target: nil)
        for raw in ["-1", "+1", "65536", "0x64", "1.5", ""] { #expect(BetterDisplayDDCFeature.scalar(raw) == nil) }
        #expect(BetterDisplayDDCFeature.scalar(" 100\n") == 100)
        #expect(continuous.updatingCurrent(101).current == nil)
        #expect(continuous.updatingCurrent(101).readFailed)
        #expect(continuous.updatingCurrent(-1).readFailed)
        let preset = BetterDisplayDDCFeature(id: 0xDC, name: "displayApplication", current: 24, maximum: 3, acceptedValues: [0,2,3,5], readFailed: false, target: nil)
        #expect(preset.updatingCurrent(24).current == 24)
        #expect(!preset.updatingCurrent(24).readFailed)
    }

    // Observed on a real monitor: direct power GET echoed 24 after picture-mode reads and
    // 5 after input reads while the monitor was visibly on. Code 5 is write-only.
    @Test("power commands and echoed invalid replies never become a confirmed current state")
    func powerReadQuirkStaysUnknown() {
        let power = BetterDisplayDDCFeature(id: 0xD6, name: "powerMode", current: 1, maximum: 1, acceptedValues: [1,4,5], readFailed: false, target: nil)
        #expect(power.updatingCurrent(5).readFailed)
        #expect(power.updatingCurrent(24).current == nil)
        #expect(power.updatingCurrent(4).current == 4)
        let noEnum = BetterDisplayDDCFeature(id: 0xD6, name: "powerMode", current: 1, maximum: 1, acceptedValues: [], readFailed: false, target: nil)
        #expect(noEnum.updatingCurrent(4).current == 4)
        #expect(noEnum.updatingCurrent(5).current == nil)
        #expect(DisplayControlFeedback.readback(code: 0xD6, requested: 5, actual: 5).state == .unavailable)
    }

    // Original failure: a failed capability request produced zero reads, then a green
    // "last control read" timestamp on every poll after the cable changed.
    @Test("empty discovery and failed values never certify a hardware reading")
    func emptyReadsAreNotSuccessful() {
        let empty = DisplayControlReadHealth(values: [])
        #expect(!empty.hasReadings && empty.message != nil)
        let failed = DisplayControlReadHealth(values: [nil, nil])
        #expect(!failed.hasReadings && failed.message != nil)
        let partial = DisplayControlReadHealth(values: [100, nil])
        #expect(partial.hasReadings && partial.message != nil)
        let complete = DisplayControlReadHealth(values: [100, 75])
        #expect(complete.hasReadings && complete.message == nil)
    }

}
