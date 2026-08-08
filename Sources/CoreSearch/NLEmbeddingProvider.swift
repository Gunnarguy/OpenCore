import CoreModel
import Foundation
import NaturalLanguage

/// On-device embeddings from Apple's `NLContextualEmbedding`.
///
/// Chosen over a bundled MiniLM for three reasons that matter here: it ships with the OS
/// so nothing is downloaded at build time, it is Apple-authored so it stays maintained
/// across releases, and it has **never been measured on a personal corpus** — which makes
/// measuring it a real result rather than a reproduction of someone else's benchmark.
///
/// The model produces one vector per token. Sentence-level meaning needs pooling, and mean
/// pooling is the honest default: it is what the BERT-family literature uses, and anything
/// cleverer would be an unmeasured choice dressed up as an optimisation.
public actor NLEmbeddingProvider: EmbeddingProvider {
    public nonisolated let modelIdentifier: String
    public nonisolated let dimensions: Int

    private let language: NLLanguage
    private let embedding: NLContextualEmbedding
    private var loaded = false

    public enum SetupError: Error, CustomStringConvertible {
        case unavailable(NLLanguage)
        case assetsUnavailable(String)

        public var description: String {
            switch self {
            case .unavailable(let language):
                "NLContextualEmbedding has no model for \(language.rawValue) on this OS"
            case .assetsUnavailable(let detail):
                "NLContextualEmbedding assets are not available: \(detail)"
            }
        }
    }

    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLContextualEmbedding(language: language) else {
            throw SetupError.unavailable(language)
        }
        self.language = language
        self.embedding = embedding
        self.dimensions = embedding.dimension
        // Revision is part of the identity: Apple shipping a new revision produces
        // different vectors, and mixing revisions in one index is the same bug as
        // mixing models.
        self.modelIdentifier = "nl-contextual-\(language.rawValue)-r\(embedding.revision)-d\(embedding.dimension)-mean"
    }

    /// Download assets if needed, then load. Safe to call repeatedly.
    public func prepare() async throws {
        guard !loaded else { return }

        if !embedding.hasAvailableAssets {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                embedding.requestAssets { result, error in
                    switch result {
                    case .available:
                        continuation.resume()
                    case .notAvailable:
                        continuation.resume(throwing: SetupError.assetsUnavailable("not available for download"))
                    case .error:
                        continuation.resume(throwing: SetupError.assetsUnavailable(error?.localizedDescription ?? "unknown error"))
                    @unknown default:
                        continuation.resume(throwing: SetupError.assetsUnavailable("unknown asset status"))
                    }
                }
            }
        }

        try embedding.load()
        loaded = true
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try await prepare()

        let result = try embedding.embeddingResult(for: trimmed, language: language)

        var sum = [Float](repeating: 0, count: dimensions)
        var tokenCount = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            guard vector.count == self.dimensions else { return true }
            for index in 0..<self.dimensions { sum[index] += Float(vector[index]) }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else { return [] }
        let mean = sum.map { $0 / Float(tokenCount) }
        // Normalised at write time so similarity is a dot product at query time.
        return VectorMath.normalise(mean)
    }
}
