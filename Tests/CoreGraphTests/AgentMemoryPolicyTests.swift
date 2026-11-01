import CoreIngest
import CoreGraph
import CoreStore
import CoreModel
import Foundation
import Testing

@Test("global and unknown generated memory is quarantined rather than imported as direct testimony")
func importedMemoryAuthorityAndScope() throws {
    let home = URL(fileURLWithPath: "/tmp/opencore-policy-fixture")
    for relative in [".codex/memories/MEMORY.md", ".codex/memories/memory_summary.md", ".codex/memories/rollout_summaries/2026-example.md", ".codex/memories/rollout_summaries/opencore.md"] {
        let policy = try #require(AgentMemoryPolicy.classification(for: home.appendingPathComponent(relative), home: home, names: .empty))
        #expect(policy.domain == .restricted); #expect(policy.authority == .generatedSummary)
    }
    let guidance = try #require(AgentMemoryPolicy.classification(for: home.appendingPathComponent(".claude/CLAUDE.md"), home: home, names: .empty))
    #expect(guidance.authority == .authoredArtifact); #expect(guidance.domain == .restricted)
    let projectMemory = try #require(AgentMemoryPolicy.classification(for: home.appendingPathComponent(".claude/projects/-Users-user-Documents-GitHub-OpenCore/memory/MEMORY.md"), home: home, names: .empty))
    #expect(projectMemory.authority == .generatedSummary); #expect(projectMemory.domain == .project)
    let scratch = try #require(AgentMemoryPolicy.classification(for: home.appendingPathComponent(".claude/projects/-private-tmp-OpenCore/memory/MEMORY.md"), home: home, names: .empty))
    #expect(scratch.domain == .restricted)
    let handoff = try #require(AgentMemoryPolicy.classification(for: home.appendingPathComponent("Documents/GitHub/OpenCore/Docs/ai/STATE.md"), home: home, names: .empty))
    #expect(handoff.authority == .generatedSummary)
    #expect(AgentMemoryPolicy.classification(for: home.appendingPathComponent("Documents/GitHub/OpenCore/Sources/private.swift"), home: home, names: .empty) == nil)
}

// A connector's less restrictive proposal must not become graph input after Store has
// retained the old private floor policy. Otherwise fresh aliases/entities could bypass it.
@Test("ingest derivation consumes the effective stored floor policy rather than unchecked connector input")
func derivationRespectsRetainedFloorPolicy() async throws {
    let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opencore-floor-policy-\(UUID().uuidString)/store.sqlite")
    let store = try await Store.open(at: path)
    let source = Source(kind: .filesystem, handle: "explicit medical", displayName: "Medical", defaultAuthority: .authoredArtifact, defaultDomain: .medical)
    try await store.upsert(source)
    var object = CoreObject(sourceID: source.id, kind: .file, externalID: "note", title: "private title", text: "plain original", authoredAt: Date(), domain: .medical, authority: .authoredArtifact, metadata: ["folder": "Private Folder"])
    try await store.ingest([object])
    object.domain = .project; object.text = "plain update"; object.contentHash = Digest.hex(object.text)
    _ = try await IngestPipeline(store: store).run(objects: [object])
    #expect(try await store.object(object.id)?.domain == .medical)
    let container = CoreEntity(kind: .concept, canonicalName: "Private Folder", domain: .medical)
    #expect(try await store.entity(container.id)?.domain == .medical)
    #expect(try await store.events(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60), domains: [.project]).isEmpty == true)
}
