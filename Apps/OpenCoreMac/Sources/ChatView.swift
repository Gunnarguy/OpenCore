import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import SwiftUI

@MainActor
@Observable
final class ChatModel {
    var turns: [Turn] = []
    var draft = ""
    var sending = false
    var readiness: Conversation.Readiness = .unknown("checking")
    /// Source the reader is inspecting, keyed by turn so two answers can be open at once.
    var expandedSource: [UUID: Int] = [:]
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
            store: store, embedder: try? NLEmbeddingProvider(), tuning: tuning, id: currentID
        )
        retained = created
        retainedKey = key
        return created
    }

    func refreshReadiness() {
        readiness = Conversation.readiness()
    }

    // MARK: - Saved threads

    func loadThreads(store: Store) async {
        threads = (try? await store.conversations()) ?? []
    }

    /// Begin a new thread. Nothing is written until the first question is asked, so opening the
    /// tab and closing it does not litter the list with empty rows.
    func startNewThread() {
        currentID = UUID().uuidString
        retained = nil
        retainedKey = nil
        turns = []
        expandedSource = [:]
        judgements = [:]
    }

    /// Reopen a saved thread, restoring both the visible history and the model's context.
    func open(_ thread: StoredConversation, store: Store, tuning: RetrievalTuning) async {
        currentID = thread.id
        retained = nil
        retainedKey = nil
        expandedSource = [:]
        judgements = [:]
        turns = (try? await conversation(store: store, tuning: tuning).restore()) ?? []
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
        guard let stored = try? await store.turns(conversationID: currentID) else { return }
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
/// provenance is *quiet until questioned* — citations are small inline chips, sources sit
/// collapsed under the answer, and the grounding check only raises its voice when it fails.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var chat = ChatModel()

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
        .task(id: model.store != nil) {
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your own history", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: chat.sending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.circle)
            .disabled(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty || chat.sending)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
    }

    private func send() {
        let question = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.sending, let store = model.store else { return }

        chat.draft = ""
        chat.sending = true
        chat.turns.append(Turn(role: .you, text: question))

        let tuning = settings.tuning

        Task {
            let conversation = chat.conversation(store: store, tuning: tuning)
            var placeholderIndex: Int?

            for await update in conversation.send(question) {
                if let index = placeholderIndex {
                    chat.turns[index] = update
                } else {
                    chat.turns.append(update)
                    placeholderIndex = chat.turns.count - 1
                }
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
    @Environment(AppModel.self) private var model

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
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.callout).foregroundStyle(.red)
                } else {
                    answerText
                }
                if !turn.sources.isEmpty { SourceStrip(turn: turn, chat: chat) }
                // A good answer that will not survive closing the window. Said out loud,
                // because the reader is about to assume the thread is on disk.
                if let failure = turn.persistenceError {
                    Label("This turn was not saved. \(failure)", systemImage: "externaldrive.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !turn.streaming && turn.error == nil { footer }
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
                if turn.receipt != nil {
                    Button("Why do you think that?") { chat.showingReceipt = turn }
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
        parts.append(receipt.model == nil ? "no model" : "on-device")
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
    let source: GroundingSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(source.title).font(.caption.weight(.semibold))
                Text(source.authority.label).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
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

// MARK: - Empty state

private struct ChatEmptyState: View {
    @Binding var draft: String

    private let examples = [
        "What have I been building lately?",
        "What did I decide about retrieval?",
        "Which projects use Swift?",
        "What changed in OpenIntelligence recently?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about your own history")
                .font(.title3.weight(.semibold))
            Text("Answers come only from what you have synced. Every sentence is checked against the passages it was written from, and anything unsupported is flagged rather than hidden.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
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
