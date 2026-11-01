import SwiftUI

struct ModelRankingView: View {
    @State private var lab = HubModelLab.shared
    @State private var suite = "grounding"
    @State private var ctrl = ComputerControlManager.shared
    @Environment(\.appModel) private var model

    private var group: HubJobRanking? { lab.checks?.rankings?.first { $0.id == suite } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("All \(lab.models.count) models · ranked by job").font(.headline)
                Spacer()
                Picker("Job to compare", selection: $suite) {
                    ForEach(lab.checks?.rankings ?? []) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 300)
            }
            if let machine = lab.checks?.machine_profile {
                Text("macOS \(machine.os) (\(machine.os_build ?? "build unavailable")) · results must match this hardware, model revision, worker libraries and serving preset.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let group {
                Text("\(group.ranked_count) compared for this job. More passed checks rank first; median response time breaks ties. Each model's strongest local placement is also shown.")
                    .font(.caption).foregroundStyle(.secondary)
                if let winner = lab.checks?.recommendations.first(where: { $0.suite == suite }) {
                    HStack {
                        Label("First choice: \(lab.name(winner.model_id))", systemImage: "checkmark.seal")
                            .font(.callout.bold()).foregroundStyle(Pastel.mint)
                        Spacer()
                        Button("Load first choice") {
                            Task { await ComputerUseStudioController.shared.loadModelIntoRAM(winner.model_id) }
                        }.disabled(lab.busy || lab.model(winner.model_id)?.installed == nil)
                        if lab.model(winner.model_id)?.taskPlanner == true {
                            Button("Use for a task…") { useForTask(winner.model_id) }
                                .disabled(lab.busy || lab.model(winner.model_id)?.installed == nil)
                        }
                    }
                }
                Table(group.entries) {
                    TableColumn("Job rank") { row in
                        Text(row.rank.map { "#\($0)" } ?? "—").fontWeight(.semibold)
                    }.width(min: 55, ideal: 65, max: 80)
                    TableColumn("Model / strongest local placement") { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).font(.callout.weight(.semibold))
                            if let best = row.best_suite, let rank = row.best_rank,
                               let name = lab.checks?.rankings?.first(where: { $0.id == best })?.name {
                                Text("#\(rank) · \(name)").font(.caption).foregroundStyle(.secondary)
                            } else { Text(row.error ?? (row.status == "not_checked" || row.status == "previous_setup" ? "Needs checks for this Mac" : row.stateDescription)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }.width(min: 220, ideal: 340)
                    TableColumn("Selected job") { row in
                        Text(row.stateDescription).foregroundStyle(row.rank == nil ? .secondary : .primary)
                            .help(row.error ?? row.stateDescription)
                    }.width(min: 120, ideal: 150)
                    TableColumn("Median") { row in
                        Text(row.rank != nil ? row.median_seconds.map { String(format: "%.2f s", $0) } ?? "Not measured" : "—")
                            .monospacedDigit()
                    }.width(min: 65, ideal: 80)
                    TableColumn("MLX peak") { row in
                        Text(row.best_rank != nil ? row.peak_memory.map { String(format: "%.2f GiB", Double($0) / 1_073_741_824) } ?? "Not measured" : "—")
                            .monospacedDigit()
                    }.width(min: 85, ideal: 100)
                    TableColumn("On disk") { row in
                        Text(row.model_id == "apple-system" ? "OS managed" : row.download_bytes.map {
                            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        } ?? "Not downloaded")
                        .monospacedDigit()
                    }.width(min: 90, ideal: 100)
                }
                .frame(height: 510)
            } else {
                Text("Restart the local model service to load complete standings, then compare installed models.")
                    .foregroundStyle(.secondary)
            }
            Text("These small local fixtures establish their tested tasks. Publisher benchmarks and intended roles remain in the cards below. Screenshot checks predict targets without clicking the desktop. MLX peak is allocator memory, not total Mac or process RAM; current workload can change speed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func useForTask(_ identity: String) {
        ctrl.taskModelID = identity
        if let scopes = lab.model(identity)?.scopes, !scopes.contains(ctrl.taskScope) {
            ctrl.taskScope = scopes.contains("browser") ? "browser" : (scopes.first ?? "browser")
        }
        ctrl.requestedStudioTab = .tasksAndRoutines
        model.navigate(to: .computerControl)
    }
}
