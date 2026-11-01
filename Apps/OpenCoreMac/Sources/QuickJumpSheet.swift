import CoreModel
import CoreReason
import CoreStore
import SwiftUI

/// Global `Cmd+K` Command and Search Palette.
///
/// Lets the user jump to any entity dossier, inspect any claim or passage, ask a question
/// directly in Chat, or trigger a sync/navigation action without touching the mouse.
struct QuickJumpSheet: View {
    @Environment(\.appModel) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedItemID: String?
    @State private var entities: [(CoreEntity, Int)] = []
    @State private var matchingClaims: [AppModel.ClaimRow] = []
    @State private var matchingPassages: [AppModel.PassageRow] = []
    /// Set when the query was read as a stretch of time, so filtered rows say they are.
    @State private var matchingWindow: String?
    @State private var instantBrief: Conversation.GroundedBrief?
    @State private var synthesizingInstant = false
    @State private var instantTask: Task<Void, Never>?
    @State private var instantRequestID = UUID()
    @State private var matchingQuery = ""
    @FocusState private var searchFocused: Bool

    enum Item: Identifiable {
        case instantAnswer(String)
        case askChat(String)
        case entity(CoreEntity, Int)
        case claim(AppModel.ClaimRow)
        case passage(AppModel.PassageRow)
        case section(Section, subtitle: String)
        case action(title: String, subtitle: String, symbol: String, run: @MainActor () -> Void)

        var id: String {
            switch self {
            case .instantAnswer(let q): "instant:\(q)"
            case .askChat(let q): "ask:\(q)"
            case .entity(let e, _): "entity:\(e.id.value)"
            case .claim(let c): "claim:\(c.id.value)"
            case .passage(let p): "passage:\(p.id.value)"
            case .section(let s, _): "section:\(s.rawValue)"
            case .action(let title, _, _, _): "action:\(title)"
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Keep keyboard selection on the same item when asynchronous passage rows are inserted.
    private var selectedIndex: Int {
        get { items.firstIndex { $0.id == selectedItemID } ?? 0 }
        nonmutating set {
            let current = items
            selectedItemID = current.indices.contains(newValue) ? current[newValue].id : current.first?.id
        }
    }

    private var items: [Item] {
        var list: [Item] = []
        let q = trimmedQuery

        if !q.isEmpty {
            list.append(.instantAnswer(q))
            list.append(.askChat(q))
        }

        let matchedEntities: [(CoreEntity, Int)]
        if q.isEmpty {
            matchedEntities = Array(entities.prefix(6))
        } else {
            let needle = q.lowercased()
            matchedEntities = entities.filter {
                $0.0.canonicalName.lowercased().contains(needle)
                    || $0.0.kind.rawValue.lowercased().contains(needle)
            }.prefix(6).map { $0 }
        }
        for (entity, count) in matchedEntities {
            list.append(.entity(entity, count))
        }

        if !q.isEmpty {
            for claim in matchingClaims.prefix(5) {
                list.append(.claim(claim))
            }
            for passage in matchingPassages.prefix(4) {
                list.append(.passage(passage))
            }
        }

        let navSections = Section.allCases.map { ($0, "\($0.guide.shortName). \($0.guide.purpose)") }

        for (sec, subtitle) in navSections {
            if q.isEmpty || sec.rawValue.lowercased().contains(q.lowercased()) || subtitle.lowercased().contains(q.lowercased()) {
                list.append(.section(sec, subtitle: subtitle))
            }
        }

        if q.isEmpty || "how workspaces connect workflow map evidence".contains(q.lowercased()) {
            list.append(.action(title: "How OpenCore fits together", subtitle: "Choose an outcome and follow one of your projects through the evidence", symbol: "map") {
                model.openWorkspaceMapAfterQuickJump = true
            })
        }

        if q.isEmpty || "sync github".contains(q.lowercased()) {
            list.append(.action(
                title: "Sync GitHub",
                subtitle: "Fetch latest repositories, commits, and README claims",
                symbol: "arrow.triangle.2.circlepath"
            ) {
                Task { await model.syncGitHub() }
            })
        }
        if q.isEmpty || "sync notes".contains(q.lowercased()) {
            list.append(.action(
                title: "Sync Apple Notes",
                subtitle: "Ingest notes locally via AppleScript",
                symbol: "note.text"
            ) {
                Task { await model.syncNotes() }
            })
        }

        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader
            Divider()
            if let instantBrief {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            "Instant Grounded Answer (\(instantBrief.modelName))",
                            systemImage: "sparkles"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                        Spacer()
                        Button("Open in Chat") {
                            let q = trimmedQuery
                            dismiss()
                            model.askInChat(q)
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        Button {
                            cancelInstantAnswer()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(instantBrief.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color.purple.opacity(0.08))
                Divider()
            }
            if let matchingWindow {
                Text(matchingWindow)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            resultsList
            Divider()
            footer
        }
        .frame(width: 640, height: 480)
        .onAppear {
            searchFocused = true
        }
        .task(id: model.dataGeneration) {
            guard let store = model.store else { return }
            let generation = model.dataGeneration
            let fetched = (try? await store.entitiesByActivity(limit: 200)) ?? []
            guard !Task.isCancelled, generation == model.dataGeneration else { return }
            entities = fetched
            if model.claims.isEmpty { await model.loadClaims() }
            guard !Task.isCancelled, generation == model.dataGeneration else { return }
            updateMatchingClaims(for: trimmedQuery)
        }
        .task(id: QuickJumpSearchQuery(query: trimmedQuery, dataGeneration: model.dataGeneration)) {
            selectedIndex = 0
            let q = trimmedQuery
            let generation = model.dataGeneration
            matchingQuery = q
            matchingPassages = []
            matchingWindow = nil
            updateMatchingClaims(for: q)
            guard q.count >= 2 else { return }
            let result = await model.searchPassages(q)
            // SwiftUI cancellation is cooperative: explicitly reject an older query's response.
            guard !Task.isCancelled, q == trimmedQuery, generation == model.dataGeneration else { return }
            matchingPassages = result?.rows ?? []
            matchingWindow = result?.report?.text
        }
        .onChange(of: trimmedQuery) { _, _ in cancelInstantAnswer() }
        .onChange(of: model.dataGeneration) { _, _ in cancelInstantAnswer() }
        .onDisappear { cancelInstantAnswer() }
        .onKeyPress(.downArrow) {
            let count = items.count
            if count > 0 { selectedIndex = min(count - 1, selectedIndex + 1) }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if items.count > 0 { selectedIndex = max(0, selectedIndex - 1) }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            TextField("Jump to an entity, search claims & passages, or ask a question…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit {
                    executeSelected()
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var resultsList: some View {
        // Regression: the palette retained the previous row closures after the query changed.
        // Snapshot the result set and reset its scroll host when result identities change.
        let currentItems = items
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(currentItems.enumerated()), id: \.element.id) { index, item in
                        QuickJumpRow(item: item, isSelected: index == selectedIndex) {
                            selectedIndex = index
                            executeSelected()
                        }
                        .id(index)
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(selectedIndex, anchor: .center) }
        }
        .id(currentItems.map(\.id))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label("↑↓ to navigate", systemImage: "arrow.up.arrow.down")
            Label("↵ to open", systemImage: "return")
            Label("esc to close", systemImage: "escape")
            Spacer()
            Text("\(model.entityCount) entities · \(model.claimCount) claims · \(model.chunkCount) passages")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func executeSelected() {
        let currentItems = items
        guard selectedIndex >= 0, selectedIndex < currentItems.count else { return }
        let chosen = currentItems[selectedIndex]
        switch chosen {
        case .instantAnswer(let question):
            startInstantAnswer(question)
        case .askChat(let question):
            dismiss()
            model.askInChat(question)
        case .entity(let entity, _):
            dismiss()
            model.openEntity(id: entity.id)
        case .claim(let row):
            dismiss()
            model.openEntity(id: row.subjectID)
            model.inspectClaim(row.id)
        case .passage(let row):
            dismiss()
            model.openPassages(query: trimmedQuery)
            model.inspectObject(row.objectID, highlight: row.text)
        case .section(let section, _):
            dismiss()
            model.navigate(to: section)
        case .action(_, _, _, let run):
            dismiss()
            run()
        }
    }

    private func updateMatchingClaims(for question: String) {
        guard !question.isEmpty else { matchingClaims = []; return }
        let needle = question.lowercased()
        matchingClaims = model.claims.filter {
            $0.subject.lowercased().contains(needle)
                || $0.predicate.lowercased().contains(needle)
                || $0.value.lowercased().contains(needle)
        }
    }

    private func cancelInstantAnswer() {
        instantTask?.cancel()
        instantTask = nil
        instantRequestID = UUID()
        instantBrief = nil
        synthesizingInstant = false
    }

    private func startInstantAnswer(_ question: String) {
        guard !synthesizingInstant else { return }
        cancelInstantAnswer()
        let requestID = UUID()
        let generation = model.dataGeneration
        let claimRows = matchingQuery == question ? matchingClaims : []
        let passageRows = matchingQuery == question ? matchingPassages : []
        instantRequestID = requestID
        synthesizingInstant = true
        instantTask = Task {
            await runInstantAnswer(question, generation: generation, requestID: requestID,
                                   claimRows: claimRows, passageRows: passageRows)
        }
    }

    private func runInstantAnswer(_ question: String, generation: Int, requestID: UUID,
                                  claimRows: [AppModel.ClaimRow], passageRows: [AppModel.PassageRow]) async {
        guard !Task.isCancelled, question == trimmedQuery, generation == model.dataGeneration,
              instantRequestID == requestID else { return }
        var sources: [GroundingSource] = []
        for claim in claimRows.prefix(6) {
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: "\(claim.subject) · \(claim.predicate)",
                text: "\(claim.subject) \(claim.predicate): \(claim.value) (authority: \(claim.claim.authority.label))",
                objectID: ObjectID.derived(from: "claim", claim.id.value),
                authority: claim.claim.authority,
                uri: nil
            ))
        }
        for passage in passageRows.prefix(4) {
            sources.append(GroundingSource(
                index: sources.count + 1,
                title: passage.title,
                text: passage.text,
                objectID: passage.objectID,
                authority: .authoredArtifact,
                uri: nil
            ))
        }
        if sources.isEmpty, let res = await model.searchPassages(question) {
            guard !Task.isCancelled, question == trimmedQuery, generation == model.dataGeneration,
                  instantRequestID == requestID else { return }
            for row in res.rows.prefix(4) {
                sources.append(GroundingSource(
                    index: sources.count + 1,
                    title: row.title,
                    text: row.text,
                    objectID: row.objectID,
                    authority: .authoredArtifact,
                    uri: nil
                ))
            }
        }
        let brief = await Conversation.synthesizeGroundedBrief(question: question, sources: sources)
        guard !Task.isCancelled, question == trimmedQuery, generation == model.dataGeneration,
              instantRequestID == requestID else { return }
        instantBrief = brief
        synthesizingInstant = false
        instantTask = nil
    }
}

private struct QuickJumpRow: View {
    let item: QuickJumpSheet.Item
    let isSelected: Bool
    let action: () -> Void

    private var symbol: String {
        switch item {
        case .instantAnswer: "sparkles"
        case .askChat: "bubble.left.and.bubble.right.fill"
        case .entity: "square.stack.3d.up.fill"
        case .claim: "checkmark.seal.fill"
        case .passage: "doc.text.magnifyingglass"
        case .section(let sec, _): sec.symbol
        case .action(_, _, let sym, _): sym
        }
    }

    private var tint: Color {
        switch item {
        case .instantAnswer: .purple
        case .askChat: .accentColor
        case .entity: .blue
        case .claim: .green
        case .passage: .purple
        case .section: .secondary
        case .action: .orange
        }
    }

    private var title: String {
        switch item {
        case .instantAnswer(let q): "Instant Answer (/fm): \"\(q)\""
        case .askChat(let q): "Ask \"\(q)\" in Chat"
        case .entity(let entity, _): entity.canonicalName
        case .claim(let row): "\(row.subject) \(row.predicate) → \(row.value)"
        case .passage(let row): row.title
        case .section(let sec, _): sec.rawValue
        case .action(let t, _, _, _): t
        }
    }

    private var subtitle: String {
        switch item {
        case .instantAnswer: "Synthesize a grounded answer inline with /usr/bin/fm without leaving your screen"
        case .askChat: "Open full multi-turn grounded conversation in Chat"
        case .entity(let entity, let count): "\(entity.kind.rawValue) · \(entity.domain.rawValue) · \(count) claims"
        case .claim(let row): "Claim · \(row.claim.authority.label) · click to open dossier & provenance"
        case .passage(let row): row.text
        case .section(_, let sub): sub
        case .action(_, let sub, _, _): sub
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : tint)
                    .frame(width: 26, height: 26)
                    .background(
                        isSelected ? tint : tint.opacity(0.14),
                        in: .rect(cornerRadius: 6)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isSelected ? .primary : .primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(badgeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var badgeText: String {
        switch item {
        case .instantAnswer: "Instant /fm ↵"
        case .askChat: "Chat ↵"
        case .entity: "Entity"
        case .claim: "Belief"
        case .passage: "Passage"
        case .section: "Screen"
        case .action: "Command"
        }
    }
}

private struct QuickJumpSearchQuery: Equatable {
    let query: String
    let dataGeneration: Int
}
