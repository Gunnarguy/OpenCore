import Foundation
import CoreGraphics
import CoreTelemetry

struct ConnectedDisplayModeChoice: Identifiable, Equatable {
    let identity: DisplayModeIdentity

    var id: String { identity.key }
    var modeID: Int32 { identity.modeID }
    var width: Int { identity.width }
    var height: Int { identity.height }
    var pixelWidth: Int { identity.pixelWidth }
    var pixelHeight: Int { identity.pixelHeight }
    var ioFlags: UInt32 { identity.ioFlags }
    var usableForDesktop: Bool { identity.usableForDesktop }
    var refreshRate: Double? {
        let value = Double(bitPattern: identity.refreshRateBits)
        return value.isFinite && value > 0 ? value : nil
    }
    var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }
    var title: String {
        let refresh = refreshRate.map { " @ \($0.formatted(.number.precision(.fractionLength(0...3)))) Hz" } ?? " • refresh not reported"
        let backing = pixelWidth != width || pixelHeight != height ? " • \(pixelWidth) × \(pixelHeight) render pixels" : ""
        return "\(width) × \(height)\(refresh)\(backing)"
    }

    init(_ mode: CGDisplayMode) {
        identity = DisplayModeIdentity(
            modeID: mode.ioDisplayModeID, width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate, ioFlags: mode.ioFlags,
            usableForDesktop: mode.isUsableForDesktopGUI())
    }
}
