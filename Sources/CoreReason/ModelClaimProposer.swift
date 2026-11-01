import CoreGraph
import CoreModel
import CoreStore
import CoreTelemetry
import Foundation

/// On-device model-proposed claim extraction (`v0.6` #11).
///
/// Lives in `CoreReason` because `CoreReason` is the only layer allowed to reach a model.
/// Every candidate proposed by `/usr/bin/fm` must pass two hard gates before entering the store:
/// 1. Its `predicate` must belong to `Predicate.allVocabulary`.
/// 2. Its `verbatimQuote` must pass `ClaimExtractor.verifiedByteRange(of:in:)` against the
///    floor `CoreObject.text` (an exact UTF-8 byte-slice round-trip).
///
/// Verified proposals are persisted in `object.metadata["model_proposed_claims"]` and derived
/// through `IngestPipeline` at `Authority.modelInference` (ordinal tier `0`, outranked by every
/// deterministic rule and human assertion) so `opencore rebuild` can reconstruct them from the
/// floor without calling the model again.
public struct ModelClaimProposer: Sendable {
    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    public struct ProposalOutcome: Sendable, Equatable {
        public var objectID: ObjectID
        public var objectTitle: String
        public var candidatesProposed: Int
        public var verifiedProposals: [ProposedClaimRecord]
        public var rejectedUnverifiedSpan: Int
        public var rejectedInvalidPredicate: Int
        public var claimsWritten: Int
        public var beliefsWritten: Int
        public var contradictionsFound: Int
        public var modelName: String

        public init(
            objectID: ObjectID,
            objectTitle: String,
            candidatesProposed: Int,
            verifiedProposals: [ProposedClaimRecord],
            rejectedUnverifiedSpan: Int,
            rejectedInvalidPredicate: Int,
            claimsWritten: Int,
            beliefsWritten: Int,
            contradictionsFound: Int,
            modelName: String
        ) {
            self.objectID = objectID
            self.objectTitle = objectTitle
            self.candidatesProposed = candidatesProposed
            self.verifiedProposals = verifiedProposals
            self.rejectedUnverifiedSpan = rejectedUnverifiedSpan
            self.rejectedInvalidPredicate = rejectedInvalidPredicate
            self.claimsWritten = claimsWritten
            self.beliefsWritten = beliefsWritten
            self.contradictionsFound = contradictionsFound
            self.modelName = modelName
        }
    }

    /// JSON Schema for `/usr/bin/fm respond --schema`.
    private static let fmProposedClaimsSchemaJSON = """
    {
      "title" : "ProposedClaimBatch",
      "type" : "object",
      "properties" : {
        "claims" : {
          "type" : "array",
          "items" : {
            "$ref" : "#/$defs/ProposedClaimItem"
          }
        }
      },
      "required" : [
        "claims"
      ],
      "additionalProperties" : false,
      "$defs" : {
        "ProposedClaimItem" : {
          "title" : "ProposedClaimItem",
          "type" : "object",
          "properties" : {
            "subject" : {
              "type" : "string",
              "description" : "Canonical name of the project, person, technology, or concept."
            },
            "subjectKind" : {
              "type" : "string",
              "enum" : ["project", "person", "organization", "technology", "concept", "place"]
            },
            "predicate" : {
              "type" : "string",
              "enum" : [
                "uses", "built_with", "depends_on", "authored_by", "works_at",
                "status", "describes", "prefers", "released_version",
                "primary_language", "part_of", "contributed_to", "has_component",
                "objective", "last_verified_commit", "next_action", "verify_command"
              ]
            },
            "value" : {
              "type" : "string",
              "description" : "Target entity name or literal fact stated by the quote."
            },
            "valueIsEntity" : {
              "type" : "boolean",
              "description" : "True if value is a named technology, project, person, or component."
            },
            "valueKind" : {
              "type" : "string",
              "enum" : ["project", "person", "organization", "technology", "concept", "place"]
            },
            "verbatimQuote" : {
              "type" : "string",
              "description" : "Exact character-for-character substring copied from the source text."
            }
          },
          "required" : [
            "subject", "subjectKind", "predicate", "value", "valueIsEntity", "valueKind", "verbatimQuote"
          ],
          "additionalProperties" : false
        }
      }
    }
    """

    private static let proposerInstructions = """
    Extract factual claims from the provided document.
    Rules:
    1. Only extract facts explicitly stated in the text.
    2. `verbatimQuote` MUST be copied character-for-character from the source text. Any paraphrased quote will be rejected by a UTF-8 byte-range check.
    3. Use only the allowed `predicate` values.
    4. Keep `subject` concise (e.g., repository or project name, person name, or concept name).
    """

    private struct FMProposedBatch: Decodable {
        struct Item: Decodable {
            let subject: String
            let subjectKind: String
            let predicate: String
            let value: String
            let valueIsEntity: Bool
            let valueKind: String
            let verbatimQuote: String
        }
        let claims: [Item]?
    }

    /// Propose, byte-verify, and ingest `Authority.modelInference` claims for a single `CoreObject`.
    @discardableResult
    public func propose(
        from object: CoreObject,
        defaultSubjectHint: String? = nil,
        customCandidates: [ProposedClaimRecord]? = nil
    ) async throws -> ProposalOutcome {
        try await Telemetry.span("propose.claims", .reason, attributes: ["object": object.id.value]) { span in
            let rawCandidates: [ProposedClaimRecord]
            let usedModel: String

            if let customCandidates {
                rawCandidates = customCandidates
                usedModel = "Custom Proposal Input"
            } else if let fmCandidates = await Self.generateProposalsWithFM(
                object: object,
                subjectHint: defaultSubjectHint
            ), !fmCandidates.isEmpty {
                rawCandidates = fmCandidates
                usedModel = Conversation.fmCLIModelIdentity
            } else {
                rawCandidates = Self.heuristicProseProposals(from: object, subjectHint: defaultSubjectHint)
                usedModel = "Deterministic Prose Fallback"
            }

            span.set("candidates", rawCandidates.count)

            var verified: [ProposedClaimRecord] = ClaimExtractor.decodedModelProposals(from: object)
            var rejectedSpan = 0
            var rejectedPredicate = 0

            for candidate in rawCandidates {
                let predicate = candidate.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Predicate.allVocabulary.contains(predicate) else {
                    rejectedPredicate += 1
                    continue
                }
                let quote = candidate.verbatimQuote.trimmingCharacters(in: .whitespacesAndNewlines)
                // A different line mentioning the value cannot rescue a fabricated quote.
                // For example, "Do not use Redis" does not support "ProjectA uses Redis".
                guard !quote.isEmpty,
                      ClaimExtractor.verifiedByteRange(of: quote, in: object.text) != nil
                else {
                    rejectedSpan += 1
                    continue
                }

                let cleanRecord = ProposedClaimRecord(
                    subject: candidate.subject.trimmingCharacters(in: .whitespacesAndNewlines),
                    subjectKind: candidate.subjectKind,
                    predicate: predicate,
                    value: candidate.value.trimmingCharacters(in: .whitespacesAndNewlines),
                    valueKind: candidate.valueKind,
                    verbatimQuote: quote,
                    confidence: min(0.84, max(0.30, candidate.confidence))
                )
                if !verified.contains(where: {
                    $0.subject.caseInsensitiveCompare(cleanRecord.subject) == .orderedSame
                        && $0.predicate == cleanRecord.predicate
                        && $0.value.caseInsensitiveCompare(cleanRecord.value) == .orderedSame
                }) {
                    verified.append(cleanRecord)
                }
            }

            span.set("verified", verified.count)
            span.set("rejected.span", rejectedSpan)
            span.set("rejected.predicate", rejectedPredicate)

            guard !verified.isEmpty else {
                return ProposalOutcome(
                    objectID: object.id,
                    objectTitle: object.title,
                    candidatesProposed: rawCandidates.count,
                    verifiedProposals: [],
                    rejectedUnverifiedSpan: rejectedSpan,
                    rejectedInvalidPredicate: rejectedPredicate,
                    claimsWritten: 0,
                    beliefsWritten: 0,
                    contradictionsFound: 0,
                    modelName: usedModel
                )
            }

            let encodedJSON = (try? JSONEncoder().encode(verified))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            let updatedObject = try await store.updateObjectMetadata(
                object.id,
                merging: [ClaimExtractor.modelProposedClaimsMetadataKey: encodedJSON]
            ) ?? {
                var copy = object
                copy.metadata[ClaimExtractor.modelProposedClaimsMetadataKey] = encodedJSON
                return copy
            }()

            let pipelineOutcome = try await IngestPipeline(store: store)
                .run(objects: [updatedObject], storeObjects: false)

            return ProposalOutcome(
                objectID: object.id,
                objectTitle: object.title,
                candidatesProposed: rawCandidates.count,
                verifiedProposals: verified,
                rejectedUnverifiedSpan: rejectedSpan,
                rejectedInvalidPredicate: rejectedPredicate,
                claimsWritten: pipelineOutcome.claims,
                beliefsWritten: pipelineOutcome.beliefs,
                contradictionsFound: pipelineOutcome.contradictions,
                modelName: usedModel
            )
        }
    }

    /// Propose `Authority.modelInference` claims across up to `limit` objects mentioning `entityID`.
    public func proposeForEntity(_ entityID: EntityID, limit: Int = 4) async throws -> [ProposalOutcome] {
        guard let entity = try await store.entity(entityID) else { return [] }
        let objects = try await store.objectsMentioning(entity.canonicalName, limit: limit)
        var outcomes: [ProposalOutcome] = []
        for object in objects {
            let outcome = try await propose(from: object, defaultSubjectHint: entity.canonicalName)
            outcomes.append(outcome)
        }
        return outcomes
    }

    private static func generateProposalsWithFM(
        object: CoreObject,
        subjectHint: String?
    ) async -> [ProposedClaimRecord]? {
        guard Conversation.isFoundationModelsCLIAvailable() else { return nil }
        let excerpt = String(object.text.prefix(2_600))
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let schemaURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-proposed-claims-schema-\(UUID().uuidString).json")
        do {
            try Data(fmProposedClaimsSchemaJSON.utf8).write(to: schemaURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schemaURL.path)
        } catch { return nil }
        defer { try? FileManager.default.removeItem(at: schemaURL) }

        let defaultSubject = subjectHint
            ?? object.metadata["repo"]?.split(separator: "/").last.map(String.init)
            ?? (object.title as NSString).deletingPathExtension
        let prompt = """
        Document Title: \(object.title)
        Primary Subject Hint: \(defaultSubject)

        Source Text:
        \(excerpt)

        Extract up to 5 concrete factual claims with exact verbatim quotes from the Source Text.
        """
        let executable = Conversation.fmExecutablePath
        let schemaPath = schemaURL.path
        let instructions = proposerInstructions

        return await Task.detached(priority: .userInitiated) {
            let arguments = [
                "respond", "--no-stream", "-g",
                "--guardrails", "permissive-content-transformations",
                "--schema", schemaPath, "-i", instructions, prompt,
            ]
            guard let result = try? BoundedProcess.run(executable: executable, arguments: arguments, timeout: 60),
                  !result.timedOut, result.status == 0, !result.stdout.isEmpty else { return nil }
            let outData = result.stdout

            let rawText = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstBrace = rawText.firstIndex(of: "{"),
                  let lastBrace = rawText.lastIndex(of: "}")
            else { return nil }
            let jsonSlice = String(rawText[firstBrace...lastBrace])
            guard let batch = try? JSONDecoder().decode(FMProposedBatch.self, from: Data(jsonSlice.utf8)),
                  let items = batch.claims
            else { return nil }

            return items.compactMap { item in
                let subj = item.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let val = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let quote = item.verbatimQuote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !subj.isEmpty, !val.isEmpty, !quote.isEmpty else { return nil }
                let sKind = EntityKind(rawValue: item.subjectKind) ?? .project
                let vKind: EntityKind? = item.valueIsEntity ? (EntityKind(rawValue: item.valueKind) ?? .technology) : nil
                return ProposedClaimRecord(
                    subject: subj,
                    subjectKind: sKind,
                    predicate: item.predicate,
                    value: val,
                    valueKind: vKind,
                    verbatimQuote: quote,
                    confidence: 0.72
                )
            }
        }.value
    }

    /// Deterministic fallback when `/usr/bin/fm` is disabled or returns empty on short prose.
    public static func heuristicProseProposals(
        from object: CoreObject,
        subjectHint: String? = nil
    ) -> [ProposedClaimRecord] {
        let subject = (
            subjectHint
                ?? object.metadata["repo"]?.split(separator: "/").last.map(String.init)
                ?? (object.title as NSString).deletingPathExtension
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return [] }

        var proposals: [ProposedClaimRecord] = []
        let lines = object.text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 16 && !$0.hasPrefix("#") && !$0.hasPrefix("```") && !$0.hasPrefix("|---") }

        for line in lines.prefix(12) {
            guard ClaimExtractor.verifiedByteRange(of: line, in: object.text) != nil else { continue }
            if proposals.count < 3 {
                let cleanValue = line.count > 180 ? String(line.prefix(180)) : line
                proposals.append(ProposedClaimRecord(
                    subject: subject,
                    subjectKind: .project,
                    predicate: Predicate.describes,
                    value: cleanValue,
                    valueKind: nil,
                    verbatimQuote: line,
                    confidence: 0.68
                ))
            }
        }
        return proposals
    }
}
