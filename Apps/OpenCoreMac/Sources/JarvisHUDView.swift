import AppKit
import AVFAudio
import CoreIngest
import CoreModel
import CoreReason
import CoreStore
import CoreTelemetry
import Observation
import Speech
import SwiftUI

/// J.A.R.V.I.S. Executive Briefing, On-Device Voice, and Multimodal Vision Controller.
///
/// Built on `MacOSX27.0.sdk` frameworks (cited 2026-10-22):
/// - `FoundationModels` (`SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `/usr/bin/fm`)
/// - `Vision` (`VNRecognizeTextRequest`, `VNDetectBarcodesRequest`)
/// - `Speech` & `AVFAudio` (`SFSpeechRecognizer`, `AVAudioEngine`, `AVSpeechSynthesizer`)
@MainActor
@Observable
final class JarvisController: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = JarvisController()

    var telemetry: Conversation.FoundationModelsTelemetry = Conversation.telemetry()

    // Executive Briefing state
    var isGeneratingBriefing = false
    var briefingHeadline = ""
    var briefingPoints: [BriefingItem] = []
    var briefingSummary: String?
    var lastBriefingAt: Date?

    // Voice Input & Neural Readback state
    var isSpeaking = false
    var autoSpeakAnswers = false
    var isListening = false
    var liveTranscript = ""
    var voiceStatusMessage: String?

    // Multimodal Image / Screenshot / Clipboard state
    var isAnalyzingMedia = false
    var mediaTitle: String?
    var mediaOCRText: String?
    var mediaFMAnalysis: String?
    var mediaTags: [String] = []
    var mediaDerivedClaimsCount: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var voiceQueryHandler: (@MainActor (String) -> Void)?
    private var voiceSessionID = UUID()

    struct BriefingItem: Identifiable, Sendable {
        let id = UUID()
        let category: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let actionLabel: String?
        let repoName: String?
        let sectionTarget: Section?
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func refreshTelemetry() {
        telemetry = Conversation.telemetry()
    }

    // MARK: - 1-Click Executive Morning Briefing

    func generateMorningBriefing(using model: AppModel) async {
        guard !isGeneratingBriefing else { return }
        isGeneratingBriefing = true
        briefingSummary = nil
        briefingHeadline = "Refreshing operator snapshots…"
        briefingPoints = []
        lastBriefingAt = nil
        defer { isGeneratingBriefing = false }

        refreshTelemetry()
        await model.refreshFleetStatus()
        await model.refreshMachineHealth(checkTailnet: true)
        let fleet = model.fleetCards
        let measured = fleet.filter(\.gitStatusMeasured)
        let dirty = measured.filter { $0.dirty > 0 }
        var items: [BriefingItem] = []
        let captured = model.fleetSnapshot.lastCapture
        let attempt = model.fleetSnapshot.lastAttempt
        var fleetDetail = captured.map {
            "Inventory collection: \($0.attemptedAt.formatted()) through \($0.finishedAt.formatted()). Individual row refreshes may be newer."
        } ?? "No usable fleet capture."
        if let captured, !captured.isComplete {
            fleetDetail += " Retained capture is partial: " + captured.issues.joined(separator: " ")
        }
        if let attempt, !attempt.issues.isEmpty {
            fleetDetail += " Latest attempt \(attempt.finishedAt.formatted()): \(attempt.issues.joined(separator: " "))"
        }
        if model.isLoadingFleet { fleetDetail += " A collection is still running; these cards are from the earlier capture." }
        fleetDetail += " \(fleet.count - measured.count) cards have no measured Git status."
        items.append(BriefingItem(category: "FLEET SNAPSHOT", symbol: "folder.fill.badge.gearshape",
            tint: captured?.isComplete == true && attempt?.isComplete == true && !model.isLoadingFleet ? .cyan : .orange,
            title: "\(fleet.count) repository cards · \(dirty.count) dirty among \(measured.count) measured trees",
            detail: fleetDetail, actionLabel: "Open fleet", repoName: nil, sectionTarget: .macOverview))

        if let eco = model.agentEcosystem {
            let details = eco.readIssues.isEmpty
                ? "\(eco.skillsInSyncCount) same-source skill folders · \(eco.codexRolloutSummaryCount) rollout files · \(eco.claudeMemoryFileCount) memory files."
                : "Inventory incomplete; aggregate counts withheld. \(eco.readIssues.joined(separator: " "))"
            items.append(BriefingItem(category: "AGENT CONFIGURATION INVENTORY", symbol: "point.3.filled.connected.trianglepath.dotted",
                tint: eco.readIssues.isEmpty ? .purple : .orange, title: "Inventory checked \(eco.checkedAt.formatted())",
                detail: details + " File presence and shared folders do not verify provider activation or runtime parity.",
                actionLabel: nil, repoName: nil, sectionTarget: nil))
        }

        if let health = model.machineHealth {
            let peers = health.tailnetPeers.filter { $0.role != "Local" && $0.reachable }.map(\.alias)
            let peerText = OperatorSnapshotFormatting.peers(requested: health.tailnetProbeRequested, reachable: peers)
            var details = ["Checks attempted through \(health.checkedAt.formatted()).", peerText]
            if health.dataVolumeFreeGiB == nil { details.append("Disk measurement unavailable.") }
            if let issue = health.simulatorCheckError { details.append(issue) }
            details.append(OperatorSnapshotFormatting.numberedFiles(count: health.icloudConflictFiles.count,
                reachedLimit: health.numberedFileScanReachedLimit, error: health.numberedFileScanError))
            if model.isLoadingMachineHealth { details.append("Another collection is still in progress.") }
            items.append(BriefingItem(category: "MAC & TAILNET SNAPSHOT", symbol: "desktopcomputer",
                tint: health.isDiskSpaceLow(thresholdGiB: AppSettings.shared.lowDiskWarningThresholdGiB) || health.dataVolumeFreeGiB == nil || health.simulatorCheckError != nil || health.numberedFileScanError != nil ? .orange : .cyan,
                title: "\(health.freeSpaceSummary) · \(health.simulatorSummary)", detail: details.joined(separator: " "),
                actionLabel: "Open Mac checks", repoName: nil, sectionTarget: .macOverview))
        }
        items.append(BriefingItem(category: "STORED HISTORY", symbol: "books.vertical.fill", tint: .green,
            title: "Inspect beliefs and their source records",
            detail: "Operator snapshots are not stored evidence. Belief history and cited answers remain in the evidence workspace.",
            actionLabel: "Open beliefs", repoName: nil, sectionTarget: .beliefs))
        briefingPoints = items
        briefingHeadline = "Good \(Self.timeOfDayGreeting()). \(fleet.count) repository cards available."
        briefingSummary = items.map { "\($0.category): \($0.title). \($0.detail)" }.joined(separator: "\n\n")
        lastBriefingAt = Date() // Presentation time only; each snapshot above carries its own capture/attempt time.
        if autoSpeakAnswers || AppSettings.shared.jarvisAutoSpeakBriefings { speak(briefingSummary ?? briefingHeadline) }
    }

    private static func timeOfDayGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "morning" }
        if hour < 18 { return "afternoon" }
        return "evening"
    }

    // MARK: - Neural Speech Output (`AVSpeechSynthesizer`)

    func speak(_ rawText: String) {
        let cleaned = Self.stripCitationTags(from: rawText)
        guard !cleaned.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = Float(AppSettings.shared.jarvisSpeechRate)
        utterance.pitchMultiplier = 1.0
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language.hasPrefix("en") && ($0.quality == .premium || $0.quality == .enhanced)
        }) ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = premiumVoice
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    private static func stripCitationTags(from text: String) -> String {
        var result = text
        for idx in 1...12 {
            result = result.replacingOccurrences(of: " [\(idx)]", with: "")
            result = result.replacingOccurrences(of: "[\(idx)]", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - On-Device Voice Dictation (`SFSpeechRecognizer` + `AVAudioEngine`)

    func toggleVoiceListening(onFinalQuery: @escaping @MainActor (String) -> Void) {
        if isListening {
            stopListening(submitTo: onFinalQuery)
        } else {
            voiceQueryHandler = onFinalQuery
            startListening()
        }
    }

    func startListening() {
        guard !isListening else { return }
        stopSpeaking()
        liveTranscript = ""
        let sessionID = UUID()
        voiceSessionID = sessionID
        voiceStatusMessage = "Requesting on-device speech recognition…"

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard self.voiceSessionID == sessionID else { return }
                guard status == .authorized else {
                    self.voiceStatusMessage = "Enable Speech Recognition in System Settings > Privacy & Security to use voice queries."
                    return
                }
                self.beginAudioSession()
            }
        }
    }

    private func beginAudioSession() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else {
            voiceStatusMessage = "On-device speech recognition is unavailable. No audio was sent to a network recognizer."
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let sessionID = voiceSessionID

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.channelCount > 0 else {
            voiceStatusMessage = "No active microphone input detected."
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.recognitionRequest = request
            self.isListening = true
            self.voiceStatusMessage = "Listening on device… Click Stop when finished."

            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                let latest = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hadError = error != nil
                Task { @MainActor in
                    guard self.voiceSessionID == sessionID, self.isListening else { return }
                    if let latest, !latest.isEmpty {
                        self.liveTranscript = latest
                    }
                    if isFinal {
                        self.stopListening(submitTo: self.voiceQueryHandler)
                    } else if hadError {
                        self.cleanupAudioEngine()
                        self.voiceQueryHandler = nil
                        self.voiceStatusMessage = "Dictation stopped before completion. The captured transcript remains visible; no query was submitted."
                    }
                }
            }
        } catch {
            cleanupAudioEngine()
            voiceStatusMessage = "Microphone error: \(error.localizedDescription)"
        }
    }

    func stopListening(submitTo onFinalQuery: (@MainActor (String) -> Void)? = nil) {
        let captured = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupAudioEngine()
        voiceQueryHandler = nil
        voiceStatusMessage = nil
        if !captured.isEmpty, let onFinalQuery {
            onFinalQuery(captured)
        }
    }

    private func cleanupAudioEngine() {
        voiceSessionID = UUID()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    // MARK: - Multimodal Vision OCR + `/usr/bin/fm --image` Analysis & Ingest

    func analyzeAndIngestImage(url: URL, using model: AppModel) async {
        guard !isAnalyzingMedia else { return }
        isAnalyzingMedia = true
        mediaTitle = url.lastPathComponent
        mediaOCRText = nil
        mediaFMAnalysis = nil
        mediaTags = []
        mediaDerivedClaimsCount = nil
        defer { isAnalyzingMedia = false }

        let ocrText: String?
        if FilesystemConnector.pdfExtensions.contains(url.pathExtension.lowercased()) {
            ocrText = FilesystemConnector.extractPDFText(from: url)?.text
        } else {
            ocrText = FilesystemConnector.extractImageText(from: url)
        }
        mediaOCRText = ocrText

        async let fmVision = Conversation.analyzeImageWithFoundationModelsCLI(imageURL: url)
        async let fmTags = Conversation.tagContentWithFoundationModelsCLI(text: ocrText ?? url.lastPathComponent)

        let (visionSummary, tags) = await (fmVision, fmTags)
        mediaFMAnalysis = visionSummary
        mediaTags = tags

        // Ingest into Store so the OCR'd text and multimodal summary become a searchable floor object
        let claimsBefore = model.claimCount
        await model.ingestDroppedURLs([url], domain: .project)
        let delta = max(0, model.claimCount - claimsBefore)
        mediaDerivedClaimsCount = delta
    }

    func analyzeClipboardImage(using model: AppModel) async {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            voiceStatusMessage = "Clipboard does not contain an image or screenshot. Copy a screenshot (⌃⇧⌘4) first."
            return
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Jarvis-Clipboard-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try pngData.write(to: tempURL, options: .atomic)
            await analyzeAndIngestImage(url: tempURL, using: model)
        } catch {
            voiceStatusMessage = "Could not stage clipboard image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Compact J.A.R.V.I.S. Hero Deck on Command Center (`HomeView`)

struct JarvisCommandDeckCard: View {
    @Environment(\.appModel) private var model
    @State private var jarvis = JarvisController.shared
    var onAskQuestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Single-line Header + Model Pill + Right-aligned Action Buttons
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: jarvis.isSpeaking || jarvis.isListening ? "waveform.circle.fill" : "sparkles.tv.fill")
                    .font(.title3)
                    .foregroundStyle(jarvis.isListening ? .red : Color.accentColor)
                    .symbolEffect(.pulse, isActive: jarvis.isSpeaking || jarvis.isListening)

                Text("J.A.R.V.I.S. Executive Command Deck")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text("AFM 3 Core · \(jarvis.telemetry.contextWindowTokens.map { "\($0 / 1024)K ctx" } ?? "64K ctx") · Local")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: .capsule)

                Spacer(minLength: 8)

                // Action buttons
                Button {
                    Task { await jarvis.generateMorningBriefing(using: model) }
                } label: {
                    HStack(spacing: 5) {
                        if jarvis.isGeneratingBriefing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(jarvis.briefingPoints.isEmpty ? "Run Briefing" : "Refresh Briefing")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
                .disabled(jarvis.isGeneratingBriefing)
                .help("Refresh repository and Mac observations, with capture times and collection limits")

                Button {
                    jarvis.toggleVoiceListening { spokenQuery in
                        onAskQuestion(spokenQuery)
                    }
                } label: {
                    Label(
                        jarvis.isListening ? "Stop & Ask" : "Voice Ask",
                        systemImage: jarvis.isListening ? "stop.circle.fill" : "mic.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(jarvis.isListening ? .red : .primary)
                    .lineLimit(1)
                }
                .controlSize(.small)
                .openCoreGlassButton()
                .help("Dictate a question on device using Apple Speech Recognition")

                if jarvis.isSpeaking {
                    Button {
                        jarvis.stopSpeaking()
                    } label: {
                        Label("Mute", systemImage: "speaker.slash.fill")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .controlSize(.small)
                    .openCoreGlassButton()
                } else if let summary = jarvis.briefingSummary {
                    Button {
                        jarvis.speak(summary)
                    } label: {
                        Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .controlSize(.small)
                    .openCoreGlassButton()
                    .help("Read the executive briefing aloud using macOS neural speech synthesis")
                }

                Button {
                    model.showingJarvisHUD = true
                } label: {
                    Label("HUD ⌘J", systemImage: "viewfinder.circle")
                        .font(.caption)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .openCoreGlassButton()
                .help("Open the full J.A.R.V.I.S. Multimodal & Voice HUD (⌘J)")
            }

            // Row 2: Single-line subtitle
            Text("Repository and Mac snapshots, agent configuration inventory, voice dictation and Vision OCR.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let status = jarvis.voiceStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: jarvis.isListening ? "mic.badge.plus" : "info.circle")
                        .foregroundStyle(jarvis.isListening ? .red : .secondary)
                    Text(jarvis.liveTranscript.isEmpty ? status : "Heard: \"\(jarvis.liveTranscript)\"")
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(8)
                .openCoreGlassCard(cornerRadius: 8, tint: jarvis.isListening ? .red : nil)
            }

            if !jarvis.briefingPoints.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let summary = jarvis.briefingSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Label("OPERATOR SNAPSHOT SUMMARY", systemImage: "list.bullet.rectangle")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Pastel.mint)
                                Text("Deterministic observations · not stored evidence")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    if jarvis.isSpeaking {
                                        jarvis.stopSpeaking()
                                    } else {
                                        jarvis.speak(summary)
                                    }
                                } label: {
                                    Label(jarvis.isSpeaking ? "Stop Audio" : "Speak Briefing", systemImage: jarvis.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                                        .font(.caption2)
                                }
                                .controlSize(.mini)
                                .openCoreGlassButton()
                            }
                            Text(summary)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 10, tint: .green)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 10)], spacing: 10) {
                        ForEach(jarvis.briefingPoints) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Image(systemName: item.symbol)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(item.tint)
                                    Text(item.category)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(item.tint)
                                    Spacer()
                                    if let label = item.actionLabel {
                                        Button(label) {
                                            if let repo = item.repoName {
                                                model.openEntity(named: repo)
                                            } else if let target = item.sectionTarget {
                                                model.navigate(to: target)
                                            }
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption2.weight(.semibold))
                                    }
                                }
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .openCoreGlassCard(cornerRadius: 9, tint: item.tint)
                        }
                    }
                }
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 14, tint: .accentColor)
        .onAppear {
            jarvis.refreshTelemetry()
        }
    }
}

// MARK: - Full-Fidelity J.A.R.V.I.S. Sheet HUD (`⌘J`)

struct JarvisHUDView: View {
    @Environment(\.appModel) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var jarvis = JarvisController.shared
    @State private var voiceQueryDraft = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: jarvis.isSpeaking || jarvis.isListening || jarvis.isGeneratingBriefing)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("J.A.R.V.I.S. On-Device Intelligence HUD")
                            .font(.title3.weight(.bold))
                        Text("macOS 27.0 SDK")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: .capsule)
                    }
                    Text("Apple Foundation Models (\(jarvis.telemetry.modelVariant)) · Vision OCR · On-Device Speech · local speech required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Auto-Speak Briefing", isOn: $jarvis.autoSpeakAnswers)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)

                Button("Close") {
                    jarvis.stopSpeaking()
                    jarvis.stopListening()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            // macOS 27 FoundationModels Telemetry Bar
            telemetryStrip

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 1. Voice & Instant Command Bar
                    voiceCommandPanel

                    // 2. Executive Morning Briefing
                    executiveBriefingSection

                    // 3. Multimodal Vision OCR + `/usr/bin/fm --image` Dropzone
                    multimodalVisionSection
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
        .frame(width: 820, height: 640)
        .onAppear {
            jarvis.refreshTelemetry()
            if jarvis.briefingPoints.isEmpty {
                Task { await jarvis.generateMorningBriefing(using: model) }
            }
        }
    }

    private var telemetryStrip: some View {
        HStack(spacing: 10) {
            Label(jarvis.telemetry.modelVariant, systemImage: "cpu.fill")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(Pastel.mint)

            if let ctx = jarvis.telemetry.contextWindowTokens {
                Text("· \(ctx.formatted()) token window")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !jarvis.telemetry.capabilities.isEmpty {
                Text("· \(jarvis.telemetry.capabilities.joined(separator: " + "))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Text(jarvis.telemetry.privateCloudComputeAvailable ? "PCC Ready (Unused: Local First)" : "100% Local Execution")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .openCoreGlassCard(cornerRadius: 8)
    }

    private var voiceCommandPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Voice & Natural Language Command", systemImage: "waveform.and.mic")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    jarvis.toggleVoiceListening { spoken in
                        voiceQueryDraft = spoken
                    }
                } label: {
                    Label(
                        jarvis.isListening ? "Stop Dictation" : "Start On-Device Dictation",
                        systemImage: jarvis.isListening ? "stop.circle.fill" : "mic.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(jarvis.isListening ? .red : .primary)
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: jarvis.isListening)
            }

            HStack(spacing: 8) {
                TextField("Speak or type any question across your repos, commits, notes & beliefs…", text: $voiceQueryDraft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit {
                        submitVoiceQuery()
                    }

                Button("Ask →") {
                    submitVoiceQuery()
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
                .disabled(voiceQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .openCoreGlassCard(cornerRadius: 10)

            if let msg = jarvis.voiceStatusMessage {
                Text(jarvis.liveTranscript.isEmpty ? msg : "Live transcript: \"\(jarvis.liveTranscript)\"")
                    .font(.caption)
                    .foregroundStyle(jarvis.isListening ? .red : .secondary)
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 12)
    }

    private var executiveBriefingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Operator Briefing (Fleet + Mac Snapshots)", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                if jarvis.isGeneratingBriefing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let summary = jarvis.briefingSummary {
                    Button {
                        if jarvis.isSpeaking {
                            jarvis.stopSpeaking()
                        } else {
                            jarvis.speak(summary)
                        }
                    } label: {
                        Label(jarvis.isSpeaking ? "Stop Speaking" : "Read Briefing Aloud", systemImage: jarvis.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .openCoreGlassButton()
                }
                Button {
                    Task { await jarvis.generateMorningBriefing(using: model) }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .controlSize(.small)
                .openCoreGlassButton()
                .disabled(jarvis.isGeneratingBriefing)
            }

            if !jarvis.briefingHeadline.isEmpty {
                Text(jarvis.briefingHeadline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if let summary = jarvis.briefingSummary {
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .openCoreGlassCard(cornerRadius: 8, tint: .green)
            }

            ForEach(jarvis.briefingPoints) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.tint)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.category) · \(item.title)")
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let actionLabel = item.actionLabel {
                        Button(actionLabel) {
                            dismiss()
                            if let repo = item.repoName {
                                model.openEntity(named: repo)
                            } else if let target = item.sectionTarget {
                                model.navigate(to: target)
                            }
                        }
                        .controlSize(.mini)
                        .openCoreGlassButton()
                    }
                }
                .padding(8)
                .openCoreGlassCard(cornerRadius: 8)
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 12)
    }

    private var multimodalVisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Multimodal Vision OCR + /usr/bin/fm --image Analyzer", systemImage: "eye.square.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await jarvis.analyzeClipboardImage(using: model) }
                } label: {
                    Label("Analyze & Ingest Clipboard Screenshot", systemImage: "doc.on.clipboard.fill")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true)
                .disabled(jarvis.isAnalyzingMedia)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .frame(minHeight: 84)

                if jarvis.isAnalyzingMedia {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running Apple Vision OCR + /usr/bin/fm --image --tool ocr --tool barcode & ingesting into Store…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        Text("Drop any screenshot, whiteboard photo, or scanned PDF here")
                            .font(.caption.weight(.semibold))
                        Text("Extracts text and barcodes via Vision, runs /usr/bin/fm --image visual analysis and content tagging, and ingests into OpenCore.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                Task { await jarvis.analyzeAndIngestImage(url: first, using: model) }
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }

            if let title = jarvis.mediaTitle {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Analyzed & Ingested: \(title)", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pastel.mint)
                        if let claimsDelta = jarvis.mediaDerivedClaimsCount {
                            Text("· +\(claimsDelta) new claim(s) derived")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if !jarvis.mediaTags.isEmpty {
                        HStack(spacing: 6) {
                            Text("Content Tags:")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(jarvis.mediaTags, id: \.self) { tag in
                                Chip(tag)
                            }
                        }
                    }

                    if let analysis = jarvis.mediaFMAnalysis {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("FOUNDATION MODEL VISUAL SUMMARY (/usr/bin/fm --image)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Text(analysis)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }

                    if let ocr = jarvis.mediaOCRText {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("VISION OCR TEXT")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(String(ocr.prefix(500)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .openCoreGlassCard(cornerRadius: 8, tint: .green)
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 12)
    }

    private func submitVoiceQuery() {
        let trimmed = voiceQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        voiceQueryDraft = ""
        dismiss()
        model.askInChat(trimmed)
    }
}
