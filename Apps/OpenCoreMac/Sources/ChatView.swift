import CoreModel
import CoreReason
import CoreSearch
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

    func refreshReadiness() {
        readiness = Conversation.readiness()
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
        .task { chat.refreshReadiness() }
        .sheet(item: $chat.showingReceipt) { turn in
            if let receipt = turn.receipt { ChatReceiptSheet(receipt: receipt, turn: turn) }
        }
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

        let history = chat.turns
        let tuning = settings.tuning

        Task {
            let conversation = Conversation(store: store, embedder: try? NLEmbeddingProvider(), tuning: tuning)
            var placeholderIndex: Int?

            for await update in await conversation.send(question, history: history) {
                if let index = placeholderIndex {
                    chat.turns[index] = update
                } else {
                    chat.turns.append(update)
                    placeholderIndex = chat.turns.count - 1
                }
            }
            chat.sending = false
        }
    }
}

// MARK: - One turn

private struct TurnView: View {
    let turn: Turn
    @Bindable var chat: ChatModel

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

    private var footer: some View {
        HStack(spacing: 10) {
            GroundingBadge(turn: turn)
            if let model = turn.modelName {
                Label(model, systemImage: "cpu").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if turn.receipt != nil {
                Button("Why do you think that?") { chat.showingReceipt = turn }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// The verification result, quiet when it passes and loud when it does not.
private struct GroundingBadge: View {
    let turn: Turn

    var body: some View {
        let bad = turn.ungrounded.count
        let total = turn.verdicts.count
        if total == 0 {
            EmptyView()
        } else if bad == 0 {
            Label("\(total) of \(total) sentences supported", systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
        } else {
            Label("\(bad) sentence\(bad == 1 ? "" : "s") not supported by the sources", systemImage: "exclamationmark.triangle.fill")
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
                            Label("Sentences the sources do not support", systemImage: "exclamationmark.triangle.fill")
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
