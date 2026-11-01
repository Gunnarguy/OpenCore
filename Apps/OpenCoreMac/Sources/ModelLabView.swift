import Foundation
import Observation
import SwiftUI

struct HubLabProfile: Decodable, Sendable {
    let name: String
    let max_tokens: Int?
    let max_input_tokens: Int?
    let temperature: Double?
    let prompt_contract: String?
}

struct HubLabModel: Decodable, Identifiable, Sendable {
    struct Installation: Decodable, Sendable { let bytes: Int64? }
    let id: String
    let name: String
    let revision: String?
    let supported: Bool
    let adapter_ready: Bool?
    let size: Int64
    let installed: Installation?
    let scopes: [String]?
    let inference: HubLabProfile?
    var readyToSetUp: Bool { supported && adapter_ready != false }
    var taskPlanner: Bool { scopes == nil || scopes?.contains("browser") == true }
}

struct HubSkillSuite: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let passed: Int
    let total: Int
    let median_seconds: Double
}

struct HubSkillCase: Decodable, Identifiable, Sendable {
    let id: String
    let suite: String
    let passed: Bool
    let seconds: Double
    let error: String?
    let output: String?
    let evidence: String?
}

struct HubQualification: Decodable, Sendable {
    let status: String
    let revision: String?
    let fixture_version: String
    let started_at: String
    let finished_at: String?
    let load_seconds: Double?
    let engine: String?
    let inference: HubLabProfile?
    let current_configuration: Bool?
    let current_machine: Bool?
    let peak_memory: Int64?
    let error: String?
    let suites: [HubSkillSuite]
    let cases: [HubSkillCase]
}

struct HubSkillRecommendation: Decodable, Identifiable, Sendable {
    var id: String { suite }
    let suite: String
    let name: String
    let model_id: String
    let passed: Int
    let total: Int
    let median_seconds: Double
    let basis: String
}

struct HubModelCheckState: Decodable, Sendable {
    struct Download: Decodable, Sendable { let received: Int64; let total: Int64 }
    let running: Bool
    let phase: String
    let model: String?
    let `case`: String?
    let error: String?
    let records: [String: HubQualification]
    let recommendations: [HubSkillRecommendation]
    let machine_profile: HubMacProfile?
    let rankings: [HubJobRanking]?
    let download: Download?
}

@MainActor @Observable
final class HubModelLab {
    static let shared = HubModelLab()
    var models: [HubLabModel] = []
    var checks: HubModelCheckState?
    var storage: HubModelStorage?
    var notice: String?
    var error: String?
    var connected = false
    var sending = false
    private var refreshID = UUID()
    var running: Bool { checks?.running == true }
    var busy: Bool { running || sending || ComputerUseStudioController.shared.isLoadingOrUnloadingModel }

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    func refresh() async {
        let requestID = UUID()
        refreshID = requestID
        let ctrl = ComputerControlManager.shared
        if !ctrl.isHubServerOnline { await ctrl.probeHubServer() }
        guard let status = await ctrl.getHubObject(path: "/api/status"), !Task.isCancelled else {
            if requestID == refreshID, !Task.isCancelled {
                connected = false
                ctrl.invalidateHubConnection(ctrl.lastHubError ?? "The model service disconnected. Readiness is unverified.")
            }
            return
        }
        struct Catalog: Decodable { let models: [HubLabModel]; let storage: HubModelStorage }
        do {
            let catalog = try decode(Catalog.self, status)
            guard let receipt = await ctrl.getHubObject(path: "/api/models/checks"), !Task.isCancelled,
                  requestID == refreshID else {
                if requestID == refreshID, !Task.isCancelled {
                    connected = false
                    error = ctrl.lastHubError ?? "Model checks could not be read."
                    ctrl.invalidateHubConnection(error ?? "Model status is unverified.")
                }
                return
            }
            let current = try decode(HubModelCheckState.self, receipt)
            models = catalog.models
            storage = catalog.storage
            if checks?.running == true && !current.running {
                ActionFeedbackCenter.shared.record(button: "Run model skill checks", command: "Local model fixture checks",
                    outcome: current.phase == "stopped" ? "Checks stopped. No model remains loaded." : "Checks finished. Review each model's passed and failed trials below.", status: .completed)
            }
            checks = current
            connected = true
            error = nil
            ctrl.applyLiveModelCatalog(status)
            if let runtime = status["runtime"] as? [String: Any] {
                ComputerUseStudioController.shared.applyRuntimeReceipt(runtime)
            }
        } catch {
            guard requestID == refreshID else { return }
            connected = false
            self.error = "The model service returned an incompatible status: \(error.localizedDescription)"
            ctrl.invalidateHubConnection(self.error ?? "Model status is unverified.")
        }
    }

    func start(ids: [String], download: Bool = false) async {
        guard !busy, !ids.isEmpty else { return }
        refreshID = UUID()
        sending = true
        defer { sending = false }
        let ctrl = ComputerControlManager.shared
        guard let receipt = await ctrl.postToHubServer(path: "/api/models/checks/start", payload: ["ids": ids, "download": download]) else {
            error = ctrl.lastHubError ?? "The model checks could not be started."
            return
        }
        do {
            let current = try decode(HubModelCheckState.self, receipt)
            checks = current
            error = nil
            ActionFeedbackCenter.shared.record(button: "Run model skill checks", command: "Local model fixture checks",
                outcome: current.running ? "Started \(ids.count) model(s). Results are checked against synthetic targets and exact practice-file contents." : (current.phase == "stopped" ? "Checks stopped. No model remains loaded." : "Checks finished. Review each model's passed and failed trials below."),
                status: current.running ? .running : .completed)
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        let ctrl = ComputerControlManager.shared
        guard await ctrl.postToHubServer(path: "/api/models/checks/stop", payload: [:]) != nil else {
            error = ctrl.lastHubError
            return
        }
        await refresh()
    }

    func removeDownload(_ identity: String) async {
        guard !busy, identity != "apple-system", model(identity)?.installed != nil else { return }
        sending = true
        notice = nil
        defer { sending = false }
        let ctrl = ComputerControlManager.shared
        guard let response = await ctrl.postToHubServer(path: "/api/models/delete", payload: ["id": identity]),
              let removed = response["reclaimed"] as? NSNumber, removed.int64Value >= 0 else {
            error = ctrl.lastHubError ?? "The download could not be deleted. Refresh to check its state."
            return
        }
        notice = "Deleted \(name(identity)) download (\(ByteCountFormatter.string(fromByteCount: removed.int64Value, countStyle: .file)) of model files). Results are kept."
        ActionFeedbackCenter.shared.record(button: "Delete model download", command: "Local Hub owned model removal",
            outcome: notice ?? "Download deleted.", status: .completed)
        await refresh()
    }

    func name(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }
    func model(_ id: String) -> HubLabModel? { models.first { $0.id == id } }
}

struct ModelLabView: View {
    @State private var lab = HubModelLab.shared
    @State private var ctrl = ComputerControlManager.shared
    @State private var tab = "rankings"
    @State private var confirmDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Model Lab · What works on your Mac", systemImage: "checkmark.seal")
                        .font(.title2.bold())
                    Text(lab.checks?.machine_profile?.description ?? "Reading this Mac's chip and memory…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await lab.refresh() } }
            }
            if !lab.connected {
                Text(lab.error ?? "Start the local model service to see installed models and recorded checks.")
                    .foregroundStyle(.secondary)
                Button("Start model service") {
                    Task { await ctrl.launchLocalHubServerOrApp(); await lab.refresh() }
                }
            } else {
                HStack {
                    Button("Download missing & compare…") { confirmDownload = true }
                    .disabled(lab.busy)
                    .confirmationDialog("Download missing model files?", isPresented: $confirmDownload, titleVisibility: .visible) {
                        Button("Download & compare") {
                            Task { await lab.start(ids: lab.models.filter(\.readyToSetUp).map(\.id), download: true) }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        let bytes = lab.models.filter { $0.id != "apple-system" && $0.installed == nil && $0.readyToSetUp }.reduce(Int64(0)) { $0 + $1.size }
                        Text("Missing packages total \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). Installed files are reused. Compare installed models runs without downloading more weights.")
                    }
                    Button("Compare installed models") {
                        Task { await lab.start(ids: lab.models.filter { $0.readyToSetUp && ($0.id == "apple-system" || $0.installed != nil) }.map(\.id)) }
                    }
                    .disabled(lab.busy)
                    Text("\(lab.models.filter { $0.id != "apple-system" && $0.installed != nil }.count) downloads · \(lab.storage.map { ByteCountFormatter.string(fromByteCount: $0.models, countStyle: .file) } ?? "Size unavailable") · \(lab.storage.map { String(format: "%.2f GiB", Double($0.free) / 1_073_741_824) } ?? "Unknown") free")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let checks = lab.checks, checks.running {
                    HStack {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading) {
                            Text("\(checks.phase.capitalized): \(checks.model.map(lab.name) ?? "Preparing")").bold()
                            if let name = checks.case { Text(name).font(.caption) }
                            if let download = checks.download, checks.phase == "downloading" {
                                ProgressView(value: Double(download.received), total: Double(max(1, download.total)))
                            }
                        }
                        Spacer()
                        Button("Stop checks") { Task { await lab.stop() } }
                    }
                    .padding(12).background(Pastel.sky.opacity(0.10), in: .rect(cornerRadius: 10))
                }
                if let error = lab.error ?? lab.checks?.error { Text(error).foregroundStyle(Pastel.peach) }
                if let notice = lab.notice { Text(notice).font(.callout).foregroundStyle(Pastel.mint) }
                Picker("Model Lab view", selection: $tab) {
                    Text("Rank every model").tag("rankings")
                    Text("Storage & delete downloads").tag("storage")
                }.pickerStyle(.segmented)
                if tab == "storage" { ModelStorageView() }
                else { ModelRankingView() }
            }
        }
        .padding(18).openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
        .task {
            await lab.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await lab.refresh()
            }
        }
    }
}

struct ModelSkillResultsView: View {
    let modelID: String
    @State private var lab = HubModelLab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let local = lab.model(modelID) {
                Text(local.scopes == ["grounding"] ? "Use for screenshot target finding. This adapter returns a location; it does not control your Mac." : "Use for scoped tasks with independent result checks.")
                    .font(.caption.weight(.semibold))
                if let profile = local.inference {
                    Text("Live preset: \(profile.name) · output limit \(profile.max_tokens.map(String.init) ?? "OS managed") tokens")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let record = lab.checks?.records[modelID] {
                HStack {
                    Text("LOCAL CHECK · \(record.current_machine == false ? "MACHINE UNVERIFIED" : record.current_configuration == false ? "PREVIOUS SETUP" : record.status.uppercased())").font(.caption.bold()).foregroundStyle(Pastel.sky)
                    Spacer()
                    if let peak = record.peak_memory {
                        Text("MLX peak \(ByteCountFormatter.string(fromByteCount: peak, countStyle: .memory))").font(.caption.monospacedDigit())
                    }
                }
                ForEach(record.suites) { suite in
                    HStack {
                        Text(suite.name)
                        Spacer()
                        Text("\(suite.passed)/\(suite.total) · \(suite.median_seconds, format: .number.precision(.fractionLength(2))) s")
                            .foregroundStyle(suite.passed == suite.total ? Pastel.mint : Pastel.peach)
                    }.font(.caption.monospacedDigit())
                }
                if let error = record.error { Text(error).font(.caption).foregroundStyle(Pastel.peach) }
                DisclosureGroup("See every trial and its evidence") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Revision \(record.revision ?? "Not reported")\nFixture \(record.fixture_version)\n\(record.finished_at ?? record.started_at)")
                            .font(.caption2.monospaced()).textSelection(.enabled)
                        if let preset = record.inference {
                            Text("Tested preset: \(preset.name), output limit \(preset.max_tokens.map(String.init) ?? "OS managed") tokens")
                                .font(.caption2)
                        }
                        ForEach(record.cases) { trial in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(trial.passed ? "Passed" : "Failed"): \(trial.id) · \(trial.seconds, format: .number.precision(.fractionLength(2))) s").bold()
                                Text(trial.error ?? trial.evidence ?? "No verification evidence")
                                if let output = trial.output { Text(output).textSelection(.enabled).foregroundStyle(.secondary) }
                            }.font(.caption)
                        }
                    }.padding(.top, 5)
                }.font(.caption)
            } else {
                Text("No completed skill checks recorded for this package yet.").font(.caption).foregroundStyle(.secondary)
            }
            ModelDownloadControls(modelID: modelID)
        }
        .padding(10).background(Pastel.sky.opacity(0.07), in: .rect(cornerRadius: 10))
    }
}
