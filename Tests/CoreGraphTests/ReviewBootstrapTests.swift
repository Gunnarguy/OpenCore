import CoreModel
import CoreStore
import CoreTelemetry
import Foundation
import Testing

private func reviewFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-policy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}
private func admit(_ path: URL, root: URL, id: String? = ReviewSnapshotPolicy.bundleIdentifier) throws -> URL {
    try ReviewSnapshotPolicy.snapshot(arguments: ["--review-store", path.path], bundleID: id, root: root)
}

// A review flag on the production entry point would already construct production singletons.
// This independent gate requires the separate identity and explicit copy, with no default path.
@Test("review bootstrap refuses production identity and incomplete launch arguments")
func reviewRequiresIdentityAndCopy() throws {
    let root = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("store.sqlite3")
    try Data("fixture".utf8).write(to: path)
    #expect(try admit(path, root: root) == path.resolvingSymlinksInPath())
    for identity in [nil, "com.gunndamental.OpenCore", "other.review"] {
        #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(path, root: root, id: identity) }
    }
    for args in [[], ["--review-store"], ["--review-store", "relative.sqlite3"], ["--review-store", path.path, "extra"], ["--db", path.path]] {
        #expect(throws: ReviewSnapshotPolicy.Refusal.self) {
            _ = try ReviewSnapshotPolicy.snapshot(arguments: args, bundleID: ReviewSnapshotPolicy.bundleIdentifier, root: root)
        }
    }
}

@Test("review snapshots require a private root and an existing regular file")
func reviewRequiresPrivateExistingCopy() throws {
    let root = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("store.sqlite3")
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(path, root: root) }
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(root, root: root) }
    try Data("fixture".utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(path, root: root) }
}

// These aliases can accidentally open the real store while calling the input a copy.
@Test("review bootstrap rejects path-prefix lookalikes, symlinks and hard links")
func reviewRejectsAliasedCopies() throws {
    let root = try reviewFixtureRoot(), outside = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let original = outside.appendingPathComponent("store.sqlite3")
    try Data("fixture".utf8).write(to: original)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(original, root: root) }
    let symlink = root.appendingPathComponent("linked.sqlite3")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(symlink, root: root) }
    let hardlink = root.appendingPathComponent("hard.sqlite3")
    try FileManager.default.linkItem(at: original, to: hardlink)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(hardlink, root: root) }
    let ordinary = root.appendingPathComponent("ordinary.sqlite3")
    try Data("fixture".utf8).write(to: ordinary)
    let insideAlias = root.appendingPathComponent("inside-alias.sqlite3")
    try FileManager.default.createSymbolicLink(at: insideAlias, withDestinationURL: ordinary)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(insideAlias, root: root) }
    let rootLink = outside.appendingPathComponent("root-link")
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(rootLink.appendingPathComponent("ordinary.sqlite3"), root: rootLink) }
    let sibling = URL(fileURLWithPath: root.path + "-lookalike", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sibling) }
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let siblingCopy = sibling.appendingPathComponent("store.sqlite3")
    try Data("fixture".utf8).write(to: siblingCopy)
    #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(siblingCopy, root: root) }
}

@Test("review opens a fixture read-only and rejects a store mutation")
func reviewCopyCannotMutate() async throws {
    let root = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("store.sqlite3")
    let writer = try await Store.open(at: root.appendingPathComponent("source.sqlite3"))
    let source = Source(kind: .manual, handle: "review-fixture", displayName: "Review fixture", defaultAuthority: .authoredArtifact, defaultDomain: .personal)
    try await writer.upsert(source)
    let originalPath = root.appendingPathComponent("source.sqlite3")
    let originalMain = try Data(contentsOf: originalPath)
    let originalWAL = try Data(contentsOf: URL(fileURLWithPath: originalPath.path + "-wal"))
    try await writer.database.createReadOnlySnapshot(at: path)
    #expect(try Data(contentsOf: originalPath) == originalMain)
    #expect(try Data(contentsOf: URL(fileURLWithPath: originalPath.path + "-wal")) == originalWAL)
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    let readOnly = try await Store.openReadOnlySnapshot(at: admit(path, root: root))
    #expect(try await readOnly.sources().map(\.handle) == [source.handle])
    await #expect(throws: (any Error).self) { try await readOnly.markSynced(source.id, at: Date(timeIntervalSince1970: 1), cursor: "denied") }
    #expect(try await writer.sources().first?.lastSyncedAt == nil)
    #expect(try await writer.sources().first?.syncCursor == nil)
}

// A regular main file alone was insufficient: SQLite could follow an aliased live sidecar.
@Test("review rejects SQLite sidecars even when the main snapshot is an ordinary copy")
func reviewRejectsSidecars() throws {
    let root = try reviewFixtureRoot(), outside = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let path = root.appendingPathComponent("store.sqlite3")
    try Data("fixture".utf8).write(to: path)
    let other = outside.appendingPathComponent("other")
    try Data("synthetic sidecar".utf8).write(to: other)
    for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = URL(fileURLWithPath: path.path + suffix)
        try FileManager.default.linkItem(at: other, to: sidecar)
        #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(path, root: root) }
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: outside.appendingPathComponent("missing").path)
        #expect(throws: ReviewSnapshotPolicy.Refusal.self) { _ = try admit(path, root: root) }
        try FileManager.default.removeItem(at: sidecar)
    }
    #expect(try admit(path, root: root) == path.resolvingSymlinksInPath())
}

@Test("immutable review snapshots escape URI characters and create no sidecars")
func reviewImmutableSnapshotIsSelfContained() async throws {
    let root = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try await Store.open(at: root.appendingPathComponent("source.sqlite3"))
    let source = Source(kind: .manual, handle: "snapshot", displayName: "Snapshot", defaultAuthority: .authoredArtifact, defaultDomain: .personal)
    try await writer.upsert(source)
    let path = root.appendingPathComponent("copy ? # %.sqlite3")
    try await writer.database.createReadOnlySnapshot(at: path)
    // Model a self-contained WAL-format image, as an older backup can produce. SQLite's
    // documented header bytes 18/19 select WAL (2). Without immutable mode an ordinary
    // read-only connection can create auxiliary files, independently of the admission gate.
    // https://www.sqlite.org/fileformat.html#the_database_header (checked 2026-11-01).
    var image = try Data(contentsOf: path)
    image[18] = 2; image[19] = 2
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    try image.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
    let original = try Data(contentsOf: path)
    let readOnly = try await Store.openReadOnlySnapshot(at: admit(path, root: root))
    #expect(try await readOnly.sources().map(\.handle) == [source.handle])
    await #expect(throws: (any Error).self) { try await readOnly.upsert(source) }
    #expect(try Data(contentsOf: path) == original)
    for suffix in ["-wal", "-shm", "-journal"] { #expect(!FileManager.default.fileExists(atPath: path.path + suffix)) }
}

@Test("review arguments cannot silently select production startup")
func reviewArgumentsNeverFallBackToProduction() throws {
    try ReviewSnapshotPolicy.requireProductionArguments([])
    try ReviewSnapshotPolicy.requireProductionArguments(["-AppleLanguages", "(en)"])
    for args in [["--review-store", "/fictional/copy.sqlite3"], ["--review-store=/fictional/copy.sqlite3"], ["--review-unknown"], ["--review"]] {
        #expect(throws: ReviewSnapshotPolicy.Refusal.self) { try ReviewSnapshotPolicy.requireProductionArguments(args) }
    }
}

@Test("immutable store construction cannot select a writable connection")
func reviewImmutableRequiresReadOnly() throws {
    let root = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("must-not-be-created/store.sqlite3")
    #expect(throws: StoreError.self) { _ = try Database(path: path, immutableSnapshot: true) }
    #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
}

@Test("review snapshot creation refuses preexisting sidecars without creating a main file")
func reviewSnapshotCreationRejectsExistingSidecar() async throws {
    let root = try reviewFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try await Store.open(at: root.appendingPathComponent("source.sqlite3"))
    for readonly in [false, true] {
        let path = root.appendingPathComponent("copy-\(readonly).sqlite3")
        let sidecar = URL(fileURLWithPath: path.path + "-shm")
        let original = Data("preexisting fixture data".utf8)
        try original.write(to: sidecar)
        await #expect(throws: (any Error).self) {
            if readonly { try await writer.database.createReadOnlySnapshot(at: path) }
            else { try await writer.database.createPolicyRepairBackup(at: path) }
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try Data(contentsOf: sidecar) == original)
    }
}

@Test("the packaged review bootstrap opens only its explicit fixture snapshot", .enabled(if: ProcessInfo.processInfo.environment["OPENCORE_RUN_REVIEW_BOOTSTRAP"] == "1"))
func packagedReviewBootstrapUsesOnlyFixture() async throws {
    let app = URL(fileURLWithPath: "/private/tmp/opencore-review-dd/Build/Products/Debug/OpenCoreReview.app", isDirectory: true)
    try #require(Bundle(url: app)?.bundleIdentifier == ReviewSnapshotPolicy.bundleIdentifier)
    let executable = app.appendingPathComponent("Contents/MacOS/OpenCoreReview")
    let root = ReviewSnapshotPolicy.snapshotRoot
    try #require((try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil)
    if !FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
    try #require(rootAttributes[.type] as? FileAttributeType == .typeDirectory)
    try #require(((rootAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0)
    let directory = root.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try await Store.open(at: directory.appendingPathComponent("source.sqlite3"))
    let source = Source(kind: .manual, handle: "packaged-fixture", displayName: "Packaged fixture", defaultAuthority: .authoredArtifact, defaultDomain: .personal)
    try await writer.upsert(source)
    try await writer.ingest([CoreObject(sourceID: source.id, kind: .note, externalID: "fixture", title: "Fixture", text: "Synthetic review fixture", domain: .personal, authority: .authoredArtifact)])
    let path = directory.appendingPathComponent("store.sqlite3")
    try await writer.database.createReadOnlySnapshot(at: path)
    let admitted = try admit(path, root: root)
    let original = try Data(contentsOf: admitted)
    let result = try await Task.detached {
        try BoundedProcess.run(executable: executable.path, arguments: ["--review-store", admitted.path], timeout: 30, maximumOutputBytes: 65_536)
    }.value
    #expect(!result.timedOut)
    try #require(result.status == 0, "fixture bootstrap failed: \(result.stderrText)")
    try #require(result.stdoutText.contains("read-only snapshot opened; objects=1; screen review pending"))
    #expect(try Data(contentsOf: admitted) == original)
    for suffix in ["-wal", "-shm", "-journal"] { #expect(!FileManager.default.fileExists(atPath: admitted.path + suffix)) }
    let refused = try await Task.detached {
        try BoundedProcess.run(executable: executable.path, arguments: [], timeout: 30, maximumOutputBytes: 65_536)
    }.value
    #expect(!refused.timedOut)
    #expect(refused.status == 2)
    #expect(refused.stdout.isEmpty)
}
