import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import SwiftUI

/// What Ask shows before a question: today, what is due and what changed. The first thing the app
/// says should be about the owner's day, not about how the app works.
struct TodayPanel: View {
    @Environment(\.appModel) private var model
    @Binding var draft: String
    @State private var today: AgendaToday?
    @State private var snapshot: HomeSnapshot?

    private let examples = [
        "What's on my calendar this week?",
        "What's overdue?",
        "What have I been working on lately?",
        "Which of my projects are dormant?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you want to know?").font(.title2.weight(.semibold))
                Text("Ask about your life and work, and see how it knows.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(examples, id: \.self) { example in
                    Button(example) { draft = example }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let today {
                HStack(alignment: .top, spacing: 12) {
                    column("Today", items: today.today, empty: "Nothing on your calendar.")
                    column("Tomorrow", items: today.tomorrow, empty: "Nothing on your calendar.")
                    column(dueHeading(today), items: today.due, empty: "Nothing due in the next two days.")
                }
                ForEach(today.notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                WhatChangedCard(snapshot: snapshot, previousVisit: model.previousVisit)
            }
        }
        .padding(.vertical, 12)
        .task(id: model.dataGeneration) {
            guard let store = model.store else { return }
            let owner = AdmissionPolicy.forQuestion("", ownerDomain: .personal)
            today = try? await AgendaAnswering(store: store).today(policy: owner, now: Date(), calendar: .current)
            snapshot = try? await store.homeSnapshot(since: model.previousVisit)
        }
    }

    private func dueHeading(_ today: AgendaToday) -> String {
        today.overdue.isEmpty ? "Due" : "Due, and \(today.overdue.count) overdue"
    }

    private func column(_ title: String, items: [AgendaItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(items.prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout).lineLimit(2)
                        if !item.isAllDay, let when = item.when, !isMidnight(when) {
                            Text(when.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if items.count > 5 {
                    Text("and \(items.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.ice)
    }

    /// A reminder due on a date has no time of its own, and midnight is how that arrives.
    private func isMidnight(_ date: Date) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
    }
}
