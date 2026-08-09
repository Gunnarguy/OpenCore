import CoreModel
import Foundation

/// The few settings the app and the CLI must agree on.
///
/// `DECISIONS.md` records that app preferences live in `UserDefaults` and not in the store,
/// and notes the exception: *"If they ever need to agree, the settings belong in a config file
/// both read."* This is that file. It exists because of one concrete bug — the Settings toggle
/// for exposing sensitive domains over MCP changed nothing, since the server runs as a
/// separate `opencore mcp` process that never sees `UserDefaults`.
///
/// Deliberately tiny. Anything that only the app cares about stays in `UserDefaults`; anything
/// that is per-dataset stays in the store. This holds only what crosses the process boundary.
public struct SharedConfig: Codable, Sendable, Equatable {
    /// Whether `opencore mcp` lets a caller reach medical, financial or relationship data.
    ///
    /// The `--unsafe-expose-sensitive` flag still wins when passed, so a deliberate one-off
    /// never depends on what a GUI toggle happens to be set to.
    public var exposeSensitiveDomainsOverMCP: Bool

    public static let `default` = SharedConfig(exposeSensitiveDomainsOverMCP: false)

    public init(exposeSensitiveDomainsOverMCP: Bool = false) {
        self.exposeSensitiveDomainsOverMCP = exposeSensitiveDomainsOverMCP
    }

    /// Beside the store, so a user who finds one finds the other.
    public static func defaultPath() -> URL {
        Database.defaultPath().deletingLastPathComponent().appendingPathComponent("config.json")
    }

    /// Read, falling back to defaults. A missing or malformed file is not an error worth
    /// failing a sync over, and the safe default is the restrictive one.
    public static func load(from url: URL? = nil) -> SharedConfig {
        let path = url ?? defaultPath()
        guard let data = try? Data(contentsOf: path),
              let config = try? JSONDecoder().decode(SharedConfig.self, from: data)
        else { return .default }
        return config
    }

    public func save(to url: URL? = nil) throws {
        let path = url ?? Self.defaultPath()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: path, options: .atomic)
    }
}

extension Store {
    /// Every table below `object`, in an order that respects foreign keys.
    ///
    /// Named here rather than inlined at each call site because it was previously duplicated
    /// between the CLI's `rebuild` and the app's Maintenance screen, in violation of the rule
    /// that every SQL string lives in `CoreStore`. Two copies of a delete list is precisely the
    /// thing that drifts: add a table, update one, and the other silently stops clearing it.
    public static let derivedTables = [
        "claim_evidence", "receipt_evidence", "receipt_claim",
        "contradiction", "belief", "correction",
        "claim", "evidence", "event", "edge",
        "chunk_vector", "chunk", "embedding_run",
    ]

    /// Drop every derived layer. Objects, sources, entities and receipts survive.
    ///
    /// Entities are kept deliberately: the CLI's original list did not clear them either, so a
    /// changed entity count after a rebuild is a real defect in resolution rather than an
    /// artifact of the reset.
    public func dropDerivedLayers() async throws {
        try await database.write { connection in
            for table in Self.derivedTables {
                try connection.execute("DELETE FROM \(table)")
            }
        }
    }

    /// Every object, paged so a large store does not build one enormous array of rows at once.
    ///
    /// It still materialises everything in memory by the end. Fine at the current 1,268 and
    /// not fine at 100k; that limit is recorded in `Docs/ROADMAP.md` rather than pretended away.
    public func allObjects(pageSize: Int = 500) async throws -> [CoreObject] {
        var all: [CoreObject] = []
        var offset = 0
        while true {
            let rows = try await database.query(
                "SELECT id FROM object ORDER BY rowid LIMIT ? OFFSET ?",
                [.integer(Int64(pageSize)), .integer(Int64(offset))]
            )
            if rows.isEmpty { break }
            all.append(contentsOf: try await objects(ids: rows.map { ObjectID($0.requireString("id")) }))
            offset += pageSize
        }
        return all
    }
}
