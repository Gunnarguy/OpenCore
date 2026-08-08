import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Testing

@testable import CoreIngest

// MARK: - Chunking

@Test("short text stays one chunk")
func shortTextIsNotSplit() throws {
    let object = CoreObject(
        sourceID: SourceID("s"), kind: .commit, externalID: "a",
        title: "t", text: "Replace vector-only retrieval with hybrid BM25.",
        domain: .project, authority: .authoredArtifact
    )
    #expect(Chunker().chunks(for: object).count == 1)
}

@Test("long text splits on structure and every chunk stays within a sane size")
func longTextSplitsOnParagraphs() throws {
    let paragraph = String(repeating: "This sentence carries some meaning. ", count: 20)
    let body = (0..<8).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
    let object = CoreObject(
        sourceID: SourceID("s"), kind: .document, externalID: "doc",
        title: "doc", text: body, domain: .project, authority: .authoredArtifact
    )

    let chunker = Chunker(targetSize: 1200, overlap: 150)
    let chunks = chunker.chunks(for: object)

    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { !$0.text.isEmpty })
    // Overlap means a chunk can exceed the target, but never unboundedly.
    #expect(chunks.allSatisfy { $0.text.count <= 1200 * 2 })
    // Ordinals must be dense and ordered, or neighbour expansion silently misses passages.
    #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
}

@Test("text with no sentence boundary is still split rather than returned whole")
func degenerateTextIsHardCut() throws {
    // Minified JS, a CSV row, a base64 blob: no paragraph and no sentence boundary.
    let object = CoreObject(
        sourceID: SourceID("s"), kind: .file, externalID: "min.js",
        title: "min.js", text: String(repeating: "abcdefghij", count: 500),
        domain: .project, authority: .authoredArtifact
    )
    let chunks = Chunker(targetSize: 500).chunks(for: object)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.text.count <= 1000 })
}

// MARK: - Vector math

@Test("normalised vectors make cosine a dot product")
func normalisationEnablesDotProduct() throws {
    let a = VectorMath.normalise([3, 4, 0])
    #expect(abs(VectorMath.dot(a, a) - 1.0) < 1e-5)

    let b = VectorMath.normalise([0, 1, 0])
    let c = VectorMath.normalise([1, 0, 0])
    #expect(abs(VectorMath.dot(b, c)) < 1e-5)

    // A zero vector must not produce NaN, which would poison every comparison it touches.
    let zero = VectorMath.normalise([0, 0, 0])
    #expect(zero.allSatisfy { $0.isFinite })
}

@Test("vector blobs round-trip exactly")
func vectorEncodingRoundTrips() throws {
    let original: [Float] = (0..<512).map { Float($0) / 512.0 }
    let decoded = VectorMath.decode(VectorMath.encode(original), dimensions: 512)
    #expect(decoded == original)

    // A blob whose length disagrees with the declared dimension is rejected rather than
    // reinterpreted, because a misread vector produces plausible-looking similarities.
    #expect(VectorMath.decode(VectorMath.encode(original), dimensions: 256).isEmpty)
}

// MARK: - MMR

@Test("MMR similarity treats near-duplicate passages as similar")
func jaccardDetectsDuplicates() throws {
    let a = PassageSearch.tokens(of: "hybrid retrieval combines BM25 with dense vectors")
    let b = PassageSearch.tokens(of: "hybrid retrieval combines BM25 with dense vector search")
    let c = PassageSearch.tokens(of: "the treadmill workout hands off between devices")

    #expect(PassageSearch.jaccard(a, b) > 0.6)
    #expect(PassageSearch.jaccard(a, c) < 0.1)
    #expect(PassageSearch.jaccard(a, []) == 0)
}

// MARK: - Notes domain tagging

@Test("Notes folder names map to domains, erring toward the more restrictive")
func notesFoldersMapToDomains() throws {
    #expect(AppleNotesConnector.domain(forFolder: "Medical") == .medical)
    #expect(AppleNotesConnector.domain(forFolder: "Health Records") == .medical)
    #expect(AppleNotesConnector.domain(forFolder: "Taxes 2026") == .financial)
    #expect(AppleNotesConnector.domain(forFolder: "Projects") == .project)
    // Unknown folders land in personal, which is readable from a personal query and
    // invisible to a project one. Erring restrictive is the intended failure direction.
    #expect(AppleNotesConnector.domain(forFolder: "Random Thoughts") == .personal)
}

// MARK: - Filesystem safety

@Test("the filesystem connector refuses to read binaries as text")
func filesystemSkipsBinaries() throws {
    #expect(FilesystemConnector.textExtensions.contains("md"))
    #expect(FilesystemConnector.textExtensions.contains("swift"))
    // A PDF read as UTF-8 produces plausible-looking garbage that then gets embedded and
    // cited as if it were the document. Better to skip it than to half-handle it.
    #expect(!FilesystemConnector.textExtensions.contains("pdf"))
    #expect(!FilesystemConnector.textExtensions.contains("png"))
    #expect(FilesystemConnector.skippedDirectories.contains("node_modules"))
    #expect(FilesystemConnector.skippedDirectories.contains(".git"))
}
