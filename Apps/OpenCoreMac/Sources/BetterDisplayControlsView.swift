import AppKit
import CoreTelemetry
import SwiftUI

struct BetterDisplayControlsView: View {
    let display: ConnectedDisplay
    @StateObject private var store = BetterDisplayControlStore()
    @State private var featureID = ""
    @State private var featureSearch = ""
    @State private var featureScope = MonitorFeatureAvailability.Group.relevant
    @State private var featureInput = ""
    @State private var connectionID = ""
    @State private var confirmFeature = false
    @State private var confirmConnection = false
    @ObservedObject private var provider = BetterDisplayClient.shared
    @ObservedObject private var nativeModes = ConnectedDisplayModeController.shared

    private enum ControlSection: String, CaseIterable {
        case picture = "Picture", modes = "Resolution & Signal", connections = "Inputs & Power", advanced = "Advanced"
    }
    @State private var section = ControlSection.picture

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Label("Monitor controls", systemImage: "slider.horizontal.3").font(.headline)
                    liveRefreshActions
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Monitor controls", systemImage: "slider.horizontal.3").font(.headline)
                    liveRefreshActions
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ControlSection.allCases, id: \.self) { choice in
                        Button { section = choice } label: {
                            Text(choice.rawValue).fontWeight(section == choice ? .semibold : .regular)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(section == choice ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: Capsule())
                        }.buttonStyle(.plain).accessibilityValue(section == choice ? "Selected" : "Not selected")
                    }
                }
            }
            if store.isLoading { ProgressView(store.progress).font(.callout) }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if provider.hasUncertainMutation {
                Label("A change has no confirmed outcome. Further adjustments wait for BetterDisplay's reply; read-only refresh is available.", systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let snapshot = store.snapshot {
                if store.readingsStale {
                    Label("Updating control reports before another adjustment…", systemImage: "arrow.clockwise.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if snapshot.ddc.isEmpty && !display.builtIn {
                    videoConnectionSummary(snapshot)
                }
                switch section {
                case .picture:
                    if snapshot.ddc.contains(where: { BetterDisplayControlStore.writableDDC.contains($0.id) && !MonitorControlGuide.needsConfirmation($0.id) }) {
                        Text("Drag a slider to adjust the monitor. Preset choices apply immediately. Each card shows what the monitor actually reports.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    hardwareControls(snapshot, connections: false)
                case .modes:
                    ConnectedDisplayModeControlsView(display: display)
                    connectionControls(snapshot)
                    reportedSection("Current signal", rows: snapshot.section("Current Display Mode (Connection Level)"))
                    reportedSection("Connection details", rows: snapshot.section("Link Information"))
                case .connections:
                    Text("These actions affect the screen's power or selected video source. Each asks before sending because the Mac picture or control path can disappear.")
                        .font(.callout).foregroundStyle(.secondary)
                    hardwareControls(snapshot, connections: true)
                case .advanced:
                    featureWorkbench(snapshot)
                    reportedSection("Reported capabilities", rows: snapshot.section("Capabilities"))
                    reportedSection("Connection details", rows: snapshot.section("Link Information"))
                    diagnosticControls(snapshot)
                    reports(snapshot)
                    DisclosureGroup("Control provider & support") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.version)
                            Text("BetterDisplay must be running with notification integration enabled. Features retain their hardware, controller and Pro requirements. All commands use this monitor's matched identity.")
                            Text("Full reports inspected \(snapshot.captured.formatted(date: .omitted, time: .standard)) · \(snapshot.desktopModes.count) provider modes · \(snapshot.ddc.count) reported VCP features")
                            HStack {
                                Button("Open BetterDisplay") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/BetterDisplay.app")) }
                                Link("Control guide", destination: URL(string: "https://betterdisplay.pro/guide/integration/")!)
                            }
                        }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                    }
                }
                if let updated = store.lastLiveUpdate {
                    HStack(spacing: 6) {
                        Circle().fill(store.liveReadError == nil && !store.readingsStale && store.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text("Last successful hardware read \(updated.formatted(date: .omitted, time: .standard)) · \(store.autoRefresh ? "auto-refresh on" : "auto-refresh paused")")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.liveReadError { Text(error).font(.callout).foregroundStyle(.orange) }
            } else if section == .modes {
                ConnectedDisplayModeControlsView(display: display)
            }
        }
        .task(id: display.connectionIdentity) {
            await store.load(display)
            await store.monitor(display)
        }
        .onDisappear { store.stopLiveControls() }
        .onChange(of: section) { _, selected in
            store.cancelUnsentPictureEdits()
            store.watchFeature(selected == .advanced ? store.snapshot?.features.first(where: { $0.id == featureID }) : nil)
        }
    }

    private var liveRefreshActions: some View {
        HStack(spacing: 12) {
            Toggle("Live readings", isOn: $store.autoRefresh).toggleStyle(.switch)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load(display) } }
                .disabled(store.isLoading || store.isApplying || store.hasLiveWork)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func reportedSection(_ title: String, rows: [(String, String)]) -> some View {
        DisclosureGroup("\(title) · BetterDisplay report") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in DetailRow(label: row.0, value: row.1) }
                if rows.isEmpty { Text("Not returned by the current provider report.").foregroundStyle(.secondary) }
            }.padding(.top, 8)
        }
    }

    @ViewBuilder private func videoConnectionSummary(_ snapshot: BetterDisplaySnapshot) -> some View {
        let link = snapshot.section("Link Information")
        let signal = snapshot.section("Current Display Mode (Connection Level)")
        let connection = link.first(where: { $0.0 == "Connection type" })?.1
        let signalFields = ["Bit Depth", "Color Mode", "HDR/SDR Mode"]
        let summary = signal.filter { signalFields.contains($0.0) }.map(\.1).joined(separator: " · ")
        if connection != nil || !summary.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Video connection readable\(connection.map { " · \($0)" } ?? "")", systemImage: "cable.connector")
                    .font(.headline)
                if !summary.isEmpty { Text(summary).font(.callout).textSelection(.enabled) }
                Text("Video information is available independently from hardware capability reports and control readback.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Video link details") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(link.filter { ["Transmission mode", "Link rate", "Lane count", "Effective link bandwidth", "Display Stream Compression (DSC)"].contains($0.0) }.enumerated()), id: \.offset) { _, row in
                            HardwareDetailValueRow(value: row.1) {
                                Text(row.0 == "Effective link bandwidth" ? "Video link capacity" : row.0).foregroundStyle(.secondary)
                            }
                        }
                        Text("Link capacity describes the negotiated connection, not measured traffic. These are BetterDisplay’s link reports, not a complete list of the monitor’s physical ports.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).padding(.top, 8)
                }
                Text("Video report captured \(snapshot.captured.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func hardwareControls(_ snapshot: BetterDisplaySnapshot, connections: Bool) -> some View {
        let features = snapshot.ddc.filter {
            BetterDisplayControlStore.writableDDC.contains($0.id) && MonitorControlGuide.needsConfirmation($0.id) == connections
        }
        return VStack(alignment: .leading, spacing: 12) {
            if features.isEmpty {
                if display.builtIn {
                    ContentUnavailableView("This screen uses Apple display controls", systemImage: "laptopcomputer",
                        description: Text("Use macOS Display Settings for the built-in screen. Advanced also exposes the installed provider’s supported controls; external-monitor DDC is a separate path."))
                } else if !snapshot.ddc.isEmpty {
                    ContentUnavailableView(connections ? "No input or power controls reported" : "No picture controls reported", systemImage: "display",
                        description: Text("The monitor returned a capability report, but it did not advertise controls in this section. Other sections and Advanced retain the capabilities it did report."))
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !connections, let brightness = snapshot.features.first(where: { $0.id == "brightness" && $0.offeredAsWrite }) {
                        ProviderBrightnessControlView(display: display, feature: brightness, store: store)
                    }
                    Label("Hardware capability report unavailable", systemImage: "display.trianglebadge.exclamationmark")
                        .font(.headline)
                    Text("Your Mac can receive this monitor’s picture without being able to read its hardware controls. An empty discovery does not establish which controls the monitor supports.")
                    if let error = snapshot.errors["ddcCapabilities"] {
                        Text("Control discovery: \(error)").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("In BetterDisplay, select this screen under Settings → Displays → Device Control → DDC Control, then run Detect DDC Capabilities. If your monitor offers a DDC/CI option in its own menu, check that it is enabled.")
                    Text("Resolution & Signal still shows the display modes macOS can read. Advanced keeps the available reports and other provider controls.")
                        .foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { discoveryActions }
                        VStack(alignment: .leading) { discoveryActions }
                    }
                    Text("Discovery checked \(snapshot.captured.formatted(date: .omitted, time: .standard)). \(store.autoRefresh ? "An empty discovery retries every 30 seconds while this screen is open." : "Automatic discovery is paused.")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    controlGrid(features, columns: 2).frame(minWidth: 660)
                    controlGrid(features, columns: 1)
                }
            }
        }
    }

    @ViewBuilder private var discoveryActions: some View {
        Button("Retry control discovery", systemImage: "arrow.clockwise") { Task { await store.load(display) } }
            .disabled(store.isLoading || store.isApplying || store.hasLiveWork)
        Button("Open BetterDisplay") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/BetterDisplay.app")) }
        Link("DDC setup guide", destination: URL(string: "https://betterdisplay.pro/guide/interface-reference/settings/displays/display/device-control/ddc/")!)
    }

    private func controlGrid(_ features: [BetterDisplayDDCFeature], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: columns), alignment: .leading, spacing: 16) {
            ForEach(features, id: \.id) { feature in
                BetterDisplayDDCControlView(display: display, feature: feature, store: store)
            }
        }
    }

    private func diagnosticControls(_ snapshot: BetterDisplaySnapshot) -> some View {
        DisclosureGroup("Other monitor capabilities & diagnostics") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(snapshot.ddc.filter { !BetterDisplayControlStore.writableDDC.contains($0.id) }, id: \.id) { feature in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MonitorControlGuide.ddc(feature.id, name: feature.name).title).font(.headline)
                        MonitorControlExplanationView(guide: .ddc(feature.id, name: feature.name))
                        Text("Reported: \(feature.current.map(String.init) ?? "unavailable") · Maximum field: \(feature.maximum.map(String.init) ?? "unavailable") · \(String(format: "VCP 0x%02X", feature.id))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Divider()
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func connectionControls(_ snapshot: BetterDisplaySnapshot) -> some View {
        GroupBox("Signal format · supported connection modes") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only modes currently compatible with the active desktop/HDR state are selectable. Changing the signal can blank the screen. There is no guaranteed automatic rollback for this provider operation.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("What these signal settings change").font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bit depth: 8 bits per color channel provides 256 signal levels; 10 bits provides 1,024. More depth can reduce visible banding but requires a compatible mode and more bandwidth. It does not prove that the panel has native 10-bit pixels.")
                        Text("RGB / YCbCr and chroma: RGB sends separate red, green and blue values. YCbCr separates brightness from color. 4:4:4 retains full color detail; 4:2:2 or 4:2:0 reduces color detail to save bandwidth, which can soften desktop text and colored edges.")
                        Text("Full / limited range: these describe the signal's black-to-white code range. The monitor and Mac must interpret it the same way. A mismatch can make blacks gray or crush dark/bright detail; this differs from the brightness slider.")
                        Text("SDR / HDR: the transfer format and color handling must match the monitor, mode and content. A catalog HDR switch alone does not prove hardware support. Only currently compatible signal modes are selectable here.")
                    }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                }
                if snapshot.connectionModes.isEmpty {
                    Text("No compatible signal modes were returned for this connection.").foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.connectionModes, id: \.id) { option in
                            MonitorChoiceTile(title: option.label,
                                detail: option.isUnsafe ? "Reported unsafe · inspection only" : "Compatible with the current desktop / HDR configuration",
                                selected: connectionID == option.id) { connectionID = option.id }
                                .disabled(option.isUnsafe || controlsBusy)
                        }
                    }
                }.frame(height: 220)
                Button("Change Signal Mode…") { confirmConnection = true }
                    .disabled(!snapshot.connectionModes.contains(where: { $0.id == connectionID && !$0.isUnsafe }) || controlsBusy)
                if let feedback = store.signalFeedback { Text(feedback).font(.callout).textSelection(.enabled) }
            }.padding(.top, 8)
        }
        .confirmationDialog("Change the signal sent to \(display.title)? The display may go blank, and this operation has no guaranteed automatic rollback.", isPresented: $confirmConnection, titleVisibility: .visible) {
            Button("Apply to This Monitor") {
                guard let option = snapshot.connectionModes.first(where: { $0.id == connectionID }) else { return }
                Task { await store.setConnectionMode(option, display: display) }
            }
        }
    }

    private func featureWorkbench(_ snapshot: BetterDisplaySnapshot) -> some View {
        let choices = snapshot.features.filter {
            availability($0, snapshot: snapshot).group == featureScope &&
            (featureSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(featureSearch) || $0.explanation.localizedCaseInsensitiveContains(featureSearch))
        }
        let feature = snapshot.features.first { $0.id == featureID }
        return GroupBox("Advanced adjustments for \(display.title)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start with adjustments backed by this screen’s current capability report. Software changes affect the Mac’s image; hardware changes affect the monitor. Provider capability reports do not verify every command or physical result.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(MonitorFeatureAvailability.Group.allCases, id: \.self) { scope in
                            let count = snapshot.features.filter { availability($0, snapshot: snapshot).group == scope }.count
                            Button { featureScope = scope; featureID = ""; featureSearch = "" } label: {
                                Text("\(scope.rawValue) · \(count)").padding(8)
                                    .background(featureScope == scope ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06), in: Capsule())
                            }.buttonStyle(.plain).accessibilityValue(featureScope == scope ? "Selected" : "Not selected")
                        }
                    }
                }
                Text(scopeExplanation).font(.callout).foregroundStyle(.secondary)
                TextField("Search within \(featureScope.rawValue.lowercased())…", text: $featureSearch)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], alignment: .leading, spacing: 8) {
                        ForEach(choices) { option in
                            MonitorChoiceTile(title: Self.title(option.id),
                                detail: MonitorControlGuide.provider(option).purpose,
                                selected: featureID == option.id) { featureID = option.id }
                        }
                    }
                }.frame(height: 240)
                if choices.isEmpty {
                    Text(featureSearch.isEmpty ? "No controls have this availability on the current connection. Check Not confirmed for missing evidence, or Other tools for diagnostics and configuration." : "No controls match this search in the selected group.")
                        .foregroundStyle(.secondary)
                }
                if let feature {
                    Divider()
                    Text(Self.title(feature.id)).font(.title3).fontWeight(.semibold)
                    Text(availability(feature, snapshot: snapshot).reason).font(.callout).foregroundStyle(.secondary)
                    if !choices.contains(where: { $0.id == feature.id }) {
                        Text("This selection is now outside the visible group or search. Its last result remains here so you can inspect or retry it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    MonitorControlExplanationView(guide: .provider(feature))
                    DisclosureGroup("Exact installed feature description") {
                        Text(feature.explanation).font(.callout).textSelection(.enabled)
                    }
                    if feature.requiresValue || feature.isReadOnly {
                        Button("Read Current Value") { Task { await store.readFeature(feature, display: display) } }.disabled(store.isLoading || store.isApplying || store.hasLiveWork)
                    } else {
                        Text("This is an action, not a readable setting. No current-value check is used to decide whether its action can be offered.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.valueFeatureID == featureID, let value = store.featureValue {
                        Text("Current provider value: \(value)").font(.callout.monospaced()).textSelection(.enabled)
                    }
                    if store.featureFeedbackID == featureID, let feedback = store.featureFeedback { Text("Last change: \(feedback)").font(.callout).textSelection(.enabled) }
                    if store.valueFeatureID == featureID, let error = store.featureReadError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if feature.offeredAsWrite && availability(feature, snapshot: snapshot).group != .unavailable {
                        if feature.isBoolean {
                            Picker("Value", selection: $featureInput) { Text("On").tag("on"); Text("Off").tag("off") }.pickerStyle(.segmented)
                        } else if !feature.advertisedValues.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .top)], spacing: 8) {
                                ForEach(feature.advertisedValues, id: \.self) { option in
                                    MonitorChoiceTile(title: option, detail: "Value listed in installed provider help", selected: featureInput == option) { featureInput = option }
                                }
                            }
                        } else if feature.requiresValue {
                            TextField("Value in the format described above", text: $featureInput)
                        }
                        Button(feature.requiresValue ? "Apply Feature…" : "Perform Action…") { confirmFeature = true }
                            .disabled(controlsBusy || (feature.requiresValue && featureInput.isEmpty))
                        Text("This is a direct provider operation. Some actions alter power, orientation, calibration or stored configuration. They do not have a guaranteed rollback.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if availability(feature, snapshot: snapshot).group == .unavailable {
                        Text("Changes are unavailable here. Retry the read after reconnecting or correcting provider setup; a capability reported as No must change before this control is offered.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if BetterDisplayFeature.specialized.contains(feature.id) {
                        Text("Use the dedicated mode, signal or DDC controls above for this feature.").font(.caption).foregroundStyle(.secondary)
                    } else if feature.requiresAdditionalContext {
                        Text("This feature needs additional controller, target or property configuration. It remains inspectable here; use BetterDisplay's own configured controls to change it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 8)
        }
        .onChange(of: featureID) { _, id in
            featureInput = ""
            let selected = snapshot.features.first { $0.id == id }
            store.watchFeature(selected)
            if let selected, selected.requiresValue || selected.isReadOnly { Task { await store.readFeature(selected, display: display) } }
        }
        .confirmationDialog("Send \(feature.map { Self.title($0.id) } ?? "this action") to \(display.title)? Review the feature description. This can change or blank the monitor and may not be reversible automatically.", isPresented: $confirmFeature, titleVisibility: .visible) {
            if let feature, availability(feature, snapshot: snapshot).group != .unavailable {
                Button("Apply to This Monitor") { Task { await store.writeFeature(feature, value: featureInput, display: display) } }
            }
        }
    }

    private var scopeExplanation: String {
        switch featureScope {
        case .relevant: return "Reported capabilities match these controls. Select one to see its current provider value, purpose and limitations."
        case .unverified: return "Support is not established. A missing DDC report, saved provider value or catalog entry cannot prove hardware support. These stay out of the default list."
        case .unavailable: return "The provider explicitly reports a missing capability, or the last read failed. Failed reads can be temporary; no write controls are offered here."
        case .tools: return "Reports, protections, connection recovery and features requiring extra setup. Use these deliberately; they are separate from everyday monitor adjustment."
        }
    }

    private func availability(_ feature: BetterDisplayFeature, snapshot: BetterDisplaySnapshot) -> MonitorFeatureAvailability {
        let capabilities = Dictionary(snapshot.section("Capabilities"), uniquingKeysWith: { first, _ in first })
        return .evaluate(feature, capabilities: capabilities, ddcCodes: Set(snapshot.ddc.map(\.id)),
                         readFailed: store.failedFeatureReads.contains(feature.id))
    }

    private func reports(_ snapshot: BetterDisplaySnapshot) -> some View {
        DisclosureGroup("Complete provider reports & advertised inputs") {
            VStack(alignment: .leading, spacing: 10) {
                Text("The configured input-source list contains common/user-defined actions, not a detected physical port inventory. The DDC input-select values above are the monitor's advertised codes. EDID and connection reports add evidence; neither proves every socket's capabilities.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(snapshot.reports.keys.sorted(), id: \.self) { key in
                    DisclosureGroup(Self.title(key)) {
                        ScrollView([.horizontal, .vertical]) {
                            Text(snapshot.reports[key] ?? "").font(.caption.monospaced()).textSelection(.enabled).padding(8)
                        }.frame(maxHeight: 300)
                    }
                }
                ForEach(snapshot.errors.keys.sorted(), id: \.self) { key in
                    Text("\(Self.title(key)): \(snapshot.errors[key] ?? "Unavailable")").font(.callout).foregroundStyle(.orange)
                }
            }.padding(.top, 8)
        }
    }

    private var controlsBusy: Bool { store.isLoading || store.isApplying || store.hasLiveWork || store.readingsStale || provider.isMutating || nativeModes.pendingDisplayID != nil || nativeModes.isBusy }
    static func title(_ id: String) -> String {
        id.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}
