import CoreModel
import CoreStore
import SwiftUI

/// One thing, and everything the store knows about it.
///
/// **The screen this app was missing.** Claims, Beliefs, Contradictions, Timeline and Receipts
/// were each reachable and each had a tab, so the sidebar was the database schema and the
/// reader was asked to join it by hand. Nobody thinks "I would like to browse the belief
/// layer"; they think "what do I know about OpenClinic".
///
/// It is also the only place `Store.beliefHistory` has ever been reachable from. Forty-three
/// belief versions existed with nothing able to display them, because a version history has no
/// meaning without a subject to hang it on.
@MainActor
@Observable
final class EntityModel {
    var entities: [(CoreEntity, Int)] = []
    var filter = ""
    var selected: EntityID?
    var dossier: EntityDossier?
    var history: [Belief] = []
    var showingHistoryFor: String?
    var loading = false

    var visible: [(CoreEntity, Int)] {
        guard !filter.isEmpty else { return entities }
        let needle = filter.lowercased()
        return entities.filter { $0.0.canonicalName.lowercased().contains(needle) }
    }

    func load(store: Store) async {
        entities = (try? await store.entitiesByActivity()) ?? []
        // Land on something rather than an empty pane. A picker whose right half is blank until
        // you guess what to click reads as broken on first open.
        if selected == nil, let first = entities.first?.0.id {
            await select(first, store: store)
        }
    }

    func select(_ id: EntityID, store: Store) async {
        selected = id
        loading = true
        defer { loading = false }
        dossier = try? await store.dossier(for: id)
        showingHistoryFor = nil
        history = []
    }

    func loadHistory(key: String, store: Store) async {
        showingHistoryFor = key
        history = (try? await store.beliefHistory(key: key)) ?? []
    }
}

struct EntityView: View {
    @Environment(AppModel.self) private var model
    @State private var entities = EntityModel()

    var body: some View {
        @Bindable var entities = entities
        HSplitView {
            list.frame(minWidth: 220, idealWidth: 260)
            detail.frame(minWidth: 420)
        }
        .navigationTitle("Entities")
        .searchable(text: $entities.filter, prompt: "Filter entities")
        .task { if let store = model.store { await entities.load(store: store) } }
    }

    private var list: some View {
        List(selection: Binding(
            get: { entities.selected },
            set: { id in
                guard let id, let store = model.store else { return }
                Task { await entities.select(id, store: store) }
            }
        )) {
            ForEach(entities.visible, id: \.0.id) { entity, count in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entity.canonicalName).font(.callout).lineLimit(1)
                        Text(entity.kind.rawValue).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    // Ordered and labelled by claim count: an entity resolved once from a stray
                    // token and one the store knows twenty things about should not look alike.
                    Text("\(count)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .tag(entity.id)
            }
        }
        .overlay {
            if entities.entities.isEmpty {
                EmptyState(message: "No entities yet.\n\nThey are resolved from synced objects, so sync a source first.")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let dossier = entities.dossier {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(dossier)
                    if dossier.isEmpty {
                        Text("Resolved as an entity, but nothing has been claimed about it yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        if !dossier.contradictions.isEmpty { contradictions(dossier) }
                        beliefs(dossier)
                        if !dossier.events.isEmpty { timeline(dossier) }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if entities.loading {
            ProgressView()
        } else {
            EmptyState(message: "Pick something to see what OpenCore knows about it.")
        }
    }

    private func header(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dossier.entity.canonicalName).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                Chip(dossier.entity.kind.rawValue)
                Chip(dossier.entity.domain.rawValue)
                Text("first seen \(Self.day.string(from: dossier.entity.firstSeenAt))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if !dossier.aliases.isEmpty {
                // What else resolves here. Worth showing because a wrong alias is the most
                // common cause of a claim landing on the wrong thing, and it is invisible
                // otherwise.
                Text("also known as: " + dossier.aliases.prefix(8).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func contradictions(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Conflicts", count: dossier.contradictions.count)
            // Shown above the beliefs, not in a separate tab. A contradiction only means
            // anything next to the thing it is about, and a reader who has to go looking for it
            // will read the belief as settled.
            ForEach(dossier.contradictions, id: \.id) { contradiction in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: contradiction.resolution == .unresolved
                            ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(contradiction.resolution == .unresolved ? .orange : .secondary)
                        Text(contradiction.kind.rawValue).font(.callout.weight(.medium))
                        Text(contradiction.resolution.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(contradiction.reason).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(contradiction.resolution == .unresolved ? 0.1 : 0.04), in: .rect(cornerRadius: 8))
            }
        }
    }

    private func beliefs(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Believed now", count: dossier.claims.count)
            // Capped. An entity with hundreds of distinct statements is a scroll, not a
            // summary, and the tail is reachable through Claims.
            ForEach(dossier.claims.prefix(60)) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: row.claim.derivation == .observed ? "circle.fill" : "circle.dashed")
                            .font(.system(size: 7))
                            .foregroundStyle(row.claim.derivation == .observed ? Color.accentColor : .orange)
                            .help(row.claim.derivation == .observed ? "read directly from source data" : "inferred by OpenCore")
                        Text(row.claim.predicate.replacingOccurrences(of: "_", with: " "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                        // Says there were many without printing many. The graph records some
                        // predicates once per commit, so this is often in the hundreds.
                        if row.occurrences > 1 {
                            Text("×\(row.occurrences)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(String(format: "%.2f", row.claim.confidence))
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 8) {
                        Text(row.claim.authority.label).font(.caption2).foregroundStyle(.tertiary)
                        // The bitemporal half that has never had a surface. A slot that changed
                        // its mind is the interesting one, and the count is what makes it
                        // findable without opening every slot.
                        if let revisions = row.revisions {
                            Button("changed \(revisions) times") {
                                guard let store = model.store else { return }
                                Task { await entities.loadHistory(key: row.claim.claimKey, store: store) }
                            }
                            .buttonStyle(.link).font(.caption2)
                        }
                    }
                    if entities.showingHistoryFor == row.claim.claimKey { historyList }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
            }
            if dossier.claims.count > 60 {
                Text("+ \(dossier.claims.count - 60) more distinct statements, in Claims")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entities.history, id: \.id) { belief in
                HStack(spacing: 8) {
                    Text("v\(belief.version)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text(Self.day.string(from: belief.decidedAt)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    // Why it changed, not just that it did. A version list without reasons is a
                    // changelog; with them it is an argument you can check.
                    Text(belief.reason).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func timeline(_ dossier: EntityDossier) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Timeline", count: dossier.events.count)
            ForEach(dossier.events.prefix(40), id: \.id) { event in
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.day.string(from: event.occurredAt))
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .frame(width: 78, alignment: .leading)
                    Text(event.verb.replacingOccurrences(of: "_", with: " "))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .leading)
                    Text(event.detail).font(.caption).lineLimit(2)
                }
            }
            if dossier.events.count > 40 {
                Text("+ \(dossier.events.count - 40) older").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct SectionLabel: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct Chip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}

/// A label and a value, side by side.
///
/// Lived in `AskView` until that screen was retired, and is used by the MCP and Time travel
/// screens. Moved here rather than left orphaned: a shared component owned by whichever view
/// happened to define it first is how deleting a screen breaks three others.
struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospaced()
        }
        .font(.caption)
    }
}
