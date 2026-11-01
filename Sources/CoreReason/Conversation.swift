import CoreModel
import CoreSearch
import CoreStore
import CoreTelemetry
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A cited passage handed to the model, numbered so the answer can point at it.
public struct GroundingSource: Sendable, Identifiable, Hashable, Codable {
    public var id: Int { index }
    public let index: Int
    public let title: String
    public let text: String
    public let objectID: ObjectID
    public let authority: Authority
    public let uri: String?
    /// Set when this source is one stored claim rather than a passage. Optional so that turns
    /// saved before it existed still decode.
    public let claimID: ClaimID?

    public init(
        index: Int,
        title: String,
        text: String,
        objectID: ObjectID,
        authority: Authority,
        uri: String? = nil,
        claimID: ClaimID? = nil
    ) {
        self.index = index
        self.title = title
        self.text = text
        self.objectID = objectID
        self.authority = authority
        self.uri = uri
        self.claimID = claimID
    }
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
    /// Set when the turn could not be written to the store. Distinct from `error`, which means
    /// the answer itself failed: this one has a perfectly good answer that will not survive
    /// closing the window. Reported rather than swallowed, because the reader is about to
    /// assume it was saved.
    public var persistenceError: String?
    /// True while tokens are still arriving, so the UI can show a caret without guessing.
    public var streaming: Bool

    /// - Parameter id: pass the stored id when rehydrating a saved turn. A fresh one otherwise.
    ///   This is not cosmetic: anything written back against a turn later, a judgement most of
    ///   all, addresses the row by this id, so a reopened thread that minted new ids would write
    ///   verdicts against rows that do not exist.
    public init(
        role: Role,
        text: String = "",
        sources: [GroundingSource] = [],
        verdicts: [Grounding.Verdict] = [],
        receipt: Receipt? = nil,
        modelName: String? = nil,
        error: String? = nil,
        streaming: Bool = false,
        id: UUID? = nil
    ) {
        self.id = id ?? UUID()
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
/// code; the model receives only those passages, plus any stored claims the question asked for
/// by name, and answers into a schema that forces every sentence to name the source it came
/// from. Afterwards each sentence is checked against *that* source by `Grounding`, and anything
/// failing is shown as failing rather than removed.
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
    private let currentDate: @Sendable () -> Date
    private let currentCalendar: @Sendable () -> Calendar

    public struct GenerationConfiguration: Sendable, Equatable {
        public let reasoningLevel: String
        public let includeSchemaInPrompt: Bool
        public init(reasoningLevel: String = "moderate", includeSchemaInPrompt: Bool = true) {
            self.reasoningLevel = ["light", "moderate", "deep"].contains(reasoningLevel) ? reasoningLevel : "moderate"
            self.includeSchemaInPrompt = includeSchemaInPrompt
        }
    }
    private var generationConfiguration = GenerationConfiguration()

    /// Applies to in-process macOS 27 generation. The fm CLI exposes neither setting.
    public func configureGeneration(_ configuration: GenerationConfiguration) {
        generationConfiguration = configuration
    }

    /// Thread identity. Stable across turns, so every exchange lands in one saved conversation
    /// and a reopened thread keeps appending to itself rather than forking a new one.
    public let id: String

    /// Next position in the thread. Held here rather than read back from the database on every
    /// turn, and seeded from the stored count by `restore()`, so a resumed thread continues its
    /// numbering instead of overwriting from zero.
    private var ordinal = 0

    /// Prior user questions and cited source titles in this thread, kept so retrieval can
    /// resolve follow-up questions ("what language is it written in?", "what about the second
    /// one?") before the language model is called.
    private var priorQuestions: [String] = []
    private var priorSourceTitles: [String] = []
    /// The window the last turn read, so "and OpenClinic?" stays in the week it followed.
    ///
    /// Held as a value because the text cannot carry it. Follow-up anchors are search terms, so
    /// "last week" came through by accident as two words and could then beat the phrase in the
    /// new question, while "recently" is a stopword and never came through at all. Not restored
    /// with a saved thread: the week it meant may be over.
    private var priorWindow: QueryTimeWindow?

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

    /// Stored claims handed to the model, one source each. **Chosen, not measured:** enough for
    /// a status with its objective and next action, and half of `sourceCount` stays for passages.
    static let askedClaimsShown = 3

    /// How many pieces of counter-evidence, and how many contradictions, one claim line carries.
    /// **Chosen, not measured:** the number of counter-evidence lines `core_ask` prints.
    static let caveatsShown = 2

    /// Where a quoted caveat is cut, in characters. **Chosen, not measured:** `core_ask`'s cut.
    static let caveatLength = 180

    /// Ends the title of a claim source. The subject comes first so a follow-up anchors on it,
    /// and `cleanSourceAnchor` splits here.
    static let claimTitleSuffix = " · stored claim"

    /// How far past `sourceCount` retrieval reaches when the question names something, so
    /// passages about that thing can be found behind better-scoring ones about others.
    /// **Chosen, not measured.** MMR then has `2 * limit` to choose from, so this is cheap.
    static let namedRetrievalFactor = 3

    /// What chat read from the claim table for one question: only what reached the model, in
    /// the units `Reasoner` writes, so one receipt column has one meaning on both paths.
    struct ClaimReading: Sendable {
        /// The rows behind the lines the model was shown, not every line that matched.
        var claims: [ClaimID] = []
        /// The evidence behind those lines, ranked for `receipt_evidence`.
        var evidence: [(EvidenceID, Double)] = []
        /// How many contradictions were put in front of the model.
        var contradictions = 0

        static let none = ClaimReading()
    }

    /// What chat hands the model for one question.
    struct Retrieval {
        var outcome: PassageOutcome
        var sources: [GroundingSource]
        var reading: ClaimReading

        var claimsConsulted: Int { reading.claims.count }
    }

    public init(
        store: Store,
        embedder: (any EmbeddingProvider)? = nil,
        tuning: RetrievalTuning = .default,
        id: String = UUID().uuidString,
        now: @autoclosure @escaping @Sendable () -> Date = Date(),
        calendar: @autoclosure @escaping @Sendable () -> Calendar = .current
    ) {
        self.store = store
        self.search = PassageSearch(store: store, embedder: embedder, tuning: tuning)
        self.id = id
        self.currentDate = now
        self.currentCalendar = calendar
    }

    // MARK: - Saved threads

    /// Reopen a saved thread: returns its turns for display **and** rebuilds the model's context
    /// from them.
    ///
    /// Both halves matter, and only doing the first is the tempting mistake. Showing the history
    /// while handing the model an empty session produces a thread that looks resumed and answers
    /// as though it has amnesia: "what about the second one" would be met with a request for
    /// clarification directly underneath a visible list of three. The stored exchanges are
    /// replayed into a real `Transcript`, so a follow-up question works the way it does within
    /// one sitting.
    ///
    /// What is deliberately **not** restored is the passage text of old turns. Those sources are
    /// shown from storage but are not put back into the model's context, because they were
    /// retrieved against a store that may have changed since. Retrieval runs fresh for every new
    /// question, which is the same rule as any other turn. Nor is anything this program wrote
    /// itself: see `replayedExchanges`.
    @discardableResult
    public func restore() async throws -> [Turn] {
        let stored = try await store.turns(conversationID: id)
        ordinal = stored.count

        let decoder = JSONDecoder()
        let turns: [Turn] = stored.map { row in
            var turn = Turn(
                role: row.role == Turn.Role.you.rawValue ? .you : .core,
                text: row.text,
                sources: (try? decoder.decode([GroundingSource].self, from: Data(row.sourcesJSON.utf8))) ?? [],
                verdicts: (try? decoder.decode([Grounding.Verdict].self, from: Data(row.verdictsJSON.utf8))) ?? [],
                modelName: row.model,
                error: row.error,
                // Carried through, not regenerated. A verdict clicked on a reopened thread has
                // to reach the row it is about.
                id: UUID(uuidString: row.id)
            )
            turn.streaming = false
            return turn
        }

        priorQuestions = turns.filter { $0.role == .you && !$0.text.isEmpty }.map(\.text)
        if let lastCore = turns.last(where: { $0.role == .core && !$0.sources.isEmpty }) {
            priorSourceTitles = lastCore.sources.map(\.title)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, *) { rebuildSession(from: turns) }
        #endif
        return turns
    }

    /// What a restored session is told it said: the exchanges a model wrote, as the model wrote
    /// them.
    ///
    /// **The defect.** Everything saved was replayed, so a reopened thread gave the model `Window:`,
    /// `Store:` and `Stale:` lines as its own earlier words, and whole event-log summaries it had
    /// never seen. Those lines are added after a model finishes so that they are not its to get
    /// wrong, and a live session never holds them. So a turn no model wrote goes back with its
    /// question, and a turn one did goes back without the report.
    ///
    /// Takes `Turn`s rather than building a `Transcript`, so a test can read the result without
    /// a model being available.
    static func replayedExchanges(_ turns: [Turn]) -> [(question: String, answer: String)] {
        var exchanges: [(question: String, answer: String)] = []
        var asked: String?
        for turn in turns {
            switch turn.role {
            case .you:
                asked = turn.text.isEmpty ? nil : turn.text
            case .core:
                if let question = asked, turn.modelName != nil, !turn.text.isEmpty {
                    exchanges.append((question, WindowReport.removed(from: turn.text)))
                }
                asked = nil
            }
        }
        return exchanges
    }

    #if canImport(FoundationModels)
    /// Replay stored exchanges into a fresh session's transcript.
    ///
    /// The instructions entry is written first and identically to a live session's, or the
    /// restored model would keep the conversation but lose the rules that make its answers
    /// citable, which is a worse failure than losing the conversation.
    @available(macOS 26, *)
    private func rebuildSession(from turns: [Turn]) {
        func segments(_ text: String) -> [Transcript.Segment] {
            [.text(Transcript.TextSegment(content: text))]
        }

        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: segments(Self.instructions), toolDefinitions: []))
        ]
        for exchange in Self.replayedExchanges(turns) {
            entries.append(.prompt(Transcript.Prompt(segments: segments(exchange.question))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: segments(exchange.answer))))
        }
        sessionBox = LanguageModelSession(transcript: Transcript(entries: entries))
    }
    #endif

    /// Persist one turn, and the thread it belongs to.
    ///
    /// Returns a message on failure rather than throwing, because a chat answer that is already
    /// on screen must not be destroyed by a storage problem. It is reported instead of swallowed:
    /// the caller puts it on the turn, so "this was not saved" reaches the reader who is about to
    /// rely on it being saved.
    private func persist(_ turn: Turn, title: String, reading: ClaimReading = .none) async -> String? {
        do {
            try await store.openConversation(id: id, title: title)
            // The receipt goes in its own table so `opencore trace` reaches a saved chat turn.
            // Before this, chat receipts were built, printed by short code, and dropped.
            // The links are what `trace` reads. Without them a turn that used claims reported
            // them and then traced to "admitted no evidence".
            if let receipt = turn.receipt {
                try await store.save(receipt, evidence: reading.evidence, claims: reading.claims)
            }
            let encoder = JSONEncoder()
            try await store.append(StoredTurn(
                id: turn.id.uuidString,
                conversationID: id,
                ordinal: ordinal,
                role: turn.role.rawValue,
                text: turn.text,
                sourcesJSON: String(decoding: (try? encoder.encode(turn.sources)) ?? Data("[]".utf8), as: UTF8.self),
                verdictsJSON: String(decoding: (try? encoder.encode(turn.verdicts)) ?? Data("[]".utf8), as: UTF8.self),
                receiptID: turn.receipt?.id,
                model: turn.modelName,
                error: turn.error
            ))
            ordinal += 1
            return nil
        } catch {
            return "not saved: \(error)"
        }
    }

    /// A thread's label, taken from its first question.
    ///
    /// Not model-generated. A title is a label, and spending a model call on one would make
    /// opening the sidebar depend on Apple Intelligence being available.
    static func title(from question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed.isEmpty ? "Untitled" : trimmed }
        let cut = trimmed.prefix(60)
        // Break on a word boundary when there is one close to the limit, so a title does not
        // end mid-word for the sake of four characters.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 40 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
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
        guard #available(macOS 26, *) else {
            return isFoundationModelsCLIAvailable() ? .ready(fmCLIModelIdentity) : .unsupportedOS
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready(modelIdentity)
        case .unavailable(let reason):
            if isFoundationModelsCLIAvailable() {
                return .ready(fmCLIModelIdentity)
            }
            return switch reason {
            case .appleIntelligenceNotEnabled: .appleIntelligenceOff
            case .modelNotReady: .modelDownloading
            case .deviceNotEligible: .deviceNotEligible
            @unknown default: .unknown("The on-device model is unavailable for an unrecognised reason.")
            }
        @unknown default:
            return isFoundationModelsCLIAvailable()
                ? .ready(fmCLIModelIdentity)
                : .unknown("The on-device model reported an unrecognised availability state.")
        }
        #else
        return isFoundationModelsCLIAvailable() ? .ready(fmCLIModelIdentity) : .unsupportedOS
        #endif
    }

    /// Live telemetry from `FoundationModels` (`MacOSX27.0.sdk` `SystemLanguageModel` and
    /// `PrivateCloudComputeLanguageModel`, cited 2026-10-22).
    public struct FoundationModelsTelemetry: Sendable, Equatable {
        public let modelVariant: String
        public let contextWindowTokens: Int?
        public let capabilities: [String]
        public let privateCloudComputeAvailable: Bool
        public let privateCloudComputeQuotaReached: Bool
        public let fmCLIAvailable: Bool

        public init(
            modelVariant: String,
            contextWindowTokens: Int?,
            capabilities: [String],
            privateCloudComputeAvailable: Bool,
            privateCloudComputeQuotaReached: Bool,
            fmCLIAvailable: Bool
        ) {
            self.modelVariant = modelVariant
            self.contextWindowTokens = contextWindowTokens
            self.capabilities = capabilities
            self.privateCloudComputeAvailable = privateCloudComputeAvailable
            self.privateCloudComputeQuotaReached = privateCloudComputeQuotaReached
            self.fmCLIAvailable = fmCLIAvailable
        }
    }

    public static func telemetry() -> FoundationModelsTelemetry {
        let cliReady = isFoundationModelsCLIAvailable()
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let sys = SystemLanguageModel.default
            let variantName = sys.variant.displayName
            let ctxSize = sys.contextSize
            var caps: [String] = []
            let rawCaps = sys.capabilities
            if rawCaps.contains(.guidedGeneration) { caps.append("guided-generation") }
            if rawCaps.contains(.reasoning) { caps.append("reasoning") }
            if rawCaps.contains(.toolCalling) { caps.append("tool-calling") }
            if rawCaps.contains(.vision) { caps.append("vision") }
            let pcc = PrivateCloudComputeLanguageModel()
            return FoundationModelsTelemetry(
                modelVariant: variantName,
                contextWindowTokens: ctxSize,
                capabilities: caps,
                privateCloudComputeAvailable: pcc.isAvailable,
                privateCloudComputeQuotaReached: pcc.quotaUsage.isLimitReached,
                fmCLIAvailable: cliReady
            )
        }
        #endif
        return FoundationModelsTelemetry(
            modelVariant: cliReady ? "Apple Foundation Model (/usr/bin/fm)" : "Unavailable",
            contextWindowTokens: nil,
            capabilities: [],
            privateCloudComputeAvailable: false,
            privateCloudComputeQuotaReached: false,
            fmCLIAvailable: cliReady
        )
    }

    /// Count tokens in `text` using `SystemLanguageModel.default.tokenCount(for:)` (`@available(macOS 26.4, *)`,
    /// cited 2026-10-22 from `MacOSX27.0.sdk`), falling back to a lexical approximation when unavailable.
    public static func estimateTokenCount(for text: String) async -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        #if canImport(FoundationModels)
        if #available(macOS 26.4, *) {
            if let exact = try? await SystemLanguageModel.default.tokenCount(for: trimmed) {
                return exact
            }
        }
        #endif
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        return max(1, Int((Double(words) * 1.3).rounded(.up)))
    }

    /// What goes in `Receipt.model`.
    ///
    /// The framework exposes no version or build identifier for the on-device model, so this
    /// names the model and stops. Inventing a version string here would be exactly the
    /// "plausible default in a receipt field" the receipt exists to refuse.
    static let modelIdentity = "Apple on-device (SystemLanguageModel.default)"

    /// Receipt model name when Apple's macOS 27 `/usr/bin/fm` CLI executes the on-device
    /// Foundation Model with `--guardrails permissive-content-transformations` and our
    /// `GroundedAnswer` JSON schema.
    public static let fmCLIModelIdentity = "Apple on-device Foundation Model (/usr/bin/fm)"

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
            let producer = Task { await self.answer(question, into: continuation) }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// Persist the finished turn, emit it, and close the stream.
    ///
    /// **Every** exit from `answer` goes through here. The alternative, saving at each return
    /// site, is the shape where one path is added later and quietly does not save, and the
    /// symptom is a thread that is missing exactly the answers that took an unusual route.
    private func complete(
        _ turn: Turn, title: String, reading: ClaimReading = .none, into continuation: AsyncStream<Turn>.Continuation
    ) async {
        var turn = turn
        turn.streaming = false
        turn.persistenceError = await persist(turn, title: title, reading: reading)
        continuation.yield(turn)
        continuation.finish()
    }

    private func answer(_ question: String, into continuation: AsyncStream<Turn>.Continuation) async {
        var turn = Turn(role: .core, streaming: true)
        let started = DispatchTime.now().uptimeNanoseconds
        let title = Self.title(from: question)

        // The question is saved before any work begins. Saving it afterwards would lose it
        // whenever the answer is the thing that failed, which is when a record of what was
        // asked is most useful.
        let asked = Turn(role: .you, text: question)
        if let failure = await persist(asked, title: title) {
            turn.persistenceError = failure
        }

        let retrievalQuery = Self.contextualizedQuery(
            question,
            priorQuestions: priorQuestions,
            priorSourceTitles: priorSourceTitles
        )
        priorQuestions.append(question)

        // ---- Retrieve, before the model is involved at all ----
        let outcome: PassageOutcome
        let reading: ClaimReading
        let domain: Domain
        let policy: AdmissionPolicy
        let queryClass: QueryClass
        var report: WindowReport?
        var reportMilliseconds = 0
        do {
            queryClass = QueryClassifier().classify(retrievalQuery).queryClass
            let (queryDomain, requested) = AdmissionPolicy.classifyDomain(
                retrievalQuery,
                knownEntitySurfaces: try await store.aliasSurfaces()
            )
            domain = queryDomain
            policy = AdmissionPolicy(queryDomain: queryDomain, explicitlyRequested: requested)

            // A time phrase is a filter. See `TemporalIntent` for what it used to be. Read from
            // the question and not from `retrievalQuery`, whose anchors are the last question's
            // words: the phrase asked now has to win over one left over from before.
            let calendar = currentCalendar()
            let ownWindow = TemporalIntent.window(in: question, now: currentDate(), calendar: calendar)
            let window = ownWindow ?? (Self.readsAsFollowUp(question) ? priorWindow : nil)
            priorWindow = window
            // Only this question's phrase can be in the text. `contextualizedQuery` keeps the
            // last one out of the anchors.
            let searchText = ownWindow.map { TemporalIntent.residual(of: retrievalQuery, removing: [$0.phrase]) } ?? retrievalQuery

            // A counting question is computed over every admitted row, never by counting the
            // passages that happened to be retrieved. Placed after the firewall on purpose:
            // the count runs under exactly the domains retrieval would have been allowed to
            // read. See `AggregateAnswering` for the measurement that put this here. It counts
            // all of time, so a count with a window goes to the event log, unless the phrase
            // only asks how things stand now. `Reasoner.answer` has both cases.
            let countable: String? = if let window { window.meansNow ? searchText : nil } else { retrievalQuery }
            if queryClass == .aggregate, let countable,
               let counted = try await AggregateAnswering(store: store)
                   .answer(countable, admitting: policy.admitted) {
                turn.text = counted.sentence
                turn.receipt = Self.countedReceipt(
                    question: question,
                    domain: queryDomain,
                    admitted: Array(policy.admitted),
                    blocked: Array(policy.blocked),
                    counted: counted,
                    milliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                )
                await complete(turn, title: title, into: continuation)
                return
            }

            if let window {
                let reportStart = DispatchTime.now().uptimeNanoseconds
                report = try await store.windowReport(window, domains: policy.admitted, calendar: calendar)
                reportMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - reportStart) / 1_000_000)
            }

            // "What was I working on last week" has no subject to search for, and no passage
            // says what happened. Like a count, it is computed rather than retrieved, so no
            // model writes it and it needs no citation to be true. A named repository changes
            // which events, not where they come from: "what did I change in OpenClinic last
            // week" went to the model over passages, while `ask` read the event log.
            //
            // The name can come from the anchors ("and what about it?"). Whether anything else
            // is being asked comes from the question alone, because anchors are stemmed search
            // terms: "working" arrives as "work worke", which is no one's topic.
            let focus = try await QueryFocus.read(from: searchText, store: store, policy: policy, externalCaller: false)
            let ownWords = window.map { TemporalIntent.residual(of: question, removing: [$0.phrase]) } ?? question
            if let window, let report,
               queryClass == .aggregate || TemporalIntent.isSubjectless(ownWords, naming: focus.namedWords) {
                let activityStart = DispatchTime.now().uptimeNanoseconds
                let summary = try await store.activity(
                    from: window.start,
                    to: window.end,
                    domains: policy.admitted,
                    subjects: focus.entities.isEmpty ? nil : Set(focus.entities)
                )
                let milliseconds = Int((DispatchTime.now().uptimeNanoseconds - activityStart) / 1_000_000)
                turn.text = Self.activityText(
                    summary,
                    report: report,
                    uncounted: queryClass == .aggregate ? TemporalIntent.unplacedTerms(in: ownWords, naming: focus.namedWords) : []
                )
                turn.receipt = Receipt(
                    query: question,
                    queryClass: queryClass,
                    domainsAdmitted: Array(policy.admitted).sorted { $0.rawValue < $1.rawValue },
                    domainsBlocked: Array(policy.blocked).sorted { $0.rawValue < $1.rawValue },
                    stages: [ReceiptStage(
                        name: "activity",
                        counters: ["events_in_window": summary.totalEvents, "subjects": summary.totalSubjects],
                        milliseconds: milliseconds,
                        note: report.stageNote
                    )],
                    objectsSearched: summary.totalEvents,
                    objectsRetrieved: 0,
                    evidenceAdmitted: 0,
                    claimsConsulted: 0,
                    contradictionsSurfaced: 0,
                    model: nil,
                    objectsTransmitted: 0,
                    confidence: nil
                )
                await complete(turn, title: title, into: continuation)
                return
            }

            let retrieved = try await retrieve(
                query: searchText,
                queryClass: queryClass,
                policy: policy,
                window: window
            )
            outcome = retrieved.outcome
            turn.sources = retrieved.sources
            reading = retrieved.reading
        } catch {
            turn.error = "retrieval failed: \(error)"
            await complete(turn, title: title, into: continuation)
            return
        }

        if !turn.sources.isEmpty {
            priorSourceTitles = turn.sources.map(\.title)
        }
        continuation.yield(turn)

        var stages = Self.retrievalStages(outcome)
        if let report {
            stages.append(ReceiptStage(
                name: "window",
                counters: ["sources_reported": report.freshness.sources.count, "sources_behind": report.behind.count],
                milliseconds: reportMilliseconds,
                note: report.stageNote
            ))
        }

        guard !turn.sources.isEmpty else {
            // No model call at all. Inventing prose over an empty context is exactly the
            // failure this design exists to prevent, and it is also the cheapest possible
            // thing to get wrong.
            turn.text = "Nothing in your history matches that. \(outcome.chunksSearched) passages searched"
                + (outcome.blockedByDomain > 0 ? ", \(outcome.blockedByDomain) withheld by domain policy." : ".")
            if let report { turn.text += "\n\n\(report.text)" }
            turn.receipt = Self.receipt(
                question: question, queryClass: queryClass, domain: domain,
                admitted: Array(policy.admitted), blocked: Array(policy.blocked),
                outcome: outcome, sources: [], stages: stages, model: nil,
                reading: reading
            )
            await complete(turn, title: title, into: continuation)
            return
        }

        if Task.isCancelled {
            turn.error = "Stopped by you."
            await complete(turn, title: title, into: continuation)
            return
        }

        // ---- Generate ----
        let generationStarted = DispatchTime.now().uptimeNanoseconds
        var modelName: String?
        var objectsTransmitted = 0
        let hasSensitiveContent = domain.isSensitive
            || policy.admitted.contains(where: \.isSensitive)
            || outcome.hits.contains(where: { $0.object.domain.isSensitive })

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let result = await generate(question: question, sources: turn.sources) { partial in
                turn.text = partial
                continuation.yield(turn)
            }
            if Task.isCancelled {
                turn.error = "Stopped by you."
                await complete(turn, title: title, into: continuation)
                return
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
                if let tokens {
                    counters["inputTokens"] = tokens.input
                    counters["outputTokens"] = tokens.output
                    counters["cachedInputTokens"] = tokens.cachedInput
                    counters["reasoningTokens"] = tokens.reasoningOutput
                }
                stages.append(ReceiptStage(
                    name: "generate",
                    counters: counters,
                    milliseconds: Int((DispatchTime.now().uptimeNanoseconds - generationStarted) / 1_000_000),
                    note: Self.modelIdentity
                ))
            case .failure(let message):
                await applyFallbackSynthesis(
                    question: question,
                    hasSensitiveContent: hasSensitiveContent,
                    reason: message,
                    generationStarted: generationStarted,
                    turn: &turn,
                    stages: &stages,
                    modelName: &modelName,
                    objectsTransmitted: &objectsTransmitted
                )
            }
        } else {
            await applyFallbackSynthesis(
                question: question,
                hasSensitiveContent: hasSensitiveContent,
                reason: Readiness.unsupportedOS.message,
                generationStarted: generationStarted,
                turn: &turn,
                stages: &stages,
                modelName: &modelName,
                objectsTransmitted: &objectsTransmitted
            )
        }
        #else
        await applyFallbackSynthesis(
            question: question,
            hasSensitiveContent: hasSensitiveContent,
            reason: Readiness.unsupportedOS.message,
            generationStarted: generationStarted,
            turn: &turn,
            stages: &stages,
            modelName: &modelName,
            objectsTransmitted: &objectsTransmitted
        )
        #endif

        // Added after the model has finished, and never handed to it, then or on a reopened
        // thread (`replayedExchanges`). A model's prose stays checkable sentence by sentence, and
        // these lines are not its to get wrong.
        if let report, !turn.text.isEmpty { turn.text += "\n\n\(report.text)" }

        // ---- Record ----
        stages.append(ReceiptStage(
            name: "total",
            milliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        ))
        turn.receipt = Self.receipt(
            question: question, queryClass: queryClass, domain: domain,
            admitted: Array(policy.admitted), blocked: Array(policy.blocked),
            outcome: outcome, sources: turn.sources, stages: stages,
            model: modelName, objectsTransmitted: objectsTransmitted,
            reading: reading
        )
        await complete(turn, title: title, reading: reading, into: continuation)
    }

    /// Gather what the model may read for one question.
    ///
    /// Focused the same way `Reasoner` is, because chat had the same defect in a worse form. It
    /// took the top six passages for "status of OpenClinic" whatever they were about, and it
    /// never read a claim, so `status`, which is derived and appears in no passage, could not
    /// reach the answer at all. An `ask` and a chat about one project could disagree on whether
    /// the store knew it.
    ///
    /// Each claim goes in as its own numbered source, so the model cites them like any other and
    /// `Grounding` checks a sentence against the one line it cited. It is still a writer: the
    /// rows were admitted by the same policy as the passages beside them.
    func retrieve(
        query: String,
        queryClass: QueryClass,
        policy: AdmissionPolicy,
        window: QueryTimeWindow?
    ) async throws -> Retrieval {
        let focus = try await QueryFocus.read(from: query, store: store, policy: policy, externalCaller: false)
        var outcome = try await search.search(
            query: query,
            queryClass: queryClass,
            policy: policy,
            limit: focus.entities.isEmpty ? Self.sourceCount : Self.sourceCount * Self.namedRetrievalFactor,
            window: window?.interval
        )

        let reasoner = Reasoner(store: store, search: search)
        let claims = try await reasoner.askedClaims(focus: focus, window: window, policy: policy)
        let shown = Array(claims.prefix(Self.askedClaimsShown))
        let claimLines = try await claimSources(from: shown, reasoner: reasoner, policy: policy)
        let room = Self.sourceCount - claimLines.sources.count
        outcome.hits = Array(try await reasoner.aboutNamedFirst(outcome.hits, focus: focus, policy: policy).prefix(room))

        var sources = claimLines.sources
        for hit in outcome.hits {
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: hit.object.title,
                text: hit.chunk.text,
                objectID: hit.object.id,
                authority: hit.object.authority,
                uri: hit.object.uri
            ))
        }
        return Retrieval(
            outcome: outcome,
            sources: sources,
            reading: ClaimReading(
                claims: Set(shown.flatMap(\.claimRows)).sorted { $0.value < $1.value },
                evidence: Reasoner.rankedEvidence(shown),
                contradictions: claimLines.contradictions
            )
        )
    }

    /// One source per claim, with everything that qualifies it.
    ///
    /// One source per line because a shared one could only be labelled from its first line:
    /// "which projects use Swift" gave three repositories under one repository's title, a
    /// sentence citing the third line opened the first line's object, and a high-tier first line
    /// lent its label to a lower one.
    ///
    /// The caveats sit on the line because the model reads nothing else. A status with refuting
    /// evidence or an open contradiction used to arrive as a flat fact, while `core_ask` printed
    /// the same claim with COUNTER-EVIDENCE beside it.
    private func claimSources(
        from points: [AnswerPoint],
        reasoner: Reasoner,
        policy: AdmissionPolicy
    ) async throws -> (sources: [GroundingSource], contradictions: Int) {
        let touching = try await reasoner.contradictions(touching: Set(points.flatMap(\.claimRows)), policy: policy)
        var sources: [GroundingSource] = []
        var surfaced = Set<ContradictionID>()

        for point in points {
            guard let evidence = point.supporting.first else { continue }
            let rows = Set(point.claimRows)
            var lines = [point.statement]
            if point.derivation == .inferred {
                lines.append("Inferred by OpenCore from other records. No source states this.")
            }
            for counter in point.counter.prefix(Self.caveatsShown) {
                lines.append("Counter-evidence: \(Self.quoted(counter.snippet))")
            }
            let standing = touching
                .filter { Reasoner.standsAgainst($0, rows: rows) }
                .sorted { ($0.resolution == .unresolved ? 0 : 1, $0.id.value) < ($1.resolution == .unresolved ? 0 : 1, $1.id.value) }
            for contradiction in standing.prefix(Self.caveatsShown) {
                surfaced.insert(contradiction.id)
                let label = contradiction.resolution == .unresolved ? "Open contradiction" : "Overruled"
                let rival = try await reasoner.rivalStatement(in: contradiction, against: rows)
                lines.append("\(label): \(rival.map { "\($0) " } ?? "")(\(Self.quoted(contradiction.reason)))")
            }

            let subject = try await store.entity(point.subject)?.canonicalName ?? point.subject.value
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: subject + Self.claimTitleSuffix,
                text: lines.joined(separator: "\n"),
                objectID: evidence.objectID,
                authority: point.authority,
                claimID: point.claimID
            ))
        }
        return (sources, surfaced.count)
    }

    private static func quoted(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(caveatLength))
    }

    private func applyFallbackSynthesis(
        question: String,
        hasSensitiveContent: Bool,
        reason: String,
        generationStarted: UInt64,
        turn: inout Turn,
        stages: inout [ReceiptStage],
        modelName: inout String?,
        objectsTransmitted: inout Int
    ) async {
        guard !Task.isCancelled else { turn.error = "Stopped by you."; return }
        // Primary on-device fallback: Apple's macOS 27 `/usr/bin/fm` CLI runs the local
        // Foundation Model with `--guardrails permissive-content-transformations` and our
        // `GroundedAnswer` JSON schema. Zero bytes leave the device (`objectsTransmitted = 0`),
        // so this path is safe for sensitive domains (.medical, .financial, .relationships)
        // and recovers from in-process guardrail false positives or ad-hoc signing limits.
        if let fmAnswer = await Self.generateWithFoundationModelsCLI(question: question, sources: turn.sources) {
            modelName = Self.fmCLIModelIdentity
            turn.modelName = Self.fmCLIModelIdentity
            turn.error = nil
            objectsTransmitted = 0
            turn.text = Self.render(fmAnswer.sentences)
            turn.verdicts = fmAnswer.sentences.map {
                grounding.verify(sentence: $0.text, citedSource: $0.source, sources: turn.sources)
            }
            if fmAnswer.insufficient {
                turn.text = "The sources retrieved do not answer that."
                    + (fmAnswer.sentences.isEmpty ? "" : " The closest they come:\n\n" + Self.render(fmAnswer.sentences))
            }
            stages.append(ReceiptStage(
                name: "generate",
                counters: [
                    "sentences": fmAnswer.sentences.count,
                    "objectsTransmitted": 0,
                ],
                milliseconds: Int((DispatchTime.now().uptimeNanoseconds - generationStarted) / 1_000_000),
                note: Self.fmCLIModelIdentity
            ))
            return
        }

        guard !Task.isCancelled else { turn.error = "Stopped by you."; return }

        // Optional cloud fallback: only when explicitly opted in AND neither the query domain,
        // the admitted policy domains, nor any retrieved hit touches a sensitive domain
        // (.medical, .financial, and .relationships never leave the device).
        if !hasSensitiveContent,
           let gemini = await Self.generateWithGemini(question: question, sources: turn.sources) {
            modelName = Self.geminiModelIdentity
            turn.modelName = Self.geminiModelIdentity
            objectsTransmitted = turn.sources.count
            turn.text = Self.render(gemini.sentences)
            turn.verdicts = gemini.sentences.map {
                grounding.verify(sentence: $0.text, citedSource: $0.source, sources: turn.sources)
            }
            if gemini.insufficient {
                turn.text = "The sources retrieved do not answer that."
                    + (gemini.sentences.isEmpty ? "" : " The closest they come:\n\n" + Self.render(gemini.sentences))
            }
            stages.append(ReceiptStage(
                name: "generate",
                counters: [
                    "sentences": gemini.sentences.count,
                    "objectsTransmitted": objectsTransmitted,
                ],
                milliseconds: Int((DispatchTime.now().uptimeNanoseconds - generationStarted) / 1_000_000),
                note: Self.geminiModelIdentity
            ))
            return
        }

        // Deterministic on-device fallback: extract verbatim cited sentences from the top
        // retrieved passages so a guardrail refusal or unavailable model still yields a
        // grounded, inspectable answer with zero bytes transmitted off-device.
        turn.error = reason
        let synthesized = Self.deterministicSynthesis(from: turn.sources)
        if !synthesized.isEmpty {
            turn.text = Self.render(synthesized)
            turn.verdicts = synthesized.map {
                grounding.verify(sentence: $0.text, citedSource: $0.source, sources: turn.sources)
            }
            stages.append(ReceiptStage(
                name: "synthesize_deterministic",
                counters: ["sentences": synthesized.count],
                milliseconds: Int((DispatchTime.now().uptimeNanoseconds - generationStarted) / 1_000_000),
                note: "deterministic passage synthesis"
            ))
        }
    }

    static let geminiModelIdentity = "Google Gemini (gemini-2.5-flash)"
    static let fmExecutablePath = "/usr/bin/fm"

    /// JSON Schema generated by `/usr/bin/fm schema object` for `GroundedAnswer`.
    private static let fmGroundedAnswerSchemaJSON = """
    {
      "title" : "GroundedAnswer",
      "properties" : {
        "sentences" : {
          "items" : {
            "$ref" : "#/$defs/CitedSentence"
          },
          "type" : "array"
        },
        "insufficient" : {
          "type" : "boolean",
          "description" : "True when the sources do not answer the question."
        }
      },
      "x-order" : [
        "insufficient",
        "sentences"
      ],
      "additionalProperties" : false,
      "$defs" : {
        "CitedSentence" : {
          "title" : "CitedSentence",
          "properties" : {
            "source" : {
              "description" : "1-based source number from [1]..[6].",
              "type" : "integer"
            },
            "text" : {
              "description" : "One factual sentence stated by a source.",
              "type" : "string"
            }
          },
          "type" : "object",
          "required" : [
            "text",
            "source"
          ],
          "x-order" : [
            "text",
            "source"
          ],
          "additionalProperties" : false
        }
      },
      "required" : [
        "insufficient",
        "sentences"
      ],
      "type" : "object"
    }
    """

    public static func isFoundationModelsCLIAvailable() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["OPENCORE_DISABLE_FM_CLI"] == "1" { return false }
        return FileManager.default.isExecutableFile(atPath: fmExecutablePath)
    }

    /// What the `fm` prompt can hold. A passage is cut, and a claim line is not: its caveats sit
    /// last, so a cut would drop exactly the part that says it is disputed. It is bounded anyway,
    /// by `caveatsShown` and `caveatLength`.
    static func clippedForCLI(_ sources: [GroundingSource]) -> [GroundingSource] {
        sources.prefix(6).map { src in
            GroundingSource(
                index: src.index,
                title: src.title,
                text: src.claimID == nil ? String(src.text.prefix(900)) : src.text,
                objectID: src.objectID,
                authority: src.authority,
                uri: src.uri,
                claimID: src.claimID
            )
        }
    }

    /// Execute Apple's on-device Foundation Model via `/usr/bin/fm respond` with greedy
    /// sampling, `permissive-content-transformations` guardrails, and our `GroundedAnswer`
    /// structured output schema.
    public static func generateWithFoundationModelsCLI(
        question: String,
        sources: [GroundingSource]
    ) async -> (insufficient: Bool, sentences: [(text: String, source: Int?)])? {
        guard isFoundationModelsCLIAvailable(), !sources.isEmpty else { return nil }

        let schemaURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-grounded-answer-\(UUID().uuidString).json")
        do {
            try Data(fmGroundedAnswerSchemaJSON.utf8).write(to: schemaURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schemaURL.path)
        }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: schemaURL) }

        let promptText = Self.prompt(question: question, sources: clippedForCLI(sources))
        let instructionsText = Self.instructions
        let schemaPath = schemaURL.path
        let executable = fmExecutablePath

        let worker = Task.detached(priority: .userInitiated) { () -> (insufficient: Bool, sentences: [(text: String, source: Int?)])? in
            let arguments = [
                "respond",
                "--no-stream",
                "-g",
                "--guardrails", "permissive-content-transformations",
                "--schema", schemaPath,
                "-i", instructionsText,
                promptText,
            ]
            guard let result = try? BoundedProcess.run(executable: executable, arguments: arguments, timeout: 30),
                  !result.timedOut, result.status == 0, !result.stdout.isEmpty else { return nil }
            let outData = result.stdout

            let rawText = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstBrace = rawText.firstIndex(of: "{"),
                  let lastBrace = rawText.lastIndex(of: "}")
            else { return nil }
            let jsonSlice = String(rawText[firstBrace...lastBrace])
            guard let structured = try? JSONDecoder().decode(GeminiStructuredAnswer.self, from: Data(jsonSlice.utf8)) else {
                return nil
            }

            let parsed = (structured.sentences ?? []).compactMap { item -> (text: String, source: Int?)? in
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (text: trimmed, source: item.source)
            }
            guard !parsed.isEmpty || (structured.insufficient == true) else { return nil }
            return (insufficient: structured.insufficient ?? false, sentences: parsed)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// One-shot grounded synthesis result from `/usr/bin/fm` (with deterministic fallback),
    /// verified sentence-by-sentence via `Grounding.verify`.
    public struct GroundedBrief: Sendable, Equatable {
        public let text: String
        public let sources: [GroundingSource]
        public let verdicts: [Grounding.Verdict]
        public let modelName: String
        public let insufficient: Bool

        public init(
            text: String,
            sources: [GroundingSource],
            verdicts: [Grounding.Verdict],
            modelName: String,
            insufficient: Bool
        ) {
            self.text = text
            self.sources = sources
            self.verdicts = verdicts
            self.modelName = modelName
            self.insufficient = insufficient
        }
    }

    /// Synthesize a cited, grounding-verified brief over `sources` using `/usr/bin/fm` on device
    /// (`objectsTransmitted = 0`), falling back to `deterministicSynthesis` if `/usr/bin/fm` is
    /// unavailable or returns no sentences.
    public static func synthesizeGroundedBrief(
        question: String,
        sources: [GroundingSource]
    ) async -> GroundedBrief? {
        guard !sources.isEmpty else { return nil }
        if let fmResult = await generateWithFoundationModelsCLI(question: question, sources: sources) {
            // An explicit insufficient answer is respected. A failed citation is never printed
            // as grounded prose, even when other sentences passed the lexical check.
            guard !fmResult.insufficient else { return nil }
            if let brief = checkedBrief(sentences: fmResult.sentences, sources: sources, modelName: fmCLIModelIdentity) {
                return brief
            }
        }
        return checkedBrief(sentences: deterministicSynthesis(from: sources), sources: sources, modelName: "Deterministic Passage Synthesis")
    }

    static func checkedBrief(
        sentences: [(text: String, source: Int?)],
        sources: [GroundingSource],
        modelName: String
    ) -> GroundedBrief? {
        let verifier = Grounding()
        let checked = sentences.map { sentence in
            (sentence, verifier.verify(sentence: sentence.text, citedSource: sentence.source, sources: sources))
        }.filter { $0.1.isGrounded }
        guard !checked.isEmpty else { return nil }
        return GroundedBrief(
            text: render(checked.map { $0.0 }), sources: sources,
            verdicts: checked.map { $0.1 }, modelName: modelName, insufficient: false
        )
    }

    /// Analyze an image or screenshot on device using `/usr/bin/fm respond --image <path> --tool ocr --tool barcode`
    /// (`MacOSX27.0.sdk` `/usr/bin/fm`, cited 2026-10-22). Zero bytes leave the Mac.
    public static func analyzeImageWithFoundationModelsCLI(
        imageURL: URL,
        prompt: String = "Describe the visible text, interface elements, architecture diagrams, or structured facts in this image in 2-4 concise sentences."
    ) async -> String? {
        guard isFoundationModelsCLIAvailable(),
              FileManager.default.fileExists(atPath: imageURL.path)
        else { return nil }
        let executable = fmExecutablePath
        let imagePath = imageURL.path

        return await Task.detached(priority: .userInitiated) {
            let arguments = [
                "respond",
                "--no-stream",
                "-g",
                "--guardrails", "permissive-content-transformations",
                "--image", imagePath,
                "--tool", "ocr",
                "--tool", "barcode",
                prompt,
            ]
            guard let result = try? BoundedProcess.run(executable: executable, arguments: arguments, timeout: 30),
                  !result.timedOut, result.status == 0, !result.stdout.isEmpty else { return nil }
            let outData = result.stdout
            let trimmed = String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }

    /// Extract semantic content tags from `text` on device using `/usr/bin/fm respond --use-case content-tagging`
    /// (`MacOSX27.0.sdk` `/usr/bin/fm`, cited 2026-10-22).
    public static func tagContentWithFoundationModelsCLI(text: String) async -> [String] {
        let clipped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
        guard isFoundationModelsCLIAvailable(), !clipped.isEmpty else { return [] }
        let executable = fmExecutablePath

        return await Task.detached(priority: .userInitiated) {
            let arguments = [
                "respond",
                "--no-stream",
                "-g",
                "--use-case", "content-tagging",
                "--guardrails", "permissive-content-transformations",
                "Return up to 6 comma-separated topic tags for the following text:\n\n\(clipped)",
            ]
            guard let result = try? BoundedProcess.run(executable: executable, arguments: arguments, timeout: 30),
                  !result.timedOut, result.status == 0, !result.stdout.isEmpty else { return [] }
            let outData = result.stdout
            let raw = String(decoding: outData, as: UTF8.self)
            let filtered: [String] = raw
                .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "•" })
                .map {
                    $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*#\"'[]")))
                }
                .filter { $0.count >= 2 && $0.count <= 36 }
            return Array(filtered.prefix(6))
        }.value
    }

    /// Extract verbatim sentences from the top three sources, paired with their `[n]` citation
    /// index so `Grounding.verify` can score each sentence against the exact passage it came
    /// from. A passage gives one sentence. A claim gives every line it has, because taking only
    /// the first would state a disputed claim flat whenever the model is unavailable.
    public static func deterministicSynthesis(from sources: [GroundingSource]) -> [(text: String, source: Int?)] {
        var out: [(text: String, source: Int?)] = []
        for source in sources.prefix(3) {
            if source.claimID != nil {
                out += source.text.split(whereSeparator: \.isNewline).map { (text: String($0), source: source.index) }
                continue
            }
            let lines = source.text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    guard line.count >= 12 else { return false }
                    if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("|---") { return false }
                    return true
                }
            guard let chosen = lines.first else { continue }
            let clipped = chosen.count > 220 ? String(chosen.prefix(220)) + "…" : chosen
            out.append((text: clipped, source: source.index))
        }
        return out
    }

    private struct GeminiPayload: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    private struct GeminiStructuredAnswer: Decodable {
        struct Sentence: Decodable {
            let text: String
            let source: Int?
        }
        let insufficient: Bool?
        let sentences: [Sentence]?
    }

    private static func generateWithGemini(
        question: String,
        sources: [GroundingSource]
    ) async -> (insufficient: Bool, sentences: [(text: String, source: Int?)])? {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENCORE_GEMINI_FALLBACK"] == "1" else { return nil }
        guard let apiKey = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"],
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)")
        else { return nil }

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": Self.instructions]]
            ],
            "contents": [
                ["role": "user", "parts": [["text": Self.prompt(question: question, sources: sources)]]]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 700,
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "insufficient": ["type": "BOOLEAN"],
                        "sentences": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "text": ["type": "STRING"],
                                    "source": ["type": "INTEGER"]
                                ],
                                "required": ["text", "source"]
                            ]
                        ]
                    ],
                    "required": ["insufficient", "sentences"]
                ]
            ]
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(GeminiPayload.self, from: data),
              let jsonText = decoded.candidates?.first?.content?.parts?.first?.text,
              let structured = try? JSONDecoder().decode(GeminiStructuredAnswer.self, from: Data(jsonText.utf8))
        else { return nil }

        let parsed = (structured.sentences ?? []).compactMap { item -> (text: String, source: Int?)? in
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (text: trimmed, source: item.source)
        }
        return (insufficient: structured.insufficient ?? false, sentences: parsed)
    }

    // MARK: - The model call

    #if canImport(FoundationModels)

    struct TokenCount: Sendable {
        let input: Int
        let output: Int
        let cachedInput: Int
        let reasoningOutput: Int
    }
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
        let promptText = Self.prompt(question: question, sources: sources)

        if #available(macOS 27.0, *) {
            let level: ContextOptions.ReasoningLevel = switch generationConfiguration.reasoningLevel {
            case "light": .light
            case "deep": .deep
            default: .moderate
            }
            let ctxOptions = ContextOptions(
                includeSchemaInPrompt: generationConfiguration.includeSchemaInPrompt,
                reasoningLevel: level
            )
            let responses = session().streamResponse(
                to: promptText,
                generating: GroundedAnswer.self,
                options: Self.options,
                contextOptions: ctxOptions
            )
            for try await snapshot in responses {
                try Task.checkCancellation()
                insufficient = snapshot.content.insufficient ?? false
                sentences = (snapshot.content.sentences ?? []).compactMap { part in
                    guard let text = part.text, !text.isEmpty else { return nil }
                    return (text: text, source: part.source)
                }
                onPartial(Self.render(sentences))
                tokens = TokenCount(
                    input: snapshot.usage.input.totalTokenCount,
                    output: snapshot.usage.output.totalTokenCount,
                    cachedInput: snapshot.usage.input.cachedTokenCount,
                    reasoningOutput: snapshot.usage.output.reasoningTokenCount
                )
            }
        } else {
            let responses = session().streamResponse(
                to: promptText,
                generating: GroundedAnswer.self,
                options: Self.options
            )
            for try await snapshot in responses {
                try Task.checkCancellation()
                insufficient = snapshot.content.insufficient ?? false
                sentences = (snapshot.content.sentences ?? []).compactMap { part in
                    guard let text = part.text, !text.isEmpty else { return nil }
                    return (text: text, source: part.source)
                }
                onPartial(Self.render(sentences))
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
            let trimmed = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let source = sentence.source else { return trimmed }
            let tag = "[\(source)]"
            if trimmed.hasSuffix(tag) || trimmed.hasSuffix("\(tag).") {
                return trimmed
            }
            return "\(trimmed) \(tag)"
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

    /// The receipt for a counted answer. The shape itself lives on `AggregateAnswer`, shared
    /// with `Reasoner`, so chat and `ask` cannot drift into reporting it differently.
    /// A window's activity as plain sentences. Deterministic, so it needs no grounding check.
    static func activityText(_ summary: ActivitySummary, report: WindowReport, uncounted: [String] = []) -> String {
        let span = report.window.span(in: report.calendar)
        guard summary.totalEvents > 0 else {
            return "Nothing recorded from \(span).\n\(report.text)"
        }
        let floor = summary.isTruncated ? "At least " : ""
        var lines = Reasoner.notCountedLine(uncounted).map { [$0] } ?? []
        lines.append("\(floor)\(summary.totalEvents) event\(summary.totalEvents == 1 ? "" : "s") from \(span):")
        for group in summary.groups {
            let upkeep = group.upkeep > 0 ? ", plus \(group.upkeep) upkeep" : ""
            lines.append("- \(group.subject.canonicalName): \(group.events) \(group.verb)\(upkeep). Latest: \(group.latest.first?.detail.replacingOccurrences(of: "\n", with: " ").prefix(100) ?? "")")
        }
        if summary.totalSubjects > summary.groups.count {
            lines.append("(\(summary.groups.count) of \(summary.totalSubjects) subjects shown, projects first.)")
        }
        lines.append("")
        lines.append(report.text)
        return lines.joined(separator: "\n")
    }

    static func countedReceipt(
        question: String,
        domain: Domain,
        admitted: [Domain]? = nil,
        blocked: [Domain] = [],
        counted: AggregateAnswer,
        milliseconds: Int
    ) -> Receipt {
        counted.receipt(
            query: question,
            domainsAdmitted: admitted ?? [domain],
            domainsBlocked: blocked,
            milliseconds: milliseconds
        )
    }

    static func receipt(
        question: String,
        queryClass: QueryClass,
        domain: Domain,
        admitted: [Domain]? = nil,
        blocked: [Domain] = [],
        outcome: PassageOutcome,
        sources: [GroundingSource],
        stages: [ReceiptStage],
        model: String?,
        objectsTransmitted: Int = 0,
        reading: ClaimReading = .none
    ) -> Receipt {
        let passages = sources.filter { $0.claimID == nil }.count
        return Receipt(
            query: question,
            queryClass: queryClass,
            // The domains admitted and blocked by `AdmissionPolicy` for this query.
            domainsAdmitted: admitted ?? [domain],
            domainsBlocked: blocked,
            stages: stages,
            objectsSearched: outcome.chunksSearched,
            objectsRetrieved: passages,
            // `Receipt.answeredFromClaims` says which of the two this is. With claims it is the
            // evidence rows behind them, as on `Reasoner`'s path, and the same rows a trace lists.
            evidenceAdmitted: reading.claims.isEmpty ? passages : reading.evidence.count,
            // Zero means no claim was asked for, not that none could be. This path reads the
            // claim table only for a question naming both a subject and something about it.
            claimsConsulted: reading.claims.count,
            contradictionsSurfaced: reading.contradictions,
            model: model,
            // Zero for on-device and deterministic synthesis; equals `sources.count` when
            // opted-in non-sensitive Gemini fallback transmits retrieved passages.
            objectsTransmitted: objectsTransmitted,
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
    5. A source may add lines saying its statement was inferred, has counter-evidence, is \
       contradicted or was overruled. Never state such a statement flat: say what stands against \
       it in the same answer.
    6. Be brief. Three sentences is usually enough.
    """

    static func prompt(question: String, sources: [GroundingSource]) -> String {
        """
        Sources:

        \(sources.map { "[\($0.index)] \($0.title)\n\($0.text)" }.joined(separator: "\n\n"))

        Question: \(question)
        """
    }

    // MARK: - Follow-up query expansion

    /// Deterministic query expansion for follow-up questions in a multi-turn conversation.
    ///
    /// `LanguageModelSession` holds the conversation transcript, so the model knows what `"it"`,
    /// `"that"`, or `"the second one"` refers to, while `PassageSearch` runs *before* the model
    /// and sees only the query string handed to it. When the current question contains anaphoric
    /// or ordinal references (`it`, `that`, `the second one`, `who else`), this method appends
    /// the anchor entity or topic from the prior exchange so retrieval finds the same subject.
    public static func contextualizedQuery(
        _ question: String,
        priorQuestions: [String],
        priorSourceTitles: [String]
    ) -> String {
        guard !priorQuestions.isEmpty || !priorSourceTitles.isEmpty else { return question }

        let lower = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = questionTokens(question)
        let ordinalIndex = ordinal(in: tokens)

        guard readsAsFollowUp(question) else { return question }

        var anchors: [String] = []
        if let idx = ordinalIndex, idx < priorSourceTitles.count {
            anchors.append(cleanSourceAnchor(priorSourceTitles[idx]))
        } else {
            if let subject = followUpSubject(of: priorSourceTitles) {
                anchors.append(subject)
            }
            if let lastQuestion = priorQuestions.last {
                // Without its time phrase. A window travels as a value in `priorWindow`, and as
                // words it came through as search terms: "in March" as "march", because "in" is a
                // stopword, and "last 3 days" as "last days", because one letter is dropped. Taking
                // the phrase out afterwards could not find either, so they stayed in the search.
                let timeless = TemporalIntent.window(in: lastQuestion)?.residualQuery ?? lastQuestion
                let extracted = HybridSearch.ftsQuery(from: timeless)
                    .split(separator: "\"")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.lowercased() != "or" && $0.lowercased() != "and" }
                anchors.append(contentsOf: extracted.prefix(4))
            }
        }

        let uniqueAnchors = anchors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !lower.contains($0.lowercased()) }
        guard !uniqueAnchors.isEmpty else { return question }

        return "\(question) (\(uniqueAnchors.joined(separator: " ")))"
    }

    /// Whether `question` leans on the one before it. Whether it picked up any anchors is a
    /// different fact: "and in Quiet?" after "what happened recently" has none to carry, and it
    /// still stays in that window.
    static func readsAsFollowUp(_ question: String) -> Bool {
        let lower = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = questionTokens(question)
        let anaphoricTokens: Set<String> = [
            "it", "its", "that", "this", "they", "them", "their", "there",
            "else", "other", "same", "instead", "one",
        ]
        let followUpPrefixes = [
            "and ", "what about ", "how about ", "why did ", "when did ", "when was ", "who else",
        ]
        return ordinal(in: tokens) != nil
            || !tokens.isDisjoint(with: anaphoricTokens)
            || followUpPrefixes.contains(where: { lower.hasPrefix($0) })
    }

    private static func questionTokens(_ question: String) -> Set<String> {
        Set(
            question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        )
    }

    private static func ordinal(in tokens: Set<String>) -> Int? {
        if tokens.contains("first") || tokens.contains("1st") { return 0 }
        if tokens.contains("second") || tokens.contains("2nd") { return 1 }
        if tokens.contains("third") || tokens.contains("3rd") { return 2 }
        return nil
    }

    /// What "it" refers to after a turn with these sources: the top one, unless they are claims
    /// about several subjects. Then no one of them is "it". "Which projects use Swift" followed
    /// by "and their language?" used to anchor on whichever repository sorted first, and
    /// `QueryFocus` then narrowed the whole turn to it. The prior question's words still carry
    /// over, and "the second one" still picks its line.
    private static func followUpSubject(of titles: [String]) -> String? {
        guard let first = titles.first else { return nil }
        let claimSubjects = Set(titles.filter { $0.hasSuffix(claimTitleSuffix) }.map(cleanSourceAnchor))
        return claimSubjects.count > 1 ? nil : cleanSourceAnchor(first)
    }

    private static func cleanSourceAnchor(_ title: String) -> String {
        if let dashRange = title.range(of: " — ") {
            return String(title[..<dashRange.lowerBound])
        }
        if let dotRange = title.range(of: " · ") {
            return String(title[..<dotRange.lowerBound])
        }
        return title
    }
}
