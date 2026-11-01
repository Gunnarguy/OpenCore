import Foundation

/// A failed or inconsistent filesystem measurement stays unknown rather than becoming zero free.
public struct DiskSpaceReading: Sendable, Equatable {
    public let freeBytes: Double?
    public let totalBytes: Double?

    public init(freeBytes: Double?, totalBytes: Double?) {
        if let freeBytes, let totalBytes,
           freeBytes.isFinite, totalBytes.isFinite,
           freeBytes >= 0, totalBytes > 0, freeBytes <= totalBytes {
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
        } else {
            self.freeBytes = nil
            self.totalBytes = nil
        }
    }

    public var freeGiB: Double? { freeBytes.map { $0 / 1_073_741_824 } }
    public var totalGiB: Double? { totalBytes.map { $0 / 1_073_741_824 } }
    public var usedPercent: Int? {
        guard let freeBytes, let totalBytes else { return nil }
        return Int(((totalBytes - freeBytes) / totalBytes * 100).rounded())
    }

    public func isLow(thresholdGiB: Double) -> Bool {
        guard let freeGiB, thresholdGiB.isFinite, thresholdGiB >= 0 else { return false }
        return freeGiB < thresholdGiB
    }
}
