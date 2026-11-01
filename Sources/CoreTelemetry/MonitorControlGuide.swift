import Foundation

/// Human explanations are distinct from reported support. MCCS names describe the standard;
/// a vendor may implement different behavior. Choices always come from the actual capability list.
public struct MonitorControlGuide: Sendable {
    public let title: String
    public let purpose: String
    public let effect: String
    public let useWhen: String
    public let limits: String
    public static let liveCodes: Set<Int> = [0x10, 0x12, 0x16, 0x18, 0x1A, 0x62]
    public static func needsConfirmation(_ code: Int) -> Bool { code == 0x60 || code == 0xD6 }

    public static func ddc(_ code: Int, name: String) -> Self {
        switch code {
        case 0x10: return .init(title: "Hardware brightness", purpose: "Changes the monitor's own luminance control.", effect: "The panel's brightness changes for the selected input. This uses the monitor, rather than putting a dark overlay over the Mac picture.", useWhen: "Match the screen to the room or make two monitors similarly bright. Drag to adjust live; the reported value is read back beside the slider.", limits: "The device's 0-to-maximum scale is not a measurement in nits. Eco, dynamic contrast or picture modes can limit the adjustment.")
        case 0x12: return .init(title: "Hardware contrast", purpose: "Changes the monitor's separation between dark and bright signal levels.", effect: "Higher values can make the image punchier but may merge bright detail. It differs from turning up the backlight.", useWhen: "Tune a washed-out or harsh image while looking at a grayscale pattern. Smaller changes make clipping easier to spot.", limits: "Some presets lock contrast. Matching numeric values on different monitor models does not match their appearance.")
        case 0x16, 0x18, 0x1A:
            let color = code == 0x16 ? "Red" : code == 0x18 ? "Green" : "Blue"
            return .init(title: "\(color) hardware gain", purpose: "Adjusts the \(color.lowercased()) channel inside the monitor.", effect: "Changes white balance and the color of bright areas. These are hardware color settings, separate from a Mac color profile or software tint.", useWhen: "Balance a color cast with a neutral white/gray image or a calibration instrument. Record the starting values before making a larger correction.", limits: "A monitor color preset may lock or overwrite the gains. A readback match confirms the setting, not color accuracy.")
        case 0x14: return .init(title: "Monitor color temperature preset", purpose: "Selects a built-in white-balance/color preset.", effect: "A warmer preset usually looks more yellow/red; a cooler one more blue. User presets can expose stored RGB adjustments.", useWhen: "Choose an advertised preset before fine-tuning RGB gains. Standard labels below are MCCS meanings; the monitor may name its on-screen presets differently.", limits: "Only advertised codes can be selected. A reported current code outside that list is retained, without guessing which vendor mode it means.")
        case 0x60: return .init(title: "Monitor input", purpose: "Chooses which connected video source the monitor displays.", effect: "HDMI/DisplayPort selection happens inside the monitor. It can switch the screen from this Mac to another computer or an empty input.", useWhen: "Switch between devices connected to the monitor. Choose a reported input, then use Switch Input to send the command.", limits: "Switching away can remove both the Mac picture and the DDC control path. Use the monitor's physical input control to return if needed. Advertised input codes do not verify every physical socket or its maximum speed.")
        case 0xD6: return .init(title: "Monitor power", purpose: "Requests a power state from this monitor.", effect: "On/off applies to the screen, without shutting down the Mac. The off command and a reported off state use different standard codes.", useWhen: "Turn a spare screen off or request that it wake. Select the state, then use Change Power to send it.", limits: "Some screens stop answering DDC while off. An On request cannot wake a monitor whose connection no longer responds; use its physical power button. A maximum field of 1 does not limit the advertised enum choices to 1.")
        case 0xDC: return .init(title: "Picture mode (Display Application)", purpose: "Selects the monitor's intended picture-use preset, such as movie or games.", effect: "The monitor may change several processing, contrast and color settings together. 'Application' here means the type of content, rather than an app installed on your Mac.", useWhen: "Try an advertised movie/game/default preset, then compare the image and other control readings. OpenCore refreshes related hardware values afterward.", limits: "Labels are standard MCCS meanings, not verified on-screen names. Vendor codes or preset locks can differ. If readback disagrees, the result is shown as unconfirmed rather than successful.")
        case 0x62: return .init(title: "Monitor speaker volume", purpose: "Changes volume on the monitor's own supported audio hardware.", effect: "Adjusts the monitor's speaker control, which can differ from the Mac's output volume.", useWhen: "Control a screen with speakers and an active audio path.", limits: "A DDC feature does not prove speakers or an active audio route exist. A silent input will remain silent.")
        case 0x8D: return .init(title: "Monitor audio mute", purpose: "Requests the monitor's hardware mute state.", effect: "Mutes supported monitor audio; some implementations also use this control for blanking.", useWhen: "Mute a supported screen without changing the Mac's volume.", limits: "Behavior depends on the MCCS version and monitor. Use only its advertised values and compare the returned state.")
        case 0x02: return diagnostic("Monitor setting change flag", "Reports whether a monitor control has changed a saved setting.", "Useful when diagnosing whether the monitor's own controls changed something. It is a status flag, not brightness or a picture mode.")
        case 0x04: return diagnostic("Factory reset capability", "Advertises a command that can restore the monitor's factory settings.", "A read can fail because reset is an action, not a readable setting. OpenCore does not offer this as a live slider. Reset can discard custom calibration.")
        case 0x05: return diagnostic("Brightness/contrast reset capability", "Advertises restoration of the monitor's default brightness and contrast.", "This is an action rather than a level. It can overwrite your tuned picture values; a failed read does not prove the action is absent.")
        case 0x08: return diagnostic("Color reset capability", "Advertises restoration of the monitor's default color adjustments.", "Zero/zero is not a usable adjustment range. Resetting can discard a tuned white balance; inspect the monitor's own controls before using a reset.")
        case 0x52: return diagnostic("Active monitor control", "Identifies an active monitor-side control when implemented.", "Diagnostic metadata for on-screen controls. A failed read remains unavailable and has no substitute value.")
        case 0xAC: return diagnostic("Horizontal signal frequency", "Reports a horizontal scan-frequency field for the current incoming signal.", "It is timing information, not a refresh-rate control or a verified maximum. Failed/encoded fields remain raw.")
        case 0xAE: return diagnostic("Vertical signal frequency", "Reports a vertical timing-frequency field for the current incoming signal.", "Use the native current-mode and connection reports for an interpreted refresh rate. This field is not an editable panel maximum.")
        case 0xB2: return diagnostic("Panel subpixel layout", "Describes the arrangement of subpixels if the monitor reports it.", "This can help explain text rendering. It does not rearrange the panel, and unsupported values stay unknown.")
        case 0xB6: return diagnostic("Display technology", "Reports a standard device technology classification.", "This is a monitor descriptor, not a control for changing panel technology or an independent teardown result.")
        case 0xC6: return diagnostic("Application enable key", "A monitor protocol field used by control applications.", "It is unrelated to choosing a Mac application or the picture-use preset. It remains diagnostic here.")
        case 0xC8: return diagnostic("Display controller identifier", "Reports a monitor-side controller identifier.", "Useful for compatibility diagnostics. It is not a Mac USB controller or an editable performance level.")
        case 0xC9: return diagnostic("Monitor firmware field", "Reports the firmware version field exposed through DDC.", "The raw value is not necessarily a human version string. Reading it does not check for updates, extract firmware or install anything.")
        case 0xDF: return diagnostic("MCCS protocol version", "Reports the monitor control protocol version field.", "This helps interpret standard VCP commands. It is separate from monitor firmware, BetterDisplay version and supported refresh rates.")
        default: return diagnostic("\(humanTitle(name))", "A monitor-reported control or diagnostic field (VCP \(String(format: "0x%02X", code))).", "Its vendor-specific meaning has not been established. The raw response is preserved; OpenCore does not invent a writable range or a description of its effect.")
        }
    }

    private static func diagnostic(_ title: String, _ purpose: String, _ limits: String) -> Self {
        .init(title: title, purpose: purpose, effect: "Inspection only in OpenCore. This reading does not send a change to the monitor.", useWhen: "Inspect compatibility or diagnose a missing/locked control. Read failure means unavailable, rather than zero.", limits: limits)
    }

    public static func option(code: Int, value: Int) -> String {
        let label: String?
        switch code {
        case 0x60: label = [15:"DisplayPort 1",16:"DisplayPort 2",17:"HDMI 1",18:"HDMI 2"][value]
        case 0xD6: label = [1:"On",2:"Standby",3:"Suspend",4:"Off (reported power state)",5:"Turn off (command)"][value]
        case 0xDC: label = [0:"Standard / default",1:"Productivity",2:"Mixed content",3:"Movie",4:"User defined",5:"Games",6:"Sports",7:"Professional",8:"Standard · intermediate power",9:"Standard · low power",10:"Demonstration",240:"Dynamic contrast"][value]
        case 0x14: label = [1:"sRGB",2:"Display native",3:"4000 K",4:"5000 K",5:"6500 K",6:"7500 K",7:"8200 K",8:"9300 K",9:"10000 K",10:"11500 K",11:"User preset 1",12:"User preset 2",13:"User preset 3"][value]
        default: label = nil
        }
        let raw = "\(value) (\(String(format: "0x%02X", value)))"
        return label.map { "\($0) · \(raw)" } ?? "Unmapped value · \(raw)"
    }

    public static func provider(_ feature: BetterDisplayFeature) -> Self {
        let id = feature.id
        let title = humanTitle(id)
        let effect: String
        let use: String
        let limits: String
        if id.contains("EDID") {
            effect = "EDID describes identity, color and timing capabilities to macOS. A configured override can change what modes the Mac believes are available."
            use = "Inspect the original report before considering an override. Use an exact compatible descriptor, with a recovery path, for a specific compatibility problem."
            limits = "An override cannot add physical ports or bandwidth. Applying/resetting it can blank or reconfigure the display; it is separate from flashing firmware."
        } else if id.hasPrefix("protect") {
            effect = "Records/enforces an aspect of the current display setup so later changes can be reversed by BetterDisplay."
            use = "Keep a known layout, resolution, refresh, profile or orientation stable. Check these protections if another control appears to revert itself."
            limits = "Read its current value first. Protection can counteract changes made in OpenCore, macOS or another display utility."
        } else if ["rotation","placement","asMain","notch","connected","nativeSmoothScaling","hiDPI","resolution","refreshRate","colorDepth"].contains(id) {
            effect = "Changes how macOS arranges or drives the selected display. Rotation changes orientation; placement moves its desktop; main-display selection changes the primary screen."
            use = "Match a portrait monitor, align screens or choose the rendering/timing you need. Prefer the exact native mode preview for resolution and refresh rate."
            limits = "Support depends on the current connection and mode. Changes can move windows or blank a screen. Direct provider operations have no guaranteed automatic rollback."
        } else if id == "hdr" || id.lowercased().contains("xdr") || id.contains("Nits") {
            effect = "Addresses HDR/display luminance behavior or an Apple display preset. Hardware capability, the active signal mode and software tone mapping are separate factors."
            use = "Match HDR content or inspect a supported display preset. Compare the connection report and current mode before changing the setting."
            limits = "Software brightness/headroom does not create hardware HDR capability. Reported nits can be an estimate; these values are not instrument measurements."
        } else if id.lowercased().contains("hardware") || ["brightness","combinedBrightness","volume","mute"].contains(id) {
            effect = "Uses the configured display control method. Explicit hardware features address the monitor/Apple display control; combined brightness can mix hardware and software."
            use = "Use the dedicated hardware sliders for live DDC adjustment. Read this feature when choosing an Apple or provider-specific alternative."
            limits = "A catalog entry does not prove that this monitor supports the command. Hardware presets and disconnected/off states may restrict it."
        } else if id.lowercased().contains("profile") {
            effect = "Selects or manages a color profile used by the Mac to interpret/display colors. A profile differs from monitor RGB gains and picture presets."
            use = "Use an installed profile intended for this screen and current SDR/HDR state. Keep an existing calibrated profile available before changing it."
            limits = "A profile is not a measurement or calibration by itself. Exact URLs/slots must exist, and the active mode can affect availability."
        } else if feature.requiresAdditionalContext {
            effect = "Controls a configured controller, another target screen, stream, picture-in-picture window or named property. The feature needs more than a single value."
            use = "Read the exact installed description and use Open BetterDisplay to configure its target/controller."
            limits = "OpenCore keeps these context-dependent operations inspectable; it does not send an incomplete command to a guessed target."
        } else if ["gamma","rGamma","gGamma","bGamma","gain","rGain","gGain","bGain","temperature","contrast","softwareBrightness","saturation","hue","quantization"].contains(id) || id.hasPrefix("filter") || id == "gaussianBlur" {
            effect = "Transforms the image produced by the Mac using software color/gamma/filter controls. The panel's physical backlight and hardware calibration are separate settings."
            use = "Tune tint, tonal response, saturation or dimming beyond a hardware range. Read the current value and the installed format/range before applying."
            limits = "Some filters require a configured compositor or Pro. Stacking software and monitor adjustments can clip detail or double-apply a correction."
        } else {
            effect = feature.isReadOnly ? "Reads a provider report/value without modifying the monitor." : "Sends the specific installed BetterDisplay feature described below to this monitor."
            use = feature.isReadOnly ? "Use Read Current Value to check what this connection actually returns." : "Read the current value, review its required format and then apply a deliberate change."
            limits = "Availability depends on this monitor, controller, current mode and any Pro requirements. A successful request alone is not proof of a physical effect."
        }
        return .init(title: title, purpose: String(feature.explanation.split(separator:".",maxSplits:1).first ?? Substring(feature.explanation)) + ".", effect: effect, useWhen: use, limits: limits)
    }

    private static func humanTitle(_ text: String) -> String {
        text.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}
