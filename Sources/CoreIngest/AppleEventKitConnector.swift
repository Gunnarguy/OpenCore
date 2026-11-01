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
    /// How many accepted attendees to name in an event's searchable text.
    ///
    /// **Chosen, not measured.** 25 is where a list still reads as a list rather than a data
    /// dump. The number that forced a cap at all was measured: one event carried 4,004 names,
    /// 78,722 characters, 31 chunks. Anything beyond the cap is counted in the same sentence,
    /// so the text never implies it is complete when it is not.
    static let namesInText = 25

    public enum Scope: String, Sendable {
        case calendar
        case reminders
    }

    public let source: Source
    private let scope: Scope
    private let lookBack: TimeInterval
    private let lookAhead: TimeInterval
    private let unattended: Bool

    /// - Parameter unattended: true for a sync nobody started. See `mustRequestAccess`.
    public init(scope: Scope, lookBackDays: Int = 730, lookAheadDays: Int = 180, unattended: Bool = false) {
        self.scope = scope
        self.unattended = unattended
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
        /// Nobody has answered the permission prompt yet, and nobody is here to answer it.
        case needsFirstGrant(Scope)
        /// EventKit answered with no list at all, which is a failed read and not an empty one.
        case readFailed(Scope)

        public var description: String {
            switch self {
            case .denied(let scope):
                "access to \(scope.rawValue) was denied. Grant it in System Settings › Privacy & Security."
            case .needsFirstGrant(let scope):
                "\(scope.rawValue) has not been allowed yet, and a scheduled sync will not raise a permission prompt with nobody watching. Sync it once from the Sources screen to answer the prompt."
            case .readFailed(let scope):
                "EventKit returned no list for \(scope.rawValue), so nothing was read and the sync date did not move. The next sync tries again."
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
            objects = try await reminderObjects(store: store, since: since, log: log)
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

        let entity: EKEntityType = scope == .calendar ? .event : .reminder
        guard try Self.mustRequestAccess(
            status: EKEventStore.authorizationStatus(for: entity), scope: scope, unattended: unattended
        ) else { return }

        let granted: Bool
        switch scope {
        case .calendar: granted = try await store.requestFullAccessToEvents()
        case .reminders: granted = try await store.requestFullAccessToReminders()
        }
        guard granted else { throw AccessError.denied(scope) }
    }

    /// Whether to ask the system for access, or throw why not. Returns false when access is held.
    ///
    /// **An unattended sync never asks.** The request does not return until someone answers the
    /// prompt, so a prompt raised by a scheduled tick with nobody at the Mac held the whole sync
    /// lane until they came back, and every other source went stale behind it.
    static func mustRequestAccess(status: EKAuthorizationStatus, scope: Scope, unattended: Bool) throws -> Bool {
        switch status {
        case .fullAccess:
            return false
        case .denied, .restricted:
            throw AccessError.denied(scope)
        default:
            // Not asked yet, or write-only, which reads nothing.
            if unattended { throw AccessError.needsFirstGrant(scope) }
            return true
        }
    }

    /// What EventKit's reminder fetch answered. Its completion block is documented as "or
    /// potentially nil", and `?? []` turned that into an empty list: a sync that read nothing
    /// reported success and moved the date.
    static func requireRead<Value>(_ read: Value?, scope: Scope) throws -> Value {
        guard let read else { throw AccessError.readFailed(scope) }
        return read
    }

    /// The stretch of calendar a sync reads. Always the whole look-back.
    ///
    /// `since` is when OpenCore last looked, and a calendar's predicate selects by when an event
    /// *happens*. Using one as the other meant an event from before the last sync was never
    /// looked at again: 450 of the 565 events on the real store have not been revisited since
    /// 2026-08-14, so they never gained `attendees_accepted` and every comment promising that
    /// a re-sync fills it in was false. `since` now filters by modification instead.
    static func window(now: Date, lookBack: TimeInterval, lookAhead: TimeInterval) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-lookBack), end: now.addingTimeInterval(lookAhead))
    }

    /// Whether an event needs re-reading. Unknown modification dates are re-read, because
    /// skipping on a date nobody recorded would lose the change silently.
    static func changed(lastModified: Date?, since: Date?) -> Bool {
        guard let since, let lastModified else { return true }
        return lastModified >= since
    }

    /// Whether a calendar event needs re-reading: it changed, or nobody has been able to see it.
    ///
    /// A modification date alone has a hole. An event made months ago that has just entered the
    /// look-ahead was past the end of the window at the last sync, so it was never read, and its
    /// old modification date would keep it from ever being read. So anything starting beyond the
    /// last sync's window counts as new. A wider look-back or look-ahead setting reaches events
    /// this cannot see, which is what Re-read Whole Calendar is for.
    static func shouldRead(lastModified: Date?, start: Date?, since: Date?, lookAhead: TimeInterval) -> Bool {
        if changed(lastModified: lastModified, since: since) { return true }
        guard let since, let start else { return false }
        return start >= since.addingTimeInterval(lookAhead)
    }

    private func calendarObjects(store: EKEventStore, since: Date?, log: @Sendable (String) -> Void) async throws -> [CoreObject] {
        let span = Self.window(now: Date(), lookBack: lookBack, lookAhead: lookAhead)
        let start = span.start
        let end = span.end

        // EventKit caps a single predicate at roughly four years, so long ranges are
        // fetched in yearly windows rather than silently truncated.
        var objects: [CoreObject] = []
        var windowStart = start
        let formatter = ISO8601DateFormatter()

        while windowStart < end {
            let windowEnd = min(end, windowStart.addingTimeInterval(365 * 86_400))
            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)

            for event in store.events(matching: predicate)
            where Self.shouldRead(lastModified: event.lastModifiedDate, start: event.startDate, since: since, lookAhead: lookAhead) {
                var text = event.title ?? "(untitled event)"
                if let location = event.location, !location.isEmpty { text += "\nLocation: \(location)" }
                if let notes = event.notes, !notes.isEmpty { text += "\n\(notes)" }
                if let attendees = event.attendees, !attendees.isEmpty {
                    // Who accepted, not who was invited. Listing every invitee put 4,004 names
                    // into one object: 78,722 characters across 31 chunks of nothing but a
                    // distribution list, competing in BM25 against real content. The invited
                    // count says the same thing in four characters.
                    //
                    // Capped and *stated*, never silently truncated: a list that quietly stops
                    // reads as a complete one.
                    let accepted = attendees.filter { $0.participantStatus == .accepted }.compactMap(\.name)
                    if !accepted.isEmpty {
                        text += "\nAttended: " + accepted.prefix(Self.namesInText).joined(separator: ", ")
                        if accepted.count > Self.namesInText {
                            text += ", and \(accepted.count - Self.namesInText) more"
                        }
                    }
                    text += "\nInvited: \(attendees.count), accepted: \(accepted.count)"
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
                        //
                        // The full invite list stays here even when it is long. Objects are the
                        // floor and this is what the calendar actually said; it is the *text*
                        // above that stopped carrying every name, because text is what gets
                        // chunked and retrieved.
                        let named = (event.attendees ?? []).compactMap(\.name).filter { !$0.isEmpty }
                        if !named.isEmpty { data["attendees"] = named.joined(separator: "\u{1F}") }

                        // **Who accepted.** `EKParticipant.participantStatus` was being dropped
                        // on the floor, and it is the only field that separates a person you
                        // met from a person who received an invitation. Without it the
                        // extractor asserted `met_with` at `.observed` for everyone on the
                        // list: measured 2026-08-14, a company-wide yoga invite produced 4,004
                        // claims saying the user had met those people, and 9 broadcast events
                        // produced 5,175 of 5,216 met_with claims in the whole store.
                        //
                        // Written even when empty, deliberately. An absent key means "this
                        // object predates the field and nobody looked"; an empty one means "we
                        // looked and nobody accepted". The extractor must be able to tell those
                        // apart, or not knowing who accepted silently becomes everyone did.
                        //
                        // `.accepted` only. `.tentative` and `.pending` are exactly the
                        // maybe that this claim must not resolve into a yes.
                        let accepted = (event.attendees ?? [])
                            .filter { $0.participantStatus == .accepted }
                            .compactMap(\.name)
                            .filter { !$0.isEmpty }
                        data["attendees_accepted"] = accepted.joined(separator: "\u{1F}")
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

    private struct RemindersRead: Sendable {
        var objects: [CoreObject]
        var total: Int
    }

    private func reminderObjects(store: EKEventStore, since: Date?, log: @Sendable (String) -> Void) async throws -> [CoreObject] {
        let predicate = store.predicateForReminders(in: nil)
        let sourceID = source.id

        // `EKReminder` is not Sendable, so the mapping to `CoreObject` happens *inside*
        // the callback. Returning the EKReminders and mapping afterwards would move
        // reference types across an isolation boundary, which Swift 6 correctly rejects.
        //
        // `since` filters by modification, as a calendar does. Without it every hourly sync
        // handed all 5,371 reminders to `IngestPipeline.run`, which derives from everything it
        // is given whether or not it changed.
        let answer: RemindersRead? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: nil)
                    return
                }
                let formatter = ISO8601DateFormatter()
                let changed = reminders.filter { Self.changed(lastModified: $0.lastModifiedDate, since: since) }
                let mapped = changed.map { reminder -> CoreObject in
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
                continuation.resume(returning: RemindersRead(objects: mapped, total: reminders.count))
            }
        }

        let read = try Self.requireRead(answer, scope: .reminders)
        log("reminders: \(read.objects.count) changed of \(read.total) (\(read.objects.filter { $0.metadata["completed"] == "true" }.count) completed)")
        return read.objects
    }
}
