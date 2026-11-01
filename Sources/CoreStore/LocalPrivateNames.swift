import Foundation

/// Names that are real, needed at run time, and must never be in this public repository.
///
/// **Why a file and not constants.** Classifying an agent's memory needs to know which
/// repositories on this Mac are medical or personal, and the operator console needs to know the
/// private repositories and machines it should look at. Those lists are private by nature: a
/// repository name can say who someone works for. They were compiled in, and a public repo
/// published them. The lists now live beside the store, outside any git tree, and the compiled
/// tables hold only repository names `origin/main` already carried.
///
/// **A missing file withholds; it does not guess.** An unlisted repository is hidden and no
/// machine is probed, and repositories the binary can't name are left out of a sync altogether.
/// They are not classified `.restricted` while the list is unavailable, because that word is a
/// one-way door: `Store.retainedImportDomain` keeps `.restricted` forever, and a repair moves the
/// object's claims and events with it. A list that went missing must cost a sync's freshness,
/// never a permanent change to what is already stored. `repositories.isComplete` is how the
/// classifier tells the two cases apart. With a complete list, a name in none of the lists is a
/// real answer, and it is `.restricted`.
///
/// `Docs/private-names.example.json` shows the shape with made-up values.
public struct LocalPrivateNames: Codable, Sendable, Equatable {
    /// Repository names by compartment, lowercased on load.
    public struct Repositories: Codable, Sendable, Equatable {
        public var project: [String]
        public var medical: [String]
        public var personal: [String]
        /// Whether a name in no list means "unknown repository" rather than "the list is
        /// unavailable". True only when the file stated all three lists, even if one is empty.
        public var isComplete: Bool

        /// No file, or a file that didn't say. Every repository the binary can't name is withheld.
        public static let unavailable = Repositories(isComplete: false)

        public init(project: [String] = [], medical: [String] = [], personal: [String] = [], isComplete: Bool = true) {
            self.project = project.map { $0.lowercased() }
            self.medical = medical.map { $0.lowercased() }
            self.personal = personal.map { $0.lowercased() }
            self.isComplete = isComplete
        }

        private enum CodingKeys: String, CodingKey { case project, medical, personal }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let project = try container.decodeIfPresent([String].self, forKey: .project)
            let medical = try container.decodeIfPresent([String].self, forKey: .medical)
            let personal = try container.decodeIfPresent([String].self, forKey: .personal)
            self.init(
                project: project ?? [], medical: medical ?? [], personal: personal ?? [],
                isComplete: project != nil && medical != nil && personal != nil
            )
        }
    }

    /// A repository the operator console lists beyond what `fleet.py` reports.
    public struct OperatorRepository: Codable, Sendable, Equatable {
        public var name: String
        /// Relative to the home directory.
        public var relativePath: String
        public var summary: String

        public init(name: String, relativePath: String, summary: String) {
            self.name = name
            self.relativePath = relativePath
            self.summary = summary
        }
    }

    /// An SSH alias the machine check may probe.
    public struct Peer: Codable, Sendable, Equatable {
        public var alias: String
        public var role: String

        public init(alias: String, role: String) {
            self.alias = alias
            self.role = role
        }
    }

    /// A repository that sits inside another one, so its name is not its container's child.
    /// The name is looked up in `repositories` like any other.
    public struct NestedRepository: Codable, Sendable, Equatable {
        public var name: String
        /// Relative to the home directory.
        public var relativePath: String

        public init(name: String, relativePath: String) {
            self.name = name
            self.relativePath = relativePath
        }
    }

    /// Where the local automation tools live, and how the loopback hub identifies itself.
    /// Nothing here has a default: an unset path is not read, and a hub that can't be matched
    /// against an expected identity is treated as not running, so its token is never fetched.
    public struct LocalAutomation: Codable, Sendable, Equatable {
        /// Relative to the home directory.
        public var hubRepositoryRelativePath: String?
        /// The value `/api/identity` must report in `app`.
        public var hubIdentity: String?
        /// Relative to the home directory.
        public var profilesRelativePath: String?

        public init(hubRepositoryRelativePath: String? = nil, hubIdentity: String? = nil, profilesRelativePath: String? = nil) {
            self.hubRepositoryRelativePath = hubRepositoryRelativePath
            self.hubIdentity = hubIdentity
            self.profilesRelativePath = profilesRelativePath
        }
    }

    public var repositories: Repositories
    public var operatorRepositories: [OperatorRepository]
    /// Extra filename keywords for attributing agent summaries to a repository, by repository key.
    public var rolloutKeywords: [String: [String]]
    public var peers: [Peer]
    public var nestedRepositories: [NestedRepository]
    public var localAutomation: LocalAutomation

    public static let empty = LocalPrivateNames()

    public init(
        repositories: Repositories = .unavailable,
        operatorRepositories: [OperatorRepository] = [],
        rolloutKeywords: [String: [String]] = [:],
        peers: [Peer] = [],
        nestedRepositories: [NestedRepository] = [],
        localAutomation: LocalAutomation = LocalAutomation()
    ) {
        self.repositories = repositories
        self.operatorRepositories = operatorRepositories
        self.rolloutKeywords = rolloutKeywords
        self.peers = peers
        self.nestedRepositories = nestedRepositories
        self.localAutomation = localAutomation
    }

    /// One decoded element of a list, or nothing. An entry missing a field costs that entry.
    private struct Lossy<Element: Decodable>: Decodable {
        let value: Element?
        init(from decoder: any Decoder) throws { value = try? Element(from: decoder) }
    }

    /// Decoded by hand so a partial file still loads. Synthesised `Decodable` requires every
    /// key, and a privacy list that silently fails to decode because one optional section is
    /// missing would drop every other section with it. The same goes for one bad entry in a
    /// list and for a section of the wrong type: each loses itself and nothing else. Only a
    /// file that isn't a JSON object throws.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = (try? container.decodeIfPresent(Repositories.self, forKey: .repositories)) ?? .unavailable
        operatorRepositories = ((try? container.decodeIfPresent([Lossy<OperatorRepository>].self, forKey: .operatorRepositories)) ?? nil)?.compactMap(\.value) ?? []
        rolloutKeywords = (try? container.decodeIfPresent([String: [String]].self, forKey: .rolloutKeywords)) ?? [:]
        peers = ((try? container.decodeIfPresent([Lossy<Peer>].self, forKey: .peers)) ?? nil)?.compactMap(\.value) ?? []
        nestedRepositories = ((try? container.decodeIfPresent([Lossy<NestedRepository>].self, forKey: .nestedRepositories)) ?? nil)?.compactMap(\.value) ?? []
        localAutomation = (try? container.decodeIfPresent(LocalAutomation.self, forKey: .localAutomation)) ?? LocalAutomation()
    }

    /// Why the repository lists can't answer, for a person to read.
    public enum LoadProblem: Sendable, Equatable {
        case missing
        case unreadable
        case incomplete

        public var explanation: String {
            let consequence = "repositories this build can't name were left out of the sync, and what is already stored was not changed."
            switch self {
            case .missing: return "private-names.json is not installed beside the store, so \(consequence)"
            case .unreadable: return "private-names.json could not be read as JSON, so \(consequence)"
            case .incomplete: return "private-names.json does not state all three repository lists, so \(consequence)"
            }
        }
    }

    /// Beside the store. `OPENCORE_PRIVATE_NAMES` overrides it for one process.
    public static func defaultPath() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENCORE_PRIVATE_NAMES"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return Database.defaultPath().deletingLastPathComponent().appendingPathComponent("private-names.json")
    }

    /// Read, and say what went wrong. Nothing here prints: this runs in the `opencore mcp` path.
    public static func read(from url: URL? = nil) -> (names: LocalPrivateNames, problem: LoadProblem?) {
        let path = url ?? defaultPath()
        guard FileManager.default.fileExists(atPath: path.path) else { return (.empty, .missing) }
        guard let data = try? Data(contentsOf: path),
              let names = try? JSONDecoder().decode(LocalPrivateNames.self, from: data)
        else { return (.empty, .unreadable) }
        return (names, names.repositories.isComplete ? nil : .incomplete)
    }

    /// Read, falling back to `.empty`.
    public static func load(from url: URL? = nil) -> LocalPrivateNames {
        read(from: url).names
    }

    /// Loaded once per process. These lists change by hand, rarely, and a classifier that
    /// re-read a file for every path of a sync would also be able to disagree with itself
    /// halfway through one.
    private static let loaded = read()
    public static var current: LocalPrivateNames { loaded.names }
    public static var currentProblem: LoadProblem? { loaded.problem }
}
