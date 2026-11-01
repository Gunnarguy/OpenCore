import CoreGraph
import CoreJSONRPC
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation
import Testing

@testable import CoreIngest
@testable import CoreMCP

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-mcp-firewall-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

private func callMCPTool(
    _ server: MCPServer,
    name: String,
    arguments: [String: JSONValue] = [:]
) async throws -> String {
    let payload: JSONValue = .object([
        "jsonrpc": .string("2.0"),
        "id": .number(1),
        "method": .string("tools/call"),
        "params": .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]),
    ])
    let data = try JSONEncoder().encode(payload)
    let request = try JSONDecoder().decode(RPCRequest.self, from: data)
    let result = try await server.handle(request)
    guard case .object(let dict) = result,
          case .array(let content)? = dict["content"],
          case .object(let first)? = content.first,
          case .string(let text)? = first["text"]
    else {
        Issue.record("Unexpected MCP tool result shape: \(result)")
        return ""
    }
    return text
}

/// **The bug.** `Reasoner.assemble` and `MCPServer` checked `policy.admits(entity.domain)` on
/// the subject entity, then trusted every claim, contradiction, belief version, and receipt
/// trace attached to or stored alongside it:
///
/// 1. `Reasoner.assemble` emitted claims on a `.project` subject even when `claim.domain` or
///    `claim.objectEntity` belonged to a blocked domain (`.medical`, `.personal`), or when the
///    claim's only supporting evidence lived in a blocked object.
/// 2. `core_claims` returned every claim on an admitted entity without checking `claim.domain`
///    or the target `objectEntity` domain.
/// 3. `core_contradictions` returned `store.contradictions()` across the entire store, leaking
///    `item.reason` for conflicts in `.medical`, `.financial`, or `.personal`.
/// 4. `core_changed` returned `store.beliefsDecided(since:)` across the entire store, leaking
///    subjects, values, and reasons from blocked domains.
/// 5. `core_trace` returned `store.trace(receipt:)` without checking whether the receipt
///    admitted a sensitive domain during a local CLI/app run or whether traced objects were in
///    admitted domains.
@Suite("MCP and Reasoner domain firewall")
struct DomainFirewallMCPTests {
    // The bug: `domain(forFolder:)` matched "code" inside "Passcodes", so the note came out `.project`
    // and an MCP caller could read it, and the schedule was about to run a whole library through
    // that with no click. Runs the real parser, so the domain is the one a sync would write.
    @Test("a note in a folder called Passcodes never reaches an MCP caller")
    func noteInPasscodesFolderStaysBehindTheFirewall() async throws {
        let store = try await temporaryStore()
        let notes = AppleNotesConnector()
        try await store.upsert(notes.source)
        let reply = ["OPENCORE_NOTES_V1", "1", "0"].joined(separator: "\u{1F}") + "\u{1E}"
            + ["note-1", "Quillberry gate", "Passcodes", "2026-06-01T09:00:00", "The quillberry gate code is 4417."].joined(separator: "\u{1F}") + "\u{1E}"
        let parsed = try AppleNotesConnector.parse(reply, sourceID: notes.source.id, since: nil)
        _ = try await IngestPipeline(store: store).run(objects: parsed.objects)
        #expect(try await store.allObjects().first?.domain == .personal)

        let server = MCPServer(store: store, sensitiveDomainsUnlockable: false)
        for tool in ["core_ask", "core_search"] {
            let text = try await callMCPTool(server, name: tool, arguments: ["query": .string("quillberry gate code")])
            #expect(!text.contains("4417"), "\(tool) returned the code")
        }
    }

    @Test("Reasoner and core_claims withhold sensitive claims and sensitive target entities on an admitted subject")
    func claimsOnAdmittedSubjectRespectClaimAndTargetDomain() async throws {
        let store = try await temporaryStore()
        let source = Source(
            kind: .filesystem,
            handle: "local",
            displayName: "Local",
            defaultAuthority: .authoredArtifact,
            defaultDomain: .project
        )
        try await store.upsert(source)

        let projectObj = CoreObject(
            sourceID: source.id,
            kind: .document,
            externalID: "OpenClinic#readme",
            title: "OpenClinic - README",
            text: "OpenClinic is built with Swift and manages clinical workflows.",
            authoredAt: Date(),
            domain: .project,
            authority: .authoredArtifact
        )
        let medicalObj = CoreObject(
            sourceID: source.id,
            kind: .note,
            externalID: "note-med-1",
            title: "Lab Results",
            text: "Private diagnosis note mentioning OpenClinic.",
            authoredAt: Date(),
            domain: .medical,
            authority: .directStatement
        )
        try await store.ingest([projectObj, medicalObj])
        try await store.save(Chunker().chunks(for: projectObj))
        try await store.save(Chunker().chunks(for: medicalObj))

        let projectEntity = CoreEntity(kind: .project, canonicalName: "OpenClinic", domain: .project)
        let swiftEntity = CoreEntity(kind: .technology, canonicalName: "Swift", domain: .project)
        let secretPerson = CoreEntity(kind: .person, canonicalName: "Dr. Secret", domain: .medical)
        try await store.upsert([projectEntity, swiftEntity, secretPerson])
        try await store.addAliases([
            EntityAlias(entityID: projectEntity.id, surface: "OpenClinic", confidence: 1.0)
        ])

        let publicClaim = CoreClaim(
            subject: projectEntity.id,
            predicate: Predicate.builtWith,
            objectEntity: swiftEntity.id,
            confidence: 0.95,
            authority: .authoredArtifact,
            derivation: .observed,
            validity: Validity(observedAt: Date()),
            domain: .project
        )
        let sensitiveClaimOnProject = CoreClaim(
            subject: projectEntity.id,
            predicate: "prescribed_medication",
            literal: "ConfidentialRx 50mg",
            confidence: 0.95,
            authority: .directStatement,
            derivation: .observed,
            validity: Validity(observedAt: Date()),
            domain: .medical
        )
        let claimToSensitiveTarget = CoreClaim(
            subject: projectEntity.id,
            predicate: Predicate.metWith,
            objectEntity: secretPerson.id,
            confidence: 0.95,
            authority: .authoredArtifact,
            derivation: .observed,
            validity: Validity(observedAt: Date()),
            domain: .project
        )
        let projectClaimBackedOnlyByMedicalEvidence = CoreClaim(
            subject: projectEntity.id,
            predicate: "deployment_note",
            literal: "MedicalOnlyEvidenceLeak",
            confidence: 0.95,
            authority: .authoredArtifact,
            derivation: .observed,
            validity: Validity(observedAt: Date()),
            domain: .project
        )
        try await store.save([
            publicClaim,
            sensitiveClaimOnProject,
            claimToSensitiveTarget,
            projectClaimBackedOnlyByMedicalEvidence,
        ])

        let publicEv = Evidence(
            objectID: projectObj.id,
            snippet: "OpenClinic is built with Swift",
            authority: .authoredArtifact
        )
        let medicalEv = Evidence(
            objectID: medicalObj.id,
            snippet: "ConfidentialRx 50mg",
            authority: .directStatement
        )
        try await store.save([publicEv, medicalEv])
        try await store.link(claim: publicClaim.id, to: publicEv.id, stance: .supports)
        try await store.link(claim: sensitiveClaimOnProject.id, to: medicalEv.id, stance: .supports)
        try await store.link(claim: claimToSensitiveTarget.id, to: publicEv.id, stance: .supports)
        try await store.link(claim: projectClaimBackedOnlyByMedicalEvidence.id, to: medicalEv.id, stance: .supports)

        // Direct store.lexicalChunks with admittedDomains must never return blocked chunks by default.
        let directLexical = try await store.lexicalChunks(
            match: "OpenClinic",
            limit: 10,
            admittedDomains: [.project, .publicRecord]
        )
        #expect(directLexical.allSatisfy { $0.object.domain == .project })

        let answer = try await Reasoner(store: store).answer("What is OpenClinic built with?", externalCaller: true)
        let statements = answer.points.map(\.statement).joined(separator: "\n")
        #expect(statements.contains("Swift"))
        #expect(!statements.contains("ConfidentialRx"))
        #expect(!statements.contains("Dr. Secret"))
        #expect(!statements.contains("MedicalOnlyEvidenceLeak"))

        let server = MCPServer(store: store, sensitiveDomainsUnlockable: false)
        let claimsOutput = try await callMCPTool(server, name: "core_claims", arguments: ["entity": .string("OpenClinic")])
        #expect(claimsOutput.contains("Swift"))
        #expect(!claimsOutput.contains("ConfidentialRx"))
        #expect(!claimsOutput.contains("Dr. Secret"))
        #expect(!claimsOutput.contains("MedicalOnlyEvidenceLeak"))
    }

    @Test("core_contradictions, core_changed, and core_trace never expose rows from blocked domains")
    func mcpToolsWithholdContradictionsChangesAndTracesFromBlockedDomains() async throws {
        let store = try await temporaryStore()
        let source = Source(
            kind: .manual,
            handle: "notes",
            displayName: "Notes",
            defaultAuthority: .directStatement,
            defaultDomain: .medical
        )
        try await store.upsert(source)

        let medicalObj = CoreObject(
            sourceID: source.id,
            kind: .note,
            externalID: "med-secret",
            title: "Cardiology Consult",
            text: "Blood pressure target is 110/70.",
            authoredAt: Date(),
            domain: .medical,
            authority: .directStatement
        )
        try await store.ingest([medicalObj])

        let medEntity = CoreEntity(kind: .concept, canonicalName: "SecretCondition", domain: .medical)
        try await store.upsert([medEntity])
        try await store.addAliases([
            EntityAlias(entityID: medEntity.id, surface: "SecretCondition", confidence: 1.0)
        ])

        let earlier = Date(timeIntervalSince1970: 1_740_000_000)
        let later = Date(timeIntervalSince1970: 1_750_000_000)
        let claimA = CoreClaim(
            subject: medEntity.id,
            predicate: Predicate.status,
            literal: "PrivateStageAlpha",
            confidence: 0.9,
            authority: .directStatement,
            derivation: .observed,
            validity: Validity(validFrom: earlier, observedAt: earlier),
            domain: .medical
        )
        let claimB = CoreClaim(
            subject: medEntity.id,
            predicate: Predicate.status,
            literal: "PrivateStageBeta",
            confidence: 0.9,
            authority: .directStatement,
            derivation: .observed,
            validity: Validity(validFrom: later, observedAt: later),
            domain: .medical
        )
        try await store.save([claimA, claimB])
        _ = try await BeliefEngine(store: store, now: Date()).reconcile()

        // Simulate a local user query that unlocked `.medical` and wrote a receipt with medical evidence.
        let medEvidence = Evidence(
            objectID: medicalObj.id,
            snippet: "Blood pressure target is 110/70.",
            authority: .directStatement
        )
        try await store.save([medEvidence])
        let localMedicalReceipt = Receipt(
            query: "what did my doctor say about SecretCondition?",
            queryClass: .factual,
            domainsAdmitted: [.medical, .personal],
            domainsBlocked: [],
            stages: [],
            objectsSearched: 1,
            objectsRetrieved: 1,
            evidenceAdmitted: 1,
            claimsConsulted: 1,
            contradictionsSurfaced: 1,
            model: nil,
            objectsTransmitted: 0,
            confidence: nil
        )
        try await store.save(localMedicalReceipt, evidence: [(medEvidence.id, 1.0)], claims: [claimB.id])

        let server = MCPServer(store: store, sensitiveDomainsUnlockable: false)

        let contradictionsOut = try await callMCPTool(server, name: "core_contradictions")
        #expect(!contradictionsOut.contains("PrivateStageAlpha"))
        #expect(!contradictionsOut.contains("PrivateStageBeta"))
        #expect(contradictionsOut == "No contradictions detected.")

        let changedOut = try await callMCPTool(server, name: "core_changed", arguments: ["days": .number(365)])
        #expect(!changedOut.contains("SecretCondition"))
        #expect(!changedOut.contains("PrivateStage"))
        #expect(changedOut == "No belief changes in the last 365 days.")

        let traceOut = try await callMCPTool(
            server,
            name: "core_trace",
            arguments: ["receipt": .string(localMedicalReceipt.shortCode)]
        )
        #expect(!traceOut.contains("Cardiology Consult"))
        #expect(!traceOut.contains("110/70"))
        #expect(!traceOut.contains("SecretCondition"))
        #expect(traceOut.contains("medical domain, which this server does not expose"))

        let dossierOut = try await callMCPTool(
            server,
            name: "core_dossier",
            arguments: ["entity": .string("SecretCondition")]
        )
        #expect(!dossierOut.contains("PrivateStageAlpha"))
        #expect(dossierOut.contains("medical domain, which this server does not expose"))

        let timelineOut = try await callMCPTool(
            server,
            name: "core_timeline",
            arguments: ["days": .number(365), "entity": .string("SecretCondition")]
        )
        #expect(timelineOut.contains("medical domain, which this server does not expose"))
    }

    @Test("Every MCP JSON-RPC endpoint and every tool executes end-to-end and enforces schema and firewall contracts")
    func allMCPEndpointsAndToolsEndToEnd() async throws {
        let store = try await temporaryStore()
        let source = Source(
            kind: .filesystem,
            handle: "workspace",
            displayName: "Workspace",
            defaultAuthority: .authoredArtifact,
            defaultDomain: .project
        )
        try await store.upsert(source)

        let repoObj = CoreObject(
            sourceID: source.id,
            kind: .repository,
            externalID: "Gunnarguy/OpenCore",
            title: "OpenCore",
            text: "OpenCore is an evidence-native store.",
            authoredAt: Date(),
            domain: .project,
            authority: .authoredArtifact,
            metadata: ["full_name": "Gunnarguy/OpenCore", "language": "Swift", "archived": "false"]
        )
        let doc = CoreObject(
            sourceID: source.id,
            kind: .file,
            externalID: "OpenCore/SPEC.md",
            title: "SPEC.md",
            text: "# OpenCore\nOpenCore is an evidence-native store built with Swift and SQLite.\n\nStatus: Active\nPrimary Language: Swift\nStack: Swift, SQLite",
            authoredAt: Date(),
            domain: .project,
            authority: .authoredArtifact,
            metadata: ["extension": "md"]
        )
        let commit = CoreObject(
            sourceID: source.id,
            kind: .commit,
            externalID: "Gunnarguy/OpenCore@abc1234",
            title: "Add MCP server endpoints",
            text: "Add MCP server endpoints and domain firewall tests.",
            authoredAt: Date(),
            domain: .project,
            authority: .authoredArtifact,
            metadata: ["repo": "Gunnarguy/OpenCore", "author": "Gunnar Hostetler"]
        )
        let outcome = try await IngestPipeline(store: store).run(objects: [repoObj, doc, commit])
        #expect(outcome.ingest.inserted == 3)
        #expect(outcome.claims >= 2)

        let server = MCPServer(store: store, sensitiveDomainsUnlockable: false)

        func rpc(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
            var dict: [String: JSONValue] = [
                "jsonrpc": .string("2.0"),
                "id": .number(1),
                "method": .string(method),
            ]
            if let params { dict["params"] = params }
            let data = try JSONEncoder().encode(JSONValue.object(dict))
            let req = try JSONDecoder().decode(RPCRequest.self, from: data)
            return try await server.handle(req)
        }

        // 1. initialize
        let initRes = try await rpc("initialize", params: .object(["protocolVersion": .string("2025-11-25")]))
        #expect(initRes["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(initRes["serverInfo"]?["name"]?.stringValue == "opencore")

        // 2. ping
        let pingRes = try await rpc("ping")
        #expect(pingRes.objectValue?.isEmpty == true)

        // 3. tools/list
        let toolsRes = try await rpc("tools/list")
        let toolNames = (toolsRes["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(Set(toolNames) == [
            "core_ask",
            "core_search",
            "core_claims",
            "core_contradictions",
            "core_changed",
            "core_trace",
            "core_dossier",
            "core_timeline",
        ])

        // 4. resources/list & prompts/list
        let resList = try await rpc("resources/list")
        #expect(resList["resources"]?.arrayValue?.isEmpty == true)
        let promptsList = try await rpc("prompts/list")
        #expect(promptsList["prompts"]?.arrayValue?.isEmpty == true)

        // 5. core_ask + core_trace
        let askOut = try await callMCPTool(server, name: "core_ask", arguments: ["query": .string("What is OpenCore built with?")])
        #expect(askOut.contains("Swift"))
        #expect(askOut.contains("--- receipt oc_"))
        let receiptCode = askOut
            .components(separatedBy: "--- receipt ")
            .dropFirst()
            .first?
            .components(separatedBy: " ---")
            .first ?? ""
        #expect(receiptCode.hasPrefix("oc_"))

        let traceOut = try await callMCPTool(server, name: "core_trace", arguments: ["receipt": .string(receiptCode)])
        #expect(traceOut.contains("OpenCore is an evidence-native store"))

        // 6. core_search
        let searchOut = try await callMCPTool(server, name: "core_search", arguments: ["query": .string("evidence-native"), "limit": .number(4)])
        #expect(searchOut.contains("SPEC.md"))

        // 7. core_claims
        let claimsOut = try await callMCPTool(server, name: "core_claims", arguments: ["entity": .string("OpenCore")])
        #expect(claimsOut.contains("OpenCore"))
        #expect(claimsOut.contains("Swift"))

        // 8. core_dossier
        let dossierOut = try await callMCPTool(server, name: "core_dossier", arguments: ["entity": .string("OpenCore")])
        #expect(dossierOut.contains("# OpenCore (project · project)"))
        #expect(dossierOut.contains("## Believed now"))
        #expect(dossierOut.contains("Swift"))

        // 9. core_timeline
        let timelineOut = try await callMCPTool(server, name: "core_timeline", arguments: ["days": .number(30), "entity": .string("OpenCore")])
        #expect(timelineOut.contains("OpenCore"))

        // 10. core_changed & core_contradictions
        let changedOut = try await callMCPTool(server, name: "core_changed", arguments: ["days": .number(30)])
        #expect(changedOut.contains("OpenCore"))
        let contradictionsOut = try await callMCPTool(server, name: "core_contradictions", arguments: ["unresolved_only": .bool(true)])
        #expect(contradictionsOut == "No unresolved contradictions.")

        // 11. Error paths: methodNotFound, missing tool name, unknown tool, missing required argument
        await #expect(throws: RPCError.self) {
            _ = try await rpc("unknown/method")
        }
        await #expect(throws: RPCError.self) {
            _ = try await rpc("tools/call", params: .object([:]))
        }
        await #expect(throws: RPCError.self) {
            _ = try await callMCPTool(server, name: "nonexistent_tool")
        }
        await #expect(throws: RPCError.self) {
            _ = try await callMCPTool(server, name: "core_ask", arguments: [:])
        }
    }
}

// The bug: a belief version's reason is stored text naming the value it replaced, and `core_claims`
// and `core_changed` gate only on the version's own claim. A slot's subject ignores domain, so a
// project-domain plan following a restricted one printed the restricted sentence over MCP. Making
// `next_action` functional gave that text a belief for the first time.
@Test("a belief reason never quotes the restricted value it replaced")
func beliefReasonDoesNotQuoteBlockedPredecessor() async throws {
    let store = try await temporaryStore()
    let subject = CoreEntity(kind: .project, canonicalName: "Quillberry", domain: .project)
    try await store.upsert([subject])
    let start = Date().addingTimeInterval(-5 * 86_400)
    func nextAction(_ value: String, day: Double, domain: Domain) -> CoreClaim {
        let at = start.addingTimeInterval(day * 86_400)
        return CoreClaim(subject: subject.id, predicate: Predicate.nextAction, literal: value, confidence: 0.9, authority: .authoredArtifact, derivation: .observed, validity: Validity(validFrom: at, observedAt: at), domain: domain)
    }

    let steps = [
        (nextAction("Ring the zebrafinch clinic", day: 0, domain: .restricted), 0.5),
        (nextAction("Write the public note", day: 1, domain: .project), 1.5),
        (nextAction("Publish the public note", day: 2, domain: .project), 2.5),
    ]
    for (claim, decided) in steps {
        try await store.save([claim])
        _ = try await BeliefEngine(store: store, now: start.addingTimeInterval(decided * 86_400)).reconcile()
    }
    let history = try await store.beliefHistory(key: steps[0].0.claimKey)
    #expect(history.count == 3, "the fixture must version the slot or this proves nothing")
    #expect(history[1].reason.contains("zebrafinch"), "the local record keeps the sentence")

    let server = MCPServer(store: store, sensitiveDomainsUnlockable: false)
    let changed = try await callMCPTool(server, name: "core_changed", arguments: ["days": .number(30)])
    #expect(changed.contains("Write the public note"), "the admitted version still shows")
    #expect(!changed.contains("zebrafinch"))
    let claims = try await callMCPTool(server, name: "core_claims", arguments: ["entity": .string("Quillberry")])
    #expect(claims.contains("Publish the public note"))
    #expect(claims.contains("v3: changed from 'Write the public note'"), "a reason that quotes nothing blocked is left alone")
    #expect(!claims.contains("zebrafinch"))
}
