import CoreCompanion
import Foundation
import SwiftUI

struct PhoneSavedChatsView: View {
    let selectedDomain: String?
    let activeThreadID: UUID?
    let isActiveThreadSaved: Bool
    let onOpenThread: (UUID, String, CompanionPage) -> Void
    let onStartNewChat: () -> Void

    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page: CompanionPage?
    @State private var records: [CompanionRecord] = []
    @State private var loading = false
    @State private var openingThreadID: UUID?
    @State private var error: String?
    @State private var requiresMacUpdate = false
    @State private var loadTask: Task<Void, Never>?
    @State private var openTask: Task<Void, Never>?

    private var domainDisplayName: String {
        selectedDomain?.capitalized ?? "Automatic"
    }

    private var isBusy: Bool {
        loading || openingThreadID != nil || model.busy
    }

    var body: some View {
        Group {
            if !model.isConnected {
                LockedContentView()
            } else {
                List {
                    Section {
                        LabeledContent("Read scope", value: domainDisplayName)
                        Text("Saved chats are scoped to this read domain and your current Mac pairing grant. Start a New Chat to switch read scope so contexts do not mix.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            startNewChat()
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .disabled(isBusy)
                    }

                    if requiresMacUpdate {
                        Section("Mac update required") {
                            Label(
                                "Update OpenCore on your Mac to list and reopen saved phone chats. Older Mac versions do not support saved phone chat history.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            Button("Check again") {
                                triggerLoad(more: false)
                            }
                            .disabled(isBusy)
                        }
                    }

                    if let error {
                        Section("Saved Chats message") {
                            Text(error)
                                .foregroundStyle(.orange)
                            Button("Try again") {
                                triggerLoad(more: false)
                            }
                            .disabled(isBusy)
                        }
                    }

                    if let page, !requiresMacUpdate {
                        if !page.note.isEmpty {
                            Section {
                                Text(page.note)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("Saved Conversations") {
                            ForEach(records, id: \.identityBytes) { record in
                                if let threadUUID = UUID(uuidString: record.id) {
                                    Button {
                                        triggerOpen(threadUUID, title: record.title)
                                    } label: {
                                        savedThreadRow(record, threadUUID: threadUUID)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)
                                } else {
                                    PhoneRecordRow(record: record)
                                }
                            }

                            if records.isEmpty && !loading {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("No saved chats in \(domainDisplayName)", systemImage: "bubble.left.and.text.bubble.right")
                                        .font(.headline)
                                    Text("Grounded Chat answers acknowledged by this iPhone under the \(domainDisplayName) read scope will appear here.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }

                            if page.nextOffset != nil {
                                Button("Load more") {
                                    triggerLoad(more: true)
                                }
                                .disabled(isBusy)
                            }
                        }

                        Section {
                            Text("Received \(page.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if loading {
                        Section {
                            ProgressView("Reading saved chats from your Mac…")
                        }
                    }

                    if openingThreadID != nil {
                        Section {
                            ProgressView("Opening conversation from your Mac…")
                        }
                    }

                    if page == nil && !loading && !requiresMacUpdate {
                        Section {
                            Button("Read saved chats from Mac") {
                                triggerLoad(more: false)
                            }
                            .disabled(isBusy)
                        }
                    }
                }
                .refreshable {
                    await load(more: false)
                }
            }
        }
        .navigationTitle("Saved Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startNewChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(!model.isConnected || isBusy)
            }
        }
        .task(id: model.sessionID) {
            if page == nil && model.isConnected && !model.busy {
                await load(more: false)
            }
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
            loadTask?.cancel()
            openTask?.cancel()
        }
    }

    @ViewBuilder
    private func savedThreadRow(_ record: CompanionRecord, threadUUID: UUID) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(record.title.isEmpty ? "Untitled" : record.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if threadUUID == activeThreadID && isActiveThreadSaved {
                        Label("Current", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                if !record.body.isEmpty {
                    Text(record.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !record.fields.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(record.fields) { field in
                            Text("\(field.label): \(field.value)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if let domain = record.domain ?? selectedDomain {
                        Text(domain.uppercased())
                            .font(.caption2.weight(.semibold))
                    } else {
                        Text("AUTOMATIC")
                            .font(.caption2.weight(.semibold))
                    }
                    if let date = record.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if openingThreadID == threadUUID {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func triggerLoad(more: Bool) {
        loadTask?.cancel()
        loadTask = Task { await load(more: more) }
    }

    private func triggerOpen(_ threadUUID: UUID, title: String) {
        openTask?.cancel()
        openTask = Task { await open(threadUUID, title: title) }
    }

    private func startNewChat() {
        loadTask?.cancel()
        openTask?.cancel()
        onStartNewChat()
        dismiss()
    }

    private func clearDisplayedHistory() {
        loadTask?.cancel()
        loadTask = nil
        openTask?.cancel()
        openTask = nil
        loading = false
        openingThreadID = nil
        page = nil
        records.removeAll()
        error = nil
        requiresMacUpdate = false
    }

    private func load(more: Bool) async {
        guard model.isConnected, !loading, openingThreadID == nil, !model.busy else { return }
        if more && page?.nextOffset == nil { return }
        let session = model.sessionID
        let offset = more ? (page?.nextOffset ?? 0) : 0
        loading = true
        defer { loading = false }
        do {
            let request = CompanionRequest(
                section: .chat,
                domain: selectedDomain,
                offset: offset,
                chatHistoryAction: .list
            )
            let result = try await model.read(request)
            guard !Task.isCancelled, model.isConnected, model.sessionID == session else { return }
            guard result.supportsChatHistoryList else {
                page = nil
                records.removeAll()
                requiresMacUpdate = result.chatHistoryVersion == nil
                error = requiresMacUpdate ? nil : "The Mac returned an incompatible saved-chat response."
                return
            }
            requiresMacUpdate = false
            let validRecords = result.records.filter { UUID(uuidString: $0.id) != nil }
            records = CompanionRecord.appendingDistinct(validRecords, to: more ? records : [])
            page = result
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard model.isConnected, model.sessionID == session else {
                clearDisplayedHistory()
                return
            }
            self.error = error.localizedDescription
        }
    }

    private func open(_ threadUUID: UUID, title: String) async {
        guard model.isConnected, !loading, openingThreadID == nil, !model.busy else { return }
        let session = model.sessionID
        openingThreadID = threadUUID
        defer { openingThreadID = nil }
        do {
            let request = CompanionRequest(
                section: .chat,
                domain: selectedDomain,
                chatHistoryAction: .open,
                chatThreadID: threadUUID
            )
            let result = try await model.read(request)
            guard !Task.isCancelled, model.isConnected, model.sessionID == session else { return }
            guard result.chatHistoryVersion == 1 else {
                requiresMacUpdate = result.chatHistoryVersion == nil
                error = requiresMacUpdate ? nil : "The Mac returned an unsupported saved-chat version."
                return
            }
            guard result.matchesChatHistory(thread: threadUUID) else {
                error = "The Mac could not confirm which conversation it returned. Refresh Saved Chats and try again."
                return
            }
            guard !result.records.isEmpty else {
                error = "That saved conversation has no admitted records for this read scope."
                return
            }
            requiresMacUpdate = false
            error = nil
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = trimmedTitle.isEmpty ? result.title : trimmedTitle
            onOpenThread(threadUUID, resolvedTitle, result)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            guard model.isConnected, model.sessionID == session else {
                clearDisplayedHistory()
                return
            }
            self.error = error.localizedDescription
        }
    }
}
