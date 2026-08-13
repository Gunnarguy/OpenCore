import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreGraph

/// **The bug.** `extractCommitClaims` carries a doc comment stating the intended shape
/// exactly: "Claim ids are derived from subject, predicate and object, so 340 commits by one
/// author collapse to one claim carrying 340 pieces of evidence. That is the correct shape: the
/// belief is single, the support for it accumulates."
///
/// It did not do that. `ClaimID` is derived from subject, predicate, object **and
/// `validity.validFrom`**, which the comment omits, and the claim was dated with each commit's
/// own timestamp. So every commit minted a fresh row for one unchanging fact. Measured on the
/// real store: 647 `contributed_to` rows covering 33 actual facts, filling the Claims screen's
/// 400-row window before anything else could be reached.
///
/// The fix is to leave these claims undated, which is also the honest reading: "X contributed
/// to Y" is not true *from* a date, it is true, and each commit is evidence for it. The dates
/// survive on the evidence rows at finer granularity than one date on the claim could carry.
///
/// The two tests below are deliberately a pair. The first asserts the collapse. The second
/// asserts that the fix was **not** applied to `status`, which is in `Predicate.functional` and
/// whose `validFrom` supersession genuinely reads: undating that one would collapse the
/// ordering onto sync time and turn a real supersession into a false tie.

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-extract-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

private let source = Source(
    kind: .github, handle: "gunnarguy", displayName: "gunnarguy",
    defaultAuthority: .authoredArtifact, defaultDomain: .project
)

/// The repository the commits belong to. Present in both tests because the project entity is
/// resolved from the repository object, not from a commit, and `contributed_to` references it.
/// The GitHub connector never emits one without the other.
private func repository() -> CoreObject {
    CoreObject(
        sourceID: source.id,
        kind: .repository,
        externalID: "gunnarguy/OpenCore",
        title: "OpenCore",
        text: "gunnarguy/OpenCore\n\nAn evidence-native store for personal history.",
        authoredAt: Date(timeIntervalSince1970: 1_700_000_000),
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "repo": "gunnarguy/OpenCore",
            "pushed_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_754_000_000)),
        ]
    )
}

private func commit(_ sha: String, at date: Date) -> CoreObject {
    CoreObject(
        sourceID: source.id,
        kind: .commit,
        externalID: "gunnarguy/OpenCore@\(sha)",
        title: "feat(retrieval): fuse by rank",
        text: "gunnarguy/OpenCore\n\nfeat(retrieval): fuse by rank",
        authoredAt: date,
        domain: .project,
        authority: .authoredArtifact,
        metadata: ["repo": "gunnarguy/OpenCore", "author": "gunnarguy"]
    )
}

@Test("many commits by one author collapse to one claim carrying many pieces of evidence")
func commitsCollapseToOneClaim() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    // Three commits, three different days. Before the fix these produced three claim rows all
    // saying "gunnarguy contributed to OpenCore".
    let commits = [
        commit("aaa1", at: Date(timeIntervalSince1970: 1_741_000_000)),
        commit("bbb2", at: Date(timeIntervalSince1970: 1_749_900_000)),
        commit("ccc3", at: Date(timeIntervalSince1970: 1_754_000_000)),
    ]
    // Through the pipeline rather than calling the extractor directly: entity resolution
    // happens there, and `IngestPipeline` is the project's single derivation path, so a test
    // that bypassed it would be testing a route nothing uses.
    _ = try await IngestPipeline(store: store).run(objects: [repository()] + commits)

    let contributions = try await store.allClaims(currentOnly: true, limit: 100)
        .filter { $0.predicate == Predicate.contributedTo }

    // The invariant, not the number three: one fact, one row, however many commits support it.
    #expect(contributions.count == 1)

    let claim = try #require(contributions.first)
    // And the dates are not lost. They are on the evidence, one row per commit, which is finer
    // than a single date on the claim could ever have been.
    let evidence = try await store.evidence(for: claim.id)
    #expect(evidence.count == commits.count)
}

@Test("a functional claim keeps the world time its supersession depends on")
func statusKeepsItsValidFrom() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    _ = try await IngestPipeline(store: store).run(objects: [repository()])

    let status = try #require(
        try await store.allClaims(currentOnly: true, limit: 100).first { $0.predicate == Predicate.status }
    )

    // The guard that stops someone "fixing" the duplicate-row count by undating this too.
    // `status` is functional, so `BeliefEngine.rank` reads `validFrom` to decide which of two
    // statuses is later. Without it the ordering falls back to `observedAt`, which is sync
    // time, and two statuses learned in one sync would tie and be reported as an unresolvable
    // contradiction instead of a supersession.
    #expect(status.validity.validFrom != nil)
    #expect(Predicate.functional.contains(Predicate.status))
}
