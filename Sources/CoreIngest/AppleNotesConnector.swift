import CoreModel
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

    public init(includeBodies: Bool = true, timeout: TimeInterval = 120) {
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

        public var description: String {
            switch self {
            case .automationDenied:
                "Automation access to Notes was denied. Grant it in System Settings › Privacy & Security › Automation."
            case .scriptFailed(let message):
                "AppleScript failed: \(message)"
            case .timedOut:
                "Notes did not respond in time. Large libraries can exceed the timeout; raise it or narrow the sync."
            }
        }
    }

    /// Field and record separators chosen from the C0 control block because they cannot
    /// occur in note text. Splitting on a comma or a newline here would corrupt every
    /// note that contains one, which is all of them.
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        let script = """
        set fieldSep to (ASCII character 31)
        set recordSep to (ASCII character 30)
        set output to ""
        tell application "Notes"
            repeat with theNote in notes
                try
                    set noteID to id of theNote as string
                    set noteName to name of theNote as string
                    set noteFolder to name of container of theNote as string
                    set noteModified to (modification date of theNote) as «class isot» as string
                    set noteBody to \(includeBodies ? "plaintext of theNote as string" : "\"\"")
                    set output to output & noteID & fieldSep & noteName & fieldSep & noteFolder & fieldSep & noteModified & fieldSep & noteBody & recordSep
                end try
            end repeat
        end tell
        return output
        """

        log("asking Notes for its library (this can take a while, and needs an Automation grant)")
        let raw = try run(script: script)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone.current

        var objects: [CoreObject] = []
        var skipped = 0

        for record in raw.components(separatedBy: Self.recordSeparator) {
            let fields = record.components(separatedBy: Self.fieldSeparator)
            guard fields.count >= 4 else { skipped += 1; continue }

            let identifier = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { skipped += 1; continue }

            let title = fields[1]
            let folder = fields[2]
            let modified = formatter.date(from: fields[3].trimmingCharacters(in: .whitespacesAndNewlines))
            let body = fields.count > 4 ? fields[4] : ""

            if let since, let modified, modified < since { continue }

            objects.append(CoreObject(
                sourceID: source.id,
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

        log("notes: \(objects.count) notes\(skipped > 0 ? ", \(skipped) unparseable records skipped" : "")")
        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
    }

    /// Folder-name heuristic for domain tagging. Deliberately errs toward the *more*
    /// restrictive domain: over-tagging a note as medical hides it from a project query,
    /// which is a mild annoyance. Under-tagging leaks it into one, which is the failure
    /// the firewall exists to prevent.
    static func domain(forFolder folder: String) -> Domain {
        let lowered = folder.lowercased()
        if ["medical", "health", "doctor", "clinical", "prescriptions"].contains(where: lowered.contains) { return .medical }
        if ["finance", "financial", "money", "tax", "taxes", "banking", "invoices"].contains(where: lowered.contains) { return .financial }
        if ["work", "job", "career", "employer"].contains(where: lowered.contains) { return .work }
        if ["project", "projects", "code", "dev", "engineering"].contains(where: lowered.contains) { return .project }
        return .personal
    }

    private func run(script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // Read concurrently with waiting: a note library larger than the 64KB pipe buffer
        // deadlocks if you wait first and read after.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            // -1743 is the TCC denial code for Automation.
            if message.contains("-1743") || message.lowercased().contains("not authorized") {
                throw NotesError.automationDenied
            }
            throw NotesError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
