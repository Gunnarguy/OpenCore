import Foundation

/// An exact mode identity, not its human-readable (and rounded) label.
public struct DisplayModeIdentity: Equatable, Hashable, Sendable {
    public let modeID: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRateBits: UInt64
    public let ioFlags: UInt32
    public let usableForDesktop: Bool

    public init(modeID: Int32, width: Int, height: Int, pixelWidth: Int,
                pixelHeight: Int, refreshRate: Double, ioFlags: UInt32,
                usableForDesktop: Bool) {
        self.modeID = modeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateBits = refreshRate.bitPattern
        self.ioFlags = ioFlags
        self.usableForDesktop = usableForDesktop
    }

    public var key: String {
        "\(modeID):\(width):\(height):\(pixelWidth):\(pixelHeight):\(refreshRateBits):\(ioFlags):\(usableForDesktop ? 1 : 0)"
    }
}

/// Quartz IDs are revalidated together with hardware identity before any write.
public struct DisplayConnectionIdentity: Equatable, Hashable, Sendable {
    public let displayID: UInt32
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    public let builtIn: Bool

    public init(displayID: UInt32, vendorID: UInt32, productID: UInt32,
                serialNumber: UInt32, builtIn: Bool) {
        self.displayID = displayID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.builtIn = builtIn
    }

    public func isUnambiguous(in online: [Self]) -> Bool {
        guard online.filter({ $0.displayID == displayID }).count == 1,
              online.contains(self) else { return false }
        let peers = online.filter {
            $0.vendorID == vendorID && $0.productID == productID && $0.builtIn == builtIn
        }
        // Missing serials cannot distinguish two same-model displays. A duplicate
        // nonzero serial is equally ambiguous, even with different Quartz IDs.
        return serialNumber == 0 ? peers.count == 1 : peers.filter { $0.serialNumber == serialNumber }.count == 1
    }
}

/// Whether retained originals may be applied without erasing a later outside edit.
public enum DisplayModeRollbackDecision: Equatable, Sendable {
    case restore
    case alreadyRestored
    case connectionsChanged
    case currentConfigurationUnavailable
    case changedOutsidePreview

    public static func evaluate(originalConnections: [DisplayConnectionIdentity],
                                liveConnections: [DisplayConnectionIdentity],
                                previewWasVerified: Bool,
                                currentMatchesPreview: Bool?,
                                currentMatchesOriginal: Bool?) -> Self {
        let original = originalConnections.sorted { $0.displayID < $1.displayID }
        let live = liveConnections.sorted { $0.displayID < $1.displayID }
        guard original == live else { return .connectionsChanged }
        // An initial apply can make the attempted mode unreadable or inactive.
        // Its retained originals are precisely the recovery path; reading the
        // failed current mode must not be a prerequisite for attempting them.
        guard previewWasVerified else { return .restore }
        guard let currentMatchesPreview, let currentMatchesOriginal else {
            return .currentConfigurationUnavailable
        }
        if currentMatchesOriginal { return .alreadyRestored }
        return currentMatchesPreview ? .restore : .changedOutsidePreview
    }
}

/// A monotonic confirmation period that begins after a preview is verified.
public struct DisplayModeConfirmationWindow: Sendable {
    public let deadline: ContinuousClock.Instant

    public init(verifiedAt: ContinuousClock.Instant, duration: Duration) {
        deadline = verifiedAt.advanced(by: duration)
    }

    public func remainingSeconds(at now: ContinuousClock.Instant) -> Int {
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        let whole = Int(clamping: components.seconds)
        return components.attoseconds > 0 && whole < Int.max ? whole + 1 : whole
    }
}
