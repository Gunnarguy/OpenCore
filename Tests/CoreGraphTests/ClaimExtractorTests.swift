import AppKit
import CoreIngest
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

@Test("an explicit Archived banner in a README outranks an inferred active status and carries a verified byte span")
func readmeStatusContradictsInferredRepositoryStatus() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let recentPush = Date()
    let repoObject = CoreObject(
        sourceID: source.id,
        kind: .repository,
        externalID: "gunnarguy/OpenAssistant",
        title: "OpenAssistant",
        text: "gunnarguy/OpenAssistant\nLegacy SwiftUI client.",
        authoredAt: recentPush,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "archived": "false",
            "pushed_at": ISO8601DateFormatter().string(from: recentPush),
        ]
    )
    let readmeText = """
    # OpenAssistant

    <p align="center">
      <strong>Archived SwiftUI client for the OpenAI Assistants API v2.</strong>
    </p>

    Built with SwiftUI and SQLite.
    """
    let readmeObject = CoreObject(
        sourceID: source.id,
        kind: .document,
        externalID: "gunnarguy/OpenAssistant#readme",
        title: "OpenAssistant — README",
        text: readmeText,
        authoredAt: recentPush,
        domain: .project,
        authority: .authoredArtifact,
        metadata: ["repo": "gunnarguy/OpenAssistant"]
    )

    let outcome = try await IngestPipeline(store: store).run(objects: [repoObject, readmeObject])
    #expect(outcome.contradictions == 1)

    let subject = CoreEntity(kind: .project, canonicalName: "OpenAssistant", domain: .project).id
    let belief = try #require(try await store.currentBelief(key: "\(subject.value)|\(Predicate.status)"))
    let winningClaim = try #require(try await store.claim(belief.claimID))

    #expect(winningClaim.literal == "archived")
    #expect(winningClaim.authority == .authoredArtifact)
    #expect(winningClaim.derivation == .observed)

    let supporting = try #require(try await store.evidence(for: winningClaim.id, stance: .supports).first?.0)
    let refuting = try await store.evidence(for: winningClaim.id, stance: .refutes).first?.0
    #expect(refuting != nil)

    let byteRange = try #require(supporting.range)
    let utf8Bytes = Array(readmeText.utf8)
    let sliced = String(decoding: utf8Bytes[byteRange], as: UTF8.self)
    #expect(sliced.contains("Archived SwiftUI client"))
}

@Test("REA evidence bundles and FINDINGS.md extract observed and inferred claims with byte spans while skipping unknown")
func reaEvidenceAndFindingsExtraction() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let bundleJSON = """
    {
      "records": [
        {
          "predicate_type": "rea.analysis",
          "evidence_id": "ev_24041f00789e9231f0a51d68702be76a0b34c2cb096444cb7fb6b4209bb64935",
          "confidence": "observed",
          "subject": { "name": "probe_secret" },
          "provider": { "name": "Ghidra" },
          "normalized_result": {
            "procedure": {
              "name": "_check_passcode",
              "address": "0x100000460",
              "signature": "int _check_passcode(char * param_1)"
            }
          }
        }
      ]
    }
    """
    let bundleObject = CoreObject(
        sourceID: source.id,
        kind: .file,
        externalID: "evidence/2026-10-19-probe-secret.json",
        title: "2026-10-19-probe-secret.json",
        text: bundleJSON,
        domain: .project,
        authority: .authoredArtifact
    )

    let findingsMD = """
    # REA Findings

    ## probe_secret (`/tmp/rea-smoke/probe_secret`, Mach-O arm64)

    | # | Class | Finding | Evidence |
    |---|---|---|---|
    | 1 | `seen` | Binary contains exported procedure `_check_passcode` (`0x100000460`) | Ghidra (`ev_24041f00`) |
    | 2 | `inferred` | Passcode decodes via XOR 0x5a to `"REA-2026!"` | Constant table (`ev_24041f00`) |
    | 3 | `unknown` | Whether an external launcher invokes `_check_passcode` | Symbol table (`ev_3c91d2ab`) |
    """
    let findingsObject = CoreObject(
        sourceID: source.id,
        kind: .file,
        externalID: "FINDINGS.md",
        title: "FINDINGS.md",
        text: findingsMD,
        domain: .project,
        authority: .authoredArtifact
    )

    _ = try await IngestPipeline(store: store).run(objects: [bundleObject, findingsObject])

    let probeEntity = CoreEntity(kind: .project, canonicalName: "probe_secret", domain: .project).id
    let probeClaims = try await store.claims(subject: probeEntity, currentOnly: true)

    // `seen` and `inferred` rows become claims; `unknown` never does.
    #expect(probeClaims.contains { $0.predicate == Predicate.hasComponent })
    #expect(probeClaims.contains { $0.predicate == Predicate.uses })
    #expect(probeClaims.contains { $0.predicate == Predicate.describes && $0.derivation == .observed })
    #expect(probeClaims.contains { $0.predicate == Predicate.describes && $0.derivation == .inferred })
    #expect(!probeClaims.contains { ($0.literal ?? "").contains("external launcher") })
}

@Test("a local structured document extracts byte-verified claims and contradicts a GitHub repository claim across sources")
func localStructuredDocumentCrossSourceContradiction() async throws {
    let store = try await temporaryStore()
    let filesSource = Source(
        kind: .filesystem,
        handle: "Docs",
        displayName: "Files · Docs",
        defaultAuthority: .authoredArtifact,
        defaultDomain: .project
    )
    try await store.upsert(source)
    try await store.upsert(filesSource)

    let olderDate = Date(timeIntervalSince1970: 1_740_000_000)
    let newerDate = Date(timeIntervalSince1970: 1_755_000_000)

    let githubRepo = CoreObject(
        sourceID: source.id,
        kind: .repository,
        externalID: "gunnarguy/TelemetryRig",
        title: "TelemetryRig",
        text: "gunnarguy/TelemetryRig\n Prototype profiler.",
        authoredAt: olderDate,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "language": "Python",
            "archived": "false",
            "pushed_at": ISO8601DateFormatter().string(from: olderDate),
        ]
    )

    let localSpecText = """
    # TelemetryRig

    Project: TelemetryRig
    Status: archived
    Primary Language: Rust
    Built with: SQLite, Docker
    Owner: gunnarguy
    """
    let localSpec = CoreObject(
        sourceID: filesSource.id,
        kind: .file,
        externalID: "/tmp/Docs/TelemetryRig/STATE.md",
        title: "STATE.md",
        text: localSpecText,
        authoredAt: newerDate,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "root": "/tmp/Docs",
            "extension": "md",
            "relative_path": "TelemetryRig/STATE.md",
        ]
    )

    let outcome = try await IngestPipeline(store: store).run(objects: [githubRepo, localSpec])
    // Both `status` (active vs archived) and `primary_language` (Python vs Rust) contradict across
    // the GitHub and Filesystem sources, and the newer local spec supersedes the older repo state.
    #expect(outcome.contradictions >= 2)

    let subject = CoreEntity(kind: .project, canonicalName: "TelemetryRig", domain: .project).id
    let statusBelief = try #require(try await store.currentBelief(key: "\(subject.value)|\(Predicate.status)"))
    let winningStatus = try #require(try await store.claim(statusBelief.claimID))
    #expect(winningStatus.literal == "archived")

    let langBelief = try #require(try await store.currentBelief(key: "\(subject.value)|\(Predicate.primaryLanguage)"))
    let winningLang = try #require(try await store.claim(langBelief.claimID))
    let rustEntity = CoreEntity(kind: .technology, canonicalName: "Rust", domain: .publicRecord).id
    #expect(winningLang.objectEntity == rustEntity)

    let supporting = try #require(try await store.evidence(for: winningLang.id, stance: .supports).first?.0)
    let byteRange = try #require(supporting.range)
    let sliced = String(decoding: Array(localSpecText.utf8)[byteRange], as: UTF8.self)
    #expect(sliced == "Primary Language: Rust")
}

@Test("FilesystemConnector extracts multi-page PDF text layers with page markers and byte-verified claims")
func filesystemConnectorExtractsMultiPagePDF() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-pdf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let pdfURL = tempDir.appendingPathComponent("Spec.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        Issue.record("Could not create CGContext for PDF generation")
        return
    }

    let pages = [
        "Project: VaultEngine\nStatus: active\nPrimary Language: Swift",
        "Built with: SQLite and SwiftUI for local persistence.",
    ]
    for pageText in pages {
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attr = NSAttributedString(
            string: pageText,
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        attr.draw(in: CGRect(x: 36, y: 600, width: 500, height: 150))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()

    let connector = FilesystemConnector(
        handle: "pdf-test",
        roots: [FilesystemConnector.Root(url: tempDir, domain: .project)]
    )
    let batch = try await connector.fetch(since: nil, cursor: nil, log: { _ in })
    let pdfObject = try #require(batch.objects.first)

    #expect(pdfObject.metadata["extension"] == "pdf")
    #expect(pdfObject.metadata["pages"] == "2")
    #expect(pdfObject.text.contains("[Page 1]"))
    #expect(pdfObject.text.contains("[Page 2]"))
    #expect(pdfObject.text.contains("VaultEngine"))

    let store = try await temporaryStore()
    try await store.upsert(connector.source)
    _ = try await IngestPipeline(store: store).run(objects: [pdfObject])

    let vault = CoreEntity(kind: .project, canonicalName: "VaultEngine", domain: .project).id
    let claims = try await store.claims(subject: vault, currentOnly: true)
    #expect(claims.contains { $0.predicate == Predicate.status && $0.literal == "active" })
    #expect(claims.contains { $0.predicate == Predicate.builtWith })
}

@Test("Nested STATE.md and CLAUDE.md extract byte-verified objective, last_verified_commit, next_action, and verify_command claims and detect stale handoff contradictions")
func nestedAnchorDocsExtractEngineeringStateAndContradictions() async throws {
    let store = try await temporaryStore()
    let fsSource = Source(
        kind: .filesystem,
        handle: "GitHub-Workspace",
        displayName: "Files · GitHub-Workspace",
        defaultAuthority: .authoredArtifact,
        defaultDomain: .project
    )
    try await store.upsert(fsSource)

    let stateText = """
    # OpenCore - Current State

    ## Current Objective
    Consolidate the 15-item sidebar into 4 workspaces and integrate /usr/bin/fm.

    ## Last Verified State
    - **Last verified commit**: `d3c0615`

    ## Exact Next Action
    1. Run swift test and launch OpenCore.app.
    """

    let claudeText = """
    # OpenCore - Operating Protocol

    ## Verify
    ```bash
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /private/tmp/opencore-build
    ```
    """

    let staleHandoffText = """
    # OpenCore - Handoff

    - **Last verified commit**: `75267a2`
    """

    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let stateObj = CoreObject(
        sourceID: fsSource.id,
        kind: .file,
        externalID: "/Users/dev/Documents/GitHub/OpenCore/Docs/ai/STATE.md",
        title: "STATE.md",
        text: stateText,
        authoredAt: t0,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "root": "/Users/dev/Documents/GitHub/OpenCore",
            "relative_path": "Docs/ai/STATE.md",
        ]
    )
    let claudeObj = CoreObject(
        sourceID: fsSource.id,
        kind: .file,
        externalID: "/Users/dev/Documents/GitHub/OpenCore/CLAUDE.md",
        title: "CLAUDE.md",
        text: claudeText,
        authoredAt: t0,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "root": "/Users/dev/Documents/GitHub/OpenCore",
            "relative_path": "CLAUDE.md",
        ]
    )
    let handoffObj = CoreObject(
        sourceID: fsSource.id,
        kind: .file,
        externalID: "/Users/dev/Documents/GitHub/OpenCore/HANDOFF.md",
        title: "HANDOFF.md",
        text: staleHandoffText,
        authoredAt: t0,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "root": "/Users/dev/Documents/GitHub/OpenCore",
            "relative_path": "HANDOFF.md",
        ]
    )

    _ = try await IngestPipeline(store: store).run(objects: [stateObj, claudeObj, handoffObj])

    let openCore = CoreEntity(kind: .project, canonicalName: "OpenCore", domain: .project).id
    let claims = try await store.claims(subject: openCore, currentOnly: false)

    #expect(claims.contains {
        $0.predicate == Predicate.objective
            && $0.literal == "Consolidate the 15-item sidebar into 4 workspaces and integrate /usr/bin/fm."
    })
    #expect(claims.contains {
        $0.predicate == Predicate.lastVerifiedCommit && $0.literal == "d3c0615"
    })
    #expect(claims.contains {
        $0.predicate == Predicate.nextAction
            && $0.literal == "Run swift test and launch OpenCore.app."
    })
    #expect(claims.contains {
        $0.predicate == Predicate.verifyCommand
            && ($0.literal?.contains("swift test --scratch-path /private/tmp/opencore-build") == true)
    })

    // Equal-timestamp disagreement between STATE.md (`d3c0615`) and HANDOFF.md (`75267a2`)
    // on functional predicate `last_verified_commit` must be recorded as a contradiction.
    let contradictions = try await store.contradictions(unresolvedOnly: false)
    #expect(contradictions.count == 1)
}

@Test("FilesystemConnector supports single-file roots, excludes secret files, and ClaimExtractor links Claude memory files and Current State headings to their repository entity")
func singleFileRootExcludesSecretsAndExtractsClaudeMemoryClaims() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-mem-\(UUID().uuidString)", isDirectory: true)
    let repoDir = tempDir.appendingPathComponent("Documents/GitHub/OpenCore/Docs/ai", isDirectory: true)
    let memDir = tempDir.appendingPathComponent(".claude/projects/-Users-example-Documents-GitHub-OpenCore/memory", isDirectory: true)
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let stateFile = repoDir.appendingPathComponent("STATE.md")
    try """
    # Current State

    Last verified commit: 36a2b8e

    ## Objective
    Pair plain-English explanations with engine jargon across all views.
    """.write(to: stateFile, atomically: true, encoding: .utf8)

    let memoryFile = memDir.appendingPathComponent("opencore-thesis.md")
    try """
    ---
    name: opencore-thesis
    description: "What OpenCore is for, and the strategic disagreement behind starting it"
    ---

    OpenCore is an evidence-native personal intelligence store in Swift 6.
    """.write(to: memoryFile, atomically: true, encoding: .utf8)

    let secretEnvFile = memDir.appendingPathComponent(".env")
    try "SECRET_TOKEN=do_not_ingest".write(to: secretEnvFile, atomically: true, encoding: .utf8)
    let secretKeyFile = memDir.appendingPathComponent("AuthKey_123.p8")
    try "PRIVATE KEY".write(to: secretKeyFile, atomically: true, encoding: .utf8)

    let connector = FilesystemConnector(
        handle: "Cross-Agent-Test",
        roots: [
            FilesystemConnector.Root(url: stateFile, domain: .project),
            FilesystemConnector.Root(url: memDir, domain: .project),
        ]
    )
    let batch = try await connector.fetch(since: nil, cursor: nil, log: { _ in })
    #expect(batch.objects.count == 2)
    #expect(batch.objects.contains { $0.externalID == stateFile.resolvingSymlinksInPath().path })
    #expect(batch.objects.contains { $0.externalID == memoryFile.resolvingSymlinksInPath().path })
    #expect(!batch.objects.contains { $0.title.contains(".env") || $0.title.contains(".p8") })

    let store = try await temporaryStore()
    try await store.upsert(connector.source)
    _ = try await IngestPipeline(store: store).run(objects: batch.objects)

    let openCore = CoreEntity(kind: .project, canonicalName: "OpenCore", domain: .project).id
    let claims = try await store.claims(subject: openCore, currentOnly: true)
    #expect(claims.contains { $0.predicate == Predicate.lastVerifiedCommit && $0.literal == "36a2b8e" })
    #expect(claims.contains {
        $0.predicate == Predicate.describes
            && ($0.literal?.contains("[Claude Memory · opencore-thesis] What OpenCore is for") == true)
    })
}

@Test("Model-proposed claims enforce exact UTF-8 byte spans, carry Authority.modelInference, are outranked by deterministic rules, and survive rebuild")
func modelProposedClaimsEnforceByteRangeAreOutrankedByRulesAndSurviveRebuild() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    let noteText = """
    # Architecture Note

    ShaderForge is currently in maintenance while we benchmark the GPU pipeline.
    The renderer uses Metal for compute dispatch.
    """

    let proposals: [ProposedClaimRecord] = [
        ProposedClaimRecord(
            subject: "ShaderForge",
            subjectKind: .project,
            predicate: Predicate.status,
            value: "maintenance",
            valueKind: nil,
            verbatimQuote: "ShaderForge is currently in maintenance",
            confidence: 0.95
        ),
        ProposedClaimRecord(
            subject: "ShaderForge",
            subjectKind: .project,
            predicate: Predicate.uses,
            value: "Metal",
            valueKind: .technology,
            verbatimQuote: "The renderer uses Metal for compute dispatch.",
            confidence: 0.88
        ),
        ProposedClaimRecord(
            subject: "ShaderForge",
            subjectKind: .project,
            predicate: Predicate.status,
            value: "deprecated",
            valueKind: nil,
            verbatimQuote: "ShaderForge was deprecated in 2024.",
            confidence: 0.99
        ),
        ProposedClaimRecord(
            subject: "ShaderForge",
            subjectKind: .project,
            predicate: "invented_predicate",
            value: "foo",
            valueKind: nil,
            verbatimQuote: "ShaderForge is currently in maintenance",
            confidence: 0.90
        ),
    ]
    let encoded = try String(data: JSONEncoder().encode(proposals), encoding: .utf8)!

    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let noteObject = CoreObject(
        sourceID: source.id,
        kind: .note,
        externalID: "note/shaderforge-1",
        title: "ShaderForge Note",
        text: noteText,
        authoredAt: t0,
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "model_proposed_claims": encoded,
        ]
    )

    _ = try await IngestPipeline(store: store).run(objects: [noteObject])

    let shaderForge = CoreEntity(kind: .project, canonicalName: "ShaderForge", domain: .project).id
    let claims = try await store.claims(subject: shaderForge, currentOnly: false)

    // 1. Fabricated quote ("deprecated") and unknown predicate ("invented_predicate") are rejected.
    #expect(!claims.contains { $0.literal == "deprecated" })
    #expect(!claims.contains { $0.predicate == "invented_predicate" })

    // 2. Byte-verified proposals become Authority.modelInference claims with exact UTF-8 byte ranges.
    let modelStatus = try #require(claims.first { $0.predicate == Predicate.status && $0.literal == "maintenance" })
    #expect(modelStatus.authority == .modelInference)
    #expect(modelStatus.derivation == .inferred)
    #expect(modelStatus.confidence <= 0.84)

    let evidence = try #require(try await store.evidence(for: modelStatus.id, stance: .supports).first?.0)
    let range = try #require(evidence.range)
    let sliced = String(decoding: Array(noteText.utf8)[range], as: UTF8.self)
    #expect(sliced == "ShaderForge is currently in maintenance")

    // 3. Deterministic rule (authoredArtifact) outranks Authority.modelInference even when older.
    let specObject = CoreObject(
        sourceID: source.id,
        kind: .file,
        externalID: "/tmp/ShaderForge/STATE.md",
        title: "STATE.md",
        text: "# ShaderForge\n\nProject: ShaderForge\nStatus: active\n",
        authoredAt: t0.addingTimeInterval(-3600),
        domain: .project,
        authority: .authoredArtifact,
        metadata: [
            "root": "/tmp",
            "relative_path": "ShaderForge/STATE.md",
        ]
    )
    _ = try await IngestPipeline(store: store).run(objects: [specObject])

    let statusBelief = try #require(try await store.currentBelief(key: "\(shaderForge.value)|\(Predicate.status)"))
    let winningStatus = try #require(try await store.claim(statusBelief.claimID))
    #expect(winningStatus.literal == "active")
    #expect(winningStatus.authority == .authoredArtifact)

    // 4. Rebuild from floor objects preserves model-proposed claims deterministically.
    try await store.dropDerivedLayers()
    _ = try await IngestPipeline(store: store).rederive()

    let rebuiltClaims = try await store.claims(subject: shaderForge, currentOnly: false)
    #expect(rebuiltClaims.contains { $0.predicate == Predicate.status && $0.literal == "maintenance" && $0.authority == .modelInference })
    #expect(rebuiltClaims.contains { $0.predicate == Predicate.uses && $0.authority == .modelInference })
}

@Test func visionOCRImageIngestDerivesClaims() async throws {
    let store = try await temporaryStore()
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opencore-vision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let imageURL = tempDir.appendingPathComponent("VisionRig-spec.png")
    let size = NSSize(width: 900, height: 320)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath.fill(NSRect(origin: .zero, size: size))
    let lines = "Project: VisionRig\nStatus: active\nLanguage: Swift"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    (lines as NSString).draw(in: NSRect(x: 36, y: 36, width: 820, height: 250), withAttributes: attrs)
    image.unlockFocus()

    let tiffData = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiffData))
    let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
    try pngData.write(to: imageURL)

    let connector = FilesystemConnector(
        handle: "vision-test",
        roots: [FilesystemConnector.Root(url: imageURL, domain: .project)]
    )
    try await store.upsert(connector.source)
    let batch = try await connector.fetch(since: nil, cursor: nil) { _ in }
    #expect(batch.objects.count == 1)
    let ocrObject = try #require(batch.objects.first)
    #expect(ocrObject.metadata["ocr"] == "vision")
    #expect(ocrObject.text.contains("VisionRig"))

    _ = try await IngestPipeline(store: store).run(objects: batch.objects)
    let visionRig = CoreEntity(kind: .project, canonicalName: "VisionRig", domain: .project).id
    let claims = try await store.claims(subject: visionRig, currentOnly: false)
    #expect(claims.contains { $0.predicate == Predicate.status && $0.literal == "active" })
}
