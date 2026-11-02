import Foundation
import Testing
@testable import CoreStore
import CoreModel

private func migrationTestPath() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("opencore-migration-\(UUID().uuidString)/store.sqlite3")
}

@Test("migration seven adds phone deletion markers without changing existing conversations")
func phoneTombstoneMigrationPreservesExistingData() async throws {
    let path = migrationTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let store = try await Store.open(at: path)
    try await store.openConversation(id: "existing-fixture", title: "Existing fixture")
    // Construct a version-six synthetic store using this fixture's own temporary database.
    try await store.database.execute("DROP TRIGGER IF EXISTS companion_thread_guard_delete")
    try await store.database.execute("DROP TABLE companion_thread_tombstone")
    try await store.database.execute("DELETE FROM schema_migration WHERE version = 7")
    try await store.database.migrate()
    #expect(try await store.database.scalarInt("SELECT MAX(version) FROM schema_migration") == 7)
    #expect(try await store.conversation(id: "existing-fixture")?.title == "Existing fixture")
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM companion_thread_tombstone") == 0)
}

@Test("an already-open older writer cannot delete a phone thread without its tombstone")
func phoneTombstoneMigrationFencesOlderWriter() async throws {
    let path = migrationTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let store = try await Store.open(at: path)
    let scope = CompanionHistoryScope(deviceID: UUID(), grantID: UUID(), domains: [.project, .publicRecord], selectedDomain: nil)
    let id = scope.conversationID(for: UUID())
    try await store.openConversation(id: id, title: "Fixture")
    // Create a version-six fixture and leave its old connection open across migration.
    try await store.database.execute("DROP TRIGGER IF EXISTS companion_thread_guard_delete")
    try await store.database.execute("DROP TABLE companion_thread_tombstone")
    try await store.database.execute("DELETE FROM schema_migration WHERE version = 7")
    let oldWriter = try Database(path: path)
    try await store.database.migrate()
    await #expect(throws: (any Error).self) {
        try await oldWriter.execute("DELETE FROM conversation WHERE id = ?", [.text(id)])
    }
    #expect(try await store.conversation(id: id) != nil)
    try await store.deleteConversation(id: id)
    #expect(try await store.conversation(id: id) == nil)
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM companion_thread_tombstone") == 1)
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM companion_thread_tombstone WHERE pending_delete_id IS NOT NULL") == 0)
    // Deleting a missing phone thread fires no DELETE trigger but must still clear authorization.
    try await store.deleteConversation(id: scope.conversationID(for: UUID()))
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM companion_thread_tombstone WHERE pending_delete_id IS NOT NULL") == 0)
}

// Previously a migration could leave half its DDL behind without a ledger entry.
@Test("a failed migration rolls back its schema and version ledger together")
func failedMigrationRollsBack() async throws {
    let path = migrationTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let database = try Database(path: path)
    await #expect(throws: (any Error).self) {
        try await database.applyMigrations([
            (1, "CREATE TABLE schema_migration(version INTEGER PRIMARY KEY, applied_at REAL); CREATE TABLE partial_change(value TEXT);"),
            (2, "INSERT INTO missing_table VALUES (1);")
        ])
    }
    #expect(try await database.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('schema_migration', 'partial_change')") == 0)
}

// Previously an older binary reran migration 1 against a store from a newer binary.
@Test("an older build refuses a newer store before running migrations")
func newerStoreIsRefused() async throws {
    let path = migrationTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let store = try await Store.open(at: path)
    try await store.database.execute("INSERT INTO schema_migration(version,applied_at) VALUES (?,0)", [.integer(Int64(Database.schemaVersion + 1))])
    await #expect(throws: (any Error).self) { try await store.database.migrate() }
    #expect(try await store.database.scalarInt("SELECT MAX(version) FROM schema_migration") == Database.schemaVersion + 1)
}

// Previously unknown persisted domain names silently became project-readable data.
@Test("unknown source and object domains are quarantined when decoded")
func unknownStoredDomainsFailClosed() async throws {
    let path = migrationTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let store = try await Store.open(at: path)
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .document, externalID: "fixture", title: "Fixture", text: "Unclassified", domain: .project, authority: .authoredArtifact)
    try await store.ingest([object])
    try await store.database.execute("UPDATE source SET default_domain='future-domain'")
    try await store.database.execute("UPDATE object SET domain='future-domain'")
    #expect(try await store.sources().first?.defaultDomain == .restricted)
    #expect(try await store.object(object.id)?.domain == .restricted)
}
