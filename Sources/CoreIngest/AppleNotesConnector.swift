import CoreModel
import CoreTelemetry
import Foundation

/// Apple Notes, via AppleScript.
///
/// Notes has no public API. AppleScript is the only supported way in, and it is genuinely
/// unpleasant: it needs an Automation grant, it is slow on large libraries, and Apple has
/// changed the dictionary between releases before.
///
/// All of that mess is confined to this one file **on purpose**. It sits behind the same
/// `Connector` protocol as everything else, so when Notes eventually gets a real API, or
/// when this breaks on some future macOS, exactly one file changes and nothing downstream
/// knows the difference. Fragility you cannot avoid should at least be fragility you can
/// point at.
public struct AppleNotesConnector: Connector {
    public let source: Source
    private let includeBodies: Bool
    private let timeout: TimeInterval

    /// - Parameter timeout: seconds before Notes is given up on. 300 is a chosen ceiling, not a
    ///   measurement: AppleScript builds its reply a note at a time, and this has never been
    ///   timed on the real library because no sync has ever returned a record.
    public init(includeBodies: Bool = true, timeout: TimeInterval = 300) {
        self.includeBodies = includeBodies
        self.timeout = timeout
        self.source = Source(
            kind: .manual,
            handle: "apple-notes",
            displayName: "Apple Notes",
            // A note is the user writing to themselves, which is a stronger signal about
            // what they think than a commit message, and weaker than telling OpenCore
            // something directly.
            defaultAuthority: .authoredArtifact,
            defaultDomain: .personal
        )
    }

    public enum NotesError: Error, CustomStringConvertible {
        case automationDenied
        case scriptFailed(String)
        case timedOut
        /// Notes answered and nothing usable came back. Never a success: an empty result used
        /// to read as "already up to date" and set the sync date.
        case noRecords(reported: Int, failed: Int, locked: Int)
        case replyTooLarge(Int)

        public var description: String {
            switch self {
            case .automationDenied:
                "Automation access to Notes was denied. Grant it in System Settings › Privacy & Security › Automation."
            case .scriptFailed(let message):
                "AppleScript failed: \(message)"
            case .timedOut:
                "Notes did not respond in time. Large libraries can exceed the timeout; raise it or narrow the sync."
            case .noRecords(let reported, let failed, let locked):
                // Says nothing about where the next sync starts, because that depends on what the
                // source already held. Only "the date did not move" is true every time.
                "Notes returned no readable notes (it reported \(reported): \(failed) failed to read and \(locked) are locked). Nothing was recorded and the sync date did not move. Check that Notes opens and that OpenCore is allowed under Privacy & Security › Automation."
            case .replyTooLarge(let bytes):
                "Notes returned more than \(bytes) bytes, so the reply may be cut off. Nothing was recorded."
            }
        }
    }

    /// Field and record separators chosen from the C0 control block because they cannot
    /// occur in note text. Splitting on a comma or a newline here would corrupt every
    /// note that contains one, which is all of them.
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        // The header record says how many notes Notes reported, how many could not be read and how
        // many are locked. Without it a `try` block that fails on every note produces the same
        // empty reply as a library with nothing in it, and the two are not the same result.
        //
        // A locked note is counted and left alone, before anything of it is read. `password
        // protected` is in Notes.sdef (macOS 27, read 2026-10-31). Someone locked it, so it is not
        // ours to carry into a store, and no retry can read it: left to the `on error` branch it
        // might fail on every pass and hold the sync date for good.
        let script = """
        set fieldSep to (ASCII character 31)
        set recordSep to (ASCII character 30)
        set output to ""
        set failedCount to 0
        set lockedCount to 0
        tell application "Notes"
            set reportedCount to count of notes
            repeat with theNote in notes
                try
                    if password protected of theNote then
                        set lockedCount to lockedCount + 1
                    else
                        set noteID to id of theNote as string
                        set noteName to name of theNote as string
                        set noteFolder to name of container of theNote as string
                        set noteModified to (modification date of theNote) as «class isot» as string
                        set noteBody to \(includeBodies ? "plaintext of theNote as string" : "\"\"")
                        set output to output & noteID & fieldSep & noteName & fieldSep & noteFolder & fieldSep & noteModified & fieldSep & noteBody & recordSep
                    end if
                on error
                    set failedCount to failedCount + 1
                end try
            end repeat
        end tell
        return "\(Self.headerMarker)" & fieldSep & reportedCount & fieldSep & failedCount & fieldSep & lockedCount & recordSep & output
        """

        log("asking Notes for its library (this can take a while, and needs an Automation grant)")
        let raw = try run(script: script)
        let parsed = try Self.parse(raw, sourceID: source.id, since: since)
        log("notes: \(parsed.objects.count) notes\(parsed.skipped > 0 ? ", \(parsed.skipped) unparseable records skipped" : "")\(parsed.failed > 0 ? ", \(parsed.failed) unreadable" : "")\(parsed.locked > 0 ? ", \(parsed.locked) locked and left out" : "")")
        return parsed.batch(cursor: ISO8601DateFormatter().string(from: Date()))
    }

    /// Marks the header record, so an older reply shape cannot be mistaken for it.
    private static let headerMarker = "OPENCORE_NOTES_V1"

    struct Parsed: Sendable {
        var objects: [CoreObject]
        var reported: Int
        var failed: Int
        var skipped: Int
        /// Notes with a usable record, including any older than `since`.
        var read: Int = 0
        /// Left out on purpose, so unlike `failed` these never hold the sync date.
        var locked: Int = 0

        /// What these notes come to as a sync result.
        ///
        /// Everything here is something a later read could still fetch. The bug: only a reply with
        /// nothing in it counted as a failure, so reading 1 of 3,000 notes moved the date, and the
        /// other 2,999 fell behind `modified < since` until someone edited them.
        ///
        /// A note that fails every time holds the date every time. That only costs comparing notes
        /// already stored, because this connector reads the whole library on every pass anyway.
        func batch(cursor: String? = nil) -> ConnectorBatch {
            var unread: [String] = []
            if failed > 0 { unread.append("\(failed) of \(reported) notes could not be read.") }
            if skipped > 0 { unread.append("\(skipped) notes came back in a form that could not be parsed.") }
            let unaccounted = reported - read - failed - skipped - locked
            if unaccounted > 0 { unread.append("\(unaccounted) of the \(reported) notes reported never arrived.") }
            return ConnectorBatch(objects: objects, cursor: cursor, unread: unread)
        }
    }

    /// Split one reply from Notes into objects. Throws rather than returning nothing.
    ///
    /// A reply with no usable record is a failure unless an incremental sync legitimately found
    /// nothing changed: `since` is set, notes were read, and all of them were older.
    static func parse(_ raw: String, sourceID: SourceID, since: Date?) throws -> Parsed {
        var records = raw.components(separatedBy: recordSeparator)
        var reported = 0
        var failed = 0
        var locked = 0
        let header = records.first?.components(separatedBy: fieldSeparator) ?? []
        if header.count >= 3, header[0].trimmingCharacters(in: .whitespacesAndNewlines) == headerMarker {
            reported = Int(header[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            failed = Int(header[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if header.count >= 4 { locked = Int(header[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
            records.removeFirst()
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone.current

        var objects: [CoreObject] = []
        var skipped = 0
        var read = 0

        for record in records {
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 4 else {
                if !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skipped += 1 }
                continue
            }

            let identifier = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { skipped += 1; continue }
            read += 1

            let title = fields[1]
            let folder = fields[2]
            let modified = formatter.date(from: fields[3].trimmingCharacters(in: .whitespacesAndNewlines))
            let body = fields.count > 4 ? fields[4] : ""

            if let since, let modified, modified < since { continue }

            objects.append(CoreObject(
                sourceID: sourceID,
                kind: .note,
                externalID: identifier,
                title: title.isEmpty ? "(untitled note)" : title,
                text: body.isEmpty ? title : "\(title)\n\n\(body)",
                uri: nil,
                authoredAt: modified,
                // Folder name is the only domain signal Notes offers. A folder called
                // "Medical" is a strong one and worth honouring.
                domain: Self.domain(forFolder: folder),
                authority: .authoredArtifact,
                metadata: ["folder": folder]
            ))
        }

        if read == 0 { throw NotesError.noRecords(reported: reported, failed: failed, locked: locked) }
        return Parsed(objects: objects, reported: reported, failed: failed, skipped: skipped, read: read, locked: locked)
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
    /// The word lists are chosen, not measured: no sync has ever returned a real folder name.
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

    /// Reply ceiling. **Chosen:** far above a text-only library, there so a runaway reply fails
    /// loudly instead of being cut off into a partial sync that looks complete.
    private static let maximumReplyBytes = 256 * 1024 * 1024

    private func run(script: String) throws -> String {
        // Bounded: `timeout` was stored and never used, so a Notes that never answered hung the
        // sync forever and `.timedOut` was unreachable.
        let result = try BoundedProcess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: timeout,
            maximumOutputBytes: Self.maximumReplyBytes
        )
        if result.timedOut { throw NotesError.timedOut }
        guard result.status == 0 else {
            let message = result.stderrText
            // -1743 is the TCC denial code for Automation.
            if message.contains("-1743") || message.lowercased().contains("not authorized") {
                throw NotesError.automationDenied
            }
            throw NotesError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if result.stdout.count >= Self.maximumReplyBytes { throw NotesError.replyTooLarge(Self.maximumReplyBytes) }
        return result.stdoutText
    }
}
