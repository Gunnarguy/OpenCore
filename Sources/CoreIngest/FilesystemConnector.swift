import CoreModel
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import Vision
#endif

/// Local documents: notes, specs, exports, code, and text-layer PDFs.
///
/// The design decision that matters is **domain per root**. A folder is the coarsest
/// honest signal about what kind of thing is inside it, and asking once per folder is far
/// more reliable than classifying ten thousand files individually. `~/Documents/Medical`
/// tagged `.medical` means those files are unreachable from a project query no matter how
/// well they match, which is the firewall doing its job on the data most worth firewalling.
public struct FilesystemConnector: Connector {
    public let source: Source
    private let roots: [Root]
    private let maximumFileSize: Int
    private let maximumPDFSize: Int
    private let honoursSince: Bool
    private let knownUnread: [String]

    public struct Root: Sendable {
        public let url: URL
        public let domain: Domain
        public let authority: Authority

        public init(url: URL, domain: Domain, authority: Authority = .authoredArtifact) {
            self.url = url
            self.domain = domain
            self.authority = authority
        }
    }

    /// Extensions worth reading directly as UTF-8 text.
    public static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "rtf", "org", "rst",
        "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm",
        "json", "yaml", "yml", "toml", "sql", "sh", "zsh", "html", "css",
    ]

    /// Extensions extracted through `PDFKit` page-by-page text layers, falling back to on-device
    /// `Vision` OCR (`VNRecognizeTextRequest`) for scanned pages with no embedded text layer.
    public static let pdfExtensions: Set<String> = ["pdf"]

    /// Image extensions extracted on device through Apple's `Vision` framework (`VNRecognizeTextRequest`
    /// and `VNDetectBarcodesRequest`, cited 2026-10-22 from `MacOSX27.0.sdk` `Vision.swiftmodule`).
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "webp",
    ]

    public static let skippedDirectories: Set<String> = [
        ".git", ".git.nosync", "node_modules", ".build", "DerivedData", "Pods", "build",
        ".venv", "venv", "__pycache__", ".next", "dist", "vendor", "Carthage", ".swiftpm",
    ]

    /// Secret, credential, and environment files that must never be read or ingested.
    public static let skippedSecretFileNames: Set<String> = [
        ".env", "config.json", "credentials.json",
    ]

    public static let skippedSecretExtensions: Set<String> = [
        "pem", "key", "pkcs12", "p8", "env",
    ]

    public static func isSecretOrExcluded(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        let lowerExt = url.pathExtension.lowercased()
        if skippedSecretFileNames.contains(lowerName) || lowerName.hasPrefix(".env.") {
            return true
        }
        if skippedSecretExtensions.contains(lowerExt) {
            return true
        }
        return false
    }

    /// - Parameter honoursSince: false when a person handed these files over, so their dates say
    ///   nothing about whether they are wanted. See `handedOver(files:domain:)`.
    /// - Parameter knownUnread: what whoever chose `roots` already knows they leave out. It goes
    ///   into every batch, so a read that is short before it starts says so. See
    ///   `AgentMemoryPolicy.Discovery`.
    public init(
        handle: String,
        roots: [Root],
        maximumFileSize: Int = 2_000_000,
        maximumPDFSize: Int = 25_000_000,
        honoursSince: Bool = true,
        knownUnread: [String] = []
    ) {
        self.roots = roots
        self.maximumFileSize = maximumFileSize
        self.maximumPDFSize = maximumPDFSize
        self.honoursSince = honoursSince
        self.knownUnread = knownUnread
        self.source = Source(
            kind: .filesystem,
            handle: handle,
            displayName: "Files · \(handle)",
            defaultAuthority: .authoredArtifact,
            // Per-object domain comes from the root that produced it; this is only the
            // fallback for a source with no roots configured.
            defaultDomain: .personal
        )
    }

    /// Files a person dropped on the window.
    ///
    /// Every multi-file drop shares the `dropped-files` source, so its sync date came from the
    /// last drop. A file last modified before that was skipped as already seen, and the screen
    /// said "0 new or modified items" about a file someone had just handed over. `since` answers
    /// "what changed while I was not looking", which is not the question a drop asks. The store
    /// still compares content, so dropping the same file twice changes nothing.
    public static func handedOver(files: [URL], domain: Domain) -> FilesystemConnector {
        FilesystemConnector(
            handle: files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "dropped-files",
            roots: files.map { Root(url: $0, domain: domain) },
            honoursSince: false
        )
    }

    /// A folder a person dropped or chose. Its source is named after the folder, so a second
    /// folder with the same name inherits the first one's sync date without this.
    public static func handedOver(folder: URL, domain: Domain) -> FilesystemConnector {
        FilesystemConnector(
            handle: folder.lastPathComponent,
            roots: [Root(url: folder, domain: domain)],
            honoursSince: false
        )
    }

    /// Extract UTF-8 text and page count from a PDF using `PDFKit` when an embedded text layer
    /// exists, or on-device `Vision` OCR (`VNRecognizeTextRequest`) for scanned pages.
    /// Returns `nil` when the file cannot be opened as a PDF or contains no recognizable text.
    public static func extractPDFText(from url: URL) -> (text: String, pageCount: Int)? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let raw = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                pages.append("[Page \(index + 1)]\n\(raw)")
                continue
            }
            #if canImport(Vision) && canImport(CoreGraphics)
            if let cgImage = renderPDFPageToCGImage(page, scale: 2.0),
               let ocrText = extractVisionText(from: cgImage),
               !ocrText.isEmpty {
                pages.append("[Page \(index + 1) · Vision OCR]\n\(ocrText)")
            }
            #endif
        }
        let combined = pages.joined(separator: "\n\n")
        guard !combined.isEmpty else { return nil }
        return (combined, document.pageCount)
        #else
        return nil
        #endif
    }

    #if canImport(PDFKit) && canImport(CoreGraphics)
    private static func renderPDFPageToCGImage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return context.makeImage()
    }
    #endif

    /// Extract UTF-8 text and barcodes from a `CGImage` on device using Apple's `Vision` framework
    /// (`VNRecognizeTextRequest` + `VNDetectBarcodesRequest`, cited 2026-10-22 from `MacOSX27.0.sdk`).
    public static func extractVisionText(from cgImage: CGImage) -> String? {
        #if canImport(Vision) && canImport(CoreGraphics)
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let barcodeRequest = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([textRequest, barcodeRequest])

        var lines: [String] = []
        if let observations = textRequest.results {
            for observation in observations {
                if let candidate = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                   !candidate.isEmpty {
                    lines.append(candidate)
                }
            }
        }
        if let barcodes = barcodeRequest.results {
            for barcode in barcodes {
                if let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !payload.isEmpty {
                    lines.append("[Barcode \(barcode.symbology.rawValue)] \(payload)")
                }
            }
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
        #else
        return nil
        #endif
    }

    /// Extract UTF-8 text and barcodes from an image file on device using `Vision`.
    public static func extractImageText(from url: URL) -> String? {
        #if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        guard let recognized = extractVisionText(from: cgImage), !recognized.isEmpty else {
            return nil
        }
        return "[Vision OCR · \(url.lastPathComponent)]\n\(recognized)"
        #else
        return nil
        #endif
    }

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        var objects: [CoreObject] = []
        let manager = FileManager.default
        // Reported, not just logged. A root on a volume that is unplugged today is a read that fell
        // short, and it used to move the date past everything on that volume.
        var missingRoots: [String] = []
        var unreadable: [String] = []

        for root in roots {
            var seen = 0
            var skippedLarge = 0
            var skippedBinary = 0

            let canonicalRootURL = root.url.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: canonicalRootURL.path, isDirectory: &isDir) else {
                log("could not read \(root.url.path)")
                missingRoots.append(root.url.path)
                continue
            }

            let candidateURLs: [URL]
            let rootBasePath: String
            if isDir.boolValue {
                guard let enumerator = manager.enumerator(
                    at: canonicalRootURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles],
                    // Without a handler the walk carries on past a folder it can't enter, as
                    // though the folder were empty.
                    errorHandler: { url, _ in
                        unreadable.append(url.path)
                        return true
                    }
                ) else {
                    log("could not read \(root.url.path)")
                    missingRoots.append(root.url.path)
                    continue
                }
                var collected: [URL] = []
                // `nextObject()` rather than `for case let url as URL in enumerator`:
                // DirectoryEnumerator's Sequence conformance is unavailable from async
                // contexts, because its iterator is not Sendable.
                while let url = enumerator.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    if values?.isDirectory == true {
                        if Self.skippedDirectories.contains(url.lastPathComponent) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    collected.append(url.resolvingSymlinksInPath())
                }
                candidateURLs = collected
                rootBasePath = canonicalRootURL.path
            } else {
                candidateURLs = [canonicalRootURL]
                rootBasePath = canonicalRootURL.deletingLastPathComponent().path
            }

            for url in candidateURLs {
                if Self.isSecretOrExcluded(url) {
                    skippedBinary += 1
                    continue
                }

                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let ext = url.pathExtension.lowercased()
                let isText = Self.textExtensions.contains(ext)
                let isPDF = Self.pdfExtensions.contains(ext)
                let isImage = Self.imageExtensions.contains(ext)
                guard isText || isPDF || isImage else {
                    skippedBinary += 1
                    continue
                }

                let sizeLimit = (isPDF || isImage) ? maximumPDFSize : maximumFileSize
                if let size = values?.fileSize, size > sizeLimit {
                    skippedLarge += 1
                    continue
                }

                let modified = values?.contentModificationDate
                // Incremental sync: skip anything untouched since the last pass. The
                // content hash in the store is the backstop for a file whose mtime lies.
                if honoursSince, let since, let modified, modified < since { continue }

                guard manager.isReadableFile(atPath: url.path) else {
                    unreadable.append(url.path)
                    continue
                }

                var metadata: [String: String] = [
                    "root": rootBasePath,
                    "extension": ext,
                    "relative_path": url.path.replacingOccurrences(of: rootBasePath + "/", with: ""),
                ]

                let text: String
                if isPDF {
                    guard let extracted = Self.extractPDFText(from: url) else {
                        skippedBinary += 1
                        continue
                    }
                    text = extracted.text
                    metadata["pages"] = "\(extracted.pageCount)"
                } else if isImage {
                    guard let extracted = Self.extractImageText(from: url) else {
                        skippedBinary += 1
                        continue
                    }
                    text = extracted
                    metadata["ocr"] = "vision"
                } else {
                    do {
                        text = try String(contentsOf: url, encoding: .utf8)
                    } catch {
                        // Both of these counted as non-text. Bytes that aren't UTF-8 won't change,
                        // and a read that failed might not fail next time.
                        if Self.isNotText(error) { skippedBinary += 1 } else { unreadable.append(url.path) }
                        continue
                    }
                    guard !text.isEmpty else {
                        skippedBinary += 1
                        continue
                    }
                }

                objects.append(CoreObject(
                    sourceID: source.id,
                    kind: .file,
                    externalID: url.path,
                    title: url.lastPathComponent,
                    text: text,
                    uri: url.absoluteString,
                    authoredAt: modified,
                    domain: root.domain,
                    authority: root.authority,
                    metadata: metadata
                ))
                seen += 1
            }

            log("\(root.url.lastPathComponent) [\(root.domain.rawValue)]: \(seen) files, \(skippedBinary) non-text, \(skippedLarge) oversized")
        }

        return ConnectorBatch(
            objects: objects,
            cursor: ISO8601DateFormatter().string(from: Date()),
            unread: knownUnread + Self.described(missingRoots, "folders or files were not there")
                + Self.described(unreadable, "files or folders could not be read")
        )
    }

    /// Whether a read failed on the bytes rather than on getting them. Invalid UTF-8 throws 259,
    /// not the 261 its name suggests [measured 2026-10-31, macOS 27], so both are taken.
    static func isNotText(_ error: any Error) -> Bool {
        guard let code = (error as? CocoaError)?.code else { return false }
        return code == .fileReadCorruptFile || code == .fileReadInapplicableStringEncoding
    }

    /// One line however many there are, because a screen shows this.
    private static func described(_ paths: [String], _ what: String) -> [String] {
        guard let first = paths.first else { return [] }
        return ["\(paths.count) \(what), starting with \(first)."]
    }
}
