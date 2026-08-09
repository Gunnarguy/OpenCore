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
            // Look ahead as well as back: calendar events are the one source with entries in
            // the future, and a timeline that silently stops at today would hide them.
            let events = try await store.events(
                from: since,
                to: Date().addingTimeInterval(365 * 86_400),
                domains: domains,
                limit: 500
            )
            var entries: [TimelineEntry] = []
            for event in events {
                entries.append(TimelineEntry(
                    id: event.id,
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
    @Environment(AppModel.self) private var model
    @State private var entries: [AppModel.TimelineEntry] = []
    @State private var days = 90
    @State private var domainFilter: Domain?
    @State private var loading = false

    private var grouped: [(day: Date, entries: [AppModel.TimelineEntry])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.occurredAt) }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if entries.isEmpty && !loading {
                EmptyState(message: "No events in this window.\n\nEvents come from commits, calendar entries, notes and files.")
            } else {
                list
            }
        }
        .navigationTitle("Timeline")
        .task { await reload() }
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
            .frame(width: 130)
            .onChange(of: days) { Task { await reload() } }

            Picker("Domain", selection: $domainFilter) {
                Text("All domains").tag(Domain?.none)
                ForEach(Domain.allCases, id: \.self) { Text($0.rawValue).tag(Domain?.some($0)) }
            }
            .frame(width: 150)
            .onChange(of: domainFilter) { Task { await reload() } }

            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Text("\(entries.count) events").font(.caption).foregroundStyle(.secondary)
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

    private func reload() async {
        loading = true
        defer { loading = false }
        entries = await model.loadTimeline(days: days, domains: domainFilter.map { [$0] })
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
                .frame(width: 74, alignment: .leading)
            Text(entry.subject)
                .font(.caption.weight(.medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
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
