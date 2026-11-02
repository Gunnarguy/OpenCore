import AppIntents
import CoreIngest
import CoreModel
import CoreReason
import CoreSearch
import CoreSpotlight
import CoreStore
import Foundation
import UniformTypeIdentifiers

// MARK: - CoreSpotlight Indexer

/// Indexes non-sensitive entities into macOS Spotlight (`CSSearchableIndex`) so searching
/// `⌘Space` for any project, person, or technology opens its dossier directly in OpenCore.
///
/// **Privacy boundary**: Entities in `.medical`, `.financial`, or `.relationships` domains
/// (`entity.domain.isSensitive == true`) are strictly excluded before constructing
/// `CSSearchableItem`s. System-wide Spotlight indices are readable by other processes on the
/// Mac, so sensitive domains never enter the index.
enum SpotlightIndexer {
    static let domainIdentifier = "com.gunndamental.OpenCore.entities"
    private static let idPrefix = "opencore-entity:"

    static func indexEntities(from store: Store) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        guard let rows = try? await store.entitiesByActivity() else { return }

        // Replace rather than add, so an entity later moved to a stricter domain does not stay
        // in a system-wide index that nothing else ever cleans.
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])

        var items: [CSSearchableItem] = []
        for (entity, activityCount) in rows.prefix(300) {
            // Hard privacy gate, and the same one MCP has: other processes can read this index,
            // so only what an external caller could read goes in. `personal` used to pass here.
            guard [.project, .publicRecord].contains(entity.domain) else { continue }

            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = entity.canonicalName
            attributes.displayName = entity.canonicalName
            attributes.contentDescription = "OpenCore \(entity.kind.rawValue) (\(entity.domain.rawValue)) · \(activityCount) linked claims and events"
            attributes.keywords = [
                entity.canonicalName,
                entity.kind.rawValue,
                entity.domain.rawValue,
                "OpenCore",
            ]

            let item = CSSearchableItem(
                uniqueIdentifier: "\(idPrefix)\(entity.id.value)",
                domainIdentifier: domainIdentifier,
                attributeSet: attributes
            )
            items.append(item)
        }

        guard !items.isEmpty else { return }
        try? await CSSearchableIndex.default().indexSearchableItems(items)
    }

    static func entityID(from userActivity: NSUserActivity) -> EntityID? {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix(idPrefix)
        else { return nil }
        let raw = String(identifier.dropFirst(idPrefix.count))
        return raw.isEmpty ? nil : EntityID(raw)
    }
}

// MARK: - AppIntents & Apple Shortcuts

@MainActor
final class PendingSection {
    static let shared = PendingSection()
    var section: Section?

    func take() -> Section? {
        defer { section = nil }
        return section
    }
}

struct AskOpenCoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask OpenCore"
    static let description = IntentDescription(
        "Answer a question from your OpenCore evidence store with a verifiable receipt."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask OpenCore?")
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = try await Store.open()
        let embedder = try? NLEmbeddingProvider()
        let tuning = await MainActor.run { AppSettings.shared.tuning }
        let reasoner = Reasoner(store: store, embedder: embedder, tuning: tuning)
        // AppIntents can be invoked by automated Shortcuts or model-generated tool calls, so
        // treat the caller as external: sensitive domains cannot be unlocked via query wording.
        let completed = try await reasoner.systemAnswer(question)
        let text = completed.answer.shortcutText(brief: completed.brief?.text)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct OpenContradictionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Review OpenCore Contradictions"
    static let description = IntentDescription(
        "Open OpenCore to inspect and resolve competing claims across sources."
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingSection.shared.section = .contradictions
        if AppModel.shared.store != nil {
            AppModel.shared.navigate(to: .contradictions)
        }
        let store = try await Store.open()
        let openCount = try await store.contradictions(unresolvedOnly: true).count
        let message = openCount == 0
            ? "No unresolved contradictions in OpenCore."
            : "\(openCount) unresolved contradiction\(openCount == 1 ? "" : "s") ready for review."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct OpenEntityDossierIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Entity Dossier in OpenCore"
    static let description = IntentDescription(
        "Open a project, person, or technology dossier in OpenCore."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Entity Name")
    var entityName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingEntity.shared.name = entityName
        PendingSection.shared.section = .entities
        if AppModel.shared.store != nil {
            AppModel.shared.openEntity(named: entityName)
        }
        return .result(dialog: IntentDialog(stringLiteral: "Opening \(entityName) in OpenCore."))
    }
}

struct OpenCoreShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOpenCoreIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Search my history in \(.applicationName)",
            ],
            shortTitle: "Ask OpenCore",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: OpenContradictionsIntent(),
            phrases: [
                "Show contradictions in \(.applicationName)",
                "Check conflicts in \(.applicationName)",
            ],
            shortTitle: "Review Contradictions",
            systemImageName: "exclamationmark.triangle"
        )
    }
}
