#if os(macOS)
import AppKit
import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Observation
import SwiftUI

/// App preferences, in `UserDefaults`.
///
/// Deliberately **not** in the SQLite store. That file is the user's data — objects, claims,
/// receipts — and it is the thing they export, back up, and hand to another machine.
@MainActor
@Observable
public final class AppSettings {
    @MainActor
    public struct Effects {
        let scheduledSyncChanged: () -> Void
        let returnToDryRun: () -> Void
        let mcpExposureChanged: (Bool) -> SharedConfig.MCPExposureWriteResult?

        public init(scheduledSyncChanged: @escaping () -> Void,
                    returnToDryRun: @escaping () -> Void,
                    mcpExposureChanged: @escaping (Bool) -> SharedConfig.MCPExposureWriteResult?) {
            self.scheduledSyncChanged = scheduledSyncChanged
            self.returnToDryRun = returnToDryRun
            self.mcpExposureChanged = mcpExposureChanged
        }

        public static var isolated: Effects {
            Effects(scheduledSyncChanged: {}, returnToDryRun: {}, mcpExposureChanged: { _ in nil })
        }
    }

    @ObservationIgnored private let effects: Effects

    // MARK: - 1. Appearance, Pastel Theme & Liquid Glass

    public enum AppearanceMode: String, CaseIterable, Identifiable {
        case dark = "Dark Obsidian (Recommended)"
        case system = "System Automatic"
        case light = "Light Frost"
        public var id: String { rawValue }

        public var colorScheme: ColorScheme? {
            switch self {
            case .dark: return .dark
            case .system: return nil
            case .light: return .light
            }
        }
    }

    public enum PastelAccentChoice: String, CaseIterable, Identifiable {
        case sky = "Sky Blue"
        case aqua = "Aqua Cyan"
        case mint = "Mint Green"
        case sage = "Sage"
        case lavender = "Lavender"
        case periwinkle = "Periwinkle"
        case lilac = "Lilac"
        case peach = "Peach"
        case butter = "Butter Yellow"
        case rose = "Coral Rose"
        case ice = "Ice Silver"

        public var id: String { rawValue }

        public var color: Color {
            switch self {
            case .sky: return Pastel.sky
            case .aqua: return Pastel.aqua
            case .mint: return Pastel.mint
            case .sage: return Pastel.sage
            case .lavender: return Pastel.lavender
            case .periwinkle: return Pastel.periwinkle
            case .lilac: return Pastel.lilac
            case .peach: return Pastel.peach
            case .butter: return Pastel.butter
            case .rose: return Pastel.rose
            case .ice: return Pastel.ice
            }
        }

        public var hexLabel: String {
            switch self {
            case .sky: return "#8FD4FF"
            case .aqua: return "#85EBF5"
            case .mint: return "#85F0C7"
            case .sage: return "#A3F2AA"
            case .lavender: return "#CCB8FF"
            case .periwinkle: return "#ADC2FF"
            case .lilac: return "#EBB3FA"
            case .peach: return "#FFC78C"
            case .butter: return "#FFE88F"
            case .rose: return "#FFA6B8"
            case .ice: return "#E2E8F0"
            }
        }
    }

    public enum FleetGridLayout: String, CaseIterable, Identifiable {
        case twoColumn = "2-Column Adaptive (460pt min)"
        case singleColumn = "1-Column Full Width (Maximum Legibility)"
        case threeColumn = "3-Column Compact (360pt min)"

        public var id: String { rawValue }

        public var minCardWidth: CGFloat {
            switch self {
            case .twoColumn: return 460
            case .singleColumn: return 980
            case .threeColumn: return 360
            }
        }
    }

    public enum FontScaleChoice: String, CaseIterable, Identifiable {
        case compact = "Compact"
        case standard = "Standard (Default)"
        case comfortable = "Comfortable (+Large)"
        case accessibility = "Extra Large (+XXLarge)"

        public var id: String { rawValue }

        public var dynamicTypeSize: DynamicTypeSize {
            switch self {
            case .compact: return .small
            case .standard: return .medium
            case .comfortable: return .xLarge
            case .accessibility: return .xxxLarge
            }
        }
    }

    public var appearanceModeRaw: String {
        didSet {
            save(appearanceModeRaw, "ui.appearanceMode")
            applyAppearanceToNSApp()
        }
    }
    public var pastelAccentRaw: String { didSet { save(pastelAccentRaw, "ui.pastelAccent") } }
    public var glassCardOpacity: Double { didSet { save(glassCardOpacity, "ui.glassCardOpacity") } }
    public var glassBorderGlow: Double { didSet { save(glassBorderGlow, "ui.glassBorderGlow") } }
    public var glassTintStrength: Double { didSet { save(glassTintStrength, "ui.glassTintStrength") } }
    public var useNativeLiquidGlassBars: Bool { didSet { save(useNativeLiquidGlassBars, "ui.useNativeLiquidGlassBars") } }
    public var fontScaleRaw: String { didSet { save(fontScaleRaw, "ui.fontScale") } }
    public var commandCenterMaxWidth: Double { didSet { save(commandCenterMaxWidth, "ui.commandCenterMaxWidth") } }
    public var fleetGridLayoutRaw: String { didSet { save(fleetGridLayoutRaw, "ui.fleetGridLayout") } }
    public var truncateLongRepoText: Bool { didSet { save(truncateLongRepoText, "ui.truncateLongRepoText") } }

    public var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .dark }
        set { appearanceModeRaw = newValue.rawValue }
    }

    /// True when the active theme is Light Frost (or System Automatic while macOS is in Light Mode).
    public var isEffectiveLightMode: Bool {
        switch appearanceMode {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .aqua
        }
    }

    public func toggleLightDarkMode() {
        if isEffectiveLightMode {
            appearanceMode = .dark
        } else {
            appearanceMode = .light
        }
    }

    public func applyAppearanceToNSApp() {
        guard let app = NSApp else { return }
        switch appearanceMode {
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .system:
            app.appearance = nil
        }
    }

    public var pastelAccent: PastelAccentChoice {
        get { PastelAccentChoice(rawValue: pastelAccentRaw) ?? .sky }
        set { pastelAccentRaw = newValue.rawValue }
    }

    public var fleetGridLayout: FleetGridLayout {
        get { FleetGridLayout(rawValue: fleetGridLayoutRaw) ?? .twoColumn }
        set { fleetGridLayoutRaw = newValue.rawValue }
    }

    public var fontScale: FontScaleChoice {
        get { FontScaleChoice(rawValue: fontScaleRaw) ?? .standard }
        set { fontScaleRaw = newValue.rawValue }
    }

    // MARK: - 2. Command Center Decks, J.A.R.V.I.S. & Foundation Models

    public var showJarvisDeck: Bool { didSet { save(showJarvisDeck, "cc.home2.showJarvisDeck") } }
    public var showHardwareAndControlDeck: Bool { didSet { save(showHardwareAndControlDeck, "cc.home2.showHardwareDeck") } }
    public var showCrossAgentHub: Bool { didSet { save(showCrossAgentHub, "cc.home2.showCrossAgentHub") } }
    public var showVisualFleetMatrix: Bool { didSet { save(showVisualFleetMatrix, "cc.home2.showVisualFleetMatrix") } }
    public var showOptionalConnectorsBanner: Bool { didSet { save(showOptionalConnectorsBanner, "cc.showConnectorsBanner") } }
    public var showOperatorWorkspaces: Bool { didSet { save(showOperatorWorkspaces, "cc.home2.showOperatorWorkspaces") } }

    /// Keep the store fresh while the app runs. See `SyncSchedule`.
    public var scheduledSyncEnabled: Bool { didSet { save(scheduledSyncEnabled, "sync.scheduled"); effects.scheduledSyncChanged() } }
    /// Separate, because reading Notes starts Notes.
    public var scheduledSyncIncludesNotes: Bool { didSet { save(scheduledSyncIncludesNotes, "sync.scheduledNotes") } }

    public var jarvisSpeechRate: Double { didSet { save(jarvisSpeechRate, "jarvis.speechRate") } }
    public var jarvisAutoSpeakBriefings: Bool { didSet { save(jarvisAutoSpeakBriefings, "jarvis.autoSpeak") } }
    public var fmReasoningLevelRaw: String { didSet { save(fmReasoningLevelRaw, "fm.reasoningLevel") } }
    public var fmIncludeSchemaInPrompt: Bool { didSet { save(fmIncludeSchemaInPrompt, "fm.includeSchema") } }
    public var lowDiskWarningThresholdGiB: Double { didSet { save(lowDiskWarningThresholdGiB, "guard.lowDiskGiB") } }

    // MARK: - 3. Hardware, USB & Automation Preferences

    public var usbStoragePollingIntervalSec: Double { didSet { save(usbStoragePollingIntervalSec, "usb.pollingInterval") } }
    public var usbHighlightBottlenecks: Bool { didSet { save(usbHighlightBottlenecks, "usb.highlightBottlenecks") } }
    public var automationDefaultDryRun: Bool {
        didSet {
            save(automationDefaultDryRun, "automation.defaultDryRun")
            // Only the safe direction takes effect at once. Starting live is `confirmLiveDefault()`,
            // and it applies from the next launch.
            if automationDefaultDryRun {
                automationLiveDefaultConfirmed = false
                effects.returnToDryRun()
            }
        }
    }
    /// Set only by the confirmation dialog, so a bare stored `false` above can't start the app live.
    public private(set) var automationLiveDefaultConfirmed: Bool {
        didSet { save(automationLiveDefaultConfirmed, "automation.liveDefaultConfirmed") }
    }

    public func confirmLiveDefault() {
        automationLiveDefaultConfirmed = true
        automationDefaultDryRun = false
    }

    public var automationShowBoundingBoxes: Bool { didSet { save(automationShowBoundingBoxes, "automation.showBoundingBoxes") } }

    // MARK: - 4. Retrieval

    public var rrfK: Double { didSet { save(rrfK, "retrieval.rrfK") } }
    public var mmrLambda: Double { didSet { save(mmrLambda, "retrieval.mmrLambda") } }
    public var candidatesPerLeg: Int { didSet { save(candidatesPerLeg, "retrieval.candidatesPerLeg") } }
    public var signalScale: Double { didSet { save(signalScale, "retrieval.signalScale") } }
    public var passageLimit: Int { didSet { save(passageLimit, "retrieval.passageLimit") } }
    public var expandContext: Bool { didSet { save(expandContext, "retrieval.expandContext") } }

    public var tuning: RetrievalTuning {
        var tuning = RetrievalTuning.default
        tuning.rrfK = rrfK
        tuning.mmrLambda = mmrLambda
        tuning.candidatesPerLeg = candidatesPerLeg
        tuning.signalScale = signalScale
        return tuning
    }

    // MARK: - 5. Chunking

    public var chunkTargetSize: Int { didSet { save(chunkTargetSize, "chunking.targetSize"); markChunkingDirty() } }
    public var chunkOverlap: Int { didSet { save(chunkOverlap, "chunking.overlap"); markChunkingDirty() } }

    private func markChunkingDirty() { chunkingDirty = true }

    public var chunker: Chunker { Chunker(targetSize: chunkTargetSize, overlap: chunkOverlap) }

    public var chunkingDirty: Bool { didSet { save(chunkingDirty, "chunking.dirty") } }

    // MARK: - 6. Sync

    public var githubCommitsPerRepo: Int { didSet { save(githubCommitsPerRepo, "sync.githubCommits") } }
    public var githubIncludeForks: Bool { didSet { save(githubIncludeForks, "sync.githubForks") } }
    public var calendarLookBackDays: Int { didSet { save(calendarLookBackDays, "sync.calendarBack") } }
    public var calendarLookAheadDays: Int { didSet { save(calendarLookAheadDays, "sync.calendarAhead") } }

    // MARK: - 7. MCP server

    public var mcpExposeSensitiveDomains: Bool {
        didSet {
            save(mcpExposeSensitiveDomains, "mcp.exposeSensitive")
            initialMCPExposureObservation = nil
            mcpExposureRequestedInSession = true
            let result = effects.mcpExposureChanged(mcpExposeSensitiveDomains)
            if case .confirmed(let observed) = result, observed != mcpExposeSensitiveDomains {
                mcpExposureWriteResult = .unconfirmed("Readback did not match the requested startup preference.")
            } else {
                mcpExposureWriteResult = result
            }
        }
    }

    /// Requested local preferences are not proof of shared configuration or running permissions.
    public private(set) var mcpExposureWriteResult: SharedConfig.MCPExposureWriteResult?
    private var initialMCPExposureObservation: Bool?
    @ObservationIgnored private var initialMCPExposureObservationAttempted = false
    @ObservationIgnored private var mcpExposureRequestedInSession = false
    public var confirmedMCPExposure: Bool? {
        switch mcpExposureWriteResult {
        case .confirmed(let enabled): return enabled
        case nil: return initialMCPExposureObservation
        default: return nil
        }
    }
    public var mcpExposureSummary: String {
        switch mcpExposureWriteResult {
        case .confirmed(true): "Last confirmed MCP startup save enabled sensitive and restricted memory."
        case .confirmed(false): "Last confirmed MCP startup save blocked sensitive and restricted memory."
        case .notWritten: "The save was not attempted. Shared MCP configuration remains unverified."
        case .unconfirmed: "The save was not confirmed. The file may already contain the change."
        case nil:
            if let observed = initialMCPExposureObservation {
                observed ? "Last observed shared MCP startup preference enables sensitive and restricted memory."
                    : "Last observed shared MCP startup preference blocks sensitive and restricted memory."
            } else {
                "Shared MCP configuration has not been verified in this session."
            }
        }
    }

    /// The production boundary may restore existing shared authorization from a strict read.
    /// This performs no I/O/callbacks and cannot replace a failed or attempted preference change.
    public func observeInitialMCPStartupConfiguration(_ observed: Bool?) {
        guard !mcpExposureRequestedInSession, mcpExposureWriteResult == nil,
              !initialMCPExposureObservationAttempted else { return }
        initialMCPExposureObservationAttempted = true
        initialMCPExposureObservation = observed
    }

    /// Cached write confirmation is insufficient if another writer changed or removed the file.
    /// A matching read cannot authorize an unconfirmed request; it only revalidates a prior save.
    public func revalidateMCPStartupConfirmation(currentSharedSetting: Bool?) -> Bool {
        guard let confirmed = confirmedMCPExposure else { return false }
        guard currentSharedSetting == confirmed else {
            mcpExposureWriteResult = .unconfirmed("The shared startup setting changed or could not be read. Save the requested preference again.")
            return false
        }
        return true
    }

    /// Shared configuration controls startup. Never bake an unsafe override into generated clients.
    public static func mcpClientConfiguration(command: String) -> String? {
        let document = ["mcpServers": ["opencore": ["command": command, "args": ["mcp"]] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Defaults & Resets

    public static let defaultChunkTargetSize = 1200
    public static let defaultChunkOverlap = 150

    public var retrievalIsDefault: Bool {
        tuning.isDefault && passageLimit == 8 && expandContext
    }

    public var chunkingIsDefault: Bool {
        chunkTargetSize == Self.defaultChunkTargetSize && chunkOverlap == Self.defaultChunkOverlap
    }

    public func resetRetrieval() {
        let base = RetrievalTuning.default
        rrfK = base.rrfK
        mmrLambda = base.mmrLambda
        candidatesPerLeg = base.candidatesPerLeg
        signalScale = base.signalScale
        passageLimit = 8
        expandContext = true
    }

    public func resetChunking() {
        chunkTargetSize = Self.defaultChunkTargetSize
        chunkOverlap = Self.defaultChunkOverlap
    }

    public func resetAppearanceAndLayout() {
        appearanceMode = .dark
        pastelAccent = .sky
        glassCardOpacity = 0.95
        glassBorderGlow = 0.48
        glassTintStrength = 0.12
        useNativeLiquidGlassBars = true
        fontScale = .standard
        commandCenterMaxWidth = 1640
        fleetGridLayout = .twoColumn
        truncateLongRepoText = false
        // Home leads with what changed in your history. The operator decks are off by default
        // and stay one toggle away in Settings.
        showJarvisDeck = true
        showHardwareAndControlDeck = true
        showCrossAgentHub = false
        showVisualFleetMatrix = false
        showOptionalConnectorsBanner = true
        showOperatorWorkspaces = true
    }

    // MARK: - Storage

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults, effects: Effects) {
        self.defaults = defaults
        self.effects = effects
        let base = RetrievalTuning.default
        let store = defaults
        func double(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) as? Double ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int {
            store.object(forKey: key) as? Int ?? fallback
        }
        func boolean(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }
        func string(_ key: String, _ fallback: String) -> String {
            store.string(forKey: key) ?? fallback
        }

        appearanceModeRaw = string("ui.appearanceMode", AppearanceMode.dark.rawValue)
        pastelAccentRaw = string("ui.pastelAccent", PastelAccentChoice.sky.rawValue)
        glassCardOpacity = double("ui.glassCardOpacity", 0.95)
        glassBorderGlow = double("ui.glassBorderGlow", 0.48)
        glassTintStrength = double("ui.glassTintStrength", 0.12)
        useNativeLiquidGlassBars = boolean("ui.useNativeLiquidGlassBars", true)
        fontScaleRaw = string("ui.fontScale", FontScaleChoice.standard.rawValue)
        commandCenterMaxWidth = double("ui.commandCenterMaxWidth", 1640)
        fleetGridLayoutRaw = string("ui.fleetGridLayout", FleetGridLayout.twoColumn.rawValue)
        truncateLongRepoText = boolean("ui.truncateLongRepoText", false)

        // Off by default under new keys. The old keys held `true` for everyone who had ever
        // opened the app, so a changed default alone would have changed nothing here.
        showJarvisDeck = boolean("cc.home2.showJarvisDeck", true)
        showHardwareAndControlDeck = boolean("cc.home2.showHardwareDeck", true)
        showCrossAgentHub = boolean("cc.home2.showCrossAgentHub", false)
        showVisualFleetMatrix = boolean("cc.home2.showVisualFleetMatrix", false)
        showOptionalConnectorsBanner = boolean("cc.showConnectorsBanner", true)
        showOperatorWorkspaces = boolean("cc.home2.showOperatorWorkspaces", true)

        jarvisSpeechRate = double("jarvis.speechRate", 0.51)
        jarvisAutoSpeakBriefings = boolean("jarvis.autoSpeak", false)
        fmReasoningLevelRaw = string("fm.reasoningLevel", "moderate")
        fmIncludeSchemaInPrompt = boolean("fm.includeSchema", false)
        lowDiskWarningThresholdGiB = double("guard.lowDiskGiB", 25.0)

        usbStoragePollingIntervalSec = double("usb.pollingInterval", 1.0)
        usbHighlightBottlenecks = boolean("usb.highlightBottlenecks", true)
        automationDefaultDryRun = boolean("automation.defaultDryRun", true)
        automationLiveDefaultConfirmed = boolean("automation.liveDefaultConfirmed", false)
        automationShowBoundingBoxes = boolean("automation.showBoundingBoxes", true)

        rrfK = double("retrieval.rrfK", base.rrfK)
        mmrLambda = double("retrieval.mmrLambda", base.mmrLambda)
        candidatesPerLeg = integer("retrieval.candidatesPerLeg", base.candidatesPerLeg)
        signalScale = double("retrieval.signalScale", base.signalScale)
        passageLimit = integer("retrieval.passageLimit", 8)
        expandContext = boolean("retrieval.expandContext", true)

        chunkTargetSize = integer("chunking.targetSize", Self.defaultChunkTargetSize)
        chunkOverlap = integer("chunking.overlap", Self.defaultChunkOverlap)
        chunkingDirty = boolean("chunking.dirty", false)

        githubCommitsPerRepo = integer("sync.githubCommits", 100)
        githubIncludeForks = boolean("sync.githubForks", false)
        calendarLookBackDays = integer("sync.calendarBack", 730)
        calendarLookAheadDays = integer("sync.calendarAhead", 180)
        scheduledSyncEnabled = boolean("sync.scheduled", true)
        scheduledSyncIncludesNotes = boolean("sync.scheduledNotes", true)

        mcpExposeSensitiveDomains = boolean("mcp.exposeSensitive", false)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

#endif
