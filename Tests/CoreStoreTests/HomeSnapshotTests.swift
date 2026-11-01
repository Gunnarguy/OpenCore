import CoreModel
import Foundation
import Testing

@testable import CoreStore

private func store() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-home-\(UUID().uuidString)/store.sqlite3"))
}

// The bug: `homeSnapshot` computed seven days of activity, Home read only `neverSynced`, and
// the first screen led with machine status. These pin what the new first screen stands on.
@Test("Home reports the window's activity, belief changes and open contradictions")
func homeLeadsWithChanges() async throws {
    let store = try await store()
    let now = Date()
    let project = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)
    try await store.upsert([project])
    try await store.save([
        CoreEvent(subject: project.id, verb: "committed", detail: "Ship the thing", occurredAt: now.addingTimeInterval(-3_600), domain: .project, authority: .authoredArtifact),
        CoreEvent(subject: project.id, verb: "committed", detail: "chore(roadmap): sync", occurredAt: now.addingTimeInterval(-1_800), domain: .project, authority: .authoredArtifact),
        CoreEvent(subject: project.id, verb: "committed", detail: "Too old to count", occurredAt: now.addingTimeInterval(-30 * 86_400), domain: .project, authority: .authoredArtifact),
    ])
    let first = CoreClaim(subject: project.id, predicate: Predicate.status, literal: "dormant", confidence: 0.8, authority: .derivedPattern, derivation: .inferred, validity: Validity(validFrom: now.addingTimeInterval(-20 * 86_400), observedAt: now.addingTimeInterval(-20 * 86_400)), domain: .project)
    let second = CoreClaim(subject: project.id, predicate: Predicate.status, literal: "active", confidence: 0.8, authority: .derivedPattern, derivation: .inferred, validity: Validity(validFrom: now.addingTimeInterval(-86_400), observedAt: now.addingTimeInterval(-86_400)), domain: .project)
    try await store.save([first, second])
    let key = second.claimKey
    let v1 = Belief(claimKey: key, version: 1, claimID: first.id, confidence: 0.8, authority: .derivedPattern, validity: first.validity, reason: "first evidence for this slot", decidedAt: now.addingTimeInterval(-20 * 86_400))
    let v2 = Belief(claimKey: key, version: 2, claimID: second.id, confidence: 0.8, authority: .derivedPattern, validity: second.validity, supersedes: v1.id, reason: "changed from 'dormant' to 'active'", decidedAt: now.addingTimeInterval(-86_400))
    try await store.save(v1)
    try await store.save(v2)
    try await store.save([Contradiction(claimA: first.id, claimB: second.id, kind: .directConflict, resolution: .unresolved, detectedAt: now, reason: "no ordering")])

    let snapshot = try await store.homeSnapshot(since: now.addingTimeInterval(-2 * 86_400), now: now)

    let activity = try #require(snapshot.work.first)
    #expect(activity.subject == "Atlas")
    #expect(activity.events == 1)
    #expect(activity.upkeep == 1)
    #expect(snapshot.beliefChanges.map(\.reason) == ["changed from 'dormant' to 'active'"])
    #expect(snapshot.contradictionRows.first?.subject == "Atlas")
    #expect(snapshot.eventsSinceVisit == 2)
    #expect(snapshot.beliefChangesSinceVisit == 1)
}

// nil and zero are different statements: nil means there was no earlier visit to compare with.
@Test("with no previous visit Home makes no claim about what changed since one")
func noVisitNoSince() async throws {
    let snapshot = try await store().homeSnapshot()
    #expect(snapshot.eventsSinceVisit == nil)
    #expect(snapshot.beliefChangesSinceVisit == nil)
}

// Home is on show whenever the app is, so a sensitive subject must not appear on it unasked.
@Test("sensitive subjects stay off Home")
func homeHidesSensitive() async throws {
    let store = try await store()
    let now = Date()
    let clinic = CoreEntity(kind: .concept, canonicalName: "Blood panel", domain: .medical)
    let quarantined = CoreEntity(kind: .project, canonicalName: "Quarantined", domain: .restricted)
    try await store.upsert([clinic, quarantined])
    try await store.save([
        CoreEvent(subject: clinic.id, verb: "noted", detail: "result", occurredAt: now.addingTimeInterval(-60), domain: .medical, authority: .authoredArtifact),
        CoreEvent(subject: quarantined.id, verb: "edited", detail: "file", occurredAt: now.addingTimeInterval(-60), domain: .restricted, authority: .authoredArtifact),
    ])
    let snapshot = try await store.homeSnapshot(now: now)
    #expect(snapshot.recent.isEmpty)
}

// Two guards on one query, each asserted alone. An event can sit in a readable domain about a
// subject in a blocked one, and printing it would print the blocked subject's name.
@Test("activity leaves out an event in a blocked domain, about a readable subject")
func activityChecksTheEventDomain() async throws {
    let store = try await store()
    let now = Date()
    let open = CoreEntity(kind: .project, canonicalName: "Open", domain: .project)
    try await store.upsert([open])
    try await store.save([CoreEvent(subject: open.id, verb: "noted", detail: "private detail", occurredAt: now.addingTimeInterval(-60), domain: .medical, authority: .authoredArtifact)])
    let summary = try await store.activity(from: now.addingTimeInterval(-3_600), to: now, domains: [.project, .publicRecord])
    #expect(summary.totalEvents == 0)
    #expect(summary.groups.isEmpty)
    #expect(summary.newestEventAt == nil)
}

@Test("activity leaves out an event in a readable domain, about a blocked subject")
func activityChecksTheSubjectDomain() async throws {
    let store = try await store()
    let now = Date()
    let blocked = CoreEntity(kind: .project, canonicalName: "Blocked", domain: .medical)
    try await store.upsert([blocked])
    try await store.save([CoreEvent(subject: blocked.id, verb: "committed", detail: "public detail", occurredAt: now.addingTimeInterval(-60), domain: .project, authority: .authoredArtifact)])
    let summary = try await store.activity(from: now.addingTimeInterval(-3_600), to: now, domains: [.project, .publicRecord])
    #expect(summary.totalEvents == 0)
    #expect(summary.groups.isEmpty)
}

// One handoff rewrite is three revisions and the screen shows six rows, so in date order a single
// session could push a repository going dormant off Home. `next_action` joining the functional set
// made that worse, which is why this is sorted rather than left to the view.
@Test("a real change of mind outranks a document restating itself")
func realChangesLeadBeliefChanges() async throws {
    let store = try await store()
    let now = Date()
    let atlas = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)
    try await store.upsert([atlas])

    func revision(_ predicate: String, _ value: String, age: TimeInterval) async throws {
        let at = now.addingTimeInterval(-age)
        let first = CoreClaim(subject: atlas.id, predicate: predicate, literal: value + " before", confidence: 0.9, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: at, observedAt: at), domain: .project)
        let second = CoreClaim(subject: atlas.id, predicate: predicate, literal: value, confidence: 0.9, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: at, observedAt: at), domain: .project)
        try await store.save([first, second])
        let v1 = Belief(claimKey: first.claimKey, version: 1, claimID: first.id, confidence: 0.9, authority: .authoredArtifact, validity: first.validity, reason: "first", decidedAt: at)
        try await store.save(v1)
        try await store.save(Belief(claimKey: first.claimKey, version: 2, claimID: second.id, confidence: 0.9, authority: .authoredArtifact, validity: second.validity, supersedes: v1.id, reason: "changed", decidedAt: at))
    }
    try await revision(Predicate.status, "dormant", age: 7_200)
    try await revision(Predicate.objective, "A later plan", age: 3_600)
    try await revision(Predicate.nextAction, "A later step", age: 1_800)

    let snapshot = try await store.homeSnapshot(now: now)
    #expect(snapshot.beliefChanges.map(\.predicate) == [Predicate.status, Predicate.nextAction, Predicate.objective])
}
