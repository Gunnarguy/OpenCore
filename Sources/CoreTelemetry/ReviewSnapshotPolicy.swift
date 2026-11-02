import Foundation

/// Admission for the separate internal review executable. Invalid input never falls back to
/// production startup or a default store. The supplied private copy is opened read-only later.
public enum ReviewSnapshotPolicy {
    public static let bundleIdentifier = "com.gunndamental.OpenCore.Review"
    public static let snapshotRoot = URL(fileURLWithPath: "/private/tmp/opencore-review-snapshots", isDirectory: true)

    public enum Refusal: String, Error, CustomStringConvertible {
        case wrongIdentity = "review requires its separate bundle identity"
        case arguments = "supply exactly --review-store followed by a snapshot path"
        case root = "the review snapshot root must be a private, ordinary directory"
        case outsideRoot = "the snapshot must be inside the dedicated review root"
        case file = "the snapshot must be an existing, ordinary file"
        case link = "symlinked or hard-linked snapshots are refused"
        case sidecar = "review requires a self-contained snapshot without SQLite sidecars"
        public var description: String { rawValue }
    }

    /// A mistaken review launch of the normal app must stop before its model is constructed.
    public static func requireProductionArguments(_ arguments: [String]) throws {
        guard !arguments.contains(where: { $0.hasPrefix("--review") }) else { throw Refusal.wrongIdentity }
    }

    public static func snapshot(arguments: [String], bundleID: String?, root: URL = snapshotRoot) throws -> URL {
        guard bundleID == bundleIdentifier else { throw Refusal.wrongIdentity }
        guard arguments.count == 2, arguments[0] == "--review-store", arguments[1].hasPrefix("/") else { throw Refusal.arguments }
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              (try? fm.destinationOfSymbolicLink(atPath: root.path)) == nil else { throw Refusal.root }
        let requested = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path.hasPrefix(canonicalRoot.path + "/") else { throw Refusal.outsideRoot }
        guard (try? fm.destinationOfSymbolicLink(atPath: requested.path)) == nil else { throw Refusal.link }
        guard let file = try? fm.attributesOfItem(atPath: canonical.path),
              file[.type] as? FileAttributeType == .typeRegular else { throw Refusal.file }
        guard let references = file[.referenceCount] as? NSNumber, references.intValue == 1 else { throw Refusal.link }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = canonical.path + suffix
            if fm.fileExists(atPath: sidecar) || (try? fm.destinationOfSymbolicLink(atPath: sidecar)) != nil {
                throw Refusal.sidecar
            }
        }
        return canonical
    }
}
