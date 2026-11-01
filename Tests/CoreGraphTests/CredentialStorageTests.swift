import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import CoreIngest

private final class MemoryCredentialKeychain: CredentialKeychainBackend {
    private struct State: Sendable {
        var entries: [String: Data] = [:]
        var readFailure: OSStatus?
        var writeFailure: OSStatus?
        var lastAuthentication: Keychain.Authentication?
    }
    private let state = Mutex(State())

    func seed(_ value: String, account: String) {
        state.withLock { $0.entries[account] = Data(value.utf8) }
    }
    func failReads(_ status: OSStatus?) { state.withLock { $0.readFailure = status } }
    func failWrites(_ status: OSStatus?) { state.withLock { $0.writeFailure = status } }
    var lastAuthentication: Keychain.Authentication? { state.withLock { $0.lastAuthentication } }

    func read(account: String, authentication: Keychain.Authentication) throws -> Data? {
        try state.withLock { state in
            state.lastAuthentication = authentication
            if let status = state.readFailure { throw Keychain.KeychainError.failed(status) }
            return state.entries[account]
        }
    }
    func store(_ data: Data, account: String, authentication: Keychain.Authentication) throws {
        try state.withLock { state in
            state.lastAuthentication = authentication
            if let status = state.writeFailure { throw Keychain.KeychainError.failed(status) }
            state.entries[account] = data
        }
    }
}

private struct FixtureCredentialVault: LegacyCredentialReading {
    let entries: [String: String]
    init(_ entries: [String: String] = [:]) { self.entries = entries }
    func read(account: String) throws -> String? { entries[account] }
}

// The former startup path deleted every legacy Keychain item before loading the vault.
@Test("reading an original Keychain item preserves it and prefers it to a legacy file value")
func keychainReadsPreserveOriginalCredential() {
    let backend = MemoryCredentialKeychain()
    backend.seed("system fixture", account: "first")
    backend.seed("second fixture", account: "second")
    let storage = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault(["first": "old fixture"]))
    #expect(storage.read(account: "first").value == "system fixture")
    #expect(storage.read(account: "second").value == "second fixture")
    #expect(backend.lastAuthentication == .nonInteractive)
}

// A cache mutation preceded a throwing vault write, so a failed save appeared successful.
@Test("a failed credential save leaves the previously saved value visible")
func failedSavePreservesCredential() throws {
    let backend = MemoryCredentialKeychain()
    let storage = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault())
    try storage.write("original fixture", account: "first")
    backend.failWrites(errSecNotAvailable)
    #expect(throws: Keychain.KeychainError.self) { try storage.write("replacement fixture", account: "first") }
    #expect(storage.read(account: "first").value == "original fixture")
}

// Process-local dictionaries overwrote unrelated writes made by the CLI or app.
@Test("independent credential readers see each successful per-account write")
func independentReadersSeeCredentialUpdates() throws {
    let backend = MemoryCredentialKeychain()
    let firstProcess = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault())
    let secondProcess = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault())
    try firstProcess.write("first fixture", account: "first")
    try secondProcess.write("second fixture", account: "second")
    #expect(firstProcess.read(account: "second").value == "second fixture")
    #expect(secondProcess.read(account: "first").value == "first fixture")
    try secondProcess.write("rotated fixture", account: "first")
    #expect(firstProcess.read(account: "first").value == "rotated fixture")
    #expect(firstProcess.read(account: "second").value == "second fixture")
}

// Re-reading a preserved file after clearing a credential must not revive that credential.
@Test("clearing a legacy credential durably suppresses fallback for that account only")
func clearingLegacyCredentialDoesNotReviveIt() throws {
    let backend = MemoryCredentialKeychain()
    let legacy = FixtureCredentialVault(["first": "old fixture", "second": "other fixture"])
    let storage = CredentialStorage(backend: backend, legacyVault: legacy)
    try storage.delete(account: "first")
    let laterProcess = CredentialStorage(backend: backend, legacyVault: legacy)
    if case .missing = laterProcess.read(account: "first") {} else { Issue.record("cleared legacy credential revived") }
    #expect(laterProcess.read(account: "second").value == "other fixture")
    try laterProcess.write("new fixture", account: "first")
    #expect(storage.read(account: "first").value == "new fixture")
    try storage.write(" \n ", account: "first")
    #expect(laterProcess.read(account: "first").value == nil)
}

// Failed deletions must not publish a retirement marker or hide usable original data.
@Test("failed deletion preserves the legacy credential until a durable clear succeeds")
func failedDeletePreservesLegacyFallback() throws {
    let backend = MemoryCredentialKeychain()
    let storage = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault(["first": "old fixture"]))
    backend.failWrites(errSecInteractionNotAllowed)
    #expect(throws: Keychain.KeychainError.self) { try storage.delete(account: "first") }
    #expect(storage.read(account: "first").value == "old fixture")
    backend.failWrites(nil)
    try storage.delete(account: "first")
    #expect(storage.read(account: "first").value == nil)
}

// Legacy recovery must never bypass a locked Keychain entry or masquerade as absence.
@Test("background lookup reports required authentication without substituting a legacy token")
func backgroundLookupReportsAuthentication() {
    let backend = MemoryCredentialKeychain()
    backend.failReads(errSecInteractionNotAllowed)
    let storage = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault(["first": "old fixture"]))
    if case .authenticationRequired = storage.read(account: "first") {} else { Issue.record("authentication was hidden") }
    #expect(backend.lastAuthentication == .nonInteractive)
    _ = storage.read(account: "first", authentication: .allowInteraction)
    #expect(backend.lastAuthentication == .allowInteraction)
}

@Test("a Keychain failure is distinct from an absent credential")
func lookupFailureIsNotAbsence() {
    let backend = MemoryCredentialKeychain()
    backend.failReads(errSecNotAvailable)
    let storage = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault(["first": "old fixture"]))
    if case .failed = storage.read(account: "first") {} else { Issue.record("storage failure was hidden") }
}

@Test("damaged Keychain envelopes do not silently fall back to stale credentials")
func malformedKeychainEnvelopeBlocksFallback() {
    let backend = MemoryCredentialKeychain()
    backend.seed("OpenCoreCredential:2\0broken", account: "first")
    let storage = CredentialStorage(backend: backend, legacyVault: FixtureCredentialVault(["first": "old fixture"]))
    if case .failed = storage.read(account: "first") {} else { Issue.record("damaged credential was treated as absent") }
}

// The previous loader marked corrupt data as an empty loaded vault and overwrote it later.
@Test("a damaged legacy vault is reported and original bytes survive a replacement save")
func damagedVaultIsPreserved() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-credential-test-\(UUID()).vault")
    let original = Data("damaged fixture bytes".utf8)
    try original.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let backend = MemoryCredentialKeychain()
    let storage = CredentialStorage(backend: backend, legacyVault: LegacyCredentialVault(url: url, username: "fixture-user"))
    if case .failed = storage.read(account: "first") {} else { Issue.record("corrupt recovery file was hidden") }
    try storage.write("replacement fixture", account: "first")
    #expect(storage.read(account: "first").value == "replacement fixture")
    #expect(try Data(contentsOf: url) == original)
}

@Test("version one encrypted credentials remain recoverable without rewriting their file")
func versionOneVaultRemainsReadOnly() throws {
    let username = "fixture-user"
    let seed = "\(Keychain.service)::\(username)::macOS-OpenCore-Vault-v1"
    let key = SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
    let plaintext = try JSONEncoder().encode(["first": "legacy fixture"])
    let sealed = try AES.GCM.seal(plaintext, using: key)
    let original = try #require(sealed.combined)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-credential-test-\(UUID()).vault")
    try original.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let backend = MemoryCredentialKeychain()
    let vault = LegacyCredentialVault(url: url, username: username)
    let storage = CredentialStorage(backend: backend, legacyVault: vault)
    if case .found("legacy fixture", source: .legacyVault) = storage.read(account: "first") {} else {
        Issue.record("legacy recovery source was not identified")
    }
    #expect(try backend.read(account: "first", authentication: .nonInteractive) == nil)
    try storage.write("legacy fixture", account: "first")
    if case .found("legacy fixture", source: .keychain) = storage.read(account: "first") {} else {
        Issue.record("explicit save did not use Keychain")
    }
    try storage.delete(account: "first")
    #expect(storage.read(account: "first").value == nil)
    #expect(try Data(contentsOf: url) == original)
}

@Test("plaintext recovery compatibility preserves its original file")
func plaintextLegacyCompatibilityIsReadOnly() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-credential-test-\(UUID()).vault")
    let original = try JSONEncoder().encode(["first": "plaintext fixture"])
    try original.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let storage = CredentialStorage(backend: MemoryCredentialKeychain(), legacyVault: LegacyCredentialVault(url: url, username: "fixture-user"))
    #expect(storage.read(account: "first").value == "plaintext fixture")
    #expect(try Data(contentsOf: url) == original)
}

@Test("a nonexistent recovery file is absence and is never created by a read")
func missingLegacyFileIsNotCreated() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-credential-test-\(UUID()).vault")
    let storage = CredentialStorage(backend: MemoryCredentialKeychain(), legacyVault: LegacyCredentialVault(url: url, username: "fixture-user"))
    if case .missing = storage.read(account: "first") {} else { Issue.record("missing file was not absence") }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// The gh CLI cache used to remember nil forever, hiding a later terminal login.
@Test("an absent gh login is retried after a short bounded cache lifetime")
func missingGitHubTokenCacheExpires() {
    let cache = GitHubCLITokenCache(successLifetime: 30, missingLifetime: 2)
    #expect(cache.resolve(at: 10) { nil } == nil)
    #expect(cache.resolve(at: 11) { "fresh fixture" } == nil)
    #expect(cache.resolve(at: 12) { "fresh fixture" } == "fresh fixture")
}

// A successful gh token was also cached forever, hiding rotation or logout.
@Test("successful gh tokens expire so a rotation or logout reaches running processes")
func successfulGitHubTokenCacheExpires() {
    let cache = GitHubCLITokenCache(successLifetime: 30, missingLifetime: 2)
    #expect(cache.resolve(at: 10) { "old fixture" } == "old fixture")
    #expect(cache.resolve(at: 39) { "rotated fixture" } == "old fixture")
    #expect(cache.resolve(at: 40) { "rotated fixture" } == "rotated fixture")
    #expect(cache.resolve(at: 70) { nil } == nil)
}

@Test("explicit gh cache invalidation immediately observes a new login or rotation")
func githubTokenCacheCanBeInvalidated() {
    let cache = GitHubCLITokenCache()
    #expect(cache.resolve(at: 10) { nil } == nil)
    cache.invalidate()
    #expect(cache.resolve(at: 10) { "new fixture" } == "new fixture")
    cache.invalidate()
    #expect(cache.resolve(at: 10) { "rotated fixture" } == "rotated fixture")
}

@Test("a backwards cache clock cannot retain a stale gh token indefinitely")
func githubTokenCacheHandlesClockRollback() {
    let cache = GitHubCLITokenCache()
    #expect(cache.resolve(at: 10) { "old fixture" } == "old fixture")
    #expect(cache.resolve(at: 9) { "rotated fixture" } == "rotated fixture")
}

@Test("a slow failed gh lookup receives its full absence cache lifetime")
func slowGitHubTokenFailureDoesNotImmediatelyExpire() {
    let cache = GitHubCLITokenCache(successLifetime: 30, missingLifetime: 2)
    var now: TimeInterval = 10
    #expect(cache.resolve(clock: { now }) { now = 15; return nil } == nil)
    #expect(cache.resolve(at: 16) { "fresh fixture" } == nil)
    #expect(cache.resolve(at: 17) { "fresh fixture" } == "fresh fixture")
}
