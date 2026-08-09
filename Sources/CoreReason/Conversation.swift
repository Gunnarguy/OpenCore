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
/// code; the model receives only those passages and answers into a schema that forces every
/// sentence to name the passage it came from. Afterwards each sentence is checked against
/// *that* passage by `Grounding`, and anything failing is shown as failing rather than removed.
///
/// So the model is a writer, not a source. That is what keeps `Authority` meaningful: nothing
/// a model produces is ever stored as a claim, and the receipt records which model actually
/// ran rather than which one was requested.
///
/// The session is held across turns so follow-up questions use the model's own `Transcript`
/// rather than a hand-rolled summary of previous exchanges pasted into the prompt.
public actor Conversation {
    private let store: Store
    private let search: PassageSearch
    private let grounding = Grounding()

    /// Held across turns for conversational continuity. Typed as `AnyObject` because
    /// `LanguageModelSession` is macOS 26+ and this package deploys to macOS 15, so it cannot
    /// appear in a stored property's type.
    private var sessionBox: AnyObject?

    /// Passages handed to the model. Enough to answer, few enough that the context stays small
    /// and every one can be listed under the answer for inspection. Chosen, not measured.
    ///
    /// Must equal `AnswerLimits.maximumSourceNumber`, which bounds the citation field in the
    /// generation schema.
    public static let sourceCount = AnswerLimits.maximumSourceNumber

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
            return .ready(modelIdentity)
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

    /// What goes in `Receipt.model`.
    ///
    /// The framework exposes no version or build identifier for the on-device model, so this
    /// names the model and stops. Inventing a version string here would be exactly the
    /// "plausible default in a receipt field" the receipt exists to refuse.
    static let modelIdentity = "Apple on-device (SystemLanguageModel.default)"

    /// Warm the model before the first question.
    ///
    /// Worth calling when the chat tab appears: it loads model assets while the user is still
    /// typing rather than after they hit return.
    public func prepare() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { session().prewarm() }
        #endif
    }

    // MARK: - Asking

    /// Retrieve, then stream a grounded answer.
    ///
    /// Emits the turn repeatedly as it fills in: sources first, so the UI can show what is
    /// being read while the model is still thinking, then text, then verdicts and receipt.
    public nonisolated func send(_ question: String) -> AsyncStream<Turn> {
        AsyncStream { continuation in
            Task { await self.answer(question, into: continuation) }
        }
    }

    private func answer(_ question: String, into continuation: AsyncStream<Turn>.Continuation) async {
        var turn = Turn(role: .core, streaming: true)
        let started = DispatchTime.now().uptimeNanoseconds

        // ---- Retrieve, before the model is involved at all ----
        let outcome: PassageOutcome
        let domain: Domain
        let queryClass: QueryClass
        do {
            queryClass = QueryClassifier().classify(question).queryClass
            let (queryDomain, requested) = AdmissionPolicy.classifyDomain(
                question,
                knownEntitySurfaces: try await store.aliasSurfaces()
            )
            domain = queryDomain
            outcome = try await search.search(
                query: question,
                queryClass: queryClass,
                policy: AdmissionPolicy(queryDomain: queryDomain, explicitlyRequested: requested),
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

        var stages = Self.retrievalStages(outcome)

        guard !turn.sources.isEmpty else {
            // No model call at all. Inventing prose over an empty context is exactly the
            // failure this design exists to prevent, and it is also the cheapest possible
            // thing to get wrong.
            turn.text = "Nothing in your history matches that. \(outcome.chunksSearched) passages searched"
                + (outcome.blockedByDomain > 0 ? ", \(outcome.blockedByDomain) withheld by domain policy." : ".")
            turn.streaming = false
            turn.receipt = Self.receipt(
                question: question, queryClass: queryClass, domain: domain,
                outcome: outcome, sources: [], stages: stages, model: nil
            )
            continuation.yield(turn)
            continuation.finish()
            return
        }

        // ---- Generate ----
        let generationStarted = DispatchTime.now().uptimeNanoseconds
        var modelName: String?

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let result = await generate(question: question, sources: turn.sources) { partial in
                turn.text = partial
                continuation.yield(turn)
            }
            switch result {
            case .success(let answer, let tokens):
                modelName = Self.modelIdentity
                turn.modelName = Self.modelIdentity
                turn.text = Self.render(answer.sentences)
                turn.verdicts = answer.sentences.map {
                    grounding.verify(sentence: $0.text, citedSource: $0.source, sources: turn.sources)
                }
                if answer.insufficient {
                    // The model said the sources do not answer the question. Report that as
                    // the answer rather than showing whatever partial prose came with it.
                    turn.text = "The sources retrieved do not answer that."
                        + (answer.sentences.isEmpty ? "" : " The closest they come:\n\n" + Self.render(answer.sentences))
                }
                var counters = ["sentences": answer.sentences.count]
                if let tokens { counters["inputTokens"] = tokens.input; counters["outputTokens"] = tokens.output }
                stages.append(ReceiptStage(
                    name: "generate",
                    counters: counters,
                    milliseconds: Int((DispatchTime.now().uptimeNanoseconds - generationStarted) / 1_000_000),
                    note: Self.modelIdentity
                ))
            case .failure(let message):
                turn.error = message
            }
        } else {
            turn.error = Readiness.unsupportedOS.message
        }
        #else
        turn.error = Readiness.unsupportedOS.message
        #endif

        // ---- Record ----
        turn.streaming = false
        stages.append(ReceiptStage(
            name: "total",
            milliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        ))
        turn.receipt = Self.receipt(
            question: question, queryClass: queryClass, domain: domain,
            outcome: outcome, sources: turn.sources, stages: stages, model: modelName
        )
        continuation.yield(turn)
        continuation.finish()
    }

    // MARK: - The model call

    #if canImport(FoundationModels)

    struct TokenCount: Sendable { let input: Int; let output: Int }
    struct FinishedAnswer: Sendable {
        let insufficient: Bool
        let sentences: [(text: String, source: Int?)]
    }
    enum GenerationResult: Sendable {
        case success(FinishedAnswer, TokenCount?)
        case failure(String)
    }

    @available(macOS 26, *)
    private func session() -> LanguageModelSession {
        if let existing = sessionBox as? LanguageModelSession { return existing }
        let created = LanguageModelSession(instructions: Self.instructions)
        sessionBox = created
        return created
    }

    /// Drop the session, keeping the tail of its transcript.
    ///
    /// Used when the context window fills. Rebuilding from the trailing entries preserves the
    /// recent exchange, which is the part a follow-up question depends on, and discards the
    /// older source blocks, which are the bulk of the tokens.
    @available(macOS 26, *)
    private func recycleSession() {
        guard let existing = sessionBox as? LanguageModelSession else { return }
        let tail = Transcript(entries: existing.transcript.suffix(Self.retainedTranscriptEntries))
        sessionBox = LanguageModelSession(transcript: tail)
    }

    /// Transcript entries kept when the context window overflows. Chosen, not measured: enough
    /// for one prior question and answer to survive, few enough that the retry has room.
    static let retainedTranscriptEntries = 4

    @available(macOS 26, *)
    private func generate(
        question: String,
        sources: [GroundingSource],
        onPartial: (String) -> Void
    ) async -> GenerationResult {
        do {
            return try await stream(question: question, sources: sources, onPartial: onPartial)
        } catch {
            guard Self.isContextOverflow(error) else { return .failure(Self.describe(error)) }
            // Recoverable exactly once: shed the old transcript and ask again.
            recycleSession()
            do {
                return try await stream(question: question, sources: sources, onPartial: onPartial)
            } catch {
                return .failure("The question and its sources do not fit in the model's context window, even after clearing the conversation history.")
            }
        }
    }

    @available(macOS 26, *)
    private func stream(
        question: String,
        sources: [GroundingSource],
        onPartial: (String) -> Void
    ) async throws -> GenerationResult {
        var sentences: [(text: String, source: Int?)] = []
        var insufficient = false
        var tokens: TokenCount?

        let responses = session().streamResponse(
            to: Self.prompt(question: question, sources: sources),
            generating: GroundedAnswer.self,
            options: Self.options
        )

        for try await snapshot in responses {
            insufficient = snapshot.content.insufficient ?? false
            sentences = (snapshot.content.sentences ?? []).compactMap { part in
                guard let text = part.text, !text.isEmpty else { return nil }
                return (text: text, source: part.source)
            }
            onPartial(Self.render(sentences))
            if #available(macOS 27, *) {
                tokens = TokenCount(
                    input: snapshot.usage.input.totalTokenCount,
                    output: snapshot.usage.output.totalTokenCount
                )
            }
        }

        return .success(FinishedAnswer(insufficient: insufficient, sentences: sentences), tokens)
    }

    /// Greedy sampling, because this is extraction rather than composition.
    ///
    /// Chosen, not measured, but for a stated reason: the same question over the same passages
    /// should give the same answer, and creative sampling is how a model starts smoothing a
    /// source into something more readable than what it says. `maximumResponseTokens` bounds a
    /// runaway generation; the schema already caps the sentence count.
    @available(macOS 26, *)
    static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 700)

    /// Whether the failure was the context window filling up, which is the one failure worth
    /// retrying rather than reporting.
    ///
    /// Detectable only on macOS 27 and later. `LanguageModelSession.GenerationError`, which
    /// carried the equivalent case before, is deprecated in full as of macOS 27, and reaching
    /// for a deprecated symbol to gain one retry on macOS 26 is not worth it. On macOS 26 an
    /// overflow is reported instead of retried.
    static func isContextOverflow(_ error: any Error) -> Bool {
        if #available(macOS 27, *), let modelError = error as? LanguageModelError {
            if case .contextSizeExceeded = modelError { return true }
        }
        return false
    }

    /// Map the framework's error taxonomy to something a reader can act on.
    ///
    /// These were previously stringified into the UI as `"\(error)"`. They are distinguished
    /// now because they mean genuinely different things, and one of them is a product fact:
    /// a guardrail violation means Apple's safety system refused to discuss *the user's own
    /// recorded history*, which is worth saying out loud rather than burying.
    ///
    /// Written against `LanguageModelError` and `SystemLanguageModel.Error` rather than
    /// `LanguageModelSession.GenerationError`, whose every case Apple deprecated in macOS 27.
    static func describe(_ error: any Error) -> String {
        if #available(macOS 27, *) {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .guardrailViolation:
                    return "Apple's on-device safety system stopped this answer. It can fire on your own records, medical ones especially. The passages it was reading are listed below and are unaffected."
                case .contextSizeExceeded:
                    return "The question and its sources do not fit in the model's context window."
                case .rateLimited:
                    return "The on-device model is rate limited. Try again shortly."
                case .refusal:
                    return "The model declined to answer this question."
                case .unsupportedCapability:
                    return "This answer needs a model capability that is unavailable here."
                case .unsupportedTranscriptContent:
                    return "The conversation history contains something this model cannot read. Starting a new conversation clears it."
                case .unsupportedGenerationGuide:
                    return "The answer schema uses a constraint this model does not support. That is a bug in OpenCore, not in your data."
                case .unsupportedLanguageOrLocale:
                    return "The on-device model does not support this language."
                case .timeout:
                    return "The model timed out before finishing the answer."
                @unknown default:
                    return modelError.localizedDescription
                }
            }
            if let assetError = error as? SystemLanguageModel.Error {
                switch assetError {
                case .assetsUnavailable:
                    return "The on-device model's assets are unavailable. Check that Apple Intelligence is on and has finished downloading."
                @unknown default:
                    return assetError.localizedDescription
                }
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    #endif

    // MARK: - Rendering

    /// Reassemble sentences into prose carrying `[n]` markers.
    ///
    /// The markers are produced here from typed fields rather than requested from the model
    /// and parsed back out, so the UI's inline citation chips render from data that was never
    /// a string the model had to format correctly.
    static func render(_ sentences: [(text: String, source: Int?)]) -> String {
        sentences.map { sentence in
            guard let source = sentence.source else { return sentence.text }
            return "\(sentence.text) [\(source)]"
        }.joined(separator: " ")
    }

    // MARK: - Receipt

    /// Turn what retrieval actually measured into stages.
    ///
    /// `PassageOutcome` has carried these counters all along; the chat path used to discard
    /// them and write `stages: []`, which is the receipt claiming a multi-stage pipeline ran
    /// no stages.
    static func retrievalStages(_ outcome: PassageOutcome) -> [ReceiptStage] {
        var stages: [ReceiptStage] = [
            ReceiptStage(
                name: "retrieve",
                counters: [
                    "chunksSearched": outcome.chunksSearched,
                    "lexicalCandidates": outcome.lexicalCandidates,
                    "denseCandidates": outcome.denseCandidates,
                    "afterFusion": outcome.afterFusion,
                    "blockedByDomain": outcome.blockedByDomain,
                    "droppedByDiversity": outcome.droppedByDiversity,
                ],
                milliseconds: outcome.stageTimings.values.reduce(0, +),
                note: outcome.unavailableSignals.isEmpty
                    ? nil
                    : outcome.unavailableSignals.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
            )
        ]
        for (name, milliseconds) in outcome.stageTimings.sorted(by: { $0.key < $1.key }) {
            stages.append(ReceiptStage(name: name, milliseconds: milliseconds))
        }
        return stages
    }

    static func receipt(
        question: String,
        queryClass: QueryClass,
        domain: Domain,
        outcome: PassageOutcome,
        sources: [GroundingSource],
        stages: [ReceiptStage],
        model: String?
    ) -> Receipt {
        Receipt(
            query: question,
            queryClass: queryClass,
            // The domain the query was classified into and therefore searched under. The
            // count of passages withheld is a stage counter; the framework does not report
            // *which* domains they belonged to, so no list of blocked domains is invented.
            domainsAdmitted: [domain],
            domainsBlocked: [],
            stages: stages,
            objectsSearched: outcome.chunksSearched,
            objectsRetrieved: sources.count,
            evidenceAdmitted: sources.count,
            // Genuinely zero: this path answers from passages and never reads the claim
            // table. Not a placeholder.
            claimsConsulted: 0,
            contradictionsSurfaced: 0,
            model: model,
            // On-device. This becomes non-zero the day a cloud model is offered, and it must
            // be counted then rather than assumed.
            objectsTransmitted: 0,
            confidence: nil
        )
    }

    // MARK: - Prompting

    /// Note what is *not* here: the previous version told the model to "prefer the words in
    /// the sources" because the answer would be checked against them. That taught the model to
    /// pass `Grounding`'s lexical test, making a high score evidence of compliance rather than
    /// of grounding. Removing it is why the scores mean something now.
    static let instructions = """
    You answer questions about one person's own recorded history.

    You are given numbered sources. They are the only thing you know.

    Rules, in order of importance:
    1. Every sentence must state something one of the sources says, and must record which \
       source it came from.
    2. If the sources do not answer the question, set `insufficient` and give no sentences. A \
       plausible answer assembled from unrelated sources is worse than no answer, because it \
       cannot be told apart from a correct one.
    3. Add nothing from outside the sources. Not context, not background, not inference.
    4. Report what a source states. Never draw a conclusion about health, finances, or \
       relationships from it.
    5. Be brief. Three sentences is usually enough.
    """

    static func prompt(question: String, sources: [GroundingSource]) -> String {
        """
        Sources:

        \(sources.map { "[\($0.index)] \($0.title)\n\($0.text)" }.joined(separator: "\n\n"))

        Question: \(question)
        """
    }
}
