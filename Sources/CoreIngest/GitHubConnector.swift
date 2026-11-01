import CoreModel
import CoreTelemetry
import Foundation
import Synchronization

/// GitHub is the first connector on purpose.
///
/// Everything the epistemic layer needs to be exercised is already structured here and
/// already timestamped: repositories are entities, commits are events, languages and
/// dependencies are claims with real validity intervals, and the whole thing has an
/// authority story that is not a guess (a commit is an authored artifact; a README's
/// description of the code is a claim that can be *wrong about it*, which is the
/// interesting case).
public struct GitHubConnector: Connector {
    public let source: Source
    private let login: String
    private let token: String
    private let commitsPerRepo: Int
    private let includeForks: Bool

    public init(login: String, token: String, commitsPerRepo: Int = 100, includeForks: Bool = false) {
        self.login = login
        self.token = token
        self.commitsPerRepo = commitsPerRepo
        self.includeForks = includeForks
        self.source = Source(
            kind: .github,
            handle: login,
            displayName: "GitHub · \(login)",
            // A commit is something the user wrote, incidentally, while doing the work.
            // Not a direct statement about themselves, which is a higher tier.
            defaultAuthority: .authoredArtifact,
            defaultDomain: .project
        )
    }

    /// Resolve a token without ever storing one in the repo.
    ///
    /// Order: explicit argument, `GITHUB_TOKEN`, the keychain, then the already-authenticated
    /// `gh` CLI. The environment beats the keychain deliberately, so a one-off
    /// `GITHUB_TOKEN=... opencore sync github` overrides a saved token without having to
    /// change the saved one.
    ///
    /// The keychain entry is what makes the **app** work. Launched from Finder it inherits no
    /// shell environment, and a sandboxed or differently-pathed process may not find `gh`
    /// either, so before this the app had no way to authenticate at all.
    public static func resolveToken(explicit: String? = nil) -> String? {
        resolveTokenWithSource(explicit: explicit).token
    }

    /// The same resolution, reporting which source won.
    ///
    /// The UI shows this. Four sources with a precedence order and no way to see which one is
    /// in effect makes "why is it still using the old token" unanswerable.
    public static func resolveTokenWithSource(explicit: String? = nil) -> (token: String?, source: CredentialSource) {
        if let explicit, !explicit.isEmpty { return (explicit, .explicit) }
        if let fromEnvironment = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !fromEnvironment.isEmpty {
            return (fromEnvironment, .environment)
        }
        switch Keychain.readResult(.githubToken) {
        case .found(let token, source: .keychain): return (token, .keychain)
        case .found(let token, source: .legacyVault): return (token, .legacyVault)
        case .authenticationRequired: return (nil, .authenticationRequired)
        case .failed: return (nil, .storageError)
        case .missing: break
        }
        if let fromCLI = ghCLIToken() { return (fromCLI, .ghCLI) }
        return (nil, .none)
    }

    /// Ask GitHub who a token belongs to. Used to confirm a saved token actually works, so the
    /// Settings screen can say "authenticated as X" rather than "saved" — saved and valid are
    /// different facts and only one of them is useful.
    public static func verify(token: String) async -> String? {
        struct User: Decodable { let login: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(User.self, from: data))?.login
    }

    private static let ghCache = GitHubCLITokenCache()

    /// Explicit refresh/sign-in actions should invalidate immediately. Automatic lookups
    /// expire success after 30 seconds and absence after 2 seconds, chosen to avoid repeated
    /// subprocesses during tab rendering while still observing login and token rotation.
    public static func invalidateTokenCache() {
        ghCache.invalidate()
    }

    private static func ghCLIToken() -> String? {
        ghCache.resolve(clock: { ProcessInfo.processInfo.systemUptime }) {
            loadGHCLIToken()
        }
    }

    private static func loadGHCLIToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/env"]
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let arguments = candidate == "/usr/bin/env" ? ["gh", "auth", "token"] : ["auth", "token"]
            var environment = ProcessInfo.processInfo.environment
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            do {
                let result = try BoundedProcess.run(
                    executable: candidate, arguments: arguments, environment: environment,
                    timeout: 5, maximumOutputBytes: 8_192
                )
                // A hanging executable should not be retried through another path to the
                // same gh process. The shared runner drains pipes and forcibly reaps it.
                guard !result.timedOut else { return nil }
                guard result.status == 0 else { continue }
                let token = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Fetch

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        var objects: [CoreObject] = []

        let repositories = try await allRepositories(log: log)
        log("found \(repositories.count) repositories")

        for repository in repositories {
            if repository.fork && !includeForks { continue }

            objects.append(repositoryObject(repository))

            // Languages: structured, authoritative, and the cleanest claim source there is.
            if let languages = try? await languages(for: repository.fullName), !languages.isEmpty {
                objects.append(languagesObject(repository, languages: languages))
            }

            // README: the repo's own description of itself. Deliberately a separate object
            // from the code, because a README claiming something the code does not do is
            // exactly the contradiction this system exists to catch.
            if let readme = try? await readme(for: repository.fullName), !readme.isEmpty {
                objects.append(readmeObject(repository, markdown: readme))
            }

            let commits = try await commits(for: repository.fullName, since: since, log: log)
            log("\(repository.fullName): \(commits.count) commits")
            objects.append(contentsOf: commits.map { commitObject($0, repository: repository) })
        }

        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
    }

    // MARK: - Object construction

    private func repositoryObject(_ repository: Repository) -> CoreObject {
        var text = "\(repository.fullName)\n"
        if let description = repository.description { text += "\(description)\n" }
        if let language = repository.language { text += "Primary language: \(language)\n" }
        if !repository.topics.isEmpty { text += "Topics: \(repository.topics.joined(separator: ", "))\n" }
        text += "Stars: \(repository.stargazersCount). Created \(repository.createdAt?.description ?? "unknown"). "
        text += "Last pushed \(repository.pushedAt?.description ?? "unknown")."

        var metadata: [String: String] = [
            "stars": String(repository.stargazersCount),
            "archived": String(repository.archived),
            "visibility": repository.visibility,
        ]
        if let language = repository.language { metadata["language"] = language }
        if let pushedAt = repository.pushedAt { metadata["pushed_at"] = ISO8601DateFormatter().string(from: pushedAt) }
        if !repository.topics.isEmpty { metadata["topics"] = repository.topics.joined(separator: ",") }

        return CoreObject(
            sourceID: source.id,
            kind: .repository,
            externalID: repository.fullName,
            title: repository.name,
            text: text,
            uri: repository.htmlURL,
            authoredAt: repository.createdAt,
            domain: repository.isPrivate ? .project : .publicRecord,
            authority: .authoredArtifact,
            metadata: metadata
        )
    }

    private func languagesObject(_ repository: Repository, languages: [String: Int]) -> CoreObject {
        let ordered = languages.sorted { $0.value > $1.value }
        let total = max(1, ordered.reduce(0) { $0 + $1.value })
        let breakdown = ordered
            .map { "\($0.key): \($0.value) bytes (\(Int(Double($0.value) / Double(total) * 100))%)" }
            .joined(separator: "\n")

        return CoreObject(
            sourceID: source.id,
            kind: .file,
            externalID: "\(repository.fullName)#languages",
            title: "\(repository.name) — language breakdown",
            text: "Language composition of \(repository.fullName), by bytes:\n\(breakdown)",
            uri: repository.htmlURL,
            authoredAt: repository.pushedAt,
            domain: repository.isPrivate ? .project : .publicRecord,
            // Measured by GitHub from the actual file contents. Structured fact, not prose.
            authority: .authoredArtifact,
            metadata: ordered.reduce(into: ["repo": repository.fullName]) { $0["lang_" + $1.key] = String($1.value) }
        )
    }

    private func readmeObject(_ repository: Repository, markdown: String) -> CoreObject {
        CoreObject(
            sourceID: source.id,
            kind: .document,
            externalID: "\(repository.fullName)#readme",
            title: "\(repository.name) — README",
            text: markdown,
            uri: "\(repository.htmlURL)#readme",
            authoredAt: repository.pushedAt,
            domain: repository.isPrivate ? .project : .publicRecord,
            authority: .authoredArtifact,
            metadata: ["repo": repository.fullName]
        )
    }

    private func commitObject(_ commit: Commit, repository: Repository) -> CoreObject {
        let message = commit.commit.message
        let subject = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message

        return CoreObject(
            sourceID: source.id,
            kind: .commit,
            externalID: "\(repository.fullName)@\(commit.sha)",
            title: subject,
            text: "\(repository.fullName)\n\(message)",
            uri: commit.htmlURL,
            authoredAt: commit.commit.author?.date,
            domain: repository.isPrivate ? .project : .publicRecord,
            authority: .authoredArtifact,
            metadata: [
                "repo": repository.fullName,
                "sha": commit.sha,
                "author": commit.commit.author?.name ?? "unknown",
            ]
        )
    }

    // MARK: - API

    private func allRepositories(log: @Sendable (String) -> Void) async throws -> [Repository] {
        var page = 1
        var all: [Repository] = []
        while true {
            let batch: [Repository] = try await get("/user/repos?per_page=100&affiliation=owner&sort=pushed&page=\(page)")
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
            if page > 20 { log("stopping at 2000 repositories"); break }
        }
        return all
    }

    private func languages(for fullName: String) async throws -> [String: Int] {
        try await get("/repos/\(fullName)/languages")
    }

    private func readme(for fullName: String) async throws -> String? {
        struct ReadmeResponse: Decodable {
            let content: String
            let encoding: String
        }
        let response: ReadmeResponse = try await get("/repos/\(fullName)/readme")
        guard response.encoding == "base64" else { return nil }
        let cleaned = response.content.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func commits(for fullName: String, since: Date?, log: @Sendable (String) -> Void) async throws -> [Commit] {
        var all: [Commit] = []
        var page = 1
        let perPage = min(100, commitsPerRepo)

        while all.count < commitsPerRepo {
            var path = "/repos/\(fullName)/commits?per_page=\(perPage)&page=\(page)"
            if let since { path += "&since=\(ISO8601DateFormatter().string(from: since))" }

            let batch: [Commit]
            do {
                batch = try await get(path)
            } catch ConnectorError.http(let status, _) where status == 409 {
                // Empty repository. Normal, not an error worth surfacing.
                return []
            }
            all.append(contentsOf: batch)
            if batch.count < perPage { break }
            page += 1
        }
        return Array(all.prefix(commitsPerRepo))
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.decode("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConnectorError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ConnectorError.decode("\(error) for \(path)")
        }
    }
}

// MARK: - Wire types

extension GitHubConnector {
    struct Repository: Decodable, Sendable {
        let name: String
        let fullName: String
        let description: String?
        let language: String?
        let htmlURL: String
        let stargazersCount: Int
        let fork: Bool
        let archived: Bool
        let isPrivate: Bool
        let visibility: String
        let topics: [String]
        let createdAt: Date?
        let pushedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case name, description, language, fork, archived, visibility, topics
            case fullName, stargazersCount, createdAt, pushedAt
            case htmlURL = "htmlUrl"
            case isPrivate = "private"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            fullName = try container.decode(String.self, forKey: .fullName)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL) ?? ""
            stargazersCount = try container.decodeIfPresent(Int.self, forKey: .stargazersCount) ?? 0
            fork = try container.decodeIfPresent(Bool.self, forKey: .fork) ?? false
            archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
            isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
            visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "public"
            topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            pushedAt = try container.decodeIfPresent(Date.self, forKey: .pushedAt)
        }
    }

    struct Commit: Decodable, Sendable {
        let sha: String
        let htmlURL: String
        let commit: CommitDetail

        private enum CodingKeys: String, CodingKey {
            case sha, commit
            case htmlURL = "htmlUrl"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sha = try container.decode(String.self, forKey: .sha)
            htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL) ?? ""
            commit = try container.decode(CommitDetail.self, forKey: .commit)
        }
    }

    struct CommitDetail: Decodable, Sendable {
        let message: String
        let author: CommitAuthor?
    }

    struct CommitAuthor: Decodable, Sendable {
        let name: String?
        let email: String?
        let date: Date?
    }
}

/// The previous cache remembered both nil and successful tokens for the process lifetime,
/// so a login or rotation in another terminal never reached an already running app.
final class GitHubCLITokenCache: Sendable {
    private struct Entry: Sendable {
        let checkedAt: TimeInterval
        let token: String?
    }

    private let entry = Mutex<Entry?>(nil)
    private let successLifetime: TimeInterval
    private let missingLifetime: TimeInterval

    init(successLifetime: TimeInterval = 30, missingLifetime: TimeInterval = 2) {
        self.successLifetime = successLifetime
        self.missingLifetime = missingLifetime
    }

    func resolve(at now: TimeInterval, load: () -> String?) -> String? {
        resolve(clock: { now }, load: load)
    }

    func resolve(clock: () -> TimeInterval, load: () -> String?) -> String? {
        entry.withLock { cached in
            let now = clock()
            if let cached {
                let age = now - cached.checkedAt
                let lifetime = cached.token == nil ? missingLifetime : successLifetime
                if age >= 0 && age < lifetime { return cached.token }
            }
            let loaded = load()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = loaded.flatMap { $0.isEmpty ? nil : $0 }
            // A slow or timed-out gh lookup must still receive the full absence lifetime;
            // starting it before the subprocess would immediately expire a slow failure.
            cached = Entry(checkedAt: clock(), token: token)
            return token
        }
    }

    func invalidate() {
        entry.withLock { $0 = nil }
    }
}
