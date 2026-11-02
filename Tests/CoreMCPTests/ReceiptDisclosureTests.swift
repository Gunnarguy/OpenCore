import CoreJSONRPC
import CoreMCP
import CoreModel
import CoreStore
import Foundation
import Testing

private func traceDisclosure(_ receipt: Receipt, server: MCPServer) async throws -> String {
    let payload: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
        "params": .object(["name": .string("core_trace"), "arguments": .object(["receipt": .string(receipt.shortCode)])])])
    let request = try RPCRequest.decode(JSONEncoder().encode(payload))
    let result = try await server.handle(request)
    guard case .object(let dict) = result, case .array(let content)? = dict["content"],
          case .object(let first)? = content.first, case .string(let text)? = first["text"] else {
        Issue.record("Unexpected trace shape"); return ""
    }
    return text
}

// An admitted trace quoted an owner's unlabelled raw question and arbitrary stage note.
@Test("model-facing receipt traces disclose outbound uncertainty without leaking owner free text")
func mcpReceiptDisclosureWithholdsUnlabelledOwnerText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencore-trace-disclosure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await Store.open(at: directory.appendingPathComponent("store.sqlite3"))
    let source = Source(kind: .manual, handle: "fixture", displayName: "Fixture", defaultAuthority: .authoredArtifact, defaultDomain: .project)
    try await store.upsert(source)
    let object = CoreObject(sourceID: source.id, kind: .document, externalID: "fixture", title: "Allowed fixture", text: "Allowed project text.", domain: .project, authority: .authoredArtifact)
    try await store.ingest([object])
    let evidence = Evidence(objectID: object.id, snippet: object.text, authority: object.authority)
    try await store.save([evidence])
    let cloud = ReceiptStage(name: "cloud.request", counters: ["request_submitted": 1, "objects_submitted": 1, "application_acknowledged": 0], milliseconds: 0)
    var receipt = Receipt(query: "PRIVATE_QUESTION_SENTINEL", queryClass: .factual, domainsAdmitted: [.project], domainsBlocked: [],
        stages: [cloud], objectsSearched: 1, objectsRetrieved: 1, evidenceAdmitted: 1, claimsConsulted: 0, contradictionsSurfaced: 0,
        model: nil, objectsTransmitted: 0, confidence: nil)
    try await store.save(receipt, evidence: [(evidence.id, 0.5)])
    let server = MCPServer(store: store)
    let traced = try await traceDisclosure(receipt, server: server)
    #expect(traced.contains("Allowed project text."))
    #expect(!traced.contains("PRIVATE_QUESTION_SENTINEL"))
    #expect(traced.contains(receipt.outboundDescription))
    receipt.id = ReceiptID("activity-fixture-receipt")
    receipt.stages.append(ReceiptStage(name: "activity", counters: ["events_in_window": 3], milliseconds: 0, note: "PRIVATE_NOTE_SENTINEL"))
    try await store.save(receipt)
    let activity = try await traceDisclosure(receipt, server: server)
    #expect(!activity.contains("PRIVATE_NOTE_SENTINEL"))
    #expect(activity.contains(receipt.outboundDescription))
    receipt.id = ReceiptID("denied-fixture-receipt")
    receipt.domainsAdmitted = [.medical]
    try await store.save(receipt)
    let denied = try await traceDisclosure(receipt, server: server)
    #expect(!denied.contains("Cloud submission"), "receipt admission must precede outbound metadata disclosure")
}
