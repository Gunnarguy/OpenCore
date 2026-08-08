import CoreModel
import CoreSearch
import CoreStore
import Foundation
import Testing

@testable import CoreGraph

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-graph-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

private let march = Date(timeIntervalSince1970: 1_741_000_000)   // 2025-03-03
private let june = Date(timeIntervalSince1970: 1_749_900_000)    // 2025-06-14
private let now = Date(timeIntervalSince1970: 1_754_000_000)     // 2025-08-01

private func project() -> CoreEntity {
    CoreEntity(kind: .project, canonicalName: "OpenIntelligence", domain: .project)
}

private func statusClaim(_ value: String, from: Date, authority: Authority = .authoredArtifact) -> CoreClaim {
    CoreClaim(
        subject: project().id,
        predicate: Predicate.status,
        literal: value,
        confidence: 0.9,
        authority: authority,
        derivation: .observed,
        validity: Validity(validFrom: from, observedAt: from),
        domain: .project
    )
}

@Test("later evidence supersedes earlier for a functional predicate")
func temporalSupersession() async throws {
    let store = try await temporaryStore()
    try await store.upsert([project()])

    let earlier = statusClaim("prototype", from: march)
    let later = statusClaim("production", from: june)
    try await store.save([earlier, later])

    let outcome = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(outcome.contradictionsFound == 1)
    #expect(outcome.resolved == 1)

    let contradiction = try await store.contradictions().first
    #expect(contradiction?.kind == .temporalSupersession)
    #expect(contradiction?.resolution == .supersededByRecency)
    #expect(contradiction?.winner == later.id)

    // The loser is retracted, never deleted.
    let retracted = try await store.claim(earlier.id)
    #expect(retracted?.validity.isCurrent == false)
    #expect(try await store.claim(later.id)?.validity.isCurrent == true)
}

@Test("multi-valued predicates are not treated as conflicts")
func multiValuedPredicatesCoexist() async throws {
    let store = try await temporaryStore()
    try await store.upsert([project()])

    let swift = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .publicRecord)
    let python = CoreEntity(kind: .technology, canonicalName: "Python", domain: .publicRecord)
    try await store.upsert([swift, python])

    // `built_with` is not functional: both are true at once.
    for technology in [swift, python] {
        try await store.save([CoreClaim(
            subject: project().id, predicate: Predicate.builtWith, objectEntity: technology.id,
            confidence: 0.9, authority: .authoredArtifact, derivation: .observed,
            validity: Validity(validFrom: june, observedAt: june), domain: .project
        )])
    }

    let outcome = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(outcome.contradictionsFound == 0)
    #expect(try await store.claimCount() == 2)
}

@Test("equal authority with no ordering is left unresolved rather than guessed")
func ambiguityStaysUnresolved() async throws {
    let store = try await temporaryStore()
    try await store.upsert([project()])

    try await store.save([
        statusClaim("active", from: june),
        statusClaim("dormant", from: june),
    ])

    let outcome = try await BeliefEngine(store: store, now: now).reconcile()
    #expect(outcome.unresolved == 1)
    #expect(outcome.resolved == 0)

    let contradiction = try await store.contradictions(unresolvedOnly: true).first
    #expect(contradiction?.resolution == .unresolved)
    #expect(contradiction?.winner == nil)
    // Neither claim is retracted: both remain visible.
    #expect(try await store.claimCount() == 2)
}

@Test("a user correction outranks an inference and records why the old belief was reachable")
func correctionOutranksInference() async throws {
    let store = try await temporaryStore()
    let entity = project()
    try await store.upsert([entity])

    let python = CoreEntity(kind: .technology, canonicalName: "Python", domain: .publicRecord)
    let swift = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .publicRecord)
    try await store.upsert([python, swift])

    let wrong = CoreClaim(
        subject: entity.id, predicate: Predicate.primaryLanguage, objectEntity: python.id,
        confidence: 0.8, authority: .derivedPattern, derivation: .inferred,
        validity: Validity(validFrom: march, observedAt: march), domain: .project
    )
    try await store.save([wrong])
    _ = try await BeliefEngine(store: store, now: march).reconcile()

    let right = CoreClaim(
        subject: entity.id, predicate: Predicate.primaryLanguage, objectEntity: swift.id,
        confidence: 1.0, authority: .directStatement, derivation: .corrected,
        validity: Validity(validFrom: march, observedAt: now), domain: .project
    )
    try await BeliefEngine(store: store, now: now).correct(
        supersedingClaim: wrong.id,
        with: right,
        reason: "author states it is Swift",
        priorFailure: "backend documentation mentioned Python tooling; extractor read it as the project language"
    )

    let belief = try await store.currentBelief(key: right.claimKey)
    #expect(belief?.claimID == right.id)
    #expect(belief?.version == 2)
    #expect(belief?.authority == .directStatement)

    let corrections = try await store.database.query("SELECT prior_failure FROM correction")
    #expect(corrections.first?.string("prior_failure")?.contains("extractor") == true)
}

@Test("belief history is append-only and checkout reconstructs a past view")
func beliefHistoryIsAppendOnly() async throws {
    let store = try await temporaryStore()
    try await store.upsert([project()])

    try await store.save([statusClaim("prototype", from: march)])
    _ = try await BeliefEngine(store: store, now: march).reconcile()

    try await store.save([statusClaim("production", from: june)])
    _ = try await BeliefEngine(store: store, now: june).reconcile()

    let history = try await store.beliefHistory(key: "\(project().id.value)|\(Predicate.status)")
    #expect(history.count == 2)
    #expect(history[0].version == 1)
    #expect(history[1].supersedes == history[0].id)

    // What the system believed in April: the March answer, not the June one.
    let april = Date(timeIntervalSince1970: 1_744_000_000)
    let asOfApril = try await store.beliefs(asOfKnowledge: april)
    #expect(asOfApril.count == 1)
    #expect(asOfApril.first?.version == 1)

    let asOfNow = try await store.beliefs(asOfKnowledge: now)
    #expect(asOfNow.first?.version == 2)
}

private func policy(for query: String, knownEntities: Set<String> = []) -> AdmissionPolicy {
    let (domain, requested) = AdmissionPolicy.classifyDomain(query, knownEntitySurfaces: knownEntities)
    return AdmissionPolicy(queryDomain: domain, explicitlyRequested: requested)
}

/// Regression: "What is OpenClinic built with?" was classified `.medical` because the
/// keyword `clinic` matched as a substring of the project name, which blocked the entire
/// project corpus and returned "not enough evidence" for a question the store could
/// answer. Two independent guards now prevent it, and both are asserted separately so a
/// future change cannot quietly remove one and still pass.
@Test("a project whose name contains a sensitive keyword is not a sensitive query")
func entityNamesDoNotTriggerTheFirewall() throws {
    // Guard 1: whole-word matching alone fixes the OpenClinic case.
    let withoutGraph = policy(for: "What is OpenClinic built with?")
    #expect(withoutGraph.admits(.project))
    #expect(!withoutGraph.admits(.medical))

    // Guard 2: name masking fixes the case where the name *is* the bare keyword.
    let budgetRepo = policy(for: "what changed in Budget last week?", knownEntities: ["budget"])
    #expect(budgetRepo.admits(.project))
    #expect(!budgetRepo.admits(.financial))

    // And the real thing still works: an unmasked keyword in ordinary prose opens it.
    let genuine = policy(for: "what did my doctor say about the diagnosis?")
    #expect(genuine.admits(.medical))
    #expect(!genuine.admits(.project))
}

@Test("word matching does not fire on keywords embedded in longer words")
func wordBoundariesAreRespected() throws {
    #expect(AdmissionPolicy.containsWord("tax", in: "my tax bill"))
    #expect(!AdmissionPolicy.containsWord("tax", in: "a syntax error"))
    #expect(AdmissionPolicy.containsWord("clinic", in: "at the clinic"))
    #expect(!AdmissionPolicy.containsWord("clinic", in: "openclinic readme"))
    // The scan must keep going after a failed boundary check rather than giving up.
    #expect(AdmissionPolicy.containsWord("clinic", in: "openclinic and the clinic"))
}

@Test("a sensitive domain stays blocked unless the query names it")
func domainFirewallBlocksByDefault() throws {
    let projectQuery = policy(for: "how should I respond to this GitHub issue?")
    #expect(projectQuery.admits(.project))
    #expect(projectQuery.admits(.publicRecord))
    #expect(!projectQuery.admits(.medical))
    #expect(!projectQuery.admits(.financial))

    // Naming the domain is what opens it. Sounding adjacent to it is not enough.
    let medicalQuery = policy(for: "what did the lab result say about my diagnosis?")
    #expect(medicalQuery.admits(.medical))
    #expect(!medicalQuery.admits(.project))

    let financialQuery = policy(for: "how much revenue did the app make?")
    #expect(financialQuery.admits(.financial))
    #expect(!financialQuery.admits(.medical))
}

@Test("an FTS match expression neutralises operator characters in user input")
func ftsQueryIsEscaped() throws {
    let expression = HybridSearch.ftsQuery(from: "why did \"hybrid\" retrieval* change?")
    #expect(expression.contains("\"hybrid\""))
    // A bare `*` would turn into a prefix scan across the whole corpus.
    #expect(!expression.contains("*"))
    // Stopwords are dropped, so the expression is about the terms that carry meaning.
    #expect(!expression.contains("\"why\""))
}
