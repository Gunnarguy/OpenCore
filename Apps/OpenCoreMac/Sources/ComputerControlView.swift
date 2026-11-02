import AppKit
import ApplicationServices
import CoreGraphics
import CoreStore
import CoreTelemetry
import Foundation
import FoundationModels
import Observation
import ScreenCaptureKit
import SwiftUI
import Vision
import _CoreSpotlight_FoundationModels
import _Vision_FoundationModels

// MARK: - Local Automation Hub (0.3.5) + Screen Automation + macOS 27 FoundationModels Data Models

struct LocalHubModelEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let provider: String
    let publisher: String
    let repo: String
    let backend: String
    let quantization: String
    let sizeGB: Double
    let ramGB: Int
    let license: String
    let gated: Bool
    let purpose: String
    let strengths: [String]
    let limits: [String]
    let recommendedUse: String
    let fitNote: String
    let downloadFiles: [String]
    let url: String

    // Runtime state from ~/Library/Application Support/Local Automation Hub/state.json
    var supported: Bool = false
    var taskScopes: [String]? = nil
    var installed: Bool
    var verified: Bool
    var status: String
    var bytesOnDisk: Int64
    var toolTestPassed: Bool?
    var toolTestNote: String
    var checkedAt: String

    // Publisher Evidence from catalog/upstream.json
    var upstreamHeadline: String
    var upstreamArchitecture: String
    var upstreamToolParser: String
    var upstreamNativeContext: Int
    var upstreamExtendedContext: Int
    var upstreamBenchmarks: [(String, String)]
    var upstreamSampling: [(String, String)]
    var upstreamNotes: [String]


}

struct LocalHubRoutineStep: Identifiable, Hashable, Sendable {
    var id: String { "\(step)-\(tool)-\(summary)" }
    let step: Int
    let kind: String
    let summary: String
    let tool: String
    let argumentsJSON: String
}

struct LocalHubRoutine: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let goal: String
    let scope: String
    let modelID: String
    let maxSteps: Int
    let checkKind: String
    let checkPath: String
    let expectedText: String
    let targetApp: String
    let targetWindow: String
    let createdAt: String
    let lastRunID: String?
    let lastStatus: String?
    let sourceRecordingID: String?
    let demonstration: [LocalHubRoutineStep]
    let filePath: String
    let parameters: [String: String]
}

struct LocalHubRunStep: Identifiable, Hashable, Sendable {
    var id: String { "\(step)-\(at)" }
    let step: Int
    let at: String
    let tool: String
    let argumentsSummary: String
    let ok: Bool?
    let observationSummary: String
}

struct LocalHubRunReceipt: Identifiable, Sendable {
    let id: String
    let goal: String
    let modelID: String
    let scope: String
    let status: String
    let startedAt: String
    let finishedAt: String
    let summary: String
    let error: String?
    let steps: [LocalHubRunStep]
    let verificationPassed: Bool?
    let verificationKind: String
    let verificationSummary: String
    let verificationEvidence: [(String, String)]
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let turnCount: Int?
    let filePath: String

    var cacheReusePercent: Int? {
        guard let inputTokens, let cachedInputTokens, inputTokens > 0 else { return nil }
        return Int((Double(cachedInputTokens) / Double(inputTokens)) * 100.0)
    }
}

struct LocalHubRecording: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let scope: String
    let startURL: String
    let createdAt: String
    let updatedAt: String
    let status: String
    let eventCount: Int
    let stepCount: Int
    let routineID: String?
    let compiledGoal: String
    let steps: [LocalHubRoutineStep]
    let filePath: String
}

struct LocalHubAppKnowledge: Identifiable, Sendable {
    var id: String { appKey }
    let appKey: String
    let appName: String
    let bundleID: String
    let updatedAt: String
    let observationCount: Int
    let shortcuts: [(String, String)]
    let rules: [String]
    let failureNotes: [String]
    let recentWindows: [String]
    let commonControls: [String]
    let recentFacts: [String]
    let filePath: String
}

struct LocalHubRunningApp: Identifiable, Hashable, Sendable {
    var id: String { "\(bundleID)-\(pid)" }
    let name: String
    let bundleID: String
    let pid: Int32
    let isActive: Bool
}

struct LocalHubSettingsState: Equatable, Sendable {
    var defaultModelID: String = "apple-system"
    var stepLimit: Int = 8
    var allowShell: Bool = false
    var allowOutsideScratch: Bool = false
    var allowedFolder: String = ""
    var confirmWindowActions: Bool = true
    var captureEveryStep: Bool = true
    var verifyEachAction: Bool = true
    var teachFromRuns: Bool = true
    var autoRetryCount: Int = 1
    var preferShortcuts: Bool = true
    var appleFMUseAdapter: Bool = false
    var mlxKVBits: Int = 4
    var mlxMaxTokensOverride: Int = 0
    var mlxTemperatureOverride: String = ""
    var serverKeepAliveSec: Int = 300
    var prewarmDefaultModel: Bool = false
}

struct LocalHubGuideEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(chapterID)-\(name)" }
    let chapterID: String
    let chapterTitle: String
    let sectionTitle: String
    let name: String
    let kind: String
    let what: String
    let when: String
    let example: String
    let watch: String
}

struct LocalHubGuideChapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let entryCount: Int
}

struct PracticeFormState: Equatable, Sendable {
    var customerName: String = ""
    var email: String = ""
    var priority: String = "normal"
    var notes: String = ""
    var submittedAt: String = ""
}

// MARK: - Computer Control & Screen Vision Models

struct DetectedScreenElement: Identifiable, Hashable, Sendable {
    enum ElementKind: String, Sendable {
        case textControl = "UI Text / Button"
        case rectangleRegion = "UI Container / Box"
    }

    let id: UUID
    let index: Int
    let label: String
    let kind: ElementKind
    /// Normalized 0..1 rect in top-left origin (for SwiftUI canvas overlay)
    let normalizedRect: CGRect
    /// Logical macOS CGEvent screen coordinates (top-left origin, points)
    let screenPoint: CGPoint
    let screenSize: CGSize
    let confidence: Float

    var coordinateBadge: String {
        "(\(Int(screenPoint.x)), \(Int(screenPoint.y)))"
    }
}

struct PlannedAutomationStep: Identifiable, Hashable, Sendable {
    let id = UUID()
    let stepNumber: Int
    let action: String // "click", "double_click", "move", "type", "scroll"
    let targetLabel: String
    let x: Int
    let y: Int
    let textToType: String?
    let reasoning: String
}

struct AutomationProfileSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let filePath: String
    let tickHz: Double
    let downscale: Double
    let matchThreshold: Double
    let dryRun: Bool
    let templateCount: Int
}

struct AutomationExecutionLog: Identifiable, Hashable, Sendable {
    let id = UUID()
    let timestamp: Date
    let mode: String // "DRY-RUN", "LIVE", "HUB", "FM-27", "VISION"
    let summary: String
    let detail: String
}

// MARK: - Unified Local Automation Hub + Screen Automation + macOS 27 FoundationModels Manager

@MainActor
@Observable
final class ComputerControlManager {
    static let shared = ComputerControlManager()

    // Paths. Where these tools live is private, so it comes from `LocalPrivateNames`. Unset means
    // nothing is read from there and the hub is never trusted (see `probeHubServer`).
    private static func homeRelativePath(_ relative: String?) -> String? {
        relative.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
    }
    let localHubRepoPath = homeRelativePath(LocalPrivateNames.current.localAutomation.hubRepositoryRelativePath)
    let localHubDataDir = ("~/Library/Application Support/Local Automation Hub" as NSString).expandingTildeInPath
    let localHubAppBundlePath = ("~/Applications/Local Hub.app" as NSString).expandingTildeInPath
    let automationRootPath = homeRelativePath(LocalPrivateNames.current.localAutomation.profilesRelativePath)
    let hubServerBaseURL = "http://127.0.0.1:8765"

    // Local Automation Hub Loaded State
    var models: [LocalHubModelEntry] = []
    var routines: [LocalHubRoutine] = []
    var runs: [LocalHubRunReceipt] = []
    var recordings: [LocalHubRecording] = []
    var learnedKnowledge: [LocalHubAppKnowledge] = []
    var runningApps: [LocalHubRunningApp] = []
    var guideChapters: [LocalHubGuideChapter] = []
    var guideEntries: [LocalHubGuideEntry] = []
    var settings = LocalHubSettingsState()
    var practiceForm = PracticeFormState()

    // Live Server & Peekaboo Bridge State
    var isHubServerOnline: Bool = false
    var hubApiToken: String = ""
    var requestedStudioTab: LocalHubStudioTab?
    private var liveModelCatalog: [String: Any]?
    private var lastModelCatalogData: Data?
    var isStartingServer: Bool = false
    var peekabooInstalled: Bool = false
    var peekabooVersion: String = "4.6.0"
    var peekabooPath: String = ""
    var peekabooLiveWindowsOutput: String = ""
    var isRunningPeekaboo: Bool = false

    // macOS 27 FoundationModels & Tool Calling Live State
    var fmVariantName: String = "Checking..."
    var fmContextSize: Int = 8192
    var fmCapabilities: [String] = []
    var pccAvailable: Bool = false
    var fmLastSessionInputTokens: Int = 0
    var fmLastSessionCachedTokens: Int = 0
    var fmLastSessionOutputTokens: Int = 0
    var isRunningFMTask: Bool = false
    var fmTaskOutput: String = ""

    // Task Composer State
    var taskGoal: String = "Save the practice form with name Ada Lovelace and note Verified by OpenCore + Local Hub."
    var taskScope: String = "browser" // browser, scratch, folder, computer, desktop
    var taskModelID: String = "apple-system"
    var taskMaxSteps: Int = 24
    var taskCheckKind: String = "fixture" // fixture, file, page_text, desktop_text, none
    var taskCheckPath: String = ""
    var taskExpectedNote: String = "Verified by OpenCore + Local Hub"
    var taskURL: String = "http://127.0.0.1:8765/fixture"
    var taskFolderID: String = ""
    var taskFolderName: String = "No folder chosen"
    var hubWindows: [LocalHubWindowOption] = []
    var isFindingHubWindows = false
    var taskAllowOverwrite: Bool = false
    var taskStatus: String = ""
    var lastHubError: String?
    var hubSettingValues: [String: Any] = [:]
    var hubSettingFields: [HubSettingField] = []
    var hubSettingsLoaded = false
    var hubSettingsStatus = "Connect to Local Hub to edit its settings."
    var isSavingHubSettings = false
    var taskExpectedText: String = "Ada Lovelace"
    // Native selector and Hub identity are different protocols. Never send a
    // display name or bundle identifier in TaskRequest.apps.
    var taskTargetApp: String = ""
    var taskHubAppID: String = ""
    var hubApps: [LocalHubAppOption] = []
    var isRefreshingHubApps = false
    var taskTargetWindow: String = ""
    var selectedRunID: String?
    var selectedModelID: String? = "apple-system"
    var selectedRoutineID: String?
    var routineParameterEdits: [String: [String: String]] = [:]

    // Screen Automation & Screen Vision State
    var capturedImage: NSImage?
    var capturedImagePath: String?
    var screenLogicalSize: CGSize = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
    var detectedElements: [DetectedScreenElement] = []
    var selectedElementID: UUID?
    var plannedSteps: [PlannedAutomationStep] = []
    var executionLogs: [AutomationExecutionLog] = []
    var automationProfiles: [AutomationProfileSummary] = []

    /// Safety lock. Starts from the saved default, and leaves dry run only through
    /// `confirmLiveControl()`, so nothing here can arm live control by assignment.
    private(set) var isDryRun: Bool
    /// Why this launch did not follow the saved default, while that is still true.
    var launchNotice: String? {
        ComputerLiveArming.launch(defaultDryRun: AppSettings.shared.automationDefaultDryRun,
                                  liveDefaultConfirmed: AppSettings.shared.automationLiveDefaultConfirmed).notice
    }
    var pendingLiveConfirmation: (title: String, message: String)?
    var isConfirmingLive = false
    private var hubProbe: ComputerStudioDiagnosis.HubProbe?
    var screenScanProblem: ComputerStudioNotice?
    var plannerProblem: ComputerStudioNotice?
    var isAnalyzingScreen = false
    var isPlanningTask = false
    var screenSummaryText: String = ""
    var lastScanTime: Date?
    var targetReticlePoint: CGPoint?

    private init() {
        let settings = AppSettings.shared
        // A setting's didSet doesn't run in init, so this is the only place the default is read.
        isDryRun = ComputerLiveArming.launch(defaultDryRun: settings.automationDefaultDryRun,
                                             liveDefaultConfirmed: settings.automationLiveDefaultConfirmed).mode == .dryRun
        reloadAllLocalHubData()
        loadAutomationProfiles()
        refreshMacOS27FoundationModelsTelemetry()
        Task {
            await probeHubServer()
        }
    }

    // MARK: - Dry-run switch, and what each planned step will do

    private var mode: ComputerExecutionMode { isDryRun ? .dryRun : .live }

    /// Every dry-run switch in the Studio comes through here.
    func requestMode(_ target: ComputerExecutionMode) {
        switch ComputerLiveArming.request(target, from: mode, runningTitle: ComputerRunCenter.shared.ledger.runningTitle) {
        case .nothingToDo:
            break
        case .returnToDryRun:
            returnToDryRun()
        case .askFirst(let title, let message):
            pendingLiveConfirmation = (title, message)
            isConfirmingLive = true
        case .refuse(let reason):
            taskStatus = reason
            logAction(mode: "BLOCKED", summary: "Live control not armed", detail: reason)
            ActionFeedbackCenter.shared.record(button: "Arm live control", command: "No change", outcome: reason, status: .warning)
        }
    }

    func confirmLiveControl() {
        // Asked again, because something could have started while the dialog was open.
        guard case .askFirst = ComputerLiveArming.request(.live, from: mode, runningTitle: ComputerRunCenter.shared.ledger.runningTitle) else { return }
        isDryRun = false
        logAction(mode: "LIVE", summary: "Live control armed", detail: "Confirmed in the dialog. It lasts until switched back or the app quits.")
    }

    func returnToDryRun() {
        guard !isDryRun else { return }
        isDryRun = true
        logAction(mode: "DRY-RUN", summary: "Back on dry run", detail: "No input events will be sent. A run already in Local Hub keeps going until stopped.")
    }

    func decision(for step: PlannedAutomationStep) -> ComputerStepDecision {
        ComputerStepPolicy.decide(action: step.action, x: Double(step.x), y: Double(step.y),
                                  screenWidth: Double(screenLogicalSize.width), screenHeight: Double(screenLogicalSize.height),
                                  mode: mode, inputPermitted: isDryRun || AXIsProcessTrusted(),
                                  runningTitle: ComputerRunCenter.shared.ledger.runningTitle)
    }

    /// Decided again at the click, because the button may be showing an earlier state.
    func performPlannedStep(_ step: PlannedAutomationStep) {
        let point = CGPoint(x: step.x, y: step.y)
        switch decision(for: step) {
        case .perform(.click, _): executeClick(at: point, label: step.targetLabel)
        case .perform(.doubleClick, _): executeClick(at: point, label: step.targetLabel, doubleClick: true)
        case .perform(.move, _): executeMoveCursor(to: point, label: step.targetLabel)
        case .preview: previewPointer(action: step.action, at: point, label: step.targetLabel)
        case .unavailable(_, let reason):
            logAction(mode: "BLOCKED", summary: "Step \(step.stepNumber) not sent", detail: reason)
        }
    }

    var hubNotice: ComputerStudioNotice? {
        ComputerStudioDiagnosis.hub(probe: hubProbe, appInstalled: FileManager.default.fileExists(atPath: localHubAppBundlePath),
                                    isOnline: isHubServerOnline, isStarting: isStartingServer, lastError: lastHubError)
    }

    var selectedElement: DetectedScreenElement? {
        guard let selectedElementID else { return detectedElements.first }
        return detectedElements.first { $0.id == selectedElementID }
    }

    var selectedRun: LocalHubRunReceipt? {
        if let selectedRunID, let found = runs.first(where: { $0.id == selectedRunID }) {
            return found
        }
        return runs.first
    }

    var selectedModel: LocalHubModelEntry? {
        if let selectedModelID, let found = models.first(where: { $0.id == selectedModelID }) {
            return found
        }
        return models.first
    }

    // MARK: - Reload All Local Automation Hub Disk + Catalog Data

    func reloadAllLocalHubData() {
        loadModelsAndCatalog()
        loadStateAndSettings()
        loadRoutines()
        loadRuns()
        loadRecordings()
        loadLearnedKnowledge()
        loadPracticeForm()
        loadGuide()
        refreshRunningApps()
        checkPeekabooHelper()
    }

    private func loadJSONDictionary(at path: String?) -> [String: Any]? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func loadJSONArray(at path: String?) -> [[String: Any]]? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return obj
    }

    // MARK: - Models, Upstream Publisher Evidence & Serving Profiles

    func applyLiveModelCatalog(_ status: [String: Any]) {
        guard let catalog = status["models"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: catalog, options: .sortedKeys),
              data != lastModelCatalogData else { return }
        lastModelCatalogData = data
        liveModelCatalog = status
        loadModelsAndCatalog()
    }

    func invalidateHubConnection(_ reason: String) {
        isHubServerOnline = false
        hubApiToken = ""
        liveModelCatalog = nil
        lastModelCatalogData = nil
        loadModelsAndCatalog()
        ComputerUseStudioController.shared.markRuntimeUnverified(reason)
    }

    func loadModelsAndCatalog() {
        let availablePath = localHubRepoPath.map { "\($0)/catalog/available.json" }
        let modelsPath = localHubRepoPath.map { "\($0)/catalog/models.json" }
        let upstreamPath = localHubRepoPath.map { "\($0)/catalog/upstream.json" }
        let statePath = "\(localHubDataDir)/state.json"

        let availableRoot = loadJSONDictionary(at: availablePath)
        let availableModels = availableRoot?["models"] as? [[String: Any]]
        let appleBuiltin: [String: Any] = [
            "id": "apple-system",
            "name": "Apple · Built-in Intelligence",
            "provider": "Apple",
            "publisher": "Apple",
            "repo": "apple/FoundationModels-macOS27",
            "backend": "apple_fm",
            "quantization": "System NPU",
            "size_gb": 0.0,
            "ram_gb": 0,
            "license": "macOS 27 System Framework",
            "purpose": "Uses the on-device model managed by macOS. No Hub model download. Its memory footprint has not been measured here.",
            "strengths": ["No model download", "OS-managed model lifecycle", "Native LanguageModelSession tool calling"],
            "limits": ["4k-8k context window", "Text & structured tool actions"]
        ]
        let stateRoot = loadJSONDictionary(at: statePath)
        let customModels = stateRoot?["custom_models"] as? [[String: Any]] ?? []
        let rawCatalog = (liveModelCatalog?["models"] as? [[String: Any]]) ?? ([appleBuiltin] + (availableModels ?? loadJSONArray(at: availablePath) ?? loadJSONArray(at: modelsPath) ?? []) + customModels)
        let upstreamRoot = loadJSONDictionary(at: upstreamPath)
        let upstreamModels = upstreamRoot?["models"] as? [String: [String: Any]] ?? [:]
        let stateModels = (stateRoot?["installed"] as? [String: [String: Any]]) ?? (stateRoot?["models"] as? [String: [String: Any]]) ?? [:]

        var entries: [LocalHubModelEntry] = []

        for item in rawCatalog {
            guard let id = item["id"] as? String else { continue }
            let name = item["name"] as? String ?? id
            let provider = item["provider"] as? String ?? (id.components(separatedBy: "/").first ?? "Local")
            let publisher = item["publisher"] as? String ?? provider
            let repo = item["repo"] as? String ?? item["source_id"] as? String ?? id
            let builtin = item["builtin"] as? Bool == true || id == "apple-system"
            let backend = (item["backend"] as? String) ?? (item["runtime"] as? String) ?? (builtin ? "apple_fm" : "mlx-lm")
            let quantization = item["quantization"] as? String ?? (builtin ? "OS managed" : (id.contains("4bit") ? "4-bit" : (id.contains("JANG") ? "JANG Mixed-Bit" : (id == "mlx-community/UGround-V1-2B" ? "bf16" : "Not reported"))))
            let rawBytes = (item["size"] as? NSNumber)?.doubleValue ?? 0.0
            let sizeGB = (item["size_gb"] as? NSNumber)?.doubleValue ?? (rawBytes > 0 ? rawBytes / 1_000_000_000.0 : 0.0)
            let ramGB = (item["ram_gb"] as? NSNumber)?.intValue ?? 0
            let license = item["license"] as? String ?? "Open"
            let gated = item["gated"] as? Bool ?? false
            let purpose = (item["purpose"] as? String) ?? (item["description"] as? String) ?? ""
            let strengths = item["strengths"] as? [String] ?? []
            let limits = item["limits"] as? [String] ?? []
            let recommendedUse = item["recommended_use"] as? String ?? ""
            let fitNote = item["fit_note"] as? String ?? ""
            let downloadFiles = (item["files"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let url = item["url"] as? String ?? ""

            // State from state.json (`installed` maps modelID -> {"revision": ..., "bytes": ..., "verification": ...})
            let diagnostics = stateRoot?["diagnostics"] as? [String: [String: Any]] ?? [:]
            let st = (item["installed"] as? [String: Any]) ?? (backend == "apple_fm" ? (diagnostics[id] ?? [:]) : (stateModels[id] ?? [:]))
            var installation = item
            installation["installed"] = st
            let installed = backend == "apple_fm" || LocalHubContract.installationComplete(installation)
            let verifStr = st["verification"] as? String ?? ""
            let verified = verifStr == "tool_test_passed"
            let status = st["status"] as? String ?? (installed ? "installed" : "not_downloaded")
            let bytesOnDisk = (st["bytes"] as? NSNumber)?.int64Value ?? (st["bytes_on_disk"] as? NSNumber)?.int64Value ?? 0
            let toolTestPassed: Bool? = verifStr == "tool_test_passed" ? true : (verifStr == "failed" ? false : (st["tool_test_passed"] as? Bool))
            let diagnostic = st["test"] as? [String: Any] ?? [:]
            let toolTestNote = diagnostic["evidence"] as? String ?? st["tool_test_note"] as? String ?? ""
            let checkedAt = diagnostic["tested_at"] as? String ?? st["checked_at"] as? String ?? ""

            // Upstream Evidence
            let up = upstreamModels[id] ?? [:]
            let headline = up["headline"] as? String ?? purpose
            let archDict = up["architecture"] as? [String: Any] ?? [:]
            let archType = archDict["type"] as? String ?? backend
            let archLayers = (archDict["layers"] as? NSNumber)?.intValue ?? 0
            let archSummary = archLayers > 0 ? "\(archType) (\(archLayers) layers)" : archType
            let toolUseDict = up["tool_use"] as? [String: Any] ?? [:]
            let toolParser = toolUseDict["tool_call_parser"] as? String ?? (backend == "apple_fm" ? "LanguageModelSession" : "json_tool")
            let ctxDict = up["context_length"] as? [String: Any] ?? [:]
            let nativeCtx = (ctxDict["native_max"] as? NSNumber)?.intValue ?? (backend == "apple_fm" ? 8192 : 32768)
            let extCtx = (ctxDict["extended_max"] as? NSNumber)?.intValue ?? nativeCtx

            var benchmarks: [(String, String)] = []
            if let benchDict = up["published_benchmarks"] as? [String: Any] {
                for key in benchDict.keys.sorted() where key != "source" {
                    if let val = benchDict[key] {
                        benchmarks.append((key, "\(val)"))
                    }
                }
            }

            var sampling: [(String, String)] = []
            if let sampDict = up["recommended_sampling"] as? [String: Any] {
                for key in sampDict.keys.sorted() {
                    if let val = sampDict[key], !(val is [String: Any]) {
                        sampling.append((key, "\(val)"))
                    } else if let sub = sampDict[key] as? [String: Any] {
                        let subStr = sub.keys.sorted().compactMap { k in sub[k].map { "\(k)=\($0)" } }.joined(separator: ", ")
                        sampling.append((key, subStr))
                    }
                }
            }

            let upNotes = up["practical_notes"] as? [String] ?? []

            entries.append(
                LocalHubModelEntry(
                    id: id,
                    name: name,
                    provider: provider,
                    publisher: publisher,
                    repo: repo,
                    backend: backend,
                    quantization: quantization,
                    sizeGB: sizeGB,
                    ramGB: ramGB,
                    license: license,
                    gated: gated,
                    purpose: purpose,
                    strengths: strengths,
                    limits: limits,
                    recommendedUse: recommendedUse,
                    fitNote: fitNote,
                    downloadFiles: downloadFiles,
                    url: url,
                    supported: liveModelCatalog != nil && (item["supported"] as? Bool) == true && (item["adapter_ready"] as? Bool) != false,
                    taskScopes: item["scopes"] as? [String],
                    installed: installed,
                    verified: verified,
                    status: status,
                    bytesOnDisk: bytesOnDisk,
                    toolTestPassed: toolTestPassed,
                    toolTestNote: toolTestNote,
                    checkedAt: checkedAt,
                    upstreamHeadline: headline,
                    upstreamArchitecture: archSummary,
                    upstreamToolParser: toolParser,
                    upstreamNativeContext: nativeCtx,
                    upstreamExtendedContext: extCtx,
                    upstreamBenchmarks: benchmarks,
                    upstreamSampling: sampling,
                    upstreamNotes: upNotes
                )
            )
        }

        models = entries
    }

    // MARK: - Settings & State (`state.json`)

    func loadStateAndSettings() {
        // Hub owns state.json. Only its validated API is allowed to change settings.
        // Legacy local settings are not evidence of the running server's settings.
    }

    func saveSettingsToDiskAndServer() async {
        guard hubSettingsLoaded, !isSavingHubSettings else { return }
        isSavingHubSettings = true
        defer { isSavingHubSettings = false }
        let permittedKeys = Set(hubSettingFields.map(\.id))
        let payload = hubSettingValues.filter { permittedKeys.contains($0.key) }
        guard let saved = await postToHubServer(path: "/api/settings", payload: payload),
              permittedKeys.allSatisfy({ saved[$0] != nil }) else {
            hubSettingsStatus = lastHubError ?? "The Hub did not confirm these settings. Nothing was written by OpenCore."
            return
        }
        hubSettingValues = saved
        hubSettingsStatus = "Settings saved and confirmed by Local Hub."
        logAction(mode: "HUB", summary: "Saved validated Local Hub settings", detail: "POST /api/settings confirmed \(payload.count) fields.")
    }

    func refreshHubSettings() async {
        guard let response = await getHubObject(path: "/api/settings"),
              let values = response["values"] as? [String: Any],
              let fields = response["fields"] as? [String: [String: Any]] else {
            hubSettingsLoaded = false
            hubSettingsStatus = lastHubError ?? "Local Hub settings are unavailable."
            return
        }
        hubSettingValues = values
        hubSettingFields = fields.keys.sorted().compactMap { key in
            guard let field = fields[key], let kind = field["kind"] as? String,
                  let label = field["label"] as? String else { return nil }
            let options = (field["options"] as? [[String: String]] ?? []).compactMap { item -> HubSettingOption? in
                guard let value = item["value"], let title = item["label"] else { return nil }
                return HubSettingOption(value: value, label: title)
            }
            return HubSettingField(id: key, kind: kind, label: label, help: field["help"] as? String ?? "",
                minimum: (field["min"] as? NSNumber)?.intValue, maximum: (field["max"] as? NSNumber)?.intValue, options: options)
        }
        hubSettingsLoaded = !hubSettingFields.isEmpty
        hubSettingsStatus = "Loaded \(hubSettingFields.count) supported settings from Local Hub."
    }

    var selectedHubApp: LocalHubAppOption? {
        hubApps.first { $0.id == taskHubAppID }
    }

    func refreshHubApps() async {
        guard !isRefreshingHubApps else { return }
        isRefreshingHubApps = true
        defer { isRefreshingHubApps = false }
        guard let array = await getHubArray(path: "/api/apps") else {
            taskStatus = lastHubError ?? "The Hub app list is unavailable."
            return
        }
        hubApps = LocalHubContract.appInventory(array)
        if !taskHubAppID.isEmpty, selectedHubApp == nil {
            taskHubAppID = ""
            taskTargetApp = ""
            taskTargetWindow = ""
            hubWindows = []
        }
    }

    func selectHubApp(_ id: String) {
        taskHubAppID = id
        // Native window-list/Exact Window APIs accept a native app selector.
        // The opaque ID is reserved for the Hub's allowed-app policy.
        taskTargetApp = selectedHubApp?.bundleID ?? ""
        taskTargetWindow = ""
        hubWindows = []
    }

    func targetRunningApp(_ app: LocalHubRunningApp) async {
        await refreshHubApps()
        guard let choice = hubApps.first(where: { $0.bundleID == app.bundleID }) else {
            taskStatus = "This running app is not in Local Hub's installed-app inventory. Refresh Apps or choose another installed app."
            return
        }
        selectHubApp(choice.id)
        taskScope = "computer"
    }

    func findHubWindows() async {
        guard !isFindingHubWindows else { return }
        isFindingHubWindows = true
        defer { isFindingHubWindows = false }
        guard let choice = selectedHubApp else {
            taskStatus = "Choose an installed app from Local Hub before finding its windows."
            return
        }
        let app = choice.bundleID
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "app", value: app)]
        guard let encoded = query.percentEncodedQuery,
              let response = await getHubObject(path: "/api/native/windows?\(encoded)") else {
            taskStatus = lastHubError ?? "The app's windows could not be read."; return
        }
        guard taskTargetApp == app else { return }
        let data = response["data"] as? [String: Any] ?? response
        hubWindows = (data["windows"] as? [[String: Any]] ?? []).compactMap { window in
            guard window["observation_capability"] as? String != "pixels_only",
                  let id = (window["window_id"] as? NSNumber)?.intValue, id > 0 else { return nil }
            return LocalHubWindowOption(id: id, title: window["window_title"] as? String ?? window["title"] as? String ?? "Untitled window")
        }
        taskTargetWindow = ""
        if hubWindows.isEmpty { taskStatus = "No accessible windows found. Open the app and check Mac-control permission in Local Hub." }
    }

    func chooseHubFolder() async {
        guard let folder = await postToHubServer(path: "/api/folders/choose", payload: [:]),
              let id = folder["id"] as? String else {
            taskStatus = lastHubError ?? "Folder selection canceled."
            return
        }
        taskFolderID = id
        taskFolderName = folder["name"] as? String ?? "Chosen folder"
    }

    // MARK: - Routines (`routines/*.json`), Runs (`runs/*.json`), Recordings (`recordings/*.json`)

    func loadRoutines() {
        let dir = "\(localHubDataDir)/routines"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        routines = files.filter { $0.hasSuffix(".json") }.compactMap { file in
            let full = "\(dir)/\(file)"
            guard let d = loadJSONDictionary(at: full), let id = d["id"] as? String else { return nil }
            let check = d["verification"] as? [String: Any] ?? [:]
            let steps = (d["steps"] as? [[String: Any]] ?? []).enumerated().map { index, action in
                let data = (try? JSONSerialization.data(withJSONObject: action, options: [.sortedKeys])) ?? Data()
                return LocalHubRoutineStep(step: index + 1, kind: "saved action", summary: action["label"] as? String ?? "",
                    tool: action["tool"] as? String ?? "unknown", argumentsJSON: String(data: data, encoding: .utf8) ?? "{}")
            }
            return LocalHubRoutine(id: id, name: d["name"] as? String ?? id,
                goal: d["original_goal"] as? String ?? d["description"] as? String ?? d["name"] as? String ?? "",
                scope: d["scope"] as? String ?? "unknown", modelID: "Deterministic routine", maxSteps: steps.count,
                checkKind: check["kind"] as? String ?? "none", checkPath: check["path"] as? String ?? "",
                expectedText: check["expected"] as? String ?? check["name"] as? String ?? "",
                targetApp: d["app"] as? String ?? "", targetWindow: (d["window"] as? NSNumber)?.stringValue ?? "",
                createdAt: d["created"] as? String ?? "", lastRunID: d["source_run"] as? String,
                lastStatus: d["verification_status"] as? String, sourceRecordingID: d["source_recording"] as? String,
                demonstration: steps, filePath: full, parameters: d["parameters"] as? [String: String] ?? [:])
        }.sorted { $0.createdAt > $1.createdAt }
        if selectedRoutineID == nil { selectedRoutineID = routines.first?.id }
    }

    func loadRuns() {
        let dir = "\(localHubDataDir)/runs"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        runs = files.filter { $0.hasSuffix(".json") }.compactMap { file in
            let full = "\(dir)/\(file)"
            guard let d = loadJSONDictionary(at: full) else { return nil }
            return LocalHubContract.receipt(d, filePath: full)
        }.sorted { $0.startedAt > $1.startedAt }
        if selectedRunID == nil { selectedRunID = runs.first?.id }
    }

    func loadRecordings() {
        let dir = "\(localHubDataDir)/recordings"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            recordings = []
            return
        }
        var loaded: [LocalHubRecording] = []
        for file in files where file.hasSuffix(".json") {
            let full = "\(dir)/\(file)"
            guard let d = loadJSONDictionary(at: full) else { continue }
            let id = d["id"] as? String ?? (file as NSString).deletingPathExtension
            let events = d["events"] as? [[String: Any]] ?? []
            let rawSteps = d["steps"] as? [[String: Any]] ?? []
            var steps: [LocalHubRoutineStep] = []
            for (idx, s) in rawSteps.enumerated() {
                let argsObj = s
                let argsData = (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data()
                let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                steps.append(
                    LocalHubRoutineStep(
                        step: (s["step"] as? NSNumber)?.intValue ?? (idx + 1),
                        kind: s["kind"] as? String ?? "browser",
                        summary: s["label"] as? String ?? "",
                        tool: s["tool"] as? String ?? "",
                        argumentsJSON: argsStr
                    )
                )
            }
            loaded.append(
                LocalHubRecording(
                    id: id,
                    title: d["title"] as? String ?? "Recorded Session",
                    scope: d["scope"] as? String ?? "browser",
                    startURL: d["url"] as? String ?? "",
                    createdAt: d["created"] as? String ?? "",
                    updatedAt: d["updated"] as? String ?? d["created"] as? String ?? "",
                    status: d["status"] as? String ?? "stopped",
                    eventCount: events.count,
                    stepCount: steps.count,
                    routineID: d["routine_id"] as? String,
                    compiledGoal: d["compiled_goal"] as? String ?? "",
                    steps: steps,
                    filePath: full
                )
            )
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Learned App Knowledge (`knowledge/*.json`) & Running Apps

    func loadLearnedKnowledge() {
        let dir = "\(localHubDataDir)/knowledge"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            learnedKnowledge = []
            return
        }
        var loaded: [LocalHubAppKnowledge] = []
        for file in files where file.hasSuffix(".json") {
            let full = "\(dir)/\(file)"
            guard let d = loadJSONDictionary(at: full) else { continue }
            let appKey = d["app_key"] as? String ?? (file as NSString).deletingPathExtension
            var shortcuts: [(String, String)] = []
            if let sc = d["shortcuts"] as? [String: Any] {
                for k in sc.keys.sorted() {
                    if let v = sc[k] { shortcuts.append((k, "\(v)")) }
                }
            }
            let factsRaw = d["facts"] as? [[String: Any]] ?? []
            let recentFacts = factsRaw.suffix(8).compactMap { $0["text"] as? String }

            loaded.append(
                LocalHubAppKnowledge(
                    appKey: appKey,
                    appName: d["app_name"] as? String ?? appKey,
                    bundleID: d["bundle_id"] as? String ?? "",
                    updatedAt: d["updated"] as? String ?? d["created"] as? String ?? "",
                    observationCount: (d["observation_count"] as? NSNumber)?.intValue ?? 0,
                    shortcuts: shortcuts,
                    rules: d["workflow_rules"] as? [String] ?? [],
                    failureNotes: d["failure_notes"] as? [String] ?? [],
                    recentWindows: d["recent_windows"] as? [String] ?? [],
                    commonControls: d["common_controls"] as? [String] ?? [],
                    recentFacts: recentFacts,
                    filePath: full
                )
            )
        }
        learnedKnowledge = loaded.sorted { $0.appName < $1.appName }
    }

    func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> LocalHubRunningApp? in
                guard let name = app.localizedName, !name.isEmpty else { return nil }
                return LocalHubRunningApp(
                    name: name,
                    bundleID: app.bundleIdentifier ?? "unknown.bundle",
                    pid: app.processIdentifier,
                    isActive: app.isActive
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        runningApps = apps
    }

    func checkPeekabooHelper() {
        let candidate = "\(localHubDataDir)/helpers/peekaboo-4.6.0/peekaboo-macos-arm64/peekaboo"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            peekabooInstalled = true
            peekabooPath = candidate
        } else {
            peekabooInstalled = false
            peekabooPath = candidate
        }
    }

    func runPeekabooWindowList() async {
        guard peekabooInstalled else { return }
        isRunningPeekaboo = true
        defer { isRunningPeekaboo = false }

        let bin = peekabooPath
        let output = await Task.detached(priority: .userInitiated) { () -> String in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["list", "windows"]
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let combined = (String(data: data, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
                return combined.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "Failed to launch Peekaboo: \(error.localizedDescription)"
            }
        }.value

        peekabooLiveWindowsOutput = output.isEmpty ? "Peekaboo completed with no output." : output
        logAction(
            mode: "HUB",
            summary: "Queried live windows via Peekaboo 4.6.0",
            detail: String(peekabooLiveWindowsOutput.prefix(200))
        )
    }

    // MARK: - Practice Form (`practice-form.json`) & Guide (`hub/static/guide.json`)

    func loadPracticeForm() {
        let path = "\(localHubDataDir)/practice-form.json"
        // The fixture is an append-only array of saved records, not an editable draft.
        guard let saved = loadJSONArray(at: path)?.last else {
            practiceForm = PracticeFormState()
            return
        }
        practiceForm = PracticeFormState(customerName: saved["name"] as? String ?? "", email: "", priority: "",
            notes: saved["note"] as? String ?? "", submittedAt: saved["saved_at"] as? String ?? "")
    }

    func resetPracticeForm() async {
        // A reset endpoint does not exist. Preserve every saved record.
        loadPracticeForm()
        logAction(mode: "HUB", summary: "Refreshed the latest saved practice form", detail: "Saved records were read without modification.")
    }

    func loadGuide() {
        guard let root = loadJSONDictionary(at: localHubRepoPath.map { "\($0)/hub/static/guide.json" }),
              let rawChapters = root["chapters"] as? [[String: Any]] else {
            return
        }
        var chaps: [LocalHubGuideChapter] = []
        var items: [LocalHubGuideEntry] = []

        for ch in rawChapters {
            let cid = ch["id"] as? String ?? UUID().uuidString
            let ctitle = ch["title"] as? String ?? "Chapter"
            let csummary = ch["summary"] as? String ?? ""
            let sections = ch["sections"] as? [[String: Any]] ?? []
            var count = 0
            for sec in sections {
                let stitle = sec["title"] as? String ?? ""
                let entries = sec["entries"] as? [[String: Any]] ?? []
                for e in entries {
                    count += 1
                    items.append(
                        LocalHubGuideEntry(
                            chapterID: cid,
                            chapterTitle: ctitle,
                            sectionTitle: stitle,
                            name: e["name"] as? String ?? "",
                            kind: e["kind"] as? String ?? "",
                            what: (e["what"] as? String ?? "").replacingOccurrences(of: "—", with: " - "),
                            when: (e["when"] as? String ?? "").replacingOccurrences(of: "—", with: " - "),
                            example: (e["example"] as? String ?? "").replacingOccurrences(of: "—", with: " - "),
                            watch: (e["watch"] as? String ?? "").replacingOccurrences(of: "—", with: " - ")
                        )
                    )
                }
            }
            chaps.append(LocalHubGuideChapter(id: cid, title: ctitle, summary: csummary, entryCount: count))
        }
        guideChapters = chaps
        guideEntries = items
    }

    // MARK: - Loopback Server Control (`http://127.0.0.1:8765`)

    func probeHubServer() async {
        // Anything can listen on this port, and the next call fetches a token. With no expected
        // identity to compare against, this stops here rather than trusting whatever answers.
        let expectedIdentity = LocalPrivateNames.current.localAutomation.hubIdentity
        let identity = expectedIdentity == nil ? nil : await getHubObject(path: "/api/identity")
        hubProbe = expectedIdentity == nil ? .notConfigured
            : identity == nil ? .notRunning
            : identity?["app"] as? String == expectedIdentity ? nil : .wrongService
        guard hubProbe == nil,
              let bootstrap = await getHubObject(path: "/api/bootstrap"),
              let token = bootstrap["token"] as? String, !token.isEmpty,
              let status = await getHubObject(path: "/api/status"),
              let runtime = status["runtime"] as? [String: Any] else {
            isHubServerOnline = false
            hubApiToken = ""
            liveModelCatalog = nil
            lastModelCatalogData = nil
            loadModelsAndCatalog()
            ComputerUseStudioController.shared.markRuntimeUnverified(
                lastHubError ?? "Local Hub could not be reached. Current model readiness is unknown.")
            return
        }
        hubApiToken = token
        isHubServerOnline = true
        applyLiveModelCatalog(status)
        ComputerUseStudioController.shared.applyRuntimeReceipt(runtime)
        adoptRunningHubRun(status)
        await refreshHubSettings()
        reloadAllLocalHubData()
    }

    /// A run this app didn't start, or started before a relaunch, still needs a Stop.
    private func adoptRunningHubRun(_ status: [String: Any]) {
        guard status["busy"] as? Bool == true,
              let id = (status["current"] as? [String: Any])?["id"] as? String else { return }
        ComputerRunCenter.shared.adoptHubRun(id) { token in
            await self.observeHubRun(id, token: token)
        }
    }

    func launchLocalHubServerOrApp() async {
        guard !isStartingServer else { return }
        isStartingServer = true
        defer { isStartingServer = false }
        await probeHubServer()
        if isHubServerOnline { return }
        // Opening the app can't help either of these, and waiting six seconds would hide why.
        if hubProbe == .notConfigured || hubProbe == .wrongService {
            if let notice = hubNotice { reportHubError(notice.text, path: "/api/identity") }
            return
        }
        guard FileManager.default.fileExists(atPath: localHubAppBundlePath),
              NSWorkspace.shared.open(URL(fileURLWithPath: localHubAppBundlePath)) else {
            reportHubError("Local Hub could not be opened. Install or repair Local Hub before using its runtime.", path: "Open Local Hub.app")
            return
        }
        for _ in 0..<12 {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await probeHubServer()
            if isHubServerOnline {
                logAction(mode: "HUB", summary: "Connected to Local Hub", detail: "Its own native app manages the server lifecycle.")
                return
            }
        }
        reportHubError("Local Hub opened, but its local service did not become ready. Check its window for setup or permission errors.", path: "/api/identity")
    }

    func postToHubServer(path: String, payload: [String: Any]) async -> [String: Any]? {
        if !isHubServerOnline || hubApiToken.isEmpty { await probeHubServer() }
        guard isHubServerOnline, !hubApiToken.isEmpty else {
            reportHubError("Connect to Local Hub before running this action.", path: path)
            return nil
        }
        return await requestHubObject(path: path, payload: payload)
    }

    /// `reportFailure` is off for a check that repeats through an outage, which would otherwise push
    /// everything else out of the 40-line log.
    func getHubObject(path: String, reportFailure: Bool = true) async -> [String: Any]? {
        await requestHubObject(path: path, payload: nil, reportFailure: reportFailure)
    }

    func getHubArray(path: String) async -> [[String: Any]]? {
        guard let url = URL(string: "\(hubServerBaseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let array = json as? [[String: Any]] else {
                reportHubError((json as? [String: Any])?["error"] as? String ?? "Local Hub did not return an app list.", path: path)
                return nil
            }
            lastHubError = nil
            return array
        } catch is CancellationError { return nil }
        catch { reportHubError("The Hub app list could not be read: \(error.localizedDescription)", path: path); return nil }
    }

    private func requestHubObject(path: String, payload: [String: Any]?, retryAuthentication: Bool = true,
                                  reportFailure: Bool = true) async -> [String: Any]? {
        guard let url = URL(string: "\(hubServerBaseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = payload == nil ? 5 : 180
        request.setValue(hubBaseOrigin, forHTTPHeaderField: "Origin")
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(hubApiToken, forHTTPHeaderField: "x-hub-token")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
            catch { reportHubError("Request could not be encoded.", path: path); return nil }
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Regression: a restarted service keeps GET working while its previous token expires.
            // Only retry after an explicit auth rejection, before the operation was admitted.
            if payload != nil, retryAuthentication, let http = response as? HTTPURLResponse,
               http.statusCode == 401 || http.statusCode == 403 {
                invalidateHubConnection("Refreshing the model service connection after restart.")
                await probeHubServer()
                guard isHubServerOnline else { return nil }
                return await requestHubObject(path: path, payload: payload, retryAuthentication: false)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object, (!LocalHubContract.responseHasError(object) ||
                    (path.hasPrefix("/api/models/checks") && object["records"] is [String: Any] && object["running"] is Bool)) else {
                let message = object?["error"] as? String ?? object?["detail"] as? String ?? "Local Hub rejected the request or returned an unexpected response."
                if reportFailure { reportHubError(message, path: path) }
                return nil
            }
            lastHubError = nil
            return object
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            // A cancelled URLSession request throws this, not CancellationError, and Stop is what
            // cancels one. It is not a Hub failure.
            return nil
        } catch {
            if reportFailure { reportHubError("Local Hub could not complete the request: \(error.localizedDescription)", path: path) }
            return nil
        }
    }

    private func reportHubError(_ message: String, path: String) {
        lastHubError = message
        logAction(mode: "HUB ERROR", summary: "Local Hub action failed", detail: message)
        ActionFeedbackCenter.shared.record(button: "Local Hub action", command: path, outcome: message, status: .warning)
    }

    private var hubBaseOrigin: String { hubServerBaseURL }

    // MARK: - Run Task or Routine via Local Hub Server OR In-Process macOS 27 FoundationModels

    /// True from the moment a Hub run is asked for until its receipt is final.
    var isStartingHubTask: Bool { ComputerRunCenter.shared.ledger.usesHub }

    func requestHubTask() {
        ComputerRunCenter.shared.launch(.hubTask) { token in await self.startHubTask(token: token) }
    }

    func requestSavedRoutine(_ routine: LocalHubRoutine) {
        ComputerRunCenter.shared.launch(.hubRoutine) { token in await self.runSavedRoutine(routine, token: token) }
    }

    /// What a failed step reports. A step that ended because of Stop is not a Hub failure.
    private func startFailure(_ token: ComputerRunToken, _ fallback: String) -> String {
        ComputerRunCenter.shared.ledger.mayContinue(token) ? (lastHubError ?? fallback) : ComputerRunLedger.stoppedBeforeStart
    }

    /// Asked after every awaited step of a start, because Stop or a return to dry run can arrive
    /// during any of them.
    private func haltedBeforeStart(_ token: ComputerRunToken) -> Bool {
        guard case .halted(let reason) = ComputerRunCenter.shared.ledger.hubStartCheck(token, mode: mode) else { return false }
        taskStatus = reason
        logAction(mode: "BLOCKED", summary: "Scoped task not started", detail: reason)
        return true
    }

    private func startHubTask(token: ComputerRunToken) async {
        let center = ComputerRunCenter.shared
        let payload: [String: Any]
        do {
            payload = try LocalHubContract.taskPayload(goal: taskGoal, scope: taskScope, url: taskURL,
                app: taskTargetApp, window: taskTargetWindow, folder: taskFolderID, allowOverwrite: taskAllowOverwrite,
                appID: taskHubAppID, knownAppIDs: Set(hubApps.map(\.id)),
                checkKind: taskCheckKind, checkPath: taskCheckPath, expected: taskExpectedText, note: taskExpectedNote)
        } catch {
            taskStatus = error.localizedDescription
            reportHubError(taskStatus, path: "/api/tasks/run")
            return
        }
        guard !isDryRun else {
            taskStatus = "Preview only. No model was loaded and no task was sent. Arm Live Execution to run this scoped task."
            logAction(mode: "DRY-RUN", summary: "Scoped task preview", detail: taskStatus)
            ActionFeedbackCenter.shared.record(button: "Run task", command: "POST /api/tasks/run (not sent)", outcome: taskStatus, status: .simulated)
            return
        }
        guard let selected = models.first(where: { $0.id == taskModelID }), selected.supported,
              selected.taskScopes?.contains(taskScope) ?? true else {
            taskStatus = "Choose a model that supports this task scope. Screenshot target finders run in Model Lab."
            return
        }
        guard (4...120).contains(taskMaxSteps) else { taskStatus = "Choose a step limit from 4 to 120."; return }
        guard await postToHubServer(path: "/api/settings", payload: ["step_limit": taskMaxSteps]) != nil else {
            taskStatus = startFailure(token, "The step limit was not accepted."); return
        }
        if haltedBeforeStart(token) { return }
        guard let runtime = await postToHubServer(path: "/api/models/load", payload: ["id": taskModelID]),
              LocalHubContract.runtimeReady(runtime, modelID: taskModelID) else {
            taskStatus = startFailure(token, "The selected model did not become ready. No task was started."); return
        }
        ComputerUseStudioController.shared.applyRuntimeReceipt(runtime)
        if haltedBeforeStart(token) { return }
        guard let response = await postToHubServer(path: "/api/tasks/run", payload: payload),
              let id = response["id"] as? String else {
            taskStatus = startFailure(token, "The task was not accepted."); return
        }
        center.attachHubRun(id, to: token)
        selectedRunID = id
        taskStatus = "Task accepted by Local Hub. Completion is unverified until its result check passes."
        ActionFeedbackCenter.shared.record(button: "Run scoped task", command: "POST /api/tasks/run", outcome: taskStatus, status: .running)
        logAction(mode: "HUB", summary: "Started scoped task \(id.prefix(8))", detail: taskStatus)
        await observeHubRun(id, token: token)
    }

    /// Watches until `ComputerHubRunWatch` has an answer, so Stop stays up as long as the run does.
    private func observeHubRun(_ id: String, token: ComputerRunToken) async {
        var poll = 0, failedChecks = 0, idleChecks = 0
        var notice: String?
        selectedRunID = id
        while true {
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            poll += 1
            loadRuns()
            let receipt = runs.first { $0.id == id }
            // The receipt on disk is the answer. The Hub is asked only to catch one that has gone quiet.
            if poll.isMultiple(of: 5), receipt.map({ ComputerHubRunWatch.openStatuses.contains($0.status) }) ?? true {
                if let status = await getHubObject(path: "/api/status", reportFailure: false) {
                    failedChecks = 0
                    idleChecks = status["busy"] as? Bool == false ? idleChecks + 1 : 0
                } else {
                    failedChecks += 1
                }
            }
            let stopped = ComputerRunCenter.shared.stopRequestedAt.map { Date().timeIntervalSince($0) }
            switch ComputerHubRunWatch.update(receiptStatus: receipt?.status, failedStatusChecks: failedChecks,
                                              idleStatusChecks: idleChecks, secondsSinceStop: stopped) {
            case .keepWatching:
                if notice != nil {
                    notice = nil
                    taskStatus = ComputerHubRunWatch.answeringAgain
                    logAction(mode: "HUB", summary: "Run \(id.prefix(8)) confirmed", detail: taskStatus)
                }
            case .unconfirmed(let message):
                // Said once, because this can last as long as an outage does.
                guard message != notice else { continue }
                notice = message
                reportUnconfirmedRun(id, message)
            case .finished:
                guard let run = receipt else { return }
                taskStatus = "Task \(run.status). \(run.verificationSummary)"
                ActionFeedbackCenter.shared.record(button: "Local Hub run", command: "Read saved run receipt", outcome: taskStatus,
                    status: run.verificationPassed == true ? .completed : .warning)
                return
            case .endedWithoutReceipt(let message):
                reportUnconfirmedRun(id, message)
                return
            }
        }
    }

    private func reportUnconfirmedRun(_ id: String, _ message: String) {
        taskStatus = message
        logAction(mode: "HUB ERROR", summary: "Run \(id.prefix(8)) not confirmed", detail: message)
        ActionFeedbackCenter.shared.record(button: "Local Hub run", command: "GET /api/status", outcome: message, status: .warning)
    }

    /// Stop's Hub half. It runs outside the cancelled tasks, so its own requests go through.
    func sendHubStop(startInFlight: Bool) async {
        if await postToHubServer(path: "/api/tasks/stop", payload: [:]) == nil {
            taskStatus = "Local Hub did not take the Stop. \(lastHubError ?? "It may not be running.") Open Local Hub and stop the run there."
            ActionFeedbackCenter.shared.record(button: "Stop", command: "POST /api/tasks/stop", outcome: taskStatus, status: .warning)
            return
        }
        guard startInFlight else { return }
        // The Hub can start a run from a request the app has already given up on, after the first
        // stop found nothing to stop. Chosen, not measured: one second covers a request in transit.
        try? await Task.sleep(for: .seconds(1))
        if await getHubObject(path: "/api/status")?["busy"] as? Bool == true {
            _ = await postToHubServer(path: "/api/tasks/stop", payload: [:])
            await probeHubServer()
        }
    }

    private func runSavedRoutine(_ routine: LocalHubRoutine, token: ComputerRunToken) async {
        guard !isDryRun else {
            taskStatus = "Preview only: \(routine.demonstration.count) saved steps with its saved inputs. Arm Live Execution to run this routine."
            logAction(mode: "DRY-RUN", summary: "Routine preview: \(routine.name)", detail: taskStatus)
            ActionFeedbackCenter.shared.record(button: "Run saved routine", command: "POST /api/routines/run (not sent)", outcome: taskStatus, status: .simulated)
            return
        }
        guard let response = await postToHubServer(path: "/api/routines/run", payload: ["id": routine.id, "parameters": routineParameterEdits[routine.id] ?? routine.parameters]),
              let id = response["id"] as? String else {
            taskStatus = startFailure(token, "The routine was not accepted."); return
        }
        ComputerRunCenter.shared.attachHubRun(id, to: token)
        selectedRunID = id
        taskStatus = "Saved routine accepted. It will replay its saved actions and run its original completion check."
        ActionFeedbackCenter.shared.record(button: "Run saved routine", command: "POST /api/routines/run", outcome: taskStatus, status: .running)
        await observeHubRun(id, token: token)
    }

    // MARK: - macOS 27 FoundationModels Telemetry & Native Tool-Calling Task Runner

    func refreshMacOS27FoundationModelsTelemetry() {
        let model = SystemLanguageModel.default
        if #available(macOS 27.0, *) {
            fmVariantName = model.variant.displayName
            fmContextSize = model.contextSize
            var caps: [String] = []
            if model.capabilities.contains(.guidedGeneration) { caps.append("GuidedGeneration") }
            if model.capabilities.contains(.toolCalling) { caps.append("ToolCalling") }
            if model.capabilities.contains(.reasoning) { caps.append("Reasoning") }
            if model.capabilities.contains(.vision) { caps.append("Vision") }
            fmCapabilities = caps

            let pcc = PrivateCloudComputeLanguageModel()
            pccAvailable = pcc.isAvailable
        } else {
            fmVariantName = "SystemLanguageModel"
            fmContextSize = 4096
            fmCapabilities = ["GuidedGeneration", "ToolCalling"]
            pccAvailable = false
        }
    }

    func runAppleFoundationModelsSelfTest() async {
        isRunningFMTask = true
        defer { isRunningFMTask = false }

        do {
            let session = LanguageModelSession(
                instructions: "Return ONLY a single JSON object with keys \"thinking\", \"tool\", and \"arguments\". Call tool \"add\" with a=19 and b=3."
            )
            let response: String
            if #available(macOS 27.0, *) {
                let ctx = ContextOptions(includeSchemaInPrompt: false, reasoningLevel: .light)
                let res = try await session.respond(to: "Add 19 and 3 using the add tool.", contextOptions: ctx)
                response = res.content
                fmLastSessionInputTokens = session.usage.input.totalTokenCount
                fmLastSessionCachedTokens = session.usage.input.cachedTokenCount
                fmLastSessionOutputTokens = session.usage.output.totalTokenCount
            } else {
                let res = try await session.respond(to: "Add 19 and 3 using the add tool.")
                response = res.content
            }

            fmTaskOutput = response.replacingOccurrences(of: "—", with: " - ")
            logAction(
                mode: "FM-27",
                summary: "Apple Foundation Models tool-call test passed (\(fmVariantName))",
                detail: "Input: \(fmLastSessionInputTokens) tok (cached: \(fmLastSessionCachedTokens)) · Output: \(fmLastSessionOutputTokens) tok"
            )
        } catch {
            fmTaskOutput = "FoundationModels self-test error: \(error.localizedDescription)"
        }
    }

    func runInProcessFoundationModelsTask(goal: String) async {
        isRunningFMTask = true
        defer { isRunningFMTask = false }

        do {
            if #available(macOS 27.0, *) {
                let spotlightTool = SpotlightSearchTool(configuration: .init(sources: [.coreSpotlight, .files]))
                let ocrTool = OCRTool()
                let barcodeTool = BarcodeReaderTool()
                let session = LanguageModelSession(
                    tools: [spotlightTool, ocrTool, barcodeTool],
                    instructions: """
                    You are OpenCore's on-device macOS 27 Automation & Computer Control assistant.
                    Use SpotlightSearchTool, OCRTool, or BarcodeReaderTool when helpful, and provide a concise, verified execution plan and result without em dashes.
                    """
                )
                let ctx = ContextOptions(includeSchemaInPrompt: false, reasoningLevel: .light)
                let res = try await session.respond(to: goal, contextOptions: ctx)
                fmTaskOutput = res.content.replacingOccurrences(of: "—", with: " - ")
                fmLastSessionInputTokens = session.usage.input.totalTokenCount
                fmLastSessionCachedTokens = session.usage.input.cachedTokenCount
                fmLastSessionOutputTokens = session.usage.output.totalTokenCount
            } else {
                let session = LanguageModelSession()
                let res = try await session.respond(to: goal)
                fmTaskOutput = res.content.replacingOccurrences(of: "—", with: " - ")
            }
            logAction(
                mode: "FM-27",
                summary: "Executed on-device FoundationModels task (\(fmVariantName))",
                detail: "Tokens: in=\(fmLastSessionInputTokens) (cached=\(fmLastSessionCachedTokens)), out=\(fmLastSessionOutputTokens)"
            )
        } catch {
            fmTaskOutput = "On-device FoundationModels error: \(error.localizedDescription)"
        }
    }

    // MARK: - Automation Profile Discovery

    func loadAutomationProfiles() {
        guard let automationRootPath else {
            automationProfiles = []
            return
        }
        let profilesDir = (automationRootPath as NSString).appendingPathComponent("config/profiles")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: profilesDir) else {
            automationProfiles = [
                AutomationProfileSummary(
                    id: "default",
                    name: "default",
                    filePath: "\(automationRootPath)/config/profiles/default.yaml",
                    tickHz: 8.0,
                    downscale: 0.5,
                    matchThreshold: 0.85,
                    dryRun: true,
                    templateCount: 0
                )
            ]
            return
        }

        var loaded: [AutomationProfileSummary] = []
        for file in files where file.hasSuffix(".yaml") || file.hasSuffix(".yml") {
            let fullPath = (profilesDir as NSString).appendingPathComponent(file)
            let raw = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
            let name = parseYAMLString(raw, key: "name") ?? (file as NSString).deletingPathExtension
            let tickHz = Double(parseYAMLString(raw, key: "tick_hz") ?? "8.0") ?? 8.0
            let downscale = Double(parseYAMLString(raw, key: "downscale") ?? "0.5") ?? 0.5
            let threshold = Double(parseYAMLString(raw, key: "match_threshold") ?? "0.85") ?? 0.85
            let dryRunStr = parseYAMLString(raw, key: "dry_run") ?? "true"
            let dryRun = dryRunStr.lowercased() != "false"

            let templatesRel = parseYAMLString(raw, key: "templates_dir") ?? "assets/templates"
            let templatesPath = (automationRootPath as NSString).appendingPathComponent(templatesRel)
            let templateFiles = (try? fm.contentsOfDirectory(atPath: templatesPath))?.filter {
                $0.hasSuffix(".png") || $0.hasSuffix(".jpg")
            } ?? []

            loaded.append(
                AutomationProfileSummary(
                    id: file,
                    name: name,
                    filePath: fullPath,
                    tickHz: tickHz,
                    downscale: downscale,
                    matchThreshold: threshold,
                    dryRun: dryRun,
                    templateCount: templateFiles.count
                )
            )
        }
        automationProfiles = loaded.sorted { $0.name < $1.name }
    }

    private func parseYAMLString(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("\(key):") else { continue }
            let val = trimmed.dropFirst(key.count + 1)
                .split(separator: "#").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return val
        }
        return nil
    }

    // MARK: - Native Screen Capture + Apple Vision UI Element Detection

    func captureScreenAndAnalyze() async {
        guard !isAnalyzingScreen else { return }
        capturedImage = nil
        capturedImagePath = nil
        detectedElements = []
        lastScanTime = nil
        screenSummaryText = "Capturing the main display…"
        isAnalyzingScreen = true
        defer { isAnalyzingScreen = false }

        let mainID = CGMainDisplayID()
        let screenFrame = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID }?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        screenLogicalSize = screenFrame.size

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-screen-\(UUID().uuidString).png")
        var cgImg: CGImage?

        if let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let mainDisplay = shareable.displays.first(where: { $0.displayID == mainID }) {
            let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = mainDisplay.width
            config.height = mainDisplay.height
            cgImg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }

        if cgImg == nil {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-C", tempURL.path]
            do { try proc.run(); proc.waitUntilExit() } catch {
                logAction(mode: "VISION", summary: "Screen capture failed", detail: error.localizedDescription)
                return
            }
            if proc.terminationStatus == 0, let nsImg = NSImage(contentsOf: tempURL),
               let tiff = nsImg.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                cgImg = rep.cgImage
            }
        } else if let cgImg {
            let rep = NSBitmapImageRep(cgImage: cgImg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: tempURL)
            }
        }

        guard let finalCGImage = cgImg else {
            logAction(mode: "VISION", summary: "Screen capture requires Screen Recording permission", detail: "Grant OpenCore Screen Recording access in System Settings -> Privacy & Security -> Screen & System Audio Recording.")
            screenScanProblem = ComputerStudioDiagnosis.screenScanDenied()
            return
        }

        capturedImage = NSImage(cgImage: finalCGImage, size: screenFrame.size)
        capturedImagePath = tempURL.path

        let logicalSize = screenFrame.size
        let elements = await Task.detached(priority: .userInitiated) { () -> [DetectedScreenElement] in
            var results: [DetectedScreenElement] = []

            let textReq = VNRecognizeTextRequest()
            textReq.recognitionLevel = .accurate
            textReq.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: finalCGImage, options: [:])
            try? handler.perform([textReq])

            let observations = textReq.results ?? []
            var idx = 1
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let str = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard str.count >= 2 else { continue }

                let box = obs.boundingBox
                let topLeftNorm = CGRect(
                    x: box.minX,
                    y: 1.0 - box.maxY,
                    width: box.width,
                    height: box.height
                )
                let centerPt = CGPoint(
                    x: topLeftNorm.midX * logicalSize.width,
                    y: topLeftNorm.midY * logicalSize.height
                )
                let ptSize = CGSize(
                    width: topLeftNorm.width * logicalSize.width,
                    height: topLeftNorm.height * logicalSize.height
                )

                results.append(
                    DetectedScreenElement(
                        id: UUID(),
                        index: idx,
                        label: str,
                        kind: .textControl,
                        normalizedRect: topLeftNorm,
                        screenPoint: centerPt,
                        screenSize: ptSize,
                        confidence: candidate.confidence
                    )
                )
                idx += 1
                if idx > 140 { break }
            }
            return results
        }.value

        detectedElements = elements
        screenScanProblem = elements.isEmpty ? ComputerStudioDiagnosis.screenScanEmpty() : nil
        selectedElementID = elements.first?.id
        lastScanTime = Date()
        screenSummaryText = "Detected \(elements.count) OCR text candidates across \(Int(screenFrame.width))x\(Int(screenFrame.height)) pt display."
        logAction(
            mode: "VISION",
            summary: "Scanned display (\(Int(screenFrame.width))x\(Int(screenFrame.height)) pt): \(elements.count) OCR text candidates mapped",
            detail: elements.prefix(6).map { "[\($0.index)] '\($0.label)' @ \($0.coordinateBadge)" }.joined(separator: " · ")
        )
    }

    // MARK: - On-Device AI Task Planner (`AutomationOrchestrator`)

    func planTaskWithOnDeviceFM(goal: String) async {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }

        if detectedElements.isEmpty {
            await captureScreenAndAnalyze()
        }

        isPlanningTask = true
        defer { isPlanningTask = false }
        plannerProblem = nil
        // A failed scan left nothing to point at, and the model still answered: `pointerPlan` only
        // checks that a point is on screen, so an invented one became a step Click Now would run.
        guard !detectedElements.isEmpty else {
            plannerProblem = screenScanProblem ?? ComputerStudioDiagnosis.screenScanEmpty()
            return
        }

        let goalWords = Set(trimmedGoal.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let rankedElements = detectedElements.sorted { lhs, rhs in
            let lHits = goalWords.filter { lhs.label.lowercased().contains($0) }.count
            let rHits = goalWords.filter { rhs.label.lowercased().contains($0) }.count
            if lHits != rHits { return lHits > rHits }
            return lhs.confidence > rhs.confidence
        }

        let candidateLines = rankedElements.prefix(45).map { el in
            "[\(el.index)] label=\"\(el.label)\" center=(\(Int(el.screenPoint.x)), \(Int(el.screenPoint.y)))"
        }.joined(separator: "\n")

        let prompt = """
        You are OpenCore's macOS Computer Control & Screen Automation Planner.
        Given the user's goal and the live screen UI elements below (with exact macOS screen coordinates), return 1 to 3 concrete steps.
        Format each line strictly as:
        STEP <number> | <click|double_click|move> | <x> | <y> | <target_label> | <reasoning>
        Only pointer previews are supported. Never output type, scroll or a substitute click for an unsupported action.
        Do not use em dashes.

        User Goal: \(trimmedGoal)
        Screen Size: \(Int(screenLogicalSize.width))x\(Int(screenLogicalSize.height))
        Detected UI Elements:
        \(candidateLines)
        """

        let rawOutput: String
        do {
            let session = LanguageModelSession(instructions: "Return only the requested pointer preview format. Never substitute a click for typing or scrolling.")
            let response = try await session.respond(to: prompt)
            rawOutput = response.content
            try Task.checkCancellation()
        } catch {
            plannedSteps = []
            if Task.isCancelled {
                logAction(mode: "PLANNER", summary: "Planning stopped", detail: "Stopped before a plan was returned.")
            } else {
                plannerProblem = ComputerStudioDiagnosis.plannerFailed(error.localizedDescription)
                logAction(mode: "PLANNER", summary: "Pointer planning failed", detail: error.localizedDescription)
            }
            return
        }

        let parsed = LocalHubContract.pointerPlan(rawOutput, screenSize: screenLogicalSize)
        if parsed.isEmpty {
            plannerProblem = ComputerStudioDiagnosis.plannerEmpty()
            logAction(mode: "PLANNER", summary: "No supported pointer plan returned", detail: "Typing and scrolling are unavailable in this preview. No fallback clicks were invented.")
        }

        plannedSteps = parsed
        if let first = parsed.first {
            targetReticlePoint = CGPoint(x: first.x, y: first.y)
        }
        logAction(
            mode: "PLANNER",
            summary: "Planned \(parsed.count) automation step(s) for '\(trimmedGoal)'",
            detail: parsed.map { "#\($0.stepNumber) \($0.action.uppercased()) '\($0.targetLabel)' @ (\($0.x), \($0.y))" }.joined(separator: " -> ")
        )
    }

    // MARK: - Native CGEvent Execution (with Dry-Run Guardrail)

    @discardableResult
    func previewPointer(action: String, at point: CGPoint, label: String) -> Bool {
        guard let target = LocalHubContract.previewPointer(action: action, at: point, screenSize: screenLogicalSize) else {
            logAction(mode: "BLOCKED", summary: "Invalid pointer preview", detail: "Unsupported action or out-of-bounds coordinates. No input event was sent.")
            return false
        }
        targetReticlePoint = target
        logAction(mode: "DRY-RUN", summary: "Preview \(action) on '\(label)' at (\(Int(target.x)), \(Int(target.y)))",
            detail: "Reticle and log only. This preview cannot send mouse or keyboard events, regardless of the Live Execution switch.")
        return true
    }

    func executeClick(at point: CGPoint, label: String, doubleClick: Bool = false) {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < screenLogicalSize.width, point.y < screenLogicalSize.height else {
            logAction(mode: "BLOCKED", summary: "Invalid screen target", detail: "Capture the screen again before using this target.")
            return
        }
        guard isDryRun || !ComputerRunCenter.shared.ledger.isActive else {
            logAction(mode: "BLOCKED", summary: "A run is in progress", detail: "No input event was sent. Stop the run or let it finish first.")
            return
        }
        guard isDryRun || AXIsProcessTrusted() else {
            logAction(mode: "BLOCKED", summary: "Accessibility permission is required", detail: "No input event was sent.")
            return
        }
        let clamped = point
        targetReticlePoint = clamped

        if isDryRun {
            logAction(
                mode: "DRY-RUN",
                summary: "Simulated \(doubleClick ? "Double-Click" : "Click") on '\(label)' at (\(Int(clamped.x)), \(Int(clamped.y)))",
                detail: "Dry-Run Safety Lock is ON. No physical mouse click was sent to macOS. Toggle 'Live Execution' to dispatch real CGEvent clicks."
            )
            return
        }

        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: clamped, mouseButton: .left),
              let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clamped, mouseButton: .left),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clamped, mouseButton: .left) else {
            return
        }

        moveEvent.post(tap: .cghidEventTap)
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)

        if doubleClick {
            downEvent.setIntegerValueField(.mouseEventClickState, value: 2)
            upEvent.setIntegerValueField(.mouseEventClickState, value: 2)
            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)
        }

        logAction(
            mode: "LIVE",
            summary: "Executed \(doubleClick ? "Double-Click" : "Click") on '\(label)' at (\(Int(clamped.x)), \(Int(clamped.y)))",
            detail: "Dispatched CGEvent(.leftMouseDown/.leftMouseUp) to cghidEventTap."
        )
    }

    func executeMoveCursor(to point: CGPoint, label: String) {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < screenLogicalSize.width, point.y < screenLogicalSize.height else {
            logAction(mode: "BLOCKED", summary: "Invalid screen target", detail: "Capture the screen again before using this target.")
            return
        }
        guard isDryRun || !ComputerRunCenter.shared.ledger.isActive else {
            logAction(mode: "BLOCKED", summary: "A run is in progress", detail: "No input event was sent. Stop the run or let it finish first.")
            return
        }
        guard isDryRun || AXIsProcessTrusted() else {
            logAction(mode: "BLOCKED", summary: "Accessibility permission is required", detail: "No input event was sent.")
            return
        }
        let clamped = point
        targetReticlePoint = clamped

        if isDryRun {
            logAction(
                mode: "DRY-RUN",
                summary: "Simulated Move Cursor to '\(label)' at (\(Int(clamped.x)), \(Int(clamped.y)))",
                detail: "Reticle updated on Visual Screen Canvas."
            )
            return
        }

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: clamped, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
            logAction(
                mode: "LIVE",
                summary: "Moved macOS cursor to '\(label)' at (\(Int(clamped.x)), \(Int(clamped.y)))",
                detail: "Dispatched CGEvent(.mouseMoved) to cghidEventTap."
            )
        }
    }

    func executePlannedSteps() {
        for step in plannedSteps.prefix(3) {
            guard previewPointer(action: step.action, at: CGPoint(x: step.x, y: step.y), label: step.targetLabel) else { return }
        }
    }

    func logAction(mode: String, summary: String, detail: String) {
        executionLogs.insert(
            AutomationExecutionLog(timestamp: Date(), mode: mode, summary: summary, detail: detail),
            at: 0
        )
        if executionLogs.count > 40 {
            executionLogs.removeLast(executionLogs.count - 40)
        }
    }
}

// MARK: - Everything running, and the one Stop

/// Separate from `ComputerControlManager` because the window's Stop bar and menu item live for the
/// whole app, and creating the manager reads the Hub's files and asks it for a token.
@MainActor
@Observable
final class ComputerRunCenter {
    static let shared = ComputerRunCenter()

    private(set) var ledger = ComputerRunLedger()
    private(set) var stopRequestedAt: Date?
    @ObservationIgnored private var tasks: [ComputerRunToken: Task<Void, Never>] = [:]
    @ObservationIgnored private var globalStopMonitor: Any?

    private init() {}

    func launch(_ kind: ComputerRunKind, _ body: @escaping @MainActor (ComputerRunToken) async -> Void) {
        switch ledger.begin(kind) {
        case .refused(let reason):
            ActionFeedbackCenter.shared.record(button: kind.rawValue, command: "Not started", outcome: reason, status: .warning)
            ComputerControlManager.shared.taskStatus = reason
            ComputerControlManager.shared.logAction(mode: "BLOCKED", summary: "\(kind.rawValue) not started", detail: reason)
        case .started(let token):
            track(token, body)
        }
    }

    func adoptHubRun(_ id: String, _ body: @escaping @MainActor (ComputerRunToken) async -> Void) {
        guard let token = ledger.adoptHubRun(id) else { return }
        track(token, body)
    }

    func attachHubRun(_ id: String, to token: ComputerRunToken) {
        ledger.attachHubRun(id, to: token)
    }

    /// Halts what is running and cancels what is queued. An action already sent can't be recalled,
    /// and the message says so.
    func stop() {
        guard ledger.isActive else { return }
        let plan = ledger.requestStop()
        stopRequestedAt = stopRequestedAt ?? Date()
        for token in plan.cancel { tasks[token]?.cancel() }
        let studio = ComputerUseStudioController.shared
        studio.isRunningAutonomousLoop = false
        studio.isReplayingLoop = false
        let ctrl = ComputerControlManager.shared
        let message = "Stop requested. Queued steps are canceled. An action already in progress may have taken effect."
        ctrl.taskStatus = message
        ctrl.logAction(mode: "STOP", summary: "Stop requested", detail: message)
        ActionFeedbackCenter.shared.record(button: "Stop", command: plan.postHubStop ? "POST /api/tasks/stop" : "Cancel local run", outcome: message, status: .warning)
        if plan.postHubStop {
            Task { await ctrl.sendHubStop(startInFlight: plan.hubStartInFlight) }
        }
    }

    private func track(_ token: ComputerRunToken, _ body: @escaping @MainActor (ComputerRunToken) async -> Void) {
        tasks[token] = Task { [weak self] in
            await body(token)
            self?.finish(token)
        }
        updateGlobalStopMonitor()
    }

    private func finish(_ token: ComputerRunToken) {
        ledger.finish(token)
        tasks[token] = nil
        if !ledger.isActive { stopRequestedAt = nil }
        updateGlobalStopMonitor()
    }

    /// A run can put another app in front, and then the menu's ⌘. goes to that app. This hears the
    /// same keys there, for as long as a run lasts. AppKit delivers key events to a global monitor
    /// only with Accessibility allowed, so without it the shortcut works only in OpenCore's window.
    private func updateGlobalStopMonitor() {
        if ledger.isActive, globalStopMonitor == nil {
            globalStopMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: Self.stopChordHandler())
        } else if !ledger.isActive, let monitor = globalStopMonitor {
            NSEvent.removeMonitor(monitor)
            globalStopMonitor = nil
        }
    }

    /// Built outside the actor. AppKit's header doesn't mark this block Sendable, so a closure
    /// written in a `@MainActor` method would inherit the actor and check it at run time.
    private nonisolated static func stopChordHandler() -> @Sendable (NSEvent) -> Void {
        { event in
            let keys = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard keys == .command, event.charactersIgnoringModifiers == "." else { return }
            Task { @MainActor in ComputerRunCenter.shared.stop() }
        }
    }
}

/// Pinned above every section, so a run's Stop can't scroll away or be left behind by navigation.
struct ComputerRunStopBar: View {
    @State private var center = ComputerRunCenter.shared

    var body: some View {
        if let line = center.ledger.statusLine {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(line).font(.callout.weight(.semibold))
                Spacer()
                Button {
                    center.stop()
                } label: {
                    Label(center.ledger.isStopping ? "Stop Again (⌘.)" : "Stop (⌘.)", systemImage: "stop.fill")
                        .font(.callout.weight(.bold))
                }
                .openCoreGlassButton(prominent: true, tint: Pastel.rose)
                .accessibilityHint("Halts the running sequence and cancels what is queued.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Pastel.rose.opacity(0.14))
        }
    }
}

/// Added to the app menu. `.command` plus "." is the Mac's usual stop key, and a menu item works
/// from any section and with the focus in a text field, which a button's shortcut may not.
struct ComputerRunStopCommand: View {
    @State private var center = ComputerRunCenter.shared

    var body: some View {
        Button("Stop Computer Use") { center.stop() }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!center.ledger.isActive)
    }
}

// MARK: - Computer Control & Local Automation Hub View (⌘5)

enum LocalHubStudioTab: String, CaseIterable, Identifiable {
    case watchAndAutonomous = "1. Autonomous Agent & Watch-Me"
    case tasksAndRoutines = "2. Scoped Tasks & Saved Routines"
    case visionAndApps = "3. Screen X-Ray & Learned Apps"
    case historyAndGuide = "4. Run History, Receipts & Guide"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .watchAndAutonomous: return "sparkles.tv.fill"
        case .tasksAndRoutines: return "play.rectangle.on.rectangle.fill"
        case .visionAndApps: return "viewfinder.rectangular"
        case .historyAndGuide: return "checkmark.seal.text.page.fill"
        }
    }

    var accent: Color {
        switch self {
        case .watchAndAutonomous: return Pastel.mint
        case .tasksAndRoutines: return Pastel.sky
        case .visionAndApps: return Pastel.periwinkle
        case .historyAndGuide: return Pastel.aqua
        }
    }
}

struct ComputerControlView: View {
    @Environment(\.appModel) private var model
    @State private var ctrl = ComputerControlManager.shared
    @State private var mem = UnifiedMemoryMonitor.shared
    @State private var activeTab: LocalHubStudioTab = .watchAndAutonomous
    @State private var taskGoalInput = ""
    @State private var elementSearch = ""
    @State private var showAllBoundingBoxes = AppSettings.shared.automationShowBoundingBoxes
    @State private var appSettings = AppSettings.shared
    @State private var guideSearch = ""
    @State private var selectedGuideChapter: String = "all"

    private var filteredElements: [DetectedScreenElement] {
        guard !elementSearch.isEmpty else { return ctrl.detectedElements }
        return ctrl.detectedElements.filter {
            $0.label.localizedCaseInsensitiveContains(elementSearch) ||
            $0.coordinateBadge.localizedCaseInsensitiveContains(elementSearch)
        }
    }

    private var filteredGuideEntries: [LocalHubGuideEntry] {
        ctrl.guideEntries.filter { entry in
            let matchesChapter = (selectedGuideChapter == "all" || entry.chapterID == selectedGuideChapter)
            guard matchesChapter else { return false }
            guard !guideSearch.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(guideSearch) ||
                   entry.what.localizedCaseInsensitiveContains(guideSearch) ||
                   entry.when.localizedCaseInsensitiveContains(guideSearch) ||
                   entry.example.localizedCaseInsensitiveContains(guideSearch)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                compactStudioHeader
                studioNotices
                studioTabBar

                switch activeTab {
                case .watchAndAutonomous:
                    WatchAndRepeatAndAutonomousStudioView()
                case .tasksAndRoutines:
                    VStack(alignment: .leading, spacing: 18) {
                        tasksAndRunnerSection
                        routinesAndDemosSection
                    }
                case .visionAndApps:
                    VStack(alignment: .leading, spacing: 18) {
                        visionAutomationSection
                        appsPeekabooAndKnowledgeSection
                    }
                case .historyAndGuide:
                    VStack(alignment: .leading, spacing: 18) {
                        historyAndReceiptsSection
                        settingsAndGuideSection
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Computer Use Studio")
        .alert(ctrl.pendingLiveConfirmation?.title ?? "", isPresented: $ctrl.isConfirmingLive) {
            Button("Stay on Dry Run", role: .cancel) {}
            Button("Arm Live Control", role: .destructive) { ctrl.confirmLiveControl() }
        } message: {
            Text(ctrl.pendingLiveConfirmation?.message ?? "")
        }
        .onChange(of: appSettings.automationShowBoundingBoxes) { _, value in showAllBoundingBoxes = value }
        .onChange(of: showAllBoundingBoxes) { _, value in appSettings.automationShowBoundingBoxes = value }
        .onChange(of: ctrl.taskHubAppID) { _, id in ctrl.selectHubApp(id) }
        .onAppear { consumeRequestedTab() }
        .onChange(of: ctrl.requestedStudioTab) { _, _ in consumeRequestedTab() }
        .task {
            ctrl.reloadAllLocalHubData()
            await ctrl.probeHubServer()
            await ctrl.refreshHubApps()
        }
    }

    private func consumeRequestedTab() {
        guard let requested = ctrl.requestedStudioTab else { return }
        activeTab = requested
        ctrl.requestedStudioTab = nil
    }

    // MARK: - Single Compact Studio Header (Replaces 2 Stacked Giant Banners)

    private var compactStudioHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "viewfinder.rectangular")
                .font(.title2.weight(.bold))
                .foregroundStyle(Pastel.mint)
                .frame(width: 40, height: 40)
                .background(Pastel.mint.opacity(0.15), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Computer Use Studio")
                        .font(.title3.weight(.bold))
                    Text("Task selection: \(ctrl.taskModelID)")
                        .openCorePastelBadge(Pastel.lavender)
                    Text(String(format: "%.1f GiB RAM Free", mem.freeGiB))
                        .openCorePastelBadge(Pastel.mint)
                    Text(ctrl.isHubServerOnline ? "HUB 127.0.0.1:8765 ONLINE" : "LOCAL HUB OFFLINE")
                        .openCorePastelBadge(ctrl.isHubServerOnline ? Pastel.mint : Pastel.butter)
                }
                Text("Preview screen plans, run scoped Local Hub tasks and saved routines, or inspect screen elements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle(isOn: Binding(get: { ctrl.isDryRun }, set: { ctrl.requestMode($0 ? .dryRun : .live) })) {
                Text(ctrl.isDryRun ? "DRY-RUN SAFE" : "LIVE CLICKS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ctrl.isDryRun ? Pastel.mint : Pastel.rose)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                model.navigate(to: .aiModelsRAM)
            } label: {
                Label("AI Models & RAM (⌘6) →", systemImage: "cpu.fill")
                    .font(.caption.weight(.semibold))
            }
            .controlSize(.small)
            .openCoreGlassButton(prominent: true, tint: Pastel.lavender)

            Button {
                Task {
                    if ctrl.isHubServerOnline {
                        await ctrl.probeHubServer()
                    } else {
                        await ctrl.launchLocalHubServerOrApp()
                    }
                }
            } label: {
                Label(
                    ctrl.isStartingServer ? "Starting…" : (ctrl.isHubServerOnline ? "Refresh Hub" : "Start Hub (8765)"),
                    systemImage: ctrl.isHubServerOnline ? "arrow.clockwise" : "play.fill"
                )
                .font(.caption.weight(.semibold))
            }
            .controlSize(.small)
            .openCoreGlassButton(tint: Pastel.sky)
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
    }

    @ViewBuilder
    private var studioNotices: some View {
        if let notice = ctrl.hubNotice {
            Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Pastel.butter)
        }
        if let notice = ctrl.launchNotice {
            Label(notice, systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(Pastel.butter)
        }
    }

    private func metricPill(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 0.8)
        }
    }

    // MARK: - 4-Mode Studio Tab Bar (Liquid Glass)

    private var studioTabBar: some View {
        HStack(spacing: 8) {
            ForEach(LocalHubStudioTab.allCases) { tab in
                let isSelected = activeTab == tab
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon)
                            .foregroundStyle(isSelected ? tab.accent : .secondary)
                        Text(tab.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        isSelected ? tab.accent.opacity(0.20) : Color.primary.opacity(0.05),
                        in: .capsule
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(isSelected ? tab.accent.opacity(0.65) : Color.primary.opacity(0.12), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(isSelected ? "Selected" : "")
            }
        }
        .padding(6)
        .openCoreGlassBar(cornerRadius: 18)
    }

    // MARK: - TAB 1: Tasks & Live Runner (All 5 Scopes + 5 Completion Checks + Practice Form + macOS 27 FM Tools)

    private var tasksAndRunnerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // Left: Task Composer Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Task Composer (All 5 Local Hub Scopes & Independent Checks)", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.headline)
                            .foregroundStyle(Pastel.sky)
                        Spacer()
                        Stepper("Step limit: \(ctrl.taskMaxSteps)", value: $ctrl.taskMaxSteps, in: 4...120)
                            .openCorePastelBadge(Pastel.aqua)
                    }

                    Text("Goal Instruction")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Pastel.ice)
                    TextEditor(text: $ctrl.taskGoal)
                        .font(.system(size: 13))
                        .frame(height: 68)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))

                    // Scope Picker (5 scopes)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Where can it work? (Scope)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.sky)
                        HStack(spacing: 8) {
                            scopeChip(id: "browser", title: "Practice Page", sub: "Safe local form", icon: "globe")
                            scopeChip(id: "scratch", title: "Scratch Folder", sub: "App Support/scratch", icon: "folder.badge.gearshape")
                            scopeChip(id: "folder", title: "Chosen Folder", sub: "Choose explicitly", icon: "folder.fill")
                            scopeChip(id: "computer", title: "Apps", sub: "System Events / AX", icon: "macwindow")
                            scopeChip(id: "desktop", title: "Exact Window", sub: "Peekaboo 4.6.0", icon: "viewfinder")
                        }
                    }

                    if ctrl.taskScope == "folder" {
                        HStack {
                            Button("Choose Work Folder…") { Task { await ctrl.chooseHubFolder() } }
                            Text(ctrl.taskFolderName).font(.caption)
                        }
                    }
                    if ctrl.taskScope == "browser" {
                        TextField("Page to work on", text: $ctrl.taskURL).textFieldStyle(.roundedBorder)
                    }
                    if ctrl.taskCheckKind == "file" {
                        TextField("Relative filename to check", text: $ctrl.taskCheckPath).textFieldStyle(.roundedBorder)
                    }
                    if ctrl.taskCheckKind == "fixture" {
                        TextField("Exact expected saved note", text: $ctrl.taskExpectedNote).textFieldStyle(.roundedBorder)
                    }
                    if !ctrl.taskStatus.isEmpty {
                        Text(ctrl.taskStatus).font(.caption).foregroundStyle(Pastel.butter)
                    }

                    // Model + Completion Check row
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Worker Model")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Pastel.lavender)
                            Picker("Model", selection: Binding(get: {
                                ctrl.models.contains { $0.id == ctrl.taskModelID && $0.supported && ($0.taskScopes?.contains(ctrl.taskScope) ?? true) } ? ctrl.taskModelID : ""
                            }, set: { ctrl.taskModelID = $0 })) {
                                Text("Choose a compatible task model…").tag("")
                                ForEach(ctrl.models.filter { $0.supported && ($0.taskScopes?.contains(ctrl.taskScope) ?? true) }) { m in
                                    Text("\(m.name) (\(m.installed ? "Ready" : "Not Downloaded"))").tag(m.id)
                                }
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Independent Completion Check")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Pastel.mint)
                            Picker("Check", selection: $ctrl.taskCheckKind) {
                                Text("Practice Form File (fixture)").tag("fixture")
                                Text("Saved File on Disk (file)").tag("file")
                                Text("Text on Web Page (page_text)").tag("page_text")
                                Text("Text in macOS App (desktop_text)").tag("desktop_text")
                                Text("No Automatic Check (none)").tag("none")
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Expected Text / Evidence")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Pastel.butter)
                            TextField("e.g. Ada Lovelace", text: $ctrl.taskExpectedText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if ctrl.taskScope == "computer" || ctrl.taskScope == "desktop" {
                        HStack(spacing: 12) {
                            Picker("Allowed app", selection: $ctrl.taskHubAppID) {
                                Text("Choose an installed app").tag("")
                                ForEach(ctrl.hubApps) { app in Text(app.name).tag(app.id) }
                            }
                            Button(ctrl.isRefreshingHubApps ? "Refreshing Apps…" : "Refresh Apps") {
                                Task { await ctrl.refreshHubApps() }
                            }.disabled(ctrl.isRefreshingHubApps)
                            if ctrl.taskScope == "desktop" {
                                Button(ctrl.isFindingHubWindows ? "Finding windows…" : "Find App Windows") {
                                    Task { await ctrl.findHubWindows() }
                                }.disabled(ctrl.isFindingHubWindows)
                                Picker("Window", selection: $ctrl.taskTargetWindow) {
                                    Text("Choose a window").tag("")
                                    ForEach(ctrl.hubWindows) { window in Text(window.title).tag(String(window.id)) }
                                }
                            }
                        }
                    }

                    if ctrl.taskScope == "computer" {
                        Text("Local Hub may control only the selected installed app. It opens that app, observes its windows and checks the result in the window it selects. Choose Exact Window to restrict a task to one already-open window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            ctrl.requestHubTask()
                        } label: {
                            Label(ctrl.isDryRun ? "Preview Scoped Task" : "Run Scoped Task", systemImage: "play.fill")
                                .font(.callout.weight(.bold))
                        }
                        .openCoreGlassButton(prominent: true, tint: Pastel.sky)
                        .disabled(ctrl.isStartingHubTask)

                        Button {
                            ComputerRunCenter.shared.launch(.textAssistance) { _ in
                                await ctrl.runInProcessFoundationModelsTask(goal: ctrl.taskGoal)
                            }
                        } label: {
                            Label(
                                ctrl.isRunningFMTask ? "Running FM-27..." : "Ask Apple Model (Text Assistance)",
                                systemImage: "sparkles"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .openCoreGlassButton(tint: Pastel.lavender)
                        .disabled(ctrl.isRunningFMTask)

                        Spacer()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)

                // Right: Live Practice Form State + macOS 27 FoundationModels Native Tool Box
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Practice Form Receipt (practice-form.json)", systemImage: "doc.text.magnifyingglass")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Pastel.mint)
                            Spacer()
                            Button("Refresh Saved Record") {
                                Task { await ctrl.resetPracticeForm() }
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(tint: Pastel.peach)
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                            GridRow {
                                Text("Saved Name:").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(ctrl.practiceForm.customerName.isEmpty ? "(empty)" : ctrl.practiceForm.customerName)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(Pastel.mint)
                            }
                            GridRow {
                                Text("Notes:").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(ctrl.practiceForm.notes.isEmpty ? "(empty)" : ctrl.practiceForm.notes)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                            GridRow {
                                Text("Submitted At:").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(ctrl.practiceForm.submittedAt.isEmpty ? "Not submitted" : ctrl.practiceForm.submittedAt)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Pastel.aqua)
                            }
                        }
                    }
                    .padding(14)
                    .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("macOS 27 FoundationModels Worker", systemImage: "apple.intelligence")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Pastel.lavender)
                            Spacer()
                            Button("Run Tool Self-Test (19+3)") {
                                Task { await ctrl.runAppleFoundationModelsSelfTest() }
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(tint: Pastel.lavender)
                        }

                        Text("Variant: \(ctrl.fmVariantName) · Context: \(ctrl.fmContextSize) tok · PCC: \(ctrl.pccAvailable ? "Available" : "Local Only")")
                            .font(.caption.monospaced())
                            .foregroundStyle(Pastel.ice)
                        Text("Bridged Tools: SpotlightSearchTool · OCRTool · BarcodeReaderTool")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        if !ctrl.fmTaskOutput.isEmpty {
                            Text(ctrl.fmTaskOutput)
                                .font(.caption.monospaced())
                                .foregroundStyle(Pastel.mint)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(14)
                    .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
                }
                .frame(width: 410)
            }
        }
    }

    private func scopeChip(id: String, title: String, sub: String, icon: String) -> some View {
        let selected = ctrl.taskScope == id
        return Button {
            ctrl.taskScope = id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .foregroundStyle(selected ? Pastel.sky : .secondary)
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                }
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Pastel.sky.opacity(0.20) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Pastel.sky : Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - TAB 2: Models & Publisher Evidence (All 6 Curated Models + Upstream Benchmarks + Serving Profiles)

    private var modelsAndEvidenceSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left list of 6 curated models
            VStack(alignment: .leading, spacing: 10) {
                Text("\(ctrl.models.count) LOCAL MODEL PACKAGES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Pastel.lavender)

                ForEach(ctrl.models) { model in
                    let isSelected = ctrl.selectedModel?.id == model.id
                    Button {
                        ctrl.selectedModelID = model.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.name)
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(model.installed ? "INSTALLED" : "NOT DOWNLOADED")
                                    .openCorePastelBadge(model.installed ? Pastel.mint : Pastel.butter)
                            }
                            HStack(spacing: 8) {
                                Text(model.publisher)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Pastel.sky)
                                Text("· \(model.quantization)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("· \(model.sizeGB == 0 ? "Built-in" : String(format: "%.1f GB", model.sizeGB))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Pastel.aqua)
                            }
                            Text(model.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Pastel.lavender.opacity(0.18) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 11))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(isSelected ? Pastel.lavender : Color.primary.opacity(0.12), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 390)

            // Right detail inspector for selected model
            if let m = ctrl.selectedModel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(m.name)
                                    .font(.title3.weight(.bold))
                                Text(m.backend)
                                    .openCorePastelBadge(Pastel.lavender)
                                Text(m.license)
                                    .openCorePastelBadge(Pastel.sky)
                                if let passed = m.toolTestPassed {
                                    Text(passed ? "TOOL TEST PASSED" : "TOOL TEST FAILED")
                                        .openCorePastelBadge(passed ? Pastel.mint : Pastel.rose)
                                }
                            }
                            Text("\(m.repo) · \(m.upstreamHeadline)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = URL(string: m.url), !m.url.isEmpty {
                            Link(destination: url) {
                                Label("Model Card", systemImage: "arrow.up.right.square")
                                    .font(.caption.weight(.semibold))
                            }
                            .openCoreGlassButton(tint: Pastel.sky)
                        }
                    }

                    ModelSkillResultsView(modelID: m.id)

                    // Strengths & Limits
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("STRENGTHS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.mint)
                            ForEach(m.strengths, id: \.self) { s in
                                Label(s, systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 10, tint: Pastel.mint)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("KNOWN LIMITS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.peach)
                            ForEach(m.limits, id: \.self) { l in
                                Label(l, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 10, tint: Pastel.peach)
                    }

                    // Publisher Benchmarks & Sampling Recipe (`catalog/upstream.json`)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PUBLISHED BENCHMARKS (catalog/upstream.json)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.sky)
                            if m.upstreamBenchmarks.isEmpty {
                                Text(m.verified ? "Hub diagnostic recorded as passed: \(m.toolTestNote)" : "No passed Hub diagnostic recorded for this model.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(m.upstreamBenchmarks, id: \.0) { k, v in
                                    HStack {
                                        Text(k).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(v).font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.sky)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 10, tint: Pastel.sky)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("PUBLISHER SAMPLING & PARSER RECIPE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.lavender)
                            HStack {
                                Text("Architecture:").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text(m.upstreamArchitecture).font(.caption.monospaced().weight(.bold))
                            }
                            HStack {
                                Text("Tool Parser:").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text(m.upstreamToolParser).font(.caption.monospaced().weight(.bold)).foregroundStyle(Pastel.lavender)
                            }
                            HStack {
                                Text("Native / Max Context:").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(m.upstreamNativeContext) / \(m.upstreamExtendedContext)").font(.caption.monospaced())
                            }
                            ForEach(m.upstreamSampling, id: \.0) { k, v in
                                HStack {
                                    Text(k).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(v).font(.caption2.monospaced()).foregroundStyle(Pastel.butter)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 10, tint: Pastel.lavender)
                    }

                    if !m.upstreamNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PRACTICAL ENGINEERING NOTES")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.butter)
                            ForEach(m.upstreamNotes, id: \.self) { note in
                                Text("• \(note.replacingOccurrences(of: "—", with: " - "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.lavender)
            }
        }
    }

    // MARK: - TAB 3: Routines & Browser Demonstrations (`routines/*.json` & `recordings/*.json`)

    private var routinesAndDemosSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // Saved Routines
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Saved Routines (\(ctrl.routines.count))", systemImage: "repeat.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Pastel.mint)
                        Spacer()
                        Button("Open routines/ Folder") {
                            OperatorConsoleService.revealInFinder(path: "\(ctrl.localHubDataDir)/routines")
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(tint: Pastel.mint)
                    }

                    if ctrl.routines.isEmpty {
                        Text(ComputerStudioDiagnosis.noRoutines(hubOnline: ctrl.isHubServerOnline).text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ctrl.routines) { routine in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(routine.name)
                                        .font(.title3.weight(.bold))
                                    Text(routine.scope.uppercased())
                                        .openCorePastelBadge(Pastel.sky)
                                    Text(routine.modelID)
                                        .openCorePastelBadge(Pastel.lavender)
                                    if let status = routine.lastStatus {
                                        Text("LAST: \(status.uppercased())")
                                            .openCorePastelBadge(status == "completed" ? Pastel.mint : Pastel.peach)
                                    }
                                    Spacer()
                                    Button {
                                        ctrl.requestSavedRoutine(routine)
                                    } label: {
                                        Label(ctrl.isDryRun ? "Preview Routine" : "Run Routine", systemImage: "play.fill")
                                            .font(.caption.weight(.bold))
                                    }
                                    .openCoreGlassButton(prominent: true, tint: Pastel.mint)
                                    .disabled(ctrl.isStartingHubTask)
                                }

                                Text(routine.goal)
                                    .font(.callout)
                                    .foregroundStyle(.primary)

                                ForEach(routine.parameters.keys.sorted(), id: \.self) { key in
                                    TextField(key, text: Binding(
                                        get: { ctrl.routineParameterEdits[routine.id]?[key] ?? routine.parameters[key] ?? "" },
                                        set: { value in
                                            var values = ctrl.routineParameterEdits[routine.id] ?? routine.parameters
                                            values[key] = value
                                            ctrl.routineParameterEdits[routine.id] = values
                                        }))
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack(spacing: 14) {
                                    Text("Check: \(routine.checkKind)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Pastel.aqua)
                                    if !routine.expectedText.isEmpty {
                                        Text("Expected: \"\(routine.expectedText)\"")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Pastel.butter)
                                    }
                                    Text("Max Steps: \(routine.maxSteps)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Inspect JSON") {
                                        OperatorConsoleService.openFile(path: routine.filePath)
                                    }
                                    .controlSize(.mini)
                                    .openCoreGlassButton()
                                }
                            }
                            .padding(14)
                            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Recorded Browser Demonstrations
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Recorded Browser Demonstrations (\(ctrl.recordings.count))", systemImage: "record.circle")
                            .font(.headline)
                            .foregroundStyle(Pastel.peach)
                        Spacer()
                    }

                    if ctrl.recordings.isEmpty {
                        Text("No browser demonstration recordings in recordings/ yet. Record a session in Local Hub to compile clicks and field edits into a reusable routine.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .openCoreGlassCard(cornerRadius: 12)
                    } else {
                        ForEach(ctrl.recordings) { rec in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(rec.title)
                                        .font(.callout.weight(.bold))
                                    Spacer()
                                    Text("\(rec.stepCount) compiled steps")
                                        .openCorePastelBadge(Pastel.peach)
                                }
                                Text("URL: \(rec.startURL)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Pastel.sky)
                                if !rec.compiledGoal.isEmpty {
                                    Text(rec.compiledGoal)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .openCoreGlassCard(cornerRadius: 10, tint: Pastel.peach)
                        }
                    }
                }
                .frame(width: 420)
            }
        }
    }

    // MARK: - TAB 4: Run History, Token Reuse & Independent Verification Receipts (`runs/*.json`)

    private var historyAndReceiptsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left list of runs
            VStack(alignment: .leading, spacing: 8) {
                Text("RUN RECEIPTS (\(ctrl.runs.count))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Pastel.aqua)

                if ctrl.runs.isEmpty {
                    Text(ComputerStudioDiagnosis.noRuns(hubOnline: ctrl.isHubServerOnline).text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(ctrl.runs) { run in
                            let isSelected = ctrl.selectedRun?.id == run.id
                            Button {
                                ctrl.selectedRunID = run.id
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(run.verificationPassed == true ? "VERIFIED PASS" : run.status.uppercased())
                                            .openCorePastelBadge(run.verificationPassed == true ? Pastel.mint : Pastel.peach)
                                        Text(run.scope.uppercased())
                                            .openCorePastelBadge(Pastel.sky)
                                        Spacer()
                                        Text("\(run.steps.count) steps")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(run.goal)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    HStack {
                                        Text(run.modelID)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(Pastel.lavender)
                                        Spacer()
                                        Text("\(run.totalTokens.map(String.init) ?? "not measured") tokens · cache \(run.cacheReusePercent.map(String.init) ?? "not measured")%")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(Pastel.aqua)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isSelected ? Pastel.aqua.opacity(0.18) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(isSelected ? Pastel.aqua : Color.primary.opacity(0.12), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 520)
            }
            .frame(width: 360)

            // Right detail receipt view
            if let r = ctrl.selectedRun {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Run Receipt \(r.id.prefix(12))")
                                    .font(.title3.weight(.bold))
                                Text(r.verificationPassed == true ? "INDEPENDENT READBACK VERIFIED" : r.status.uppercased())
                                    .openCorePastelBadge(r.verificationPassed == true ? Pastel.mint : Pastel.peach)
                            }
                            Text(r.goal)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Receipt JSON") {
                            OperatorConsoleService.openFile(path: r.filePath)
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(tint: Pastel.aqua)
                    }

                    // Token & Verification Telemetry Row
                    HStack(spacing: 10) {
                        metricPill(label: "INPUT TOKENS", value: "\(r.inputTokens.map(String.init) ?? "not measured")", color: Pastel.sky)
                        metricPill(label: "CACHED INPUT", value: "\(r.cachedInputTokens.map(String.init) ?? "not measured") (\(r.cacheReusePercent.map(String.init) ?? "not measured")%)", color: Pastel.mint)
                        metricPill(label: "OUTPUT TOKENS", value: "\(r.outputTokens.map(String.init) ?? "not measured")", color: Pastel.lavender)
                        metricPill(label: "TURNS / STEPS", value: "\(r.turnCount.map(String.init) ?? "not measured") / \(r.steps.count)", color: Pastel.butter)
                    }

                    // Independent Verification Evidence Box
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Independent Verification: \(r.verificationSummary)", systemImage: r.verificationPassed == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(r.verificationPassed == true ? Pastel.mint : Pastel.peach)
                            Spacer()
                            Text("check_kind: \(r.verificationKind)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if !r.verificationEvidence.isEmpty {
                            HStack(spacing: 14) {
                                ForEach(r.verificationEvidence, id: \.0) { k, v in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(k).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        Text(v).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Pastel.mint)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .openCoreGlassCard(cornerRadius: 10, tint: r.verificationPassed == true ? Pastel.mint : Pastel.peach)

                    // Step-by-Step Tool Trace
                    Text("STEP-BY-STEP TOOL EXECUTION TRACE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Pastel.sky)

                    ForEach(r.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("STEP #\(step.step)")
                                    .openCorePastelBadge(Pastel.sky)
                                Text(step.tool)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(Pastel.lavender)
                                Text(step.argumentsSummary)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(step.ok.map { $0 ? "OK" : "ERR" } ?? "NOT REPORTED")
                                    .openCorePastelBadge(step.ok == true ? Pastel.mint : Pastel.peach)
                            }
                            if !step.observationSummary.isEmpty {
                                Text(step.observationSummary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(10)
                        .openCoreGlassCard(cornerRadius: 8)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.aqua)
            }
        }
    }

    // MARK: - TAB 5: Apps, Peekaboo 4.6.0 & Learned Knowledge (`knowledge/*.json`)

    private var appsPeekabooAndKnowledgeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Peekaboo 4.6.0 Helper Card
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "eye.square.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Pastel.peach)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Peekaboo \(ctrl.peekabooVersion) Window-Bound Desktop Engine")
                            .font(.headline)
                        Text(ctrl.peekabooInstalled ? "BINARY INSTALLED" : "NOT INSTALLED")
                            .openCorePastelBadge(ctrl.peekabooInstalled ? Pastel.mint : Pastel.rose)
                    }
                    Text(ctrl.peekabooPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await ctrl.runPeekabooWindowList() }
                } label: {
                    Label(ctrl.isRunningPeekaboo ? "Inspecting..." : "List Live Windows (Peekaboo)", systemImage: "macwindow.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .openCoreGlassButton(prominent: true, tint: Pastel.peach)
                .disabled(!ctrl.peekabooInstalled || ctrl.isRunningPeekaboo)
            }
            .padding(14)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.peach)

            if !ctrl.peekabooLiveWindowsOutput.isEmpty {
                ScrollView {
                    Text(ctrl.peekabooLiveWindowsOutput)
                        .font(.caption.monospaced())
                        .foregroundStyle(Pastel.ice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(12)
                .openCoreGlassCard(cornerRadius: 10, tint: Pastel.sky)
            }

            HStack(alignment: .top, spacing: 16) {
                // Running macOS Apps
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Running macOS Apps (\(ctrl.runningApps.count))", systemImage: "app.connected.to.app.below.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Pastel.sky)
                        Spacer()
                        Button("Refresh") { ctrl.refreshRunningApps() }
                            .controlSize(.mini)
                            .openCoreGlassButton()
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(ctrl.runningApps) { app in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(app.name)
                                                .font(.caption.weight(.bold))
                                            if app.isActive {
                                                Text("FRONTMOST")
                                                    .openCorePastelBadge(Pastel.mint)
                                            }
                                        }
                                        Text("\(app.bundleID) · PID \(app.pid)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Target in Task") {
                                        Task {
                                            await ctrl.targetRunningApp(app)
                                            activeTab = .tasksAndRoutines
                                        }
                                    }
                                    .controlSize(.mini)
                                    .openCoreGlassButton(tint: Pastel.sky)
                                }
                                .padding(8)
                                .openCoreGlassCard(cornerRadius: 8)
                            }
                        }
                    }
                    .frame(height: 360)
                }
                .padding(14)
                .frame(width: 440)
                .openCoreGlassCard(cornerRadius: 12)

                // Learned App Knowledge (`knowledge/*.json`)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Learned App Knowledge Cards (\(ctrl.learnedKnowledge.count))", systemImage: "brain.head.profile")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Pastel.lavender)
                        Spacer()
                        Button("Open knowledge/ Folder") {
                            OperatorConsoleService.revealInFinder(path: "\(ctrl.localHubDataDir)/knowledge")
                        }
                        .controlSize(.mini)
                        .openCoreGlassButton()
                    }

                    if ctrl.learnedKnowledge.isEmpty {
                        Text("No per-app knowledge JSON files recorded in ~/Library/Application Support/Local Automation Hub/knowledge yet. When 'Teach From Runs' is enabled, successful runs automatically store app shortcuts, controls, and rules here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ctrl.learnedKnowledge) { k in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(k.appName)
                                        .font(.callout.weight(.bold))
                                    Text("\(k.observationCount) observations")
                                        .openCorePastelBadge(Pastel.lavender)
                                    Spacer()
                                    Text(k.bundleID)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if !k.rules.isEmpty {
                                    Text("Rules: " + k.rules.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(Pastel.mint)
                                }
                                if !k.commonControls.isEmpty {
                                    Text("Controls: " + k.commonControls.prefix(8).joined(separator: ", "))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 10, tint: Pastel.lavender)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 12)
            }
        }
    }

    // MARK: - TAB 6: Screen Vision, CGEvent & Automation Studio

    private var visionAutomationSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            automationHeaderBar
            actionPlannerBar
            visualScreenAndInspectorSplit
            automationProfilesAndHistorySection
        }
        .task {
            if ctrl.capturedImage == nil {
                await ctrl.captureScreenAndAnalyze()
            }
        }
    }

    private var automationHeaderBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "viewfinder.rectangular")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Pastel.periwinkle)
                .frame(width: 44, height: 44)
                .background(Pastel.periwinkle.opacity(0.16), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Vision Bounding-Box Map & CGEvent Executor")
                    .font(.headline)
                Text("Captures your live display via ScreenCaptureKit, maps every clickable text/button region via Apple Vision, and plans or executes actions with a Dry-Run safety lock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                ctrl.requestMode(ctrl.isDryRun ? .live : .dryRun)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ctrl.isDryRun ? "lock.shield.fill" : "bolt.shield.fill")
                    Text(ctrl.isDryRun ? "DRY-RUN SAFETY LOCK: ON" : "LIVE CGEvent EXECUTION: ARMED")
                        .font(.caption.monospaced().weight(.bold))
                }
                .foregroundStyle(ctrl.isDryRun ? Pastel.mint : Pastel.peach)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((ctrl.isDryRun ? Pastel.mint : Pastel.peach).opacity(0.16), in: .capsule)
            }
            .buttonStyle(.plain)

            Button {
                Task { await ctrl.captureScreenAndAnalyze() }
            } label: {
                Label(ctrl.isAnalyzingScreen ? "Scanning..." : "Scan Screen Now", systemImage: "camera.viewfinder")
                    .font(.caption.weight(.semibold))
            }
            .openCoreGlassButton(prominent: true, tint: Pastel.periwinkle)
            .disabled(ctrl.isAnalyzingScreen)
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.periwinkle)
    }

    private var actionPlannerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Pastel.lavender)
                TextField("Describe an action to plan on screen (e.g., 'Click Sync All', 'Click Command Center', 'Find Quick Jump')...", text: $taskGoalInput)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit {
                        ComputerRunCenter.shared.launch(.screenPlanning) { _ in
                            await ctrl.planTaskWithOnDeviceFM(goal: taskGoalInput)
                        }
                    }

                Toggle("Overlay Boxes (\(ctrl.detectedElements.count))", isOn: $showAllBoundingBoxes)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)

                Button {
                    ComputerRunCenter.shared.launch(.screenPlanning) { _ in
                            await ctrl.planTaskWithOnDeviceFM(goal: taskGoalInput)
                        }
                } label: {
                    Label(ctrl.isPlanningTask ? "Planning..." : "Plan Action (/usr/bin/fm)", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                }
                .openCoreGlassButton(prominent: true, tint: Pastel.lavender)
                .disabled(taskGoalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ctrl.isPlanningTask)
            }
            .padding(12)
            .openCoreGlassCard(cornerRadius: 12)

            if let problem = ctrl.plannerProblem {
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Pastel.butter)
            }

            if !ctrl.plannedSteps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Planned Screen Action Sequence (/usr/bin/fm)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.lavender)
                        Spacer()
                        Button {
                            ctrl.executePlannedSteps()
                        } label: {
                            Label(
                                "Preview Sequence (No Input Events)",
                                systemImage: ctrl.isDryRun ? "play.circle" : "bolt.fill"
                            )
                            .font(.caption.weight(.bold))
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: true, tint: Pastel.mint)
                    }

                    ForEach(ctrl.plannedSteps) { step in
                        HStack(spacing: 10) {
                            Text("#\(step.stepNumber)")
                                .openCorePastelBadge(Pastel.lavender)
                            Text(step.action.uppercased())
                                .font(.caption2.monospaced().weight(.bold))
                            Text("'\(step.targetLabel)'")
                                .font(.caption.weight(.semibold))
                            Text("@ (\(step.x), \(step.y))")
                                .font(.caption.monospaced())
                                .foregroundStyle(Pastel.aqua)
                            Text("· \(step.reasoning)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            let decision = ctrl.decision(for: step)
                            if let reason = decision.reason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(Pastel.butter)
                                    .lineLimit(2)
                            }
                            Button(decision.title) { ctrl.performPlannedStep(step) }
                                .controlSize(.mini)
                                .openCoreGlassButton()
                                .disabled(!decision.isEnabled)
                                .help(decision.reason ?? "")
                        }
                    }
                }
                .padding(12)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
            }
        }
    }

    private var visualScreenAndInspectorSplit: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Interactive Screen Vision Map", systemImage: "macwindow.on.rectangle")
                        .font(.subheadline.weight(.bold))
                    Text(ctrl.screenSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if let image = ctrl.capturedImage {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipShape(.rect(cornerRadius: 10))

                            if showAllBoundingBoxes {
                                ForEach(filteredElements) { el in
                                    let isSelected = ctrl.selectedElement?.id == el.id
                                    let x = el.normalizedRect.minX * geo.size.width
                                    let y = el.normalizedRect.minY * geo.size.height
                                    let w = max(el.normalizedRect.width * geo.size.width, 16)
                                    let h = max(el.normalizedRect.height * geo.size.height, 12)

                                    Button {
                                        ctrl.selectedElementID = el.id
                                        ctrl.targetReticlePoint = el.screenPoint
                                    } label: {
                                        Rectangle()
                                            .fill(isSelected ? Pastel.aqua.opacity(0.28) : Pastel.lavender.opacity(0.10))
                                            .overlay {
                                                Rectangle()
                                                    .strokeBorder(
                                                        isSelected ? Pastel.aqua : Pastel.lavender.opacity(0.65),
                                                        lineWidth: isSelected ? 2.0 : 1.0
                                                    )
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: w, height: h)
                                    .position(x: x + w / 2, y: y + h / 2)
                                    .help("[\(el.index)] \(el.label) @ \(el.coordinateBadge)")
                                }
                            }

                            if let reticle = ctrl.targetReticlePoint,
                               ctrl.screenLogicalSize.width > 0,
                               ctrl.screenLogicalSize.height > 0 {
                                let rx = (reticle.x / ctrl.screenLogicalSize.width) * geo.size.width
                                let ry = (reticle.y / ctrl.screenLogicalSize.height) * geo.size.height
                                ZStack {
                                    Circle()
                                        .strokeBorder(Pastel.peach, lineWidth: 2)
                                        .frame(width: 24, height: 24)
                                    Circle()
                                        .fill(Pastel.peach)
                                        .frame(width: 6, height: 6)
                                }
                                .position(x: rx, y: ry)
                            }
                        }
                    }
                    .aspectRatio(
                        max(ctrl.screenLogicalSize.width, 1) / max(ctrl.screenLogicalSize.height, 1),
                        contentMode: .fit
                    )
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(ctrl.screenScanProblem?.text ?? "Click 'Scan Screen Now' to capture display & detect UI bounding boxes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .openCoreGlassCard(cornerRadius: 14)

            VStack(alignment: .leading, spacing: 12) {
                if let sel = ctrl.selectedElement {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SELECTED UI ELEMENT #\(sel.index)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.aqua)
                            Spacer()
                            Text(String(format: "%.0f%% conf", sel.confidence * 100))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(sel.label)
                            .font(.headline)
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Label("Center: \(sel.coordinateBadge)", systemImage: "scope")
                                .font(.caption.monospaced())
                            Label("Size: \(Int(sel.screenSize.width))x\(Int(sel.screenSize.height)) pt", systemImage: "viewfinder")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button {
                                ctrl.executeClick(at: sel.screenPoint, label: sel.label)
                            } label: {
                                Label(ctrl.isDryRun ? "Test Click (Dry-Run)" : "Click Element", systemImage: "cursorarrow.click")
                                    .font(.caption.weight(.semibold))
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(prominent: true, tint: Pastel.aqua)

                            Button {
                                ctrl.executeMoveCursor(to: sel.screenPoint, label: sel.label)
                            } label: {
                                Label("Move Cursor", systemImage: "cursorarrow.motionlines")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .openCoreGlassButton()
                        }
                    }
                    .padding(12)
                    .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)
                }

                if ctrl.capturedImage != nil, let problem = ctrl.screenScanProblem {
                    Text(problem.text).font(.caption).foregroundStyle(Pastel.butter)
                }

                TextField("Filter \(ctrl.detectedElements.count) detected elements...", text: $elementSearch)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredElements) { el in
                            let isSelected = ctrl.selectedElement?.id == el.id
                            Button {
                                ctrl.selectedElementID = el.id
                                ctrl.targetReticlePoint = el.screenPoint
                            } label: {
                                HStack(spacing: 8) {
                                    Text("#\(el.index)")
                                        .font(.caption2.monospaced().weight(.bold))
                                        .foregroundStyle(isSelected ? Pastel.aqua : .secondary)
                                        .frame(width: 30, alignment: .leading)
                                    Text(el.label)
                                        .font(.caption.weight(isSelected ? .bold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(el.coordinateBadge)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? Pastel.aqua.opacity(0.18) : Color.secondary.opacity(0.06),
                                    in: .rect(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 310)
            }
            .frame(width: 340)
        }
    }

    private var automationProfilesAndHistorySection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Automation Profiles", systemImage: "slider.horizontal.2.square.on.square")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    if let root = ctrl.automationRootPath {
                        Button("Open in Finder") {
                            OperatorConsoleService.revealInFinder(path: root)
                        }
                        .controlSize(.mini)
                        .openCoreGlassButton()
                    }
                }

                if ctrl.automationRootPath == nil {
                    Text("No profile folder is set in private-names.json, so no profiles are listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(ctrl.automationProfiles) { prof in
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(Pastel.lavender)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(prof.name)
                                    .font(.callout.weight(.bold))
                                Text(prof.dryRun ? "DRY-RUN DEFAULT" : "LIVE")
                                    .openCorePastelBadge(prof.dryRun ? Pastel.mint : Pastel.peach)
                            }
                            Text("tick_hz: \(String(format: "%.1f", prof.tickHz)) Hz · downscale: \(String(format: "%.2f", prof.downscale)) · threshold: \(String(format: "%.2f", prof.matchThreshold)) · \(prof.templateCount) templates")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Inspect YAML") {
                            OperatorConsoleService.openFile(path: prof.filePath)
                        }
                        .controlSize(.mini)
                        .openCoreGlassButton()
                    }
                    .padding(10)
                    .openCoreGlassCard(cornerRadius: 8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .openCoreGlassCard(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Computer Control Audit Log", systemImage: "list.bullet.rectangle.portrait")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    if !ctrl.executionLogs.isEmpty {
                        Button("Clear") {
                            ctrl.executionLogs.removeAll()
                        }
                        .controlSize(.mini)
                        .openCoreGlassButton()
                    }
                }

                if ctrl.executionLogs.isEmpty {
                    Text("No screen scans or actions logged yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ctrl.executionLogs.prefix(6)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.mode)
                                    .openCorePastelBadge(entry.mode == "LIVE" ? Pastel.peach : Pastel.mint)
                                Text(entry.summary)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .openCoreGlassCard(cornerRadius: 8)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .openCoreGlassCard(cornerRadius: 12)
        }
    }

    // MARK: - TAB 7: 17 Validated Settings (`hub/settings.py`) & 110-Entry Searchable Guide (`hub/static/guide.json`)

    private var settingsAndGuideSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            LocalHubSettingsEditor()

            // Bottom: 8-Chapter, 110-Entry Searchable Reference Manual (`hub/static/guide.json`)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Local Automation Hub Reference Manual (\(filteredGuideEntries.count) / \(ctrl.guideEntries.count) entries across \(ctrl.guideChapters.count) chapters)", systemImage: "book.pages.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.sky)
                    Spacer()
                    TextField("Search 110-entry guide (models, tools, scopes, troubleshooting)...", text: $guideSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 340)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("All Chapters (\(ctrl.guideEntries.count))") {
                            selectedGuideChapter = "all"
                        }
                        .controlSize(.small)
                        .openCoreGlassButton(prominent: selectedGuideChapter == "all", tint: Pastel.sky)

                        ForEach(ctrl.guideChapters) { ch in
                            Button("\(ch.title) (\(ch.entryCount))") {
                                selectedGuideChapter = ch.id
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(prominent: selectedGuideChapter == ch.id, tint: Pastel.lavender)
                        }
                    }
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredGuideEntries) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name)
                                        .font(.callout.weight(.bold))
                                        .foregroundStyle(Pastel.sky)
                                    Text(item.kind)
                                        .openCorePastelBadge(Pastel.lavender)
                                    Spacer()
                                    Text("\(item.chapterTitle) · \(item.sectionTitle)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.what)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                if !item.when.isEmpty {
                                    Text("When to use: \(item.when)")
                                        .font(.caption2)
                                        .foregroundStyle(Pastel.mint)
                                }
                                if !item.example.isEmpty {
                                    Text("Example: \(item.example)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(Pastel.butter)
                                }
                                if !item.watch.isEmpty {
                                    Text("Watch out for: \(item.watch)")
                                        .font(.caption2)
                                        .foregroundStyle(Pastel.peach)
                                }
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 10)
                        }
                    }
                }
                .frame(height: 420)
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
        }
    }
}

// MARK: - Dedicated Workspace ⌘6: AI Models & RAM (LM Studio-Style Model & Memory Deck)

struct AIModelsAndRAMWorkspaceView: View {
    @Environment(\.appModel) private var model
    @State private var ctrl = ComputerControlManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModelLabView()

                // Dedicated unified memory bar and loaded model controls.
                LMStudioMemoryAndModelDeck()

                // 13 Curated Computer-Use Models + Custom HuggingFace MLX Repo Downloader
                SpecialistComputerUseModelZooView()

                // Local Hub Serving Profiles, KV Quantization, and Empirical Task Verification Evidence
                ComputerControlView().modelsAndEvidencePublicSection
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("AI Models & RAM")
        .task {
            ctrl.reloadAllLocalHubData()
            await ctrl.probeHubServer()
        }
    }
}

extension ComputerControlView {
    var modelsAndEvidencePublicSection: some View {
        modelsAndEvidenceSection
    }
}

struct LocalHubAppOption: Identifiable, Sendable {
    let id: String
    let name: String
    let bundleID: String
}

struct LocalHubWindowOption: Identifiable, Sendable {
    let id: Int
    let title: String
}

// MARK: - Local Hub wire contract (pure parsing and validation)

struct HubSettingOption: Identifiable, Sendable {
    var id: String { value }
    let value: String
    let label: String
}

struct HubSettingField: Identifiable, Sendable {
    let id: String
    let kind: String
    let label: String
    let help: String
    let minimum: Int?
    let maximum: Int?
    let options: [HubSettingOption]
}

enum LocalHubContract {
    static func responseHasError(_ object: [String: Any]) -> Bool {
        guard let value = object["error"] else { return false }
        return !(value is NSNull)
    }

    struct InvalidRequest: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runtimeReady(_ receipt: [String: Any], modelID: String) -> Bool {
        !responseHasError(receipt) && receipt["active"] as? String == modelID && receipt["status"] as? String == "ready"
    }

    static func installationComplete(_ entry: [String: Any]) -> Bool {
        guard let installed = entry["installed"] as? [String: Any],
              let revision = entry["revision"] as? String, !revision.isEmpty,
              installed["revision"] as? String == revision,
              let files = entry["files"] as? [[String: Any]], !files.isEmpty,
              files.contains(where: { ($0["name"] as? String)?.hasSuffix(".safetensors") == true }),
              files.allSatisfy({ (($0["size"] as? NSNumber)?.int64Value ?? 0) > 0 && ($0["sha256"] is String || $0["git_sha1"] is String) }),
              let bytes = installed["bytes"] as? NSNumber else { return false }
        let expected = files.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
        // Hub records this exact revision/byte receipt only after checking every
        // required file against its pinned size and upstream artifact hash.
        return bytes.int64Value == expected
    }

    static func appInventory(_ rows: [[String: Any]]) -> [LocalHubAppOption] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, id.count == 20, id.allSatisfy(\.isHexDigit),
                  let name = row["name"] as? String, !name.isEmpty,
                  let bundle = row["bundle"] as? String, !bundle.isEmpty, seen.insert(id).inserted else { return nil }
            return LocalHubAppOption(id: id, name: name, bundleID: bundle)
        }
    }

    static func previewPointer(action: String, at point: CGPoint, screenSize: CGSize) -> CGPoint? {
        guard ["click", "double_click", "right_click", "move"].contains(action),
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < screenSize.width, point.y < screenSize.height else { return nil }
        return point
    }

    static func taskPayload(goal: String, scope: String, url: String, app: String, window: String,
                            folder: String, allowOverwrite: Bool, appID: String = "", knownAppIDs: Set<String> = [],
                            checkKind: String, checkPath: String,
                            expected: String, note: String) throws -> [String: Any] {
        func reject(_ message: String) throws -> Never { throw InvalidRequest(message: message) }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 5000 else { try reject("Enter a goal of 1 to 5,000 characters.") }
        let allowedChecks = ["browser": ["fixture", "page_text", "none"], "scratch": ["file", "none"],
                             "folder": ["file", "none"], "computer": ["desktop_text", "none"], "desktop": ["desktop_text", "none"]]
        guard allowedChecks[scope]?.contains(checkKind) == true else { try reject("Choose a completion check that matches the selected task scope.") }
        var payload: [String: Any] = ["goal": goal, "scope": scope, "allow_overwrite": allowOverwrite]
        if scope == "browser" {
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
                try reject("Enter a complete http or https page address.")
            }
            payload["url"] = url
        }
        if scope == "folder" {
            guard !folder.isEmpty else { try reject("Choose a work folder before running this task.") }
            payload["folder"] = folder
        }
        if scope == "computer" {
            guard appID.count == 20, appID.allSatisfy(\.isHexDigit), knownAppIDs.contains(appID) else {
                try reject("Choose an installed app from Local Hub's current app list.")
            }
            payload["apps"] = [appID]
            // Computer tasks start from allowed Hub app identities. The Hub
            // opens the app and sets its current PID/window before readback.
            // Native selector/window fields are reserved for Exact Window scope.
        }
        if scope == "desktop" {
            guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { try reject("Choose the app this task may control.") }
            guard let id = Int(window), id > 0 else { try reject("Select an exact numeric window ID for the desktop task.") }
            payload["app"] = app
            payload["window"] = id
        }
        var check: [String: Any] = ["kind": checkKind]
        switch checkKind {
        case "fixture":
            guard url == "http://127.0.0.1:8765/fixture" else { try reject("The saved-form check applies to the Local Hub practice page.") }
            guard !expected.isEmpty else { try reject("Enter the exact name to find in the saved form.") }
            check["name"] = expected
            check["note"] = note
        case "file":
            guard !checkPath.isEmpty, !checkPath.hasPrefix("/"), !checkPath.split(separator: "/").contains("..") else {
                try reject("Enter a relative filename inside the selected work folder.")
            }
            guard !expected.isEmpty else { try reject("Enter the exact file contents to check.") }
            check["path"] = checkPath
            check["expected"] = expected
        case "page_text", "desktop_text":
            guard !expected.isEmpty else { try reject("Enter the exact text to check.") }
            if checkKind == "desktop_text", scope == "desktop", (Int(window) ?? 0) <= 0 {
                try reject("Select an exact numeric window ID for the app text check.")
            }
            check["expected"] = expected
        default: break
        }
        payload["verification"] = check
        return payload
    }

    static func receipt(_ raw: [String: Any], filePath: String) -> LocalHubRunReceipt? {
        guard let id = raw["id"] as? String else { return nil }
        func summary(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "Not reported" }
            if let text = value as? String { return text }
            if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { return text }
            return String(describing: value)
        }
        let steps = (raw["steps"] as? [[String: Any]] ?? []).enumerated().map { index, step in
            let action = step["action"] as? [String: Any] ?? [:]
            let result = step["result"] as? [String: Any]
            return LocalHubRunStep(step: index + 1, at: step["at"] as? String ?? "",
                tool: action["tool"] as? String ?? "unknown", argumentsSummary: summary(action),
                ok: result?["ok"] as? Bool, observationSummary: summary(step["result"]))
        }
        let check = raw["verification"] as? [String: Any] ?? [:]
        let evidence = raw["evidence"] as? [String: Any] ?? [:]
        let proof = evidence["evidence"]
        let evidenceRows: [(String, String)]
        if let object = proof as? [String: Any] {
            evidenceRows = object.keys.sorted().map { ($0, summary(object[$0])) }
        } else if let proof, !(proof is NSNull) {
            evidenceRows = [("Readback", summary(proof))]
        } else { evidenceRows = [] }
        let usage = raw["usage"] as? [[String: Any]] ?? []
        func sum(_ keys: [String]) -> Int? {
            let measured = usage.compactMap { turn in keys.lazy.compactMap { (turn[$0] as? NSNumber)?.intValue }.first }
            return measured.count == usage.count && !usage.isEmpty ? measured.reduce(0, +) : nil
        }
        let input = sum(["input_tokens", "prompt_tokens"])
        let output = sum(["output_tokens", "completion_tokens"])
        let cached = sum(["cached_input_tokens", "cached_tokens"])
        let total = sum(["total_tokens"])
        let events = raw["events"] as? [[String: Any]] ?? []
        return LocalHubRunReceipt(id: id, goal: raw["goal"] as? String ?? "",
            modelID: raw["model"] as? String ?? ((raw["routine_id"] is String) ? "Deterministic routine" : "Not reported"),
            scope: raw["scope"] as? String ?? "unknown", status: raw["status"] as? String ?? "unknown",
            startedAt: raw["created"] as? String ?? "", finishedAt: raw["finished"] as? String ?? "",
            summary: raw["summary"] as? String ?? events.last?["message"] as? String ?? "", error: raw["error"] as? String,
            steps: steps, verificationPassed: evidence["passed"] as? Bool,
            verificationKind: check["kind"] as? String ?? "none", verificationSummary: summary(proof), verificationEvidence: evidenceRows,
            inputTokens: input, cachedInputTokens: cached, outputTokens: output,
            totalTokens: total ?? input.flatMap { i in output.map { i + $0 } }, turnCount: usage.isEmpty ? nil : usage.count, filePath: filePath)
    }

    static func pointerPlan(_ raw: String, screenSize: CGSize) -> [PlannedAutomationStep] {
        let lines = raw.split(separator: "\n")
        var result: [PlannedAutomationStep] = []
        for line in lines {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6, fields[0].hasPrefix("STEP "), ["click", "double_click", "move"].contains(fields[1]),
                  let x = Int(fields[2]), let y = Int(fields[3]), x >= 0, y >= 0,
                  CGFloat(x) < screenSize.width, CGFloat(y) < screenSize.height else { return [] }
            result.append(PlannedAutomationStep(stepNumber: result.count + 1, action: fields[1], targetLabel: fields[4],
                x: x, y: y, textToType: nil, reasoning: fields[5]))
            if result.count == 3 { break }
        }
        return result
    }
}

// MARK: - Settings discovered from the running Hub, never a guessed schema

struct LocalHubSettingsEditor: View {
    @State private var ctrl = ComputerControlManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Local Hub Settings", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("Reload") { Task { await ctrl.refreshHubSettings() } }
                Button(ctrl.isSavingHubSettings ? "Saving…" : "Save to Local Hub") {
                    Task { await ctrl.saveSettingsToDiskAndServer() }
                }
                .disabled(!ctrl.hubSettingsLoaded || ctrl.isSavingHubSettings)
            }
            Text(ctrl.hubSettingsStatus).font(.caption).foregroundStyle(.secondary)
            ForEach(ctrl.hubSettingFields) { field in
                VStack(alignment: .leading, spacing: 3) {
                    if field.kind == "boolean" {
                        Toggle(field.label, isOn: Binding(get: { ctrl.hubSettingValues[field.id] as? Bool ?? false },
                            set: { ctrl.hubSettingValues[field.id] = $0 }))
                    } else if field.kind == "integer", let lower = field.minimum, let upper = field.maximum, lower <= upper {
                        Stepper(value: Binding(get: { (ctrl.hubSettingValues[field.id] as? NSNumber)?.intValue ?? lower },
                            set: { ctrl.hubSettingValues[field.id] = $0 }), in: lower...upper) {
                            Text("\(field.label): \((ctrl.hubSettingValues[field.id] as? NSNumber)?.stringValue ?? "not reported")")
                        }
                    } else if field.kind == "choice" {
                        Picker(field.label, selection: Binding(get: { ctrl.hubSettingValues[field.id] as? String ?? "" },
                            set: { ctrl.hubSettingValues[field.id] = $0 })) {
                            ForEach(field.options) { option in Text(option.label).tag(option.value) }
                        }
                    } else {
                        Text("\(field.label): this control is unavailable in this app version.")
                    }
                    Text(field.help).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.butter)
        .task { await ctrl.refreshHubSettings() }
    }
}
