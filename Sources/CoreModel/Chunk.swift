import Foundation

/// A passage of an object.
///
/// The retrieval unit for anything long enough that the whole thing is a bad citation.
/// A commit message is one chunk; a forty-page document is many. Chunks keep their byte
/// offsets into `CoreObject.text` so a hit can always be expanded back into its
/// surrounding context, which is the difference between citing a sentence and citing a
/// sentence that turns out to have been inside a "what we decided *not* to do" section.
public struct CoreChunk: Hashable, Sendable, Codable, Identifiable {
    public var id: ChunkID
    public var objectID: ObjectID
    public var ordinal: Int
    public var text: String
    public var range: Range<Int>
    /// Rough token count. Deliberately named an estimate: it is characters divided by a
    /// constant, not a tokenizer, and nothing downstream should treat it as exact.
    public var tokenEstimate: Int

    public init(objectID: ObjectID, ordinal: Int, text: String, range: Range<Int>) {
        self.id = ChunkID.derived(from: objectID.value, String(ordinal))
        self.objectID = objectID
        self.ordinal = ordinal
        self.text = text
        self.range = range
        self.tokenEstimate = max(1, text.count / 4)
    }
}

public enum ChunkScope: Sendable {}
public typealias ChunkID = ID<ChunkScope>

/// A stored embedding. `model` is part of the identity because vectors from two different
/// models are not comparable and must never meet in one similarity search.
public struct StoredVector: Sendable {
    public let chunkID: ChunkID
    public let model: String
    public let values: [Float]

    public init(chunkID: ChunkID, model: String, values: [Float]) {
        self.chunkID = chunkID
        self.model = model
        self.values = values
    }
}

/// Something that turns text into a vector.
///
/// Lives in `CoreModel` rather than beside its implementation because both the search
/// layer and the ingest layer need to name it, and neither should have to depend on a
/// concrete provider to do so.
public protocol EmbeddingProvider: Sendable {
    /// Stable identifier stored alongside every vector. Changing the model must change
    /// this string, or old and new vectors silently mix in one similarity search.
    var modelIdentifier: String { get }
    var dimensions: Int { get }
    func embed(_ text: String) async throws -> [Float]
    func embed(batch: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    public func embed(batch: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(batch.count)
        for text in batch { results.append(try await embed(text)) }
        return results
    }
}

public enum VectorMath {
    /// L2-normalise, so cosine similarity reduces to a dot product at query time.
    /// Normalising once at write time rather than on every comparison is the whole
    /// reason search can stay a single pass over a BLOB column.
    public static func normalise(_ values: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        for value in values { sumOfSquares += value * value }
        let magnitude = sumOfSquares.squareRoot()
        guard magnitude > 1e-9 else { return values }
        return values.map { $0 / magnitude }
    }

    /// Dot product. Correct as cosine similarity **only** for normalised inputs, which is
    /// why `normalise` runs at write time and this does not re-check.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for index in 0..<a.count { total += a[index] * b[index] }
        return total
    }

    public static func encode(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data, dimensions: Int) -> [Float] {
        guard data.count == dimensions * MemoryLayout<Float>.size else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
