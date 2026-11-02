#if OPENCORE_REVIEW
import CoreStore
import CoreTelemetry
import Foundation

/// Foundation-only first step of the internal screen-review harness. No production App,
/// AppModel, AppSettings, RootView, menu bar or operator singleton is constructed here.
@main
struct OpenCoreReviewMain {
    static func main() async {
        Telemetry.disable()
        do {
            let path = try ReviewSnapshotPolicy.snapshot(arguments: Array(CommandLine.arguments.dropFirst()),
                                                        bundleID: Bundle.main.bundleIdentifier)
            let store = try await Store.openReadOnlySnapshot(at: path)
            let count = try await store.objectCount()
            // Counts qualify the bootstrap only. They do not certify any rendered screen.
            print("review bootstrap: read-only snapshot opened; objects=\(count); screen review pending")
        } catch {
            FileHandle.standardError.write(Data("Review refused: \(error)\n".utf8))
            exit(2)
        }
    }
}
#endif
