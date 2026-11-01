import Testing
@testable import CoreTelemetry

@Suite("Monitor feature availability")
struct MonitorFeatureAvailabilityTests {
    private func feature(_ id: String) -> BetterDisplayFeature {
        .init(id: id, explanation: "A contiguous range of values are accepted. Device (display) specific feature.")
    }

    // Regression: the global provider catalog put unsupported HDR/Apple controls beside usable ones.
    @Test("explicit missing capabilities exclude controls even when the catalog offers writes")
    func explicitNo() {
        for id in ["hdr", "xdrPreset", "brightnessUpscaling", "rotation"] {
            let caps = ["Supports HDR": "No", "Supports Apple Display Presets": "No",
                        "XDR/HDR upscaling available": "No", "Supports changing orientation": "No"]
            #expect(MonitorFeatureAvailability.evaluate(feature(id), capabilities: caps, ddcCodes: []).group == .unavailable)
        }
    }

    @Test("missing evidence stays unknown while matching capability reports are relevant")
    func unknownAndKnown() {
        #expect(MonitorFeatureAvailability.evaluate(feature("gamma"), capabilities: [:], ddcCodes: []).group == .unverified)
        #expect(MonitorFeatureAvailability.evaluate(feature("gamma"), capabilities: ["Color table alteration capable": "Yes"], ddcCodes: []).group == .relevant)
        #expect(MonitorFeatureAvailability.evaluate(feature("futureUnrecognizedControl"), capabilities: ["Software control": "Yes"], ddcCodes: []).group == .unverified)
    }

    @Test("generic provider hardware values do not replace a missing DDC capability")
    func hardwareEvidence() {
        #expect(MonitorFeatureAvailability.evaluate(feature("hardwareContrast"), capabilities: ["Potentially DDC compatible": "Yes"], ddcCodes: []).group == .unverified)
        #expect(MonitorFeatureAvailability.evaluate(feature("hardwareContrast"), capabilities: [:], ddcCodes: [0x12]).group == .relevant)
    }

    @Test("read failure removes a relevant control without declaring permanent incompatibility")
    func readFailure() {
        let result = MonitorFeatureAvailability.evaluate(feature("rotation"), capabilities: ["Supports changing orientation": "Yes"], ddcCodes: [], readFailed: true)
        #expect(result.group == .unavailable)
        #expect(result.reason.contains("Retry"))
    }

    @Test("configuration and reports stay outside everyday controls")
    func tools() {
        #expect(MonitorFeatureAvailability.evaluate(feature("hardwareFactoryReset"), capabilities: [:], ddcCodes: []).group == .tools)
        #expect(MonitorFeatureAvailability.evaluate(.init(id: "displayInformation", explanation: "Information retrieval feature."), capabilities: [:], ddcCodes: []).group == .tools)
    }
    // Regression: perform-only recovery actions reject GET; that cannot disqualify their action.
    @Test("write-only actions are not disabled by a failed value read")
    func performOnly() {
        let action = BetterDisplayFeature(id: "reinitialize", explanation: "No value must be specified. Device (display) specific feature.")
        #expect(MonitorFeatureAvailability.evaluate(action, capabilities: [:], ddcCodes: [], readFailed: true).group == .tools)
    }

    @Test("automatic brightness remains relevant when only a hardware route is reported")
    func hardwareOnlyBrightness() {
        #expect(MonitorFeatureAvailability.evaluate(feature("brightness"), capabilities: ["Software control": "No"], ddcCodes: [0x10]).group == .relevant)
        #expect(MonitorFeatureAvailability.evaluate(feature("brightness"), capabilities: ["Hardware control (Apple)": "Yes"], ddcCodes: []).group == .relevant)
        #expect(MonitorFeatureAvailability.evaluate(feature("brightness"), capabilities: ["Software control": "No"], ddcCodes: []).group == .unverified)
    }

    @Test("mute can use advertised volume without a dedicated mute code")
    func volumeMute() {
        #expect(MonitorFeatureAvailability.evaluate(feature("mute"), capabilities: [:], ddcCodes: [0x62]).group == .relevant)
        #expect(MonitorFeatureAvailability.evaluate(feature("mute"), capabilities: [:], ddcCodes: [0x8D]).group == .relevant)
        #expect(MonitorFeatureAvailability.evaluate(feature("mute"), capabilities: [:], ddcCodes: []).group == .unverified)
    }

    @Test("generic HDR upscaling does not qualify a built-in XDR-only feature")
    func directUpscaling() {
        #expect(MonitorFeatureAvailability.evaluate(feature("directBrightnessUpscaling"), capabilities: ["XDR/HDR upscaling available": "Yes"], ddcCodes: []).group == .unverified)
    }

}
