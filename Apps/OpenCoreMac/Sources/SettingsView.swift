import AppKit
import CoreIngest
import CoreModel
import CorePresentation
import CoreSearch
import CoreStore
import CoreTelemetry
import FoundationModels
import SwiftUI

// MARK: - Full-Fidelity OpenCore Settings Control Center

struct SettingsView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var tab: Tab = .appearance

    /// The order here is the order on screen: what people change most, first.
    enum Tab: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case commandCenter = "Ask & AI"
        case phone = "iPhone"
        case connections = "Connections"
        case sync = "Sync"
        case retrieval = "Search"
        case hardware = "Hardware"
        case automation = "Computer Use"
        case security = "Privacy & Data"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .appearance: return "paintpalette.fill"
            case .commandCenter: return "sparkles.rectangle.stack.fill"
            case .hardware: return "cable.connector.horizontal"
            case .automation: return "gearshape.2.fill"
            case .retrieval: return "slider.horizontal.3"
            case .sync: return "arrow.triangle.2.circlepath"
            case .security: return "lock.shield.fill"
            case .phone: return "iphone"
            case .connections: return "powerplug"
            }
        }

        var accent: Color {
            switch self {
            case .appearance: return Pastel.lavender
            case .commandCenter: return Pastel.sky
            case .hardware: return Pastel.aqua
            case .automation: return Pastel.mint
            case .retrieval: return Pastel.butter
            case .sync: return Pastel.peach
            case .security: return Pastel.rose
            case .phone: return Pastel.aqua
            case .connections: return Pastel.sky
            }
        }
    }

    @State private var confirmingReset = false

    var body: some View {
        HStack(spacing: 0) {
            tabList
            Divider()
            // Connections fills the pane with lists of its own, which a scroll view would flatten.
            if tab == .connections {
                MCPView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scrollingTab
            }
        }
        .navigationTitle("Settings")
        .task(id: model.requestedSettingsTab) {
            if let requested = model.requestedSettingsTab {
                tab = requested
                model.requestedSettingsTab = nil
            }
        }
        .confirmationDialog("Reset appearance, layout and search settings?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) {
                settings.resetAppearanceAndLayout()
                settings.resetRetrieval()
                settings.resetChunking()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your data, connections and paired devices are not touched.")
        }
    }

    /// A list down the side shows every section at once. A sideways strip hid the last ones.
    private var tabList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.callout.weight(tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(tab == item ? item.accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer()
            Button("Reset to Defaults…") { confirmingReset = true }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, 10)
        }
        .padding(12)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
    }

    private var scrollingTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(tab.rawValue).font(.title2.weight(.semibold))

                switch tab {
                case .appearance:
                    AppearanceAndThemeTab()
                case .commandCenter:
                    CommandCenterAndAITab()
                case .hardware:
                    HardwareAndUSBSettingsTab()
                case .automation:
                    AutomationAndControlSettingsTab()
                case .retrieval:
                    RetrievalTab()
                case .sync:
                    SyncTab()
                case .security:
                    SecurityMCPAndDataTab()
                case .phone:
                    CompanionSettingsView()
                case .connections:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - TAB 1: Appearance, Pastel Colors & Liquid Glass

private struct AppearanceAndThemeTab: View {
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            // 1. Pastel Accent Swatch Grid
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Primary Pastel Accent Palette (11 Luminous macOS 27 Tokens)", systemImage: "swatchpalette.fill")
                        .font(.headline)
                        .foregroundStyle(settings.pastelAccent.color)
                    Spacer()
                    Text("Active: \(settings.pastelAccent.rawValue) · \(settings.pastelAccent.hexLabel)")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(settings.pastelAccent.color)
                }
                Text("Select your primary pastel accent color. Updates buttons, links, active tabs, and ambient card borders across all workspaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], spacing: 10) {
                    ForEach(AppSettings.PastelAccentChoice.allCases) { choice in
                        let isSelected = settings.pastelAccent == choice
                        Button {
                            settings.pastelAccent = choice
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: isSelected ? 2 : 0.5)
                                    }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(choice.rawValue)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text(choice.hexLabel)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(choice.color)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(choice.color)
                                }
                            }
                            .padding(10)
                            .background(isSelected ? choice.color.opacity(0.20) : Color.white.opacity(0.04), in: .rect(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isSelected ? choice.color : Color.white.opacity(0.10), lineWidth: isSelected ? 1.5 : 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: settings.pastelAccent.color)

            // 2. Liquid Glass Physics + Typography & Layout Density
            HStack(alignment: .top, spacing: 16) {
                // Left: Liquid Glass Surface Physics
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("macOS 27 Liquid Glass Surface Physics", systemImage: "sparkles.square.filled.on.square")
                            .font(.headline)
                            .foregroundStyle(Pastel.aqua)
                        Spacer()
                        Button("Reset Glass") {
                            settings.glassCardOpacity = 0.95
                            settings.glassBorderGlow = 0.48
                            settings.glassTintStrength = 0.12
                            settings.useNativeLiquidGlassBars = true
                            settings.appearanceMode = .dark
                        }
                        .controlSize(.mini)
                        .openCoreGlassButton()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Window Appearance Mode")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.ice)
                        Picker("Appearance", selection: $settings.appearanceMode) {
                            ForEach(AppSettings.AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Card Obsidian Base Opacity")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.0f%%", settings.glassCardOpacity * 100))
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.aqua)
                        }
                        Slider(value: $settings.glassCardOpacity, in: 0.72...0.99, step: 0.01)
                        Text("Higher values deepen the dark slate backing for maximum pastel text contrast.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pastel Specular Rim Glow")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.0f%%", settings.glassBorderGlow * 100))
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.lavender)
                        }
                        Slider(value: $settings.glassBorderGlow, in: 0.15...0.85, step: 0.02)
                        Text("Controls the brightness of the top-left to bottom-right pastel border highlight on cards.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Interior Pastel Gradient Wash")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.0f%%", settings.glassTintStrength * 100))
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.mint)
                        }
                        Slider(value: $settings.glassTintStrength, in: 0.02...0.30, step: 0.01)
                        Text("Controls how much pastel color washes across the top-left corner of tinted cards.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Use Native macOS 27 GlassEffectContainer on Navigation Bars", isOn: $settings.useNativeLiquidGlassBars)
                        .font(.caption.weight(.semibold))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.aqua)

                // Right: Typography, Layout Width & Truncation Controls
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Typography, Grid Density & Zero-Truncation Layout", systemImage: "textformat.size")
                            .font(.headline)
                            .foregroundStyle(Pastel.mint)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Application Font Scale (Dynamic Type)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.ice)
                        Picker("Font Scale", selection: $settings.fontScale) {
                            ForEach(AppSettings.FontScaleChoice.allCases) { scale in
                                Text(scale.rawValue).tag(scale)
                            }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Repository Fleet Card Grid Layout")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.sky)
                        Picker("Grid Layout", selection: $settings.fleetGridLayout) {
                            ForEach(AppSettings.FleetGridLayout.allCases) { layout in
                                Text(layout.rawValue).tag(layout)
                            }
                        }
                        .labelsHidden()
                        Text("Switch to '1-Column Full Width' if you want every repository card to span the entire window width.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Mac Overview Max Content Width")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Int(settings.commandCenterMaxWidth)) pt")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.mint)
                        }
                        Slider(value: $settings.commandCenterMaxWidth, in: 1120...2200, step: 40)
                        Text("Controls how wide Mac Overview expands on large displays.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Clamp Long Repository GOAL / NEXT / STOP Text (Off = Full Text, Zero '...')", isOn: $settings.truncateLongRepoText)
                        .font(.caption.weight(.semibold))

                    // Live Interactive Theme Preview Box
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("LIVE SURFACE & PASTEL CONTRAST PREVIEW")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(settings.pastelAccent.color)
                            Spacer()
                            Text("Contrast preview")
                                .openCorePastelBadge(Pastel.mint)
                        }
                        HStack(spacing: 8) {
                            Text("Sky").openCorePastelBadge(Pastel.sky)
                            Text("Mint").openCorePastelBadge(Pastel.mint)
                            Text("Lavender").openCorePastelBadge(Pastel.lavender)
                            Text("Peach").openCorePastelBadge(Pastel.peach)
                            Text("Butter").openCorePastelBadge(Pastel.butter)
                            Text("Rose").openCorePastelBadge(Pastel.rose)
                        }
                    }
                    .padding(12)
                    .openCoreGlassCard(cornerRadius: 10, tint: settings.pastelAccent.color)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
            }
        }
    }
}

// MARK: - TAB 2: Command Center, J.A.R.V.I.S. & Foundation Models

private struct CommandCenterAndAITab: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @AppStorage("sidebar.showEvidence") private var showDeveloper = false
    @State private var jarvis = JarvisController.shared

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                // Left: Command Center Deck Visibility
                VStack(alignment: .leading, spacing: 12) {
                    Label("Command Center Visible Decks & Panels", systemImage: "rectangle.grid.2x2.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.sky)
                    Text("Toggle which high-level telemetry and executive decks appear on the Command Center (⌘1).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Show J.A.R.V.I.S. Executive Command Deck at Top", isOn: $settings.showJarvisDeck)
                        .font(.callout)
                    Toggle("Show 4-Card Hardware, USB, Local Hub & Tailnet Telemetry Deck", isOn: $settings.showHardwareAndControlDeck)
                        .font(.callout)
                    Toggle("Show Coding Agents quick launch on Command Center", isOn: $settings.showCrossAgentHub)
                        .font(.callout)
                    Toggle("Show Visual Repository Fleet Matrix & Wrapping Repo Pills", isOn: $settings.showVisualFleetMatrix)
                        .font(.callout)
                    Toggle("Show Optional Unconfigured Connectors Banner", isOn: $settings.showOptionalConnectorsBanner)
                        .font(.callout)
                    Toggle("Show Workspace Launchers & Repository Fleet", isOn: $settings.showOperatorWorkspaces)
                        .font(.callout)

                    Divider()

                    Toggle("Expand Developer Tables in Left Sidebar (Claims, Beliefs, Passages, Receipts)", isOn: $showDeveloper)
                        .font(.callout)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Low Disk Space Warning Threshold (/System/Volumes/Data)")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Int(settings.lowDiskWarningThresholdGiB)) GiB")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.peach)
                        }
                        Slider(value: $settings.lowDiskWarningThresholdGiB, in: 10...100, step: 5)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)

                // Right: J.A.R.V.I.S. Voice & macOS 27 FoundationModels
                VStack(alignment: .leading, spacing: 14) {
                    Label("J.A.R.V.I.S. Neural Speech & macOS 27 FoundationModels", systemImage: "apple.intelligence")
                        .font(.headline)
                        .foregroundStyle(Pastel.lavender)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("J.A.R.V.I.S. Neural Voice Speech Rate (AVSpeechSynthesizer)")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.2f", settings.jarvisSpeechRate))
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.lavender)
                        }
                        Slider(value: $settings.jarvisSpeechRate, in: 0.38...0.62, step: 0.01)
                        HStack {
                            Toggle("Auto-Speak Executive Briefings When Ready", isOn: $settings.jarvisAutoSpeakBriefings)
                                .font(.caption)
                            Spacer()
                            Button {
                                jarvis.speak("OpenCore J.A.R.V.I.S. voice synthesis calibrated and ready.")
                            } label: {
                                Label("Test Voice", systemImage: "speaker.wave.2.fill")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(tint: Pastel.lavender)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Grounded Chat · Native FoundationModels Settings")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.aqua)

                        Picker("Reasoning Level (ContextOptions.ReasoningLevel):", selection: $settings.fmReasoningLevelRaw) {
                            Text("Light (Fastest)").tag("light")
                            Text("Moderate (Balanced)").tag("moderate")
                            Text("Deep (Maximum Reasoning)").tag("deep")
                        }
                        .font(.caption)

                        Toggle("Include JSON Schema in Prompt (includeSchemaInPrompt)", isOn: $settings.fmIncludeSchemaInPrompt)
                            .font(.caption)

                        Text("Applies to native Grounded Chat sessions. CLI briefings and model extraction use their own fixed options.")
                            .font(.caption2).foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text("Active Model: \(ComputerControlManager.shared.fmVariantName)")
                                .openCorePastelBadge(Pastel.mint)
                            Text("Context: \(ComputerControlManager.shared.fmContextSize) tok")
                                .openCorePastelBadge(Pastel.sky)
                            Text(ComputerControlManager.shared.pccAvailable ? "PCC Available" : "PCC Not Available")
                                .openCorePastelBadge(Pastel.lavender)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.lavender)
            }
        }
    }
}

// MARK: - TAB 3: Hardware, USB & Thunderbolt Settings

private struct HardwareAndUSBSettingsTab: View {
    @Environment(\.appModel) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appSettings) private var settings
    @ObservedObject private var usbManager = USBManager.shared

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("USB, Thunderbolt & Block-Storage Telemetry Settings", systemImage: "cable.connector.horizontal")
                        .font(.headline)
                        .foregroundStyle(Pastel.aqua)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("IOBlockStorageDriver Live Throughput Sampling Interval")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.1fs", settings.usbStoragePollingIntervalSec))
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Pastel.aqua)
                        }
                        Slider(value: $settings.usbStoragePollingIntervalSec, in: 0.5...5.0, step: 0.5)
                            .onChange(of: settings.usbStoragePollingIntervalSec) { _, interval in
                                usbManager.startLiveStorageMonitoring(interval: interval)
                            }
                        Text("Controls how frequently OpenCore samples read/write bytes/sec, IOPS, and latency for external USB/Thunderbolt drives.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Surface USB 3+ Link Bottlenecks in Reality Checks & Diffs", isOn: $settings.usbHighlightBottlenecks)
                        .font(.callout)

                    HStack(spacing: 10) {
                        Button {
                            usbManager.refreshAll()
                        } label: {
                            Label(usbManager.isScanning ? "Scanning Buses..." : "Rescan All Hardware Buses Now", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                        }
                        .openCoreGlassButton(prominent: true, tint: Pastel.aqua)

                        Button {
                            model.navigate(to: .hardwareUSB)
                            openWindow(id: "main", value: "workspace")
                        } label: {
                            Label("Open Full USB & macOS 27 Hardware Suite (⌘4)", systemImage: "arrow.up.forward.app")
                                .font(.caption.weight(.semibold))
                        }
                        .openCoreGlassButton(tint: Pastel.sky)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.aqua)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Live Hardware Bus Snapshot", systemImage: "cpu.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.mint)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Connected USB Devices:").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(usbManager.devices.count)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.sky)
                        }
                        GridRow {
                            Text("USB Host Controllers (xHCI):").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(usbManager.controllers.count)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.aqua)
                        }
                        GridRow {
                            Text("Thunderbolt Ports & Switches:").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(usbManager.thunderboltDevices.count)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.lavender)
                        }
                        GridRow {
                            Text("CoreHID / IOHIDManager Devices:").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(usbManager.hidDevices.count)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.mint)
                        }
                        GridRow {
                            Text("CoreAudio Peripherals:").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(usbManager.audioPeripherals.count)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.peach)
                        }
                        GridRow {
                            Text("AVFoundation Cameras:").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(usbManager.videoPeripherals.count)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.butter)
                        }
                    }
                }
                .padding(16)
                .frame(width: 420, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
            }
        }
    }
}

// MARK: - TAB 4: Local Automation Hub 0.3.5 & Computer Control Settings

private struct AutomationAndControlSettingsTab: View {
    @Environment(\.appModel) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appSettings) private var settings
    @State private var ctrl = ComputerControlManager.shared
    @State private var isConfirmingLiveDefault = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            // Top: Screen Vision & CGEvent Safety Lock
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Screen Vision & CGEvent Execution Safety", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.mint)
                    Toggle("Default to Dry-Run Safety Lock ON (Simulate clicks on reticle without sending macOS CGEvents)", isOn: Binding(
                        get: { settings.automationDefaultDryRun },
                        set: { keepDryRun in
                            if keepDryRun { settings.automationDefaultDryRun = true } else { isConfirmingLiveDefault = true }
                        }))
                        .font(.callout)
                        .alert(ComputerLiveArming.liveDefaultTitle, isPresented: $isConfirmingLiveDefault) {
                            Button("Keep Dry Run", role: .cancel) {}
                            Button("Start in Live Mode", role: .destructive) { settings.confirmLiveDefault() }
                        } message: {
                            Text(ComputerLiveArming.liveDefaultMessage)
                        }
                    if let notice = ctrl.launchNotice {
                        Text(notice).font(.caption).foregroundStyle(Pastel.butter)
                    }
                    Toggle("Show Vision OCR Bounding Boxes on Screen Canvas by Default", isOn: $settings.automationShowBoundingBoxes)
                        .font(.callout)
                }
                Spacer()
                Button {
                    model.navigate(to: .computerControl)
                    openWindow(id: "main", value: "workspace")
                } label: {
                    Label("Open Local Hub + Automation Studio (⌘5)", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.bold))
                }
                .openCoreGlassButton(prominent: true, tint: Pastel.mint)
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)

            LocalHubSettingsEditor()
        }
    }
}

// MARK: - TAB 5: Retrieval, Chunking & Knowledge Graph

private struct Tuned<Control: View>: View {
    let label: String
    let help: String
    let isDefault: Bool
    let defaultText: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.semibold))
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isDefault {
                Text("default \(defaultText)")
                    .openCorePastelBadge(Pastel.peach)
            }
            control
        }
        .padding(.vertical, 4)
    }
}

private struct RetrievalTab: View {
    @Environment(\.appSettings) private var settings

    static func text(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Hybrid Retrieval Fusion & MMR Ranking (RRF + BM25 + 512-d NLEmbedding)", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(Pastel.butter)
                    Spacer()
                    if !settings.retrievalIsDefault || !settings.chunkingIsDefault {
                        Button("Reset Retrieval & Chunking to Defaults") {
                            settings.resetRetrieval()
                            settings.resetChunking()
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(tint: Pastel.peach)
                    }
                }

                Tuned(label: "RRF k", help: "How fast rank advantage decays when fusing BM25 and vector legs.", isDefault: settings.rrfK == RetrievalTuning.default.rrfK, defaultText: Self.text(RetrievalTuning.default.rrfK, places: 0)) {
                    Stepper(value: $settings.rrfK, in: 1...200, step: 5) {
                        Text("\(Int(settings.rrfK))").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Tuned(label: "MMR λ", help: "Relevance versus diversity (0.85 measured default). At 1.0 diversification is off.", isDefault: settings.mmrLambda == RetrievalTuning.default.mmrLambda, defaultText: Self.text(RetrievalTuning.default.mmrLambda, places: 2)) {
                    Stepper(value: $settings.mmrLambda, in: 0.1...1.0, step: 0.05) {
                        Text(settings.mmrLambda.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Tuned(label: "Candidates per leg", help: "Results each retriever contributes before Reciprocal Rank Fusion.", isDefault: settings.candidatesPerLeg == RetrievalTuning.default.candidatesPerLeg, defaultText: "\(RetrievalTuning.default.candidatesPerLeg)") {
                    Stepper(value: $settings.candidatesPerLeg, in: 10...500, step: 10) {
                        Text("\(settings.candidatesPerLeg)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Tuned(label: "Signal scale", help: "How much authority and recency count once relevance is fused.", isDefault: settings.signalScale == RetrievalTuning.default.signalScale, defaultText: Self.text(RetrievalTuning.default.signalScale, places: 3)) {
                    Stepper(value: $settings.signalScale, in: 0...0.2, step: 0.005) {
                        Text(settings.signalScale.formatted(.number.precision(.fractionLength(3)))).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Tuned(label: "Passages returned", help: "Number of passages returned on the Passages screen.", isDefault: settings.passageLimit == 8, defaultText: "8") {
                    Stepper(value: $settings.passageLimit, in: 1...50) {
                        Text("\(settings.passageLimit)").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Expand hits into neighbouring passages", isOn: $settings.expandContext)
                    .font(.callout)
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.butter)

            VStack(alignment: .leading, spacing: 12) {
                Label("Passage Chunking (Floor Object Splitter)", systemImage: "scissors")
                    .font(.headline)
                    .foregroundStyle(Pastel.sky)

                Tuned(label: "Target chunk size (characters)", help: "Characters per passage, roughly four characters per token.", isDefault: settings.chunkTargetSize == AppSettings.defaultChunkTargetSize, defaultText: "1200") {
                    Stepper(value: $settings.chunkTargetSize, in: 200...4000, step: 100) {
                        Text("\(settings.chunkTargetSize)").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Tuned(label: "Chunk overlap (characters)", help: "Trailing context repeated into the next passage.", isDefault: settings.chunkOverlap == AppSettings.defaultChunkOverlap, defaultText: "150") {
                    Stepper(value: $settings.chunkOverlap, in: 0...800, step: 25) {
                        Text("\(settings.chunkOverlap)").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                if settings.chunkingDirty {
                    Label("Stored passages were built with different values. Re-derive on the Maintenance tab, then rebuild embeddings.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Pastel.peach)
                        .font(.callout)
                }
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
        }
    }
}

// MARK: - TAB 6: Sync, Cross-Agent Roots & LaunchAgent

private struct SyncTab: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var daemonInstalled = false
    @State private var daemonMessage: String?

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.gunnar.opencore.sync.plist")
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Hourly Background LaunchAgent (com.gunnar.opencore.sync)", systemImage: "clock.arrow.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(Pastel.peach)

                    HStack(spacing: 8) {
                        Image(systemName: daemonInstalled ? "checkmark.circle.fill" : "clock.badge.questionmark")
                            .foregroundStyle(daemonInstalled ? Pastel.mint : .secondary)
                        Text(daemonInstalled ? "Installed (hourly sync + 512-d embed)" : "Not currently installed")
                            .font(.callout.weight(.semibold))
                    }

                    HStack(spacing: 10) {
                        if daemonInstalled {
                            Button("Uninstall Background Agent") {
                                toggleDaemon(install: false)
                            }
                            .openCoreGlassButton(tint: Pastel.rose)
                        } else {
                            Button("Install Hourly Background Agent") {
                                toggleDaemon(install: true)
                            }
                            .openCoreGlassButton(prominent: true, tint: Pastel.mint)
                        }

                        Button {
                            Task { await model.syncAllWorkspaceAndSources() }
                        } label: {
                            Label("Sync All Sources Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .openCoreGlassButton(prominent: true, tint: Pastel.sky)
                    }

                    if let daemonMessage {
                        Text(daemonMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.peach)

                VStack(alignment: .leading, spacing: 12) {
                    Label("GitHub & Calendar Sync Windows", systemImage: "calendar.badge.clock")
                        .font(.headline)
                        .foregroundStyle(Pastel.sky)

                    Tuned(label: "Commits per repository", help: "How far back a full GitHub sync reads.", isDefault: settings.githubCommitsPerRepo == 100, defaultText: "100") {
                        Stepper(value: $settings.githubCommitsPerRepo, in: 10...1000, step: 10) {
                            Text("\(settings.githubCommitsPerRepo)").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    Toggle("Include forked repositories in GitHub sync", isOn: $settings.githubIncludeForks)
                        .font(.callout)
                    Toggle("Sync automatically while OpenCore is running", isOn: $settings.scheduledSyncEnabled)
                        .font(.callout)
                    Toggle("Include Apple Notes in automatic sync after you sync it once yourself (this opens Notes)", isOn: $settings.scheduledSyncIncludesNotes)
                        .font(.callout)
                        .disabled(!settings.scheduledSyncEnabled)

                    Tuned(label: "Calendar look-back (days)", help: "Days of past Calendar events to ingest.", isDefault: settings.calendarLookBackDays == 730, defaultText: "730") {
                        Stepper(value: $settings.calendarLookBackDays, in: 30...3650, step: 30) {
                            Text("\(settings.calendarLookBackDays)").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    Tuned(label: "Calendar look-ahead (days)", help: "Days of future Calendar events to ingest.", isDefault: settings.calendarLookAheadDays == 180, defaultText: "180") {
                        Stepper(value: $settings.calendarLookAheadDays, in: 0...730, step: 30) {
                            Text("\(settings.calendarLookAheadDays)").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
            }
        }
        .task {
            daemonInstalled = FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
        }
    }

    private func toggleDaemon(install: Bool) {
        let cliPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/opencore").path
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            daemonMessage = "Install the CLI at ~/.local/bin/opencore first."
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["daemon", install ? "install" : "uninstall"]
        do {
            try proc.run()
            proc.waitUntilExit()
            daemonInstalled = FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
            daemonMessage = nil
        } catch {
            daemonMessage = "\(error)"
        }
    }
}

// MARK: - TAB 7: Security, Credentials, MCP Firewall & Data Export

private struct SecurityMCPAndDataTab: View {
    @State private var confirmingUnsafeMCP = false
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var tokenField = ""
    @State private var status: Status = .unknown
    @State private var source: CredentialSource = .none
    @State private var saving = false
    @State private var verifying = false
    @State private var exporting = false
    @State private var outcome: String?

    enum Status: Equatable {
        case unknown, absent
        case present(login: String)
        case invalid(String)
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                // GitHub Credentials
                VStack(alignment: .leading, spacing: 12) {
                    Label("GitHub API Token & Keychain Precedence", systemImage: "key.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.mint)

                    StatusLine(status: status, source: source, busy: verifying)

                    SecureField("Token", text: $tokenField, prompt: Text("ghp_... or github_pat_..."))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await save() } }

                    HStack(spacing: 8) {
                        Button("Verify & Save to Keychain") { Task { await save() } }
                            .openCoreGlassButton(prominent: true, tint: Pastel.mint)
                            .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        if case .present = status {
                            Button("Clear Keychain Token") { Task { await clear() } }
                                .openCoreGlassButton(tint: Pastel.rose)
                                .disabled(saving)
                        }
                        Button("Re-check") { Task { await refresh() } }
                            .openCoreGlassButton()
                            .disabled(verifying)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)

                // Store & Export
                VStack(alignment: .leading, spacing: 12) {
                    Label("SQLite Store & Lossless Archival Export", systemImage: "internaldrive.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.sky)

                    if let path = model.storePath {
                        HStack {
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(Pastel.ice)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(tint: Pastel.sky)
                        }
                    }

                    Text("\(model.objectCount) floor objects · \(model.chunkCount) passages · \(model.entityCount) entities · \(model.claimCount) claims")
                        .font(.callout.monospaced().weight(.semibold))
                        .foregroundStyle(Pastel.aqua)

                    HStack(spacing: 10) {
                        ForEach(Exporter.Format.allCases, id: \.self) { format in
                            Button("Export \(format.rawValue.uppercased())") {
                                Task { await export(format) }
                            }
                            .openCoreGlassButton(prominent: format == .jsonl, tint: Pastel.sky)
                            .disabled(exporting)
                        }
                        if exporting { ProgressView().controlSize(.small) }
                    }
                    if let outcome {
                        Text(outcome).font(.caption).foregroundStyle(Pastel.mint)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
            }

            // Domain Firewall & MCP Server Config
            VStack(alignment: .leading, spacing: 12) {
                Label("Domain Firewall Admission Matrix & Outbound MCP Server", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(Pastel.rose)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    ForEach(Domain.allCases, id: \.self) { domain in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(domain.rawValue.uppercased())
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(domain.isSensitive ? Pastel.peach : Pastel.mint)
                                Spacer()
                                Text(domain.isSensitive ? "SENSITIVE FIREWALL" : "STANDARD")
                                    .openCorePastelBadge(domain.isSensitive ? Pastel.peach : Pastel.mint)
                            }
                            Text("May read: " + domain.readableDomains.map(\.rawValue).sorted().joined(separator: ", "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .openCoreGlassCard(cornerRadius: 10, tint: domain.isSensitive ? Pastel.peach : Pastel.mint)
                    }
                }

                Text(settings.mcpExposureSummary)
                    .font(.callout)
                if let message = settings.mcpExposureWriteResult?.failureDescription {
                    Text(message).font(.caption).foregroundStyle(Pastel.rose)
                }
                Text("Reconnect or restart MCP clients after saving. Existing servers keep their startup permissions. Remove any explicit --unsafe-expose-sensitive argument when blocking access; that argument overrides the shared setting.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Block sensitive MCP access") { settings.mcpExposeSensitiveDomains = false }
                    Button("Configure unsafe MCP access…") { confirmingUnsafeMCP = true }
                }
                .confirmationDialog("Expose sensitive and restricted memory to models?", isPresented: $confirmingUnsafeMCP, titleVisibility: .visible) {
                    Button("Enable unsafe MCP startup access", role: .destructive) { settings.mcpExposeSensitiveDomains = true }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This opens medical, financial, relationship and restricted mixed memory to MCP callers. A model is not you. The iPhone companion uses a separate owner channel and does not need this setting.")
                }

                MCPConfigSnippet()
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.rose)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        verifying = true
        defer { verifying = false }
        let resolved = await Task.detached {
            GitHubConnector.invalidateTokenCache()
            return GitHubConnector.resolveTokenWithSource()
        }.value
        source = resolved.source
        guard let token = resolved.token else {
            if resolved.source == .authenticationRequired || resolved.source == .storageError {
                status = .invalid(resolved.source.rawValue)
            } else {
                status = .absent
            }
            return
        }
        if let login = await GitHubConnector.verify(token: token) {
            status = .present(login: login)
        } else {
            status = .invalid("the token found via \(resolved.source.rawValue) was rejected")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let candidate = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard let login = await GitHubConnector.verify(token: candidate) else {
            status = .invalid("GitHub rejected that token. Check its scopes and expiry.")
            return
        }
        do {
            try Keychain.write(candidate, to: .githubToken, authentication: .allowInteraction)
            tokenField = ""
            status = .present(login: login)
            source = GitHubConnector.resolveTokenWithSource().source
        } catch { status = .invalid("\(error)") }
    }

    private func clear() async {
        do {
            try Keychain.delete(.githubToken, authentication: .allowInteraction)
            tokenField = ""
            await refresh()
        } catch { status = .invalid("\(error)") }
    }

    private func export(_ format: Exporter.Format) async {
        exporting = true
        defer { exporting = false }
        outcome = await model.exportStore(format: format)
    }
}

private struct StatusLine: View {
    let status: SecurityMCPAndDataTab.Status
    let source: CredentialSource
    let busy: Bool

    private var symbol: String {
        switch status {
        case .unknown: "hourglass"
        case .absent: "exclamationmark.triangle"
        case .present: "checkmark.circle.fill"
        case .invalid: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .unknown: .secondary
        case .absent: Pastel.peach
        case .present: Pastel.mint
        case .invalid: Pastel.rose
        }
    }

    private var message: String {
        switch status {
        case .unknown: "Checking GitHub token..."
        case .absent: "No GitHub token found"
        case .present(let login): "Authenticated as \(login) via \(source.rawValue)"
        case .invalid(let reason): reason
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).font(.callout.weight(.semibold))
            if busy { ProgressView().controlSize(.small) }
        }
    }
}

private struct MCPConfigSnippet: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var copied = false

    private var snippet: String? {
        AppSettings.mcpClientConfiguration(command: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/opencore").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snippet ?? "Client configuration could not be generated.")
                .font(.caption.monospaced())
                .foregroundStyle(Pastel.ice)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 8))
            HStack {
                Button(copied ? "Copied JSON" : "Copy MCP Config") {
                    guard settings.revalidateMCPStartupConfirmation(currentSharedSetting: SharedConfig.readMCPExposure()),
                          let snippet else {
                        if let message = settings.mcpExposureWriteResult?.failureDescription {
                            model.recordAuditFailure("MCP client configuration: " + message)
                        }
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                .disabled(settings.confirmedMCPExposure == nil || snippet == nil)
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.sky)
                Spacer()
            }
            Text(settings.confirmedMCPExposure == nil
                 ? "Confirm the shared startup preference before copying. Retry a failed save. This example contains no unsafe override."
                 : "This example uses the saved shared startup preference and contains no unsafe override.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { settings.observeInitialMCPStartupConfiguration(SharedConfig.readMCPExposure()) }
    }
}
