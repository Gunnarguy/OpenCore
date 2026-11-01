import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreGraph

private func temporaryStore() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-beliefs-\(UUID().uuidString)/test.sqlite3"))
}

private let files = Source(kind: .filesystem, handle: "workspace", displayName: "Files", defaultAuthority: .authoredArtifact, defaultDomain: .project)
private let github = Source(kind: .github, handle: "user", displayName: "GitHub", defaultAuthority: .authoredArtifact, defaultDomain: .project)
private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private let day: TimeInterval = 86_400

private func stateDocument(path: String, objective: String, at date: Date, authority: Authority) -> CoreObject {
    CoreObject(
        sourceID: files.id, kind: .file, externalID: path, title: "STATE.md",
        text: "# State\n\nProject: Atlas\nObjective: \(objective)\n", authoredAt: date,
        domain: .project, authority: authority, metadata: ["root": "/tmp", "extension": "md", "relative_path": "Atlas/STATE.md"]
    )
}

private func currentObjective(_ store: Store) async throws -> String? {
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    guard let belief = try await store.currentBelief(key: "\(subject.value)|\(Predicate.objective)") else { return nil }
    return try await store.claim(belief.claimID)?.literal
}

// The bug, measured on the real store: 70 objects from an old `/private/tmp` copy of the
// repositories sat at authority 4, the real STATE.md files sat at 2, and `adjudicate` asked about
// authority before time. So OpenCore's own objective froze on a sentence the file had long since
// replaced, two newer values were retracted, and the screen said "authored artifact outranks
// generated summary" about the same document. Six of the store's 14 contradictions were this.
@Test("a newer revision of the same document wins by time, with no contradiction row")
func documentSuccessionIgnoresAuthority() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let now = Date()
    let oldCopy = stateDocument(path: "/private/tmp/copy/Atlas/Docs/ai/STATE.md", objective: "Measure the old thing", at: now.addingTimeInterval(-10 * day), authority: .authoredArtifact)
    let real = stateDocument(path: "/repo/Atlas/Docs/ai/STATE.md", objective: "Ship the new thing", at: now.addingTimeInterval(-day), authority: .generatedSummary)

    let outcome = try await IngestPipeline(store: store, now: now).run(objects: [oldCopy, real])

    #expect(try await currentObjective(store) == "Ship the new thing")
    #expect(outcome.contradictions == 0)
    #expect(outcome.documentSuccessions == 1)
    #expect(try await store.contradictions().isEmpty)
}

// The guard above must not swallow real disagreement. A README and a handoff are two documents.
@Test("two different documents that disagree are still a contradiction")
func differentDocumentsStillContradict() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let now = Date()
    let state = stateDocument(path: "/repo/Atlas/STATE.md", objective: "Ship the new thing", at: now.addingTimeInterval(-day), authority: .authoredArtifact)
    var handoff = stateDocument(path: "/repo/Atlas/HANDOFF.md", objective: "Do something else", at: now.addingTimeInterval(-2 * day), authority: .authoredArtifact)
    handoff.title = "HANDOFF.md"

    let outcome = try await IngestPipeline(store: store, now: now).run(objects: [state, handoff])
    #expect(outcome.documentSuccessions == 0)
    #expect(outcome.contradictions == 1)
}

// A tie has no ordering to act on, so it must fall through rather than guess.
@Test("two revisions with the same date retire nothing")
func tiedRevisionsAreLeftAlone() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let now = Date()
    let at = now.addingTimeInterval(-day)
    let one = stateDocument(path: "/a/Atlas/STATE.md", objective: "First wording", at: at, authority: .authoredArtifact)
    let two = stateDocument(path: "/b/Atlas/STATE.md", objective: "Second wording", at: at, authority: .authoredArtifact)
    let outcome = try await IngestPipeline(store: store, now: now).run(objects: [one, two])
    #expect(outcome.documentSuccessions == 0)
    #expect(outcome.contradictionsOpen == 1)
}

private func repository(language: String = "Swift", pushed: Date, created: Date) -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .repository, externalID: "user/Atlas", title: "Atlas",
        text: "user/Atlas\nA repository about pushes at \(stamp(pushed)) in \(language)", authoredAt: created,
        domain: .project, authority: .authoredArtifact,
        metadata: ["language": language, "archived": "false", "pushed_at": stamp(pushed)]
    )
}

private func commit(_ message: String, at date: Date, author: String = "someone") -> CoreObject {
    CoreObject(
        sourceID: github.id, kind: .commit, externalID: "user/Atlas@\(message)", title: message,
        text: "user/Atlas\n\(message)", authoredAt: date, domain: .project, authority: .authoredArtifact,
        metadata: ["repo": "user/Atlas", "author": author]
    )
}

private func currentStatus(_ store: Store) async throws -> String? {
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    guard let belief = try await store.currentBelief(key: "\(subject.value)|\(Predicate.status)") else { return nil }
    return try await store.claim(belief.claimID)?.literal
}

// The bug: with no new push, `pushed_at` is unchanged, so `active` and `dormant` shared a
// `validFrom`, tied, and the verdict was "no temporal ordering". The belief stayed `active`
// forever. Measured 2026-10-30: zero active-to-dormant beliefs in the whole store.
@Test("a repository that goes quiet becomes dormant at the moment the threshold passed")
func goingQuietResolves() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let pushed = Date().addingTimeInterval(-300 * day)
    let created = pushed.addingTimeInterval(-500 * day)
    let object = repository(pushed: pushed, created: created)

    _ = try await IngestPipeline(store: store, now: pushed.addingTimeInterval(day)).run(objects: [object])
    #expect(try await currentStatus(store) == "active")

    let later = pushed.addingTimeInterval(200 * day)
    let outcome = try await IngestPipeline(store: store, now: later).run(objects: [object])
    #expect(try await currentStatus(store) == "dormant")
    #expect(outcome.contradictionsOpen == 0)
}

// The bug: `pushed_at` cannot tell a README edit from work. WoWBud's gap ran June 2025 to October
// 2026 and a README ended it, and four repositories woke up that way.
@Test("a docs-only push does not wake a dormant repository")
func readmeCommitIsNotARevival() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let lastWork = now.addingTimeInterval(-400 * day)
    let readme = now.addingTimeInterval(-2 * day)
    let objects = [
        repository(pushed: readme, created: lastWork.addingTimeInterval(-100 * day)),
        commit("Add the real feature", at: lastWork),
        commit("README: say what this is", at: readme),
    ]
    _ = try await IngestPipeline(store: store, now: now).run(objects: objects)
    #expect(try await currentStatus(store) == "dormant")
}

@Test("real work after a long gap does wake a repository")
func realCommitIsARevival() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let lastWork = now.addingTimeInterval(-400 * day)
    let revived = now.addingTimeInterval(-2 * day)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-100 * day)).run(objects: [
        repository(pushed: lastWork, created: lastWork.addingTimeInterval(-100 * day)),
        commit("Add the real feature", at: lastWork),
    ])
    #expect(try await currentStatus(store) == "dormant")
    _ = try await IngestPipeline(store: store, now: now).run(objects: [
        repository(pushed: revived, created: lastWork.addingTimeInterval(-100 * day)),
        commit("Start the new engine", at: revived),
    ])
    #expect(try await currentStatus(store) == "active")
}

@Test("commit titles sort into upkeep and work")
func commitNature() {
    #expect(CommitNature.isUpkeep(title: "README: match the code"))
    #expect(CommitNature.isUpkeep(title: "docs: the handoff"))
    #expect(CommitNature.isUpkeep(title: "Add a README describing what the code does"))
    #expect(CommitNature.isUpkeep(title: "[ci skip] Handoff: the Atlas is pushed"))
    #expect(CommitNature.isUpkeep(title: "Add the feature", author: "github-actions[bot]"))
    #expect(!CommitNature.isUpkeep(title: "Add network resilience to AssetManager"))
    #expect(!CommitNature.isUpkeep(title: "fix(Retrieval): pass one bm25 weight per column"))
}

// The bug: `validFrom` was the repository's creation date, so a language change always tied with
// its predecessor and stayed open forever. Both unresolved contradictions on the real store.
@Test("a repository whose language changed resolves by the push that changed it")
func languageChangeResolves() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let created = now.addingTimeInterval(-600 * day)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-30 * day))
        .run(objects: [repository(language: "HTML", pushed: now.addingTimeInterval(-31 * day), created: created)])
    let outcome = try await IngestPipeline(store: store, now: now)
        .run(objects: [repository(language: "Swift", pushed: now.addingTimeInterval(-day), created: created)])

    #expect(outcome.contradictionsOpen == 0)
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    let belief = try #require(try await store.currentBelief(key: "\(subject.value)|\(Predicate.primaryLanguage)"))
    let swift = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .publicRecord).id
    #expect(try await store.claim(belief.claimID)?.objectEntity == swift)
}

// The bug: `reconcile` re-counts every open slot on every pass, and the alert used that count, so
// each non-empty sync fired "2 Unresolved Contradictions" under a timestamped identifier and the
// banners stacked. Each one invited a click that used to disable rebuild for good.
@Test("two syncs in a row raise a contradiction once")
func openContradictionAlertsOnce() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let now = Date()
    let at = now.addingTimeInterval(-day)
    var other = stateDocument(path: "/b/Atlas/HANDOFF.md", objective: "Second wording", at: at, authority: .authoredArtifact)
    other.title = "HANDOFF.md"
    let objects = [stateDocument(path: "/a/Atlas/STATE.md", objective: "First wording", at: at, authority: .authoredArtifact), other]

    let first = try await IngestPipeline(store: store, now: now).run(objects: objects)
    #expect(first.contradictionsOpen == 1)
    #expect(first.contradictionsNew.count == 1)
    #expect(BeliefAlerts.contradictionIdentifier(for: first.contradictionsNew) != nil)

    let second = try await IngestPipeline(store: store, now: now.addingTimeInterval(3_600)).run(objects: objects)
    #expect(second.contradictionsOpen == 1, "still open, which is what the screen must keep showing")
    #expect(second.contradictionsNew.isEmpty)
    #expect(BeliefAlerts.contradictionIdentifier(for: second.contradictionsNew) == nil)
}

@Test("a contradiction's alert identifier is stable, so a repeat replaces rather than stacks")
func alertIdentifierIsStable() {
    let a = ContradictionID("aaa"), b = ContradictionID("bbb")
    #expect(BeliefAlerts.contradictionIdentifier(for: [a, b]) == BeliefAlerts.contradictionIdentifier(for: [b, a]))
    #expect(BeliefAlerts.contradictionIdentifier(for: [a]) != BeliefAlerts.contradictionIdentifier(for: [b]))
}

@Test("a handoff rewrite is not worth a banner, and a real change of mind is")
func documentChurnDoesNotAlert() {
    #expect(!BeliefAlerts.isWorthAlerting(predicate: Predicate.objective))
    #expect(!BeliefAlerts.isWorthAlerting(predicate: Predicate.lastVerifiedCommit))
    #expect(!BeliefAlerts.isWorthAlerting(predicate: Predicate.nextAction))
    #expect(BeliefAlerts.isWorthAlerting(predicate: Predicate.status))
    #expect(BeliefAlerts.isWorthAlerting(predicate: Predicate.primaryLanguage))
}

// A row stays forever and only its resolution changes, so a slot that resolved through a new pair
// of claims used to leave its old pair open for good.
@Test("settling a slot closes the old open contradiction on it")
func settledSlotClosesOldContradiction() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let now = Date()
    let at = now.addingTimeInterval(-3 * day)
    var other = stateDocument(path: "/b/Atlas/HANDOFF.md", objective: "Second wording", at: at, authority: .authoredArtifact)
    other.title = "HANDOFF.md"
    let state = stateDocument(path: "/a/Atlas/STATE.md", objective: "First wording", at: at, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-day)).run(objects: [state, other])
    #expect(try await store.contradictions(unresolvedOnly: true).count == 1)

    let updated = stateDocument(path: "/a/Atlas/STATE.md", objective: "A third thing altogether", at: now, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store, now: now).run(objects: [updated])
    #expect(try await store.contradictions(unresolvedOnly: true).isEmpty)
}

// MARK: - The real slot

private func openCoreState(path: String, objective: String, next: String, at date: Date, authority: Authority) -> CoreObject {
    CoreObject(
        sourceID: files.id, kind: .file, externalID: path, title: "STATE.md",
        text: "# State\n\nProject: Atlas\nObjective: \(objective)\nLast verified commit: abc1234\nNext action: \(next)\n", authoredAt: date,
        domain: .project, authority: authority, metadata: ["root": "/tmp", "extension": "md", "relative_path": "Atlas/STATE.md"]
    )
}

private func allObjectives(_ store: Store) async throws -> [CoreClaim] {
    try await store.allClaims(currentOnly: false, limit: .max).filter { $0.predicate == Predicate.objective }
}

// The shape of OpenCore's own `objective` slot on 2026-10-30, sync by sync. One sentence arrived at
// authority 4 through a `/private/tmp` copy and at 2 through the real file. The real file then moved
// on twice. Adjudication asked about authority first, so the old sentence stayed the belief, both
// newer values were retracted, and the store held "authored artifact outranks generated summary"
// about a file disagreeing with its own earlier self. Six of 14 contradictions were this shape.
@Test("the real objective slot follows its file, and a sync with nothing new changes nothing")
func openCoreObjectiveSlot() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-30 * day)
    let real = "/repo/Atlas/Docs/ai/STATE.md"

    let copy = openCoreState(path: "/private/tmp/workspace/Atlas/Docs/ai/STATE.md", objective: "Measure retrieval", next: "Sync the docs", at: start, authority: .authoredArtifact)
    let first = openCoreState(path: real, objective: "Measure retrieval", next: "Sync the docs", at: start, authority: .generatedSummary)
    _ = try await IngestPipeline(store: store, now: start.addingTimeInterval(day)).run(objects: [copy, first])
    #expect(try await currentObjective(store) == "Measure retrieval")

    let second = openCoreState(path: real, objective: "Deliver the monitor controls", next: "Repair the layout", at: start.addingTimeInterval(2 * day), authority: .generatedSummary)
    _ = try await IngestPipeline(store: store, now: start.addingTimeInterval(3 * day)).run(objects: [second])
    #expect(try await currentObjective(store) == "Deliver the monitor controls")

    let third = openCoreState(path: real, objective: "Finish the warning destinations", next: "Nothing is left", at: start.addingTimeInterval(4 * day), authority: .generatedSummary)
    let settled = try await IngestPipeline(store: store, now: start.addingTimeInterval(5 * day)).run(objects: [third])
    #expect(try await currentObjective(store) == "Finish the warning destinations")
    #expect(settled.contradictions == 0)
    #expect(settled.contradictionsNew.isEmpty)
    #expect(try await store.contradictions().isEmpty, "a file changing its mind is not two sources disagreeing")

    // Retired, never deleted, and each older sentence says what replaced it.
    let objectives = try await allObjectives(store)
    let current = objectives.filter(\.validity.isCurrent)
    #expect(Set(current.compactMap(\.literal)) == ["Finish the warning destinations"])
    #expect(Set(objectives.compactMap(\.literal)).count == 3)
    for retired in objectives where !retired.validity.isCurrent {
        #expect(try await !store.evidence(for: retired.id, stance: .refutes).isEmpty, "counter-evidence is a row, never an absence")
    }

    // The history is the three values in order, each read as a change of mind.
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    let history = try await store.beliefHistory(key: "\(subject.value)|\(Predicate.objective)")
    #expect(history.map(\.version) == Array(1...history.count))
    #expect(history.count == 3)
    #expect(history.last?.reason.contains("changed from") == true)

    // Two more syncs of the same files: no belief, no row, nothing to alert on.
    for hours in [1.0, 2.0] {
        let repeated = try await IngestPipeline(store: store, now: start.addingTimeInterval(5 * day + hours * 3_600)).run(objects: [copy, third])
        #expect(repeated.beliefs == 0)
        #expect(repeated.contradictions == 0)
        #expect(repeated.contradictionsNew.isEmpty)
        #expect(BeliefAlerts.contradictionIdentifier(for: repeated.contradictionsNew) == nil)
    }
}

// The bug: `next_action` was undated and outside `Predicate.functional`, so nothing could ever replace
// one. OpenCore held three live next actions, all from one file, and answers offered all of them.
@Test("a next action is replaced by the next revision, so a project has one")
func nextActionHasOneCurrentValue() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-10 * day)
    let path = "/repo/Atlas/STATE.md"
    _ = try await IngestPipeline(store: store, now: start).run(objects: [openCoreState(path: path, objective: "Same", next: "Do the first thing", at: start, authority: .generatedSummary)])
    let later = start.addingTimeInterval(day)
    let outcome = try await IngestPipeline(store: store, now: later).run(objects: [openCoreState(path: path, objective: "Same", next: "Do the second thing", at: later, authority: .generatedSummary)])

    let live = try await store.allClaims(currentOnly: true, limit: .max).filter { $0.predicate == Predicate.nextAction }
    #expect(live.compactMap(\.literal) == ["Do the second thing"])
    #expect(live.first?.validity.validFrom != nil, "time orders revisions, so an undated one cannot be ordered")
    #expect(outcome.documentSuccessions == 1)
    #expect(try await store.contradictions().isEmpty)

    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    #expect(try await store.currentBelief(key: "\(subject.value)|\(Predicate.nextAction)") != nil, "functional predicates are the ones that get a belief")
}

// Guards the widening: `next_action` joined a set whose rule is that only its members contradict.
@Test("the functional set still excludes what is genuinely multi-valued")
func functionalStaysNarrow() {
    #expect(Predicate.documentRestated.isSubset(of: Predicate.functional))
    for predicate in [Predicate.builtWith, Predicate.metWith, Predicate.attended, Predicate.verifyCommand, Predicate.hasComponent] {
        #expect(!Predicate.functional.contains(predicate))
    }
}

// Same-document succession retired a claim as soon as one of its files moved on. The value can reach
// a slot from two documents, and the one that has not changed still says it.
@Test("a value stays while another document still states it")
func aValueSurvivesWhileAnotherDocumentStatesIt() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-10 * day)
    var handoff = stateDocument(path: "/repo/Atlas/HANDOFF.md", objective: "Shared sentence", at: start, authority: .authoredArtifact)
    handoff.title = "HANDOFF.md"
    let state = stateDocument(path: "/repo/Atlas/STATE.md", objective: "Shared sentence", at: start, authority: .authoredArtifact)
    _ = try await IngestPipeline(store: store, now: start).run(objects: [handoff, state])

    let moved = stateDocument(path: "/repo/Atlas/STATE.md", objective: "New sentence", at: start.addingTimeInterval(day), authority: .authoredArtifact)
    let outcome = try await IngestPipeline(store: store, now: start.addingTimeInterval(2 * day)).run(objects: [moved])

    #expect(outcome.documentSuccessions == 0, "HANDOFF.md has not changed its mind")
    #expect(outcome.contradictions == 1, "two documents now disagree, which is a contradiction")
}

// The count check inside the same rule. A second document that cannot say which way it went has not
// moved on, and treating its silence as agreement retires a value it may still state.
@Test("a value stays while its other document is tied and cannot say")
func aValueSurvivesATiedDocument() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-10 * day)
    func handoff(_ path: String, _ objective: String) -> CoreObject {
        var object = stateDocument(path: path, objective: objective, at: start, authority: .authoredArtifact)
        object.title = "HANDOFF.md"
        return object
    }
    _ = try await IngestPipeline(store: store, now: start).run(objects: [
        stateDocument(path: "/repo/Atlas/STATE.md", objective: "Shared sentence", at: start, authority: .authoredArtifact),
        handoff("/x/Atlas/HANDOFF.md", "Shared sentence"),
        handoff("/y/Atlas/HANDOFF.md", "Rival sentence"),
    ])

    let moved = stateDocument(path: "/repo/Atlas/STATE.md", objective: "New sentence", at: start.addingTimeInterval(day), authority: .authoredArtifact)
    let outcome = try await IngestPipeline(store: store, now: start.addingTimeInterval(2 * day)).run(objects: [moved])
    #expect(outcome.documentSuccessions == 0)
}

// Found reviewing the revision rule itself, which runs before anything compares authority. A proposal
// is evidence-linked to the file it read, so a newer revision with no objective line of its own let a
// model's guess retire a sentence a person wrote, through the one door that ignores tiers.
@Test("a model's reading of a newer revision retires nothing a person wrote")
func modelProposalCannotUseTheRevisionPath() async throws {
    let store = try await temporaryStore()
    let atlas = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)
    try await store.upsert([atlas])
    try await store.upsert(files)
    let now = Date()
    let older = stateDocument(path: "/a/Atlas/STATE.md", objective: "What a person wrote", at: now.addingTimeInterval(-5 * day), authority: .authoredArtifact)
    let newer = stateDocument(path: "/b/Atlas/STATE.md", objective: "unused", at: now.addingTimeInterval(-day), authority: .authoredArtifact)
    try await store.ingest([older, newer])

    let written = objectiveClaim("What a person wrote", at: now.addingTimeInterval(-5 * day), authority: .authoredArtifact)
    let proposed = objectiveClaim("What a model thinks", at: now.addingTimeInterval(-day), authority: .modelInference, derivation: .inferred)
    let writtenEvidence = Evidence(objectID: older.id, snippet: "written", authority: .authoredArtifact)
    let proposedEvidence = Evidence(objectID: newer.id, snippet: "proposed", authority: .modelInference)
    try await store.save([writtenEvidence, proposedEvidence])
    try await store.save([written, proposed])
    try await store.link(claim: written.id, to: writtenEvidence.id, stance: .supports)
    try await store.link(claim: proposed.id, to: proposedEvidence.id, stance: .supports)

    let outcome = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(outcome.documentSuccessions == 0)
    #expect(try await store.claim(written.id)?.validity.isCurrent == true)
    #expect(try await store.claim(proposed.id)?.validity.isCurrent == false)
}

// MARK: - Authority against recency

private func objectiveClaim(_ value: String, at date: Date, authority: Authority, derivation: Derivation = .observed) -> CoreClaim {
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    return CoreClaim(subject: subject, predicate: Predicate.objective, literal: value, confidence: 0.9, authority: authority, derivation: derivation, validity: Validity(validFrom: date, observedAt: date), domain: .project)
}

private func storeWithAtlas() async throws -> Store {
    let store = try await temporaryStore()
    try await store.upsert([CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)])
    return store
}

// The bug's other half. Same-document succession cannot help when the disagreeing files have two
// names, so a `HANDOFF.md` under a higher tier froze a newer `STATE.md` exactly as before.
@Test("between two documents the newer statement of a plan wins, whatever root each came from")
func planStatementsCompareByTimeAcrossTiers() async throws {
    let store = try await storeWithAtlas()
    let now = Date()
    let older = objectiveClaim("Old plan", at: now.addingTimeInterval(-5 * day), authority: .authoredArtifact)
    let newer = objectiveClaim("New plan", at: now.addingTimeInterval(-day), authority: .generatedSummary)
    try await store.save([older, newer])

    let outcome = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(outcome.resolved == 1)
    #expect(try await store.claim(older.id)?.validity.isCurrent == false)
    #expect(try await store.claim(newer.id)?.validity.isCurrent == true)
    #expect(try await store.contradictions().first?.resolution == .supersededByRecency)
}

// Time now outranks tier here, so the newest row can be a lower tier than the one the belief rests
// on. Comparing raw authority would call that a change: one sentence, re-saved in the real file, read
// "re-asserted at generated summary (was authored artifact)" in a history of changes of mind.
@Test("the same sentence re-read at another tier is not a change of mind")
func sameSentenceAtAnotherTierIsNotAVersion() async throws {
    let store = try await storeWithAtlas()
    let now = Date()
    try await store.save([objectiveClaim("One plan", at: now.addingTimeInterval(-5 * day), authority: .authoredArtifact)])
    _ = try await BeliefEngine(store: store, now: now.addingTimeInterval(-4 * day)).reconcile()

    let resaved = objectiveClaim("One plan", at: now.addingTimeInterval(-day), authority: .generatedSummary)
    try await store.save([resaved])
    _ = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(try await store.beliefHistory(key: resaved.claimKey).count == 1)
}

// The guard that keeps the fix above from becoming the opposite failure: models propose and cannot
// overrule, so recency must never carry a proposal over something a person wrote.
@Test("a newer model proposal cannot displace a statement a person wrote, and the reason admits it is newer")
func modelProposalNeverWinsOnRecency() async throws {
    let store = try await storeWithAtlas()
    let now = Date()
    let written = objectiveClaim("What the file says", at: now.addingTimeInterval(-5 * day), authority: .generatedSummary)
    let proposed = objectiveClaim("What a model thinks", at: now.addingTimeInterval(-day), authority: .modelInference, derivation: .inferred)
    try await store.save([written, proposed])

    _ = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(try await store.claim(written.id)?.validity.isCurrent == true)
    #expect(try await store.claim(proposed.id)?.validity.isCurrent == false)
    let row = try #require(try await store.contradictions().first)
    #expect(row.resolution == .supersededByAuthority)
    #expect(row.reason.contains("although the other claim is newer"))
}

// The screen said "outranks" and never said what had been overridden, so an old claim beating a newer
// one read as a finding. A correction must still win, and the reason must say what it beat.
@Test("a correction outlasts a newer document, and the reason says so")
func correctionOutlastsNewerDocument() async throws {
    let store = try await storeWithAtlas()
    let now = Date()
    let corrected = objectiveClaim("What the owner said", at: now.addingTimeInterval(-5 * day), authority: .directStatement, derivation: .corrected)
    let document = objectiveClaim("What a file says later", at: now.addingTimeInterval(-day), authority: .authoredArtifact)
    try await store.save([corrected, document])

    _ = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(try await store.claim(corrected.id)?.validity.isCurrent == true)
    let row = try #require(try await store.contradictions().first)
    #expect(row.reason.contains("newer"))
}

@Test("authority beating an older claim stays a plain statement")
func authorityWithoutOverrideSaysNothingExtra() async throws {
    let store = try await temporaryStore()
    let atlas = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)
    try await store.upsert([atlas])
    let now = Date()
    func status(_ value: String, _ age: TimeInterval, _ authority: Authority) -> CoreClaim {
        let at = now.addingTimeInterval(-age * day)
        return CoreClaim(subject: atlas.id, predicate: Predicate.status, literal: value, confidence: 0.9, authority: authority, derivation: .observed, validity: Validity(validFrom: at, observedAt: at), domain: .project)
    }
    try await store.save([status("archived", 1, .authoredArtifact), status("active", 5, .derivedPattern)])
    _ = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(try await store.contradictions().first?.reason.contains("newer") == false)
}

// MARK: - One record rewriting itself

private func archivedRepository(pushed: Date, created: Date) -> CoreObject {
    var object = repository(pushed: pushed, created: created)
    object.metadata["archived"] = "true"
    return object
}

// The objective's freeze, on another predicate: `archived` is observed at authority 4 and `active` is
// inferred at 1, so a repository brought back from the archive stayed archived for good. The record
// itself had said otherwise, and authority let its old reading outrank its new one.
@Test("a repository brought back from the archive stops reading archived")
func unarchivedRepositoryRecovers() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let created = now.addingTimeInterval(-500 * day)
    let archivedAt = now.addingTimeInterval(-30 * day)
    _ = try await IngestPipeline(store: store, now: archivedAt).run(objects: [archivedRepository(pushed: archivedAt, created: created)])
    #expect(try await currentStatus(store) == "archived")

    let revived = now.addingTimeInterval(-day)
    let outcome = try await IngestPipeline(store: store, now: now).run(objects: [repository(pushed: revived, created: created)])
    #expect(try await currentStatus(store) == "active")
    #expect(outcome.contradictionsOpen == 0)
    let row = try #require(try await store.contradictions().first)
    #expect(row.kind == .temporalSupersession, "a repository changing state keeps its row, unlike a handoff")
}

// The bug: GitHub recomputes a language after a push, so two readings could share `pushed_at`, and a
// shared date tied forever. The push-date fix alone leaves this open. The real rows looked like this.
@Test("two language readings with one date resolve by which was read later")
func sameDatedLanguageReadingsResolveByObservation() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let created = now.addingTimeInterval(-600 * day)
    let pushed = now.addingTimeInterval(-31 * day)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-30 * day)).run(objects: [repository(language: "Python", pushed: pushed, created: created)])
    let outcome = try await IngestPipeline(store: store, now: now).run(objects: [repository(language: "HTML", pushed: pushed, created: created)])

    #expect(outcome.contradictionsOpen == 0)
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    let belief = try #require(try await store.currentBelief(key: "\(subject.value)|\(Predicate.primaryLanguage)"))
    let html = CoreEntity(kind: .technology, canonicalName: "HTML", domain: .publicRecord).id
    #expect(try await store.claim(belief.claimID)?.objectEntity == html)
}

// Every push mints a new claim for an unchanged language, so one change retires several rows. The
// first version of the revision rule wrote a row per retired claim, and a rehearsal on the real store
// showed four rows for two language changes.
@Test("a language that changed once is one row, however many readings said the old value")
func oneChangeIsOneRow() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let created = now.addingTimeInterval(-600 * day)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-30 * day)).run(objects: [repository(language: "Python", pushed: now.addingTimeInterval(-31 * day), created: created)])
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-20 * day)).run(objects: [repository(language: "Python", pushed: now.addingTimeInterval(-21 * day), created: created)])
    _ = try await IngestPipeline(store: store, now: now).run(objects: [repository(language: "HTML", pushed: now.addingTimeInterval(-day), created: created)])

    let languages = try await store.allClaims(currentOnly: false, limit: .max).filter { $0.predicate == Predicate.primaryLanguage }
    #expect(languages.count == 3, "the fixture must hold both old readings or this proves nothing")
    #expect(languages.filter(\.validity.isCurrent).count == 1)
    #expect(try await store.contradictions().count == 1)
    // The row is per change, so the readings past the first have only this. It used to be nothing:
    // the shared row was skipped and `valuesWithRow` skipped the contradiction.
    for retired in languages where !retired.validity.isCurrent {
        #expect(try await !store.evidence(for: retired.id, stance: .refutes).isEmpty, "counter-evidence is a row, never an absence")
        #expect(try await !store.evidence(for: retired.id, stance: .supports).isEmpty)
    }
}

// The bug: a repository record's evidence has no byte range, so every reading shares one evidence
// row, and `claim_evidence` holds one stance per pair. Writing `.refutes` overwrote the claim's own
// `.supports`. On the real store 14 claims had no support left, 9 of them current, each citing its
// own evidence as refuting it, and an answer drops a claim with no support.
@Test("a claim keeps its own support when its rival was read from the same record")
func sharedEvidenceIsNotTurnedAgainstItsOwnClaim() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let pushed = Date().addingTimeInterval(-300 * day)
    let object = repository(pushed: pushed, created: pushed.addingTimeInterval(-500 * day))
    _ = try await IngestPipeline(store: store, now: pushed.addingTimeInterval(day)).run(objects: [object])
    _ = try await IngestPipeline(store: store, now: pushed.addingTimeInterval(200 * day)).run(objects: [object])

    let statuses = try await store.allClaims(currentOnly: false, limit: .max).filter { $0.predicate == Predicate.status }
    #expect(statuses.count == 2, "the fixture must hold both readings or this proves nothing")
    for claim in statuses {
        let support = try await store.evidence(for: claim.id, stance: .supports)
        let counter = try await store.evidence(for: claim.id, stance: .refutes)
        #expect(!support.isEmpty)
        // The retired reading records why on a row of its own, and its own row stays support.
        #expect(counter.isEmpty == claim.validity.isCurrent)
        #expect(Set(support.map(\.0.id)).isDisjoint(with: counter.map(\.0.id)))
    }
}

// The same overwrite through ordinary adjudication, which has its own call site.
@Test("a claim keeps its support when two sources tie on one piece of evidence")
func sharedEvidenceSurvivesAdjudication() async throws {
    let store = try await temporaryStore()
    let atlas = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project)
    try await store.upsert([atlas])
    try await store.upsert(github)
    let at = Date().addingTimeInterval(-day)
    let object = repository(pushed: at, created: at.addingTimeInterval(-day))
    try await store.ingest([object])
    let evidence = Evidence(objectID: object.id, snippet: "shared", authority: .authoredArtifact)
    try await store.save([evidence])
    func status(_ value: String) -> CoreClaim {
        CoreClaim(subject: atlas.id, predicate: Predicate.status, literal: value, confidence: 0.9, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: at, observedAt: at), domain: .project)
    }
    let claims = [status("active"), status("dormant")]
    try await store.save(claims)
    for claim in claims { try await store.link(claim: claim.id, to: evidence.id, stance: .supports) }

    _ = try await BeliefEngine(store: store, now: Date()).reconcile()
    for claim in claims { #expect(try await !store.evidence(for: claim.id, stance: .supports).isEmpty) }
}

// MARK: - What counts as new

// The bug: "new" was keyed on the row, and a claim id includes its date, so re-saving two tied files
// minted a new pair and raised an alert for an argument the store had already reported.
@Test("the same two values re-dated are not a new contradiction")
func reDatedDisagreementDoesNotAlertAgain() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-10 * day)
    func pair(_ at: Date) -> [CoreObject] {
        var other = stateDocument(path: "/b/Atlas/HANDOFF.md", objective: "Second wording", at: at, authority: .authoredArtifact)
        other.title = "HANDOFF.md"
        return [stateDocument(path: "/a/Atlas/STATE.md", objective: "First wording", at: at, authority: .authoredArtifact), other]
    }
    let first = try await IngestPipeline(store: store, now: start).run(objects: pair(start))
    #expect(first.contradictionsNew.count == 1)

    let touched = start.addingTimeInterval(day)
    let second = try await IngestPipeline(store: store, now: touched).run(objects: pair(touched))
    #expect(second.contradictionsOpen == 1)
    #expect(second.contradictionsNew.isEmpty, "the same two sentences, newly dated, are the same argument")
}

// MARK: - A record read in order

private func statusRows(_ store: Store) async throws -> [CoreClaim] {
    try await store.allClaims(currentOnly: false, limit: .max).filter { $0.predicate == Predicate.status }
}

// The bug: within a record, order was world time. `dormant` is dated by a threshold and `archived` by
// the last push, so a repository archived after going quiet read `dormant` as newest, the record's
// observed `archived` was retired by its own inferred status, and nothing could undo it: an archived
// repository can't be pushed to, so its claim id never changes. The row read "observed <threshold>",
// which nothing observed. Archiving with `pushed_at` unchanged is the assumption here, and the
// connector records no archive date, so this holds whichever way GitHub goes.
@Test("a repository archived after going quiet reads archived, with its push date unchanged")
func archivedAfterGoingQuiet() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let pushed = Date().addingTimeInterval(-300 * day)
    let created = pushed.addingTimeInterval(-500 * day)
    _ = try await IngestPipeline(store: store, now: pushed.addingTimeInterval(200 * day)).run(objects: [repository(pushed: pushed, created: created)])
    #expect(try await currentStatus(store) == "dormant")

    let read = pushed.addingTimeInterval(210 * day)
    let outcome = try await IngestPipeline(store: store, now: read).run(objects: [archivedRepository(pushed: pushed, created: created)])
    #expect(try await currentStatus(store) == "archived")
    #expect(outcome.contradictionsOpen == 0)

    let row = try #require(try await store.contradictions().first)
    #expect(row.kind == .temporalSupersession)
    let threshold = String(stamp(pushed.addingTimeInterval(180 * day)).prefix(10))
    #expect(!row.reason.contains(threshold), "a threshold is not an observation")
    #expect(row.reason.contains(String(stamp(read).prefix(10))))
}

// The same root the other way round. `active` is dated by the last real work, and `archived` by a
// push that can be later upkeep, so restoring a repository with no new push read as older than the
// archive, and it froze until the next real commit.
@Test("a repository restored with no new push stops reading archived")
func unarchivedWithNoNewPush() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let work = now.addingTimeInterval(-40 * day)
    let upkeep = now.addingTimeInterval(-30 * day)
    let created = work.addingTimeInterval(-100 * day)
    let commits = [commit("Add the real feature", at: work), commit("README: say what this is", at: upkeep)]
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-20 * day)).run(objects: [archivedRepository(pushed: upkeep, created: created)] + commits)
    #expect(try await currentStatus(store) == "archived")

    _ = try await IngestPipeline(store: store, now: now).run(objects: [repository(pushed: upkeep, created: created)] + commits)
    #expect(try await currentStatus(store) == "active")
}

// The bug: a value that came back reproduced its old id, and a retracted claim stays retracted, so
// the extension of `sameDatedLanguageReadingsResolveByObservation` to a third read left the stale
// HTML current while the record said Python.
@Test("a language that flips back at one push date follows the record, and stays one row")
func sameDatedLanguageFlipsBack() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let created = now.addingTimeInterval(-600 * day)
    let pushed = now.addingTimeInterval(-31 * day)
    let subject = CoreEntity(kind: .project, canonicalName: "Atlas", domain: .project).id
    let python = CoreEntity(kind: .technology, canonicalName: "Python", domain: .publicRecord).id
    for (age, language) in [(30.0, "Python"), (20.0, "HTML"), (10.0, "Python")] {
        _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-age * day)).run(objects: [repository(language: language, pushed: pushed, created: created)])
    }
    let belief = try #require(try await store.currentBelief(key: "\(subject.value)|\(Predicate.primaryLanguage)"))
    #expect(try await store.claim(belief.claimID)?.objectEntity == python)

    let languages = { try await store.allClaims(currentOnly: false, limit: .max).filter { $0.predicate == Predicate.primaryLanguage } }
    let settled = try await languages().count
    #expect(try await languages().filter(\.validity.isCurrent).count == 1)
    let repeated = try await IngestPipeline(store: store, now: now).run(objects: [repository(language: "Python", pushed: pushed, created: created)])
    #expect(try await languages().count == settled, "the record saying the same thing again is no new reading")
    #expect(repeated.contradictions == 0)
}

@Test("archived, restored and archived again with no push ends archived")
func archiveFlipBack() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let pushed = now.addingTimeInterval(-100 * day)
    let created = pushed.addingTimeInterval(-100 * day)
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-30 * day)).run(objects: [archivedRepository(pushed: pushed, created: created)])
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-20 * day)).run(objects: [repository(pushed: pushed, created: created)])
    #expect(try await currentStatus(store) == "active")
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-10 * day)).run(objects: [archivedRepository(pushed: pushed, created: created)])
    #expect(try await currentStatus(store) == "archived")
    #expect(try await statusRows(store).filter(\.validity.isCurrent).count == 1)

    // Past checkouts read `retracted_at`, so the first `archived` stays retired and a new row speaks.
    #expect(try await statusRows(store).filter { $0.literal == "archived" && !$0.validity.isCurrent }.count == 1)
}

// The guard on the flip above. Without it a status that a document outranks is "new" on every sync:
// retired by adjudication, minted again by the next read, retired again.
@Test("a status a document outranks is not read again on every sync")
func outrankedStatusIsNotRemintedPerSync() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    try await store.upsert(files)
    let now = Date()
    let pushed = now.addingTimeInterval(-10 * day)
    let object = repository(pushed: pushed, created: pushed.addingTimeInterval(-100 * day))
    let readme = CoreObject(
        sourceID: files.id, kind: .file, externalID: "/repo/Atlas/STATE.md", title: "STATE.md",
        text: "# State\n\nProject: Atlas\nStatus: archived\n", authoredAt: now.addingTimeInterval(-20 * day),
        domain: .project, authority: .authoredArtifact, metadata: ["root": "/tmp", "extension": "md", "relative_path": "Atlas/STATE.md"]
    )
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-3 * day)).run(objects: [object, readme])
    #expect(try await currentStatus(store) == "archived")
    let settled = try await statusRows(store).count

    for age in [2.0, 1.0] {
        let again = try await IngestPipeline(store: store, now: now.addingTimeInterval(-age * day)).run(objects: [object, readme])
        #expect(again.contradictions == 0)
    }
    #expect(try await statusRows(store).count == settled)
    #expect(try await currentStatus(store) == "archived")
}

// `reading` reuses or re-dates a value, and neither may undo a person. `retract` must keep holding.
@Test("a corrected status holds while the record repeats what was corrected")
func correctionHoldsAgainstRepeatedReading() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let pushed = now.addingTimeInterval(-10 * day)
    let object = repository(pushed: pushed, created: pushed.addingTimeInterval(-100 * day))
    _ = try await IngestPipeline(store: store, now: now.addingTimeInterval(-5 * day)).run(objects: [object])
    let wrong = try #require(try await statusRows(store).first)
    let asserted = CoreClaim(subject: wrong.subject, predicate: Predicate.status, literal: "archived", confidence: 1, authority: .directStatement, derivation: .corrected, validity: Validity(validFrom: now.addingTimeInterval(-4 * day), observedAt: now.addingTimeInterval(-4 * day)), domain: .project)
    try await BeliefEngine(store: store, now: now.addingTimeInterval(-4 * day)).correct(supersedingClaim: wrong.id, with: asserted, reason: "the owner said so", priorFailure: nil)

    _ = try await IngestPipeline(store: store, now: now).run(objects: [object])
    #expect(try await currentStatus(store) == "archived")
    #expect(try await store.claim(wrong.id)?.validity.isCurrent == false)
}

// The bug: `commits` keeps the newest 200, so "the oldest stored commit" was the 200th newest and real
// work past position 200 was invisible. A bot at 1.1 commits a day read `active` for good, and its
// fallback date moved with each commit, so each sync minted a status row. This is the case
// `CommitNature` exists to stop.
@Test("more than 200 upkeep commits do not hide the real work behind them")
func upkeepBeyondTheCommitLimit() async throws {
    let store = try await temporaryStore()
    try await store.upsert(github)
    let now = Date()
    let work = now.addingTimeInterval(-400 * day)
    let upkeep = (0..<201).map { commit("README: update \($0)", at: now.addingTimeInterval(-Double($0 + 1) * 4_000)) }
    let objects = [repository(pushed: now.addingTimeInterval(-3_600), created: work.addingTimeInterval(-100 * day)), commit("Add the real feature", at: work)] + upkeep
    _ = try await IngestPipeline(store: store, now: now).run(objects: objects)
    #expect(try await currentStatus(store) == "dormant")
}

// MARK: - What a revision records

// The bug: counter-evidence ran both ways on a revision, so the current objective carried each older
// sentence of its own file as `.refutes`. An answer and its receipt showed that as evidence against
// the current line, it grew by one per rewrite, and no contradiction row explained it. The slot test
// above asserts `.refutes` only on retired claims, so it passed either way.
@Test("a rewritten document's current claim is not refuted by its own earlier revisions")
func revisionsDoNotArgueAgainstTheCurrentClaim() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-10 * day)
    let path = "/repo/Atlas/STATE.md"
    for (offset, objective) in ["The first sentence", "A rather longer second sentence", "The third"].enumerated() {
        let at = start.addingTimeInterval(Double(offset) * day)
        _ = try await IngestPipeline(store: store, now: at).run(objects: [stateDocument(path: path, objective: objective, at: at, authority: .authoredArtifact)])
    }
    let objectives = try await allObjectives(store)
    let current = try #require(objectives.first { $0.validity.isCurrent })
    #expect(current.literal == "The third")
    #expect(try await store.evidence(for: current.id, stance: .refutes).isEmpty)
    for retired in objectives where !retired.validity.isCurrent {
        #expect(try await !store.evidence(for: retired.id, stance: .refutes).isEmpty)
    }
}

// The bug: an evidence id is its object and byte range, so a value of the same length at the same
// offset reached the old row. The snippet was overwritten, the old claim cited the new sentence, and
// the shared-row skip left the retired claim with nothing recorded against it. A fixed-length
// `Last verified commit` hash does this every time. The fixtures above all change the length.
@Test("a same-length rewrite keeps each claim's own citation and records why the old one retired")
func sameLengthRevisionKeepsItsOwnEvidence() async throws {
    let store = try await temporaryStore()
    try await store.upsert(files)
    let start = Date().addingTimeInterval(-10 * day)
    let path = "/repo/Atlas/STATE.md"
    _ = try await IngestPipeline(store: store, now: start).run(objects: [stateDocument(path: path, objective: "Sentence one", at: start, authority: .authoredArtifact)])
    let later = start.addingTimeInterval(day)
    _ = try await IngestPipeline(store: store, now: later).run(objects: [stateDocument(path: path, objective: "Sentence two", at: later, authority: .authoredArtifact)])

    let objectives = try await allObjectives(store)
    #expect(objectives.count == 2)
    for claim in objectives {
        let citation = try #require(try await store.evidence(for: claim.id, stance: .supports).first)
        #expect(citation.0.snippet.contains(try #require(claim.literal)), "a claim must not cite the sentence that replaced it")
        #expect(try await !store.evidence(for: claim.id, stance: .refutes).isEmpty == !claim.validity.isCurrent)
    }
}

// MARK: - Ties and tiers

// The bug: with three values tied on rank, `representatives` came from `Dictionary.values` and `max`
// had no total order, so the winner varied by process. `disagreement` pairs only winner and loser, so
// a later process could record B-C after A-B and A-C: a new open row and a new alert on a store where
// nothing changed. Twenty slots, because hash order differs per key, so one lucky slot proves nothing.
@Test("three tied values name the same winner every time")
func threeWayTieIsDeterministic() async throws {
    let store = try await temporaryStore()
    let now = Date()
    let at = now.addingTimeInterval(-day)
    var claims: [CoreClaim] = []
    for index in 0..<20 {
        let subject = CoreEntity(kind: .project, canonicalName: "Atlas\(index)", domain: .project)
        try await store.upsert([subject])
        for value in ["Alpha plan \(index)", "Bravo plan \(index)", "Charlie plan \(index)"] {
            claims.append(CoreClaim(subject: subject.id, predicate: Predicate.objective, literal: value, confidence: 0.9, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: at, observedAt: at), domain: .project))
        }
    }
    try await store.save(claims)

    let first = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(first.newlyOpened.count == 40)
    for row in try await store.contradictions() {
        #expect(try await store.claim(row.claimA)?.literal?.hasPrefix("Charlie") == true)
    }
    let second = try await BeliefEngine(store: store, now: now.addingTimeInterval(60)).reconcile()
    #expect(second.newlyOpened.isEmpty)
}

// `standing` put these two at 0 for plan predicates, so a newer model proposal beat a derived claim
// on time. ClaimExtractor's gate says a proposal is outranked by every deterministic rule.
@Test("a newer model proposal cannot displace a derived plan either")
func modelProposalCannotDisplaceDerivedPattern() async throws {
    let store = try await storeWithAtlas()
    let now = Date()
    let derived = objectiveClaim("What a rule found", at: now.addingTimeInterval(-5 * day), authority: .derivedPattern, derivation: .inferred)
    let proposed = objectiveClaim("What a model thinks", at: now.addingTimeInterval(-day), authority: .modelInference, derivation: .inferred)
    try await store.save([derived, proposed])

    _ = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(try await store.claim(derived.id)?.validity.isCurrent == true)
    #expect(try await store.claim(proposed.id)?.validity.isCurrent == false)
}
