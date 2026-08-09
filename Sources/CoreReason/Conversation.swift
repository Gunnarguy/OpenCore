import CoreModel
import CoreSearch
import CoreStore
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A cited passage handed to the model, numbered so the answer can point at it.
public struct GroundingSource: Sendable, Identifiable, Hashable {
    public var id: Int { index }
    public let index: Int
    public let title: String
    public let text: String
    public let objectID: ObjectID
    public let authority: Authority
    public let uri: String?
}

/// One exchange.
public struct Turn: Sendable, Identifiable {
    public enum Role: String, Sendable { case you, core }

    public let id: UUID
    public let role: Role
    public var text: String
    public var sources: [GroundingSource]
    public var verdicts: [Grounding.Verdict]
    public var receipt: Receipt?
    public var modelName: String?
    public var error: String?
    /// True while tokens are still arriving, so the UI can show a caret without guessing.
    public var streaming: Bool

    public init(
        role: Role,
        text: String = "",
        sources: [GroundingSource] = [],
        verdicts: [Grounding.Verdict] = [],
        receipt: Receipt? = nil,
        modelName: String? = nil,
        error: String? = nil,
        streaming: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.sources = sources
        self.verdicts = verdicts
        self.receipt = receipt
        self.modelName = modelName
        self.error = error
        self.streaming = streaming
    }

    public var ungrounded: [Grounding.Verdict] { verdicts.filter { !$0.isGrounded } }
}

/// Conversation over your own history, with a model writing the prose.
///
/// The architecture that matters is what the model is **not** allowed to do. It never sees the
/// store, never queries anything, and never introduces a claim. Retrieval happens first, in
/// code; the model receives only those passages and is instructed to answer from them alone.
/// Afterwards every sentence is scored against that same text by `Grounding`, and anything
/// that fails is shown as failing rather than quietly removed.
///
/// So the model is a writer, not a source. That is what keeps `Authority` meaningful: nothing
/// a model produces is ever stored as a claim, and the receipt records which model actually
/// ran rather than which one was requested.
public actor Conversation {
    private let store: Store
    private let search: PassageSearch
    private let grounding = Grounding()

    /// Passages handed to the model. Enough to answer, few enough that the context stays small
    /// and every one can be listed under the answer for inspection. Chosen, not measured.
    public static let sourceCount = 6

    public init(store: Store, embedder: (any EmbeddingProvider)? = nil, tuning: RetrievalTuning = .default) {
        self.store = store
        self.search = PassageSearch(store: store, embedder: embedder, tuning: tuning)
    }

    // MARK: - Availability

    public enum Readiness: Sendable, Equatable {
        case ready(String)
        case unsupportedOS
        case appleIntelligenceOff
        case modelDownloading
        case deviceNotEligible
        case unknown(String)

        public var isReady: Bool { if case .ready = self { return true }; return false }

        public var message: String {
            switch self {
            case .ready(let name): "Using \(name)."
            case .unsupportedOS: "Chat needs macOS 26 or later. Everything else in OpenCore works without it."
            case .appleIntelligenceOff: "Apple Intelligence is switched off. Turn it on in System Settings, then reopen this tab."
            case .modelDownloading: "The on-device model is still downloading. This finishes on its own."
            case .deviceNotEligible: "This Mac cannot run Apple's on-device model."
            case .unknown(let detail): detail
            }
        }
    }

    public static func readiness() -> Readiness {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready("Apple on-device model")
        case .unavailable(let reason):
            return switch reason {
            case .appleIntelligenceNotEnabled: .appleIntelligenceOff
            case .modelNotReady: .modelDownloading
            case .deviceNotEligible: .deviceNotEligible
            @unknown default: .unknown("The on-device model is unavailable for an unrecognised reason.")
            }
        @unknown default:
            return .unknown("The on-device model reported an unrecognised availability state.")
        }
        #else
        return .unsupportedOS
        #endif
    }

    // MARK: - Asking

    /// Retrieve, then stream a grounded answer.
    ///
    /// Emits the turn repeatedly as it fills in: sources first, so the UI can show what is
    /// being read while the model is still thinking, then text, then verdicts and receipt.
    public func send(_ question: String, history: [Turn] = []) -> AsyncStream<Turn> {
        AsyncStream { continuation in
            Task {
                var turn = Turn(role: .core, streaming: true)

                // ---- Retrieve, before the model is involved at all ----
                let outcome: PassageOutcome
                do {
                    let classification = QueryClassifier().classify(question)
                    let (domain, requested) = AdmissionPolicy.classifyDomain(
                        question,
                        knownEntitySurfaces: try await store.aliasSurfaces()
                    )
                    outcome = try await search.search(
                        query: question,
                        queryClass: classification.queryClass,
                        policy: AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested),
                        limit: Self.sourceCount
                    )
                } catch {
                    turn.error = "retrieval failed: \(error)"
                    turn.streaming = false
                    continuation.yield(turn)
                    continuation.finish()
                    return
                }

                turn.sources = outcome.hits.enumerated().map { index, hit in
                    GroundingSource(
                        index: index + 1,
                        title: hit.object.title,
                        text: hit.chunk.text,
                        objectID: hit.object.id,
                        authority: hit.object.authority,
                        uri: hit.object.uri
                    )
                }
                continuation.yield(turn)

                guard !turn.sources.isEmpty else {
                    // No model call at all. Inventing prose over an empty context is exactly
                    // the failure this design exists to prevent, and it is also the cheapest
                    // possible thing to get wrong.
                    turn.text = "Nothing in your history matches that. \(outcome.chunksSearched) passages searched"
                        + (outcome.blockedByDomain > 0 ? ", \(outcome.blockedByDomain) withheld by domain policy." : ".")
                    turn.streaming = false
                    continuation.yield(turn)
                    continuation.finish()
                    return
                }

                // ---- Generate ----
                let context = Self.contextBlock(turn.sources)
                #if canImport(FoundationModels)
                if #available(macOS 26, *) {
                    do {
                        let session = LanguageModelSession(instructions: Self.instructions)
                        let prompt = Self.prompt(question: question, context: context, history: history)

                        for try await snapshot in session.streamResponse(to: prompt) {
                            turn.text = snapshot.content
                            continuation.yield(turn)
                        }
                        turn.modelName = "Apple on-device"
                    } catch {
                        turn.error = "\(error)"
                    }
                } else {
                    turn.error = Readiness.unsupportedOS.message
                }
                #else
                turn.error = Readiness.unsupportedOS.message
                #endif

                // ---- Verify, then record ----
                turn.verdicts = grounding.verify(answer: turn.text, against: context)
                turn.streaming = false

                turn.receipt = Receipt(
                    query: question,
                    queryClass: QueryClassifier().classify(question).queryClass,
                    domainsAdmitted: [],
                    domainsBlocked: [],
                    stages: [],
                    objectsSearched: outcome.chunksSearched,
                    objectsRetrieved: turn.sources.count,
                    evidenceAdmitted: turn.sources.count,
                    claimsConsulted: 0,
                    contradictionsSurfaced: 0,
                    // The model that actually ran, not the one requested.
                    model: turn.modelName,
                    // On-device. This becomes non-zero the day a cloud model is offered, and
                    // it must be counted then rather than assumed.
                    objectsTransmitted: 0,
                    confidence: nil
                )
                continuation.yield(turn)
                continuation.finish()
            }
        }
    }

    // MARK: - Prompting

    static let instructions = """
    You answer questions about one person's own history, using only the numbered sources you \
    are given.

    Rules, in order of importance:
    1. Use only the sources. If they do not contain the answer, say so plainly and stop. Do \
       not fill a gap with general knowledge.
    2. Cite with bracketed numbers matching the sources, like [2]. Every factual sentence \
       needs one.
    3. Prefer the words in the sources over paraphrase. This answer is checked afterwards \
       against the source text, and invented phrasing fails that check.
    4. Be brief. Three sentences is usually enough.
    5. Never speculate about health, finances, or relationships, even if a source mentions \
       them. Report only what the source states.
    """

    static func contextBlock(_ sources: [GroundingSource]) -> String {
        sources.map { "[\($0.index)] \($0.title)\n\($0.text)" }.joined(separator: "\n\n")
    }

    static func prompt(question: String, context: String, history: [Turn]) -> String {
        // Only the last two exchanges. A long transcript crowds out the sources in a small
        // context window, and the sources are the part that makes the answer trustworthy.
        let recent = history.suffix(4)
            .map { "\($0.role == .you ? "Q" : "A"): \($0.text.prefix(300))" }
            .joined(separator: "\n")

        return """
        \(recent.isEmpty ? "" : "Earlier in this conversation:\n\(recent)\n\n")Sources:

        \(context)

        Question: \(question)
        """
    }
}
