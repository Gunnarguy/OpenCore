import CoreModel
import Foundation
import Testing

@testable import CoreStore

/// Two additions from 2026-08-10, both aimed at the same observation: this system was
/// rigorously built and lightly used, and every defect found that day was found by exercising
/// it rather than by reading it.
///
/// **Judgements** exist because every retrieval constant in the project rests on 20 hand-written
/// benchmark cases. Chat turns were already persisted with their sources and receipts, so a
/// verdict was the only missing column between ordinary use and a growing eval corpus.
///
/// **The dossier** exists because claims, beliefs, contradictions and events were each reachable
/// and each had a tab, so the sidebar was the schema and the reader did the joins.
@Suite("Judgements and dossiers")
struct JudgementAndDossierTests {
    private static func temporaryStore() async throws -> Store {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3")
        return try await Store.open(at: path)
    }

    @Test("an unjudged answer stays distinguishable from a judged one")
    func unjudgedIsNotNeutral() async throws {
        let store = try await Self.temporaryStore()
        try await store.openConversation(id: "t", title: "t")
        try await store.append(StoredTurn(id: "a", conversationID: "t", ordinal: 0, role: "core", text: "one"))
        try await store.append(StoredTurn(id: "b", conversationID: "t", ordinal: 1, role: "core", text: "two"))

        try await store.judge(turn: "a", as: .good)

        // The whole point of the corpus. An accuracy figure computed as good/(good+bad) is a
        // different and much smaller claim than good/everything, and only one of them is
        // honest. Folding "nobody said" into either side is how a system starts reporting a
        // number it did not measure.
        let counts = try await store.judgementCounts()
        #expect(counts.good == 1)
        #expect(counts.bad == 0)
        #expect(counts.unjudged == 1)
        #expect(try await store.judgedTurns().count == 1)
    }

    @Test("withdrawing a verdict clears its timestamp with it")
    func withdrawingClearsTheTimestamp() async throws {
        let store = try await Self.temporaryStore()
        try await store.openConversation(id: "t", title: "t")
        try await store.append(StoredTurn(id: "a", conversationID: "t", ordinal: 0, role: "core", text: "one"))

        try await store.judge(turn: "a", as: .bad)
        #expect(try await store.turns(conversationID: "t").first?.judgedAt != nil)

        // A misclick has to be fully recoverable. Leaving `judged_at` behind would make the
        // corpus report a labelling that no longer exists, which is worse than never having
        // labelled it.
        try await store.judge(turn: "a", as: nil)
        let turn = try await store.turns(conversationID: "t").first
        #expect(turn?.judgement == nil)
        #expect(turn?.judgedAt == nil)
        #expect(try await store.judgedTurns().isEmpty)
    }

    @Test("a judgement survives the turn being re-appended")
    func judgementSurvivesReappend() async throws {
        let store = try await Self.temporaryStore()
        try await store.openConversation(id: "t", title: "t")
        let turn = StoredTurn(id: "a", conversationID: "t", ordinal: 0, role: "core", text: "streaming…")
        try await store.append(turn)
        try await store.judge(turn: "a", as: .good)

        // `append` upserts, because a turn is written as it streams. If its `ON CONFLICT` clause
        // ever grows to touch the judgement columns, a verdict would be silently erased by the
        // next frame of the same answer.
        var finished = turn
        finished.text = "the finished answer"
        try await store.append(finished)

        let reloaded = try await store.turns(conversationID: "t").first
        #expect(reloaded?.text == "the finished answer")
        #expect(reloaded?.judgement == .good)
    }

    @Test("a dossier gathers what six separate screens used to show")
    func dossierAssemblesOneEntity() async throws {
        let store = try await Self.temporaryStore()
        let source = Source(
            kind: .github, handle: "tester", displayName: "test",
            defaultAuthority: .authoredArtifact, defaultDomain: .project
        )
        try await store.upsert(source)

        let entity = CoreEntity(kind: .project, canonicalName: "OpenClinic", domain: .project)
        let other = CoreEntity(kind: .project, canonicalName: "Unrelated", domain: .project)
        try await store.upsert([entity, other])
        try await store.addAliases([EntityAlias(entityID: entity.id, surface: "openclinic", confidence: 0.9)])

        let claim = CoreClaim(
            subject: entity.id, predicate: "built_with", literal: "Swift", confidence: 0.9,
            authority: .authoredArtifact, derivation: .observed,
            validity: Validity(observedAt: Date(timeIntervalSince1970: 1_700_000_000)), domain: .project
        )
        let elsewhere = CoreClaim(
            subject: other.id, predicate: "built_with", literal: "Python", confidence: 0.9,
            authority: .authoredArtifact, derivation: .observed,
            validity: Validity(observedAt: Date(timeIntervalSince1970: 1_700_000_000)), domain: .project
        )
        try await store.save([claim, elsewhere])
        try await store.save([
            CoreEvent(subject: entity.id, verb: "committed", detail: "a change", occurredAt: Date(timeIntervalSince1970: 1_700_000_000), domain: .project, authority: .authoredArtifact),
            CoreEvent(subject: other.id, verb: "committed", detail: "elsewhere", occurredAt: Date(timeIntervalSince1970: 1_700_000_000), domain: .project, authority: .authoredArtifact),
        ])

        let dossier = try #require(try await store.dossier(for: entity.id))
        #expect(dossier.entity.canonicalName == "OpenClinic")
        #expect(dossier.aliases.contains("openclinic"))

        // The other entity's claim and event must not leak in. A dossier that quietly widens to
        // the whole store is worse than no dossier, because everything on it reads as being
        // about the thing named at the top.
        #expect(dossier.claims.count == 1)
        #expect(dossier.claims.first?.value == "Swift")
        #expect(dossier.events.count == 1)
        #expect(dossier.events.first?.detail == "a change")
    }

    @Test("a slot that changed its mind reports how many times")
    func revisionsAreCounted() async throws {
        let store = try await Self.temporaryStore()
        let entity = CoreEntity(kind: .project, canonicalName: "OpenCore", domain: .project)
        try await store.upsert([entity])
        let claim = CoreClaim(
            subject: entity.id, predicate: "uses", literal: "SQLite", confidence: 0.9,
            authority: .authoredArtifact, derivation: .observed,
            validity: Validity(observedAt: Date(timeIntervalSince1970: 1_700_000_000)), domain: .project
        )
        try await store.save([claim])

        // Two versions of the same slot. `beliefHistory` has existed and been correct all along
        // with nothing able to display it, because a version history has no meaning without a
        // subject to hang it on. This count is what makes a changed slot findable.
        try await store.save(Belief(
            claimKey: claim.claimKey, version: 1, claimID: claim.id, confidence: 0.8,
            authority: .authoredArtifact, validity: claim.validity, reason: "first read"
        ))
        try await store.save(Belief(
            claimKey: claim.claimKey, version: 2, claimID: claim.id, confidence: 0.9,
            authority: .authoredArtifact, validity: claim.validity, reason: "confirmed by a second source"
        ))

        let dossier = try #require(try await store.dossier(for: entity.id))
        let row = try #require(dossier.claims.first)
        #expect(row.revisions == 2)
        #expect(row.belief?.version == 2)
    }

    @Test("the corpus snapshot reports what it could not place rather than dropping it")
    func snapshotKeepsUndatedVisible() async throws {
        let store = try await Self.temporaryStore()
        let source = Source(
            kind: .github, handle: "tester", displayName: "GitHub",
            defaultAuthority: .authoredArtifact, defaultDomain: .project
        )
        try await store.upsert(source)
        try await store.ingest([
            CoreObject(sourceID: source.id, kind: .repository, externalID: "a", title: "a", text: "a",
                       authoredAt: Date(timeIntervalSince1970: 1_700_000_000), domain: .project, authority: .authoredArtifact),
            CoreObject(sourceID: source.id, kind: .repository, externalID: "b", title: "b", text: "b",
                       domain: .project, authority: .authoredArtifact),
        ])

        let snapshot = try await store.corpusSnapshot()
        #expect(snapshot.objects == 2)
        // A histogram that silently omits undated objects presents a confident picture of a
        // corpus it only partly drew.
        #expect(snapshot.undated == 1)
        #expect(snapshot.byMonth.map(\.1).reduce(0, +) == 1)
        #expect(snapshot.bySource.first?.0 == "GitHub")
    }
}
