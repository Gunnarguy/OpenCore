import CoreCompanion
import CryptoKit
import Foundation

/// A durable operation marker binds a random request ID to every wire field. Framing is
/// versioned and byte-length-prefixed rather than depending on JSON escaping. When adding a
/// CompanionRequest field, add it here and version the format before using it for writes.
enum CompanionChatFingerprint {
    static func hex(_ request: CompanionRequest) -> String {
        let fields: [String?] = [
            request.id.uuidString, request.section.rawValue, request.query, request.recordID, request.domain,
            request.asOf.map { String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16) },
            String(request.offset), request.answerMode.rawValue, request.resumeID?.uuidString,
            request.chatHistoryAction?.rawValue, request.chatThreadID?.uuidString,
        ]
        var bytes = Data("OpenCore companion request v1\u{0}".utf8)
        for field in fields {
            guard let field else { bytes.append(0); continue }
            let value = Data(field.utf8)
            bytes.append(1)
            bytes.append(contentsOf: String(value.count).utf8)
            bytes.append(58) // ASCII colon separates the length from the value.
            bytes.append(value)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
