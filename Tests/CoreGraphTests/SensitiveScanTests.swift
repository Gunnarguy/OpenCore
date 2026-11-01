import Foundation
import Testing

/// Runs the real script against a throwaway repository, so a hit proves the whole path works and
/// not only a regular expression. Every term here is made up.
private struct ScanFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-scan-\(UUID().uuidString)", isDirectory: true)
        let scripts = root.appendingPathComponent("script", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Local"), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("script")
        for name in ["check_sensitive.sh", "check_sensitive.py"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: scripts.appendingPathComponent(name))
        }
        try write(".gitignore", "/Local/\n")
        try write("Local/sensitive-terms.txt", "# a comment\nquokkaland\nzorp\n")
        try git("init", "-q")
        try commit("start")
    }

    func write(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    func git(_ arguments: String...) throws -> (status: Int32, output: String) {
        try run("/usr/bin/git", arguments)
    }

    func commit(_ message: String, author: String = "Example <example@example.invalid>") throws {
        try git("add", "-A")
        try git("-c", "user.name=Example", "-c", "user.email=example@example.invalid", "commit", "-q", "--allow-empty", "--author", author, "-m", message)
    }

    func scan(_ arguments: String...) throws -> (status: Int32, output: String) {
        try run("/bin/bash", ["script/check_sensitive.sh"] + arguments)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

// One at a time. Each case starts git and python several times, and alongside the rest of this
// binary that load made a two-second transport timeout in `stdioFramingPreservesPayload` fail once.
@Suite("Sensitive scan", .serialized)
struct SensitiveScanTests {
    @Test("a clean repository passes and says so")
    func scanCleanRepository() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        let result = try repo.scan()
        #expect(result.status == 0)
        #expect(result.output.contains("clean"))
    }

    // The original failure: the pattern ended in `[^"]`, which needs a character after the closing
    // dashes. `git grep` matches a line at a time and a real header ends at the newline, so a real
    // private key did not match.
    @Test("a real private key header is found")
    func scanFindsPrivateKeyHeader() throws {
        // Assembled here, or this file would be a hit in the real repository's own scan.
        for kind in ["", "OPENSSH ", "RSA "] {
            let repo = try ScanFixture(); defer { repo.remove() }
            try repo.write("notes.txt", "-----BEGIN \(kind)PRIVATE " + "KEY-----\nMIIEvQ\n")
            #expect(try repo.scan().status == 1)
        }
    }

    // The original failure: `git grep -w` treats `_` and letters as word characters, so a term inside an
    // identifier or a path passed.
    @Test("a term inside an identifier or a path is found")
    func scanFindsTermsInsideIdentifiers() throws {
        for line in ["let quokkalandFoo = 1", "quokkaland_x", "src/myquokkaland/file", "QuokkaLandThing", "zorpTool", "ZORPProfile", "let a_zorp = 1", "aZorp"] {
            let repo = try ScanFixture(); defer { repo.remove() }
            try repo.write("code.txt", "\(line)\n")
            #expect(try repo.scan().status == 1, "\(line)")
        }
    }

    // The other side: this is what a boundary is for. A short term anywhere would fire on ordinary words.
    @Test("a short term inside an ordinary word is not a hit")
    func scanLeavesOrdinaryWordsAlone() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        try repo.write("code.txt", "seazorpion azorpb\n")
        #expect(try repo.scan().status == 0)
    }

    // The original failure: only file contents were searched.
    @Test("a term in a file name is found")
    func scanFindsFileNames() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        try repo.write("Docs/quokkaland-notes.txt", "nothing here\n")
        let result = try repo.scan()
        #expect(result.status == 1)
        #expect(result.output.contains("file name"))
    }

    // The original failure: the terms file omitted most of the private names file, so the scan could
    // pass with those names in the tree.
    @Test("every name in the private file is a term, and a name already public is not")
    func scanDerivesTermsFromPrivateNames() throws {
        let names = """
        {"repositories":{"project":["example-tool"],"medical":["example-health"],"personal":["example-garden"]},
         "operatorRepositories":[{"name":"ExampleOperator","relativePath":"Documents/ExampleFolder","summary":"s"},{"name":"USB","relativePath":"Documents/USB","summary":"s"}],
         "rolloutKeywords":{"example-keyed":["example_keyword"]},
         "peers":[{"alias":"example-host","role":"r"}],
         "nestedRepositories":[{"name":"example-nested","relativePath":"Documents/example-tool/example-subfolder"}],
         "localAutomation":{"hubIdentity":"example-identity","profilesRelativePath":"Documents/example-profiles"}}
        """
        for term in ["example-tool", "example-health", "example-garden", "ExampleOperator", "ExampleFolder", "example-keyed", "example_keyword", "example-host", "example-nested", "example-subfolder", "example-identity", "example-profiles"] {
            let repo = try ScanFixture(); defer { repo.remove() }
            try repo.write("Local/private-names.json", names)
            try repo.write("notes.txt", "see \(term) here\n")
            #expect(try repo.scan().status == 1, "\(term)")
        }

        // Three letters is an ordinary word.
        let short = try ScanFixture(); defer { short.remove() }
        try short.write("Local/private-names.json", names)
        try short.write("notes.txt", "a USB cable\n")
        #expect(try short.scan().status == 0)

        // What origin/main already holds is public, and the terms file always applies.
        let carried = try ScanFixture(); defer { carried.remove() }
        try carried.write("Local/private-names.json", names)
        try carried.write("notes.txt", "see example-tool here\n")
        try carried.commit("public")
        try carried.git("update-ref", "refs/remotes/origin/main", "HEAD")
        #expect(try carried.scan().status == 0)
        try carried.write("Local/sensitive-terms.txt", "example-tool\n")
        #expect(try carried.scan().status == 1)
    }

    // A check that can't read its own list must not look like a pass.
    @Test("a private file that can't be parsed stops the scan")
    func scanRefusesUnreadableNames() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        try repo.write("Local/private-names.json", "not json")
        #expect(try repo.scan().status == 2)
    }

    // The original failure: `--history` searched trees only, so its "no commit contains a term" said
    // more than it checked.
    @Test("history looks at messages, author fields and file names as well as contents")
    func scanHistoryLooksEverywhere() throws {
        func history(_ change: (ScanFixture) throws -> Void) throws -> (status: Int32, output: String) {
            let repo = try ScanFixture(); defer { repo.remove() }
            try repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
            try change(repo)
            return try repo.scan("--history")
        }
        #expect(try history { try $0.commit("an ordinary change") }.status == 0)
        let message = try history { try $0.commit("fix the quokkaland import") }
        #expect(message.status == 1)
        #expect(message.output.contains("commit message"))
        let author = try history { try $0.commit("an ordinary change", author: "Quokkaland Staff <staff@example.invalid>") }
        #expect(author.status == 1)
        #expect(author.output.contains("commit author"))
        let name = try history { repo in
            try repo.write("quokkaland.txt", "nothing\n")
            try repo.commit("an ordinary change")
        }
        #expect(name.status == 1)
        #expect(name.output.contains("file name"))
        let contents = try history { repo in
            try repo.write("notes.txt", "quokkaland\n")
            try repo.commit("an ordinary change")
        }
        #expect(contents.status == 1)
        #expect(contents.output.contains("notes.txt"))
    }

    // The original failure: `2>/dev/null` on `git grep` turned a failed scan into a clean one.
    @Test("a scan git could not run is not clean")
    func scanFailureIsNotClean() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        #expect(try repo.scan("--history", "no-such-ref..HEAD").status == 2)

        try repo.write("notes.txt", "quokkaland\n")
        try repo.git("add", "-A")
        try Data("not an index".utf8).write(to: repo.root.appendingPathComponent(".git/index"))
        let result = try repo.scan()
        #expect(result.status == 2)
        #expect(!result.output.contains("clean"))
    }

    // The original failure: the documented format was `path:line-text` but the filter compared it to
    // `path:N:text`, so an entry written as documented filtered nothing.
    @Test("an allow entry in the documented format filters that hit and no other")
    func scanAllowFormat() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        try repo.write("a.txt", "the quokkaland vendor table\n")
        try repo.write("b.txt", "the quokkaland vendor table\n")
        try repo.write("Local/sensitive-allow.txt", "# false positive\na.txt:quokkaland vendor\n")
        let result = try repo.scan()
        #expect(result.status == 1)
        #expect(result.output.contains("b.txt"))
        #expect(!result.output.contains("a.txt"))
    }

    @Test("the working tree scan reads what is staged, and a fix waiting to be staged is not a hit")
    func scanStagedScopes() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        try repo.write("notes.txt", "quokkaland\n")
        try repo.commit("adds a term")
        // Fixed in the working tree, still in the index: the next commit would still hold it.
        try repo.write("notes.txt", "fixed\n")
        #expect(try repo.scan().status == 0)
        #expect(try repo.scan("--staged").status == 1)

        try repo.git("add", "-A")
        #expect(try repo.scan("--staged").status == 0)

        // Staged, then removed from the working tree: only the index still holds it.
        try repo.write("other.txt", "quokkaland\n")
        try repo.git("add", "-A")
        try repo.write("other.txt", "fixed\n")
        #expect(try repo.scan().status == 1)
    }

    // Before the fix the whole line was dropped when any path on it was an allowed one.
    @Test("a real home path beside an example one is still found")
    func scanHomePaths() throws {
        let repo = try ScanFixture(); defer { repo.remove() }
        try repo.write("clean.txt", "/Users/example/Documents and /Users/test/x/\n")
        #expect(try repo.scan().status == 0)
        // Assembled here, or this file would be a hit in the real repository's own scan.
        try repo.write("notes.txt", "/Users/example/a and " + "/Users" + "/somebody/b\n")
        #expect(try repo.scan().status == 1)
    }
}
