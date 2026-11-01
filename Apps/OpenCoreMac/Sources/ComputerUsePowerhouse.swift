import ApplicationServices
import AppKit
import CoreGraphics
import CoreTelemetry
import Darwin
import Foundation
import FoundationModels
import Metal
import Observation
import ScreenCaptureKit
import SwiftUI
import Vision

// MARK: - 1. Real-Time Apple Silicon Unified Memory Monitor (LM Studio-Style RAM / VRAM Bar)

@MainActor
@Observable
final class UnifiedMemoryMonitor {
    static let shared = UnifiedMemoryMonitor()

    var totalRAMGiB: Double = 0
    var wiredAndGPUGiB: Double = 0
    var activeAppGiB: Double = 0
    var compressedGiB: Double = 0
    var freeGiB: Double = 0
    var metalRecommendedMaxGiB: Double = 0
    var gpuDeviceName: String = "Device unavailable"
    var pressureLevel: String = "Not sampled"
    var hasMemorySample = false

    private var timer: Timer?

    private init() {
        if let dev = MTLCopyAllDevices().first {
            gpuDeviceName = dev.name
            metalRecommendedMaxGiB = Double(dev.recommendedMaxWorkingSetSize) / 1_073_741_824.0
        }
        totalRAMGiB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        sampleMemory()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMemory()
            }
        }
    }

    func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        mach_port_deallocate(mach_task_self_, hostPort)
        guard result == KERN_SUCCESS else { hasMemorySample = false; return }
        hasMemorySample = true

        let pageBytes = Double(getpagesize())
        let gib = 1_073_741_824.0

        let wired = Double(stats.wire_count) * pageBytes / gib
        let active = Double(stats.active_count) * pageBytes / gib
        let compressed = Double(stats.compressor_page_count) * pageBytes / gib

        let newWired = (wired * 10).rounded() / 10
        let newActive = (active * 10).rounded() / 10
        let newCompressed = (max(0.0, compressed) * 10).rounded() / 10
        let used = min(totalRAMGiB, newWired + newActive + newCompressed)
        let newFree = (Double(stats.free_count) * pageBytes / gib * 10).rounded() / 10

        if abs(wiredAndGPUGiB - newWired) >= 0.1 { wiredAndGPUGiB = newWired }
        if abs(activeAppGiB - newActive) >= 0.1 { activeAppGiB = newActive }
        if abs(compressedGiB - newCompressed) >= 0.1 { compressedGiB = newCompressed }
        if abs(freeGiB - newFree) >= 0.1 { freeGiB = newFree }

        let usedRatio = used / max(totalRAMGiB, 1.0)
        let newPressure: String
        if usedRatio > 0.88 {
            newPressure = "High sampled use (estimate)"
        } else if usedRatio > 0.75 {
            newPressure = "Elevated sampled use (estimate)"
        } else {
            newPressure = "Sampled use (estimate)"
        }
        if pressureLevel != newPressure { pressureLevel = newPressure }
    }
}

// MARK: - 2. Specialist Computer-Use Model Zoo (Local Hub + Frontier 2025-2026 MLX GUI Models)

struct SpecialistGUIModel: Identifiable, Sendable {
    enum TaskSpecialty: String, CaseIterable, Identifiable, Sendable {
        case all = "All Models"
        case multiStepAgent = "Autonomous GUI Agents"
        case clickGrounding = "Pixel & Click Grounding"
        case browserWeb = "Browser & Web DOM"
        case toolPlanner = "Fast Tool & Macro Planners"
        case builtInOS = "macOS Native"

        var id: String { rawValue }

        var accent: Color {
            switch self {
            case .all: return Pastel.ice
            case .multiStepAgent: return Pastel.lavender
            case .clickGrounding: return Pastel.mint
            case .browserWeb: return Pastel.aqua
            case .toolPlanner: return Pastel.sky
            case .builtInOS: return Pastel.butter
            }
        }
    }

    let id: String
    let name: String
    let creator: String
    let hfRepo: String
    let runtimeEngine: String
    let quantization: String
    let sizeGB: Double?
    let estRAMGB: Double?
    let specialty: TaskSpecialty
    let specialtyHeadline: String
    let whenToPick: String
    let bestForTasks: [String]
    let whyDesignedAndArch: String
    let trainedOnCorpus: String
    let tradeoffsAndLimits: String
    let benchmarkBadge: String
    let isLocalHubNative: Bool

    var publisherURL: URL? {
        let address: String
        switch id {
        case "apple-system": address = "https://developer.apple.com/documentation/foundationmodels"
        case "mlx-community/UI-TARS-1.5-7B-4bit": address = "https://huggingface.co/ByteDance-Seed/UI-TARS-1.5-7B"
        case "mlx-community/Holo1-7B-4bit": address = "https://huggingface.co/Hcompany/Holo1-7B"
        case "mlx-community/Holo1-3B-4bit": address = "https://huggingface.co/Hcompany/Holo1-3B"
        case "mlx-community/ShowUI-2B-bf16-4bit": address = "https://arxiv.org/abs/2411.17465"
        case "mlx-community/UGround-V1-2B": address = "https://huggingface.co/osunlp/UGround-V1-2B"
        case "microsoft/Fara1.5-4B": address = "https://huggingface.co/microsoft/Fara1.5-4B"
        case "OsaurusAI/Raptor-0.6-4B-JANG_6M": address = "https://huggingface.co/OsaurusAI/Raptor-0.6-4B-JANG_6M"
        case "OsaurusAI/Raptor-0.6-4B-JANG_4M": address = "https://huggingface.co/OsaurusAI/Raptor-0.6-4B-JANG_4M"
        case "mlx-community/Qwen3-4B-Instruct-2507-4bit": address = "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507"
        case "mlx-community/Qwen3-1.7B-4bit": address = "https://huggingface.co/Qwen/Qwen3-1.7B"
        case "mlx-community/Qwen2.5-VL-7B-Instruct-4bit": address = "https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct"
        case "prncvrm/OS-Atlas-Base-7B-4bit": address = "https://huggingface.co/OS-Copilot/OS-Atlas-Base-7B"
        default: return nil
        }
        return URL(string: address)
    }

    var resourceDescription: String {
        if id == "apple-system" { return "OS-managed model; RAM not measured" }
        return "Local package; memory in skill results"
    }
}

// MARK: - 3. Watch-Me & Repeat with Variations Data Structures

struct RecordedActionStep: Identifiable, Hashable, Sendable {
    var id = UUID()
    var stepNumber: Int
    var actionKind: String // "click", "double_click", "type", "keypress", "activate_app", "scroll"
    var appName: String
    var windowTitle: String
    var elementRole: String
    var elementTitle: String
    var x: Int
    var y: Int
    var textValue: String
    var parameterName: String? // e.g. "query" -> "{{query}}"
    var timestamp: Date
}

struct ReplayVariationPass: Identifiable, Hashable, Sendable {
    let id = UUID()
    var passIndex: Int
    var parameters: [String: String]
    var summary: String
    var status: String // "pending", "running", "completed", "failed"
}

// MARK: - 4. Autonomous Agent Cognitive Loop Stage ("Observe -> Think -> Ground -> Act -> Verify")

enum CognitiveStage: String, CaseIterable, Identifiable, Sendable {
    case observe = "1. OBSERVE SCREEN"
    case think = "2. THINK & PLAN"
    case ground = "3. GROUND (X,Y)"
    case act = "4. EXECUTE ACTION"
    case verify = "5. VERIFY OUTCOME"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .observe: return "camera.viewfinder"
        case .think: return "brain.head.profile"
        case .ground: return "scope"
        case .act: return "cursorarrow.click.2"
        case .verify: return "checkmark.seal.fill"
        }
    }

    var accent: Color {
        switch self {
        case .observe: return Pastel.sky
        case .think: return Pastel.lavender
        case .ground: return Pastel.butter
        case .act: return Pastel.mint
        case .verify: return Pastel.aqua
        }
    }
}

struct CognitiveTraceEntry: Identifiable, Sendable {
    let id = UUID()
    let stepIndex: Int
    let stage: CognitiveStage
    let timestamp: Date
    let headline: String
    let thoughtOrEvidence: String
    let targetPoint: CGPoint?
    let succeeded: Bool
}

// MARK: - 5. Watch-Me, Autonomous Loop & LM Studio Model Controller

@MainActor
@Observable
final class ComputerUseStudioController {
    static let shared = ComputerUseStudioController()

    // LM Studio Model Loader State
    var activeLoadedModelID: String?
    var activeRuntimeStatus: String = "not connected" // "unloaded", "loading", "ready", "generating"
    var activeRuntimeEngine: String = "Not reported"
    var isRuntimeStateVerified = false
    var lastConfirmedModelID: String?
    var activeModelError: String?
    var isLoadingOrUnloadingModel: Bool = false
    var customHFRepoInput: String = ""
    var selectedSpecialtyFilter: SpecialistGUIModel.TaskSpecialty = .all
    var activeDownloadProgress: [String: (receivedBytes: Int64, totalBytes: Int64, status: String, speedMBps: Double)] = [:]
    var downloadedCustomModels: Set<String> = []

    // Watch-Me & Repeat with Variations State
    var isWatchingDesktop: Bool = false
    var isWatchingBrowser: Bool = false
    var recordedSteps: [RecordedActionStep] = []
    var demonstrationTitle: String = "My Recorded Mac Workflow"
    var repeatCount: Int = 3
    var variationInstruction: String = "Repeat this workflow 3 times, varying the typed input for each pass: Pass 1 = 'OpenCore', Pass 2 = 'OpenIntelligence', Pass 3 = 'Local Automation Hub'."
    var generatedPasses: [ReplayVariationPass] = []
    var isGeneratingVariations: Bool = false
    var isReplayingLoop: Bool = false
    var currentReplayPassIndex: Int = 0
    var currentReplayStepIndex: Int = 0

    // Autonomous "Watch It Figure It Out" Loop State
    var autonomousGoal: String = "Find the search or input field on screen, click it, type 'OpenCore macOS 27', and verify the text appears."
    var selectedSpecialistModelID: String = "apple-system"
    var isRunningAutonomousLoop: Bool = false
    var currentCognitiveStage: CognitiveStage = .observe
    var cognitiveTraces: [CognitiveTraceEntry] = []
    var autonomousMaxSteps: Int = 5
    var currentAutonomousStep: Int = 0

    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var workspaceObserver: Any?
    private var pendingTypedBuffer: String = ""
    private var pendingTypedApp: String = ""
    private var pendingTypedWindow: String = ""

    var modelCardTestOutputs: [String: String] = [:]
    var failedModelActions: Set<String> = []

    let specialistCatalog: [SpecialistGUIModel] = [
        // 1. Built-in macOS 27
        SpecialistGUIModel(
            id: "apple-system",
            name: "Apple Foundation Models (macOS 27 Built-In)",
            creator: "Apple",
            hfRepo: "apple/FoundationModels-macOS27",
            runtimeEngine: "Apple FoundationModels framework",
            quantization: "OS-managed; runtime details not measured",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .builtInOS,
            specialtyHeadline: "On-device text planning and structured generation",
            whenToPick: "Use the system model for text planning when Apple Intelligence reports it available. No separate OpenCore weights package is required.",
            bestForTasks: [
                "Text planning from a supplied goal",
                "Structured responses using FoundationModels schemas",
                "Planning from separately extracted OCR text"
            ],
            whyDesignedAndArch: "Apple supplies an on-device language model through FoundationModels. OpenCore reads runtime availability; model identity and supported features depend on the OS.",
            trainedOnCorpus: "Apple documents its model training separately. OpenCore does not inspect the installed model training data.",
            tradeoffsAndLimits: "The preview supplies OCR text rather than screenshot pixels. Local checks report elapsed time; the Apple worker does not report MLX memory. Availability alone does not prove task success.",
            benchmarkBadge: "System availability checked at runtime",
            isLocalHubNative: true
        ),
        // 2. UI-TARS 1.5 7B (ByteDance)
        SpecialistGUIModel(
            id: "mlx-community/UI-TARS-1.5-7B-4bit",
            name: "UI-TARS 1.5 · 7B (4-bit MLX)",
            creator: "ByteDance Seed / mlx-community",
            hfRepo: "mlx-community/UI-TARS-1.5-7B-4bit",
            runtimeEngine: "mlx-vlm",
            quantization: "Community 4-bit MLX conversion",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .multiStepAgent,
            specialtyHeadline: "Visual GUI action model with reasoning traces",
            whenToPick: "Choose UI-TARS to locate desktop targets from screenshots. Compare its local results above before using a predicted point.",
            bestForTasks: [
                "Screenshot interpretation and action prediction",
                "Visual target grounding",
                "Research on multi-step GUI interaction"
            ],
            whyDesignedAndArch: "UI-TARS 1.5 uses a Qwen2.5-VL backbone and reasoning before GUI actions.",
            trainedOnCorpus: "The publisher describes reinforcement learning for GUI interaction and general computer use. The released 7B model differs from the larger research system.",
            tradeoffsAndLimits: "Uses a local screenshot adapter. Check the recorded trials for this exact package; publisher benchmark scores do not measure this Mac.",
            benchmarkBadge: "Publisher benchmark only; see original 7B card",
            isLocalHubNative: false
        ),
        // 3. Holo1 7B (H Company)
        SpecialistGUIModel(
            id: "mlx-community/Holo1-7B-4bit",
            name: "Holo1 · 7B Action VLM (4-bit MLX)",
            creator: "H Company / mlx-community",
            hfRepo: "mlx-community/Holo1-7B-4bit",
            runtimeEngine: "mlx-vlm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .browserWeb,
            specialtyHeadline: "Web action vision-language model from Surfer-H",
            whenToPick: "Choose Holo1 7B for locating controls in web screenshots. Compare its six local target checks with the smaller 3B package.",
            bestForTasks: [
                "Web interface localization",
                "Visual action prediction",
                "Policy, localizer or validator experiments"
            ],
            whyDesignedAndArch: "Holo1-7B is fine-tuned from Qwen2.5-VL-7B-Instruct and forms part of the modular Surfer-H architecture.",
            trainedOnCorpus: "The publisher describes a mix of open-access, synthetic and self-generated data.",
            tradeoffsAndLimits: "Full Surfer-H results include a larger agent architecture. Use the local checks for this exact conversion; locating a target is separate from completing a workflow.",
            benchmarkBadge: "Web action model; publisher results linked",
            isLocalHubNative: false
        ),
        // 4. Holo1 3B (H Company)
        SpecialistGUIModel(
            id: "mlx-community/Holo1-3B-4bit",
            name: "Holo1 · 3B Fast Action VLM (4-bit MLX)",
            creator: "H Company / mlx-community",
            hfRepo: "mlx-community/Holo1-3B-4bit",
            runtimeEngine: "mlx-vlm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .clickGrounding,
            specialtyHeadline: "Smaller Holo1 web action model",
            whenToPick: "Choose Holo1 3B when you want a smaller screenshot locator. Check whether its local target results match the 7B model.",
            bestForTasks: [
                "Web screenshot localization",
                "Action prediction with a separate harness",
                "Comparing smaller visual models"
            ],
            whyDesignedAndArch: "A 3B member of the Holo1 Action VLM family. A smaller parameter count does not establish a measured speedup on this Mac.",
            trainedOnCorpus: "Holo1 uses open-access, synthetic and self-generated data. Distillation details are not asserted here.",
            tradeoffsAndLimits: "The local 4-bit package runs through the screenshot adapter. Its measured results and failures appear in the skill checks.",
            benchmarkBadge: "3B target finder; compare local skill results",
            isLocalHubNative: false
        ),
        // 5. ShowUI 2B (ShowLab)
        SpecialistGUIModel(
            id: "mlx-community/ShowUI-2B-bf16-4bit",
            name: "ShowUI · 2B GUI Grounding (4-bit MLX)",
            creator: "ShowLab / mlx-community",
            hfRepo: "mlx-community/ShowUI-2B-bf16-4bit",
            runtimeEngine: "mlx-vlm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .clickGrounding,
            specialtyHeadline: "Small GUI model with visual token selection",
            whenToPick: "Choose ShowUI for a compact screenshot locator. It returns a target location through the local adapter.",
            bestForTasks: [
                "Screenshot target grounding",
                "Interleaved vision, language and action research",
                "Comparing token selection strategies"
            ],
            whyDesignedAndArch: "ShowUI combines UI-guided visual token selection with interleaved vision-language-action sequences.",
            trainedOnCorpus: "The paper describes 256K training examples and evaluates zero-shot GUI grounding. Its benchmark is not an OpenCore measurement.",
            tradeoffsAndLimits: "The screenshot adapter uses this community Qwen2-VL conversion. Compare its local target-finding results and measured allocation before choosing it.",
            benchmarkBadge: "Research paper linked; compare local skill results",
            isLocalHubNative: false
        ),
        // 6. UGround V1 2B (OSU NLP)
        SpecialistGUIModel(
            id: "mlx-community/UGround-V1-2B",
            name: "UGround V1 · 2B Visual Locator",
            creator: "OSU NLP / mlx-community",
            hfRepo: "mlx-community/UGround-V1-2B",
            runtimeEngine: "mlx-vlm",
            quantization: "bf16 (unquantized)",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .clickGrounding,
            specialtyHeadline: "Visual grounding model for UI targets",
            whenToPick: "Choose UGround to turn a control description into a screenshot location. It is a locator, paired with a separate planner for broader tasks.",
            bestForTasks: [
                "Locating an element from a natural-language description",
                "Supplying coordinates to a separate planner",
                "Visual grounding evaluation"
            ],
            whyDesignedAndArch: "UGround-V1-2B is based on Qwen2-VL-2B. It separates target localization from broader task planning.",
            trainedOnCorpus: "The publisher provides a GUI grounding model and training references. Unverified dataset element and screenshot counts have been removed.",
            tradeoffsAndLimits: "Grounding is not a complete desktop agent. Coordinate conventions, conversion compatibility and performance require validation.",
            benchmarkBadge: "Grounding specialist; local skill checks available",
            isLocalHubNative: false
        ),
        // 7. Microsoft Fara 1.5 4B (Local Hub Validated)
        SpecialistGUIModel(
            id: "microsoft/Fara1.5-4B",
            name: "Fara 1.5 · 4B (Local Hub Vision Specialist)",
            creator: "Microsoft",
            hfRepo: "microsoft/Fara1.5-4B",
            runtimeEngine: "vmlx-fara",
            quantization: "4-bit",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .browserWeb,
            specialtyHeadline: "Screenshot-based web action model",
            whenToPick: "Use only when the Hub reports this exact model and runtime supported. Microsoft recommends its Fara or Magentic-Lite harness.",
            bestForTasks: [
                "Web screenshot action prediction",
                "Coordinate-grounded browser interaction",
                "Evaluating verified web-task trajectories"
            ],
            whyDesignedAndArch: "Fara1.5-4B is a Qwen3.5-4B model supervised fine-tuned for web computer use. Perception uses screenshots rather than a DOM.",
            trainedOnCorpus: "Microsoft describes FaraGen1.5 synthetic web tasks, successful verified trajectories, and curated grounding and UI-understanding data.",
            tradeoffsAndLimits: "The browser adapter runs locally. Its target checks and saved-form diagnostic are separate evidence; neither establishes reliability on arbitrary websites.",
            benchmarkBadge: "Hub support checked at runtime",
            isLocalHubNative: true
        ),
        // 8. Raptor 0.6 4B JANG 6M (Local Hub Validated)
        SpecialistGUIModel(
            id: "OsaurusAI/Raptor-0.6-4B-JANG_6M",
            name: "Raptor 0.6 · 4B JANG 6M (High Fidelity)",
            creator: "OsaurusAI",
            hfRepo: "OsaurusAI/Raptor-0.6-4B-JANG_6M",
            runtimeEngine: "vmlx-spark",
            quantization: "JANG 6M Mixed-Bit",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .toolPlanner,
            specialtyHeadline: "Tool planner tuned for the Osaurus harness",
            whenToPick: "Consider Raptor for structured tool planning when the connected Hub supports this exact quantization.",
            bestForTasks: [
                "Structured tool-call generation",
                "Comparing harness-specific action decisions",
                "Local text planning through a supported Hub runtime"
            ],
            whyDesignedAndArch: "The publisher describes supervised fine-tuning of Spark-X2.5-4B and JANG mixed-bit quantization. Harness behavior matters alongside the weights.",
            trainedOnCorpus: "The model card describes fine-tuning for tool use and action decisions in the Osaurus harness.",
            tradeoffsAndLimits: "Near-FP16 accuracy, strict schema reliability and this Mac memory usage have not been established by OpenCore.",
            benchmarkBadge: "JANG 6M; compare local skill results",
            isLocalHubNative: true
        ),
        // 9. Raptor 0.6 4B JANG 4M (Local Hub Validated)
        SpecialistGUIModel(
            id: "OsaurusAI/Raptor-0.6-4B-JANG_4M",
            name: "Raptor 0.6 · 4B JANG 4M (Fast Tier)",
            creator: "OsaurusAI",
            hfRepo: "OsaurusAI/Raptor-0.6-4B-JANG_4M",
            runtimeEngine: "vmlx-spark",
            quantization: "JANG 4M Mixed-Bit",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .toolPlanner,
            specialtyHeadline: "Alternative Raptor mixed-bit package",
            whenToPick: "Compare this package with 6M only when the Hub supports both and local measurements are available.",
            bestForTasks: [
                "Comparing supported quantization packages",
                "Structured tool-call experiments",
                "Local text planning"
            ],
            whyDesignedAndArch: "A separately packaged Raptor quantization. Package names alone do not prove equivalent behavior or a particular memory saving.",
            trainedOnCorpus: "Consult the publisher card for this exact package. No additional training or calibration method is inferred from its name.",
            tradeoffsAndLimits: "The previous 1.1 GB RAM saving and faster-token claims were unmeasured. Support and installation come from the Hub response.",
            benchmarkBadge: "Exact package support checked at runtime",
            isLocalHubNative: true
        ),
        // 10. Qwen 3 4B Instruct (Local Hub Validated)
        SpecialistGUIModel(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            name: "Qwen 3 · 4B Instruct (4-bit MLX)",
            creator: "Alibaba Qwen / mlx-community",
            hfRepo: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            runtimeEngine: "mlx-lm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .toolPlanner,
            specialtyHeadline: "General instruction model for text planning",
            whenToPick: "Use as a text planner when the Hub supports its exact MLX conversion. Test tool calls against the intended workflow.",
            bestForTasks: [
                "Instruction following",
                "Structured text and tool-call experiments",
                "Parameter generation for supported routines"
            ],
            whyDesignedAndArch: "The 2507 Instruct release is a 4B dense model with non-thinking instruction behavior and a publisher-specified 262,144-token context.",
            trainedOnCorpus: "Qwen describes pretraining and post-training improvements for instruction following, coding and tool use. A family-wide token total is not assigned to this specific card.",
            tradeoffsAndLimits: "It has no vision encoder. OCR text is separate input. Use the local file and control checks to assess this package; they do not measure general routine reliability.",
            benchmarkBadge: "Text planner; compare local skill results",
            isLocalHubNative: true
        ),
        // 11. Qwen 3 1.7B (Local Hub Validated)
        SpecialistGUIModel(
            id: "mlx-community/Qwen3-1.7B-4bit",
            name: "Qwen 3 · 1.7B Ultra-Light (4-bit MLX)",
            creator: "Alibaba Qwen / mlx-community",
            hfRepo: "mlx-community/Qwen3-1.7B-4bit",
            runtimeEngine: "mlx-lm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .toolPlanner,
            specialtyHeadline: "Small Qwen3 text model",
            whenToPick: "Consider this smaller text model for supported Hub experiments, then compare actual results with larger models.",
            bestForTasks: [
                "Simple instruction following",
                "Text planning experiments",
                "Comparing smaller local language models"
            ],
            whyDesignedAndArch: "A 1.7B dense model in the Qwen3 family, using a community MLX conversion.",
            trainedOnCorpus: "Refer to Qwen documentation for the family training process. This card does not assert that the model was distilled.",
            tradeoffsAndLimits: "Package size and local elapsed time are shown separately from MLX allocation. Smaller parameter count does not guarantee faster or correct tool use.",
            benchmarkBadge: "Small text planner; compare local skill results",
            isLocalHubNative: true
        ),
        // 12. Qwen 2.5 VL 7B Instruct (4-bit MLX)
        SpecialistGUIModel(
            id: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            name: "Qwen 2.5 VL · 7B Vision-Agent (4-bit MLX)",
            creator: "Alibaba Qwen / mlx-community",
            hfRepo: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            runtimeEngine: "mlx-vlm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .multiStepAgent,
            specialtyHeadline: "General vision-language model with localization",
            whenToPick: "Choose Qwen2.5-VL to read screenshot text and locate targets. Its reading and location checks are scored separately.",
            bestForTasks: [
                "Visual question answering",
                "Document and screenshot interpretation",
                "Structured spatial localization"
            ],
            whyDesignedAndArch: "Qwen2.5-VL combines dynamic-resolution vision processing with a language model and supports spatial localization outputs.",
            trainedOnCorpus: "The publisher describes multimodal training for visual understanding, documents and localization. Publisher benchmark results are not results for OpenCore.",
            tradeoffsAndLimits: "Runs through the local screenshot adapter. Screenshot size affects resources; inspect the recorded MLX peak rather than assuming a fixed RAM footprint.",
            benchmarkBadge: "Publisher card linked; no local accuracy claim",
            isLocalHubNative: false
        ),
        // 13. OS-Atlas Base 7B (4-bit MLX)
        SpecialistGUIModel(
            id: "prncvrm/OS-Atlas-Base-7B-4bit",
            name: "OS-Atlas · 7B Desktop Foundation (4-bit MLX)",
            creator: "OS-Copilot / prncvrm conversion",
            hfRepo: "prncvrm/OS-Atlas-Base-7B-4bit",
            runtimeEngine: "mlx-vlm",
            quantization: "4-bit MLX",
            sizeGB: nil,
            estRAMGB: nil,
            specialty: .multiStepAgent,
            specialtyHeadline: "Cross-platform GUI grounding model",
            whenToPick: "Choose OS-Atlas Base for desktop target localization. This package uses the prncvrm MLX conversion and a separate planner for broader tasks.",
            bestForTasks: [
                "Screenshot target localization",
                "Cross-platform grounding experiments",
                "Comparing GUI representations"
            ],
            whyDesignedAndArch: "OS-Atlas-Base-7B is a grounding model fine-tuned from Qwen2-VL-7B. Base grounding is distinct from an end-to-end action policy.",
            trainedOnCorpus: "The publisher supplies cross-platform GUI grounding data and training references. Unverified dataset counts have been removed.",
            tradeoffsAndLimits: "It does not by itself implement menu navigation or a complete autonomous workflow. Its local trial results include missed targets; inspect those before choosing it.",
            benchmarkBadge: "GUI grounding; local skill checks available",
            isLocalHubNative: false
        )
    ]

    private init() {
        scanInstalledCustomModels()
        // No demonstration is represented as recorded until the user records one.
    }

    var filteredCatalog: [SpecialistGUIModel] {
        guard selectedSpecialtyFilter != .all else { return specialistCatalog }
        return specialistCatalog.filter { $0.specialty == selectedSpecialtyFilter }
    }

    var activeLoadedSpecialist: SpecialistGUIModel? {
        guard let activeLoadedModelID else { return nil }
        return specialistCatalog.first { $0.id == activeLoadedModelID }
    }

    func isModelInstalled(_ model: SpecialistGUIModel, hubModels: [LocalHubModelEntry]) -> Bool {
        if model.id == "apple-system" { return true }
        return hubModels.first { $0.id == model.id || $0.repo == model.hfRepo }?.installed == true
    }

    func isModelSupported(_ model: SpecialistGUIModel, hubModels: [LocalHubModelEntry]) -> Bool {
        hubModels.first { $0.id == model.id || $0.repo == model.hfRepo }?.supported == true
    }

    func markRuntimeUnverified(_ reason: String) {
        if let activeLoadedModelID { lastConfirmedModelID = activeLoadedModelID }
        activeLoadedModelID = nil
        isRuntimeStateVerified = false
        activeRuntimeStatus = "readiness unverified"
        activeRuntimeEngine = "Not currently verified"
        activeModelError = reason
    }

    func applyRuntimeReceipt(_ runtime: [String: Any]) {
        guard !LocalHubContract.responseHasError(runtime), let status = runtime["status"] as? String,
              runtime["active"] is String || runtime["active"] is NSNull else {
            markRuntimeUnverified(runtime["error"] as? String ?? "The Hub did not return a complete runtime state.")
            return
        }
        activeLoadedModelID = runtime["active"] as? String
        lastConfirmedModelID = activeLoadedModelID
        isRuntimeStateVerified = true
        activeRuntimeStatus = status
        activeRuntimeEngine = runtime["engine"] as? String ?? "Not reported"
        activeModelError = nil
    }

    private func matchingHubEntry(modelID: String) async -> [String: Any]? {
        let ctrl = ComputerControlManager.shared
        if !ctrl.isHubServerOnline { await ctrl.probeHubServer() }
        guard let status = await ctrl.getHubObject(path: "/api/status"),
              let entries = status["models"] as? [[String: Any]] else { return nil }
        let repo = specialistCatalog.first { $0.id == modelID }?.hfRepo ?? modelID
        return entries.first { entry in
            (entry["id"] as? String) == modelID || (entry["source_id"] as? String) == repo || (entry["repo"] as? String) == repo
        }
    }

    private func modelActionFailed(_ id: String, _ message: String) {
        activeModelError = message
        failedModelActions.insert(id)
        modelCardTestOutputs[id] = message
        ActionFeedbackCenter.shared.record(button: "Model action: \(id)", command: "Local Hub runtime", outcome: message, status: .warning)
    }

    func scanInstalledCustomModels() {
        // Cache folders may be partial downloads. They are not installation receipts.
        downloadedCustomModels = []
    }

    // MARK: - LM Studio Style Load / Eject / Download / Verify Actions

    func loadModelIntoRAM(_ modelID: String) async {
        guard !isLoadingOrUnloadingModel else { return }
        isLoadingOrUnloadingModel = true
        activeModelError = nil
        defer { isLoadingOrUnloadingModel = false; UnifiedMemoryMonitor.shared.sampleMemory() }
        let ctrl = ComputerControlManager.shared
        guard let entry = await matchingHubEntry(modelID: modelID),
              let backendID = entry["id"] as? String,
              entry["supported"] as? Bool == true,
              (entry["adapter_ready"] as? Bool) != false else {
            modelActionFailed(modelID, ctrl.lastHubError ?? "This model has no available Local Hub runtime adapter. Its reference card does not establish support.")
            return
        }
        guard backendID == "apple-system" || LocalHubContract.installationComplete(entry) else {
            modelActionFailed(modelID, "The Hub has not confirmed a complete, revision-pinned installation. Finish its download first.")
            return
        }
        guard let receipt = await ctrl.postToHubServer(path: "/api/models/load", payload: ["id": backendID]),
              LocalHubContract.runtimeReady(receipt, modelID: backendID) else {
            modelActionFailed(modelID, ctrl.lastHubError ?? "The runtime did not confirm this model ready. No alternate engine was selected.")
            await ctrl.probeHubServer()
            return
        }
        applyRuntimeReceipt(receipt)
        ctrl.taskModelID = backendID
        failedModelActions.remove(modelID)
        modelCardTestOutputs[modelID] = "READY: Local Hub confirmed \(backendID) using \(activeRuntimeEngine). Model memory consumption has not been measured separately."
        ctrl.logAction(mode: "HUB", summary: "Model ready: \(backendID)", detail: activeRuntimeEngine)
        ActionFeedbackCenter.shared.record(button: "Load model", command: "POST /api/models/load", outcome: modelCardTestOutputs[modelID] ?? "Ready", status: .completed)
    }

    func ejectModelFromRAM() async {
        guard !isLoadingOrUnloadingModel else { return }
        isLoadingOrUnloadingModel = true
        defer { isLoadingOrUnloadingModel = false; UnifiedMemoryMonitor.shared.sampleMemory() }
        let ctrl = ComputerControlManager.shared
        let previous = activeLoadedModelID ?? "unknown"
        guard let receipt = await ctrl.postToHubServer(path: "/api/models/unload", payload: [:]),
              receipt["active"] is NSNull, receipt["status"] as? String == "unloaded", !LocalHubContract.responseHasError(receipt) else {
            modelActionFailed(previous, ctrl.lastHubError ?? "The Hub did not confirm an unloaded runtime. Freed memory has not been measured.")
            return
        }
        applyRuntimeReceipt(receipt)
        let message = "Local Hub confirmed the runtime is unloaded. The amount of freed memory was not measured."
        modelCardTestOutputs[previous] = message
        ActionFeedbackCenter.shared.record(button: "Unload model", command: "POST /api/models/unload", outcome: message, status: .completed)
    }

    func testModelCardQuickProbe(_ model: SpecialistGUIModel) async {
        await HubModelLab.shared.start(ids: [model.id])
    }

    func downloadModel(_ model: SpecialistGUIModel) async {
        let ctrl = ComputerControlManager.shared
        guard let entry = await matchingHubEntry(modelID: model.id), let backendID = entry["id"] as? String,
              entry["supported"] as? Bool == true,
              (entry["adapter_ready"] as? Bool) != false else {
            modelActionFailed(model.id, "This model is a reference only. A compatible, qualified Hub adapter is unavailable, so OpenCore will not download unusable weights.")
            return
        }
        guard let response = await ctrl.postToHubServer(path: "/api/models/download", payload: ["id": backendID]),
              response["started"] as? Bool == true else {
            modelActionFailed(model.id, ctrl.lastHubError ?? "The Hub did not start a download.")
            return
        }
        modelCardTestOutputs[model.id] = "Download started in Local Hub. Its pinned manifest validates required file sizes and hashes; partial files remain resumable."
        await pollHubDownload(modelID: backendID, totalEstimateBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0)
    }

    func addAndDownloadCustomHFRepo() async {
        let reference = customHFRepoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { modelActionFailed("custom", "Enter a public model repository."); return }
        let ctrl = ComputerControlManager.shared
        guard let model = await ctrl.postToHubServer(path: "/api/models/add", payload: ["reference": reference]),
              let id = model["id"] as? String, model["supported"] as? Bool == true else {
            modelActionFailed("custom", ctrl.lastHubError ?? "The Hub could not accept this model format.")
            return
        }
        guard let response = await ctrl.postToHubServer(path: "/api/models/download", payload: ["id": id]), response["started"] as? Bool == true else {
            modelActionFailed(id, ctrl.lastHubError ?? "The Hub did not start the download."); return
        }
        await pollHubDownload(modelID: id, totalEstimateBytes: (model["size"] as? NSNumber)?.int64Value ?? 0)
    }

    private func pollHubDownload(modelID: String, totalEstimateBytes: Int64) async {
        let ctrl = ComputerControlManager.shared
        activeDownloadProgress[modelID] = (0, max(totalEstimateBytes, 1), "Waiting for Hub receipt…", 0)
        defer { activeDownloadProgress.removeValue(forKey: modelID) }
        var lastBytes: Int64 = 0
        var lastTime = Date()
        for _ in 0..<600 {
            do { try await Task.sleep(for: .milliseconds(800)) } catch {
                modelActionFailed(modelID, "Stopped monitoring. The Hub still owns the download and its resumable partial files.")
                return
            }
            guard let entry = await matchingHubEntry(modelID: modelID) else {
                modelActionFailed(modelID, ctrl.lastHubError ?? "Cannot read the download state. Its completion is unverified.")
                return
            }
            if LocalHubContract.installationComplete(entry) {
                ctrl.reloadAllLocalHubData()
                failedModelActions.remove(modelID)
                modelCardTestOutputs[modelID] = "DOWNLOAD CONFIRMED: The Hub recorded all required files at the pinned revision after artifact size/hash checks. Model inference still needs a diagnostic."
                ActionFeedbackCenter.shared.record(button: "Download model", command: "Local Hub pinned manifest download", outcome: modelCardTestOutputs[modelID] ?? "Downloaded", status: .completed)
                return
            }
            guard let download = entry["download"] as? [String: Any] else { continue }
            let state = download["status"] as? String ?? "unknown"
            if ["failed", "canceled"].contains(state) {
                modelActionFailed(modelID, download["error"] as? String ?? "The download was \(state). Partial files were preserved by Local Hub.")
                return
            }
            let received = (download["received"] as? NSNumber)?.int64Value ?? 0
            let total = max((download["total"] as? NSNumber)?.int64Value ?? totalEstimateBytes, 1)
            let now = Date()
            let speed = Double(max(0, received - lastBytes)) / max(now.timeIntervalSince(lastTime), 0.1) / 1_048_576
            activeDownloadProgress[modelID] = (received, total, state, speed)
            lastBytes = received
            lastTime = now
        }
        modelActionFailed(modelID, "Stopped monitoring after eight minutes. The Hub may still be downloading. No installation has been claimed.")
    }

    private func downloadFromHuggingFaceDirectly(repo: String, modelID: String, displayName: String) async {
        // Downloads must use Hub model acceptance and its revision-pinned manifest.
        // This entry point intentionally cannot bypass format or artifact checks.
        modelActionFailed(modelID, "Use the Local Hub model catalog to validate this format before downloading. No files were changed.")
    }

    // MARK: - 6. "Watch Me & Repeat with Variations" Desktop + Browser Recorder

    func seedDefaultDemonstrationIfNeeded() {
        // Do not fabricate recorded user actions from a bundled demonstration.
    }

    func toggleDesktopWatching() {
        if isWatchingDesktop {
            stopWatchingDesktop()
        } else {
            startWatchingDesktop()
        }
    }

    func startWatchingDesktop() {
        // The previous global event recorder captured every app and secure-field
        // input without a qualified redaction/scope boundary. Do not start it.
        activeModelError = "Desktop recording is unavailable until app/window scoping and private-field filtering are qualified. Use Local Hub's scoped browser demonstration instead. Saved previews remain readable."
        ComputerControlManager.shared.logAction(mode: "BLOCKED", summary: "Desktop recording is unavailable", detail: activeModelError ?? "")
        ActionFeedbackCenter.shared.record(button: "Record demonstration", command: "Scoped recorder required", outcome: activeModelError ?? "Unavailable", status: .warning)
    }

    func stopWatchingDesktop() {
        flushPendingTypedBuffer()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        isWatchingDesktop = false
        let ctrl = ComputerControlManager.shared
        ctrl.logAction(
            mode: "WATCH-ME",
            summary: "Finished watching desktop demonstration (\(recordedSteps.count) steps captured)",
            detail: "Typed inputs automatically parameterized for repeat-with-variation execution."
        )
    }

    private func recordMouseClick(at point: CGPoint, isRightClick: Bool, clickCount: Int) {
        flushPendingTypedBuffer()
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
        // Ignore clicks inside OpenCore itself when possible unless testing
        let (role, title, winTitle) = inspectAccessibilityElement(at: point)
        let kind = isRightClick ? "right_click" : (clickCount >= 2 ? "double_click" : "click")
        let nextNum = recordedSteps.count + 1
        recordedSteps.append(
            RecordedActionStep(
                stepNumber: nextNum,
                actionKind: kind,
                appName: frontApp,
                windowTitle: winTitle.isEmpty ? frontApp : winTitle,
                elementRole: role,
                elementTitle: title.isEmpty ? "UI Target at (\(Int(point.x)), \(Int(point.y)))" : title,
                x: Int(point.x),
                y: Int(point.y),
                textValue: "",
                parameterName: nil,
                timestamp: Date()
            )
        )
    }

    private func recordKeyDown(characters: String, keyCode: UInt16) {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
        // Return / Enter key (36) or Tab (48) flushes the typed buffer and records the key
        if keyCode == 36 || keyCode == 76 {
            flushPendingTypedBuffer()
            let nextNum = recordedSteps.count + 1
            recordedSteps.append(
                RecordedActionStep(
                    stepNumber: nextNum,
                    actionKind: "keypress",
                    appName: frontApp,
                    windowTitle: frontApp,
                    elementRole: "AXKeyboard",
                    elementTitle: "Press Return (↵)",
                    x: recordedSteps.last?.x ?? 400,
                    y: recordedSteps.last?.y ?? 300,
                    textValue: "RETURN",
                    parameterName: nil,
                    timestamp: Date()
                )
            )
            return
        }
        guard !characters.isEmpty,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else {
            return
        }
        pendingTypedApp = frontApp
        pendingTypedWindow = frontApp
        pendingTypedBuffer.append(characters)
    }

    private func flushPendingTypedBuffer() {
        let trimmed = pendingTypedBuffer
        guard !trimmed.isEmpty else { return }
        pendingTypedBuffer = ""
        let paramCount = recordedSteps.filter { $0.parameterName != nil }.count + 1
        let paramName = paramCount == 1 ? "target_item" : "input_\(paramCount)"
        let lastX = recordedSteps.last?.x ?? 400
        let lastY = recordedSteps.last?.y ?? 300
        let nextNum = recordedSteps.count + 1
        recordedSteps.append(
            RecordedActionStep(
                stepNumber: nextNum,
                actionKind: "type",
                appName: pendingTypedApp.isEmpty ? "macOS" : pendingTypedApp,
                windowTitle: pendingTypedWindow.isEmpty ? "Window" : pendingTypedWindow,
                elementRole: "AXTextField",
                elementTitle: "Typed Input ({{\(paramName)}})",
                x: lastX,
                y: lastY,
                textValue: trimmed,
                parameterName: paramName,
                timestamp: Date()
            )
        )
    }

    private func inspectAccessibilityElement(at point: CGPoint) -> (role: String, title: String, windowTitle: String) {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard err == .success, let element = elementRef else {
            return ("AXElement", "", "")
        }
        func attr(_ el: AXUIElement, _ key: String) -> String {
            var val: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, key as CFString, &val) == .success,
                  let str = val as? String else { return "" }
            return str
        }
        let role = attr(element, kAXRoleAttribute)
        let title = [attr(element, kAXTitleAttribute), attr(element, kAXDescriptionAttribute), attr(element, kAXValueAttribute)]
            .first { !$0.isEmpty } ?? ""
        var winRef: CFTypeRef?
        var winTitle = ""
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
           let win = winRef {
            winTitle = attr(win as! AXUIElement, kAXTitleAttribute)
        }
        return (role.isEmpty ? "AXElement" : role, String(title.prefix(60)), String(winTitle.prefix(60)))
    }

    // MARK: - Synthesize Parameterized Variations for Repeat Loop

    func synthesizeVariationPasses() async {
        guard !isGeneratingVariations, !isReplayingLoop else { return }
        let count = min(max(repeatCount, 1), 50)
        let parameters = Set(recordedSteps.compactMap(\.parameterName)).sorted()
        guard parameters.count == 1, let parameter = parameters.first else {
            activeModelError = "Variation preview currently supports one named input. Record or choose a workflow with exactly one parameter."
            return
        }
        isGeneratingVariations = true
        defer { isGeneratingVariations = false }
        do {
            let session = LanguageModelSession(instructions: "Return only a JSON array containing exactly \(count) strings. Do not invent inputs the user did not request.")
            let response = try await session.respond(to: "Generate input variations for parameter \(parameter). User instruction: \(variationInstruction)")
            try Task.checkCancellation()
            let raw = response.content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8), let values = try JSONSerialization.jsonObject(with: data) as? [String],
                  values.count == count, values.allSatisfy({ !$0.isEmpty && $0.count <= 4000 }) else {
                activeModelError = "Apple's model did not return the requested input list. No fallback values were invented."
                return
            }
            generatedPasses = values.enumerated().map { index, value in
                ReplayVariationPass(passIndex: index + 1, parameters: [parameter: value], summary: "Pass \(index + 1): \(value)", status: "preview")
            }
        } catch is CancellationError { return }
        catch { activeModelError = "Variation generation failed: \(error.localizedDescription)" }
    }

    func runWatchAndRepeatLoop() async {
        guard !isReplayingLoop else { return }
        let ctrl = ComputerControlManager.shared
        guard ctrl.isDryRun else {
            activeModelError = "Live coordinate replay is unavailable: stored coordinates do not establish the current app, field identity, or replacement behavior. Use a scoped Hub routine for live replay."
            ctrl.logAction(mode: "BLOCKED", summary: "Live replay unavailable", detail: activeModelError ?? "")
            return
        }
        let steps = recordedSteps
        let passes = generatedPasses
        guard !steps.isEmpty, !passes.isEmpty, passes.count <= 50,
              steps.count <= 100, passes.count <= 100 / steps.count else {
            activeModelError = "Generate a preview first. A preview is limited to 100 total steps across at most 50 passes."
            return
        }
        let supported = Set(["activate_app", "click", "double_click", "right_click", "type", "keypress", "move"])
        guard steps.allSatisfy({ supported.contains($0.actionKind) }),
              steps.filter({ $0.actionKind == "keypress" }).allSatisfy({ ["RETURN", "TAB", "ESCAPE", "BACKSPACE"].contains($0.textValue.uppercased()) }) else {
            activeModelError = "This workflow contains an unsupported action. The preview stopped; no action was substituted."
            return
        }
        isReplayingLoop = true
        defer { isReplayingLoop = false }
        for (index, pass) in passes.enumerated() {
            guard isReplayingLoop, !Task.isCancelled, generatedPasses.indices.contains(index), generatedPasses[index].id == pass.id else { return }
            generatedPasses[index].status = "previewing"
            currentReplayPassIndex = index + 1
            for step in steps {
                guard isReplayingLoop, !Task.isCancelled else { generatedPasses[index].status = "canceled"; return }
                currentReplayStepIndex = step.stepNumber
                let point = CGPoint(x: step.x, y: step.y)
                switch step.actionKind {
                case "click", "double_click", "move":
                    guard ctrl.previewPointer(action: step.actionKind, at: point, label: step.elementTitle) else {
                        generatedPasses[index].status = "invalid preview target"
                        return
                    }
                case "type":
                    let value = step.parameterName.flatMap { pass.parameters[$0] } ?? step.textValue
                    dispatchTypedText(value, at: point, dryRun: true, passIndex: index + 1)
                case "right_click", "keypress", "activate_app":
                    ctrl.logAction(mode: "DRY-RUN", summary: "Preview \(step.actionKind): \(step.elementTitle)", detail: "No mouse, key or app activation event was sent.")
                default: return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { generatedPasses[index].status = "canceled"; return }
            }
            generatedPasses[index].status = "simulated; result unverified"
        }
    }

    private func dispatchTypedText(_ text: String, at point: CGPoint, dryRun: Bool, passIndex: Int) {
        let ctrl = ComputerControlManager.shared
        guard dryRun else {
            ctrl.logAction(mode: "BLOCKED", summary: "Unscoped field typing unavailable", detail: "Field identity and replacement semantics must be supplied by a scoped Hub routine.")
            return
        }
        ctrl.targetReticlePoint = point
        ctrl.logAction(mode: "DRY-RUN", summary: "Preview typing for pass \(passIndex)", detail: "Would type \(text.count) characters. No field was changed and no replacement was claimed.")
    }

    // MARK: - 7. "Tell It What To Do & Watch It Figure It Out" Autonomous Cognitive Loop

    func runAutonomousWatchItFigureItOutLoop() async {
        guard !isRunningAutonomousLoop else { return }
        let ctrl = ComputerControlManager.shared
        guard ctrl.isDryRun else {
            activeModelError = "This screen planner is a dry-run preview. Run a scoped task with its selected model and an independent completion check for live automation."
            return
        }
        guard selectedSpecialistModelID == "apple-system" else {
            activeModelError = "This preview uses Apple's on-device text planner. Other models are available only through their supported scoped Hub runtime."
            return
        }
        isRunningAutonomousLoop = true
        cognitiveTraces.removeAll()
        defer { isRunningAutonomousLoop = false }
        currentCognitiveStage = .observe
        await ctrl.captureScreenAndAnalyze()
        guard isRunningAutonomousLoop, !Task.isCancelled else { return }
        guard !ctrl.detectedElements.isEmpty else {
            activeModelError = (ctrl.screenScanProblem ?? ComputerStudioDiagnosis.screenScanEmpty()).text
            return
        }
        cognitiveTraces.append(CognitiveTraceEntry(stepIndex: 0, stage: .observe, timestamp: Date(), headline: "Screen observed for preview", thoughtOrEvidence: "Detected \(ctrl.detectedElements.count) text/control candidates. This does not verify task completion.", targetPoint: nil, succeeded: true))
        currentCognitiveStage = .think
        await ctrl.planTaskWithOnDeviceFM(goal: autonomousGoal)
        guard isRunningAutonomousLoop, !Task.isCancelled else { return }
        let budget = min(max(autonomousMaxSteps, 1), 25)
        let plan = Array(ctrl.plannedSteps.prefix(budget))
        guard !plan.isEmpty else {
            activeModelError = "The planner returned no supported pointer actions. No fallback click was generated."
            return
        }
        cognitiveTraces.append(CognitiveTraceEntry(stepIndex: 0, stage: .think, timestamp: Date(), headline: "Apple planner returned \(plan.count) pointer preview steps", thoughtOrEvidence: "Typing and scrolling require a scoped Hub task and are rejected by this preview.", targetPoint: nil, succeeded: true))
        for (index, step) in plan.enumerated() {
            guard isRunningAutonomousLoop, !Task.isCancelled, ctrl.isDryRun else { return }
            currentAutonomousStep = index + 1
            currentCognitiveStage = .ground
            let point = CGPoint(x: step.x, y: step.y)
            ctrl.targetReticlePoint = point
            currentCognitiveStage = .act
            switch step.action {
            case "click", "double_click", "move":
                guard ctrl.previewPointer(action: step.action, at: point, label: step.targetLabel) else { return }
            default: activeModelError = "Unsupported action \(step.action). Preview stopped."; return
            }
            cognitiveTraces.append(CognitiveTraceEntry(stepIndex: index + 1, stage: .act, timestamp: Date(), headline: "SIMULATED \(step.action) · \(step.targetLabel)", thoughtOrEvidence: "Reticle preview only. No input event was sent.", targetPoint: point, succeeded: true))
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        currentCognitiveStage = .verify
        cognitiveTraces.append(CognitiveTraceEntry(stepIndex: plan.count + 1, stage: .verify, timestamp: Date(), headline: "Outcome not verified", thoughtOrEvidence: "Simulation changed no app state. Use a scoped Hub task and its independent result receipt to establish completion.", targetPoint: ctrl.targetReticlePoint, succeeded: false))
    }

}

// MARK: - 8. LM Studio-Style Unified Memory & Active Model Switchboard Bar View

struct LMStudioMemoryAndModelDeck: View {
    @State private var mem = UnifiedMemoryMonitor.shared
    @State private var studio = ComputerUseStudioController.shared
    @State private var ctrl = ComputerControlManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Row: Active Model Switchboard (LM Studio Style)
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(studio.isRuntimeStateVerified && studio.activeRuntimeStatus == "ready" && studio.activeLoadedModelID != nil ? Pastel.mint : Pastel.butter)
                        .frame(width: 10, height: 10)
                    Text(studio.isRuntimeStateVerified ? "CONFIRMED RUNTIME:" : "RUNTIME STATUS UNKNOWN:")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Pastel.ice)
                }

                Picker("Loaded Model", selection: Binding(
                    get: { studio.activeLoadedModelID ?? "none" },
                    set: { newID in
                        Task {
                            if newID == "none" { await studio.ejectModelFromRAM() }
                            else { await studio.loadModelIntoRAM(newID) }
                        }
                    }
                )) {
                    Text(studio.activeLoadedModelID != nil ? "Unload current model" : (studio.isRuntimeStateVerified ? "No model loaded" : "Readiness unverified")).tag("none")
                    ForEach(studio.specialistCatalog.filter { studio.isModelSupported($0, hubModels: ctrl.models) }) { item in
                        let installed = studio.isModelInstalled(item, hubModels: ctrl.models)
                        Text("\(item.name) — \(item.specialty.rawValue) (\(installed ? item.resourceDescription : "Download Needed"))")
                            .tag(item.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 460)
                .disabled(studio.isLoadingOrUnloadingModel)

                if let activeSpec = studio.activeLoadedSpecialist {
                    Text(activeSpec.specialty.rawValue.uppercased())
                        .openCorePastelBadge(activeSpec.specialty.accent)
                    Text("MODEL RAM NOT MEASURED")
                        .openCorePastelBadge(Pastel.mint)
                } else {
                    Text(studio.activeRuntimeStatus.uppercased())
                        .openCorePastelBadge(Pastel.butter)
                }

                Spacer()

                if studio.activeLoadedModelID != nil {
                    Button {
                        Task { await studio.ejectModelFromRAM() }
                    } label: {
                        Label("Eject Model from RAM", systemImage: "eject.fill")
                            .font(.caption.weight(.bold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.rose)
                    .disabled(studio.isLoadingOrUnloadingModel)
                }

                Button {
                    Task {
                        let target = studio.activeLoadedModelID ?? studio.selectedSpecialistModelID
                        await studio.loadModelIntoRAM(target)
                    }
                } label: {
                    Label(studio.isLoadingOrUnloadingModel ? "Loading..." : "Reload / Warm RAM", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.mint)
                .disabled(studio.isLoadingOrUnloadingModel)
            }

            if !studio.isRuntimeStateVerified, let lastKnown = studio.lastConfirmedModelID {
                Text("Last confirmed model: \(lastKnown). Its current load state and readiness are unknown until Local Hub reconnects.")
                    .font(.caption).foregroundStyle(Pastel.butter)
            }

            if !mem.hasMemorySample {
                Text("Memory sample unavailable. Values below do not represent a successful measurement.")
                    .font(.caption).foregroundStyle(Pastel.butter)
            }
            // VM counters are sampled system data; they do not attribute model memory.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Label("\(mem.gpuDeviceName) Unified Memory", systemImage: "memorychip.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Pastel.sky)

                    Text(String(format: "Total: %.1f GiB · Wired: %.1f GiB · Active pages: %.1f GiB · Free pages: %.1f GiB",
                                mem.totalRAMGiB, mem.wiredAndGPUGiB, mem.activeAppGiB, mem.freeGiB))
                        .font(.caption.monospaced())
                        .foregroundStyle(Pastel.ice)

                    Spacer()

                    Text("Metal Max Budget: \(String(format: "%.1f GiB", mem.metalRecommendedMaxGiB)) · \(mem.pressureLevel)")
                        .openCorePastelBadge(mem.pressureLevel == "Nominal" ? Pastel.mint : Pastel.peach)
                }

                GeometryReader { geo in
                    let total = max(mem.totalRAMGiB, 1.0)
                    let modelRAM = 0.0 // Per-model memory has not been measured; do not subtract an estimate from sampled pages.
                    let wWired = CGFloat(min(mem.wiredAndGPUGiB / total, 1.0)) * geo.size.width
                    let wModel = CGFloat(min(modelRAM / total, 0.5)) * geo.size.width
                    let wActive = CGFloat(min(max(0, mem.activeAppGiB - modelRAM) / total, 1.0)) * geo.size.width
                    let wComp = CGFloat(min(mem.compressedGiB / total, 1.0)) * geo.size.width

                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Pastel.lavender)
                            .frame(width: max(0, wWired))
                        if modelRAM > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Pastel.mint)
                                .frame(width: max(10, wModel))
                        }
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Pastel.sky)
                            .frame(width: max(0, wActive))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Pastel.peach)
                            .frame(width: max(0, wComp))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.05))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 10)
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.lavender)
    }
}

// MARK: - 9. Watch-Me & Repeat with Variations Studio View + Autonomous Execution Theatre View

struct WatchAndRepeatAndAutonomousStudioView: View {
    @State private var studio = ComputerUseStudioController.shared
    @State private var ctrl = ComputerControlManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section A: "Tell It What To Do & Watch It Figure It Out" (Observe -> Think -> Ground -> Act -> Verify)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Label("Screen Plan Preview · Apple On-Device Planner", systemImage: "sparkles.tv.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.sky)
                    Spacer()
                    Button {
                        ctrl.requestMode(ctrl.isDryRun ? .live : .dryRun)
                    } label: {
                        Text(ctrl.isDryRun ? "DRY-RUN SIMULATION (SAFE)" : "LIVE MAC EXECUTION ARMED")
                            .openCorePastelBadge(ctrl.isDryRun ? Pastel.mint : Pastel.peach)
                    }
                    .buttonStyle(.plain)
                }

                Text("This is a dry-run pointer preview using Apple's on-device text planner. It cannot establish that a task was completed. Use Scoped Tasks & Saved Routines for live execution.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = studio.activeModelError {
                    Text(message).font(.caption).foregroundStyle(Pastel.butter)
                }
                Stepper("Preview step limit: \(studio.autonomousMaxSteps)", value: $studio.autonomousMaxSteps, in: 1...25)

                // 5-Stage Cognitive Pipeline Indicator
                HStack(spacing: 8) {
                    ForEach(CognitiveStage.allCases) { stage in
                        let isCurrent = studio.isRunningAutonomousLoop && studio.currentCognitiveStage == stage
                        let isDone = studio.cognitiveTraces.contains { $0.stage == stage }
                        HStack(spacing: 6) {
                            Image(systemName: stage.symbol)
                                .foregroundStyle(isCurrent ? stage.accent : (isDone ? Pastel.mint : .secondary))
                            Text(stage.rawValue)
                                .font(.system(size: 11, weight: isCurrent ? .bold : .semibold, design: .monospaced))
                                .foregroundStyle(isCurrent ? .primary : (isDone ? Pastel.ice : .secondary))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            isCurrent ? stage.accent.opacity(0.24) : (isDone ? Pastel.mint.opacity(0.10) : Color.primary.opacity(0.05)),
                            in: .rect(cornerRadius: 9)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isCurrent ? stage.accent : (isDone ? Pastel.mint.opacity(0.45) : Color.primary.opacity(0.12)), lineWidth: isCurrent ? 1.5 : 0.8)
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField("Tell the agent what to do on your Mac...", text: $studio.autonomousGoal)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        ComputerRunCenter.shared.launch(.screenPlanPreview) { _ in
                            await studio.runAutonomousWatchItFigureItOutLoop()
                        }
                    } label: {
                        Label(
                            studio.isRunningAutonomousLoop ? "Running Step \(studio.currentAutonomousStep)..." : "Preview Pointer Plan",
                            systemImage: "play.circle.fill"
                        )
                        .font(.callout.weight(.bold))
                    }
                    .openCoreGlassButton(prominent: true, tint: Pastel.sky)
                    .disabled(studio.isRunningAutonomousLoop || !ctrl.isDryRun)
                }

                if !studio.cognitiveTraces.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(studio.cognitiveTraces) { trace in
                            HStack(alignment: .top, spacing: 10) {
                                Text(trace.stage.rawValue)
                                    .openCorePastelBadge(trace.stage.accent)
                                    .frame(width: 150, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(trace.headline)
                                        .font(.callout.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text(trace.thoughtOrEvidence)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Pastel.ice)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .openCoreGlassCard(cornerRadius: 10, tint: trace.stage.accent)
                        }
                    }
                }
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)

            // Section B: "Watch How I Do Something -> Repeat with Instructions for Variation"
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Watch How I Do Something & Repeat It with Variations", systemImage: "record.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Pastel.mint)
                        Text("Desktop recording and live coordinate replay are unavailable until app/window scoping, private-field filtering and field replacement are qualified. Use Local Hub for scoped browser demonstrations and saved routines. Existing previews can be inspected here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        studio.toggleDesktopWatching()
                    } label: {
                        Label(
                            studio.isWatchingDesktop ? "■ Stop Watching (\(studio.recordedSteps.count) steps)" : "● Start Watching Me (Desktop & Apps)",
                            systemImage: studio.isWatchingDesktop ? "stop.circle.fill" : "record.circle"
                        )
                        .font(.callout.weight(.bold))
                    }
                    .openCoreGlassButton(prominent: true, tint: studio.isWatchingDesktop ? Pastel.rose : Pastel.mint)
                    .disabled(true)
                    .help("Desktop recording has no qualified app/window boundary or private-field filter.")

                    Button("Clear Steps") {
                        studio.recordedSteps.removeAll()
                        studio.generatedPasses.removeAll()
                    }
                    .controlSize(.small)
                    .openCoreGlassButton()
                    .disabled(studio.isReplayingLoop || studio.isGeneratingVariations)
                }

                if studio.recordedSteps.isEmpty {
                    Text(ComputerStudioDiagnosis.noRecordedSteps().text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Recorded Steps Table
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECORDED DEMONSTRATION STEPS (\(studio.recordedSteps.count) STEPS — EDITABLE)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Pastel.aqua)

                    ForEach($studio.recordedSteps) { $step in
                        HStack(spacing: 10) {
                            Text("#\(step.stepNumber)")
                                .openCorePastelBadge(Pastel.sky)
                            Text(step.actionKind.uppercased())
                                .openCorePastelBadge(step.actionKind == "type" ? Pastel.butter : Pastel.mint)
                            Text(step.appName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Pastel.lavender)
                            Text(step.elementTitle)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                            Text("(\(step.x), \(step.y))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if step.actionKind == "type" {
                                TextField("Typed value", text: $step.textValue)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                                Text("{{\(step.parameterName ?? "target_item")}}")
                                    .openCorePastelBadge(Pastel.butter)
                            }
                        }
                        .padding(8)
                        .openCoreGlassCard(cornerRadius: 8)
                    }
                }

                // Variation Instruction + Repeat Count Bar
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Variation Instruction for Repeat Loop:")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.butter)
                        Stepper("Repeat Count: \(studio.repeatCount)x", value: $studio.repeatCount, in: 1...50)
                            .font(.caption.monospaced().weight(.bold))
                        Spacer()
                        Button {
                            Task { await studio.synthesizeVariationPasses() }
                        } label: {
                            Label(studio.isGeneratingVariations ? "Synthesizing..." : "1. Generate Variations (/fm)", systemImage: "wand.and.stars")
                                .font(.caption.weight(.bold))
                        }
                        .openCoreGlassButton(tint: Pastel.butter)

                        Button {
                            ComputerRunCenter.shared.launch(.replayPreview) { _ in
                                await studio.runWatchAndRepeatLoop()
                            }
                        } label: {
                            Label(
                                studio.isReplayingLoop ? "Replaying Pass #\(studio.currentReplayPassIndex)..." : "2. Preview Replay (\(studio.repeatCount)x)",
                                systemImage: "repeat.circle.fill"
                            )
                            .font(.callout.weight(.bold))
                        }
                        .openCoreGlassButton(prominent: true, tint: Pastel.mint)
                        .disabled(studio.recordedSteps.isEmpty || studio.isReplayingLoop || !ctrl.isDryRun)
                    }

                    TextField("Describe how each repeat pass should vary...", text: $studio.variationInstruction)
                        .textFieldStyle(.roundedBorder)
                }

                // Generated Variation Passes Preview
                if !studio.generatedPasses.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GENERATED VARIATION MATRIX (\(studio.generatedPasses.count) PASSES)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.butter)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)], spacing: 8) {
                            ForEach(studio.generatedPasses) { pass in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pass.summary)
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                    Spacer()
                                    Text(pass.status.uppercased())
                                        .openCorePastelBadge(pass.status == "completed" ? Pastel.mint : (pass.status == "running" ? Pastel.butter : Pastel.sky))
                                }
                                .padding(10)
                                .openCoreGlassCard(cornerRadius: 8, tint: pass.status == "completed" ? Pastel.mint : Pastel.butter)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
        }
    }
}

// MARK: - 10. Specialist Computer-Use Model Hub & Downloader View

struct SpecialistComputerUseModelZooView: View {
    @State private var studio = ComputerUseStudioController.shared
    @State private var ctrl = ComputerControlManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Task Specialty Filter Bar + Custom HF Repo Downloader
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Label("Specialist Computer-Use Model Zoo (13 Curated GUI & Action Models)", systemImage: "cpu.fill")
                        .font(.headline)
                        .foregroundStyle(Pastel.lavender)
                    Spacer()
                    TextField("Add a Hub-compatible public model repository", text: $studio.customHFRepoInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 380)
                    Button {
                        Task { await studio.addAndDownloadCustomHFRepo() }
                    } label: {
                        Label("Validate & Download", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.bold))
                    }
                    .openCoreGlassButton(prominent: true, tint: Pastel.lavender)
                }

                if let err = studio.activeModelError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Pastel.rose)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SpecialistGUIModel.TaskSpecialty.allCases) { spec in
                            let selected = studio.selectedSpecialtyFilter == spec
                            Button {
                                studio.selectedSpecialtyFilter = spec
                                ActionFeedbackCenter.shared.record(
                                    button: "Filter Model Zoo -> \(spec.rawValue)",
                                    command: "selectedSpecialtyFilter = .\(spec.id)",
                                    outcome: "Showing \(studio.filteredCatalog.count) specialist model(s) in category '\(spec.rawValue)'.",
                                    status: .completed
                                )
                            } label: {
                                Text(spec.rawValue)
                                    .font(.caption.weight(selected ? .bold : .medium))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selected ? spec.accent.opacity(0.24) : Color.primary.opacity(0.05), in: .capsule)
                                    .overlay {
                                        Capsule().strokeBorder(selected ? spec.accent : Color.primary.opacity(0.12), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .openCoreGlassCard(cornerRadius: 14, tint: Pastel.lavender)

            // Specialist Model Grid
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 16)], spacing: 16) {
                ForEach(studio.filteredCatalog) { model in
                    let isInstalled = studio.isModelInstalled(model, hubModels: ctrl.models)
                    let isLoaded = studio.activeLoadedModelID == model.id
                    let dlProgress = studio.activeDownloadProgress[model.id]
                    let inlineTestOutput = studio.modelCardTestOutputs[model.id]

                    VStack(alignment: .leading, spacing: 12) {
                        // 1. Header Row
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(model.name)
                                        .font(.title3.weight(.bold))
                                    Text(model.specialty.rawValue)
                                        .openCorePastelBadge(model.specialty.accent)
                                    if isLoaded {
                                        Text(model.id == "apple-system" ? "ACTIVE (SYSTEM)" : "LOADED IN RAM")
                                            .openCorePastelBadge(Pastel.mint)
                                    } else if isInstalled {
                                        Text("ON DISK")
                                            .openCorePastelBadge(Pastel.sky)
                                    } else {
                                        Text("LOCAL · HF WEIGHTS")
                                            .openCorePastelBadge(Pastel.butter)
                                    }
                                }
                                Text("Creator: \(model.creator) · Source: \(model.id == "apple-system" ? "macOS system model" : model.hfRepo) · Engine: \(model.runtimeEngine) · Quant: \(model.quantization)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(HubModelLab.shared.model(model.id).map { $0.id == "apple-system" ? "OS managed" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) + " package" } ?? model.resourceDescription)
                                .openCorePastelBadge(Pastel.aqua)
                        }

                        // 2. Specialty Headline
                        Text(model.specialtyHeadline)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(model.specialty.accent)

                        ModelSkillResultsView(modelID: model.id)

                        // 3. Obvious Decision Rule ("WHEN TO PICK THIS MODEL")
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "scope")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(Pastel.butter)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("WHEN TO PICK THIS MODEL (DECISION RULE)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Pastel.butter)
                                Text(model.whenToPick)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Pastel.butter.opacity(0.11), in: .rect(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Pastel.butter.opacity(0.35), lineWidth: 0.9)
                        }

                        // 4. Concrete Use-Case Strengths
                        VStack(alignment: .leading, spacing: 5) {
                            Text("INTENDED STRENGTHS · PUBLISHER ROLE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.mint)
                            ForEach(model.bestForTasks, id: \.self) { task in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Pastel.mint)
                                        .padding(.top, 2)
                                    Text(task)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        // 5. Deep Fidelity: Why It Was Designed + What It Was Trained On + Limits
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cpu")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Pastel.sky)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("WHY IT WAS DESIGNED & ARCHITECTURE")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Pastel.sky)
                                    Text(model.whyDesignedAndArch)
                                        .font(.caption)
                                        .foregroundStyle(Pastel.ice)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Divider().opacity(0.4)

                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cylinder.split.1x2.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Pastel.lavender)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("WHAT IT WAS TRAINED ON (CORPUS & RL METHOD)")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Pastel.lavender)
                                    Text(model.trainedOnCorpus)
                                        .font(.caption)
                                        .foregroundStyle(Pastel.ice)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Divider().opacity(0.4)

                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "gauge.with.dots.needle.67percent")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Pastel.peach)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("TRADEOFFS & HONEST LIMITS")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Pastel.peach)
                                    Text(model.tradeoffsAndLimits)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                        }

                        // 6. Download Progress OR Inline Live Action Readout
                        if let dl = dlProgress {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text(dl.status)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Pastel.butter)
                                    Spacer()
                                    if dl.speedMBps > 0 {
                                        Text(String(format: "%.1f MB/s", dl.speedMBps))
                                            .font(.caption.monospaced().weight(.bold))
                                            .foregroundStyle(Pastel.mint)
                                    }
                                }
                                ProgressView(value: Double(dl.receivedBytes), total: Double(max(dl.totalBytes, 1)))
                                    .tint(Pastel.mint)
                            }
                        }

                        if let inlineTestOutput {
                            let resultColor = studio.failedModelActions.contains(model.id) ? Pastel.peach : Pastel.mint
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "waveform.path.ecg")
                                    .foregroundStyle(resultColor)
                                    .font(.caption.weight(.bold))
                                Text(inlineTestOutput)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(resultColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(8)
                            .background(resultColor.opacity(0.12), in: .rect(cornerRadius: 8))
                        }

                        if !studio.isModelSupported(model, hubModels: ctrl.models) {
                            Text("Connect the local model service and its runtime before using these controls. Local results above show what has actually been tested.")
                                .font(.caption).foregroundStyle(Pastel.butter)
                        }
                        Text("Card specifications and benchmark claims are reference information, not measurements from this Mac.")
                            .font(.caption2).foregroundStyle(.secondary)

                        // 7. Action Bar
                        HStack(spacing: 8) {
                            Text(model.benchmarkBadge)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(Pastel.butter)

                            Spacer()

                            Button {
                                Task { await studio.testModelCardQuickProbe(model) }
                            } label: {
                                Label("Run skill checks", systemImage: "stethoscope")
                                    .font(.caption.weight(.semibold))
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(tint: Pastel.aqua, telemetryLabel: "Probe Model: \(model.name)")
                            .disabled(!isInstalled || !studio.isModelSupported(model, hubModels: ctrl.models) || studio.isLoadingOrUnloadingModel || HubModelLab.shared.busy)
                            .help("Load and test this model on the local skill fixtures")

                            if !isInstalled && dlProgress == nil {
                                Button {
                                    Task { await studio.downloadModel(model) }
                                } label: {
                                    Label("Download", systemImage: "arrow.down.circle.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(prominent: true, tint: Pastel.sky, telemetryLabel: "Download Model: \(model.name)")
                                .disabled(!studio.isModelSupported(model, hubModels: ctrl.models) || studio.isLoadingOrUnloadingModel || HubModelLab.shared.busy)
                            }

                            if isLoaded {
                                Button {
                                    Task { await studio.ejectModelFromRAM() }
                                } label: {
                                    Label(model.id == "apple-system" ? "Unselect (OS Built-In)" : "Eject from RAM", systemImage: "eject.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(prominent: true, tint: Pastel.rose, telemetryLabel: "Eject Model: \(model.name)")
                            } else {
                                Button {
                                    Task {
                                        if !isInstalled {
                                            await studio.downloadModel(model)
                                        }
                                        await studio.loadModelIntoRAM(model.id)
                                    }
                                } label: {
                                    Label(isInstalled ? "Load into RAM" : "Download & Load", systemImage: "bolt.horizontal.circle.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(prominent: isInstalled, tint: Pastel.mint, telemetryLabel: "Load into RAM: \(model.name)")
                                .disabled(!studio.isModelSupported(model, hubModels: ctrl.models) || studio.isLoadingOrUnloadingModel || HubModelLab.shared.busy)
                            }

                            if let url = model.publisherURL {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(telemetryLabel: "Open publisher reference: \(model.name)")
                            }
                        }
                    }
                    .padding(16)
                    .openCoreGlassCard(cornerRadius: 14, tint: isLoaded ? Pastel.mint : model.specialty.accent)
                }
            }
        }
    }
}
