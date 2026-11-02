import CoreModel
import Foundation

extension GroundingSource {
    public static func floorObjects(in sources: [GroundingSource]) -> Set<ObjectID> {
        Set(sources.flatMap { [$0.objectID] + ($0.representedObjectIDs ?? []) })
    }
}

/// Application-level observations, not packet/byte measurements or proof of provider retention.
struct GeminiGenerationAttempt: Sendable {
    struct Answer: Sendable {
        var insufficient: Bool
        var sentences: [(text: String, source: Int?)]
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var submitted = false
    var objects: Set<ObjectID>
    var httpStatus: Int?
    var applicationAcknowledged = false
    var answer: Answer?
    var outcome = "Not submitted."
    var milliseconds = 0

    var confirmedObjectCount: Int { applicationAcknowledged ? objects.count : 0 }
    var stage: ReceiptStage {
        var counters = [
            "request_submitted": submitted ? 1 : 0,
            "objects_submitted": submitted ? objects.count : 0,
            "application_acknowledged": applicationAcknowledged ? 1 : 0,
            "answer_decoded": answer == nil ? 0 : 1,
        ]
        if let httpStatus { counters["http_status"] = httpStatus }
        return ReceiptStage(name: "cloud.request", counters: counters, milliseconds: milliseconds,
            note: Conversation.geminiModelIdentity + ": " + outcome)
    }

    static func perform(_ request: URLRequest, sources: [GroundingSource], transport: Transport) async -> Self {
        let start = DispatchTime.now().uptimeNanoseconds
        var attempt = Self(objects: GroundingSource.floorObjects(in: sources))
        guard !Task.isCancelled else {
            attempt.outcome = "Cancelled before submission."
            attempt.milliseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            return attempt
        }
        attempt.submitted = true // The prepared request is now handed to the transport.
        do {
            let (data, response) = try await transport(request)
            attempt.httpStatus = (response as? HTTPURLResponse)?.statusCode
            if let status = attempt.httpStatus, (200..<300).contains(status),
               let payload = try? JSONDecoder().decode(Payload.self, from: data) {
                let text = payload.candidates?.first?.content?.parts?.first?.text
                attempt.applicationAcknowledged = text != nil || payload.candidates?.first?.finishReason != nil || payload.promptFeedback?.blockReason != nil
                if let text, let structured = try? JSONDecoder().decode(StructuredAnswer.self, from: Data(text.utf8)) {
                    attempt.answer = Answer(insufficient: structured.insufficient, sentences: structured.sentences.compactMap {
                        let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : (text, $0.source)
                    })
                    attempt.outcome = "Provider application response acknowledged; answer decoded."
                } else {
                    attempt.outcome = attempt.applicationAcknowledged
                        ? "Provider application response acknowledged; no usable structured answer."
                        : "HTTP response received; provider application acknowledgment not established."
                }
            } else {
                attempt.outcome = attempt.httpStatus == nil
                    ? "Transport returned no HTTP response; delivery unconfirmed."
                    : "HTTP response received; provider application acknowledgment not established."
            }
        } catch is CancellationError {
            attempt.outcome = "Cancelled after submission; delivery unconfirmed."
        } catch {
            attempt.outcome = "Transport failed after submission; delivery unconfirmed."
        }
        attempt.milliseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return attempt
    }

    private struct Payload: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String? }
                var parts: [Part]?
            }
            var content: Content?
            var finishReason: String?
        }
        struct PromptFeedback: Decodable { var blockReason: String? }
        var candidates: [Candidate]?
        var promptFeedback: PromptFeedback?
    }
    private struct StructuredAnswer: Decodable {
        struct Sentence: Decodable { var text: String; var source: Int? }
        var insufficient: Bool
        var sentences: [Sentence]
    }
}
