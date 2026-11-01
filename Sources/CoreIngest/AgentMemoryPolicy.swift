import CoreModel
import CoreStore
import Foundation

/// One conservative policy for imported agent instructions, generated memories and repo anchors.
/// Path names locate a source; they cannot establish that an unknown summary is safe to publish.
public enum AgentMemoryPolicy {
    public struct Classification: Sendable, Equatable {
        public let domain: Domain
        public let authority: Authority
        public init(domain: Domain, authority: Authority) {
            self.domain = domain
            self.authority = min(authority, .authoredArtifact)
        }
    }

    /// These names identify existing software workspaces. Everything unrecognised remains in
    /// quarantine rather than becoming project context because its filename sounds technical.
    ///
    /// **Compiled in: only what `origin/main` already carried.** Every other repository name
    /// lives in `LocalPrivateNames`, outside this public tree.
    private static let publicProjectNames: Set<String> = [
        "opencore", "openintelligence", "openresponses", "opencone", "plaudblender",
        "fascinaiting", "gunzino", "gunnarguy-portfolio", "ddg-pct",
    ]
    private static let publicMedicalNames: Set<String> = ["openclinic"]

    /// The folders that hold repositories, in the two forms a path and a slug spell them.
    private static let repositoryContainers = ["Documents/GitHub/", "Documents/Projects/", "Claude/Projects/"]
    private static let slugContainers = ["documents-github-", "documents-projects-", "claude-projects-", "applications-"]

    /// The compartment a repository's name puts it in. A name in two lists takes the stricter.
    public static func repositoryDomain(name: String, names: LocalPrivateNames = .current) -> Domain {
        let lower = name.lowercased()
        let local = names.repositories
        if publicMedicalNames.contains(lower) || local.medical.contains(lower) { return .medical }
        if local.personal.contains(lower) { return .personal }
        if publicProjectNames.contains(lower) || local.project.contains(lower) { return .project }
        return .restricted
    }

    /// `repositoryDomain`, or `nil` when the answer would only mean the list is unavailable.
    ///
    /// The difference is permanent. `.restricted` from a sync is never lowered again, so one sync
    /// with a missing, malformed or partial file used to pin every repository the binary can't
    /// name, along with its claims and events. `nil` leaves such a repository out instead: it
    /// isn't read, and what is stored stays as it was.
    private static func provenDomain(name: String, names: LocalPrivateNames) -> Domain? {
        let domain = repositoryDomain(name: name, names: names)
        return domain == .restricted && !names.repositories.isComplete ? nil : domain
    }

    /// The domain a `~/.claude/projects` slug proves, or `nil` when `provenDomain` can't say.
    ///
    /// A slug flattens `/` and `-` alike, so `foo-opencore` might be an unknown repository or a
    /// subfolder of a medical one, and a name is only trusted when it is the whole of what follows
    /// a repository container. Matching a suffix read both of those as `.project`.
    private static func slugDomain(_ lowerSlug: String, names: LocalPrivateNames) -> Domain? {
        let path: Substring
        if lowerSlug.hasPrefix("-applications-") {
            path = lowerSlug.dropFirst()
        } else if lowerSlug.hasPrefix("-users-") {
            // An account name holding a dash reads as no container, which is the safe direction.
            path = lowerSlug.dropFirst("-users-".count).drop { $0 != "-" }.dropFirst()
        } else {
            return .restricted
        }
        guard let container = slugContainers.first(where: { path.hasPrefix($0) }) else { return .restricted }
        if let nested = names.nestedRepositories.first(where: { slugPath($0.relativePath) == path }) {
            return provenDomain(name: nested.name, names: names)
        }
        return provenDomain(name: String(path.dropFirst(container.count)), names: names)
    }

    private static func slugPath(_ relativePath: String) -> String {
        relativePath.lowercased().replacingOccurrences(of: "/", with: "-")
    }

    /// Why a path is or isn't read. A sync has to tell the last two apart: a path that is no
    /// anchor is simply not wanted, and a withheld one is wanted and missing.
    private enum Placement {
        case placed(Classification)
        case notAnAnchor
        case withheld
    }

    /// `nil` means leave it out, either because the path is no anchor or because `names` can't
    /// say what the repository is.
    public static func classification(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, names: LocalPrivateNames = .current) -> Classification? {
        guard case .placed(let classification) = placement(for: url, home: home, names: names) else { return nil }
        return classification
    }

    /// Global files and rollout summaries mix projects and private topics. A summary's author
    /// is the generating agent, even when it describes the user's own words.
    private static func placement(for url: URL, home: URL, names: LocalPrivateNames) -> Placement {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return .notAnAnchor }
        let relative = String(path.dropFirst(prefix.count))
        if relative.hasPrefix(".codex/memories/") || relative.hasPrefix(".codex/memories_v2/") {
            return .placed(Classification(domain: .restricted, authority: .generatedSummary))
        }
        if relative.hasPrefix(".claude/projects/"), relative.contains("/memory/") || relative.hasSuffix("/memory") {
            let slug = relative.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
            let lowerSlug = slug.lowercased()
            let uncertain = ["private-tmp", "scratch", "worktrees", "conductor-workspaces", "ssh-"].contains { lowerSlug.contains($0) }
            guard let domain = uncertain ? .restricted : slugDomain(lowerSlug, names: names) else { return .withheld }
            return .placed(Classification(domain: domain, authority: .generatedSummary))
        }
        let globalAuthored: Set<String> = [".agents/MACHINE-MAP.md", ".claude/CLAUDE.md", "AGENTS.md", ".codex/AGENTS.md", ".agents/continuity/WORKFLOW.md", ".gemini/config/rules/gunnar.md"]
        if globalAuthored.contains(relative) {
            return .placed(Classification(domain: .restricted, authority: .authoredArtifact))
        }
        if relative == ".agents/briefs/codex-antigravity-parity.md" || relative == ".agents/continuity/Docs/ai/STATE.md" {
            return .placed(Classification(domain: .restricted, authority: .generatedSummary))
        }
        for container in repositoryContainers where relative.hasPrefix(container) {
            let tail = String(relative.dropFirst(container.count))
            let components = tail.split(separator: "/")
            guard let repo = components.first else { continue }
            let nested = names.nestedRepositories.first { relative.lowercased().hasPrefix($0.relativePath.lowercased() + "/") }
            let name = nested?.name ?? String(repo)
            let anchor = nested.map { String(relative.dropFirst($0.relativePath.count + 1)) } ?? components.dropFirst().joined(separator: "/")
            let anchorPaths: Set<String> = ["claude.md", "agents.md", "gemini.md", "readme.md", "handoff.md", "docs/ai/state.md", "docs/handoff.md", "docs/architecture.md", ".claude/.state/last-stop.md"]
            guard anchorPaths.contains(anchor.lowercased()) else { return .notAnAnchor }
            let lower = url.lastPathComponent.lowercased()
            let generated = lower == "state.md" || lower == "handoff.md" || lower == "last-stop.md"
            guard let domain = provenDomain(name: name, names: names) else { return .withheld }
            return .placed(Classification(domain: domain, authority: generated ? .generatedSummary : .authoredArtifact))
        }
        return .notAnAnchor
    }

    /// What a walk of the agents' folders found, and how much of it the policy had to leave out.
    public struct Discovery: Sendable {
        public let roots: [FilesystemConnector.Root]
        /// Files wanted and left out, because `names` can't say what their repository is.
        public let withheld: Int

        /// For `FilesystemConnector`, so that its read says it fell short.
        ///
        /// The bug: withholding left a repository's stored objects alone, and the sync it was left
        /// out of still moved the source's date. Once the list came back, those repositories'
        /// documents older than that date were skipped by `modified < since`.
        public var unread: [String] {
            withheld == 0 ? [] : ["\(withheld) files were left out because the private repository list is unavailable."]
        }
    }

    /// Every memory root `discoverMemories` finds. A sync wants that one, which keeps the count.
    public static func discoverRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser, names: LocalPrivateNames = .current) -> [FilesystemConnector.Root] {
        discoverMemories(home: home, names: names).roots
    }

    /// Every repository anchor `discoverRepositories` finds. A sync wants that one.
    public static func repositoryRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser, names: LocalPrivateNames = .current) -> [FilesystemConnector.Root] {
        discoverRepositories(home: home, names: names).roots
    }

    public static func discoverMemories(home: URL = FileManager.default.homeDirectoryForCurrentUser, names: LocalPrivateNames = .current) -> Discovery {
        let fm = FileManager.default
        var candidates = [
            ".agents/MACHINE-MAP.md", ".agents/briefs/codex-antigravity-parity.md", ".agents/continuity/Docs/ai/STATE.md", ".claude/CLAUDE.md", "AGENTS.md", ".codex/AGENTS.md", ".agents/continuity/WORKFLOW.md", ".gemini/config/rules/gunnar.md",
            ".codex/memories/MEMORY.md", ".codex/memories/memory_summary.md", ".codex/memories/Docs/ai/STATE.md",
            ".codex/memories_v2/MEMORY.md", ".codex/memories_v2/memory_summary.md", ".codex/memories_v2/Docs/ai/STATE.md",
        ].map { home.appendingPathComponent($0) }
        for folder in [".codex/memories/rollout_summaries", ".codex/memories_v2/rollout_summaries"] {
            candidates += ((try? fm.contentsOfDirectory(at: home.appendingPathComponent(folder), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension.lowercased() == "md" }
        }
        let projects = home.appendingPathComponent(".claude/projects")
        for slug in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
            candidates.append(slug.appendingPathComponent("memory"))
        }
        return discovery(candidates, home: home, names: names)
    }

    public static func discoverRepositories(home: URL = FileManager.default.homeDirectoryForCurrentUser, names: LocalPrivateNames = .current) -> Discovery {
        let fm = FileManager.default
        var repos: [URL] = []
        for container in repositoryContainers {
            repos += ((try? fm.contentsOfDirectory(at: home.appendingPathComponent(container), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        repos += names.nestedRepositories.map { home.appendingPathComponent($0.relativePath) }
        let anchors = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "README.md", "HANDOFF.md", "Docs/ai/STATE.md", "docs/ai/STATE.md", "Docs/HANDOFF.md", "docs/HANDOFF.md", "Docs/ARCHITECTURE.md", "docs/ARCHITECTURE.md", ".claude/.state/last-stop.md"]
        return discovery(repos.flatMap { repo in anchors.map { repo.appendingPathComponent($0) } }, home: home, names: names)
    }

    private static func discovery(_ candidates: [URL], home: URL, names: LocalPrivateNames) -> Discovery {
        var seen: Set<String> = []
        var roots: [FilesystemConnector.Root] = []
        var withheld = 0
        for url in candidates where FileManager.default.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL.path).inserted {
            switch placement(for: url, home: home, names: names) {
            case .placed(let policy): roots.append(FilesystemConnector.Root(url: url, domain: policy.domain, authority: policy.authority))
            case .withheld: withheld += 1
            case .notAnAnchor: break
            }
        }
        return Discovery(roots: roots, withheld: withheld)
    }
}
