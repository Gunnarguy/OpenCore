import Testing
@testable import CoreTelemetry

struct DisplayModeIdentityTests {
    private func mode(_ id: Int32 = 1, refresh: Double = 59.94,
                      pixelWidth: Int = 3840, flags: UInt32 = 0) -> DisplayModeIdentity {
        DisplayModeIdentity(modeID: id, width: 1920, height: 1080,
                            pixelWidth: pixelWidth, pixelHeight: 2160,
                            refreshRate: refresh, ioFlags: flags, usableForDesktop: true)
    }

    // The original inventory deduplicated rounded labels, hiding Quartz choices
    // with different timing IDs, backing buffers or fractional refresh rates.
    @Test("modes that share a rounded label retain distinct exact identities")
    func distinctModesStayDistinct() {
        let original = mode()
        #expect(original.key != mode(2).key)
        #expect(original.key != mode(refresh: 59.94000001).key)
        #expect(original.key != mode(pixelWidth: 1920).key)
        #expect(original.key != mode(flags: 1).key)
        #expect(original == mode())
    }

    @Test("zero refresh remains distinguishable from a measured refresh")
    func zeroIsNotAnInventedSixtyHertz() {
        #expect(mode(refresh: 0).key != mode(refresh: 60).key)
        #expect(mode(refresh: 0).refreshRateBits == Double(0).bitPattern)
    }

    private func display(_ id: UInt32, serial: UInt32 = 0) -> DisplayConnectionIdentity {
        DisplayConnectionIdentity(displayID: id, vendorID: 100, productID: 200,
                                  serialNumber: serial, builtIn: false)
    }

    @Test("same-model displays without serials are ambiguous despite different runtime IDs")
    func missingSerialCannotIdentifyDuplicateMonitors() {
        let a = display(1), b = display(2)
        #expect(a.isUnambiguous(in: [a]))
        #expect(!a.isUnambiguous(in: [a, b]))
        #expect(!a.isUnambiguous(in: [b]))
    }

    @Test("a nonzero serial must identify exactly one connected display")
    func serialMustBeUniqueAndConnectionMustBeCurrent() {
        let a = display(1, serial: 50)
        #expect(a.isUnambiguous(in: [a, display(2, serial: 60)]))
        #expect(!a.isUnambiguous(in: [a, display(2, serial: 50)]))
        #expect(!a.isUnambiguous(in: [display(1, serial: 60)]))
        #expect(!a.isUnambiguous(in: [a, a]))
    }

    // Regression: rollback repeated the failed current-mode read after an initial
    // apply made a display inactive/unreadable, so retained originals were never tried.
    @Test("an unverified initial apply can restore retained modes without reading the failed mode")
    func unreadableInitialApplyStillHasRecovery() {
        let original = [display(1, serial: 50)]
        #expect(DisplayModeRollbackDecision.evaluate(
            originalConnections: original, liveConnections: original,
            previewWasVerified: false, currentMatchesPreview: nil,
            currentMatchesOriginal: nil) == .restore)
    }

    @Test("an established preview preserves unreadable or changed outside configurations")
    func establishedPreviewRequiresOutsideEditCheck() {
        let original = [display(1, serial: 50)]
        #expect(DisplayModeRollbackDecision.evaluate(
            originalConnections: original, liveConnections: original,
            previewWasVerified: true, currentMatchesPreview: nil,
            currentMatchesOriginal: nil) == .currentConfigurationUnavailable)
        #expect(DisplayModeRollbackDecision.evaluate(
            originalConnections: original, liveConnections: original,
            previewWasVerified: true, currentMatchesPreview: false,
            currentMatchesOriginal: false) == .changedOutsidePreview)
        #expect(DisplayModeRollbackDecision.evaluate(
            originalConnections: original, liveConnections: original,
            previewWasVerified: true, currentMatchesPreview: true,
            currentMatchesOriginal: false) == .restore)
        #expect(DisplayModeRollbackDecision.evaluate(
            originalConnections: original, liveConnections: original,
            previewWasVerified: true, currentMatchesPreview: false,
            currentMatchesOriginal: true) == .alreadyRestored)
    }

    @Test("initial recovery never permits a changed display connection")
    func recoveryDoesNotWeakenIdentityGuard() {
        let original = [display(1, serial: 50)]
        for verified in [false, true] {
            #expect(DisplayModeRollbackDecision.evaluate(
                originalConnections: original, liveConnections: [display(1, serial: 60)],
                previewWasVerified: verified, currentMatchesPreview: nil,
                currentMatchesOriginal: nil) == .connectionsChanged)
        }
    }

    // Regression: slow synchronous application/verification consumed the user’s
    // advertised 15 seconds before the confirmation controls became available.
    @Test("the confirmation period starts after verification regardless of apply latency")
    func previewLatencyDoesNotConsumeConfirmationTime() {
        let started = ContinuousClock.now
        let verified = started.advanced(by: .seconds(9))
        let window = DisplayModeConfirmationWindow(verifiedAt: verified, duration: .seconds(15))
        #expect(started.duration(to: window.deadline) == .seconds(24))
        #expect(window.remainingSeconds(at: verified) == 15)
        #expect(window.remainingSeconds(at: verified.advanced(by: .milliseconds(250))) == 15)
        #expect(window.remainingSeconds(at: verified.advanced(by: .seconds(14))) == 1)
        #expect(window.remainingSeconds(at: verified.advanced(by: .seconds(15))) == 0)
        #expect(window.remainingSeconds(at: verified.advanced(by: .seconds(16))) == 0)
    }
}
