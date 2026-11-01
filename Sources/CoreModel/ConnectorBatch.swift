import Foundation

/// What a connector hands back after a sync pass.
///
/// Lives here because `SourceSync` takes it whole. It used to copy `objects` and `cursor` across
/// by hand, and a third field would have been dropped at every call site with no error.
public struct ConnectorBatch: Sendable {
    public var objects: [CoreObject]
    /// Opaque resume token stored on the source, so the next sync can be incremental.
    public var cursor: String?
    /// What this read was asked for and could not reach, a sentence each. Empty means it reached
    /// everything. Not empty holds the source's sync date where it was, because connectors skip
    /// `modified < since`, so a date that moved past something unread hides it until it is next
    /// edited. Something left out on purpose does not belong here: it would hold the date forever
    /// and say nothing true.
    public var unread: [String]

    public init(objects: [CoreObject], cursor: String? = nil, unread: [String] = []) {
        self.objects = objects
        self.cursor = cursor
        self.unread = unread
    }
}
