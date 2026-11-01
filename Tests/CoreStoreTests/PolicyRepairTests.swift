import CoreModel
import Foundation
import Testing
@testable import CoreStore

private func policyStore() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-policy-\(UUID().uuidString)/store.sqlite"))
}
private func policySource(_ name: String = "memory") -> Source {
    Source(kind: .filesystem, handle: name, displayName: "Files · \(name)", defaultAuthority: .authoredArtifact, defaultDomain: .project)
}

// Original bug: text-hash equality skipped authority/domain/metadata changes, and changed-text
// upserts also omitted domain/authority. Private generated memory remained public direct testimony.
@Test("unchanged text can be reclassified without losing metadata or its original text")
func unchangedMemoryReclassification() async throws {
    let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
    var object = CoreObject(sourceID: source.id, kind: .file, externalID: "memory", title: "memory", text: "private original", domain: .project, authority: .directStatement, metadata: ["floor_only": "keep"])
    try await store.ingest([object])
    object.domain = .restricted; object.authority = .generatedSummary; object.metadata = ["incoming": "keep too"]
    let outcome = try await store.ingest([object]); let repaired = try #require(await store.object(object.id))
    #expect(outcome.updated == 1); #expect(outcome.unchanged == 0)
    #expect(repaired.text == "private original"); #expect(repaired.domain == .restricted); #expect(repaired.authority == .generatedSummary)
    #expect(repaired.metadata["floor_only"] == "keep"); #expect(repaired.metadata["incoming"] == "keep too")
    #expect(repaired.metadata["classification_history"]?.contains("authority=5") == true)
}

@Test("policy repair is dry-run first and preserves every historical body")
func policyRepairPreservesVersions() async throws {
    let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
    var object = CoreObject(sourceID: source.id, kind: .file, externalID: "memory", title: "memory", text: "older private body", domain: .project, authority: .directStatement, metadata: ["custom": "old"])
    try await store.ingest([object]); object.text = "new private body"; object.contentHash = Digest.hex(object.text); try await store.ingest([object])
    let entity = CoreEntity(kind: .project, canonicalName: "example", domain: .project); try await store.upsert([entity])
    let claim = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "private", confidence: 0.8, authority: .directStatement, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    let evidence = Evidence(objectID: object.id, snippet: "new private body", authority: .directStatement)
    try await store.save([claim]); try await store.save([evidence]); try await store.link(claim: claim.id, to: evidence.id, stance: .supports)
    let repairs = [Store.ObjectPolicyRepair(objectID: object.id, domain: .restricted, authority: .generatedSummary, reason: "regression")]
    let dryRun = try await store.reclassifyObjects(repairs)
    #expect(dryRun.objectsChanged == 1); #expect(dryRun.versionsChanged == 1)
    #expect(try await store.object(object.id)?.domain == .project)
    let applied = try await store.reclassifyObjects(repairs, dryRun: false)
    #expect(applied.requiresRebuild)
    let history = try await store.objectHistory()
    #expect(history.map(\.text) == ["older private body"])
    #expect(history.allSatisfy { $0.domain == .restricted && $0.authority == .generatedSummary })
    #expect(history.first?.metadata["custom"] == "old")
    #expect(try await store.claim(claim.id)?.domain == .restricted)
    #expect(try await store.claim(claim.id)?.confidence == claim.confidence)
    #expect(try await store.entity(entity.id)?.domain == .restricted)
}

// Original bug: lower-tier proposals overwrote confidence while max(authority) retained the
// stronger tier, and reverse insertion preserved the weak derivation beside strong authority.
@Test("colliding claim assertions preserve the strongest producer in either insertion order")
func strongestClaimRemainsCoherent() async throws {
    for weakerFirst in [true, false] {
        let store = try await policyStore(); let entity = CoreEntity(kind: .project, canonicalName: "example", domain: .project); try await store.upsert([entity])
        let validity = Validity(validFrom: Date(timeIntervalSince1970: 1), observedAt: Date(timeIntervalSince1970: 10))
        let strong = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.95, authority: .authoredArtifact, derivation: .observed, validity: validity, domain: .project)
        let weak = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.2, authority: .modelInference, derivation: .inferred, validity: validity, domain: .project)
        try await store.save(weakerFirst ? [weak, strong] : [strong, weak])
        let saved = try #require(await store.claim(strong.id))
        #expect(saved.authority == strong.authority); #expect(saved.confidence == strong.confidence); #expect(saved.derivation == strong.derivation)
    }
}

// Original bug: source/month cards filtered an already limited latest page (or title text),
// so legitimate older objects appeared absent despite a nonzero global distribution count.
@Test("source and authored month filtering happens before the recent objects limit")
func corpusFiltersAddressWholeStore() async throws {
    let store = try await policyStore(); let target = policySource("older source"); let other = policySource("new source")
    try await store.upsert(target); try await store.upsert(other)
    let old = CoreObject(sourceID: target.id, kind: .file, externalID: "old", title: "needle", text: "specific content", authoredAt: Date(timeIntervalSince1970: 1_577_836_800), domain: .project, authority: .authoredArtifact)
    try await store.ingest([old] + (0..<100).map { CoreObject(sourceID: other.id, kind: .file, externalID: "new\($0)", title: "new", text: "recent \($0)", authoredAt: Date(), domain: .project, authority: .authoredArtifact) })
    #expect(try await store.recentObjects(sourceName: target.displayName, limit: 1).map(\.id) == [old.id])
    #expect(try await store.recentObjects(authoredMonth: "2020-01", limit: 1).map(\.id) == [old.id])
    #expect(try await store.recentObjects(sourceName: target.displayName, authoredMonth: "2020-01", searchText: "specific", limit: 1).map(\.id) == [old.id])
}

// Original bug: rebuilding cleared correction and direct user assertion rows with no floor
// representation from which to reconstruct them. Reject atomically before the first deletion.
@Test("rebuild refuses to discard unreplayable user assertions")
func rebuildProtectsUserAssertions() async throws {
    let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .file, externalID: "floor", title: "floor", text: "preserved", domain: .project, authority: .authoredArtifact); try await store.ingest([object])
    let entity = CoreEntity(kind: .project, canonicalName: "example", domain: .project); try await store.upsert([entity])
    let claim = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "corrected", confidence: 1, authority: .directStatement, derivation: .corrected, validity: Validity(observedAt: Date()), domain: .project); try await store.save([claim])
    let correction = Correction(supersededClaim: nil, assertedClaim: claim.id, reason: "user correction")
    try await store.save(correction)
    let receipt = Receipt(query: "example", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [.restricted], stages: [], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 0, claimsConsulted: 1, contradictionsSurfaced: 0, model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(receipt, claims: [claim.id])
    do { try await store.dropDerivedLayers(); Issue.record("unsafe rebuild succeeded") } catch is RebuildSafetyError {}
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM correction") == 1)
    #expect(try await store.receipt(code: receipt.id.value)?.id == receipt.id)
    #expect(try await store.database.scalarInt("SELECT COUNT(*) FROM receipt_claim") == 1)
    #expect(try await store.object(object.id)?.text == "preserved")
    #expect(try await store.claim(claim.id)?.derivation == .corrected)
}

// A known repo filename is not permission to relax a manually protected source. Historical
// versions retain their own protection, and a repeated run must still report pending replay.
@Test("automatic policy repair never relaxes an existing private compartment and keeps pending replay visible")
func policyRepairIsMonotonicAndPending() async throws {
    let store = try await policyStore(); let source = policySource("manually configured"); try await store.upsert(source)
    var object = CoreObject(sourceID: source.id, kind: .file, externalID: "/Users/example/Documents/GitHub/OpenCore/README.md", title: "private", text: "old protected body", domain: .medical, authority: .authoredArtifact)
    try await store.ingest([object]); object.text = "new protected body"; object.contentHash = Digest.hex(object.text); try await store.ingest([object])
    let repairs = [Store.ObjectPolicyRepair(objectID: object.id, domain: .project, authority: .authoredArtifact, reason: "filename guess")]
    let dry = try await store.reclassifyObjects(repairs)
    #expect(dry.objectsChanged == 0); #expect(dry.versionsChanged == 0)
    _ = try await store.reclassifyObjects(repairs, dryRun: false)
    #expect(try await store.object(object.id)?.domain == .medical)
    #expect(try await store.objectHistory().allSatisfy { $0.domain == .medical })
    let restricted = [Store.ObjectPolicyRepair(objectID: object.id, domain: .restricted, authority: .generatedSummary, reason: "mixed memory")]
    _ = try await store.reclassifyObjects(restricted, dryRun: false)
    let repeated = try await store.reclassifyObjects(restricted)
    #expect(repeated.objectsChanged == 0); #expect(repeated.versionsChanged == 0)
    #expect(repeated.objectsPendingRebuild == 1); #expect(repeated.requiresRebuild)
}

@Test("backup is created consistently from the active store and refuses existing files and links")
func policyRepairBackupIsCreatedRatherThanTrusted() async throws {
    let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .file, externalID: "floor", title: "floor", text: "backup body", domain: .medical, authority: .authoredArtifact); try await store.ingest([object])
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-backup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let aliasStore = try await policyStore()
    let sourceURL = await aliasStore.database.path
    let symlink = directory.appendingPathComponent("symlink.sqlite"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sourceURL)
    let hardlink = directory.appendingPathComponent("hardlink.sqlite"); try FileManager.default.linkItem(at: sourceURL, to: hardlink)
    for url in [sourceURL, symlink, hardlink] {
        do { try await aliasStore.createPolicyRepairBackup(at: url); Issue.record("existing database alias accepted") } catch {}
    }
    // Aliases belong to a separate fixture: hardlinking a live SQLite source can alter
    // its VFS path state, independently of whether the destination check rejects it.
    try FileManager.default.removeItem(at: hardlink)
    let backupURL = directory.appendingPathComponent("new-backup.sqlite")
    try await store.createPolicyRepairBackup(at: backupURL)
    let backup = try await Store.open(at: backupURL)
    #expect(try await backup.object(object.id)?.text == object.text)
    #expect(try await backup.object(object.id)?.domain == .medical)
    #expect(try await backup.database.query("PRAGMA integrity_check").first?.string("integrity_check") == "ok")
    #expect((try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try await store.object(object.id)?.text == object.text)
    do { try await store.createPolicyRepairBackup(at: backupURL); Issue.record("existing backup overwritten") } catch {}
}

@Test("a claim supported by two repaired objects is counted once")
func repairCountsDistinctClaims() async throws {
    let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
    let objects = ["a", "b"].map { CoreObject(sourceID: source.id, kind: .file, externalID: $0, title: $0, text: "private \($0)", domain: .project, authority: .authoredArtifact) }
    try await store.ingest(objects)
    let entity = CoreEntity(kind: .project, canonicalName: "shared", domain: .project); try await store.upsert([entity])
    let claim = CoreClaim(subject: entity.id, predicate: Predicate.describes, literal: "private", confidence: 0.8, authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project); try await store.save([claim])
    for object in objects { let evidence = Evidence(objectID: object.id, snippet: object.text, authority: .authoredArtifact); try await store.save([evidence]); try await store.link(claim: claim.id, to: evidence.id, stance: .supports) }
    let report = try await store.reclassifyObjects(objects.map { .init(objectID: $0.id, domain: .restricted, authority: .generatedSummary, reason: "fixture") })
    #expect(report.claimsQuarantined == 1)
}

// Original bug: the corpus promised path search but ignored the URI column entirely.
@Test("corpus path search matches a URI absent from title and content")
func corpusSearchIncludesURI() async throws {
    let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .file, externalID: "uri-only", title: "plain title", text: "plain content", uri: "file:///Users/example/unique-path-fragment/notes.md", domain: .project, authority: .authoredArtifact)
    try await store.ingest([object])
    #expect(try await store.recentObjects(searchText: "unique-path-fragment").map(\.id) == [object.id])
}

// Original bug: duplicate dossier statements used confidence alone, overriding ordinal authority.
@Test("dossier duplicate statements preserve their most authoritative representative")
func dossierRepresentativeUsesAuthorityFirst() async throws {
    let store = try await policyStore()
    let entity = CoreEntity(kind: .project, canonicalName: "ordered", domain: .project)
    try await store.upsert([entity])
    let strong = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.6,
                           authority: .directStatement, derivation: .observed,
                           validity: Validity(observedAt: Date(timeIntervalSince1970: 10)), domain: .project)
    let weak = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.99,
                         authority: .modelInference, derivation: .inferred,
                         validity: Validity(observedAt: Date(timeIntervalSince1970: 20)), domain: .project)
    try await store.save([strong, weak])
    let dossier = try #require(await store.dossier(for: entity.id))
    #expect(dossier.claims.first?.claim.authority == .directStatement)
}

// Personal/work are real compartments even though they are not in Domain.sensitive. Keeping
// an old project label when importing personal memory would leave it admitted to project MCP.
@Test("project imports can move into personal or work while private imports cannot move back into project")
func personalAndWorkCompartmentRepairsAreApplied() async throws {
    for domain in [Domain.personal, .work] {
        let store = try await policyStore(); let source = policySource(); try await store.upsert(source)
        var object = CoreObject(sourceID: source.id, kind: .file, externalID: "compartment", title: "note", text: "older text", domain: .project, authority: .authoredArtifact)
        try await store.ingest([object]); object.text = "newer text"; object.contentHash = Digest.hex(object.text); try await store.ingest([object])
        _ = try await store.reclassifyObjects([.init(objectID: object.id, domain: domain, authority: .generatedSummary, reason: "private compartment")], dryRun: false)
        #expect(try await store.object(object.id)?.domain == domain)
        #expect(try await store.objectHistory().allSatisfy { $0.domain == domain })
        object.domain = .project; try await store.ingest([object])
        #expect(try await store.object(object.id)?.domain == domain)
    }
}

// Original bug: a newer representative changed the ID but not the current believed value.
@Test("a collapsed dossier statement remains believed after same-value corroboration")
func dossierHeldStateSurvivesRepresentativeChange() async throws {
    let store = try await policyStore()
    let entity = CoreEntity(kind: .project, canonicalName: "corroborated", domain: .project)
    try await store.upsert([entity])
    let earlier = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.8,
                            authority: .authoredArtifact, derivation: .observed,
                            validity: Validity(observedAt: Date(timeIntervalSince1970: 10)), domain: .project)
    let later = CoreClaim(subject: entity.id, predicate: Predicate.status, literal: "active", confidence: 0.8,
                          authority: .authoredArtifact, derivation: .observed,
                          validity: Validity(observedAt: Date(timeIntervalSince1970: 20)), domain: .project)
    try await store.save([earlier, later])
    try await store.save(Belief(claimKey: earlier.claimKey, version: 1, claimID: earlier.id,
                                confidence: 0.8, authority: .authoredArtifact, validity: earlier.validity, reason: "initial"))
    let dossier = try #require(await store.dossier(for: entity.id))
    #expect(dossier.claims.first?.id == later.id)
    #expect(dossier.claims.first?.isBelieved == true)
}

// Original bug: a retained manual audit ledger appeared as a connector pending first sync.
@Test("manual audit records do not advertise a nonexistent connector sync")
func manualAuditSourcesAreNotPendingConnectors() async throws {
    let store = try await policyStore()
    let manual = Source(kind: .manual, handle: "audit-ledger", displayName: "Local audit", defaultAuthority: .generatedSummary, defaultDomain: .restricted)
    let connector = policySource("real unsynced connector")
    try await store.upsert(manual); try await store.upsert(connector)
    let snapshot = try await store.homeSnapshot()
    #expect(!snapshot.neverSynced.contains(manual.displayName))
    #expect(snapshot.neverSynced.contains(connector.displayName))
}
