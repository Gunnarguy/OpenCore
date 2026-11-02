import CoreModel
import Foundation

public struct OwnerPassage: Sendable {
    public var id: String
    public var text: String
    public var object: CoreObject
}

/// Typed, scoped and paged owner reads. These contain every new SQL statement used by
/// the companion; the wire protocol and the phone know nothing about SQLite.
extension Store {
    public func ownerPassages(domains: Set<Domain>, offset: Int, limit: Int = 41) async throws -> [OwnerPassage] {
        guard !domains.isEmpty else { return [] }
        let names = domains.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        return try await database.query("""
            SELECT ch.id AS passage_id,ch.text AS passage_text,o.* FROM chunk ch JOIN object o ON o.id=ch.object_id
            WHERE o.domain IN (\(marks)) ORDER BY o.ingested_at DESC,o.id,ch.ordinal LIMIT ? OFFSET ?
            """, names.map(SQLValue.text) + [.integer(Int64(limit)),.integer(Int64(offset))]).map {
                OwnerPassage(id: $0.requireString("passage_id"), text: $0.requireString("passage_text"), object: CoreObject(row: $0))
            }
    }
    public func ownerObjects(domains: Set<Domain>, query: String, offset: Int, limit: Int = 41) async throws -> [CoreObject] {
        guard !domains.isEmpty else { return [] }
        let names = domains.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        return try await database.query("""
            SELECT * FROM object WHERE domain IN (\(marks))
            AND (? = '' OR instr(lower(title),lower(?)) > 0 OR instr(lower(text),lower(?)) > 0)
            ORDER BY ingested_at DESC,id LIMIT ? OFFSET ?
            """, names.map(SQLValue.text) + [.text(query),.text(query),.text(query),.integer(Int64(limit)),.integer(Int64(offset))])
            .map(CoreObject.init(row:))
    }
    public func ownerClaims(domains: Set<Domain>, query: String, offset: Int, limit: Int = 41) async throws -> [CoreClaim] {
        let admission = Self.ownerClaimAdmission(domains: domains)
        return try await database.query("""
            SELECT c.* FROM claim c WHERE c.retracted_at IS NULL AND \(admission.sql)
            AND (? = '' OR instr(lower(COALESCE(c.literal,'') || ' ' || c.predicate),lower(?)) > 0
                OR EXISTS(SELECT 1 FROM entity e WHERE e.id=c.subject AND instr(lower(e.canonical_name),lower(?)) > 0))
            ORDER BY c.observed_at DESC,c.id LIMIT ? OFFSET ?
            """, admission.bindings + [.text(query),.text(query),.text(query),.integer(Int64(limit)),.integer(Int64(offset))])
            .map(CoreClaim.init(row:))
    }
    public func ownerAdmitsClaim(_ id: ClaimID, domains: Set<Domain>) async throws -> Bool {
        let admission = Self.ownerClaimAdmission(domains: domains)
        return try await database.scalarInt("SELECT COUNT(*) FROM claim c WHERE c.id=? AND \(admission.sql)", [.text(id.value)] + admission.bindings) > 0
    }
    private static func ownerClaimAdmission(domains: Set<Domain>) -> (sql: String, bindings: [SQLValue]) {
        guard !domains.isEmpty else { return ("0", []) }
        let names = domains.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        return ("""
            c.domain IN (\(marks))
            AND EXISTS(SELECT 1 FROM entity e WHERE e.id=c.subject AND e.domain IN (\(marks)))
            AND (c.object_entity IS NULL OR EXISTS(SELECT 1 FROM entity t WHERE t.id=c.object_entity AND t.domain IN (\(marks))))
            AND EXISTS(SELECT 1 FROM claim_evidence ce JOIN evidence ev ON ev.id=ce.evidence_id JOIN object o ON o.id=ev.object_id
                WHERE ce.claim_id=c.id AND ce.stance='supports' AND o.domain IN (\(marks)))
            """, Array(repeating: names.map(SQLValue.text), count: 4).flatMap { $0 })
    }
    public func ownerCounts(domains: Set<Domain>) async throws -> (objects: Int, passages: Int, claims: Int, entities: Int) {
        guard !domains.isEmpty else { return (0,0,0,0) }
        let names = domains.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        let values = names.map(SQLValue.text)
        let objects = try await database.scalarInt("SELECT COUNT(*) FROM object WHERE domain IN (\(marks))",values)
        let passages = try await database.scalarInt("SELECT COUNT(*) FROM chunk ch JOIN object o ON o.id=ch.object_id WHERE o.domain IN (\(marks))",values)
        let entities = try await database.scalarInt("SELECT COUNT(*) FROM entity WHERE domain IN (\(marks))",values)
        let admission = Self.ownerClaimAdmission(domains: domains)
        let claims = try await database.scalarInt("SELECT COUNT(*) FROM claim c WHERE c.retracted_at IS NULL AND \(admission.sql)",admission.bindings)
        return (objects,passages,claims,entities)
    }
    public func ownerEvents(domains: Set<Domain>, before: Date, query: String = "", offset: Int, limit: Int = 41) async throws -> [CoreEvent] {
        guard !domains.isEmpty else { return [] }
        let names = domains.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        return try await database.query("""
            SELECT ev.* FROM event ev JOIN entity subject ON subject.id=ev.subject
            WHERE ev.domain IN (\(marks)) AND subject.domain IN (\(marks)) AND ev.occurred_at<=?
            AND (?='' OR instr(lower(ev.detail || ' ' || ev.verb),lower(?)) > 0 OR instr(lower(subject.canonical_name),lower(?)) > 0)
            ORDER BY ev.occurred_at DESC,ev.id LIMIT ? OFFSET ?
            """, names.map(SQLValue.text) + names.map(SQLValue.text)
                + [.real(before.timeIntervalSince1970),.text(query),.text(query),.text(query),.integer(Int64(limit)),.integer(Int64(offset))]).map(CoreEvent.init(row:))
    }
}
