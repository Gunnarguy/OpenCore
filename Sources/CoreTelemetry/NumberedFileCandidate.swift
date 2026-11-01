import Foundation

/// A filename match is a review candidate, not proof of an iCloud conflict or of authorship.
public struct NumberedFileCandidate: Sendable, Equatable {
    public static let suffixes = [" 2.swift", " 2.md", " 2.py", " 2.ts", " 2.js", " 3.swift"]
    public let numberedURL: URL
    public let relatedURL: URL

    public init?(relativePath: String, root: URL) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              let suffix = Self.suffixes.first(where: { relativePath.hasSuffix($0) }) else { return nil }
        let numbered = root.appendingPathComponent(relativePath).standardizedFileURL
        let relatedName = String(numbered.lastPathComponent.dropLast(suffix.count)) + "." + numbered.pathExtension
        guard !relatedName.hasPrefix(".") else { return nil }
        let related = numbered.deletingLastPathComponent().appendingPathComponent(relatedName)
        // Foundation may leave a parent symlink unresolved when the final file is absent.
        // Reject symlinks component by component, including a missing counterpart's leaf.
        for target in [numbered, related] {
            var current = root
            let relative = target.path.dropFirst(root.standardizedFileURL.path.count + 1)
            for component in relative.split(separator: "/") {
                current.appendPathComponent(String(component))
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else { return nil }
            }
        }
        let boundary = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard [numbered, related].allSatisfy({ $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(boundary) }) else { return nil }
        numberedURL = numbered
        relatedURL = related
    }
}
