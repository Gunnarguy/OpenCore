import Testing
@testable import CoreTelemetry

@Suite("BetterDisplayFeature")
struct BetterDisplayFeatureTests {
    // Selected lines from installed BetterDisplay 5.1.1 (53784) help, captured read-only.
    private let help = """
    - `ambientLight` - Returns the current ambient light level for the display when a supported sensor output method is available. Use with get. Pro feature. A contiguous range of values are accepted. Device (display) specific feature.
    - `hardwareBrightness` - Hardware brightness (DDC or Apple). Should only be used if auto-selection using `brightness` is not adequate. A contiguous range of values are accepted. Device (display) specific feature.
    - `hardwareBrightnessNits` - Current hardware brightness control level in nits according to current hardware and software brightness settings. A contiguous range of values are accepted. Device (display) specific feature. Information retrieval feature.
    - `ddc` - Sends a direct DDC command to the display. Requires a natively connected display with DDC enabled. Specify `set` and `get` for DDC write and read. Use the `vcp` parameter to specify the DDC control code. Use `value` to provide value for a `set` operation. Specific values must be provided. Device (display) specific feature.
    - `ddcAlt` - Sends a direct DDC command to the display using an alternate addressing (mostly used by some LG displays to control input source). Requires a natively connected display with DDC enabled. Use the `vcp` parameter to specify the DDC control code. Use `value` to provide value for a `set` or `feed` operation. Specific values must be provided. Device (display) specific feature.
    - `control` - Invokes a custom (or predefined) control by its CLI designation. Use the `specifier` parameter to specify the (custom) control name. Use `value` to provide value (if relevant) for a `set` operation. A contiguous range of values are accepted. Bool value (`on` or `off`) is accepted. No value must be specified. Device (display) specific feature.
    - `rotation` - Display rotation. Valid values are `0`, `90`, `180`, `270`. Works on display framebuffers with rotation support. Pro feature. Specific values must be provided. Device (display) specific feature.
    - `favoriteMode` - Set display mode to the one recorded in the specified favorite slot. Valid values are `1` to `5`. Pro feature. Specific values must be provided. Device (display) specific feature.
    - `moveTo` - Move display next to another display in the display layout using direction specifiers. A target display (relative to which the display is moved) must be specified. Specific values must be provided. No value must be specified. Device (display) specific feature. Pro feature. Available values: `topLeftCorner`, `topLeft`, `top`, `topRight`, `topRightCorner`, `leftTop`, `left`, `leftBottom`, `rightTop`, `right`, `rightBottom`, `bottomLeftCorner`, `bottomLeft`, `bottom`, `bottomRight`, `bottomRightCorner`.
    - `mirror` - Mirror display. One or more target display must be specified. Bool value (`on` or `off`) is accepted. Device (display) specific feature.
    - `framebufferBoolProperty` - Set a boolean framebuffer property. Use `specifier` to specify the framebuffer property name. Available on Apple silicon Macs only. Bool value (`on` or `off`) is accepted. Device (display) specific feature.
    - `displayInformation` - Gets the detailed display information report. Use with `get`. Provides the same text output as the Display Information export. Information retrieval feature. Device (display) specific feature.
    - `ddcCapabilities` - Explores DDC capabilities by parsing the DDC capabilities string and attempting to read supported commands. Use with `get`. Provides a brief report. Device (display) specific feature.
    - `darkMode` - Turns Dark Mode on or off. Pro feature. Bool value (`on` or `off`) is accepted. Not a device (display) specific feature.
    - `disconnectAllButMain` - Disconnects all displays except the current main display. Pro feature. No value must be specified. Not a device (display) specific feature.
    - `rotateBy` - Rotate image. Valid values are `0`, `90`, `180`, `270`. Used by the following: `stream`, `pip`, `contentStreamWindow`. Specific values must be provided. Pro feature.
    """

    private func feature(_ id: String) throws -> BetterDisplayFeature {
        try #require(BetterDisplayFeature.catalog(help).first { $0.id == id })
    }

    // Original bug: ambientLight was offered as writable because its contiguous-range
    // wording overrode the explicit get-only usage instruction.
    @Test("ambient light remains inspection-only despite its advertised contiguous range")
    func ambientLightIsReadOnly() throws {
        let ambient = try feature("ambientLight")
        #expect(ambient.isReadOnly && !ambient.offeredAsWrite)
        #expect(ambient.requiresValue)
        #expect(ambient.advertisedValues.isEmpty)
    }

    @Test("real brightness controls stay writable while brightness reports stay read-only")
    func brightnessControlsAndReportsDiffer() throws {
        let brightness = try feature("hardwareBrightness")
        #expect(!brightness.isReadOnly && brightness.offeredAsWrite && brightness.requiresValue)
        #expect(!(try feature("hardwareBrightnessNits")).offeredAsWrite)
    }

    @Test("direct DDC features require their dedicated validated controls")
    func directDDCIsDedicated() throws {
        for id in ["ddc", "ddcAlt"] {
            let direct = try feature(id)
            #expect(!direct.isReadOnly)
            #expect(BetterDisplayFeature.specialized.contains(direct.id))
            #expect(!direct.offeredAsWrite)
        }
    }

    @Test("controls needing specifiers or target displays remain inspection-only")
    func complexFeaturesNeedAdditionalContext() throws {
        for id in ["control", "moveTo", "mirror", "framebufferBoolProperty"] {
            let complex = try feature(id)
            #expect(complex.requiresAdditionalContext && !complex.offeredAsWrite)
        }
        let predefined = BetterDisplayFeature(id: "videoFilter", explanation: "Specific values must be provided.")
        #expect(predefined.requiresAdditionalContext && !predefined.offeredAsWrite)
    }

    @Test("explicit get-only clauses and retrieval documentation never expose writes")
    func readOnlyDocumentationControlsEligibility() throws {
        #expect((try feature("displayInformation")).isReadOnly)
        #expect((try feature("ddcCapabilities")).isReadOnly)
        for usage in ["Use with get.", "Use with `get`.", "Use with the `get` operation."] {
            let onlyGet = BetterDisplayFeature(id: "reading", explanation: "\(usage) A contiguous range of values are accepted.")
            #expect(onlyGet.isReadOnly && !onlyGet.offeredAsWrite)
        }
        for usage in ["Use with `set` and `get`.", "Use with get and set.", "Use with get. Use with perform."] {
            let both = BetterDisplayFeature(id: "setting", explanation: "\(usage) A contiguous range of values are accepted.")
            #expect(!both.isReadOnly && both.offeredAsWrite)
        }
    }

    @Test("global and operation-parameter entries stay outside the display feature catalog")
    func catalogExcludesGlobalAndParameterEntries() {
        let ids = Set(BetterDisplayFeature.catalog(help).map(\.id))
        #expect(ids.contains("hardwareBrightness") && ids.contains("rotation"))
        #expect(!ids.contains("darkMode") && !ids.contains("disconnectAllButMain") && !ids.contains("rotateBy"))
    }

    @Test("rotation stays writable with only the explicitly advertised angle choices")
    func rotationRetainsExactChoices() throws {
        let rotation = try feature("rotation")
        #expect(rotation.offeredAsWrite && !rotation.isReadOnly && rotation.requiresValue)
        #expect(rotation.advertisedValues == ["0", "90", "180", "270"])
        #expect((try feature("moveTo")).advertisedValues == ["topLeftCorner", "topLeft", "top", "topRight", "topRightCorner", "leftTop", "left", "leftBottom", "rightTop", "right", "rightBottom", "bottomLeftCorner", "bottomLeft", "bottom", "bottomRight", "bottomRightCorner"])
        #expect((try feature("favoriteMode")).advertisedValues.isEmpty)
    }

    @Test("enum lists reject unquoted mixed duplicate or incomplete value descriptions")
    func enumListsAreExplicitOnly() {
        for description in ["Valid values are `1` to `5`.", "Available values: `on`, off.",
                            "Available values: `on`, `on`.", "Available values: `on`, `off.",
                            "Available values: `on`,.", "Specific values must be provided."] {
            #expect(BetterDisplayFeature(id: "setting", explanation: description).advertisedValues.isEmpty)
        }
    }
}
