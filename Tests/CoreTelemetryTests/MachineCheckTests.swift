import CoreTelemetry
import Foundation
import Testing

// Original bug: missing filesystem attributes became zero free, causing a false low-space alert.
@Test("missing or invalid disk readings stay unknown and do not trigger a low-space alert")
func unknownDiskSpaceIsNotZero() {
    for (free, total) in [(nil, nil), (0, nil), (-1, 100), (101, 100), (Double.nan, 100), (0, Double.infinity)] as [(Double?, Double?)] {
        let reading = DiskSpaceReading(freeBytes: free, totalBytes: total)
        #expect(reading.freeGiB == nil && reading.totalGiB == nil && reading.usedPercent == nil)
        #expect(!reading.isLow(thresholdGiB: 25))
    }
}

// Original bug: the warning ignored the threshold exposed in Settings and always used 25 GiB.
@Test("the low-space alert follows the configured threshold and a measured full disk stays valid")
func diskThresholdUsesTheConfiguredValue() {
    let reading = DiskSpaceReading(freeBytes: 10 * 1_073_741_824, totalBytes: 100 * 1_073_741_824)
    #expect(reading.isLow(thresholdGiB: 25))
    #expect(!reading.isLow(thresholdGiB: 5))
    #expect(!reading.isLow(thresholdGiB: 10))
    #expect(reading.usedPercent == 90)
    #expect(DiskSpaceReading(freeBytes: 0, totalBytes: 100).isLow(thresholdGiB: 1))
}

// Original bug: a Swift-only conflict label concealed Markdown/Python matches and no file destination existed.
@Test("numbered review candidates resolve the actual file and its matching unnumbered filename")
func numberedFilesHaveSpecificDestinations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for (numbered, related) in [("Repo/README 2.md", "README.md"), ("Repo/build_portal 2.py", "build_portal.py"), ("Repo/View 3.swift", "View.swift")] {
        let pair = try #require(NumberedFileCandidate(relativePath: numbered, root: root))
        #expect(pair.numberedURL == root.appendingPathComponent(numbered))
        #expect(pair.relatedURL.lastPathComponent == related)
    }
    for bad in ["../README 2.md", "/tmp/README 2.md", "Repo/../README 2.md", "Repo/README.md", "Repo//README 2.md"] {
        #expect(NumberedFileCandidate(relativePath: bad, root: root) == nil)
    }
}

@Test("a numbered-file link cannot escape its scan root through a symbolic link")
func numberedFilesStayInsideTheirScanRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
    #expect(NumberedFileCandidate(relativePath: "outside/README 2.md", root: root) == nil)
}

// Original bug: failed/malformed simulator checks returned [], which the detail view called all-clear.
@Test("a successful empty simulator result differs from malformed or missing device data")
func simulatorFailureIsNotAnEmptySuccess() throws {
    #expect(try SimulatorReading.decode(Data(#"{"devices":{}}"#.utf8)).isEmpty)
    for bad in ["not JSON", "{}", #"{"devices":{"runtime":[{"state":"Booted"}]}}"#] {
        #expect(throws: (any Error).self) { try SimulatorReading.decode(Data(bad.utf8)) }
    }
    let devices = try SimulatorReading.decode(Data(#"{"devices":{"runtime":[{"name":"Phone","udid":"one","state":"Booted"},{"name":"Tablet","udid":"two","state":"Shutdown"}]}}"#.utf8))
    #expect(devices.map(\.udid) == ["one"])
}
