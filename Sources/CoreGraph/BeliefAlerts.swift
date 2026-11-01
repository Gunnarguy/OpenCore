import CoreModel
import Foundation

/// Decides what is worth interrupting someone for after a sync.
///
/// Pure, and outside the app target on purpose: the notification code cannot be tested, and the
/// defect here was a decision rather than a delivery. The same two contradictions fired after
/// every non-empty sync under a timestamped identifier, so they stacked, and each one invited
/// a click that used to disable rebuild for good.
public enum BeliefAlerts {
    /// An identifier stable for one set of contradictions, so delivering it twice replaces
    /// the banner instead of adding one. nil when nothing new opened.
    public static func contradictionIdentifier(for opened: [ContradictionID]) -> String? {
        guard !opened.isEmpty else { return nil }
        return "opencore.contradictions." + opened.map(\.value).sorted().joined(separator: "-").prefix(120)
    }

    /// True when a new belief version is a real change of mind rather than a working document
    /// restating itself. A handoff is rewritten every session, and alerting on that would drown
    /// the one thing that alert exists for.
    public static func isWorthAlerting(predicate: String) -> Bool {
        !Predicate.documentRestated.contains(predicate)
    }
}
