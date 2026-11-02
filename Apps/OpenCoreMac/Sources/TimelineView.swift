import CoreModel
import CoreStore
import SwiftUI

/// What happened, from every source, in one ordering.
///
/// The store held 1,244 events and nothing displayed them. Events are what claims are not: a
/// claim says what *is*, an event says what *happened*, and for the sources that yield no
/// claims at all — notes, local files, most calendar entries — the timeline is the only thing
/// they contribute. Without this view those sources were invisible no matter how much of them
/// had been ingested.
extension AppModel {
    struct TimelineEntry: Identifiable, Sendable {
        let id: EventID
        let subjectID: EntityID
        let subject: String
        let verb: String
        let detail: String
        let occurredAt: Date
        let domain: Domain
        let authority: Authority
    }

    func loadTimeline(days: Int, domains: Set<Domain>?) async -> [TimelineEntry] {
        guard let store else { return [] }
        do {
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            // The lookback picker ends at now. Future calendar entries remain in their source.
            // The chosen 500-row display cap is disclosed beside the picker.
            let events = try await store.events(
                from: since,
                to: Date(),
                domains: domains,
                limit: 500
            )
            var entries: [TimelineEntry] = []
            for event in events {
                entries.append(TimelineEntry(
                    id: event.id,
                    subjectID: event.subject,
                    subject: try await store.entity(event.subject)?.canonicalName ?? "?",
                    verb: event.verb,
                    detail: event.detail,
                    occurredAt: event.occurredAt,
                    domain: event.domain,
                    authority: event.authority
                ))
            }
            return entries
        } catch {
            state = .failed("timeline: \(error)")
            return []
        }
    }
}

struct TimelineView: View {
    @Environment(\.appModel) private var model
    @State private var entries: [AppModel.TimelineEntry] = []
    @State private var days = 90
    @State private var domainFilter: Domain?
    @State private var loading = false
    @State private var latestReload = 0
    @State private var mode: Mode = .events

    enum Mode: String, CaseIterable, Identifiable {
        case events = "Chronological Event Stream"
        case timeTravel = "Bitemporal Time Machine"

        var id: String { rawValue }

        var humanSummary: String {
            switch self {
            case .events:
                "What happened and when across all your sources (commits, calendar meetings, notes, and file edits)"
            case .timeTravel:
                "Rewind OpenCore's memory to any date to compare what it knew then vs what was true in real life"
            }
        }

        var engineJargon: String {
            switch self {
            case .events:
                "CoreEvent · Point-in-time actions (occurredAt) distinct from persistent state facts (CoreClaim)"
            case .timeTravel:
                "Bitemporal Query · Knowledge Time (observedAt / decidedAt) vs World Time (validFrom / validTo)"
            }
        }
    }

    private var grouped: [(day: Date, entries: [AppModel.TimelineEntry])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.occurredAt) }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text(mode.humanSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(mode.engineJargon)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)

            Divider()

            switch mode {
            case .events:
                controls
                Divider()
                if entries.isEmpty && !loading {
                    EmptyState(message: "No events in this window.\n\nEvents come from commits, calendar entries, notes and files.")
                } else {
                    list
                }
            case .timeTravel:
                TimeTravelView()
            }
        }
        .navigationTitle("Timeline & Time Travel")
        .task(id: model.dataGeneration) { await reload() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Window", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("All").tag(36_500)
            }
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: days) { Task { await reload() } }

            Picker("Domain", selection: $domainFilter) {
                Text("All domains").tag(Domain?.none)
                ForEach(Domain.allCases, id: \.self) { Text($0.rawValue).tag(Domain?.some($0)) }
            }
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: domainFilter) { Task { await reload() } }

            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Text(entries.count == 500 ? "Showing latest 500 events" : "\(entries.count) events").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(grouped, id: \.day) { group in
                    SwiftUI.Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.entries) { entry in
                                TimelineRow(entry: entry)
                            }
                        }
                    } header: {
                        Text(group.day.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background)
                    }
                }
            }
            .padding(24)
        }
    }

    /// Changing the span while a read is running starts a second one, and the slower of the two used
    /// to win: a 90-day read finishing late replaced the 7 days now selected, under the 7-day label.
    private func reload() async {
        latestReload &+= 1
        let request = latestReload
        loading = true
        let result = await model.loadTimeline(days: days, domains: domainFilter.map { [$0] })
        guard request == latestReload else { return }
        entries = result
        loading = false
    }
}

private struct TimelineRow: View {
    let entry: AppModel.TimelineEntry

    private var verbColor: Color {
        switch entry.verb {
        case "committed": .accentColor
        case "attended", "met": .purple
        case "created": .green
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.verb)
                .font(.caption.monospaced())
                .foregroundStyle(verbColor)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 82, alignment: .leading)
            EntityLinkChip(name: entry.subject, entityID: entry.subjectID)
                .fixedSize(horizontal: true, vertical: false)
            Text(entry.detail.replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.domain.isSensitive {
                Text(entry.domain.rawValue).font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
