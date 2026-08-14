import CoreModel
import CoreStore
import SwiftUI

/// The front door.
///
/// **Why this exists.** There wasn't one. Opening OpenCore put you in a chat box with no
/// indication of what it knew, what had changed, or whether anything wanted attention. Thirteen
/// sidebar rows each exposed one layer of the pipeline, which answers "show me the claims table"
/// and never answers "what am I opening this for". The app read as a database inspector because
/// that is what it was.
///
/// The rule this screen is built to: **every line either says something specific about your
/// data, or it is not here.** No progress bars for their own sake, no "welcome back", no counter
/// that is only a counter. If a row cannot state a fact, it is cut.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Binding var section: Section

    @State private var snapshot: HomeSnapshot?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ask
                if let snapshot {
                    work(snapshot)
                    attention(snapshot)
                    other(snapshot)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        // Keyed on the store rather than run once. A `.task` with no id fires before the
        // database has finished opening and never retries, which is the bug that made Chat's
        // history menu say "no saved chats yet" on every launch.
        .task(id: model.store == nil) {
            guard let store = model.store else { return }
            snapshot = try? await store.homeSnapshot()
        }
    }

    // MARK: - Ask

    /// The one thing you came here to do, at the top, doing nothing clever.
    ///
    /// Typing here hands the question to Chat rather than answering inline. Two answer surfaces
    /// for one question is the split that produced Ask and Chat in the first place.
    private var ask: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Ask about your own history", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(handOff)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        }
    }

    private func handOff() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        PendingQuestion.shared.text = question
        draft = ""
        section = .chat
    }

    // MARK: - Sections

    @ViewBuilder
    private func work(_ snapshot: HomeSnapshot) -> some View {
        Band(title: "Projects", subtitle: "last \(snapshot.windowDays) days") {
            if snapshot.work.isEmpty {
                // An invitation, not an apology, and specific about which window was searched.
                Text("Nothing in the last \(snapshot.windowDays) days. Sync a source, or ask about something older.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.work) { row in
                    ActivityRow(activity: row) { open(row.subject) }
                }
            }
        }
    }

    @ViewBuilder
    private func attention(_ snapshot: HomeSnapshot) -> some View {
        // Rendered only when there is something to say. An empty "worth a look" band is the
        // kind of chrome that makes a screen feel like a template.
        if snapshot.openContradictions > 0 || !snapshot.neverSynced.isEmpty || snapshot.unattributed > 0 {
            Band(title: "Worth a look") {
                if snapshot.openContradictions > 0 {
                    Note(
                        tint: .orange,
                        headline: "\(snapshot.openContradictions) unresolved contradiction\(snapshot.openContradictions == 1 ? "" : "s")",
                        detail: "Two sources disagree and neither outranks the other, so nothing was decided."
                    ) { section = .contradictions }
                }
                if !snapshot.neverSynced.isEmpty {
                    Note(
                        tint: .secondary,
                        headline: "Never synced: \(snapshot.neverSynced.joined(separator: ", "))",
                        detail: "Configured but never fetched, so nothing from them is searchable."
                    ) { section = .sources }
                }
                if snapshot.unattributed > 0 {
                    // Said out loud rather than dropped. A quiet week and a week whose subjects
                    // could not be named look identical otherwise.
                    Note(
                        tint: .secondary,
                        headline: "\(snapshot.unattributed) events belong to no known subject",
                        detail: "They happened, but entity resolution could not name what they were about."
                    ) { section = .entities }
                }
            }
        }
    }

    @ViewBuilder
    private func other(_ snapshot: HomeSnapshot) -> some View {
        if !snapshot.other.isEmpty {
            Band(title: "Everything else", subtitle: "mostly calendars") {
                ForEach(snapshot.other) { row in
                    ActivityRow(activity: row) { open(row.subject) }
                }
            }
        }
    }

    private func open(_ subject: String) {
        PendingEntity.shared.name = subject
        section = .entities
    }
}

// MARK: - Pieces

/// A titled group. One component so the bands cannot drift into three different spacings, which
/// is most of why the old screens looked unrelated to each other.
private struct Band<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

private struct ActivityRow: View {
    let activity: HomeSnapshot.Activity
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline) {
                Text(activity.subject).font(.body)
                Spacer(minLength: 16)
                // The verb matters as much as the count: "16 committed" is a sentence and "16"
                // is a number waiting for you to guess what it counts.
                Text("\(activity.events) \(activity.verb)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct Note: View {
    let tint: Color
    let headline: String
    let detail: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.10), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

// MARK: - Hand-off

/// A question typed on Home, waiting for Chat to pick it up.
///
/// A shared box rather than a binding threaded through `RootView`, because the two screens are
/// siblings in a `switch` and neither owns the other. Cleared on read so a question is asked
/// once and does not reappear when you come back to the tab.
@MainActor
final class PendingQuestion {
    static let shared = PendingQuestion()
    var text: String?

    func take() -> String? {
        defer { text = nil }
        return text
    }
}

/// Same, for opening one subject's page from a row.
@MainActor
final class PendingEntity {
    static let shared = PendingEntity()
    var name: String?

    func take() -> String? {
        defer { name = nil }
        return name
    }
}
