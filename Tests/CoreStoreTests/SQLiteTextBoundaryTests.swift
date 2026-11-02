import CoreStore
import Foundation
import Testing

// SQLite text used to be read as a C string, so a stored value silently lost all bytes after NUL.
@Test("SQLite text reads retain embedded NUL and every later UTF-8 byte",
      arguments: ["before\u{0}after", "Ω🙂\u{0}tail", "ordinary text"])
func sqliteReadKeepsEmbeddedNUL(value: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-text-fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(path: directory.appendingPathComponent("fixture.sqlite3"))
    // Bind bytes and let SQLite produce TEXT, so broken text binding cannot mask a read defect.
    let rows = try await database.query("SELECT CAST(? AS TEXT) AS value", [.blob(Data(value.utf8))])
    #expect(rows.first?.string("value") == value)
}

// A -1 text binding length previously stopped at NUL, silently truncating the stored value.
@Test("SQLite text bindings retain embedded NUL and use byte lengths, including empty strings",
      arguments: ["", "before\u{0}after", "Ω🙂\u{0}tail", "ordinary text"])
func sqliteBindKeepsEmbeddedNUL(value: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-text-fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(path: directory.appendingPathComponent("fixture.sqlite3"))
    // Read back a BLOB, so a broken TEXT reader cannot mask the text-binding defect.
    let rows = try await database.query("SELECT typeof(?) AS kind, CAST(? AS BLOB) AS bytes", [.text(value), .text(value)])
    #expect(rows.first?.string("kind") == "text")
    #expect(rows.first?.data("bytes") == Data(value.utf8))
}

@Test("a failed text binding reports the error and leaves the database usable")
func sqliteInvalidTextBindingReportsError() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-text-fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(path: directory.appendingPathComponent("fixture.sqlite3"))
    // SQLite rejects binding a value when the prepared statement has no parameter.
    await #expect(throws: StoreError.self) {
        try await database.query("SELECT 1", [.text("unused")])
    }
    let rows = try await database.query("SELECT ? AS value", [.text("still usable")])
    #expect(rows.first?.string("value") == "still usable")
}
