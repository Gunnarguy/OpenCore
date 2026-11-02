import CoreGraph
import CoreJSONRPC
import CoreMCP
import CoreModel
import CoreStore
import Foundation
import Testing

private func repairFirewallStore() async throws -> Store {
    try await Store.open(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-repair-firewall-\(UUID().uuidString)/store.sqlite"))
}
private func repairTool(_ server: MCPServer, name: String, arguments: [String: JSONValue] = [:]) async throws -> String {
    let payload: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])
    let request = try RPCRequest.decode(JSONEncoder().encode(payload))
    let result = try await server.handle(request)
    guard case .object(let dict) = result, case .array(let content)? = dict["content"], case .object(let first)? = content.first, case .string(let text)? = first["text"] else { Issue.record("unexpected MCP result"); return "" }
    return text
}

// Original repair quarantined shared entities permanently. Simply retaining them would instead
// leak aliases introduced by the private source, because entity_alias has no object provenance.
@Test("repair retains independently public project and technology but blocks unproven private aliases")
func sharedEntitiesKeepPublicFactsWithoutPrivateAliases() async throws {
    let store = try await repairFirewallStore()
    let publicSource = Source(kind: .github, handle: "public", displayName: "Public GitHub", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    let memorySource = Source(kind: .filesystem, handle: "Cross-Agent-Memory", displayName: "Agent memories", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(publicSource); try await store.upsert(memorySource)
    let publicObject = CoreObject(sourceID: publicSource.id, kind: .repository, externalID: "user/OpenCore", title: "OpenCore", text: "OpenCore is built with Swift.", authoredAt: Date(), domain: .project, authority: .authoredArtifact)
    let privateObject = CoreObject(sourceID: memorySource.id, kind: .file, externalID: "memory", title: "private file", text: "Secret memory about a shared project", authoredAt: Date(), domain: .project, authority: .authoredArtifact)
    try await store.ingest([publicObject, privateObject])
    let project = CoreEntity(kind: .project, canonicalName: "OpenCore", domain: .project)
    let swift = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .publicRecord)
    try await store.upsert([project, swift])
    try await store.addAliases([EntityAlias(entityID: project.id, surface: "OpenCore", confidence: 1), EntityAlias(entityID: project.id, surface: "unique-private-alias", confidence: 1), EntityAlias(entityID: swift.id, surface: "Swift", confidence: 1)])
    let publicClaim = CoreClaim(subject: project.id, predicate: Predicate.builtWith, objectEntity: swift.id, confidence: 0.98, authority: .authoredArtifact, derivation: .observed, validity: Validity(observedAt: Date()), domain: .project)
    let privateClaim = CoreClaim(subject: project.id, predicate: Predicate.describes, objectEntity: swift.id, literal: "PRIVATE_VALUE", confidence: 0.8, authority: .generatedSummary, derivation: .inferred, validity: Validity(observedAt: Date()), domain: .project)
    try await store.save([publicClaim, privateClaim])
    let publicEvidence = Evidence(objectID: publicObject.id, snippet: publicObject.text, authority: .authoredArtifact)
    let privateEvidence = Evidence(objectID: privateObject.id, snippet: privateObject.text, authority: .authoredArtifact)
    try await store.save([publicEvidence, privateEvidence])
    try await store.link(claim: publicClaim.id, to: publicEvidence.id, stance: .supports)
    try await store.link(claim: privateClaim.id, to: privateEvidence.id, stance: .supports)
    _ = try await store.reclassifyObjects([.init(objectID: privateObject.id, domain: .restricted, authority: .generatedSummary, reason: "privacy repair")], dryRun: false)
    #expect(try await store.entity(project.id)?.domain == .project)
    #expect(try await store.entity(swift.id)?.domain == .publicRecord)
    #expect(try await store.claim(publicClaim.id)?.domain == .project)
    #expect(try await store.claim(privateClaim.id)?.domain == .restricted)
    let server = MCPServer(store: store)
    let dossier = try await repairTool(server, name: "core_dossier", arguments: ["entity": .string("OpenCore")])
    #expect(dossier.contains("Swift")); #expect(!dossier.contains("unique-private-alias")); #expect(!dossier.contains("PRIVATE_VALUE"))
    for tool in ["core_dossier", "core_claims", "core_timeline"] {
        let text = try await repairTool(server, name: tool, arguments: ["entity": .string("unique-private-alias")])
        #expect(text.contains("No entity known"))
    }
    #expect(try await store.resolve(surface: "unique-private-alias").isEmpty == false) // local history retained
}

// Original repair located events only through claim subjects. Plain files produce timeline
// rows without claims, leaving their private current and historical titles exposed over MCP.
@Test("repair quarantines exact claim-free timeline events from current and historical floor versions")
func claimFreeTimelineTitlesStayPrivate() async throws {
    let store = try await repairFirewallStore()
    let source = Source(kind: .filesystem, handle: "Cross-Agent-Memory", displayName: "Agent memories", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    var note = CoreObject(sourceID: source.id, kind: .file, externalID: "plain-note", title: "medical followup", text: "plain generic prose", authoredAt: Date().addingTimeInterval(-60), domain: .project, authority: .authoredArtifact, metadata: ["folder": "Mixed notes"])
    _ = try await IngestPipeline(store: store).run(objects: [note])
    note.title = "private finance meeting"; note.text = "different generic prose"; note.contentHash = Digest.hex(note.text); note.authoredAt = Date().addingTimeInterval(-30)
    _ = try await IngestPipeline(store: store).run(objects: [note])
    #expect(try await store.claimCount() == 0)
    let server = MCPServer(store: store)
    #expect(try await repairTool(server, name: "core_timeline").contains("medical followup"))
    _ = try await store.reclassifyObjects([.init(objectID: note.id, domain: .restricted, authority: .generatedSummary, reason: "privacy repair")], dryRun: false)
    let text = try await repairTool(server, name: "core_timeline")
    #expect(!text.contains("medical followup")); #expect(!text.contains("private finance meeting"))
    let preserved = try await store.events(from: Date().addingTimeInterval(-3600), to: Date(), domains: [.restricted])
    #expect(Set(preserved.map(\.detail)) == ["medical followup", "private finance meeting"])
    #expect(try await store.objectHistory().first?.text == "plain generic prose")
}

// The body hash cannot distinguish title/date/container updates. These original fields must
// survive on the floor and reproduce both timeline entries after a deterministic rebuild.
@Test("same-body presentation history survives repair and rebuild without a content version")
func sameBodyPresentationHistoryIsFloorData() async throws {
    let store = try await repairFirewallStore()
    let source = Source(kind: .filesystem, handle: "Cross-Agent-Memory", displayName: "Memories", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    var object = CoreObject(sourceID: source.id, kind: .file, externalID: "same-body", title: "medical followup", text: "plain generic prose", uri: "file:///old", authoredAt: Date().addingTimeInterval(-60), domain: .project, authority: .authoredArtifact, metadata: ["folder": "Old folder"])
    _ = try await IngestPipeline(store: store).run(objects: [object])
    object.title = "generic notes"; object.authoredAt = Date().addingTimeInterval(-30); object.uri = "file:///new"; object.metadata["folder"] = "New folder"
    _ = try await IngestPipeline(store: store).run(objects: [object])
    let stored = try #require(await store.object(object.id))
    let presentations = ObjectPresentation.history(in: stored.metadata)
    #expect(presentations.first?.title == "medical followup"); #expect(presentations.first?.uri == "file:///old")
    #expect(try await store.objectHistory().isEmpty)
    _ = try await store.reclassifyObjects([.init(objectID: object.id, domain: .restricted, authority: .generatedSummary, reason: "privacy repair")], dryRun: false)
    // Quarantine now stops an in-place drop, so this clears the temporary store the way a
    // rehearsal clears its copy. What is asserted below is that the floor alone is enough.
    try await store.clearDerivedLayersOfRehearsalCopy()
    _ = try await IngestPipeline(store: store).rederive()
    let events = try await store.events(from: Date().addingTimeInterval(-3600), to: Date(), domains: [.restricted])
    #expect(Set(events.map(\.detail)) == ["medical followup", "generic notes"])
    let exposed = try await repairTool(MCPServer(store: store), name: "core_timeline")
    #expect(!exposed.contains("medical followup")); #expect(!exposed.contains("generic notes"))
}

// Older stores already lost these fields. Preserve uncertain legacy rows as explicit restricted
// floor snapshots while keeping a different exact, safely backed event in the same container.
@Test("legacy same-body timeline rows are quarantined while an independently public event stays visible")
func legacyPresentationGapDoesNotLeakOrHideProvenPublicEvent() async throws {
    let store = try await repairFirewallStore()
    let source = Source(kind: .filesystem, handle: "Cross-Agent-Memory", displayName: "Memories", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    let publicSource = Source(kind: .github, handle: "public", displayName: "Public", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source); try await store.upsert(publicSource)
    var privateObject = CoreObject(sourceID: source.id, kind: .file, externalID: "legacy-note", title: "medical followup", text: "plain generic prose", authoredAt: Date().addingTimeInterval(-60), domain: .project, authority: .authoredArtifact, metadata: ["folder": "Old private folder"])
    _ = try await IngestPipeline(store: store).run(objects: [privateObject])
    let oldFolder = CoreEntity(kind: .concept, canonicalName: "Old private folder", domain: .project)
    try await store.addAliases([EntityAlias(entityID: oldFolder.id, surface: "private-old-folder-alias", confidence: 1)])
    // Reproduce the shipped older behavior deliberately: overwrite only presentation fields,
    // create its new event, and retain no descriptor for the older event on the floor.
    privateObject.title = "generic notes"; privateObject.authoredAt = Date().addingTimeInterval(-30); privateObject.metadata["folder"] = "New folder"
    try await store.database.execute("UPDATE object SET title = ?, authored_at = ?, metadata = ? WHERE id = ?", [.text(privateObject.title), .real(privateObject.authoredAt!.timeIntervalSince1970), .text(String(decoding: try JSONEncoder().encode(privateObject.metadata), as: UTF8.self)), .text(privateObject.id.value)])
    _ = try await IngestPipeline(store: store).run(objects: [privateObject], storeObjects: false)
    let publicObject = CoreObject(sourceID: publicSource.id, kind: .file, externalID: "public-note", title: "public release note", text: "public generic prose", authoredAt: Date().addingTimeInterval(-10), domain: .project, authority: .authoredArtifact, metadata: ["folder": "New folder"])
    _ = try await IngestPipeline(store: store).run(objects: [publicObject])
    // Exercise the scoped pass after the global audit with a second actual policy change.
    let secondPrivate = CoreObject(sourceID: source.id, kind: .file, externalID: "second-private", title: "second private entry", text: "other generic prose", authoredAt: Date().addingTimeInterval(-5), domain: .project, authority: .authoredArtifact, metadata: ["folder": "Second private folder"])
    _ = try await IngestPipeline(store: store).run(objects: [secondPrivate])
    #expect(try await store.objectHistory().isEmpty)
    _ = try await store.reclassifyObjects([.init(objectID: privateObject.id, domain: .restricted, authority: .generatedSummary, reason: "privacy repair"), .init(objectID: publicObject.id, domain: .project, authority: .authoredArtifact, reason: "unchanged safe candidate"), .init(objectID: secondPrivate.id, domain: .restricted, authority: .generatedSummary, reason: "second privacy repair")], dryRun: false)
    let server = MCPServer(store: store)
    var exposed = try await repairTool(server, name: "core_timeline")
    #expect(exposed.contains("public release note")); #expect(!exposed.contains("medical followup")); #expect(!exposed.contains("generic notes")); #expect(!exposed.contains("second private entry"))
    #expect(try await store.entity(oldFolder.id)?.domain == .restricted)
    for tool in ["core_dossier", "core_claims"] {
        let denied = try await repairTool(server, name: tool, arguments: ["entity": .string("Old private folder")])
        #expect(denied.contains("does not expose")); #expect(!denied.contains("medical followup")); #expect(!denied.contains("private-old-folder-alias"))
        let alias = try await repairTool(server, name: tool, arguments: ["entity": .string("private-old-folder-alias")])
        #expect(alias.contains("No entity known"))
    }
    let floor = try #require(await store.object(privateObject.id))
    #expect(floor.text == privateObject.text)
    let auditFloors = try await store.allObjects().filter { $0.domain == .restricted && $0.metadata["legacy_provenance"] != nil }
    #expect(auditFloors.contains { ObjectPresentation.legacyEvents(in: $0.metadata).contains { $0.detail == "medical followup" } && $0.metadata["classification_affected_entities"] != nil })
    try await store.clearDerivedLayersOfRehearsalCopy()
    _ = try await IngestPipeline(store: store).rederive()
    exposed = try await repairTool(server, name: "core_timeline")
    #expect(exposed.contains("public release note")); #expect(!exposed.contains("medical followup"))
    #expect(try await store.entity(oldFolder.id)?.domain == .restricted)
    let rejectedAlias = try await repairTool(server, name: "core_dossier", arguments: ["entity": .string("private-old-folder-alias")])
    #expect(rejectedAlias.contains("No entity known"))
    let retained = try await store.events(from: Date().addingTimeInterval(-3600), to: Date(), domains: [.restricted])
    #expect(Set(retained.map(\.detail)) == ["medical followup", "generic notes", "second private entry"])
}

// A technology-looking string in a private model proposal is not public vocabulary. Previously
// both its subject and target were forced to publicRecord and got publicly resolvable aliases.
@Test("new private model-proposed technology names inherit their source compartment")
func privateModelTechnologyNamesAreNotPublished() async throws {
    for domain in [Domain.medical, .restricted, .personal, .work] {
        let store = try await repairFirewallStore()
        let source = Source(kind: .filesystem, handle: "private", displayName: "Private", defaultAuthority: .generatedSummary, defaultDomain: domain)
        try await store.upsert(source)
        let record = ProposedClaimRecord(subject: "PrivateSubjectTech", subjectKind: .technology, predicate: Predicate.uses, value: "PrivateTargetTech", valueKind: .technology, verbatimQuote: "PrivateSubjectTech uses PrivateTargetTech.", confidence: 0.5)
        let encoded = String(decoding: try JSONEncoder().encode([record]), as: UTF8.self)
        let object = CoreObject(sourceID: source.id, kind: .file, externalID: "private-proposal", title: "Private note", text: record.verbatimQuote, authoredAt: Date(), domain: domain, authority: .generatedSummary, metadata: [ClaimExtractor.modelProposedClaimsMetadataKey: encoded])
        _ = try await IngestPipeline(store: store).run(objects: [object])
        for name in ["PrivateSubjectTech", "PrivateTargetTech"] {
            let id = CoreEntity(kind: .technology, canonicalName: name, domain: domain).id
            #expect(try await store.entity(id)?.domain == domain)
        }
        let dossier = try await repairTool(MCPServer(store: store), name: "core_dossier", arguments: ["entity": .string("PrivateSubjectTech")])
        #expect(!dossier.contains("PrivateTargetTech")); #expect(!dossier.contains("aliases:"))
    }
}
