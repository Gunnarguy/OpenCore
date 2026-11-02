import CoreCompanion
import Foundation
import SwiftUI

struct PhoneChatView: View {
    @Environment(PhoneModel.self) private var model
    @State private var question = ""
    @State private var pendingQuestion: String?
    @State private var replies: [CompanionPage] = []
    @State private var failure: String?
    @State private var saveNotice: String?
    @State private var requiresMacUpdate = false
    @State private var sending = false
    @State private var mode = CompanionAnswerMode.chat
    @State private var domain = "automatic"
    @State private var chatThreadID = UUID()
    @State private var openedThreadTitle: String?
    @State private var hasOpenedThread = false
    @State private var isCurrentThreadSaved = false
    @State private var showingSavedChats = false
    @State private var sendTask: Task<Void, Never>?
    @State private var sendOperation = UUID()
    @State private var confirmedHistorySession: UUID?

    private var selectedDomainOrNil: String? {
        domain == "automatic" ? nil : domain
    }

    private var domainDisplayName: String {
        domain == "automatic" ? "Automatic" : domain.capitalized
    }

    private var isThreadLocked: Bool {
        !replies.isEmpty || hasOpenedThread
    }

    var body: some View {
        Group {
            if !model.isConnected {
                LockedContentView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 12) {
                            Button {
                                showingSavedChats = true
                            } label: {
                                Label("Saved Chats", systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(sending || model.busy)

                            Button {
                                startNewChat()
                            } label: {
                                Label("New Chat", systemImage: "square.and.pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(sending || model.busy)
                        }

                        Picker("Answer mode", selection: $mode) {
                            Text("Grounded Chat").tag(CompanionAnswerMode.chat)
                            Text("Evidence").tag(CompanionAnswerMode.evidence)
                        }
                        .pickerStyle(.segmented)
                        .disabled(sending || model.busy || isThreadLocked)

                        if mode == .evidence {
                            Label(
                                "Evidence mode is not yet saved to Saved Chats. Answers include their sources, caveats and receipt for this session only.",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Grounded Chat assigns a stable thread ID so acknowledged answers are saved on an updated Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Picker("Read from", selection: $domain) {
                            Text("Automatic").tag("automatic")
                            ForEach(["project", "personal", "work", "medical", "financial", "relationship", "public"], id: \.self) { value in
                                Text(value.capitalized).tag(value)
                            }
                        }
                        .disabled(sending || model.busy || isThreadLocked)
                        .onChange(of: domain) { _, _ in
                            if !isThreadLocked {
                                resetThreadIdentity()
                            }
                        }

                        Text("Personal includes calendar, reminders and journals. Your Mac's pairing permissions always limit access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if isThreadLocked {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Label(
                                    "Read scope (\(domainDisplayName)) is fixed for this thread so contexts do not mix. Start a New Chat to change it.",
                                    systemImage: "lock.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button("New Chat") {
                                    startNewChat()
                                }
                                .font(.caption.weight(.semibold))
                                .disabled(sending || model.busy)
                            }
                        }

                        if let openedThreadTitle {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(openedThreadTitle, systemImage: "bubble.left.and.text.bubble.right")
                                    .font(.subheadline.weight(.semibold))
                                Text("Thread · \(domainDisplayName) read scope")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        }

                        if requiresMacUpdate {
                            Label(
                                saveNotice ?? "Update OpenCore on your Mac to save and reopen phone chats. This answer was not saved to history.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        } else if let saveNotice {
                            Label(
                                saveNotice,
                                systemImage: isCurrentThreadSaved && mode == .chat ? "externaldrive.badge.checkmark" : "info.circle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }

                        if replies.isEmpty && !sending {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "text.bubble")
                                    .font(.largeTitle)
                                    .foregroundStyle(.cyan)
                                Text("Ask your history.")
                                    .font(.title2.bold())
                                Text("Your Mac generates the answer. Every source, caveat and receipt comes with it.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 24)
                        }

                        ForEach(Array(replies.enumerated()), id: \.offset) { _, reply in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(reply.records.enumerated()), id: \.offset) { index, record in
                                    if index > 0 && Self.isQuestionRecord(record) {
                                        Divider().padding(.vertical, 4)
                                    }
                                    recordView(for: record)
                                }
                                if !reply.note.isEmpty {
                                    Text(reply.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(18)
                            .background(.regularMaterial, in: .rect(cornerRadius: 20))
                        }

                        if sending {
                            VStack(alignment: .leading, spacing: 12) {
                                if let pendingQuestion {
                                    questionBubble(text: pendingQuestion, date: nil)
                                }
                                ProgressView("Your Mac is answering…")
                                if let draft = model.streamedDraft {
                                    Text(draft.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(draft.records, id: \.identityBytes) { record in
                                        Text(record.body)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Button("Stop and lock", systemImage: "stop.fill", role: .destructive) {
                                    sendTask?.cancel()
                                    Task { await model.lock() }
                                }
                            }
                            .padding(18)
                            .background(.regularMaterial, in: .rect(cornerRadius: 20))
                        }

                        if let failure {
                            Text(failure)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(20)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(alignment: .bottom, spacing: 12) {
                        TextField("Ask OpenCore", text: $question, axis: .vertical)
                            .lineLimit(1...5)
                            .padding(12)
                            .background(.background, in: .rect(cornerRadius: 16))
                        Button("Send", systemImage: "arrow.up") {
                            sendTask = Task { await send() }
                        }
                        .labelStyle(.iconOnly)
                        .font(.title3.bold())
                        .frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(sending || model.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(12)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Grounded Chat")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingSavedChats = true
                } label: {
                    Label("Saved Chats", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!model.isConnected || sending || model.busy)

                Button {
                    startNewChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(!model.isConnected || sending || model.busy)
            }
        }
        .navigationDestination(isPresented: $showingSavedChats) {
            PhoneSavedChatsView(
                selectedDomain: selectedDomainOrNil,
                activeThreadID: chatThreadID,
                isActiveThreadSaved: isCurrentThreadSaved,
                onOpenThread: openSavedThread,
                onStartNewChat: startNewChat
            )
        }
        .onChange(of: model.isConnected) { _, connected in
            if !connected {
                clearDisplayedHistory()
            }
        }
        .onChange(of: model.sessionID) { _, _ in
            clearDisplayedHistory()
        }
        .onDisappear {
            sendTask?.cancel()
        }
    }

    @ViewBuilder
    private func recordView(for record: CompanionRecord) -> some View {
        if Self.isReceiptRecord(record) {
            NavigationLink {
                PhoneReadView(section: .receipts, recordID: record.id)
            } label: {
                PhoneRecordRow(record: record)
            }
        } else if Self.isSourceOrLinkedRecord(record) {
            NavigationLink {
                PhoneRecordDetail(record: record)
            } label: {
                PhoneRecordRow(record: record)
            }
        } else if Self.isQuestionRecord(record) {
            questionBubble(
                text: record.body.isEmpty ? record.title : record.body,
                date: record.date
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.title.isEmpty ? "OpenCore" : record.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !record.body.isEmpty {
                    Text(record.body)
                        .textSelection(.enabled)
                }
                ForEach(record.fields) { field in
                    Text("\(field.label): \(field.value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func questionBubble(text: String, date: Date?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.blue.opacity(0.14), in: .rect(cornerRadius: 16))
            if let date {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func resetThreadIdentity() {
        chatThreadID = UUID()
        openedThreadTitle = nil
        hasOpenedThread = false
        isCurrentThreadSaved = false
        failure = nil
        saveNotice = nil
        requiresMacUpdate = false
    }

    private func startNewChat() {
        sendTask?.cancel()
        sendTask = nil
        sendOperation = UUID()
        sending = false
        pendingQuestion = nil
        replies.removeAll()
        question = ""
        resetThreadIdentity()
    }

    private func clearDisplayedHistory() {
        showingSavedChats = false
        confirmedHistorySession = nil
        startNewChat()
    }

    private func openSavedThread(_ threadID: UUID, title: String, page: CompanionPage) {
        sendTask?.cancel()
        sendTask = nil
        sending = false
        pendingQuestion = nil
        chatThreadID = threadID
        openedThreadTitle = title.isEmpty ? "Saved Chat" : title
        hasOpenedThread = true
        isCurrentThreadSaved = true
        mode = .chat
        replies = [page]
        question = ""
        failure = nil
        requiresMacUpdate = false
        saveNotice = "Opened saved chat from your Mac. Follow-up questions continue this thread."
    }

    private func send() async {
        let submittedDraft = question
        let query = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !sending, model.isConnected else { return }
        let session = model.sessionID
        let requestMode = mode
        let requestDomain = selectedDomainOrNil
        let requestThreadID = requestMode == .chat ? chatThreadID : nil
        let operation = UUID()
        sendOperation = operation
        sending = true
        pendingQuestion = query
        defer {
            if sendOperation == operation {
                sending = false
                pendingQuestion = nil
            }
        }
        do {
            // Older Macs ignore an unknown thread ID and reuse their per-device context.
            // Probe support before sending the question so New Chat cannot mix contexts.
            if requestMode == .chat && confirmedHistorySession != session {
                let capability = try await model.read(CompanionRequest(section: .chat, domain: requestDomain, chatHistoryAction: .list))
                guard !Task.isCancelled, model.isConnected, model.sessionID == session, sendOperation == operation else { return }
                guard capability.supportsChatHistoryList else {
                    if capability.chatHistoryVersion == nil {
                        requiresMacUpdate = true
                        saveNotice = "Update OpenCore on your Mac before starting a saved chat. Your question was not sent."
                    } else {
                        requiresMacUpdate = false
                        failure = "The Mac returned an incompatible saved-chat response. Your question was not sent."
                    }
                    return
                }
                confirmedHistorySession = session
            }
            let result = try await model.read(
                CompanionRequest(
                    section: .chat,
                    query: query,
                    domain: requestDomain,
                    answerMode: requestMode,
                    chatThreadID: requestThreadID
                )
            )
            guard !Task.isCancelled, model.isConnected, model.sessionID == session, sendOperation == operation else { return }
            if requestMode == .chat {
                guard let threadID = requestThreadID, result.matchesChatHistory(thread: threadID) else {
                    failure = "The Mac could not confirm which conversation this answer belongs to. Check Saved Chats before retrying."
                    return
                }
            }
            let displayedPage = Self.ensuringLeadingQuestionRecord(in: result, query: query)
            replies.append(displayedPage)
            if question == submittedDraft { question = "" }
            failure = nil
            if requestMode == .evidence {
                requiresMacUpdate = false
                saveNotice = "Evidence mode answers are not saved in Saved Chats."
            } else if let threadID = requestThreadID, result.matchesChatHistory(thread: threadID) {
                isCurrentThreadSaved = true
                requiresMacUpdate = false
                if openedThreadTitle == nil {
                    openedThreadTitle = String(query.prefix(60))
                }
                saveNotice = "Saved to your Mac in Saved Chats."
            }
        } catch is CancellationError {
            return
        } catch {
            guard sendOperation == operation else { return }
            guard model.isConnected, model.sessionID == session else {
                clearDisplayedHistory()
                return
            }
            failure = error.localizedDescription
        }
    }

    private static func ensuringLeadingQuestionRecord(in page: CompanionPage, query: String) -> CompanionPage {
        if let first = page.records.first, isQuestionRecord(first) {
            return page
        }
        var updated = page
        updated.records.insert(
            CompanionRecord(
                id: "question-\(UUID().uuidString)",
                title: "You",
                body: query,
                date: page.generatedAt
            ),
            at: 0
        )
        return updated
    }

    private static func isReceiptRecord(_ record: CompanionRecord) -> Bool {
        record.title.hasPrefix("Receipt ·") || record.title.hasPrefix("Cloud request audit ·")
    }

    private static func isSourceOrLinkedRecord(_ record: CompanionRecord) -> Bool {
        !isReceiptRecord(record) && (record.id.hasPrefix("source-") || record.objectID != nil || !record.links.isEmpty)
    }

    private static func isQuestionRecord(_ record: CompanionRecord) -> Bool {
        guard !isReceiptRecord(record), !isSourceOrLinkedRecord(record) else { return false }
        if record.id == "question" || record.id.hasPrefix("question-") || record.id.hasPrefix("you-") {
            return true
        }
        let normalizedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedTitle == "you"
            || normalizedTitle == "question"
            || normalizedTitle.hasPrefix("you ·")
            || normalizedTitle.hasPrefix("question ·") {
            return true
        }
        if record.fields.contains(where: {
            $0.label.caseInsensitiveCompare("Role") == .orderedSame
                && ($0.value.caseInsensitiveCompare("you") == .orderedSame
                    || $0.value.caseInsensitiveCompare("question") == .orderedSame)
        }) {
            return true
        }
        if normalizedTitle == "opencore"
            || normalizedTitle == "evidence answer"
            || normalizedTitle == "draft"
            || normalizedTitle == "answer"
            || record.id == "answer"
            || record.id == "draft" {
            return false
        }
        return record.fields.isEmpty
    }
}
