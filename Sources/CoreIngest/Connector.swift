import CoreModel
import Foundation

/// What a connector hands back after a sync pass.
public struct ConnectorBatch: Sendable {
    public var objects: [CoreObject]
    /// Opaque resume token stored on the source, so the next sync can be incremental.
    public var cursor: String?

    public init(objects: [CoreObject], cursor: String? = nil) {
        self.objects = objects
        self.cursor = cursor
    }
}

/// A source of objects.
///
/// Connectors produce `CoreObject`s and nothing else. They never write claims, never touch
/// entities, and never decide what anything means. That separation is what keeps the
/// derived layers rebuildable: if claim extraction is wrong, it gets rerun over objects
/// already on disk rather than requiring a re-fetch from a rate-limited API.
public protocol Connector: Sendable {
    var source: Source { get }
    func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch
}

public enum ConnectorError: Error, CustomStringConvertible {
    case missingCredential(String)
    case http(status: Int, body: String)
    case decode(String)

    public var description: String {
        switch self {
        case .missingCredential(let hint): "missing credential: \(hint)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(300))"
        case .decode(let message): "could not decode response: \(message)"
        }
    }
}
