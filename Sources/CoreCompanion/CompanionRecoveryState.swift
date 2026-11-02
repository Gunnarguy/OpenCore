import Foundation

/// Session-only recovery information; never persisted to the phone's store or Keychain.
public struct CompanionRecoveryState: Sendable {
    public var pending: (id: UUID, section: CompanionSection)?
    public private(set) var page: CompanionPage?
    public private(set) var epoch = UUID()

    public init(pending: (id: UUID, section: CompanionSection)? = nil, page: CompanionPage? = nil) {
        self.pending = pending
        self.page = page
    }

    public mutating func beginConnection(isNewPairing: Bool) {
        epoch = UUID()
        page = nil
        if isNewPairing { pending = nil }
    }

    public mutating func endSession() {
        epoch = UUID()
        page = nil
    }

    public mutating func publish(_ page: CompanionPage, ifCurrent expected: UUID) {
        guard epoch == expected else { return }
        self.page = page
    }
}
