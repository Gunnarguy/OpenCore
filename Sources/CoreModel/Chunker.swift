import Foundation

/// Splits an object's text into retrievable passages.
///
/// Structure-first, then size. Paragraph and heading boundaries are where an author
/// already decided one idea ends, so respecting them costs nothing and beats a fixed
/// character window that cuts a sentence in half and embeds both halves as nonsense.
/// Oversized paragraphs fall back to sentence boundaries, and only text with no sentence
/// boundary at all gets a hard cut.
public struct Chunker: Sendable {
    /// Target passage size in characters. ~300 tokens at four characters per token, which
    /// sits comfortably inside NLContextualEmbedding's 256-token window after tokenisation
    /// overhead. Chosen, not measured.
    public let targetSize: Int
    /// Trailing context repeated into the next chunk, so a fact split across a boundary
    /// is still retrievable from at least one side.
    public let overlap: Int
    /// Below this, a whole object is one chunk. A commit message should not be split.
    public let minimumSplitSize: Int

    public init(targetSize: Int = 1200, overlap: Int = 150, minimumSplitSize: Int = 1600) {
        self.targetSize = targetSize
        self.overlap = overlap
        self.minimumSplitSize = minimumSplitSize
    }

    public func chunks(for object: CoreObject) -> [CoreChunk] {
        let text = object.text
        guard text.count > minimumSplitSize else {
            guard !text.isEmpty else { return [] }
            return [CoreChunk(objectID: object.id, ordinal: 0, text: text, range: 0..<text.utf8.count)]
        }

        let blocks = paragraphs(in: text)
        var chunks: [CoreChunk] = []
        var current = ""
        var currentStart = 0
        var ordinal = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { current = ""; return }
            chunks.append(CoreChunk(
                objectID: object.id,
                ordinal: ordinal,
                text: trimmed,
                range: currentStart..<(currentStart + current.utf8.count)
            ))
            ordinal += 1
            // Carry the tail forward as overlap.
            current = overlap > 0 ? String(trimmed.suffix(overlap)) : ""
            currentStart += max(0, trimmed.utf8.count - current.utf8.count)
        }

        for block in blocks {
            if block.text.count > targetSize {
                flush()
                for piece in sentences(in: block.text, maximum: targetSize) {
                    current = piece
                    currentStart = block.offset
                    flush()
                }
                current = ""
                continue
            }

            if current.count + block.text.count > targetSize {
                flush()
            }
            if current.isEmpty { currentStart = block.offset }
            current += (current.isEmpty ? "" : "\n\n") + block.text
        }
        flush()

        return chunks.filter { !$0.text.isEmpty }
    }

    // MARK: - Splitting

    private struct Block {
        let text: String
        let offset: Int
    }

    /// Blank-line separated blocks, with a markdown heading forced to start a new block
    /// even when it is not preceded by a blank line.
    private func paragraphs(in text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer = ""
        var bufferStart = 0
        var offset = 0

        for line in text.components(separatedBy: "\n") {
            let lineBytes = line.utf8.count + 1
            let isHeading = line.hasPrefix("#") || (line.hasPrefix("==") && line.count > 2)
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty

            if (isBlank || isHeading), !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(Block(text: buffer.trimmingCharacters(in: .whitespacesAndNewlines), offset: bufferStart))
                buffer = ""
                bufferStart = offset
            }
            if !isBlank {
                if buffer.isEmpty { bufferStart = offset }
                buffer += (buffer.isEmpty ? "" : "\n") + line
            }
            offset += lineBytes
        }

        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { blocks.append(Block(text: tail, offset: bufferStart)) }
        return blocks
    }

    /// Sentence-boundary packing for a block that is already too long.
    private func sentences(in text: String, maximum: Int) -> [String] {
        var pieces: [String] = []
        var current = ""

        var sentence = ""
        for character in text {
            sentence.append(character)
            let ended = character == "." || character == "!" || character == "?" || character == "\n"
            guard ended else { continue }

            if current.count + sentence.count > maximum, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += sentence
            sentence = ""
        }
        current += sentence

        // No sentence boundary anywhere (minified code, a CSV line). Hard-cut on a
        // character boundary, which is still safe for UTF-8 because String indexes
        // by grapheme rather than by byte.
        if current.count > maximum {
            var remainder = Substring(current)
            while remainder.count > maximum {
                pieces.append(String(remainder.prefix(maximum)))
                remainder = remainder.dropFirst(maximum)
            }
            current = String(remainder)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
