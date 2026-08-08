import AppKit
import CoreStore
import Foundation

extension AppModel {
    /// Export the whole store to a timestamped folder in Downloads.
    ///
    /// Downloads rather than a save panel because the output is a *directory* of files for
    /// JSONL, and asking someone to pick a destination for something they have not seen yet is
    /// worse than putting it somewhere obvious and revealing it in Finder.
    ///
    /// Returns a short summary for the UI, or a description of what went wrong. Errors are
    /// returned rather than thrown to match the convention of every other action on this type.
    func exportStore(format: Exporter.Format) async -> String {
        guard let store else { return "store is not open" }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let name = "OpenCore-export-" + stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let directory = downloads.appendingPathComponent(name, isDirectory: true)

        state = .working("exporting")
        do {
            let outcome = try await Exporter(store: store).export(to: directory, format: format) { [weak self] message in
                Task { @MainActor in self?.state = .working("exporting: \(message)") }
            }
            state = .idle

            let kilobytes = outcome.totalBytes / 1024
            let rows = outcome.files.reduce(0) { $0 + $1.rows }
            NSWorkspace.shared.activateFileViewerSelecting([directory])
            return "\(outcome.files.count) file(s), \(rows) rows, \(kilobytes)KB → Downloads/\(name)"
        } catch {
            state = .failed("export: \(error)")
            return "failed: \(error)"
        }
    }
}
