import CoreStore
import Foundation

/// A rehearsal in plain language, for the Maintenance screen and the CLI.
///
/// Lives here and not in the view because the app has no tests, and these sentences carry the
/// numbers a person approves an apply on.
public struct RebuildNarrative: Sendable {
    public struct Finding: Sendable, Identifiable {
        public var title: String
        public var summary: String
        /// One line per reason, with its count.
        public var breakdown: [String]
        public var needsAttention: Bool
        public var id: String { title }
    }

    public static let whatItIs = """
        Your objects are the original records: files, notes, commits and events. Everything OpenCore \
        concluded from them (claims, beliefs, contradictions, passages) can be worked out again. \
        A rebuild does that with today's rules and shows you what would be different.
        """

    public static let whenToUse = """
        Use it after an update changes how OpenCore reads your records, after you change the \
        passage size, or when a claim or belief looks wrong and you suspect how it was derived. \
        You do not need it for a normal sync.
        """

    public static let howItIsSafe = """
        A rehearsal works on two copies and needs about twice the store's size on disk. Your store is \
        not touched. Applying is a separate step that only happens when you confirm it.
        """

    public var headline: String
    public var findings: [Finding]
    public var applyWill: [String]
    public var applyWillNot: [String]
    public var confirmationTitle: String
    public var confirmation: String

    public init(_ report: RebuildReport) {
        let diff = report.diff
        let explanation = report.explanation
        let reasons = { (kind: RebuildChangeKind) in
            explanation.reasons(for: kind).map { "\($0.count): \(Self.sentence(for: $0.reason))" }
        }

        headline = report.canApply
            ? "Nothing has changed yet. This is what applying would do."
            : "This rehearsal cannot be applied. Nothing has changed."

        var findings = [Finding(
            title: "Current beliefs",
            summary: "\(diff.beliefsChanged) would change value, and \(diff.beliefsAdded) slot(s) with no belief would get their first.",
            breakdown: RebuildBeliefReason.allCases.compactMap { reason in
                let count = explanation.beliefs.filter { $0.reason == reason }.count
                return count > 0 ? "\(count): \(Self.sentence(for: reason))" : nil
            },
            needsAttention: diff.beliefsChanged + diff.beliefsAdded > 0
        )]
        findings.append(Finding(
            title: "Claims no longer believed",
            summary: "\(diff.claimsRetired) would be retired. Each is kept as history, and past answers that cited it still resolve.",
            breakdown: reasons(.retired),
            needsAttention: false
        ))
        findings.append(Finding(
            title: "New claims",
            summary: "\(diff.claimsAdded) would be added, and \(diff.claimsAddedAsHistory) more recorded as history only. \(diff.claimsRestored) retired claim(s) would be believed again.",
            breakdown: reasons(.added) + reasons(.restored),
            needsAttention: false
        ))
        findings.append(Finding(
            title: "Claim authority",
            summary: "\(diff.authorityChanged) would change standing.",
            breakdown: reasons(.authorityChanged),
            needsAttention: false
        ))
        findings.append(Finding(
            title: "Who can read what",
            summary: "\(diff.domainsRaised + diff.eventsRaised) would become readable by more callers, which would stop the apply. \(diff.domainsLowered) would become readable by fewer. \(diff.quarantineHeld) stay in quarantine, including \(report.carried.heldAtEarlierDomain) new row(s) held at the domain of the statement they replace.",
            breakdown: reasons(.domainLowered),
            needsAttention: diff.domainsRaised + diff.eventsRaised > 0
        ))
        let contradictions = explanation.contradictions
        findings.append(Finding(
            title: "Contradictions",
            summary: "Open ones go from \(diff.openContradictionsBefore) to \(diff.openContradictionsAfter). No recorded contradiction is lost.",
            breakdown: RebuildContradictionFate.allCases.compactMap { fate in
                let count = contradictions.filter { $0.fate == fate }.count
                return count > 0 ? "\(count): \(Self.sentence(for: fate))" : nil
            },
            needsAttention: diff.contradictionRowsDropped > 0
        ))
        findings.append(Finding(
            title: "Past answers",
            summary: "All \(diff.receiptsTotal) receipts were traced for real: \(diff.receiptsResolving) resolve as before, \(diff.receiptsBroken) broken, and \(diff.receiptsWithoutLinks) never had links to trace. \(diff.receiptsWithEvidence) have evidence rows.",
            breakdown: Self.grouped(explanation.receipts.filter { $0.outcome == .noLinks }.map(\.detail)),
            needsAttention: diff.receiptsBroken > 0
        ))
        findings.append(Finding(
            title: "Passages",
            summary: "\(diff.chunksAdded) added and \(diff.chunksRemoved) removed. \(diff.chunksWithoutVector) would need a vector before search can find them by meaning.",
            breakdown: [],
            needsAttention: false
        ))
        self.findings = findings

        applyWill = [
            "Replace claims, beliefs, contradictions, passages and events with the rehearsed set, in one transaction, so anything reading the store sees the old set or the new one.",
            "Make \(diff.beliefsChanged) belief change(s), add \(diff.beliefsAdded) new belief(s), retire \(diff.claimsRetired) claim(s) and add \(diff.claimsAdded).",
            "Copy the store first, prove the copy, and keep it beside this rehearsal as the way back.",
            "Build the \(diff.chunksWithoutVector) missing vector(s) afterwards.",
        ]
        applyWillNot = [
            "Change your objects, your saved chats or your receipts.",
            "Make anything readable by more callers. The check runs again during the apply.",
            "Run if the store changed after this rehearsal. You would rehearse again.",
        ]

        confirmationTitle = "Apply this rebuild to your store?"
        confirmation = """
            \(diff.beliefsChanged) belief change(s) and \(diff.beliefsAdded) new belief(s). \(diff.claimsRetired) claim(s) retired and kept as history, \
            \(diff.claimsAdded) added. \(diff.authorityChanged) authority change(s). \(diff.domainsLowered) claim(s) \
            readable by fewer callers, 0 by more. Open contradictions \(diff.openContradictionsBefore) to \
            \(diff.openContradictionsAfter). \(diff.receiptsResolving) of \(diff.receiptsTotal - diff.receiptsWithoutLinks) \
            linked past answers still trace.

            Your objects are not touched. The store is copied first, and that copy is the way back. \
            If the store changed after the rehearsal, this refuses and you rehearse again.
            """
    }

    /// Identical lines, counted.
    private static func grouped(_ lines: [String]) -> [String] {
        Dictionary(grouping: lines, by: { $0 }).map { "\($0.value.count): \($0.key)" }.sorted()
    }

    public static func sentence(for reason: RebuildChangeReason) -> String {
        switch reason {
        case .sameStatementNewDate: "the same statement, on a row with a different date"
        case .movedToAnotherSubject: "the same statement from the same record, now under a different name"
        case .replacedByNewValue: "a different value now holds that slot"
        case .noLongerDerived: "nothing in your records produces this any more"
        case .newValueInSlot: "a value that slot did not have before"
        case .newSlot: "something OpenCore had not concluded before"
        case .replayedHistory: "an earlier state of a record, replayed as history"
        case .correctedByOwner: "says what you corrected, so it stays retired"
        case .derivedAgain: "your records produce this again"
        case .followsObjectAuthority: "now matches the authority of the records it was read from"
        case .objectAwaitingReview: "read from a record still awaiting review"
        case .mixedSourceDomains: "read from records in different domains, so it is restricted"
        case .followsObjectDomain: "now matches the domain of the records it was read from"
        case .unexplained: "no known reason"
        }
    }

    public static func sentence(for reason: RebuildBeliefReason) -> String {
        switch reason {
        case .silencePassedThreshold: "no real work for \(Int(ClaimExtractor.dormantAfter / 86_400)) days, so the project now reads as dormant"
        case .winnerLostItsAuthority: "the old answer led only on authority its records no longer have"
        case .newerReadingWins: "a newer reading of your records wins"
        case .firstBeliefForSlot: "no belief here before, so this is the first"
        }
    }

    public static func sentence(for fate: RebuildContradictionFate) -> String {
        switch fate {
        case .kept: "kept as they were"
        case .decidedByRebuild: "were open, and the same disagreement is now decided"
        case .resolutionChanged: "resolved differently than before"
        case .new: "found by this rebuild"
        }
    }
}
