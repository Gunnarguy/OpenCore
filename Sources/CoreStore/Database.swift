import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case schemaMissing
    case notFound(String)

    public var description: String {
        switch self {
        case .open(let message): "could not open database: \(message)"
        case .prepare(let message, let sql): "could not prepare statement: \(message)\n  sql: \(sql)"
        case .step(let message, let sql): "statement failed: \(message)\n  sql: \(sql)"
        case .schemaMissing: "schema.sql is missing from the CoreStore bundle"
        case .notFound(let what): "not found: \(what)"
        }
    }
}

/// A bindable SQL value. Modelled explicitly rather than with `Any` so a nil never
/// silently becomes the string "nil", which is the classic way a NULL column ends up
/// holding four characters.
public enum SQLValue: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(nilLiteral: ()) { self = .null }

    public init(text value: String?) { self = value.map { .text($0) } ?? .null }
    public init(int value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(double value: Double?) { self = value.map { .real($0) } ?? .null }
    public init(date value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
    public init(blob value: Data?) { self = value.map { .blob($0) } ?? .null }
    public init(bool value: Bool) { self = .integer(value ? 1 : 0) }
}

/// One result row, already materialised. Rows are read out of the statement fully before
/// the handle is finalised, so nothing escapes holding a pointer into SQLite memory.
public struct Row: Sendable {
    private let columns: [String: SQLValue]

    init(columns: [String: SQLValue]) { self.columns = columns }

    public func string(_ name: String) -> String? {
        if case .text(let value) = columns[name] ?? .null { return value }
        return nil
    }

    public func int(_ name: String) -> Int? {
        switch columns[name] ?? .null {
        case .integer(let value): Int(value)
        case .real(let value): Int(value)
        default: nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch columns[name] ?? .null {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public func date(_ name: String) -> Date? {
        double(name).map(Date.init(timeIntervalSince1970:))
    }

    public func data(_ name: String) -> Data? {
        if case .blob(let value) = columns[name] ?? .null { return value }
        return nil
    }

    /// For columns declared NOT NULL. Traps rather than returning a fallback, because a
    /// missing NOT NULL column is a schema bug and papering over it hides the bug.
    public func requireString(_ name: String) -> String {
        guard let value = string(name) else { preconditionFailure("column '\(name)' is NOT NULL but read as null") }
        return value
    }

    public func requireInt(_ name: String) -> Int {
        guard let value = int(name) else { preconditionFailure("column '\(name)' is NOT NULL but read as null") }
        return value
    }

    public func requireDouble(_ name: String) -> Double {
        guard let value = double(name) else { preconditionFailure("column '\(name)' is NOT NULL but read as null") }
        return value
    }

    public func requireDate(_ name: String) -> Date {
        Date(timeIntervalSince1970: requireDouble(name))
    }
}

// MARK: - Connection

/// A raw SQLite handle with synchronous methods.
///
/// Not `Sendable` on purpose: it is owned by the `Database` actor and only ever handed to
/// a closure that runs inside actor isolation. Keeping the sync API here is what lets
/// `transaction` take an ordinary throwing closure that can issue several statements
/// without an `await` between them, which is the only way BEGIN/COMMIT is actually atomic.
public final class Connection {
    fileprivate let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    /// Multi-statement DDL. Uses `sqlite3_exec` because prepare/step handles one statement.
    public func executeScript(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw StoreError.step(message, sql: String(sql.prefix(200)))
        }
    }

    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw StoreError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw StoreError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }

            var columns: [String: SQLValue] = [:]
            columns.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let position = Int32(index)
                switch sqlite3_column_type(statement, position) {
                case SQLITE_INTEGER:
                    columns[names[index]] = .integer(sqlite3_column_int64(statement, position))
                case SQLITE_FLOAT:
                    columns[names[index]] = .real(sqlite3_column_double(statement, position))
                case SQLITE_TEXT:
                    columns[names[index]] = .text(String(cString: sqlite3_column_text(statement, position)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, position) {
                        let count = Int(sqlite3_column_bytes(statement, position))
                        columns[names[index]] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        columns[names[index]] = .blob(Data())
                    }
                default:
                    columns[names[index]] = .null
                }
            }
            rows.append(Row(columns: columns))
        }
        return rows
    }

    /// First column of the first row, as an Int. Column name is irrelevant.
    public func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        for (offset, value) in bindings.enumerated() {
            let position = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, position)
            case .integer(let number):
                sqlite3_bind_int64(statement, position, number)
            case .real(let number):
                sqlite3_bind_double(statement, position, number)
            case .text(let string):
                sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }
        return statement
    }
}

// MARK: - Database

/// The only thing in OpenCore that talks to SQLite.
///
/// An actor because SQLite connections are not thread-safe in the mode used here, and
/// serialising at the type boundary is cheaper to reason about than a lock discipline
/// every caller has to remember.
public actor Database {
    private let connection: Connection
    public let path: URL

    /// Current schema version. Bump alongside a new migration.
    public static let schemaVersion = 1

    public init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.open(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        self.connection = Connection(handle: handle)
    }

    /// The default location: `~/Library/Application Support/OpenCore/opencore.sqlite3`.
    /// Deliberately outside `~/Documents`, because iCloud sync corrupts SQLite WAL files
    /// and that lesson has already been paid for once in this codebase's ancestry.
    public static func defaultPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenCore", isDirectory: true).appendingPathComponent("opencore.sqlite3")
    }

    public func migrate() throws {
        guard let url = Bundle.module.url(forResource: "schema", withExtension: "sql"),
              let sql = try? String(contentsOf: url, encoding: .utf8)
        else { throw StoreError.schemaMissing }

        try connection.executeScript(sql)

        let applied = try connection.query(
            "SELECT version FROM schema_migration WHERE version = ?",
            [.integer(Int64(Self.schemaVersion))]
        )
        if applied.isEmpty {
            try connection.execute(
                "INSERT INTO schema_migration (version, applied_at) VALUES (?, ?)",
                [.integer(Int64(Self.schemaVersion)), .real(Date().timeIntervalSince1970)]
            )
        }
    }

    /// Run work against the connection. The closure is synchronous, so a caller can issue
    /// several statements with no suspension point between them.
    public func read<T: Sendable>(_ body: (Connection) throws -> T) throws -> T {
        try body(connection)
    }

    /// Same, wrapped in a transaction that rolls back on any thrown error.
    public func write<T: Sendable>(_ body: (Connection) throws -> T) throws -> T {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            let value = try body(connection)
            try connection.executeScript("COMMIT")
            return value
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }

    /// Convenience for one-off statements outside a transaction.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        try connection.execute(sql, bindings)
    }

    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        try connection.query(sql, bindings)
    }

    public func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        try connection.scalarInt(sql, bindings)
    }
}
