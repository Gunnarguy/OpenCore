import Foundation

/// Relevance from this connection's explicit capability report, never the global CLI catalog.
public struct MonitorFeatureAvailability: Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case relevant = "For this screen"
        case unverified = "Not confirmed"
        case unavailable = "Unavailable"
        case tools = "Other tools"
    }
    public let group: Group
    public let reason: String

    public static func evaluate(_ feature: BetterDisplayFeature, capabilities: [String: String],
                                ddcCodes: Set<Int>, readFailed: Bool = false) -> Self {
        if readFailed && (feature.requiresValue || feature.isReadOnly) { return .init(group: .unavailable, reason: "Last provider read failed on this connection. Retry is available; this is not proof of permanent incompatibility.") }
        let id = feature.id
        // Positive/negative values are exact provider fields. Missing/unrecognized values stay unknown.
        func capability(_ key: String, _ purpose: String) -> Self {
            switch capabilities[key]?.lowercased() {
            case "yes": return .init(group: .relevant, reason: "Provider reports \(purpose). A returned value is provider state, not proof of a physical effect.")
            case "no": return .init(group: .unavailable, reason: "Provider reports no \(purpose) for this connection.")
            default: return .init(group: .unverified, reason: "No explicit \(purpose) capability was returned.")
            }
        }
        // Check prerequisites before routing diagnostics/setup elsewhere, so unsupported Apple/HDR
        // definitions do not appear relevant just because the provider knows their names.
        if ["xdrPreset", "xdrPresetReset", "xdrPresetList"].contains(id) {
            let result = capability("Supports Apple Display Presets", "Apple Display Preset support")
            if result.group != .relevant || id == "xdrPreset" { return result }
        }
        if ["hdr", "protectHDR", "protectHDRProfile", "protectHDRColorMode"].contains(id) {
            let result = capability("Supports HDR", "HDR support")
            if result.group != .relevant || id == "hdr" { return result }
        }
        if id == "directBrightnessUpscaling" {
            return .init(group: .unverified, reason: "This provider feature requires a built-in XDR display. The generic HDR/upscaling flag does not establish that prerequisite.")
        }
        if id == "brightnessUpscaling" {
            return capability("XDR/HDR upscaling available", "XDR/HDR upscaling")
        }
        if feature.requiresAdditionalContext || BetterDisplayFeature.specialized.contains(id) ||
            feature.isReadOnly || !feature.offeredAsWrite || id.hasPrefix("protect") ||
            ["customEDID", "autoApplyCustomEDID", "applyCustomEDID", "applyFactoryEDID", "hardwareFactoryReset", "hardwarePowerOff", "xdrPresetReset", "reinitialize", "favoriteMode", "saveFavoriteMode", "connected"].contains(id) {
            return .init(group: .tools, reason: "Diagnostic, configuration, recovery or dedicated control. Kept outside everyday adjustments.")
        }
        let hardware: [String: Int] = ["hardwareBrightness": 0x10, "hardwareContrast": 0x12,
            "redHardwareGain": 0x16, "greenHardwareGain": 0x18, "blueHardwareGain": 0x1A,
            "redHardwareBlackLevel": 0x6C, "greenHardwareBlackLevel": 0x6E,
            "blueHardwareBlackLevel": 0x70, "volume": 0x62, "mute": 0x8D]
        if let code = hardware[id] {
            if id == "mute", ddcCodes.contains(0x62) {
                return .init(group: .relevant, reason: "Monitor advertises DDC volume control. BetterDisplay can mute through volume, optionally using a dedicated mute control.")
            }
            if ddcCodes.contains(code) { return .init(group: .relevant, reason: String(format: "Monitor advertises VCP 0x%02X. Current readback and physical behavior still need checking.", code)) }
            if id == "hardwareBrightness", capabilities["Hardware control (Apple)"] == "Yes" {
                return capability("Hardware control (Apple)", "Apple hardware brightness control")
            }
            return .init(group: .unverified, reason: "This hardware control was not advertised in the current DDC report. A missing report does not establish lack of support.")
        }
        if id == "rotation" { return capability("Supports changing orientation", "rotation support") }
        if ["colorProfileURL", "colorProfileReset"].contains(id) { return capability("Supports Color Profiles", "color profile support") }
        if id == "brightness" {
            if ddcCodes.contains(0x10) || capabilities["Hardware control (Apple)"] == "Yes" {
                return .init(group: .relevant, reason: "A hardware brightness route is advertised. BetterDisplay chooses its configured brightness method; this is not physical luminance verification.")
            }
            if capabilities["Software control"] == "Yes" { return capability("Software control", "software brightness control") }
            return .init(group: .unverified, reason: "No explicit brightness route is reported. Missing DDC discovery does not prove brightness cannot work.")
        }
        if id == "softwareBrightness" { return capability("Software control", "software brightness control") }
        if ["gain", "gamma", "rGamma", "gGamma", "bGamma", "rGain", "gGain", "bGain", "temperature", "quantization", "contrast", "resetColorAdjustments"].contains(id) {
            return capability("Color table alteration capable", "software color-table adjustment")
        }
        return .init(group: .unverified, reason: "This catalog definition has no explicit matching capability evidence yet. Software filters, sensors and hardware controls have different requirements.")
    }
}
