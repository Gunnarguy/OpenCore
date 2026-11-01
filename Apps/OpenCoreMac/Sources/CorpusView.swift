import CoreModel
import CoreStore
import SwiftUI

/// Corpus & Indexed Files Explorer: full-width visual breakdown + interactive raw Floor Object browser.
struct CorpusView: View {
    @Environment(\.appModel) private var model
    @State private var snapshot: CorpusSnapshot?
    @State private var recentObjects: [CoreObject] = []
    @State private var selectedKindFilter: ObjectKind?
    @State private var selectedDomainFilter: Domain?
    @State private var searchText: String = ""
    @State private var isLoadingObjects: Bool = false
    @State private var selectedSourceFilter: String?
    @State private var selectedMonthFilter: String?
    @State private var objectsRequestID = UUID()
    @State private var snapshotRequestID = UUID()
    @State private var objectsError: String?
    @State private var snapshotError: String?

    private var objectQuery: CorpusObjectQuery {
        CorpusObjectQuery(kind: selectedKindFilter, domain: selectedDomainFilter,
                          sourceName: selectedSourceFilter, authoredMonth: selectedMonthFilter,
                          text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                          dataGeneration: model.dataGeneration)
    }

    private var hasFilters: Bool {
        selectedKindFilter != nil || selectedDomainFilter != nil || selectedSourceFilter != nil
            || selectedMonthFilter != nil || !searchText.isEmpty
    }

    private var filteredObjects: [CoreObject] { recentObjects }

    var body: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Human-Friendly Orientation Header
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Label("Original Records (Corpus)", systemImage: "chart.pie.fill")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(Pastel.sky)
                                if let snapshot {
                                    Text("\(snapshot.objects) TOTAL FILES & RECORDS")
                                        .openCorePastelBadge(Pastel.mint)
                                }
                            }
                            Text("Choose a source, type or privacy domain to filter originals. Open a record to inspect its text, searchable excerpts and derived statements.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            if hasFilters {
                                Button {
                                    selectedKindFilter = nil
                                    selectedDomainFilter = nil
                                    selectedSourceFilter = nil
                                    selectedMonthFilter = nil
                                    searchText = ""
                                } label: {
                                    Label("Clear Filters", systemImage: "xmark.circle.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(tint: Pastel.rose, telemetryLabel: "Clear Corpus Filters")
                            }

                            Button {
                                Task { await reloadAll(explicit: true) }
                            } label: {
                                Label("Refresh Corpus Snapshot", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.bold))
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(tint: Pastel.aqua, telemetryLabel: "Refresh Corpus Snapshot")

                            Button {
                                Task { await model.syncLocalGitHubWorkspace() }
                            } label: {
                                Label("Sync Local Repo Docs", systemImage: "folder.fill.badge.gearshape")
                                    .font(.caption.weight(.bold))
                            }
                            .controlSize(.small)
                            .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Sync Local Repo Docs")
                        }
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)

                if let error = snapshotError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Pastel.peach)
                }
                if let snapshot {
                    // 2. Five Interactive Layer Totals
                    totals(snapshot) {
                        selectedKindFilter = nil
                        selectedDomainFilter = nil
                        selectedSourceFilter = nil
                        selectedMonthFilter = nil
                        searchText = ""
                        withAnimation { scrollProxy.scrollTo("corpus-originals", anchor: .top) }
                    }

                    // 3. Retrieval Imbalance Advisory (if any single kind > 50%)
                    imbalance(snapshot)

                    // 4. Three-Column Interactive Distribution Grid
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14)], spacing: 14) {
                        kindBreakdownCard(snapshot)
                        sourceBreakdownCard(snapshot)
                        domainBreakdownCard(snapshot)
                    }

                    // 5. Monthly Activity Timeline
                    overTime(snapshot)

                    // 6. Interactive Raw Floor Objects Browser
                    rawObjectsBrowserSection
                        .id("corpus-originals")
                } else if snapshotError == nil {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Corpus Snapshot and Floor Objects from SQLite...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    .openCoreGlassCard(cornerRadius: 12)
                }
            }
            .padding(24)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        }
        .navigationTitle("Corpus")
        .task(id: model.dataGeneration) {
            _ = await reloadSnapshot(explicit: false)
        }
        .task(id: objectQuery) {
            isLoadingObjects = true
            objectsError = nil
            recentObjects = []
            // Text searches run in Store before LIMIT, rather than filtering the latest 80 rows.
            if !objectQuery.text.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
            _ = await reloadObjects(reason: "Apply Corpus filters")
        }
        .onDisappear {
            objectsRequestID = UUID()
            snapshotRequestID = UUID()
        }
    }

    private func reloadAll(explicit: Bool) async {
        let loadedSnapshot = await reloadSnapshot(explicit: explicit)
        if loadedSnapshot { _ = await reloadObjects(reason: explicit ? "Manual Corpus refresh" : nil) }
    }

    @discardableResult
    private func reloadSnapshot(explicit: Bool) async -> Bool {
        guard let store = model.store else { return false }
        let requestID = UUID()
        let generation = model.dataGeneration
        snapshotRequestID = requestID
        let start = Date()
        do {
            let fetched = try await store.corpusSnapshot()
            guard !Task.isCancelled, snapshotRequestID == requestID,
                  generation == model.dataGeneration else { return false }
            snapshot = fetched
            snapshotError = nil
            if explicit {
                ActionFeedbackCenter.shared.record(
                    button: "Refresh Corpus Snapshot",
                    command: "Store.corpusSnapshot",
                    outcome: "Loaded \(fetched.objects) raw objects, \(fetched.chunks) passages, \(fetched.entities) entities, and \(fetched.claims) claims.",
                    status: .completed,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)
                )
            }
            return true
        } catch {
            guard !Task.isCancelled, snapshotRequestID == requestID,
                  generation == model.dataGeneration else { return false }
            snapshotError = "Corpus snapshot could not load: \(error.localizedDescription)"
            ActionFeedbackCenter.shared.record(button: "Refresh Corpus Snapshot", command: "Store.corpusSnapshot",
                outcome: snapshotError ?? "Snapshot failed.", status: .warning,
                durationMs: Int(Date().timeIntervalSince(start) * 1000))
            return false
        }
    }

    @discardableResult
    private func reloadObjects(reason: String?) async -> Bool {
        guard let store = model.store else { return false }
        let requested = objectQuery
        let requestID = UUID()
        objectsRequestID = requestID
        let start = Date()
        isLoadingObjects = true
        objectsError = nil
        do {
            let fetched = try await store.recentObjects(
                kind: requested.kind, domain: requested.domain, sourceName: requested.sourceName,
                authoredMonth: requested.authoredMonth, searchText: requested.text, limit: 80
            )
            // Regression: a slower previous filter may never replace the current browser contents.
            guard !Task.isCancelled, objectsRequestID == requestID, requested == objectQuery else { return false }
            recentObjects = fetched
            isLoadingObjects = false
            if let reason {
                ActionFeedbackCenter.shared.record(
                    button: reason, command: "Store.recentObjects",
                    outcome: "Loaded \(fetched.count) matching Floor Object(s), up to 80, using the active filters.",
                    status: .completed,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)
                )
            }
            return true
        } catch {
            guard !Task.isCancelled, objectsRequestID == requestID, requested == objectQuery else { return false }
            isLoadingObjects = false
            recentObjects = []
            objectsError = "Indexed files could not load: \(error.localizedDescription)"
            ActionFeedbackCenter.shared.record(button: reason ?? "Load Corpus files", command: "Store.recentObjects",
                outcome: objectsError ?? "File query failed.", status: .warning,
                durationMs: Int(Date().timeIntervalSince(start) * 1000))
            return false
        }
    }

    private func totals(_ snapshot: CorpusSnapshot, showOriginals: @escaping () -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            Total(
                "Originals",
                subtitle: "Browse imported records",
                value: snapshot.objects,
                symbol: "doc.on.doc.fill",
                tint: Pastel.sky
            ) {
                showOriginals()
            }
            Total(
                "Excerpts",
                subtitle: "Search text passages",
                value: snapshot.chunks,
                symbol: "doc.text.magnifyingglass",
                tint: Pastel.mint
            ) {
                model.navigate(to: .passages)
            }
            Total(
                "Topics",
                subtitle: "Explore projects, people & concepts",
                value: snapshot.entities,
                symbol: "point.3.connected.trianglepath.dotted",
                tint: Pastel.lavender
            ) {
                model.navigate(to: .entities)
            }
            Total(
                "Statements",
                subtitle: "Inspect extracted claims",
                value: snapshot.claims,
                symbol: "list.bullet.rectangle",
                tint: Pastel.butter
            ) {
                model.navigate(to: .claims)
            }
            Total(
                "Events",
                subtitle: "Browse dated activity",
                value: snapshot.events,
                symbol: "clock.arrow.circlepath",
                tint: Pastel.aqua
            ) {
                model.navigate(to: .timeline)
            }
        }
    }

    @ViewBuilder
    private func imbalance(_ snapshot: CorpusSnapshot) -> some View {
        if let top = snapshot.byKind.first, snapshot.dominantShare > 0.5 {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chart.pie.fill")
                    .font(.title3)
                    .foregroundStyle(Pastel.butter)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Corpus Shape Insight: \(Int(snapshot.dominantShare * 100))% of your indexed items are '\(humanKindName(top.0))' (\(top.1) of \(snapshot.objects))")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Why this matters: When one document type dominates the store, keyword search naturally hits it most often. OpenCore's Reciprocal Rank Fusion + MMR diversity filter balances results across types.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    selectedKindFilter = (selectedKindFilter == top.0) ? nil : top.0
                } label: {
                    Text(selectedKindFilter == top.0 ? "Showing Only \(top.0.rawValue)" : "Filter to \(top.0.rawValue)")
                        .font(.caption.weight(.bold))
                }
                .controlSize(.small)
                .openCoreGlassButton(tint: Pastel.butter, telemetryLabel: "Filter Corpus by \(top.0.rawValue)")
            }
            .padding(14)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.butter)
        }
    }

    private func kindBreakdownCard(_ snapshot: CorpusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("By Document Type (Click to Filter)", systemImage: "doc.richtext")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.sky)
                Spacer()
                Text("\(snapshot.byKind.count) types")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Click any row below to inspect those files in the browser at the bottom.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(snapshot.byKind, id: \.0) { kind, count in
                let isSelected = selectedKindFilter == kind
                let pct = snapshot.objects > 0 ? Int((Double(count) / Double(snapshot.objects) * 100).rounded()) : 0
                Button {
                    selectedKindFilter = isSelected ? nil : kind
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : kindSymbol(kind))
                                    .foregroundStyle(isSelected ? Pastel.mint : Pastel.sky)
                                    .font(.caption)
                                Text(humanKindName(kind))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text("(\(kind.rawValue))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(count) (\(pct)%)")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(isSelected ? Pastel.mint : Pastel.ice)
                        }
                        ScoreBar(value: snapshot.objects > 0 ? Double(count) / Double(snapshot.objects) : 0)
                    }
                    .padding(8)
                    .background(isSelected ? Pastel.mint.opacity(0.16) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.sky)
    }

    private func sourceBreakdownCard(_ snapshot: CorpusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("By Connected Source", systemImage: "cylinder.split.1x2.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.mint)
                Spacer()
                Button("Manage Sources") {
                    model.navigate(to: .sources)
                }
                .controlSize(.mini)
                .openCoreGlassButton(tint: Pastel.mint, telemetryLabel: "Open Sources from Corpus")
            }
            Text("Which connector or folder imported these records into OpenCore.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(snapshot.bySource.prefix(10), id: \.0) { sourceName, count in
                let pct = snapshot.objects > 0 ? Int((Double(count) / Double(snapshot.objects) * 100).rounded()) : 0
                Button {
                    selectedSourceFilter = selectedSourceFilter == sourceName ? nil : sourceName
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(sourceName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(count) (\(pct)%)")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(Pastel.mint)
                        }
                        ScoreBar(value: snapshot.objects > 0 ? Double(count) / Double(snapshot.objects) : 0)
                    }
                    .padding(8)
                    .background(selectedSourceFilter == sourceName ? Pastel.mint.opacity(0.16) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)
    }

    private func domainBreakdownCard(_ snapshot: CorpusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("By Privacy Firewall Domain (Click to Filter)", systemImage: "lock.shield.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pastel.lavender)
                Spacer()
                Text("\(snapshot.byDomain.count) domains")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("OpenCore's query firewall isolates personal, project, medical, and financial data.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(snapshot.byDomain, id: \.0) { domain, count in
                let isSelected = selectedDomainFilter == domain
                let pct = snapshot.objects > 0 ? Int((Double(count) / Double(snapshot.objects) * 100).rounded()) : 0
                Button {
                    selectedDomainFilter = isSelected ? nil : domain
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "shield.lefthalf.filled")
                                    .foregroundStyle(isSelected ? Pastel.mint : Pastel.lavender)
                                    .font(.caption)
                                Text(domain.rawValue.capitalized)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Text("\(count) (\(pct)%)")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(isSelected ? Pastel.mint : Pastel.lavender)
                        }
                        ScoreBar(value: snapshot.objects > 0 ? Double(count) / Double(snapshot.objects) : 0)
                    }
                    .padding(8)
                    .background(isSelected ? Pastel.mint.opacity(0.16) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
    }

    @ViewBuilder
    private func overTime(_ snapshot: CorpusSnapshot) -> some View {
        if !snapshot.byMonth.isEmpty {
            let peak = max(snapshot.byMonth.map(\.1).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Authoring & Activity Timeline by Month", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Pastel.aqua)
                    Spacer()
                    if snapshot.undated > 0 {
                        Text("\(snapshot.undated) undated file(s) not in chart")
                            .openCorePastelBadge(Pastel.butter)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(snapshot.byMonth, id: \.0) { month, count in
                            Button {
                                selectedMonthFilter = selectedMonthFilter == month ? nil : month
                            } label: {
                                VStack(spacing: 4) {
                                    Text("\(count)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Pastel.aqua)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(
                                            LinearGradient(
                                                colors: [Pastel.aqua, Pastel.sky.opacity(0.6)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(width: 28, height: max(6, 84 * Double(count) / Double(peak)))
                                    Text(month)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                                .background(selectedMonthFilter == month ? Pastel.aqua.opacity(0.16) : Color.clear,
                                            in: .rect(cornerRadius: 6))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Click to inspect \(month): \(count) items")
                        }
                    }
                }
            }
            .padding(16)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)
        }
    }

    private var rawObjectsBrowserSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Browse & Inspect Indexed Files (Floor Objects)", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(Pastel.mint)
                Spacer()
                TextField("Search all files by title, path, or content...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                Text("\(recentObjects.count) matches shown (up to 80)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let kind = selectedKindFilter {
                    Text("KIND: \(kind.rawValue.uppercased())").openCorePastelBadge(Pastel.sky)
                }
                if let domain = selectedDomainFilter {
                    Text("DOMAIN: \(domain.rawValue.uppercased())").openCorePastelBadge(Pastel.lavender)
                }
                if let source = selectedSourceFilter {
                    Text("SOURCE: \(source)").openCorePastelBadge(Pastel.mint)
                }
                if let month = selectedMonthFilter {
                    Text("MONTH: \(month)").openCorePastelBadge(Pastel.aqua)
                }
                Spacer()
            }

            if let objectsError {
                Label(objectsError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Pastel.peach)
                    .padding(16)
            } else if isLoadingObjects {
                ProgressView("Loading Floor Objects...")
                    .padding(20)
            } else if filteredObjects.isEmpty {
                Text("No Floor Objects matched the current filter. Click 'Clear Filters' or 'Sync Local Repo Docs' above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredObjects) { obj in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: kindSymbol(obj.kind))
                                .font(.title3)
                                .foregroundStyle(Pastel.sky)
                                .frame(width: 32, height: 32)
                                .background(Pastel.sky.opacity(0.14), in: .rect(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(obj.title)
                                        .font(.callout.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text(humanKindName(obj.kind))
                                        .openCorePastelBadge(Pastel.sky)
                                    Text(obj.domain.rawValue)
                                        .openCorePastelBadge(Pastel.lavender)
                                    Text(obj.authority.label)
                                        .openCorePastelBadge(Pastel.aqua)
                                    Text("\(obj.text.utf8.count) B · sha256:\(obj.contentHash.prefix(8))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }

                                if let uri = obj.uri, !uri.isEmpty {
                                    Text(uri)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Text(obj.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.caption)
                                    .foregroundStyle(Pastel.ice)
                                    .lineLimit(2)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 6) {
                                Button {
                                    model.inspectObject(obj.id)
                                } label: {
                                    Label("Inspect original", systemImage: "sidebar.right")
                                        .font(.caption.weight(.bold))
                                }
                                .controlSize(.small)
                                .openCoreGlassButton(prominent: true, tint: Pastel.mint, telemetryLabel: "Inspect Object: \(obj.title)")

                                Button {
                                    model.openPassages(query: obj.title)
                                } label: {
                                    Label("Find excerpts", systemImage: "magnifyingglass")
                                        .font(.caption2.weight(.semibold))
                                }
                                .controlSize(.mini)
                                .openCoreGlassButton(tint: Pastel.sky, telemetryLabel: "Search Passages for \(obj.title)")
                            }
                        }
                        .padding(12)
                        .openCoreGlassCard(cornerRadius: 10)
                    }
                }
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)
    }

    private func humanKindName(_ kind: ObjectKind) -> String {
        switch kind {
        case .repository: return "Git Repository"
        case .commit: return "Git Commit"
        case .issue: return "GitHub Issue"
        case .pullRequest: return "Pull Request"
        case .release: return "Release Tag"
        case .file: return "Source / Config File"
        case .document: return "Document / PDF"
        case .note: return "Markdown Note / Task"
        case .message: return "Message / Transcript"
        case .calendarEvent: return "Calendar Event"
        }
    }

    private func kindSymbol(_ kind: ObjectKind) -> String {
        switch kind {
        case .repository: return "folder.badge.gearshape"
        case .commit: return "point.topleft.down.curvedto.point.bottomright.up"
        case .issue: return "exclamationmark.circle"
        case .pullRequest: return "arrow.triangle.pull"
        case .release: return "tag"
        case .file: return "doc.text"
        case .document: return "doc.richtext"
        case .note: return "note.text"
        case .message: return "bubble.left"
        case .calendarEvent: return "calendar"
        }
    }
}

private struct Total: View {
    let label: String
    let subtitle: String
    let value: Int
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    init(_ label: String, subtitle: String, value: Int, symbol: String, tint: Color, action: @escaping () -> Void) {
        self.label = label
        self.subtitle = subtitle
        self.value = value
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button {
            ActionFeedbackCenter.shared.record(
                button: "Corpus KPI Card -> \(label)",
                command: "Navigate to \(label) (\(value) rows)",
                outcome: "Jumped from Corpus summary card to \(label) (\(value.formatted()) stored rows).",
                status: .completed
            )
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.16), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.formatted())
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(hovering ? tint : .secondary.opacity(0.5))
            }
            .padding(12)
            .openCoreGlassCard(cornerRadius: 12, tint: hovering ? tint : nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// A value snapshot lets each asynchronous response prove it still belongs to the visible filters.
private struct CorpusObjectQuery: Equatable {
    let kind: ObjectKind?
    let domain: Domain?
    let sourceName: String?
    let authoredMonth: String?
    let text: String
    let dataGeneration: Int
}
