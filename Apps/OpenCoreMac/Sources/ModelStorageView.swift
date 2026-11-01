import SwiftUI

struct ModelStorageView: View {
    @State private var lab = HubModelLab.shared

    private var installed: [HubLabModel] {
        lab.models.filter { $0.id != "apple-system" && $0.installed != nil }
            .sorted { ($0.installed?.bytes ?? 0) > ($1.installed?.bytes ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model downloads · largest first").font(.headline)
            if let storage = lab.storage {
                Text("\(ByteCountFormatter.string(fromByteCount: storage.models, countStyle: .file)) in installed model downloads · \(String(format: "%.2f GiB", Double(storage.free) / 1_073_741_824)) currently available on disk")
                    .font(.callout.weight(.semibold))
            }
            Text("Unloading frees RAM. Deleting a download removes its files from disk. Results, saved routines and task history are kept. Disk availability is measured again after deletion; APFS may release space later.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(installed) { local in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(local.name).font(.callout.bold())
                        if let best = lab.checks?.rankings?.first?.entries.first(where: { $0.model_id == local.id }),
                           let suite = best.best_suite, let rank = best.best_rank,
                           let job = lab.checks?.rankings?.first(where: { $0.id == suite }) {
                            Text("Best local placement: #\(rank) · \(job.name)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(local.installed?.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable")
                        .monospacedDigit()
                    ModelDownloadControls(modelID: local.id)
                }
                .padding(12).openCoreGlassCard(cornerRadius: 10)
            }
            if installed.isEmpty { Text("No Hub model downloads installed.").foregroundStyle(.secondary) }
            Text("Apple intelligence is built into macOS. It has no Hub download to delete. Runtime libraries and temporary builds are separate from these model files.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ModelDownloadControls: View {
    let modelID: String
    @State private var lab = HubModelLab.shared
    @State private var confirming = false

    var body: some View {
        if let local = lab.model(modelID), local.id != "apple-system", local.installed != nil {
            let size = local.installed?.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "this model's"
            Button(role: .destructive) { confirming = true } label: {
                Label("Delete download…", systemImage: "trash")
            }
                .accessibilityLabel("Delete downloaded \(local.name)")
                .disabled(lab.busy)
                .confirmationDialog("Delete \(local.name)?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Delete \(size) download", role: .destructive) {
                        Task { await lab.removeDownload(local.id) }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Removes \(size) of Hub model files. A loaded copy will be unloaded first. You can download it again later. Test results, saved routines and task history stay on this Mac.")
                }
        }
    }
}
