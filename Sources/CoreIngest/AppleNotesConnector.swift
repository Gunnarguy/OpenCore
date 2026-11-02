import CoreModel
import CoreTelemetry
import Foundation

/// Apple Notes' Automation adapter. Produces floor objects only; interpretation stays downstream.
public struct AppleNotesConnector: Connector {
    public let source: Source
    private let includeBodies: Bool
    private let timeout: TimeInterval

    /// 300 seconds is a chosen overall ceiling, not a measured library completion time.
    public init(includeBodies: Bool = true, timeout: TimeInterval = 300) {
        self.includeBodies = includeBodies
        self.timeout = timeout
        source = Source(kind: .manual, handle: "apple-notes", displayName: "Apple Notes",
                        defaultAuthority: .authoredArtifact, defaultDomain: .personal)
    }

    public enum NotesError: Error, CustomStringConvertible {
        case automationDenied
        case scriptFailed(String)
        case timedOut
        case eventTimedOut
        case invalidTimeout
        case invalidReply(String)
        case noRecords(reported: Int, failed: Int, locked: Int)
        case failedRead(reported: Int, failed: Int, locked: Int, timedOutEvents: Int, deniedEvents: Int)
        case replyTooLarge(Int)

        public var description: String {
            switch self {
            case .automationDenied:
                "Automation access to Notes was denied. Grant it in System Settings › Privacy & Security › Automation."
            case .scriptFailed(let message):
                "AppleScript failed: \(message)"
            case .timedOut:
                "The Notes reader exceeded its overall time limit. Nothing was recorded and the sync date did not move."
            case .eventTimedOut:
                "Notes timed out answering an Apple Event. Nothing was recorded and the sync date did not move."
            case .invalidTimeout:
                "The Notes time limit must be finite, positive and no greater than 2147483647 seconds."
            case .invalidReply(let reason):
                "Notes returned an invalid reply (\(reason)). Nothing was recorded and the sync date did not move."
            case .noRecords(let reported, let failed, let locked):
                "Notes returned no readable notes (it reported \(reported): \(failed) failed to read and \(locked) are locked). Nothing was recorded and the sync date did not move. Check that Notes opens and that OpenCore is allowed under Privacy & Security › Automation."
            case .failedRead(let reported, let failed, let locked, let timeouts, let denied):
                NotesError.noRecords(reported: reported, failed: failed, locked: locked).description
                    + " Apple Event timeouts: \(timeouts); Automation denials: \(denied)."
            case .replyTooLarge(let bytes):
                "The Notes reply reached the \(bytes)-byte safety limit and may be cut off. Nothing was recorded and the sync date did not move."
            }
        }
    }

    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"
    private static let escape = "\u{1D}"
    // Chosen ceiling; saturation fails closed even if the child also exits with an error.
    private static let maximumReplyBytes = 256 * 1024 * 1024

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        let script = try Self.readerScript(includeBodies: includeBodies, timeout: timeout)
        log("asking Notes for its library (this can take a while, and needs an Automation grant)")
        let parsed = try await Self.readOffMain(sourceID: source.id, since: since) {
            let result = try BoundedProcess.run(executable: "/usr/bin/osascript", arguments: ["-e", script],
                                                timeout: timeout, maximumOutputBytes: Self.maximumReplyBytes)
            return try Self.processReply(status: result.status, stdout: result.stdout, stderr: result.stderr,
                                         timedOut: result.timedOut, limit: Self.maximumReplyBytes)
        }
        log("notes: \(parsed.objects.count) notes, \(parsed.failed) unreadable, \(parsed.skipped) unparseable, \(parsed.locked) locked and left out")
        return parsed.batch(cursor: ISO8601DateFormatter().string(from: Date()))
    }

    /// Blocking process and parsing work leave the caller's actor. Parent cancellation reaches
    /// BoundedProcess, which terminates only the child it started, and never publishes a batch.
    static func readOffMain(sourceID: SourceID, since: Date?, read: @escaping @Sendable () throws -> String) async throws -> Parsed {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let raw = try read()
            try Task.checkCancellation()
            return try parse(raw, sourceID: sourceID, since: since)
        }
        return try await withTaskCancellationHandler {
            let parsed = try await worker.value
            try Task.checkCancellation()
            return parsed
        } onCancel: { worker.cancel() }
    }

    // Shared by the actual reader and synthetic-only AppleScript tests. None of these handlers
    // targets an application. Escape the escape byte first, then the field/record separators.
    static let wireHandlers = """
    on replaceText(value, oldText, newText)
        set savedDelimiters to AppleScript's text item delimiters
        try
            considering case
                set AppleScript's text item delimiters to oldText
                set pieces to text items of value
                set AppleScript's text item delimiters to newText
                set joinedText to pieces as string
            end considering
            set AppleScript's text item delimiters to savedDelimiters
            return joinedText
        on error errorMessage number errorNumber
            set AppleScript's text item delimiters to savedDelimiters
            error errorMessage number errorNumber
        end try
    end replaceText

    on wireField(value)
        set escapeByte to ASCII character 29
        set value to my replaceText(value as string, escapeByte, escapeByte & "E")
        set value to my replaceText(value, ASCII character 31, escapeByte & "F")
        return my replaceText(value, ASCII character 30, escapeByte & "R")
    end wireField

    on wireRecord(values)
        set encodedFields to {}
        repeat with value in values
            set end of encodedFields to my wireField(contents of value)
        end repeat
        set savedDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to ASCII character 31
        set encodedRecord to encodedFields as string
        set AppleScript's text item delimiters to savedDelimiters
        return encodedRecord & (ASCII character 30)
    end wireRecord

    on wireReply(reportedCount, failedCount, lockedCount, timeoutCount, deniedCount, noteRecords)
        set savedDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to ""
        set output to noteRecords as string
        set AppleScript's text item delimiters to savedDelimiters
        return my wireRecord({"OPENCORE_NOTES_V2", reportedCount, failedCount, lockedCount, timeoutCount, deniedCount}) & output
    end wireReply
    """

    static func readerScript(includeBodies: Bool, timeout: TimeInterval) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout <= Double(Int32.max) else { throw NotesError.invalidTimeout }
        // AppleScript's timeout applies per Apple Event, not to the whole script. The child
        // process has the separate overall deadline above. Current Apple docs checked 2026-10-31.
        let eventSeconds = max(1, Int(timeout.rounded(.up)))
        return wireHandlers + "\n" + """
        set noteRecords to {}
        set failedCount to 0
        set lockedCount to 0
        set timeoutCount to 0
        set deniedCount to 0
        with timeout of \(eventSeconds) seconds
            tell application "Notes"
                set reportedCount to count of notes
                repeat with theNote in notes
                    try
                        -- password protected is in the macOS 27 Notes dictionary, checked 2026-10-31.
                        -- Count locked notes before reading their contents; never attempt to unlock.
                        if password protected of theNote then
                            set lockedCount to lockedCount + 1
                        else
                            set noteID to id of theNote as string
                            set noteName to name of theNote as string
                            set noteFolder to name of container of theNote as string
                            set noteModified to (modification date of theNote) as «class isot» as string
                            set noteBody to \(includeBodies ? "plaintext of theNote as string" : "\"\"")
                            set end of noteRecords to my wireRecord({noteID, noteName, noteFolder, noteModified, noteBody})
                        end if
                    on error errorMessage number errorNumber
                        set failedCount to failedCount + 1
                        if errorNumber is -1712 then set timeoutCount to timeoutCount + 1
                        if errorNumber is -1743 then set deniedCount to deniedCount + 1
                    end try
                end repeat
            end tell
        end timeout
        return my wireReply(reportedCount, failedCount, lockedCount, timeoutCount, deniedCount, noteRecords)
        """
    }

    struct Parsed: Sendable {
        var objects: [CoreObject]
        var reported: Int
        var failed: Int
        var skipped: Int
        var read: Int
        var locked: Int
        var timedOutEvents: Int
        var deniedEvents: Int

        func batch(cursor: String? = nil) -> ConnectorBatch {
            var unread: [String] = []
            if failed > 0 { unread.append("\(failed) of \(reported) notes could not be read.") }
            if timedOutEvents > 0 { unread.append("\(timedOutEvents) note reads timed out answering Apple Events.") }
            if deniedEvents > 0 { unread.append("\(deniedEvents) note reads were denied Automation access. Check Privacy & Security › Automation.") }
            if skipped > 0 { unread.append("\(skipped) notes came back in a form that could not be parsed.") }
            let unaccounted = reported - failed - locked - read - skipped
            if unaccounted > 0 { unread.append("\(unaccounted) of the \(reported) notes reported never arrived.") }
            return ConnectorBatch(objects: objects, cursor: cursor, unread: unread)
        }
    }

    /// V2 is lossless for control bytes. Strict V1 remains readable for older captured replies,
    /// but never silently truncates extra fields or treats missing/malformed counters as zero.
    static func parse(_ raw: String, sourceID: SourceID, since: Date?) throws -> Parsed {
        var records = raw.components(separatedBy: recordSeparator)
        guard let first = records.first else { throw NotesError.invalidReply("missing header") }
        let header = first.components(separatedBy: fieldSeparator)
        let isV2 = header.first == "OPENCORE_NOTES_V2"
        guard (isV2 && header.count == 6) || (header.first == "OPENCORE_NOTES_V1" && (3...4).contains(header.count)) else {
            throw NotesError.invalidReply("unknown or malformed header")
        }
        func counter(_ text: String) throws -> Int {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text) else {
                throw NotesError.invalidReply("invalid counter")
            }
            return value
        }
        let reported = try counter(header[1]), failed = try counter(header[2])
        let locked = try header.count > 3 ? counter(header[3]) : 0
        let timeouts = try isV2 ? counter(header[4]) : 0
        let denied = try isV2 ? counter(header[5]) : 0
        // Subtractions after bounds checks avoid overflow on hostile counters.
        guard failed <= reported, locked <= reported - failed,
              timeouts <= failed, denied <= failed - timeouts else {
            throw NotesError.invalidReply("inconsistent counters")
        }
        records.removeFirst()
        // osascript adds a terminal newline. Never trim note fields or discard an internal row.
        guard let tail = records.last, ["", "\n", "\r\n"].contains(tail) else {
            throw NotesError.invalidReply("unterminated record")
        }
        records.removeLast()
        let available = reported - failed - locked
        guard records.count <= available else { throw NotesError.invalidReply("more records than reported") }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone.current
        formatter.isLenient = false
        // Notes' ISO coercion has whole-second precision; SourceSync's start date may have
        // fractions. Retain that boundary second so an edit after a read began cannot fall
        // permanently behind its next incremental cutoff.
        let lowerBound = since.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        var objects: [CoreObject] = [], identifiers: Set<String> = []
        var skipped = 0, read = 0
        for record in records {
            try Task.checkCancellation()
            let encoded = record.components(separatedBy: fieldSeparator)
            guard encoded.count == 5, let fields = isV2 ? decodeFields(encoded) : encoded else { skipped += 1; continue }
            let identifier = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { skipped += 1; continue }
            guard identifiers.insert(identifier).inserted else { throw NotesError.invalidReply("duplicate identifier") }
            guard let modified = formatter.date(from: fields[3]), formatter.string(from: modified) == fields[3] else {
                skipped += 1; continue
            }
            read += 1
            if let lowerBound, modified < lowerBound { continue }
            let title = fields[1], folder = fields[2], body = fields[4]
            objects.append(CoreObject(sourceID: sourceID, kind: .note, externalID: identifier,
                                      title: title.isEmpty ? "(untitled note)" : title,
                                      text: body.isEmpty ? title : "\(title)\n\n\(body)",
                                      uri: nil, authoredAt: modified, domain: domain(forFolder: folder),
                                      authority: .authoredArtifact, metadata: ["folder": folder]))
        }
        if read == 0 {
            if timeouts > 0 || denied > 0 {
                throw NotesError.failedRead(reported: reported, failed: failed, locked: locked,
                                            timedOutEvents: timeouts, deniedEvents: denied)
            }
            throw NotesError.noRecords(reported: reported, failed: failed, locked: locked)
        }
        return Parsed(objects: objects, reported: reported, failed: failed, skipped: skipped, read: read,
                      locked: locked, timedOutEvents: timeouts, deniedEvents: denied)
    }

    private static func decodeFields(_ fields: [String]) -> [String]? {
        var decoded: [String] = []
        for field in fields {
            var value = "", escaping = false
            for scalar in field.unicodeScalars {
                if escaping {
                    switch scalar {
                    case "E": value += escape
                    case "F": value += fieldSeparator
                    case "R": value += recordSeparator
                    default: return nil
                    }
                    escaping = false
                } else if scalar == "\u{1D}" { escaping = true }
                else { value.unicodeScalars.append(scalar) }
            }
            guard !escaping else { return nil }
            decoded.append(value)
        }
        return decoded
    }

    /// Pure result classification. Error text may contain note contents, so only a terminal
    /// osascript error number is recognized; arbitrary stderr is never copied into diagnostics.
    static func processReply(status: Int32, stdout: Data, stderr: Data, timedOut: Bool, limit: Int) throws -> String {
        if timedOut { throw NotesError.timedOut }
        if stdout.count >= limit { throw NotesError.replyTooLarge(limit) }
        if status != 0 {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasSuffix("(-1743)") { throw NotesError.automationDenied }
            if message.hasSuffix("(-1712)") { throw NotesError.eventTimedOut }
            throw NotesError.scriptFailed("osascript exited with status \(status).")
        }
        guard let text = String(data: stdout, encoding: .utf8) else { throw NotesError.invalidReply("invalid UTF-8") }
        return text
    }

    /// Folder-name heuristic for domain tagging. Deliberately errs toward the *more*
    /// restrictive domain: over-tagging a note as medical hides it from a project query,
    /// which is a mild annoyance. Under-tagging leaks it into one, which is the failure
    /// the firewall exists to prevent.
    ///
    /// **So the two directions match differently.** A word that closes a note may match anywhere,
    /// which keeps "Healthcare" medical and costs "Syntax" a financial tag. A word that opens a
    /// note to an MCP caller has to be a whole word. Those matched anywhere too, so "Passcodes"
    /// held "code" and "Devices" held "dev" and both came out `.project`, while "Workouts" and
    /// "Homework" came out `.work`. Nothing else reads a folder's name, and `.personal`, where a
    /// name matching nothing lands, is out of an MCP caller's reach.
    ///
    /// The word lists are chosen, not measured against the owner’s library.
    static func domain(forFolder folder: String) -> Domain {
        let lowered = folder.lowercased()
        if ["medical", "health", "doctor", "clinical", "prescriptions"].contains(where: lowered.contains) { return .medical }
        if ["finance", "financial", "money", "tax", "taxes", "banking", "invoices"].contains(where: lowered.contains) { return .financial }
        // Before the opening words, so "Work Passwords" and "Personal Projects" stay closed.
        if ["password", "passcode", "credential", "secret", "login", "private", "personal"].contains(where: lowered.contains) { return .personal }
        let words = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !words.isDisjoint(with: ["work", "job", "jobs", "career", "careers", "employer"]) { return .work }
        if !words.isDisjoint(with: ["project", "projects", "code", "dev", "development", "engineering"]) { return .project }
        return .personal
    }

}
