import CoreModel
import Foundation

/// Local documents: notes, specs, exports, code.
///
/// The design decision that matters is **domain per root**. A folder is the coarsest
/// honest signal about what kind of thing is inside it, and asking once per folder is far
/// more reliable than classifying ten thousand files individually. `~/Documents/Medical`
/// tagged `.medical` means those files are unreachable from a project query no matter how
/// well they match, which is the firewall doing its job on the data most worth firewalling.
public struct FilesystemConnector: Connector {
    public let source: Source
    private let roots: [Root]
    private let maximumFileSize: Int

    public struct Root: Sendable {
        public let url: URL
        public let domain: Domain
        public let authority: Authority

        public init(url: URL, domain: Domain, authority: Authority = .authoredArtifact) {
            self.url = url
            self.domain = domain
            self.authority = authority
        }
    }

    /// Extensions worth reading as text. Binary formats that need extraction (PDF, docx)
    /// are listed in `Docs/ROADMAP.md` rather than half-handled here: a PDF read as UTF-8
    /// produces plausible-looking garbage that then gets embedded and cited.
    public static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "rtf", "org", "rst",
        "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm",
        "json", "yaml", "yml", "toml", "sql", "sh", "zsh", "html", "css",
    ]

    public static let skippedDirectories: Set<String> = [
        ".git", ".git.nosync", "node_modules", ".build", "DerivedData", "Pods", "build",
        ".venv", "venv", "__pycache__", ".next", "dist", "vendor", "Carthage", ".swiftpm",
    ]

    public init(handle: String, roots: [Root], maximumFileSize: Int = 2_000_000) {
        self.roots = roots
        self.maximumFileSize = maximumFileSize
        self.source = Source(
            kind: .filesystem,
            handle: handle,
            displayName: "Files · \(handle)",
            defaultAuthority: .authoredArtifact,
            // Per-object domain comes from the root that produced it; this is only the
            // fallback for a source with no roots configured.
            defaultDomain: .personal
        )
    }

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        var objects: [CoreObject] = []
        let manager = FileManager.default

        for root in roots {
            var seen = 0
            var skippedLarge = 0
            var skippedBinary = 0

            guard let enumerator = manager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                log("could not read \(root.url.path)")
                continue
            }

            // `nextObject()` rather than `for case let url as URL in enumerator`:
            // DirectoryEnumerator's Sequence conformance is unavailable from async
            // contexts, because its iterator is not Sendable.
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])

                if values?.isDirectory == true {
                    if Self.skippedDirectories.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard Self.textExtensions.contains(url.pathExtension.lowercased()) else {
                    skippedBinary += 1
                    continue
                }
                if let size = values?.fileSize, size > maximumFileSize {
                    skippedLarge += 1
                    continue
                }

                let modified = values?.contentModificationDate
                // Incremental sync: skip anything untouched since the last pass. The
                // content hash in the store is the backstop for a file whose mtime lies.
                if let since, let modified, modified < since { continue }

                guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
                    skippedBinary += 1
                    continue
                }

                objects.append(CoreObject(
                    sourceID: source.id,
                    kind: .file,
                    externalID: url.path,
                    title: url.lastPathComponent,
                    text: text,
                    uri: url.absoluteString,
                    authoredAt: modified,
                    domain: root.domain,
                    authority: root.authority,
                    metadata: [
                        "root": root.url.path,
                        "extension": url.pathExtension.lowercased(),
                        "relative_path": url.path.replacingOccurrences(of: root.url.path + "/", with: ""),
                    ]
                ))
                seen += 1
            }

            log("\(root.url.lastPathComponent) [\(root.domain.rawValue)]: \(seen) files, \(skippedBinary) non-text, \(skippedLarge) oversized")
        }

        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
    }
}
