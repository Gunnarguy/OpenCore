import CoreTelemetry
import AppKit
import CoreIngest
import CoreModel
import CoreStore
import Foundation

// MARK: - Cross-Agent Unification Snapshot (Claude Code · Codex · Antigravity)

struct AgentEcosystemSnapshot: Sendable, Equatable {
    // Claude Code (~/.claude)
    let claudeGlobalMDExists: Bool
    let claudeSkills: [String]
    let claudeHooksCount: Int
    let claudeMemoryProjectCount: Int
    let claudeMemoryFileCount: Int

    // Codex (~/.codex + ~/.agents)
    let codexGlobalAgentsMDExists: Bool
    let sharedAgentsSkills: [String]
    let codexProceduralSkills: [String]
    let codexHooksCount: Int
    let codexMemoryHandbookLines: Int
    let codexMemoryTaskSections: Int
    let codexRolloutSummaryCount: Int
    let codexMemoryStateUpdated: String
    let codexMemoryStateCommit: String
    let codexMemoryV2Exists: Bool

    // Antigravity (agy · ~/.gemini/config + ~/.agents)
    let agyGunnarRuleExists: Bool
    let agyKitBridgeExists: Bool
    let agySkillsCount: Int
    let parityBriefExists: Bool

    // Shared Machine Map
    let machineMapExists: Bool
    let machineMapSizeKB: Int

    // Rollout mentions per repo name (lowercased repo key -> count)
    let codexRolloutsByRepo: [String: Int]

    var skillsInSyncCount: Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Set(claudeSkills).intersection(Set(sharedAgentsSkills)).filter { name in
            let original = home.appendingPathComponent(".claude/skills/\(name)").resolvingSymlinksInPath().standardizedFileURL
            let shared = home.appendingPathComponent(".agents/skills/\(name)").resolvingSymlinksInPath().standardizedFileURL
            return original == shared
        }.count
    }

    var totalUnifiedMemoryArtifacts: Int {
        claudeMemoryFileCount + codexRolloutSummaryCount + (codexMemoryHandbookLines > 0 ? 2 : 0) + (codexMemoryV2Exists ? 1 : 0)
    }
}

// MARK: - Live Fleet Repository Card (`fleet.py --json` + `here.py --json`)

struct FleetRepoCard: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let desc: String
    let root: String
    let homeRel: String
    let git: Bool
    let branch: String
    let head: String
    let headSubject: String
    let headWhen: String
    let headDate: String
    let dirty: Int
    let dirtySample: [String]
    let unpushed: Int
    let statePath: String
    let stateRel: String
    let stateExists: Bool
    let stateUpdated: String
    let stateAgeDays: Int?
    let stateCommit: String
    let stateBehind: Int
    let stateStatus: String
    let objective: [String]
    let next: [String]
    let blockers: [String]
    let verifyCmd: String
    let shipCmd: String
    let fastCheck: Bool
    let fastCheckCmd: String
    let lastStop: String
    let lastStopMsg: String
    let sessions: Int
    let lastSession: String
    let memoryFiles: Int
    let memoryLines: Int
    let slugDir: String
    let rules: [String]
    let skills: [String]
    let missingDir: Bool
    let errorMessage: String?

    // Cross-Agent Unification metadata (Claude Code · Codex · Antigravity)
    let hasClaudeMD: Bool
    let hasAgentsMD: Bool
    let hasGeminiMD: Bool
    let codexRolloutCount: Int
    let fallbackOverview: String?
    let fallbackSourceLabel: String?

    var isHandoffCurrent: Bool { stateStatus == "current" }
    var isHandoffStale: Bool { stateStatus == "stale" }
    var isDirty: Bool { dirty > 0 }

    /// Clean relative path to the state/handoff file (never an 85-character `/Users/...` path).
    var shortStateRel: String {
        if !stateRel.isEmpty, !stateRel.hasPrefix("/") && !stateRel.hasPrefix("~") {
            return stateRel
        }
        if !statePath.isEmpty, !root.isEmpty, statePath.hasPrefix(root + "/") {
            return String(statePath.dropFirst(root.count + 1))
        }
        if !statePath.isEmpty {
            return (statePath as NSString).lastPathComponent
        }
        return "Docs/ai/STATE.md"
    }

    /// Human-clear explanation of what the handoff badge means.
    var handoffBadgeText: String {
        switch stateStatus {
        case "current":
            return "● HANDOFF CURRENT"
        case "stale":
            if stateBehind > 0 {
                return "▲ GIT +\(stateBehind) AHEAD"
            }
            return "▲ HANDOFF STALE"
        case "missing":
            return fallbackOverview != nil ? "◐ DOC OVERVIEW" : "○ NO STATE.MD"
        default:
            return "◐ HANDOFF \(stateStatus.uppercased())"
        }
    }

    var handoffProvenanceHelp: String {
        switch stateStatus {
        case "current":
            return "\(shortStateRel) last verified commit (\(stateCommit)) matches git HEAD (\(head)). Shared across Claude Code, Codex, and Antigravity."
        case "stale":
            let ahead = stateBehind > 0 ? "\(stateBehind) git commit(s) landed after \(shortStateRel) was written (\(stateCommit) -> \(head))." : "Git HEAD (\(head)) differs from \(shortStateRel) (\(stateCommit))."
            return "\(ahead) Run /handoff in Claude, Codex, or Antigravity to refresh \(shortStateRel)."
        case "missing":
            return "No \(shortStateRel) handoff file yet; showing summary from \(fallbackSourceLabel ?? "repo docs"). Ask the working agent to write a handoff. Automatic closeout behavior has not been verified for every provider."
        default:
            return "Handoff file at \(shortStateRel) (\(stateStatus))."
        }
    }

    /// Active agent badges for this repository (`Claude`, `Codex`, `AGY`).
    var activeAgents: [String] {
        var list: [String] = []
        if hasClaudeMD || memoryFiles > 0 || sessions > 0 || !lastStop.isEmpty {
            list.append("Claude")
        }
        if hasAgentsMD || codexRolloutCount > 0 {
            list.append("Codex")
        }
        if hasGeminiMD || hasClaudeMD || hasAgentsMD {
            list.append("AGY")
        }
        return list
    }

    var primaryObjective: String? {
        let joined = objective.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
        return fallbackOverview
    }

    var primaryObjectiveSource: String {
        let joined = objective.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            return shortStateRel
        }
        return fallbackSourceLabel ?? "README.md"
    }

    var primaryNextAction: String? {
        let joined = next.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    var primaryBlocker: String? {
        let joined = blockers.first?
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*"))) ?? ""
        return joined.isEmpty ? nil : joined
    }

    /// Ready-to-paste non-destructive orientation brief for Claude Code, Codex, or Antigravity.
    var sessionResumePrompt: String {
        var lines: [String] = [
            "Repository: \(name) (\(homeRel))",
            "Branch / HEAD: \(branch) @ \(head) (\(headWhen)) - \(headSubject)",
            "Working Tree: \(dirty == 0 ? "clean" : "\(dirty) modified files (\(dirtySample.prefix(5).joined(separator: ", ")))") · \(unpushed) unpushed commits",
            "Handoff (\(shortStateRel)): \(stateStatus.uppercased()) (last verified commit: \(stateCommit.isEmpty ? "none" : stateCommit))",
            "Agent Coverage: \(activeAgents.joined(separator: " + ")) · \(memoryFiles) Claude mem · \(codexRolloutCount) Codex rollouts · \(sessions) sessions",
        ]
        if let obj = primaryObjective {
            lines.append("Current Objective (\(primaryObjectiveSource)): \(obj)")
        }
        if let nxt = primaryNextAction {
            lines.append("Exact Next Action: \(nxt)")
        }
        if let blk = primaryBlocker {
            lines.append("Active Blocker: \(blk)")
        }
        if !lastStopMsg.isEmpty {
            lines.append("Last Session Stop (\(lastStop)): \(lastStopMsg)")
        }
        if !verifyCmd.isEmpty {
            lines.append("Verify Command: \(verifyCmd)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Read-Only Machine, Simulator, iCloud & Tailnet Health

struct BootedSimulatorInfo: Identifiable, Sendable, Equatable {
    var id: String { udid }
    let name: String
    let udid: String
    let runtime: String
}

struct TailnetPeerStatus: Identifiable, Sendable, Equatable {
    var id: String { alias }
    let alias: String
    let role: String
    let reachable: Bool
    let summary: String
}

struct MachineHealthSnapshot: Sendable, Equatable {
    let diskSpace: DiskSpaceReading
    var dataVolumeFreeGiB: Double? { diskSpace.freeGiB }
    var dataVolumeTotalGiB: Double? { diskSpace.totalGiB }
    var dataVolumeUsedPercent: Int? { diskSpace.usedPercent }
    let bootedSimulators: [BootedSimulatorInfo]
    let icloudConflictFiles: [String]
    let simulatorCheckError: String?
    let numberedFileScanError: String?
    let tailnetPeers: [TailnetPeerStatus]
    let claudeMemoryFileCount: Int
    let codexRolloutCount: Int
    let sharedSkillCount: Int
    let machineMapExists: Bool
    let checkedAt: Date

    func isDiskSpaceLow(thresholdGiB: Double) -> Bool { diskSpace.isLow(thresholdGiB: thresholdGiB) }
    var freeSpaceSummary: String { dataVolumeFreeGiB.map { String(format: "%.1f GiB free", $0) } ?? "Disk space not measured" }
    var simulatorSummary: String { simulatorCheckError == nil ? "\(bootedSimulators.count) sim" : "sim check unavailable" }
    var numberedFileSummary: String { numberedFileScanError == nil ? "\(icloudConflictFiles.count) possible duplicates" : "duplicate scan incomplete" }
    var estimatedSimulatorRAMGiB: Double { Double(bootedSimulators.count) * 3.0 }
}

// MARK: - Operator Console Service (100% Read-Only & Non-Destructive)

enum OperatorConsoleService {
    // Chosen bound for the read-only filename scan, not a count of every duplicate on the Mac.
    static let numberedFileScanLimit = 20

    /// Repositories beyond `fleet.py`'s static table that should appear with full handoff cards.
    /// Only names this public repository already carries are compiled in; the rest come from
    /// `LocalPrivateNames`, which lives outside any git tree.
    private static let extraActiveRepos: [(name: String, relPath: String, desc: String)] = {
        let compiled: [(name: String, relPath: String, desc: String)] = [
            ("Codex-Memories", ".codex/memories", "Codex progressive-disclosure handbook (MEMORY.md + rollout summaries)"),
            ("OpenClinic", "Documents/GitHub/OpenClinic", "Local clinical RAG & FHIR workflow suite"),
            ("OpenCone", "Documents/GitHub/OpenCone", "Semantic vector & retrieval workbench"),
        ]
        return compiled + LocalPrivateNames.current.operatorRepositories.map { ($0.name, $0.relativePath, $0.summary) }
    }()

    /// Collects real-time cross-agent unification metrics across Claude Code (`~/.claude`),
    /// Codex (`~/.codex` + `~/.agents`), and Antigravity (`~/.gemini/config` + `~/.agents`).
    static func collectAgentEcosystem() async -> AgentEcosystemSnapshot {
        await Task.detached(priority: .userInitiated) {
            buildAgentEcosystemSnapshotSync()
        }.value
    }

    private static func buildAgentEcosystemSnapshotSync() -> AgentEcosystemSnapshot {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. Claude Code (~/.claude)
        let claudeGlobalMD = home.appendingPathComponent(".claude/CLAUDE.md").path
        let claudeSkillsDir = home.appendingPathComponent(".claude/skills").path
        let claudeSkills = listSkillDirectoryNames(atPath: claudeSkillsDir)
        let claudeHooksDir = home.appendingPathComponent(".claude/hooks").path
        let claudeHooks = ((try? fm.contentsOfDirectory(atPath: claudeHooksDir)) ?? [])
            .filter { $0.hasSuffix(".sh") && !$0.contains(".bak") && $0 != "lib.sh" }
        let claudeRoots = discoverClaudeMemoryRoots()
        var claudeMemFiles = 0
        for root in claudeRoots {
            let files = (try? fm.contentsOfDirectory(atPath: root.url.path)) ?? []
            claudeMemFiles += files.filter { $0.lowercased().hasSuffix(".md") }.count
        }

        // 2. Codex (~/.codex + ~/.agents)
        let codexGlobalAgentsMD = home.appendingPathComponent(".codex/AGENTS.md").path
        let sharedSkillsDir = home.appendingPathComponent(".agents/skills").path
        let sharedSkills = listSkillDirectoryNames(atPath: sharedSkillsDir)
        let codexProcSkillsDir = home.appendingPathComponent(".codex/memories/skills").path
        let codexProcSkills = ((try? fm.contentsOfDirectory(atPath: codexProcSkillsDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        let codexHooksDir = home.appendingPathComponent(".codex/hooks").path
        let codexHooks = ((try? fm.contentsOfDirectory(atPath: codexHooksDir)) ?? [])
            .filter { $0.hasSuffix(".sh") && !$0.contains(".bak") && $0 != "lib.sh" }

        let codexMemoryMDPath = home.appendingPathComponent(".codex/memories/MEMORY.md").path
        let codexMemoryMDText = (try? String(contentsOfFile: codexMemoryMDPath, encoding: .utf8)) ?? ""
        let codexMemoryLines = codexMemoryMDText.isEmpty ? 0 : codexMemoryMDText.components(separatedBy: .newlines).count
        let codexTaskSections = codexMemoryMDText.components(separatedBy: "\n### ").count - 1

        let rolloutsDir = home.appendingPathComponent(".codex/memories/rollout_summaries").path
        let rolloutFiles = ((try? fm.contentsOfDirectory(atPath: rolloutsDir)) ?? [])
            .filter { $0.hasSuffix(".md") }
        let rolloutsV2Dir = home.appendingPathComponent(".codex/memories_v2/rollout_summaries").path
        let rolloutV2Files = ((try? fm.contentsOfDirectory(atPath: rolloutsV2Dir)) ?? [])
            .filter { $0.hasSuffix(".md") }
        let allRolloutNames = (rolloutFiles + rolloutV2Files).map { $0.lowercased() }

        // Count rollout mentions by repository keyword
        var repoKeywords: [String: [String]] = [
            "openintelligence": ["openintelligence", "5_7", "pcc_rag"],
            "opencore": ["opencore"],
            "gunnarguy-portfolio": ["portfolio"],
            "fascinaiting": ["fascinaiting"],
            "gunzino": ["gunzino"],
            "plaud": ["plaud"],
            "plaudblender": ["plaud"],
            "openclinic": ["openclinic", "fhir"],
            "opencone": ["opencone"],
            "codex-memories": [""],
        ]
        repoKeywords.merge(LocalPrivateNames.current.rolloutKeywords) { $0 + $1 }
        var rolloutsByRepo: [String: Int] = [:]
        for (repoKey, needles) in repoKeywords {
            if repoKey == "codex-memories" {
                rolloutsByRepo[repoKey] = allRolloutNames.count
                continue
            }
            let count = allRolloutNames.filter { filename in
                needles.contains { needle in !needle.isEmpty && filename.contains(needle) }
            }.count
            if count > 0 {
                rolloutsByRepo[repoKey] = count
            }
        }

        let codexStatePath = home.appendingPathComponent(".codex/memories/Docs/ai/STATE.md").path
        let codexStateText = (try? String(contentsOfFile: codexStatePath, encoding: .utf8)) ?? ""
        var codexUpdated = ""
        var codexCommit = ""
        for line in codexStateText.components(separatedBy: .newlines) {
            if line.hasPrefix("Updated:") {
                codexUpdated = line.replacingOccurrences(of: "Updated:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Last verified commit:") {
                let raw = line.replacingOccurrences(of: "Last verified commit:", with: "").trimmingCharacters(in: .whitespaces)
                codexCommit = String(raw.split(separator: " ").first ?? "")
            }
        }
        let codexV2SummaryPath = home.appendingPathComponent(".codex/memories_v2/memory_summary.md").path

        // 3. Antigravity (agy · ~/.gemini/config + ~/.agents)
        let agyRulePath = home.appendingPathComponent(".gemini/config/rules/gunnar.md").path
        let agyBridgePath = home.appendingPathComponent(".gemini/config/hooks/kit-bridge.py").path
        let agySkillsDir = home.appendingPathComponent(".gemini/config/skills").path
        let agySkills = listSkillDirectoryNames(atPath: agySkillsDir)
        let parityBriefPath = home.appendingPathComponent(".agents/briefs/codex-antigravity-parity.md").path

        // 4. Machine Map
        let machineMapPath = home.appendingPathComponent(".agents/MACHINE-MAP.md").path
        let machineMapExists = fm.fileExists(atPath: machineMapPath)
        let machineMapBytes = ((try? fm.attributesOfItem(atPath: machineMapPath))?[.size] as? NSNumber)?.intValue ?? 0

        return AgentEcosystemSnapshot(
            claudeGlobalMDExists: fm.fileExists(atPath: claudeGlobalMD),
            claudeSkills: claudeSkills,
            claudeHooksCount: claudeHooks.count,
            claudeMemoryProjectCount: claudeRoots.count,
            claudeMemoryFileCount: claudeMemFiles,
            codexGlobalAgentsMDExists: fm.fileExists(atPath: codexGlobalAgentsMD),
            sharedAgentsSkills: sharedSkills,
            codexProceduralSkills: codexProcSkills,
            codexHooksCount: codexHooks.count,
            codexMemoryHandbookLines: codexMemoryLines,
            codexMemoryTaskSections: max(0, codexTaskSections),
            codexRolloutSummaryCount: allRolloutNames.count,
            codexMemoryStateUpdated: codexUpdated,
            codexMemoryStateCommit: codexCommit,
            codexMemoryV2Exists: fm.fileExists(atPath: codexV2SummaryPath),
            agyGunnarRuleExists: fm.fileExists(atPath: agyRulePath),
            agyKitBridgeExists: fm.fileExists(atPath: agyBridgePath),
            agySkillsCount: agySkills.count,
            parityBriefExists: fm.fileExists(atPath: parityBriefPath),
            machineMapExists: machineMapExists,
            machineMapSizeKB: max(1, machineMapBytes / 1024),
            codexRolloutsByRepo: rolloutsByRepo
        )
    }

    private static func listSkillDirectoryNames(atPath dirPath: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return [] }
        return entries.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let skillFile = (dirPath as NSString).appendingPathComponent("\(name)/SKILL.md")
            return FileManager.default.fileExists(atPath: skillFile)
        }.sorted()
    }

    /// Runs `~/.claude/bin/fleet.py --json` plus `here.py --json` on active sibling repos off the
    /// main thread and enriches every card with Claude, Codex, and Antigravity metadata.
    static func collectFleet() async -> [FleetRepoCard] {
        await Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let fleetScript = home.appendingPathComponent(".claude/bin/fleet.py").path
            let hereScript = home.appendingPathComponent(".claude/bin/here.py").path
            guard FileManager.default.fileExists(atPath: fleetScript) else { return [] }

            let ecosystem = buildAgentEcosystemSnapshotSync()

            let (exitCode, stdout, _) = runProcess(
                executable: "/usr/bin/python3",
                arguments: [fleetScript, "--json"],
                timeoutSeconds: 25
            )
            var cards: [FleetRepoCard] = []
            if exitCode == 0, let data = stdout.data(using: .utf8),
               let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                cards = rawArray.map { parseCard($0, rolloutsByRepo: ecosystem.codexRolloutsByRepo) }
            }

            // Also inspect the extra active repositories listed in `extraActiveRepos`.
            if FileManager.default.fileExists(atPath: hereScript) {
                let existingNames = Set(cards.map { $0.name.lowercased() })
                for extra in extraActiveRepos where !existingNames.contains(extra.name.lowercased()) {
                    let fullRoot = home.appendingPathComponent(extra.relPath).path
                    guard FileManager.default.fileExists(atPath: fullRoot) else { continue }
                    let (rc, out, _) = runProcess(
                        executable: "/usr/bin/python3",
                        arguments: [hereScript, "--json", fullRoot],
                        timeoutSeconds: 6
                    )
                    if rc == 0, let d = out.data(using: .utf8),
                       var dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        dict["name"] = extra.name
                        dict["desc"] = extra.desc
                        cards.append(parseCard(dict, rolloutsByRepo: ecosystem.codexRolloutsByRepo))
                    }
                }
            }

            return cards
        }.value
    }

    /// Refreshes a single repository card via `~/.claude/bin/here.py --json <root>`.
    static func collectSingleRepo(root: String, existingName: String, existingDesc: String) async -> FleetRepoCard? {
        await Task.detached(priority: .userInitiated) {
            let scriptPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/bin/here.py").path
            guard FileManager.default.fileExists(atPath: scriptPath) else { return nil }

            let ecosystem = buildAgentEcosystemSnapshotSync()
            let (exitCode, stdout, _) = runProcess(
                executable: "/usr/bin/python3",
                arguments: [scriptPath, "--json", root],
                timeoutSeconds: 12
            )
            guard exitCode == 0, let data = stdout.data(using: .utf8),
                  var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            dict["name"] = existingName
            dict["desc"] = existingDesc
            return parseCard(dict, rolloutsByRepo: ecosystem.codexRolloutsByRepo)
        }.value
    }

    /// Read-only inspection of disk space, booted simulators, iCloud duplicate conflict files,
    /// cross-agent memory counts, and reachability of the machines named in `LocalPrivateNames`.
    static func collectMachineHealth(checkTailnet: Bool = true) async -> MachineHealthSnapshot {
        await Task.detached(priority: .utility) {
            // 1. Data volume free space (/System/Volumes/Data)
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/System/Volumes/Data")
            let diskSpace = DiskSpaceReading(freeBytes: (attrs?[.systemFreeSize] as? NSNumber)?.doubleValue,
                                             totalBytes: (attrs?[.systemSize] as? NSNumber)?.doubleValue)

            // 2. Read-only booted simulator inspection (never erases, deletes, or shuts down)
            let bootedSims = listBootedSimulators()

            // 3. Read-only iCloud conflict file check (`* 2.swift`, `* 2.md`, `* 2.py`)
            let conflictFiles = scanICloudConflictFiles()

            // 4. Cross-agent ecosystem summary
            let ecosystem = buildAgentEcosystemSnapshotSync()

            // 5. Tailnet peer status (read-only 2-second SSH ping)
            var peers: [TailnetPeerStatus] = [
                TailnetPeerStatus(
                    alias: "this Mac",
                    role: "Local",
                    reachable: true,
                    summary: diskSpace.freeGiB.map { String(format: "%.1f GiB free on Data volume", $0) } ?? "Data volume space not measured"
                )
            ]
            if checkTailnet {
                // Which machines exist is private, so the list is `LocalPrivateNames`. No list
                // means no probes rather than a hard-coded guess at somebody's hostnames.
                for peer in LocalPrivateNames.current.peers {
                    peers.append(probeTailnetPeer(alias: peer.alias, role: peer.role))
                }
            }

            return MachineHealthSnapshot(
                diskSpace: diskSpace,
                bootedSimulators: bootedSims.devices,
                icloudConflictFiles: conflictFiles.files,
                simulatorCheckError: bootedSims.error,
                numberedFileScanError: conflictFiles.error,
                tailnetPeers: peers,
                claudeMemoryFileCount: ecosystem.claudeMemoryFileCount,
                codexRolloutCount: ecosystem.codexRolloutSummaryCount,
                sharedSkillCount: ecosystem.sharedAgentsSkills.count,
                machineMapExists: ecosystem.machineMapExists,
                checkedAt: Date()
            )
        }.value
    }

    /// Discovers all real `~/.claude/projects/<slug>/memory` directories with their appropriate
    /// privacy `Domain` compartment, per `AgentMemoryPolicy`.
    static func discoverClaudeMemoryRoots() -> [FilesystemConnector.Root] {
        AgentMemoryPolicy.discoverRoots().filter { $0.url.path.contains("/.claude/projects/") }
    }

    // MARK: - Non-Destructive OS Actions

    @MainActor
    static func openInTerminal(rootPath: String) {
        let folderURL = URL(fileURLWithPath: rootPath)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folderURL], withApplicationAt: terminalURL, configuration: config)
    }

    @MainActor
    static func revealInFinder(path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        }
    }

    @MainActor
    static func openFile(path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Runs a read-only git and handoff inspection on `repo.root` and returns the formatted report.
    static func runReadOnlyRepoAudit(repo: FleetRepoCard) async -> String {
        await Task.detached(priority: .userInitiated) {
            let herePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/bin/here.py").path
            var sections: [String] = []
            if FileManager.default.fileExists(atPath: herePath) {
                let (_, out, err) = runProcess(
                    executable: "/usr/bin/python3",
                    arguments: [herePath, repo.root],
                    timeoutSeconds: 12
                )
                let combined = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
                if !combined.isEmpty {
                    sections.append("=== here.py orientation card ===\n\(combined)")
                }
            }
            if repo.git {
                let (_, logOut, _) = runProcess(
                    executable: "/usr/bin/git",
                    arguments: ["-C", repo.root, "log", "-n", "5", "--oneline", "--decorate"],
                    timeoutSeconds: 8
                )
                if !logOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append("=== Recent 5 Commits ===\n\(logOut.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            return sections.isEmpty ? "No output returned." : sections.joined(separator: "\n\n")
        }.value
    }

    // MARK: - Internal Helpers

    private static func listBootedSimulators() -> (devices: [BootedSimulatorInfo], error: String?) {
        let (code, stdout, _) = runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "booted", "-j"],
            timeoutSeconds: 5
        )
        guard code == 0, let data = stdout.data(using: .utf8), let devices = try? SimulatorReading.decode(data)
        else { return ([], "Simulator status could not be read. Refresh to retry.") }
        return (devices.map { BootedSimulatorInfo(name: $0.name, udid: $0.udid, runtime: $0.runtime) }, nil)
    }

    private static func scanICloudConflictFiles() -> (files: [String], error: String?) {
        let githubRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub", isDirectory: true)
        guard let repos = try? FileManager.default.contentsOfDirectory(
            at: githubRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], "The repository folder could not be read. Refresh to retry.") }

        let watchedSuffixes = NumberedFileCandidate.suffixes
        var conflicts: [String] = []
        var incomplete = false
        let incompleteMessage = "Some repository folders could not be checked. Results may be incomplete. Refresh to retry."

        for repo in repos {
            guard let values = try? repo.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { incomplete = true; continue }
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: repo,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in incomplete = true; return true }
            ) else { incomplete = true; continue }

            while let url = enumerator.nextObject() as? URL {
                let name = url.lastPathComponent
                if FilesystemConnector.skippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if watchedSuffixes.contains(where: { name.hasSuffix($0) }) {
                    guard let flags = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { incomplete = true; continue }
                    guard flags.isRegularFile == true, flags.isSymbolicLink != true else { continue }
                    let rel = url.path.replacingOccurrences(of: githubRoot.path + "/", with: "")
                    conflicts.append(rel)
                    if conflicts.count >= numberedFileScanLimit { return (conflicts, incomplete ? incompleteMessage : nil) }
                }
            }
        }
        return (conflicts, incomplete ? incompleteMessage : nil)
    }

    private static func probeTailnetPeer(alias: String, role: String) -> TailnetPeerStatus {
        let (code, stdout, _) = runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                alias,
                "uptime"
            ],
            timeoutSeconds: 4
        )
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == 0, !trimmed.isEmpty {
            return TailnetPeerStatus(alias: alias, role: role, reachable: true, summary: trimmed)
        } else {
            return TailnetPeerStatus(alias: alias, role: role, reachable: false, summary: "Offline or unreachable via SSH")
        }
    }

    /// Extracts a concise 1-line summary from `CLAUDE.md`, `AGENTS.md`, or `README.md` when a repo
    /// does not yet have a `Docs/ai/STATE.md` objective.
    private static func extractDocFallbackOverview(root: String) -> (overview: String?, source: String?) {
        guard !root.isEmpty else { return (nil, nil) }
        let fm = FileManager.default
        for candidate in ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "README.md"] {
            let path = (root as NSString).appendingPathComponent(candidate)
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            for rawLine in content.components(separatedBy: .newlines).prefix(35) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty
                    || trimmed.hasPrefix("#")
                    || trimmed.hasPrefix("```")
                    || trimmed.hasPrefix("|")
                    || trimmed.hasPrefix("![")
                    || trimmed.hasPrefix("<")
                    || trimmed.hasPrefix("> [!") {
                    continue
                }
                let cleaned = trimmed
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                if cleaned.count >= 18 {
                    return (String(cleaned.prefix(180)), candidate)
                }
            }
        }
        return (nil, nil)
    }

    private static func parseCard(_ d: [String: Any], rolloutsByRepo: [String: Int]) -> FleetRepoCard {
        let name = (d["name"] as? String) ?? "Unknown"
        let root = (d["root"] as? String) ?? ""
        let fm = FileManager.default

        let hasClaudeMD = (d["claude_md"] as? Bool) ?? (!root.isEmpty && fm.fileExists(atPath: (root as NSString).appendingPathComponent("CLAUDE.md")))
        let hasAgentsMD = !root.isEmpty && fm.fileExists(atPath: (root as NSString).appendingPathComponent("AGENTS.md"))
        let hasGeminiMD = !root.isEmpty && fm.fileExists(atPath: (root as NSString).appendingPathComponent("GEMINI.md"))
        let rollouts = rolloutsByRepo[name.lowercased()] ?? 0

        let rawObjective = (d["objective"] as? [String]) ?? []
        let fallback: (overview: String?, source: String?)
        if rawObjective.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fallback = extractDocFallbackOverview(root: root)
        } else {
            fallback = (nil, nil)
        }

        return FleetRepoCard(
            name: name,
            desc: (d["desc"] as? String) ?? "",
            root: root,
            homeRel: (d["home_rel"] as? String) ?? "",
            git: (d["git"] as? Bool) ?? false,
            branch: (d["branch"] as? String) ?? "",
            head: (d["head"] as? String) ?? "",
            headSubject: (d["head_subject"] as? String) ?? "",
            headWhen: (d["head_when"] as? String) ?? "",
            headDate: (d["head_date"] as? String) ?? "",
            dirty: (d["dirty"] as? Int) ?? 0,
            dirtySample: (d["dirty_sample"] as? [String]) ?? [],
            unpushed: (d["unpushed"] as? Int) ?? 0,
            statePath: (d["state_path"] as? String) ?? "",
            stateRel: (d["state_rel"] as? String) ?? "",
            stateExists: (d["state_exists"] as? Bool) ?? false,
            stateUpdated: (d["state_updated"] as? String) ?? "",
            stateAgeDays: d["state_age_days"] as? Int,
            stateCommit: (d["state_commit"] as? String) ?? "",
            stateBehind: (d["state_behind"] as? Int) ?? 0,
            stateStatus: (d["state_status"] as? String) ?? "missing",
            objective: rawObjective,
            next: (d["next"] as? [String]) ?? [],
            blockers: (d["blockers"] as? [String]) ?? [],
            verifyCmd: (d["verify_cmd"] as? String) ?? "",
            shipCmd: (d["ship_cmd"] as? String) ?? "",
            fastCheck: (d["fast_check"] as? Bool) ?? false,
            fastCheckCmd: (d["fast_check_cmd"] as? String) ?? "",
            lastStop: (d["last_stop"] as? String) ?? "",
            lastStopMsg: (d["last_stop_msg"] as? String) ?? "",
            sessions: (d["sessions"] as? Int) ?? 0,
            lastSession: (d["last_session"] as? String) ?? "",
            memoryFiles: (d["memory_files"] as? Int) ?? 0,
            memoryLines: (d["memory_lines"] as? Int) ?? 0,
            slugDir: (d["slug_dir"] as? String) ?? "",
            rules: (d["rules"] as? [String]) ?? [],
            skills: (d["skills"] as? [String]) ?? [],
            missingDir: (d["missing_dir"] as? Bool) ?? false,
            errorMessage: d["error"] as? String,
            hasClaudeMD: hasClaudeMD,
            hasAgentsMD: hasAgentsMD,
            hasGeminiMD: hasGeminiMD,
            codexRolloutCount: rollouts,
            fallbackOverview: fallback.overview,
            fallbackSourceLabel: fallback.source
        )
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> (Int32, String, String) {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        do {
            let result = try BoundedProcess.run(executable: executable, arguments: arguments,
                                                environment: env, timeout: timeoutSeconds)
            if result.timedOut {
                return (-2, result.stdoutText, "Timed out after \(Int(timeoutSeconds))s. " + result.stderrText)
            }
            return (result.status, result.stdoutText, result.stderrText)
        } catch {
            return (-1, "", "\(error)")
        }
    }
}
