import AppKit
import CoreTelemetry
import SwiftUI

struct MachineChecksView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var topic: MachineCheckTopic
    @State private var refreshGeneration = 0
    @State private var storage: [MachineStorageLocation] = []
    @State private var measuringStorage = false
    @State private var actionError: String?
    let navigate: (Section) -> Void

    init(initialTopic: MachineCheckTopic, navigate: @escaping (Section) -> Void) {
        _topic = State(initialValue: initialTopic)
        self.navigate = navigate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac checks").font(.title2.bold())
                    if let health = model.machineHealth {
                        Text("Checked \(health.checkedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh checks", systemImage: "arrow.clockwise") { refreshGeneration += 1 }
                    .disabled(model.isLoadingMachineHealth || measuringStorage)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Mac check", selection: $topic) {
                ForEach(MachineCheckTopic.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if let actionError { Text(actionError).font(.callout).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch topic {
                    case .storage: storageDetails
                    case .duplicates: duplicateDetails
                    case .simulators: simulatorDetails
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }
        .padding(22)
        .frame(width: 850, height: 650)
        .task(id: "\(topic.id)-\(refreshGeneration)") {
            actionError = nil
            await model.refreshMachineHealth(checkTailnet: false)
            guard !Task.isCancelled, topic == .storage else { return }
            measuringStorage = true
            defer { measuringStorage = false }
            do {
                let measured = try await MachineStorageReview.measure()
                guard !Task.isCancelled else { return }
                storage = measured
            } catch is CancellationError { }
            catch { actionError = "Storage locations could not be measured. Refresh to retry." }
        }
    }

    private var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Data volume storage").font(.title3.bold())
            if let health = model.machineHealth {
                HStack(spacing: 24) {
                    metric("Available", value: health.dataVolumeFreeGiB.map { String(format: "%.1f GiB", $0) } ?? "Not measured")
                    metric("Total capacity", value: health.dataVolumeTotalGiB.map { String(format: "%.1f GiB", $0) } ?? "Not measured")
                    metric("Used", value: health.dataVolumeUsedPercent.map { "\($0)%" } ?? "Not measured")
                }
                if let used = health.dataVolumeUsedPercent { ProgressView(value: Double(used), total: 100) }
            }
            Text("Warning level: \(settings.lowDiskWarningThresholdGiB.formatted()) GiB free. Measured on /System/Volumes/Data.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Manage downloaded models…", systemImage: "cpu") { navigate(.aiModelsRAM) }
                Button("USB & disk details…", systemImage: "externaldrive") { navigate(.hardwareUSB) }
            }
            Divider()
            HStack {
                Text("Known model and build locations").font(.headline)
                if measuringStorage { ProgressView().controlSize(.small) }
            }
            Text("Allocated sizes for these locations only, not a full Mac storage scan. Review their contents in Finder before deciding what to keep.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(storage) { location in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(location.title).font(.headline)
                        Spacer()
                        Text(location.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not measured")
                            .monospacedDigit()
                        Button("Show in Finder") { reveal(location.url) }
                            .disabled(!location.isPresent)
                            .accessibilityLabel("Show \(location.title) in Finder")
                    }
                    Text(location.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let note = location.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }.padding(12).openCoreGlassCard(cornerRadius: 10)
            }
        }
    }

    private var duplicateDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review possible duplicate files").font(.title3.bold())
            Text("Numbered filenames can come from copies or sync conflicts. A filename alone does not establish an iCloud conflict. Compare the files before choosing which version to keep.")
                .font(.callout).foregroundStyle(.secondary)
            let paths = model.machineHealth?.icloudConflictFiles ?? []
            if let error = model.machineHealth?.numberedFileScanError {
                Text(error).foregroundStyle(.orange)
            }
            Text("Scope: visible repositories under ~/Documents/GitHub; generated folders are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            if paths.count >= OperatorConsoleService.numberedFileScanLimit {
                Text("Showing the first \(OperatorConsoleService.numberedFileScanLimit) matches. Additional matches may exist.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if paths.isEmpty, model.machineHealth?.numberedFileScanError == nil {
                Text(model.isLoadingMachineHealth || model.machineHealth == nil ? "Checking numbered filenames…" : "No matching numbered files in this scan.")
                    .padding(.vertical)
            }
            ForEach(paths, id: \.self) { path in duplicateRow(path) }
        }
    }

    private func duplicateRow(_ path: String) -> some View {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub")
        let pair = NumberedFileCandidate(relativePath: path, root: root)
        return VStack(alignment: .leading, spacing: 8) {
            Text((path as NSString).lastPathComponent).font(.headline)
            Text(path).font(.callout.monospaced()).textSelection(.enabled)
            if let pair {
                let numberedExists = FileManager.default.fileExists(atPath: pair.numberedURL.path)
                let relatedExists = FileManager.default.fileExists(atPath: pair.relatedURL.path)
                Text("Matching base name: \(pair.relatedURL.lastPathComponent)\(relatedExists ? "" : " (not present)")")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Show numbered file") { reveal(pair.numberedURL) }
                        .disabled(!numberedExists)
                        .accessibilityLabel("Show numbered file \(path) in Finder")
                    Button("Show \(pair.relatedURL.lastPathComponent)") { reveal(pair.relatedURL) }
                        .disabled(!relatedExists)
                        .accessibilityLabel("Show matching base file for \(path) in Finder")
                }
                if !numberedExists { Text("This file is no longer at the scanned path. Refresh checks.").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("This path could not be resolved inside the scan folder. Refresh checks.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).openCoreGlassCard(cornerRadius: 10)
    }

    private var simulatorDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Running simulators").font(.title3.bold())
            Text("Review running devices in Device Hub. Per-device memory use is not measured by this check.")
                .font(.callout).foregroundStyle(.secondary)
            let devices = model.machineHealth?.bootedSimulators ?? []
            if let error = model.machineHealth?.simulatorCheckError { Text(error).foregroundStyle(.orange) }
            else if devices.isEmpty { Text(model.isLoadingMachineHealth || model.machineHealth == nil ? "Checking simulators…" : "No running simulators in the latest check.") }
            ForEach(devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline)
                    Text(device.runtime).font(.callout)
                    Text(device.udid).font(.caption.monospaced()).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).openCoreGlassCard(cornerRadius: 10)
            }
            Button("Open Device Hub", systemImage: "iphone") {
                if !NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app")) {
                    actionError = "Device Hub could not be opened from the installed Xcode."
                }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
    }

    private func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            actionError = "This location is no longer available. Refresh checks before opening it."
            return
        }
        actionError = nil
        OperatorConsoleService.revealInFinder(path: url.path)
    }
}
