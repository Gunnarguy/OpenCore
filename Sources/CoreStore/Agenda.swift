import CoreModel
import Foundation

/// One calendar event or reminder, read straight from the object the connector wrote.
public struct AgendaItem: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var title: String
    /// An event's start, a reminder's due date, or a finished reminder's completion date.
    public var when: Date?
    public var isAllDay: Bool
    /// The calendar an event is on, or the list a reminder is in.
    public var group: String?

    init(_ object: CoreObject) {
        id = object.id
        title = object.title
        when = object.authoredAt
        isAllDay = object.metadata["all_day"] == "true"
        group = object.metadata["calendar"] ?? object.metadata["list"]
    }

    /// Whether every word of `terms` appears in the title or the group's name.
    public func matches(_ terms: [String]) -> Bool {
        let text = "\(title) \(group ?? "")".lowercased()
        return terms.allSatisfy { text.contains($0) }
    }
}

extension Store {
    /// Far more rows than any answer shows, so a filter on a topic still sees the whole span.
    /// **Chosen, not measured:** the real store held 565 events and 5,478 reminders on 2026-11-02.
    private static let agendaRowCeiling = 10_000

    /// Calendar events starting in `start..<end`, earliest first, from admitted domains only.
    public func agendaEvents(from start: Date, to end: Date, domains: Set<Domain>) async throws -> [AgendaItem] {
        guard !domains.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
        return try await database.query(
            """
            SELECT o.* FROM object o JOIN source s ON s.id = o.source_id
            WHERE s.kind = ? AND s.handle = ? AND o.kind = ? AND o.domain IN (\(placeholders))
              AND o.authored_at >= ? AND o.authored_at < ?
            ORDER BY o.authored_at ASC, o.id ASC
            LIMIT ?
            """,
            [.text(SourceKind.calendar.rawValue), .text("calendar"), .text(ObjectKind.calendarEvent.rawValue)]
                + Self.agendaDomainBindings(domains)
                + [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970), .integer(Int64(Self.agendaRowCeiling))]
        ).map { AgendaItem(CoreObject(row: $0)) }
    }

    /// Reminders by whether they are finished, from admitted domains only. The newest first, and
    /// undated ones last. `from` and `to` bound a date only when given, so an undated open reminder
    /// is still returned when neither is.
    public func agendaReminders(completed: Bool, from start: Date? = nil, to end: Date? = nil,
                                domains: Set<Domain>) async throws -> [AgendaItem] {
        guard !domains.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
        var bounds = ""
        var bindings: [SQLValue] = []
        if let start { bounds += " AND o.authored_at >= ?"; bindings.append(.real(start.timeIntervalSince1970)) }
        if let end { bounds += " AND o.authored_at < ?"; bindings.append(.real(end.timeIntervalSince1970)) }
        return try await database.query(
            """
            SELECT o.* FROM object o JOIN source s ON s.id = o.source_id
            WHERE s.kind = ? AND s.handle = ? AND o.domain IN (\(placeholders))
              AND json_extract(o.metadata, '$.completed') = ?\(bounds)
            ORDER BY o.authored_at IS NULL, o.authored_at DESC, o.id ASC
            LIMIT ?
            """,
            [.text(SourceKind.calendar.rawValue), .text("reminders")] + Self.agendaDomainBindings(domains)
                + [.text(completed ? "true" : "false")] + bindings + [.integer(Int64(Self.agendaRowCeiling))]
        ).map { AgendaItem(CoreObject(row: $0)) }
    }

    /// When a calendar source last synced. `handle` is `calendar` or `reminders`. Nil means never.
    public func agendaLastSynced(_ handle: String) async throws -> Date? {
        try await database.query(
            "SELECT last_synced_at AS synced FROM source WHERE kind = ? AND handle = ?",
            [.text(SourceKind.calendar.rawValue), .text(handle)]
        ).first?.date("synced")
    }

    private static func agendaDomainBindings(_ domains: Set<Domain>) -> [SQLValue] {
        domains.map(\.rawValue).sorted().map { .text($0) }
    }

    /// Current `predicate` claims holding exactly `literal`, for a question that names a value and
    /// no subject: "which projects are dormant".
    public func currentClaims(predicate: String, literal: String) async throws -> [CoreClaim] {
        try await database.query(
            "SELECT * FROM claim WHERE predicate = ? AND literal = ? AND retracted_at IS NULL ORDER BY subject, observed_at DESC, id ASC",
            [.text(predicate), .text(literal)]
        ).map(CoreClaim.init(row:))
    }
}
