import CoreModel
import CorePresentation
import CoreReason
import CoreSearch
import CoreStore
import SwiftUI

@MainActor
@Observable
final class ChatModel {
    var turns: [Turn] = []
    var draft = ""
    var ownerDomain: Domain?
    var draftTokens = 0
    var sending = false
    var sendTask: Task<Void, Never>?
    var sendRequestID = UUID()

    func stopSending() {
        if sending {
            ActionFeedbackCenter.shared.record(button: "Stop chat", command: "Cancel active response",
                                               outcome: "Cancellation requested. You can ask another question.", status: .received)
        }
        sendTask?.cancel()
        sendTask = nil
        sendRequestID = UUID()
        sending = false
        retained = nil
        retainedKey = nil
        if let index = turns.lastIndex(where: { $0.role == .core && $0.streaming }) {
            turns[index].streaming = false
            turns[index].error = "Stopped by you."
        }
    }
    var readiness: Conversation.Readiness = .unknown("checking")
    var telemetry: Conversation.FoundationModelsTelemetry = Conversation.telemetry()
    /// Source the reader is inspecting, keyed by turn so two answers can be open at once.
    var expandedSource: [UUID: Int] = [:]
    var structuredAnswers: [UUID: Answer] = [:]
    var showingReceipt: Turn?

    /// Saved threads, most recently used first.
    var threads: [StoredConversation] = []

    /// Which thread new turns belong to. Part of the retained key below, so selecting another
    /// thread drops the held `Conversation` and its model session with it. Reusing the session
    /// across threads would carry one conversation's context into another, which is worse than
    /// having no history at all because it is invisible.
    private(set) var currentID = UUID().uuidString

    /// Held across turns so a follow-up question reaches the model's own `Transcript` instead
    /// of a summary of previous exchanges pasted into the prompt. Rebuilt when the store, the
    /// retrieval tuning or the thread changes, because all three are baked in at construction.
    private var retained: Conversation?
    private var retainedKey: (store: ObjectIdentifier, tuning: RetrievalTuning, id: String)?

    func conversation(store: Store, tuning: RetrievalTuning) -> Conversation {
        // `Store` is a value type wrapping the `Database` actor, so the actor's identity is
        // what actually distinguishes one store from another.
        let key = (store: ObjectIdentifier(store.database), tuning: tuning, id: currentID)
        if let retained, let retainedKey, retainedKey == key { return retained }
        let created = Conversation(
            store: store, embedder: try? NLEmbeddingProvider(), tuning: tuning, id: currentID,
            onAuditFailure: { message in await AppModel.shared.recordAuditFailure(message) }
        )
        retained = created
        retainedKey = key
        return created
    }

    func refreshReadiness() {
        readiness = Conversation.readiness()
        telemetry = Conversation.telemetry()
    }

    // MARK: - Saved threads

    func loadThreads(store: Store) async {
        threads = (try? await store.conversations()) ?? []
    }

    /// Begin a new thread. Nothing is written until the first question is asked, so opening the
    /// tab and closing it does not litter the list with empty rows.
    func startNewThread() {
        stopSending()
        currentID = UUID().uuidString
        retained = nil
        retainedKey = nil
        turns = []
        expandedSource = [:]
        structuredAnswers = [:]
        judgements = [:]
    }

    /// Reopen a saved thread, restoring both the visible history and the model's context.
    func open(_ thread: StoredConversation, store: Store, tuning: RetrievalTuning) async {
        stopSending()
        currentID = thread.id
        retained = nil
        retainedKey = nil
        expandedSource = [:]
        structuredAnswers = [:]
        judgements = [:]
        let requestID = sendRequestID
        let restored = (try? await conversation(store: store, tuning: tuning).restore()) ?? []
        guard !Task.isCancelled, currentID == thread.id, sendRequestID == requestID else { return }
        turns = restored
        // After the turns, because it keys on their ids.
        await loadJudgements(store: store)
    }

    func delete(_ thread: StoredConversation, store: Store) async {
        try? await store.deleteConversation(id: thread.id)
        if thread.id == currentID { startNewThread() }
        await loadThreads(store: store)
    }

    // MARK: - Judgements

    /// Verdicts for the turns on screen, keyed by turn id.
    ///
    /// Held separately from `turns` because `Turn` is `CoreReason`'s type, streamed from the
    /// conversation actor and replaced wholesale on every update. Putting a judgement on it
    /// would mean the next streamed frame silently discarding what the reader just clicked.
    var judgements: [UUID: TurnJudgement] = [:]

    func judge(_ turn: Turn, as verdict: TurnJudgement?, store: Store?) async {
        guard let store else { return }
        if let verdict { judgements[turn.id] = verdict } else { judgements[turn.id] = nil }
        // The stored row keys on the same UUID the turn was persisted under, so this reaches the
        // right row whether the thread was just typed or reopened from history.
        try? await store.judge(turn: turn.id.uuidString, as: verdict)
    }

    /// Load verdicts for a reopened thread, so a judgement made yesterday is still shown.
    func loadJudgements(store: Store) async {
        let conversationID = currentID
        guard let stored = try? await store.turns(conversationID: conversationID),
              !Task.isCancelled, currentID == conversationID else { return }
        for row in stored {
            guard let verdict = row.judgement, let id = UUID(uuidString: row.id) else { continue }
            judgements[id] = verdict
        }
    }
}

/// Conversation over your own history.
///
/// The design brief for this screen: it should feel like a good chat app, and it should be
/// impossible to forget that every sentence came from somewhere. Those pull in opposite
/// directions, because provenance UI is usually clutter. The resolution here is that
/// provenance is *quiet until questioned*: citations are small inline chips, sources sit
/// collapsed under the answer, and the grounding check only raises its voice when it fails.
struct ChatView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var chat = ChatModel()

    private struct ChatLoadTrigger: Equatable {
        let storeReady: Bool
        let dataGeneration: Int
        let pendingQuestion: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            if !chat.readiness.isReady { readinessBanner }
            transcript
            Divider()
            composer
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { historyMenu }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chat.startNewThread()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("Start a new thread. The current one is already saved.")
            }
        }
        // Keyed on whether the store is open, not run once. This tab is the app's landing
        // screen, so it appears before `start()` has finished opening the database: the first
        // pass found `model.store` nil, skipped both steps, and never ran again. The History
        // menu said "No saved chats yet" with a dozen threads on disk until you asked a
        // question, and the model's assets were never pre-loaded, so the first answer of every
        // session was slow for no visible reason. Same fix as `TimeTravelView`, which hit this
        // and solved it; it just was not carried across.
        .task(id: ChatLoadTrigger(
            storeReady: model.store != nil,
            dataGeneration: model.dataGeneration,
            pendingQuestion: model.pendingQuestion
        )) {
            // Typed on Home, Quick Jump, Menu Bar or Entity and handed over rather than
            // answered in a duplicate surface.
            if let question = model.pendingQuestion {
                model.pendingQuestion = nil
                chat.draft = question
            } else if let question = PendingQuestion.shared.take() {
                chat.draft = question
            }
            chat.refreshReadiness()
            guard let store = model.store else { return }
            await chat.loadThreads(store: store)
            // Load the model's assets while the reader is still typing rather than after they
            // hit return.
            if chat.readiness.isReady {
                await chat.conversation(store: store, tuning: settings.tuning).prepare()
            }
        }
        .sheet(item: $chat.showingReceipt) { turn in
            if let receipt = turn.receipt { ChatReceiptSheet(receipt: receipt, turn: turn) }
        }
    }

    // MARK: - Saved threads

    /// Past threads, most recently used first.
    ///
    /// A menu rather than a permanent sidebar: this screen already competes for width with the
    /// app's navigation column, and a second always-on list would push the passages, which are
    /// the point of the screen, into a gutter.
    private var historyMenu: some View {
        Menu {
            if chat.threads.isEmpty {
                Text("No saved chats yet")
            } else {
                ForEach(chat.threads) { thread in
                    Button {
                        guard let store = model.store else { return }
                        Task { await chat.open(thread, store: store, tuning: settings.tuning) }
                    } label: {
                        // The turn count is the honest measure of a thread's weight. A date
                        // alone does not distinguish one abandoned question from a long session.
                        Text("\(thread.title)  ·  \(thread.turnCount) turns")
                        if thread.id == chat.currentID { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(chat.threads) { thread in
                        Button(thread.title, role: .destructive) {
                            guard let store = model.store else { return }
                            Task { await chat.delete(thread, store: store) }
                        }
                    }
                }
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
        .help("Reopen a saved chat. Reopening restores the conversation the model can see, not just the text on screen.")
    }

    // MARK: - Banner

    private var readinessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(chat.readiness.message).font(.callout)
            Spacer()
            Button("Re-check") { chat.refreshReadiness() }.controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if chat.turns.isEmpty { ChatEmptyState(draft: $chat.draft) }
                    ForEach(chat.turns) { turn in
                        TurnView(turn: turn, chat: chat).id(turn.id)
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.turns.last?.text) {
                guard let last = chat.turns.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        let jarvis = JarvisController.shared
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Read from", selection: $chat.ownerDomain) {
                Text("Automatic").tag(Domain?.none)
                ForEach(Domain.allCases.filter { $0 != .restricted }, id: \.self) { domain in
                    Text(domain.rawValue.capitalized).tag(Optional(domain))
                }
            }.pickerStyle(.menu).disabled(chat.sending)
                .help("Personal includes calendar, reminders and journals. This choice applies only to your questions.")
            HStack(spacing: 8) {
                Label(chat.telemetry.modelVariant, systemImage: "cpu.fill")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.green)
                if let ctx = chat.telemetry.contextWindowTokens {
                    Text("· \(ctx.formatted()) ctx")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !chat.telemetry.capabilities.isEmpty {
                    Text("· \(chat.telemetry.capabilities.joined(separator: " + "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if chat.draftTokens > 0 {
                    Text("\(chat.draftTokens) prompt token\(chat.draftTokens == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your own history", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                    .onSubmit(send)
                    .onChange(of: chat.draft) { _, newValue in
                        Task {
                            chat.draftTokens = await Conversation.estimateTokenCount(for: newValue)
                        }
                    }

                Button {
                    jarvis.toggleVoiceListening { spoken in
                        chat.draft = spoken
                        send()
                    }
                } label: {
                    Image(systemName: jarvis.isListening ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(jarvis.isListening ? .red : .primary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .clipShape(.circle)
                .help("Dictate question on device via Apple Speech Recognition")

                Button {
                    if chat.sending { chat.stopSending() } else { send() }
                } label: {
                    Image(systemName: chat.sending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(.circle)
                .disabled(!chat.sending && chat.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
    }

    private func send() {
        let question = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.sending, let store = model.store else { return }

        chat.draft = ""
        chat.sending = true
        let priorQuestions = chat.turns.filter { $0.role == .you }.map(\.text)
        let priorSourceTitles = chat.turns.filter { $0.role == .core }.flatMap { $0.sources.map(\.title) }
        let contextualized = Conversation.contextualizedQuery(
            question,
            priorQuestions: priorQuestions,
            priorSourceTitles: priorSourceTitles
        )
        chat.turns.append(Turn(role: .you, text: question))

        let tuning = settings.tuning
        let ownerDomain = chat.ownerDomain
        let requestID = UUID()
        chat.sendRequestID = requestID
        chat.sendTask = Task {
            defer {
                if chat.sendRequestID == requestID { chat.sending = false; chat.sendTask = nil }
            }
            async let structuredAnswer = model.reasonAnswer(question, persistReceipt: false, ownerDomain: ownerDomain, retrievalQuery: contextualized)
            let conversation = chat.conversation(store: store, tuning: tuning)
            await conversation.configureGeneration(.init(reasoningLevel: settings.fmReasoningLevelRaw,
                                                         includeSchemaInPrompt: settings.fmIncludeSchemaInPrompt))
            var placeholderIndex: Int?
            var finalTurnID: UUID?

            for await update in conversation.send(question, ownerDomain: ownerDomain) {
                guard !Task.isCancelled, chat.sendRequestID == requestID else { break }
                finalTurnID = update.id
                if let index = placeholderIndex {
                    chat.turns[index] = update
                } else {
                    chat.turns.append(update)
                    placeholderIndex = chat.turns.count - 1
                }
            }
            guard !Task.isCancelled, chat.sendRequestID == requestID else { return }
            let answer = await structuredAnswer
            guard !Task.isCancelled, chat.sendRequestID == requestID else { return }
            if let finalTurnID, let answer {
                chat.structuredAnswers[finalTurnID] = answer
            }
            chat.sending = false
            // After, not before: the thread's title and turn count are only correct once the
            // turn has been written, and a new thread does not exist in the list until then.
            await chat.loadThreads(store: store)
        }
    }
}

// MARK: - One turn

private struct TurnView: View {
    let turn: Turn
    @Bindable var chat: ChatModel
    @Environment(\.appModel) private var model

    var body: some View {
        if turn.role == .you {
            HStack {
                Spacer(minLength: 60)
                Text(turn.text)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 14))
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let error = turn.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                    if !turn.text.isEmpty {
                        answerText
                    }
                    if let structured = chat.structuredAnswers[turn.id] {
                        StructuredAnswerCard(answer: structured, isFallback: true)
                    }
                } else {
                    answerText
                    if !turn.streaming,
                       let structured = chat.structuredAnswers[turn.id],
                       (!structured.points.isEmpty || !structured.contradictions.isEmpty || (structured.activity?.totalEvents ?? 0) > 0) {
                        StructuredAnswerCard(answer: structured, isFallback: false)
                    }
                }
                if !turn.sources.isEmpty { SourceStrip(turn: turn, chat: chat) }
                // A good answer that will not survive closing the window. Said out loud,
                // because the reader is about to assume the thread is on disk.
                if let failure = turn.persistenceError {
                    Label("This turn was not saved. \(failure)", systemImage: "externaldrive.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !turn.streaming && (!turn.text.isEmpty || turn.error == nil) { footer }
            }
        }
    }

    /// The answer, with `[n]` citations styled so they read as references rather than noise.
    private var answerText: some View {
        // The caret is folded into the attributed string rather than concatenated as a second
        // Text: `Text + Text` requires both sides to still be Text, and the modifiers below
        // erase the first to `some View`.
        Text(Self.styled(turn.text, streaming: turn.streaming))
            .font(.body)
            .textSelection(.enabled)
            .lineSpacing(2)
    }

    static func styled(_ text: String, streaming: Bool = false) -> AttributedString {
        var attributed = AttributedString(text)
        // Highlight every [1], [2] … so a reader's eye separates claim from citation.
        for match in text.ranges(of: /\[\d+\]/) {
            if let range = Range(match, in: attributed) {
                attributed[range].foregroundColor = .accentColor
                attributed[range].font = .body.weight(.semibold)
            }
        }
        if streaming {
            var caret = AttributedString(" ▍")
            caret.foregroundColor = .secondary
            attributed.append(caret)
        }
        return attributed
    }

    /// Provenance, always present, one line.
    ///
    /// The screen's rule is that provenance stays "quiet until questioned", and that is right
    /// for citations. But quiet and invisible are different, and the receipt was invisible: it
    /// lived behind a link phrased as a question, so the thing that distinguishes this product
    /// from any other chat window only appeared if you thought to ask for it.
    ///
    /// So the counters are stated and the receipt code is shown. Reading them costs a glance
    /// and expanding them is still a click.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                GroundingBadge(turn: turn)
                if let receipt = turn.receipt {
                    // The one line that says how this answer was produced. A counted answer
                    // reports rows counted and no sources, which is the honest shape and reads
                    // as deliberate rather than as a failed retrieval.
                    Text(provenance(receipt))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                if !turn.text.isEmpty {
                    Button {
                        if JarvisController.shared.isSpeaking {
                            JarvisController.shared.stopSpeaking()
                        } else {
                            JarvisController.shared.speak(turn.text)
                        }
                    } label: {
                        Label(
                            JarvisController.shared.isSpeaking ? "Stop" : "Read Aloud",
                            systemImage: JarvisController.shared.isSpeaking ? "stop.fill" : "speaker.wave.2.fill"
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if turn.receipt != nil {
                    Button("Audit Receipt (Why & How)") { chat.showingReceipt = turn }
                        .buttonStyle(.link).font(.caption)
                }
            }
            judgement
        }
    }

    private func provenance(_ receipt: Receipt) -> String {
        var parts: [String] = []
        if receipt.queryClass == .aggregate {
            parts.append("counted \(receipt.objectsSearched) rows")
        } else {
            parts.append("\(receipt.objectsRetrieved) of \(receipt.objectsSearched) passages")
        }
        parts.append(receipt.outboundDescription)
        parts.append(receipt.shortCode)
        return parts.joined(separator: " · ")
    }

    /// Was this any good?
    ///
    /// Two icons, and the cheapest high-value affordance in the app. Every retrieval constant in
    /// this project rests on 20 hand-written benchmark cases, because writing them by hand is
    /// expensive. Chat turns are already persisted with their sources and receipts, so a verdict
    /// is the only missing column between ordinary use and a growing eval corpus.
    ///
    /// Neither state is preselected. An unjudged answer is unmeasured, not neutral, and a
    /// default would manufacture agreement out of people not clicking.
    @ViewBuilder
    private var judgement: some View {
        HStack(spacing: 6) {
            Text("was this right?").font(.caption2).foregroundStyle(.tertiary)
            ForEach(TurnJudgement.allCases, id: \.self) { verdict in
                let chosen = chat.judgements[turn.id] == verdict
                Button {
                    // Clicking the current verdict withdraws it, so a misclick is recoverable
                    // without leaving a wrong label in the corpus.
                    Task { await chat.judge(turn, as: chosen ? nil : verdict, store: model.store) }
                } label: {
                    Image(systemName: verdict == .good
                        ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup")
                        : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(chosen ? (verdict == .good ? Color.green : Color.orange) : Color.secondary)
                .help(verdict == .good ? "Useful and correct" : "Wrong, or missed what I asked")
            }
        }
    }
}

/// The verification result, quiet when it passes and loud when it does not.
///
/// The wording is deliberately narrow. This badge used to read "N of N sentences supported",
/// which a reader will hear as "this answer is right". It cannot mean that: the check compares
/// each sentence to the passage it cited, so it verifies that the answer came from your data,
/// not that the retrieved passages were the right ones. An answer built faithfully from
/// passages about the wrong project passes this badge and should.
private struct GroundingBadge: View {
    let turn: Turn

    var body: some View {
        let bad = turn.ungrounded.count
        let total = turn.verdicts.count
        if total == 0 {
            EmptyView()
        } else if bad == 0 {
            Label("\(total) of \(total) sentences match the source they cite", systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
                .help("Each sentence was checked against the passage it cites. This does not check whether those were the right passages.")
        } else {
            Label("\(bad) sentence\(bad == 1 ? "" : "s") do not match the source cited", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .help(turn.ungrounded.map(\.sentence).joined(separator: "\n\n"))
        }
    }
}

// MARK: - Sources

private struct SourceStrip: View {
    let turn: Turn
    @Bindable var chat: ChatModel

    private var expanded: Int? { chat.expandedSource[turn.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(turn.sources) { source in
                        SourceChip(source: source, selected: expanded == source.index) {
                            chat.expandedSource[turn.id] = expanded == source.index ? nil : source.index
                        }
                    }
                }
            }
            if let index = expanded, let source = turn.sources.first(where: { $0.index == index }) {
                SourceDetail(source: source)
            }
        }
    }
}

private struct SourceChip: View {
    let source: GroundingSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(source.index)")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(selected ? Color.white : .accentColor)
                Text(source.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : .secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 260)
    }
}

private struct SourceDetail: View {
    @Environment(\.appModel) private var model
    let source: GroundingSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(source.title).font(.caption.weight(.semibold))
                Text(source.authority.label).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    model.inspectObject(source.objectID, highlight: source.text)
                } label: {
                    Label("Inspect Floor Object", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2)
                }
                .buttonStyle(.link)
                if let uri = source.uri, let url = URL(string: uri) {
                    Link("Open", destination: url).font(.caption2)
                }
            }
            Text(source.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(14)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Structured Believed Claims & Counter-Evidence

private struct StructuredAnswerCard: View {
    @Environment(\.appModel) private var model
    let answer: Answer
    let isFallback: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isFallback ? "brain.head.profile" : "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(isFallback ? .orange : Color.accentColor)
                Text(isFallback
                     ? "Deterministic Reasoner Fallback (\(answer.points.count) believed claims)"
                     : "Structured Claims & Counter-Evidence (\(answer.points.count) claims\(answer.contradictions.isEmpty ? "" : ", \(answer.contradictions.count) open conflicts"))")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !isFallback {
                    Button(expanded ? "Hide" : "Show") {
                        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }

            if isFallback || expanded {
                if isFallback {
                    Text(answer.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                if let activity = answer.activity, activity.totalEvents > 0 {
                    ActivityRows(activity: activity)
                }

                ForEach(Array(answer.points.prefix(8).enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(point.statement)
                            .font(.caption)
                        if !point.counter.isEmpty {
                            Text("\(point.counter.count) COUNTER-EVIDENCE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: .capsule)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(point.authority.label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let claimID = point.claimID {
                            Button("Inspect") { model.inspectClaim(claimID) }
                                .buttonStyle(.link)
                                .font(.caption2)
                        }
                    }
                }

                if !answer.contradictions.isEmpty {
                    Divider()
                    ForEach(answer.contradictions, id: \.id) { conflict in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(conflict.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Inspect A") { model.inspectClaim(conflict.claimA) }
                                .buttonStyle(.link)
                                .font(.caption2)
                            Button("Inspect B") { model.inspectClaim(conflict.claimB) }
                                .buttonStyle(.link)
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 10, tint: isFallback ? .orange : .accentColor)
    }
}

// MARK: - Empty state

private struct ChatEmptyState: View {
    @Binding var draft: String

    private let examples = [
        "What have I been building lately?",
        "What is the current objective and verify command for OpenCore?",
        "Which projects use Swift?",
        "What changed in OpenIntelligence recently?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Grounded Chat Over Your Own History")
                .font(.title3.weight(.semibold))
            Text("OpenCore retrieves passages from your indexed history for an on-device answer. It shows source references, sentence grounding checks, structured claims and counter-evidence alongside the response.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("TRY A QUESTION")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                ForEach(examples, id: \.self) { example in
                    Button(example) { draft = example }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 40)
    }
}

// MARK: - Receipt

private struct ChatReceiptSheet: View {
    let receipt: Receipt
    let turn: Turn
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why it said that").font(.headline)
                    Text(receipt.shortCode).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ReceiptCard(receipt: receipt)

                    if !turn.ungrounded.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Sentences that do not match the source they cite", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.medium)).foregroundStyle(.orange)
                            ForEach(Array(turn.ungrounded.enumerated()), id: \.offset) { _, verdict in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verdict.sentence).font(.callout)
                                    Text("unsupported words: \(verdict.unsupported.prefix(8).joined(separator: ", "))")
                                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
                            }
                            Text("This check is lexical overlap, not entailment. It catches a sentence about something absent from your data; it does not catch one that inverts the meaning of something present.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What it read").font(.callout.weight(.medium))
                        ForEach(turn.sources) { SourceDetail(source: $0) }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 620)
    }
}


/// What happened in a question's time window, from the event log.
struct ActivityRows: View {
    @Environment(\.appModel) private var model
    let activity: ActivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activity.groups) { group in
                Button { model.openEntity(id: group.subject.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(group.subject.canonicalName).font(.caption.weight(.semibold))
                            Spacer(minLength: 6)
                            Text(group.upkeep > 0 ? "\(group.events) \(group.verb) +\(group.upkeep) upkeep" : "\(group.events) \(group.verb)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let latest = group.latest.first {
                            Text(latest.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
