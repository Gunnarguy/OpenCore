import Foundation

struct HubMacProfile: Decodable, Sendable {
    let id: String?
    let architecture: String
    let chip: String?
    let model: String?
    let memory_bytes: Int64?
    let os: String
    let os_build: String?

    var description: String {
        let memory = memory_bytes.map { String(format: "%.0f GiB", Double($0) / 1_073_741_824) } ?? "RAM unavailable"
        return "\(chip ?? "Chip unavailable") · \(memory) · \(model ?? "Mac model unavailable")"
    }
}

struct HubLocalRank: Decodable, Identifiable, Sendable {
    var id: String { model_id }
    let model_id: String
    let name: String
    let rank: Int?
    let status: String
    let passed: Int?
    let total: Int?
    let median_seconds: Double?
    let peak_memory: Int64?
    let load_seconds: Double?
    let download_bytes: Int64?
    let installed: Bool
    let finished_at: String?
    let error: String?
    let best_suite: String?
    let best_rank: Int?

    var stateDescription: String {
        switch status {
        case "ranked": return "\(passed ?? 0)/\(total ?? 0) passed"
        case "previous_setup": return "Recheck this Mac/setup"
        case "different_job": return "Different job"
        case "incomplete": return "Check incomplete"
        case "failed": return "Check failed"
        case "stopped": return "Checks stopped"
        case "interrupted": return "Checks interrupted"
        default: return "Not checked"
        }
    }
}

struct HubJobRanking: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let ranked_count: Int
    let entries: [HubLocalRank]
}

struct HubModelStorage: Decodable, Sendable {
    let free: Int64
    let models: Int64
}
