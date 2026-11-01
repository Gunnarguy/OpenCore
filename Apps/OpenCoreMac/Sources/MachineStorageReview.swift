import CoreTelemetry
import Foundation

struct MachineStorageLocation: Identifiable, Sendable {
    var id: String { url.path }
    let title: String
    let url: URL
    let bytes: Int64?
    let isPresent: Bool
    let note: String?
}

enum MachineStorageReview {
    /// Metadata-only sizes of known app-owned locations. No cleanup, model loads or file reads.
    static func measure() async throws -> [MachineStorageLocation] {
        let worker = Task.detached(priority: .utility) {
            let hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Local Automation Hub")
            let locations: [(String, URL)] = [
                ("Downloaded models", hub.appendingPathComponent("models")),
                ("Vision runtime", hub.appendingPathComponent("runtime-vision")),
                ("Text runtime", hub.appendingPathComponent("runtime")),
                ("Model runtime helpers", hub.appendingPathComponent("helpers")),
                ("Temporary engine build", URL(fileURLWithPath: "/private/tmp/opencore-build")),
                ("Temporary app build", URL(fileURLWithPath: "/private/tmp/opencore-review-dd")),
                ("Previous app versions", URL(fileURLWithPath: "/private/tmp/OpenCore-app-backups")),
            ]
            return try locations.map { title, url in
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return MachineStorageLocation(title: title, url: url, bytes: nil, isPresent: false, note: "Not present")
                }
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    return MachineStorageLocation(title: title, url: url, bytes: nil, isPresent: true, note: "Linked location; size not measured")
                }
                do {
                    let result = try BoundedProcess.run(executable: "/usr/bin/du", arguments: ["-sk", url.path],
                        environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 8, maximumOutputBytes: 4096)
                    guard !result.timedOut, result.status == 0,
                          let first = result.stdoutText.split(whereSeparator: { $0.isWhitespace }).first,
                          let kib = Int64(first), kib >= 0, kib <= Int64.max / 1024 else {
                        return MachineStorageLocation(title: title, url: url, bytes: nil, isPresent: true,
                            note: result.timedOut ? "Size check timed out; refresh to retry" : "Size could not be measured")
                    }
                    return MachineStorageLocation(title: title, url: url, bytes: kib * 1024, isPresent: true, note: nil)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    return MachineStorageLocation(title: title, url: url, bytes: nil, isPresent: true, note: "Size could not be measured")
                }
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
