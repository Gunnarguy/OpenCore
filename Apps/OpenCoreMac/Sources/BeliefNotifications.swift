import CoreGraph
import CoreModel
import CoreStore
import Foundation
import UserNotifications

/// Delivers native macOS notifications when an ingestion pass updates an existing belief
/// (`belief.version > 1`) or opens a contradiction that no earlier pass had seen.
///
/// Sensitive domains (`.medical`, `.financial`, `.relationships`) never include claim values in
/// notification banners so lock-screen or screen-sharing notifications cannot leak private facts.
enum BeliefNotifier {
    private static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestAuthorizationIfNeeded() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notifyIfNeeded(
        outcome: IngestPipeline.Outcome,
        since syncStarted: Date,
        store: Store
    ) async {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()

        // 1. Newly opened contradictions, once each. `contradictionsOpen` repeats on every pass,
        // so it stays on the Contradictions screen and never reaches a banner.
        if let identifier = BeliefAlerts.contradictionIdentifier(for: outcome.contradictionsNew) {
            let count = outcome.contradictionsNew.count
            let content = UNMutableNotificationContent()
            content.title = "\(count) New Contradiction\(count == 1 ? "" : "s")"
            content.body = "Two sources made competing claims and neither outranks the other. Review them in Contradictions."
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await center.add(request)
        }

        // 2. Belief revisions (`version > 1`) where OpenCore changed its mind on a functional predicate.
        guard let recentBeliefs = try? await store.beliefsDecided(since: syncStarted) else { return }
        let revised = recentBeliefs.filter { $0.version > 1 }
        guard !revised.isEmpty else { return }

        // Counted after the filter, so a run of handoff rewrites cannot use up the three slots.
        var delivered = 0
        for belief in revised {
            guard delivered < 3 else { break }
            guard let claim = try? await store.claim(belief.claimID),
                  !claim.domain.isSensitive,
                  BeliefAlerts.isWorthAlerting(predicate: claim.predicate)
            else { continue }
            delivered += 1

            let subject = (try? await store.entity(claim.subject)?.canonicalName) ?? String(claim.subject.value.prefix(8))
            let predicate = claim.predicate.replacingOccurrences(of: "_", with: " ")
            let value: String
            if let objectEntity = claim.objectEntity,
               let resolved = try? await store.entity(objectEntity) {
                value = resolved.canonicalName
            } else {
                value = claim.literal ?? "updated"
            }

            let content = UNMutableNotificationContent()
            content.title = "Belief Updated: \(subject)"
            content.body = "\(subject) \(predicate) is now \(value) (v\(belief.version))"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "opencore.belief.\(belief.id.value)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
