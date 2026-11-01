import CoreModel
import CoreStore
import CoreTelemetry
import Foundation

/// What a rehearsed rebuild would do, saved beside its two database copies.
public struct RebuildReport: Codable, Sendable {
    public var createdAt: Date
    /// The live store's signature when the rehearsal began. Apply refuses if it has moved.
    public var signature: String
    /// A consistent copy of the store as it was, which is also the way back.
    public var pristinePath: String
    public var rebuiltPath: String
    public var diff: RebuildDiff
    /// Every change by id, with its reason. The totals in `diff` count these rows.
    public var explanation: RebuildExplanation
    public var carried: RebuildCarryOutcome
    /// Must be empty before this can be applied. There is no override.
    public var blockers: [String]
    /// A person should read these before approving.
    public var warnings: [String]
    public var seconds: Double

    public var canApply: Bool { blockers.isEmpty }

    public static let fileName = "rebuild-report.json"

    public static func load(from directory: URL) throws -> RebuildReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RebuildReport.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// What an apply left behind.
public struct RebuildApplyOutcome: Sendable {
    /// A proved copy of the store from the moment before the apply. The way back.
    public var backupPath: String
    /// Every receipt's real trace after the apply, against that backup.
    public var receipts: [RebuildReceiptTrace]

    public var receiptsBroken: Int { receipts.filter { $0.outcome == .broken }.count }
}

/// Rebuild on a copy, compare the result, and change the real store only on approval.
///
/// **The defect this replaces.** A button named "Run Deterministic Rebuild Check" deleted every
/// derived table in the live store and re-derived them. It was not a check. Traced on the real
/// store it would have cut 964 receipt-evidence and 523 receipt-claim links, returned quarantined
/// claims to readable domains, reset every knowledge timestamp, and left a half-empty graph for
/// any `opencore mcp` process reading during the work. Its verdict compared row counts, so a
/// claim changing domain read as "Reproduced 100% Exactly". One correction disabled it for good.
///
/// Now nothing here writes to the live store. `rehearse` works on two copies in `directory`.
/// `apply` is a separate call that a person makes after reading the report, and it replaces the
/// derived rows in one transaction, refusing if anything moved in between.
public struct RebuildRehearsal: Sendable {
    private let store: Store
    private let chunker: Chunker
    private let now: Date

    public init(store: Store, chunker: Chunker = Chunker(), now: Date = Date()) {
        self.store = store
        self.chunker = chunker
        self.now = now
    }

    /// Where rehearsals live by default: beside the store, outside iCloud, one per run.
    public static func defaultDirectory(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return Database.defaultPath().deletingLastPathComponent()
            .appendingPathComponent("Rehearsals", isDirectory: true)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)
    }

    /// Rebuild a copy of the store and report the difference. Never writes to the live store.
    public func rehearse(in directory: URL, log: @Sendable (String) -> Void = { _ in }) async throws -> RebuildReport {
        try await Telemetry.span("rebuild.rehearse", .graph) { scope in
            let started = Date()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let pristine = directory.appendingPathComponent("pristine.sqlite3")
            let rebuilt = directory.appendingPathComponent("rebuilt.sqlite3")

            let signature = try await store.floorSignature()
            log("copying the store")
            try await store.snapshot(to: pristine)
            try FileManager.default.copyItem(at: pristine, to: rebuilt)

            let copy = try await Store.open(at: rebuilt)
            log("clearing derived layers on the copy")
            try await copy.clearDerivedLayersOfRehearsalCopy()

            log("re-deriving on the copy")
            let pipeline = IngestPipeline(store: copy, chunker: chunker, now: now)
            _ = try await pipeline.rederive(log: log)

            log("replaying corrections and carrying user claims")
            var carried = try await copy.carryUserClaims(from: pristine)
            _ = try await BeliefEngine(store: copy, now: now).reconcile()

            log("carrying quarantine, knowledge time, vectors and receipt links")
            let derived = try await copy.carryDerivedState(from: pristine, now: now)
            carried.vectors = derived.vectors
            carried.quarantined = derived.quarantined
            carried.retained = derived.retained
            carried.heldAtEarlierDomain = derived.heldAtEarlierDomain
            carried.contradictionsKept = derived.contradictionsKept
            carried.contradictionsClosed = derived.contradictionsClosed
            carried.beliefVersionsKept = derived.beliefVersionsKept
            carried.evidenceTextKept = derived.evidenceTextKept

            log("comparing by id")
            var diff = try await copy.diff(againstPristine: pristine)
            var explanation = try await copy.explain(againstPristine: pristine)
            explanation.receipts = try await copy.receiptTraceAudit(againstEarlier: pristine)
            diff.record(explanation.receipts)
            try await copy.checkpoint()

            let report = RebuildReport(
                createdAt: now,
                signature: signature,
                pristinePath: pristine.path,
                rebuiltPath: rebuilt.path,
                diff: diff,
                explanation: explanation,
                carried: carried,
                blockers: Self.blockers(in: diff),
                warnings: Self.warnings(in: diff, explanation: explanation),
                seconds: Date().timeIntervalSince(started)
            )
            try report.save(to: directory)
            scope.set("blockers", report.blockers.count)
            scope.set("warnings", report.warnings.count)
            return report
        }
    }

    /// Replace the live store's derived layers with a rehearsal's. The approval step.
    ///
    /// Refuses a blocked report, and refuses if the store moved after the rehearsal, because
    /// then what was reviewed is not what would land. Copies the store first and proves the copy
    /// before anything changes: the pristine copy is as old as the rehearsal, and receipts have
    /// been arriving since.
    @discardableResult
    public func apply(_ report: RebuildReport) async throws -> RebuildApplyOutcome {
        guard report.canApply else { throw RebuildSafetyError.rehearsalBlocked(report.blockers) }
        // Checked here too, so a stale rehearsal does not cost a copy of the store.
        guard try await store.floorSignature() == report.signature else { throw RebuildSafetyError.staleRehearsal }

        let directory = URL(fileURLWithPath: report.pristinePath).deletingLastPathComponent()
        let backup = directory.appendingPathComponent("before-apply-\(UUID().uuidString).sqlite3")
        try await store.snapshot(to: backup)
        try await store.verifyBackup(backup, expecting: report.signature)

        try await store.applyRehearsal(rebuilt: URL(fileURLWithPath: report.rebuiltPath), expecting: report.signature)
        return RebuildApplyOutcome(backupPath: backup.path, receipts: try await store.receiptTraceAudit(againstEarlier: backup))
    }

    /// Conditions that stop an apply outright.
    static func blockers(in diff: RebuildDiff) -> [String] {
        var blockers: [String] = []
        if diff.domainsRaised > 0 {
            blockers.append("\(diff.domainsRaised) claim(s) would become readable by more callers than today")
        }
        if diff.eventsRaised > 0 {
            blockers.append("\(diff.eventsRaised) event(s) would become readable by more callers than today")
        }
        if diff.correctionsKept < diff.correctionsBefore {
            blockers.append("\(diff.correctionsBefore - diff.correctionsKept) user correction(s) would be lost")
        }
        if diff.correctionsUndone > 0 {
            blockers.append("\(diff.correctionsUndone) claim(s) you corrected would be believed again")
        }
        if diff.claimRowsDropped > 0 {
            blockers.append("\(diff.claimRowsDropped) claim row(s) would disappear")
        }
        if diff.contradictionRowsDropped > 0 {
            blockers.append("\(diff.contradictionRowsDropped) recorded contradiction(s) would disappear")
        }
        if diff.beliefVersionsDropped > 0 {
            blockers.append("\(diff.beliefVersionsDropped) recorded belief version(s) would disappear or change date")
        }
        if diff.receiptsBroken > 0 {
            blockers.append("\(diff.receiptsBroken) past answer(s) would no longer trace to what they cited")
        }
        return blockers
    }

    /// Things a person should weigh. Real and expected on a store whose extraction rules changed.
    static func warnings(in diff: RebuildDiff, explanation: RebuildExplanation = RebuildExplanation()) -> [String] {
        var warnings: [String] = []
        if explanation.unexplained > 0 {
            warnings.append("\(explanation.unexplained) change(s) have no known reason. Read them before applying")
        }
        if diff.claimsRetired > 0 { warnings.append("\(diff.claimsRetired) current claim(s) would be retired") }
        if diff.receiptLinksKept < diff.receiptLinksBefore {
            warnings.append("\(diff.receiptLinksBefore - diff.receiptLinksKept) of \(diff.receiptLinksBefore) receipt link(s) would be cut")
        }
        if diff.beliefsChanged > 0 { warnings.append("\(diff.beliefsChanged) current belief(s) would change value") }
        if diff.beliefsAdded > 0 { warnings.append("\(diff.beliefsAdded) slot(s) with no belief would get their first") }
        if diff.chunksWithoutVector > 0 {
            warnings.append("\(diff.chunksWithoutVector) passage(s) would need a vector; run `opencore embed` after applying")
        }
        if diff.domainsLowered > 0 {
            warnings.append("\(diff.domainsLowered) claim(s) would become readable by fewer callers")
        }
        if diff.edgesRemoved > 0 { warnings.append("\(diff.edgesRemoved) link(s) between entities would be removed") }
        return warnings
    }
}
