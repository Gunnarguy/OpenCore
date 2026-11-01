import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreGraph
@testable import CoreIngest

private let complete = LocalPrivateNames(repositories: .init(project: ["example-tool"], medical: ["example-health"], personal: []))

private func fixtureHome(_ files: [String]) throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-names-\(UUID().uuidString)", isDirectory: true)
    for file in files {
        let url = home.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Fixture\n\nStatus: active\n".utf8).write(to: url)
    }
    return home
}

private func memory(_ slug: String) -> String { ".claude/projects/\(slug)/memory/MEMORY.md" }

private func classify(_ relative: String, _ names: LocalPrivateNames) -> AgentMemoryPolicy.Classification? {
    let home = URL(fileURLWithPath: "/tmp/opencore-policy-fixture")
    return AgentMemoryPolicy.classification(for: home.appendingPathComponent(relative), home: home, names: names)
}

// Why these are not `.restricted`: `Store.retainedImportDomain` never lowers that domain, so a file
// that went missing, was malformed or lost a list pinned every repository the binary can't name, on
// the next sync, with its claims and events, and `dropDerivedLayers` then refused to run.
@Test("an unavailable list leaves unknown repositories out rather than classifying them")
func unavailableListWithholds() throws {
    let private_ = "Documents/GitHub/example-tool/CLAUDE.md"
    let slug = memory("-Users-example-Documents-GitHub-example-tool")
    let incomplete = LocalPrivateNames(repositories: .init(project: ["other"], medical: [], personal: [], isComplete: false))
    for names in [LocalPrivateNames.empty, incomplete] {
        #expect(classify(private_, names) == nil)
        #expect(classify(slug, names) == nil)
        #expect(classify("Documents/GitHub/OpenCore/CLAUDE.md", names)?.domain == .project)
        #expect(classify(memory("-Users-example-Documents-GitHub-OpenClinic"), names)?.domain == .medical)
    }
    // A complete list is an answer, and a name it leaves out really is unknown.
    #expect(classify(private_, complete)?.domain == .project)
    #expect(classify(slug, complete)?.domain == .project)
    #expect(classify("Documents/GitHub/some-other-repo/CLAUDE.md", complete)?.domain == .restricted)
    #expect(classify(memory("-Users-example-Documents-GitHub-some-other-repo"), complete)?.domain == .restricted)
    // Scratch folders and the home folder are no repository, so no list changes them.
    #expect(classify(memory("-private-tmp-OpenCore"), .empty)?.domain == .restricted)
    #expect(classify(memory("-Users-example"), .empty)?.domain == .restricted)
}

@Test("repository and memory roots follow the same rule as a single path")
func rootsWithhold() throws {
    let home = try fixtureHome([
        "Documents/GitHub/OpenCore/CLAUDE.md", "Documents/GitHub/example-tool/CLAUDE.md",
        memory("-Users-example-Documents-GitHub-example-tool"),
    ])
    defer { try? FileManager.default.removeItem(at: home) }
    func paths(_ roots: [FilesystemConnector.Root]) -> [String] { roots.map(\.url.path) }

    let without = paths(AgentMemoryPolicy.repositoryRoots(home: home, names: .empty) + AgentMemoryPolicy.discoverRoots(home: home, names: .empty))
    #expect(without.contains { $0.contains("GitHub/OpenCore") })
    #expect(!without.contains { $0.contains("example-tool") })

    let with = paths(AgentMemoryPolicy.repositoryRoots(home: home, names: complete) + AgentMemoryPolicy.discoverRoots(home: home, names: complete))
    #expect(with.filter { $0.contains("example-tool") }.count == 2)
}

// The original failure, end to end: objects stored while the list was present, then a sync and a
// repair with it gone. Before the fix the root came back `.restricted` and the object stayed there.
@Test("one sync with the list gone changes nothing that is stored")
func missingListDoesNotPinStoredObjects() async throws {
    let home = try fixtureHome(["Documents/GitHub/example-tool/CLAUDE.md", "Documents/GitHub/OpenCore/CLAUDE.md"])
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try await Store.open(at: home.appendingPathComponent("store/opencore.sqlite3"))

    func sync(_ names: LocalPrivateNames) async throws {
        let connector = FilesystemConnector(handle: "Cross-Agent-Memory", roots: AgentMemoryPolicy.repositoryRoots(home: home, names: names))
        try await store.upsert(connector.source)
        _ = try await IngestPipeline(store: store).run(objects: try await connector.fetch(since: nil, cursor: nil) { _ in }.objects)
    }
    func repair(_ names: LocalPrivateNames) async throws {
        let repairs = try await store.allObjects().compactMap { object -> Store.ObjectPolicyRepair? in
            guard let policy = AgentMemoryPolicy.classification(for: URL(fileURLWithPath: object.externalID), home: home, names: names) else { return nil }
            return Store.ObjectPolicyRepair(objectID: object.id, domain: policy.domain, authority: policy.authority, reason: "fixture")
        }
        _ = try await store.reclassifyObjects(repairs, dryRun: false)
    }
    func anchor() async throws -> CoreObject {
        try #require(try await store.allObjects().first { $0.externalID.contains("example-tool") })
    }

    try await sync(complete)
    #expect(try await anchor().domain == .project)

    try await sync(.empty)
    try await repair(.empty)
    let after = try await anchor()
    #expect(after.domain == .project)
    #expect(after.metadata["classification_requires_rebuild"] == nil)

    // The door is real: a complete list that no longer names it does restrict it, and that sticks.
    try await sync(LocalPrivateNames(repositories: .init(project: [], medical: [], personal: [])))
    #expect(try await anchor().domain == .restricted)
    try await sync(complete)
    #expect(try await anchor().domain == .restricted)
}

// The bug: withholding kept a repository's stored objects as they were, and the scheduled sync it
// was left out of still moved the source's date. The list came back, and that repository's documents
// older than the date were skipped by `modified < since` until someone edited them.
@Test("documents withheld while the list was gone arrive when it returns")
func withheldDocumentsArriveLater() async throws {
    let home = try fixtureHome(["Documents/GitHub/OpenCore/CLAUDE.md", "Documents/GitHub/example-tool/CLAUDE.md"])
    defer { try? FileManager.default.removeItem(at: home) }
    let old = Date().addingTimeInterval(-30 * 86_400)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("Documents/GitHub/example-tool/CLAUDE.md").path)
    let store = try await Store.open(at: home.appendingPathComponent("store/opencore.sqlite3"))

    func sync(_ names: LocalPrivateNames) async throws -> SourceSync.Report {
        let found = AgentMemoryPolicy.discoverRepositories(home: home, names: names)
        let connector = FilesystemConnector(handle: "GitHub-Workspace", roots: found.roots, knownUnread: found.unread)
        try await store.upsert(connector.source)
        return try await SourceSync(store: store, pipeline: IngestPipeline(store: store)).run(connector.source.id, fetch: { since in
            try await connector.fetch(since: since, cursor: nil) { _ in }
        })
    }

    let without = try await sync(.empty)
    #expect(!without.advanced)
    #expect(without.read == 1, "what the binary can name still syncs")
    #expect(try await store.allObjects().allSatisfy { !$0.externalID.contains("example-tool") })

    let with = try await sync(complete)
    #expect(with.advanced)
    #expect(try await store.allObjects().contains { $0.externalID.contains("example-tool") })
}

@Test("a walk counts what it withheld, and a complete list withholds nothing")
func discoveryCountsWithheld() throws {
    let home = try fixtureHome([
        "Documents/GitHub/OpenCore/CLAUDE.md", "Documents/GitHub/example-tool/CLAUDE.md",
        "Documents/GitHub/example-tool/not-an-anchor.md",
        memory("-Users-example-Documents-GitHub-example-tool"),
    ])
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(AgentMemoryPolicy.discoverRepositories(home: home, names: .empty).withheld == 1)
    #expect(AgentMemoryPolicy.discoverMemories(home: home, names: .empty).withheld == 1)
    #expect(AgentMemoryPolicy.discoverRepositories(home: home, names: complete).withheld == 0)
    #expect(AgentMemoryPolicy.discoverMemories(home: home, names: complete).withheld == 0)
    #expect(AgentMemoryPolicy.discoverRepositories(home: home, names: complete).unread.isEmpty)
}

// The original failure: `Repositories`, `Peer` and `OperatorRepository` had synthesized `Decodable`,
// so one absent key threw, the whole file became `.empty`, and nothing said so.
@Test("a partial file keeps what it states, and says the lists are not complete")
func partialFilesLoad() throws {
    func decode(_ json: String) throws -> LocalPrivateNames {
        try JSONDecoder().decode(LocalPrivateNames.self, from: Data(json.utf8))
    }
    let oneList = try decode(#"{"repositories":{"medical":["Example-Health"]},"peers":[{"alias":"example-host","role":"helper"}]}"#)
    #expect(oneList.repositories.medical == ["example-health"])
    #expect(!oneList.repositories.isComplete)
    #expect(oneList.peers.count == 1)

    let badEntries = try decode(#"{"peers":[{"alias":"no-role"},{"alias":"example-host","role":"helper"}],"operatorRepositories":[{"name":"no-path"},{"name":"Example","relativePath":"a/b","summary":"c"}],"nestedRepositories":[{"name":"no-path"}]}"#)
    #expect(badEntries.peers.map(\.alias) == ["example-host"])
    #expect(badEntries.operatorRepositories.map(\.name) == ["Example"])
    #expect(badEntries.nestedRepositories.isEmpty)

    let wrongType = try decode(#"{"repositories":{"project":"not-a-list","medical":[],"personal":[]},"rolloutKeywords":7,"peers":[{"alias":"example-host","role":"helper"}]}"#)
    #expect(wrongType.repositories == .unavailable)
    #expect(wrongType.peers.count == 1)

    let allThree = try decode(#"{"repositories":{"project":[],"medical":[],"personal":[]}}"#)
    #expect(allThree.repositories.isComplete)
}

@Test("reading the file reports what went wrong, and a complete file reports nothing")
func loadProblems() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-names-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func problem(_ contents: String) throws -> LocalPrivateNames.LoadProblem? {
        let url = folder.appendingPathComponent("\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return LocalPrivateNames.read(from: url).problem
    }
    #expect(LocalPrivateNames.read(from: folder.appendingPathComponent("absent.json")).problem == .missing)
    #expect(try problem("not json") == .unreadable)
    #expect(try problem("[1,2]") == .unreadable)
    #expect(try problem(#"{"peers":[]}"#) == .incomplete)
    #expect(try problem(#"{"repositories":{"project":[],"medical":[]}}"#) == .incomplete)
    #expect(try problem(#"{"repositories":{"project":[],"medical":[],"personal":[]}}"#) == nil)
}

// The original failure: `hasSuffix("-" + name)` had no boundary. A slug flattens `/` and `-`, so an
// unknown repository and a subfolder of a medical repository both read as `.project`.
@Test("a slug names a repository only when the name is all that follows a container")
func slugBoundaries() {
    func domain(_ slug: String) -> Domain? { classify(memory(slug), complete)?.domain }
    #expect(domain("-Users-example-Documents-GitHub-OpenCore") == .project)
    #expect(domain("-Users-example-Documents-Projects-example-tool") == .project)
    #expect(domain("-Users-example-Documents-GitHub-OpenClinic") == .medical)
    #expect(domain("-Users-example-Claude-Projects-example-health") == .medical)
    #expect(domain("-Applications-example-tool") == .project)

    #expect(domain("-Users-example-Documents-GitHub-foo-opencore") == .restricted)
    #expect(domain("-Users-example-Documents-GitHub-OpenClinic-opencore") == .restricted)
    #expect(domain("-Users-example-Documents-GitHub-example-health-example-tool") == .restricted)
    #expect(domain("-Users-example-Documents-OpenCore") == .restricted)
    #expect(domain("-Users-example-Other-Documents-GitHub-OpenCore") == .restricted)
}

// The original failure: this repository's name and path were compiled in. It belongs to the file.
@Test("a nested repository comes from the file, and without it the path is nothing")
func nestedRepositories() throws {
    let path = "Documents/GitHub/example-tool/apps/Example-Mobile"
    let names = LocalPrivateNames(
        repositories: .init(project: ["example-tool"], medical: [], personal: ["example-mobile"]),
        nestedRepositories: [.init(name: "Example-Mobile", relativePath: path)]
    )
    #expect(classify("\(path)/CLAUDE.md", names)?.domain == .personal)
    #expect(classify(memory("-Users-example-Documents-GitHub-example-tool-apps-Example-Mobile"), names)?.domain == .personal)
    #expect(classify("\(path)/CLAUDE.md", complete) == nil)
    #expect(classify(memory("-Users-example-Documents-GitHub-example-tool-apps-Example-Mobile"), complete)?.domain == .restricted)

    let home = try fixtureHome(["\(path)/CLAUDE.md"])
    defer { try? FileManager.default.removeItem(at: home) }
    let root = try #require(AgentMemoryPolicy.repositoryRoots(home: home, names: names).first)
    #expect(root.url.path.hasSuffix("Example-Mobile/CLAUDE.md"))
    #expect(root.domain == .personal)
}

// The original failure: this branch compared the slug to `NSUserName()`, so re-deriving the same
// objects under another account mapped them differently, and no test reached it because the fixtures
// all returned earlier. The two account names here are never the one running the tests.
@Test("a memory path names the same project under any account")
func memoryProjectNameIgnoresTheAccount() {
    func name(_ slug: String) -> String? {
        ClaimExtractor.claudeMemoryProjectName(from: "/Users/example/.claude/projects/\(slug)/memory/MEMORY.md")
    }
    for account in ["someone", "another"] {
        #expect(name("-Users-\(account)") == "Machine-Global")
        #expect(name("-Users-\(account)-Tools") == "Tools")
        #expect(name("-Users-\(account)-Tools-nested") == nil)
        #expect(name("-Users-\(account)-Documents-GitHub-Example-Repo") == "Example-Repo")
        #expect(name("-Users-\(account)-Claude-Projects-Example") == "Example")
    }
    #expect(name("-Applications-Example-Game") == "Example-Game")
    #expect(name("-private-tmp-Example") == nil)
}

@Test("an account folder is never inferred as a project")
func accountFolderIsNotAProject() {
    func subject(_ path: String) -> String? {
        let source = SourceID("fixture")
        let object = CoreObject(sourceID: source, kind: .file, externalID: path, title: "README.md", text: "Status: active\n", authoredAt: nil, domain: .project, authority: .authoredArtifact, metadata: [:])
        return ClaimExtractor.structuredDocumentExtraction(from: object)?.subject.canonicalName
    }
    #expect(subject("/Users/example/README.md") == nil)
    #expect(subject("/Users/tester/README.md") == nil)
    #expect(subject("/Users/example/Tools/README.md") == "Tools")
}
