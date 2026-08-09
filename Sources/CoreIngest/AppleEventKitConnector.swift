import CoreModel
import EventKit
import Foundation

/// Calendar events and reminders via EventKit.
///
/// Both are tagged `.personal`, which means a project question cannot reach them. That is
/// not caution for its own sake: a calendar is the single richest source of who you meet,
/// when you are ill, and who you are close to, and it arrives in the store looking like
/// harmless scheduling metadata.
///
/// **Permissions.** EventKit reads the calling binary's `Info.plist` for usage strings.
/// The app bundle has them; a bare SwiftPM executable does not, so from the CLI these
/// requests are denied by TCC without a prompt ever appearing. That is a platform
/// constraint, not a bug, and `authorize()` reports it as such instead of returning an
/// empty result that looks like an empty calendar.
public struct AppleEventKitConnector: Connector {
    public enum Scope: String, Sendable {
        case calendar
        case reminders
    }

    public let source: Source
    private let scope: Scope
    private let lookBack: TimeInterval
    private let lookAhead: TimeInterval

    public init(scope: Scope, lookBackDays: Int = 730, lookAheadDays: Int = 180) {
        self.scope = scope
        self.lookBack = TimeInterval(lookBackDays) * 86_400
        self.lookAhead = TimeInterval(lookAheadDays) * 86_400
        self.source = Source(
            kind: .calendar,
            handle: scope.rawValue,
            displayName: scope == .calendar ? "Apple Calendar" : "Apple Reminders",
            // The user wrote these, but as scheduling artefacts rather than statements
            // about themselves. A calendar title is evidence, not testimony.
            defaultAuthority: .authoredArtifact,
            defaultDomain: .personal
        )
    }

    public enum AccessError: Error, CustomStringConvertible {
        case denied(Scope)
        case noInfoPlist

        public var description: String {
            switch self {
            case .denied(let scope):
                "access to \(scope.rawValue) was denied. Grant it in System Settings › Privacy & Security."
            case .noInfoPlist:
                """
                EventKit needs usage strings in the calling binary's Info.plist, which a \
                SwiftPM executable does not have. Run this sync from the OpenCore app, \
                which does. See Docs/CONNECTORS.md.
                """
            }
        }
    }

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        let store = EKEventStore()
        try await authorize(store: store)

        let objects: [CoreObject]
        switch scope {
        case .calendar:
            objects = try await calendarObjects(store: store, since: since, log: log)
        case .reminders:
            objects = try await reminderObjects(store: store, log: log)
        }
        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
    }

    private func authorize(store: EKEventStore) async throws {
        // Without usage strings the request returns false immediately rather than
        // prompting, so the two failures are distinguished by checking the bundle first.
        let key = scope == .calendar ? "NSCalendarsFullAccessUsageDescription" : "NSRemindersFullAccessUsageDescription"
        if Bundle.main.object(forInfoDictionaryKey: key) == nil {
            throw AccessError.noInfoPlist
        }

        let granted: Bool
        switch scope {
        case .calendar: granted = try await store.requestFullAccessToEvents()
        case .reminders: granted = try await store.requestFullAccessToReminders()
        }
        guard granted else { throw AccessError.denied(scope) }
    }

    private func calendarObjects(store: EKEventStore, since: Date?, log: @Sendable (String) -> Void) async throws -> [CoreObject] {
        let start = since ?? Date().addingTimeInterval(-lookBack)
        let end = Date().addingTimeInterval(lookAhead)

        // EventKit caps a single predicate at roughly four years, so long ranges are
        // fetched in yearly windows rather than silently truncated.
        var objects: [CoreObject] = []
        var windowStart = start
        let formatter = ISO8601DateFormatter()

        while windowStart < end {
            let windowEnd = min(end, windowStart.addingTimeInterval(365 * 86_400))
            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)

            for event in store.events(matching: predicate) {
                var text = event.title ?? "(untitled event)"
                if let location = event.location, !location.isEmpty { text += "\nLocation: \(location)" }
                if let notes = event.notes, !notes.isEmpty { text += "\n\(notes)" }
                if let attendees = event.attendees, !attendees.isEmpty {
                    text += "\nAttendees: " + attendees.compactMap { $0.name }.joined(separator: ", ")
                }
                if let startDate = event.startDate { text += "\nStarts: \(formatter.string(from: startDate))" }

                objects.append(CoreObject(
                    sourceID: source.id,
                    kind: .calendarEvent,
                    externalID: event.eventIdentifier ?? "\(event.calendarItemIdentifier)",
                    title: event.title ?? "(untitled event)",
                    text: text,
                    uri: nil,
                    authoredAt: event.startDate,
                    domain: .personal,
                    authority: .authoredArtifact,
                    metadata: {
                        var data: [String: String] = [
                            "calendar": event.calendar?.title ?? "unknown",
                            "all_day": String(event.isAllDay),
                            "attendee_count": String(event.attendees?.count ?? 0),
                        ]
                        // Named attendees, so claim extraction can build person entities and
                        // met_with edges. Without this the richest signal in a calendar, who
                        // you actually spend time with, is only unstructured text.
                        let named = (event.attendees ?? []).compactMap(\.name).filter { !$0.isEmpty }
                        if !named.isEmpty { data["attendees"] = named.joined(separator: "\u{1F}") }
                        if let location = event.location, !location.isEmpty { data["location"] = location }
                        if let organiser = event.organizer?.name { data["organiser"] = organiser }
                        return data
                    }()
                ))
            }
            windowStart = windowEnd
        }

        log("calendar: \(objects.count) events")
        return objects
    }

    private func reminderObjects(store: EKEventStore, log: @Sendable (String) -> Void) async throws -> [CoreObject] {
        let predicate = store.predicateForReminders(in: nil)
        let sourceID = source.id

        // `EKReminder` is not Sendable, so the mapping to `CoreObject` happens *inside*
        // the callback. Returning the EKReminders and mapping afterwards would move
        // reference types across an isolation boundary, which Swift 6 correctly rejects.
        let objects: [CoreObject] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let formatter = ISO8601DateFormatter()
                let mapped = (reminders ?? []).map { reminder -> CoreObject in
                    var text = reminder.title ?? "(untitled reminder)"
                    if let notes = reminder.notes, !notes.isEmpty { text += "\n\(notes)" }
                    text += "\nStatus: \(reminder.isCompleted ? "completed" : "open")"
                    if let due = reminder.dueDateComponents?.date { text += "\nDue: \(formatter.string(from: due))" }

                    return CoreObject(
                        sourceID: sourceID,
                        kind: .note,
                        externalID: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "(untitled reminder)",
                        text: text,
                        uri: nil,
                        // Completion date first: when a reminder was finished is the more
                        // informative timestamp, and creation is not exposed by EventKit.
                        authoredAt: reminder.completionDate ?? reminder.dueDateComponents?.date,
                        domain: .personal,
                        authority: .authoredArtifact,
                        metadata: [
                            "list": reminder.calendar?.title ?? "unknown",
                            "completed": String(reminder.isCompleted),
                            "priority": String(reminder.priority),
                        ]
                    )
                }
                continuation.resume(returning: mapped)
            }
        }

        log("reminders: \(objects.count) items (\(objects.filter { $0.metadata["completed"] == "true" }.count) completed)")
        return objects
    }
}
