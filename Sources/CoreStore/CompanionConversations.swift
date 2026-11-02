import CoreModel
import Foundation

/// A saved phone thread is tied to the exact pairing grant and read ceiling that created it.
/// The identity is derived on the Mac from authenticated values, never from a phone path.
public struct CompanionHistoryScope: Sendable, Hashable {
    public let deviceID: UUID
    public let grantID: UUID
    public let domains: Set<Domain>
    public let selectedDomain: Domain?

    public init(deviceID: UUID, grantID: UUID, domains: Set<Domain>, selectedDomain: Domain?) {
        self.deviceID = deviceID
        self.grantID = grantID
        self.domains = domains
        self.selectedDomain = selectedDomain
    }

    public func conversationID(for thread: UUID) -> String {
        conversationPrefix + thread.uuidString
    }

    fileprivate var conversationPrefix: String {
        let ceiling = domains.map(\.rawValue).sorted().joined(separator: "+")
        return "phone-v1:\(deviceID.uuidString):\(grantID.uuidString):\(selectedDomain?.rawValue ?? "automatic"):\(ceiling):"
    }

    fileprivate var isValid: Bool {
        !domains.isEmpty && (selectedDomain.map { domains.contains($0) } ?? true)
    }

    fileprivate func operationPrefix(thread: UUID, request: UUID) -> String {
        "Conversation \(conversationID(for: thread)). Request \(request.uuidString). Digest v1:"
    }

    fileprivate func isDeliveryStage(_ stage: ReceiptStage) -> Bool {
        let prefix = "Acknowledged by paired device \(deviceID.uuidString) ("
        let suffix = "). Grant \(grantID.uuidString)."
        return stage.name == "companion.delivery" && stage.note?.hasPrefix(prefix) == true
            && stage.note?.hasSuffix(suffix) == true
    }
}

public enum CompanionHistoryError: Error, Sendable {
    case invalidScope
    case invalidExchange
    case untrustedConversation
    case duplicateOperation
    case staleConversation
    case invalidPage
}

public struct CompanionHistoryExchange: Sendable {
    public let question: StoredTurn
    public let answer: StoredTurn
    public let receipt: Receipt
}

public struct CompanionHistorySnapshot: Sendable {
    public let scope: CompanionHistoryScope
    public let thread: UUID
    public let exchanges: [CompanionHistoryExchange]
    /// The complete ordered exchange identities, captured before generating a follow-up.
    public var revision: CompanionHistoryRevision {
        CompanionHistoryRevision(entries: exchanges.map {
            .init(question: $0.question.id, answer: $0.answer.id, receipt: $0.receipt.id.value)
        })
    }
}

public struct CompanionHistoryRevision: Sendable, Equatable {
    fileprivate struct Entry: Sendable, Equatable {
        let question: String
        let answer: String
        let receipt: String
    }
    fileprivate let entries: [Entry]
    public static let empty = CompanionHistoryRevision(entries: [])
}

/// A missing thread may start empty; an existing but untrusted one must never do so.
public enum CompanionHistoryLookup: Sendable {
    case missing
    case unavailable
    case admitted(CompanionHistorySnapshot)
}

public struct CompanionHistorySummary: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let exchangeCount: Int
}

public struct CompanionHistoryPage: Sendable {
    public let threads: [CompanionHistorySummary]
    public let nextOffset: Int?
}

// The full source model lives in CoreReason. This narrower decoder is only for checking every
// referenced floor object and claim before any saved content is sent to a phone.
private struct CompanionSourceReferences: Decodable {
    let objectID: ObjectID
    let representedObjectIDs: [ObjectID]?
    let claimID: ClaimID?
}

extension Store {
    /// One random request UUID represents one phone answer, including across retries. Its
    /// receipt survives conversation deletion and therefore also retains the deduplication key.
    public static func companionReceiptID(for request: UUID) -> ReceiptID {
        ReceiptID(Digest.hex("OpenCore companion request v1:\(request.uuidString)"))
    }

    /// Commit one acknowledged phone exchange, its receipt, and its trace in one transaction.
    /// The request digest binds the durable operation identity to the original wire request.
    /// This primitive does not itself acknowledge delivery or perform a phone read.
    public func saveCompanionExchange(
        scope: CompanionHistoryScope, thread: UUID, request: UUID, requestDigest: String,
        question: String, answer: StoredTurn, receipt: Receipt, expectedRevision: CompanionHistoryRevision,
        evidence: [(EvidenceID, Double)] = [], claims: [ClaimID] = [], additionalEvidence: [Evidence] = []
    ) async throws -> Receipt {
        try await saveCompanionExchange(scope: scope, thread: thread, request: request, requestDigest: requestDigest,
            question: question, answer: answer, receipt: receipt, evidence: evidence, claims: claims,
            additionalEvidence: additionalEvidence, expectedRevision: expectedRevision, enforceCurrentAdmission: true)
    }

    // Internal switch lets synthetic tests construct corrupt historical rows. Production
    // callers use the public entry point, which always rechecks current admission.
    func saveCompanionExchange(
        scope: CompanionHistoryScope, thread: UUID, request: UUID, requestDigest: String,
        question: String, answer: StoredTurn, receipt: Receipt,
        evidence: [(EvidenceID, Double)] = [], claims: [ClaimID] = [], additionalEvidence: [Evidence] = [],
        expectedRevision: CompanionHistoryRevision? = nil, enforceCurrentAdmission: Bool
    ) async throws -> Receipt {
        guard scope.isValid else { throw CompanionHistoryError.invalidScope }
        let conversationID = scope.conversationID(for: thread)
        guard Self.validCompanionDigest(requestDigest), !question.isEmpty, receipt.query == question,
              answer.conversationID == conversationID, answer.role == "core",
              let answerID = UUID(uuidString: answer.id), answer.id == answerID.uuidString, answerID != request,
              receipt.id == Self.companionReceiptID(for: request), answer.receiptID == receipt.id,
              Set(receipt.domainsAdmitted).isSubset(of: scope.domains),
              receipt.stages.contains(where: scope.isDeliveryStage),
              !receipt.stages.contains(where: { $0.name == "companion.operation" })
        else { throw CompanionHistoryError.invalidExchange }

        return try await database.write { connection in
            let deleted = try Self.hasCompanionTombstone(conversationID, connection: connection)
            guard try !Self.hasCompanionBlobConversationIdentity(conversationID, connection: connection)
            else { throw CompanionHistoryError.untrustedConversation }
            guard try Self.companionEvidenceIsCompatible(additionalEvidence, connection: connection)
            else { throw CompanionHistoryError.invalidExchange }
            let existing = try connection.query("SELECT id FROM conversation WHERE id = ?", [.text(conversationID)])
            let rows = try Self.companionTurnRows(conversationID, connection: connection)
            var currentRevision = CompanionHistoryRevision.empty
            if !existing.isEmpty {
                guard try Self.companionTurnsAreOwned(rows, scope: scope, thread: thread, connection: connection)
                else { throw CompanionHistoryError.untrustedConversation }
                if enforceCurrentAdmission || expectedRevision != nil {
                    guard let prior = try Self.companionHistory(scope: scope, thread: thread, connection: connection),
                          !prior.exchanges.isEmpty else { throw CompanionHistoryError.untrustedConversation }
                    currentRevision = prior.revision
                }
            } else if !rows.isEmpty {
                throw CompanionHistoryError.untrustedConversation
            }
            let questionID = request.uuidString
            guard try connection.query("SELECT id FROM conversation_turn WHERE id IN (?, ?, ?, ?) LIMIT 1",
                [.text(questionID), .blob(Data(questionID.utf8)), .text(answer.id), .blob(Data(answer.id.utf8))]).isEmpty,
                  try connection.query("SELECT id FROM receipt WHERE id IN (?, ?) LIMIT 1",
                    [.text(receipt.id.value), .blob(Data(receipt.id.value.utf8))]).isEmpty
            else { throw CompanionHistoryError.duplicateOperation }
            guard !deleted else { throw CompanionHistoryError.staleConversation }
            if let expectedRevision, expectedRevision != currentRevision { throw CompanionHistoryError.staleConversation }

            if existing.isEmpty {
                let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(60))
                try connection.execute(
                    "INSERT INTO conversation (id, title, started_at, updated_at) VALUES (?, ?, ?, ?)",
                    [.text(conversationID), .text(title), .real(answer.createdAt.timeIntervalSince1970), .real(answer.createdAt.timeIntervalSince1970)]
                )
            }
            let questionTurn = StoredTurn(id: request.uuidString, conversationID: conversationID, ordinal: rows.count,
                role: "you", text: question, receiptID: receipt.id, createdAt: answer.createdAt)
            var response = answer
            response.ordinal = rows.count + 1
            let payloadDigest = Self.companionPayloadDigest(question: questionTurn, answer: response)
            var delivered = receipt
            delivered.stages.append(ReceiptStage(name: "companion.operation", milliseconds: 0,
                note: scope.operationPrefix(thread: thread, request: request) + requestDigest + " Payload v1:" + payloadDigest))
            try Self.saveReceipt(delivered, evidence: evidence, claims: claims, additionalEvidence: additionalEvidence, connection: connection)
            if enforceCurrentAdmission {
                guard try Self.companionSourcesAreAdmitted(answer: response, receipt: delivered, scope: scope, connection: connection)
                else { throw CompanionHistoryError.invalidExchange }
            }
            try Self.insertCompanionTurn(questionTurn, connection: connection)
            try Self.insertCompanionTurn(response, connection: connection)
            try connection.execute("UPDATE conversation SET updated_at = ? WHERE id = ?",
                [.real(answer.createdAt.timeIntervalSince1970), .text(conversationID)])
            return delivered
        }
    }

    /// A thread is returned only after its current grant, immutable turn bindings and every
    /// currently referenced object and claim are admitted in one SQLite read snapshot.
    /// Callers must still decode the complete source and verdict models before exposing them.
    public func companionHistory(scope: CompanionHistoryScope, thread: UUID) async throws -> CompanionHistorySnapshot? {
        guard scope.isValid else { throw CompanionHistoryError.invalidScope }
        let result = try await database.read { connection in
            try Self.withCompanionSnapshot(connection: connection) {
                try Self.companionHistory(scope: scope, thread: thread, connection: connection)
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Distinguish a genuinely new scope-derived thread from an existing thread whose current
    /// ownership, payload or source admission no longer validates. Both checks share one snapshot.
    public func companionHistoryLookup(scope: CompanionHistoryScope, thread: UUID) async throws -> CompanionHistoryLookup {
        guard scope.isValid else { throw CompanionHistoryError.invalidScope }
        let result: CompanionHistoryLookup = try await database.read { connection in
            try Self.withCompanionSnapshot(connection: connection) {
                try Self.companionHistoryLookup(scope: scope, thread: thread, connection: connection)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func companionHistoryLookup(scope: CompanionHistoryScope, thread: UUID,
                                                connection: Connection) throws -> CompanionHistoryLookup {
        let id = scope.conversationID(for: thread)
        guard try !hasCompanionTombstone(id, connection: connection) else { return .unavailable }
        // SQLite distinguishes TEXT and BLOB keys even when their bytes match.
        guard try !hasCompanionBlobConversationIdentity(id, connection: connection) else { return .unavailable }
        guard let row = try connection.query("SELECT id FROM conversation WHERE id = ?", [.text(id)]).first else {
            let orphan = try connection.query("SELECT 1 FROM conversation_turn WHERE conversation_id = ? LIMIT 1", [.text(id)])
            return orphan.isEmpty ? .missing : .unavailable
        }
        guard let stored = row.string("id"), sameCompanionID(stored, id),
              let snapshot = try companionHistory(scope: scope, thread: thread, connection: connection),
              !snapshot.exchanges.isEmpty else { return .unavailable }
        return .admitted(snapshot)
    }

    /// Revalidate every history represented in a page in one read snapshot before sending it.
    /// The caller's synchronous predicate checks its complete source/verdict models.
    public func companionHistoryRevisionsAreAdmitted(
        scope: CompanionHistoryScope, revisions: [(UUID, CompanionHistoryRevision)],
        admitting: @escaping @Sendable (CompanionHistorySnapshot) -> Bool
    ) async throws -> Bool {
        guard scope.isValid else { return false }
        let result = try await database.read { connection in
            try Self.withCompanionSnapshot(connection: connection) {
                for (thread, revision) in revisions {
                    try Task.checkCancellation()
                    guard case .admitted(let current) = try Self.companionHistoryLookup(scope: scope, thread: thread, connection: connection),
                          current.revision == revision, admitting(current) else { return false }
                }
                return true
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Before sending a prepared saved-chat answer, check the exact restored revision and all
    /// newly displayed/traced references together in one read snapshot. This performs no write.
    public func companionPreparedChatIsAdmitted(
        scope: CompanionHistoryScope, thread: UUID, expectedRevision: CompanionHistoryRevision,
        request: UUID, answerID: UUID,
        receipt: Receipt, representedObjects: Set<ObjectID>, referencedClaims: Set<ClaimID>,
        evidenceIDs: [EvidenceID], additionalEvidence: [Evidence]
    ) async throws -> Bool {
        guard scope.isValid, receipt.id == Self.companionReceiptID(for: request), answerID != request,
              Set(receipt.domainsAdmitted).isSubset(of: scope.domains) else { return false }
        let committedRevision = CompanionHistoryRevision(entries: expectedRevision.entries + [
            .init(question: request.uuidString, answer: answerID.uuidString, receipt: receipt.id.value)
        ])
        let result = try await database.read { connection in
            try Self.withCompanionSnapshot(connection: connection) {
                switch try Self.companionHistoryLookup(scope: scope, thread: thread, connection: connection) {
                case .missing where expectedRevision == .empty: break
                case .admitted(let current) where current.revision == expectedRevision || current.revision == committedRevision: break
                default: return false
                }
                guard try Self.companionEvidenceIsCompatible(additionalEvidence, connection: connection) else { return false }
                var objects = representedObjects
                var additions: [Data: Evidence] = [:]
                for item in additionalEvidence {
                    objects.insert(item.objectID)
                    additions[Data(item.id.value.utf8)] = item
                }
                for id in evidenceIDs {
                    try Task.checkCancellation()
                    guard Self.validCompanionID(id.value) else { return false }
                    let key = Data(id.value.utf8)
                    if let item = additions[key] {
                        objects.insert(item.objectID)
                        continue
                    }
                    guard try connection.query("SELECT id FROM evidence WHERE id = ? LIMIT 1", [.blob(key)]).isEmpty,
                          let row = try connection.query("SELECT id, object_id FROM evidence WHERE id = ? LIMIT 1", [.text(id.value)]).first,
                          let stored = row.string("id"), Self.sameCompanionID(stored, id.value),
                          let object = row.string("object_id"), Self.validCompanionID(object) else { return false }
                    objects.insert(ObjectID(object))
                }
                return try Self.companionReferencesAreAdmitted(objects: objects, claims: referencedClaims,
                    receipt: receipt, scope: scope, connection: connection)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func hasCompanionBlobConversationIdentity(_ id: String, connection: Connection) throws -> Bool {
        let bytes = Data(id.utf8)
        let blobConversation = try connection.query("SELECT id FROM conversation WHERE id = ? LIMIT 1", [.blob(bytes)])
        if !blobConversation.isEmpty { return true }
        return try !connection.query("SELECT 1 FROM conversation_turn WHERE conversation_id = ? LIMIT 1", [.blob(bytes)]).isEmpty
    }

    static func companionTombstoneKey(_ conversationID: String) -> String {
        Digest.hex("OpenCore companion thread deletion v1:" + conversationID)
    }

    private static func hasCompanionTombstone(_ conversationID: String, connection: Connection) throws -> Bool {
        let key = companionTombstoneKey(conversationID)
        return try !connection.query("SELECT id FROM companion_thread_tombstone WHERE id IN (?, ?) LIMIT 1",
            [.text(key), .blob(Data(key.utf8))]).isEmpty
    }

    /// A regenerated passage may reuse an evidence ID only for the exact same stored
    /// provenance and snippet. This does not itself authorize the evidence's domain.
    public func companionAdditionalEvidenceIsCompatible(_ evidence: [Evidence]) async throws -> Bool {
        let compatible = try await database.read { connection in
            try Self.withCompanionSnapshot(connection: connection) {
                try Self.companionEvidenceIsCompatible(evidence, connection: connection)
            }
        }
        try Task.checkCancellation()
        return compatible
    }

    /// Save a non-history phone receipt only while every displayed and traced reference is
    /// still admitted under the authenticated request's ceiling in this write transaction.
    public func saveCompanionReceipt(_ receipt: Receipt, scope: CompanionHistoryScope,
                                     representedObjects: Set<ObjectID>, referencedClaims: Set<ClaimID>,
                                     evidence: [(EvidenceID, Double)] = [], claims: [ClaimID] = [],
                                     additionalEvidence: [Evidence] = []) async throws {
        guard scope.isValid, Set(receipt.domainsAdmitted).isSubset(of: scope.domains) else { throw CompanionHistoryError.invalidScope }
        try await database.write { connection in
            guard try Self.companionEvidenceIsCompatible(additionalEvidence, connection: connection)
            else { throw CompanionHistoryError.invalidExchange }
            try Self.saveReceipt(receipt, evidence: evidence, claims: claims, additionalEvidence: additionalEvidence, connection: connection)
            guard try Self.companionReferencesAreAdmitted(objects: representedObjects, claims: referencedClaims,
                receipt: receipt, scope: scope, connection: connection) else { throw CompanionHistoryError.invalidExchange }
        }
    }

    private static func companionEvidenceIsCompatible(_ evidence: [Evidence], connection: Connection) throws -> Bool {
        var seen: [Data: Evidence] = [:]
        for item in evidence {
            try Task.checkCancellation()
            let id = item.id.value
            guard validCompanionID(id), validCompanionID(item.objectID.value) else { return false }
            let key = Data(id.utf8)
            if let prior = seen[key] {
                guard sameCompanionEvidence(prior, item) else { return false }
                continue
            }
            seen[key] = item
            guard try connection.query("SELECT id FROM evidence WHERE id = ? LIMIT 1", [.blob(key)]).isEmpty else { return false }
            let rows = try connection.query("""
                SELECT id, object_id, range_start, range_end, snippet, authority,
                       typeof(range_start) AS start_type, typeof(range_end) AS end_type,
                       typeof(authority) AS authority_type
                FROM evidence WHERE id = ? LIMIT 1
                """, [.text(id)])
            guard let row = rows.first else { continue }
            guard let storedID = row.string("id"), sameCompanionID(storedID, id),
                  let object = row.string("object_id"), sameCompanionID(object, item.objectID.value),
                  let snippet = row.string("snippet"), snippet.utf8.elementsEqual(item.snippet.utf8),
                  row.string("authority_type") == "integer", row.int("authority") == item.authority.rawValue else { return false }
            if let range = item.range {
                guard row.string("start_type") == "integer", row.string("end_type") == "integer",
                      row.int("range_start") == range.lowerBound, row.int("range_end") == range.upperBound else { return false }
            } else {
                guard row.string("start_type") == "null", row.string("end_type") == "null" else { return false }
            }
        }
        return true
    }

    private static func sameCompanionEvidence(_ left: Evidence, _ right: Evidence) -> Bool {
        left.id.value.utf8.elementsEqual(right.id.value.utf8)
            && left.objectID.value.utf8.elementsEqual(right.objectID.value.utf8)
            && left.range == right.range && left.authority == right.authority
            && left.snippet.utf8.elementsEqual(right.snippet.utf8)
    }

    /// Filter ownership, current source admission and the caller's full-model validation
    /// before applying the visible offset. The title comes from the validated question.
    /// The synchronous predicate runs inside the read snapshot and must not perform I/O.
    public func companionHistoryPage(scope: CompanionHistoryScope, offset: Int = 0, limit: Int = 40,
                                     admitting: @escaping @Sendable (CompanionHistorySnapshot) -> Bool = { _ in true }) async throws -> CompanionHistoryPage {
        guard scope.isValid else { throw CompanionHistoryError.invalidScope }
        guard (0...1_000_000).contains(offset), (1...40).contains(limit) else { throw CompanionHistoryError.invalidPage }
        let result = try await database.read { connection in
            try Self.withCompanionSnapshot(connection: connection) {
                var cursor = 0, admitted = 0
                var summaries: [CompanionHistorySummary] = []
                var more = false
                let prefix = scope.conversationPrefix
                // Chosen batch size: scan past denied threads so they cannot consume a page.
                let batchSize = 64
                scan: while true {
                    try Task.checkCancellation()
                    let candidates = try connection.query(
                        """
                        SELECT id, updated_at FROM conversation WHERE substr(id, 1, ?) = ?
                        ORDER BY updated_at DESC, id ASC LIMIT ? OFFSET ?
                        """,
                        [.integer(Int64(prefix.utf8.count)), .text(prefix), .integer(Int64(batchSize)), .integer(Int64(cursor))]
                    )
                    if candidates.isEmpty { break }
                    cursor += candidates.count
                    for candidate in candidates {
                        try Task.checkCancellation()
                        guard let id = candidate.string("id"), id.hasPrefix(prefix),
                              let thread = UUID(uuidString: String(id.dropFirst(prefix.count))),
                              id == scope.conversationID(for: thread), let updated = candidate.date("updated_at"),
                              updated.timeIntervalSince1970.isFinite,
                              let snapshot = try Self.companionHistory(scope: scope, thread: thread, connection: connection),
                              let first = snapshot.exchanges.first, admitting(snapshot) else { continue }
                        if admitted >= offset {
                            if summaries.count == limit { more = true; break scan }
                            let question = first.question.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            summaries.append(CompanionHistorySummary(id: thread,
                                title: question.isEmpty ? "Untitled" : String(question.prefix(60)),
                                updatedAt: updated, exchangeCount: snapshot.exchanges.count))
                        }
                        admitted += 1
                    }
                    if candidates.count < batchSize { break }
                }
                return CompanionHistoryPage(threads: summaries, nextOffset: more ? offset + limit : nil)
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// BEGIN is deferred, so a first SELECT starts a read transaction without taking the
    /// writer lock. All queries in the closure see that same snapshot until COMMIT.
    static func withCompanionSnapshot<T>(connection: Connection, _ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try connection.executeScript("BEGIN DEFERRED")
        do {
            let value = try body()
            try Task.checkCancellation()
            try connection.executeScript("COMMIT")
            return value
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }

    private static func companionHistory(scope: CompanionHistoryScope, thread: UUID,
                                         connection: Connection) throws -> CompanionHistorySnapshot? {
        let id = scope.conversationID(for: thread)
        guard try !hasCompanionTombstone(id, connection: connection),
              try !hasCompanionBlobConversationIdentity(id, connection: connection) else { return nil }
        guard let row = try connection.query("SELECT id FROM conversation WHERE id = ?", [.text(id)]).first,
              let stored = row.string("id"), sameCompanionID(stored, id) else { return nil }
        let rows = try companionTurnRows(id, connection: connection)
        guard try companionTurnsAreOwned(rows, scope: scope, thread: thread, connection: connection) else { return nil }
        var exchanges: [CompanionHistoryExchange] = []
        for index in stride(from: 0, to: rows.count, by: 2) {
            try Task.checkCancellation()
            let question = StoredTurn(row: rows[index]), answer = StoredTurn(row: rows[index + 1])
            guard let id = answer.receiptID,
                  let receipt = try companionReceipt(id, connection: connection),
                  try companionSourcesAreAdmitted(answer: answer, receipt: receipt, scope: scope, connection: connection)
            else { return nil }
            exchanges.append(CompanionHistoryExchange(question: question, answer: answer, receipt: receipt))
        }
        return CompanionHistorySnapshot(scope: scope, thread: thread, exchanges: exchanges)
    }

    static func validCompanionDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func companionTurnRows(_ conversationID: String, connection: Connection) throws -> [Row] {
        try connection.query(
            """
            SELECT *, typeof(ordinal) AS _phone_ordinal_type, typeof(model) AS _phone_model_type,
                   typeof(error) AS _phone_error_type
            FROM conversation_turn WHERE conversation_id = ? ORDER BY ordinal, id
            """, [.text(conversationID)]
        )
    }

    private static func isWellFormedCompanionTurn(_ row: Row) -> Bool {
        guard row.string("id") != nil, row.string("conversation_id") != nil, row.string("role") != nil,
              row.string("text") != nil, row.string("sources") != nil, row.string("verdicts") != nil,
              row.string("receipt_id") != nil, row.string("_phone_ordinal_type") == "integer",
              ["text", "null"].contains(row.string("_phone_model_type") ?? ""),
              ["text", "null"].contains(row.string("_phone_error_type") ?? ""),
              let created = row.double("created_at"), created.isFinite else { return false }
        return true
    }

    private static func companionReceipt(_ id: ReceiptID, connection: Connection) throws -> Receipt? {
        let rows = try connection.query(
            """
            SELECT *, typeof(objects_searched) AS _phone_objects_searched,
                   typeof(objects_retrieved) AS _phone_objects_retrieved,
                   typeof(evidence_admitted) AS _phone_evidence_admitted,
                   typeof(claims_consulted) AS _phone_claims_consulted,
                   typeof(contradictions_surfaced) AS _phone_contradictions_surfaced,
                   typeof(objects_transmitted) AS _phone_objects_transmitted,
                   typeof(model) AS _phone_model, typeof(confidence) AS _phone_confidence
            FROM receipt WHERE id = ?
            """, [.text(id.value)]
        )
        guard let row = rows.first, let stored = row.string("id"), sameCompanionID(stored, id.value), row.string("query") != nil,
              let queryClass = row.string("query_class"), QueryClass(rawValue: queryClass) != nil,
              let admitted = row.string("domains_admitted"), let blocked = row.string("domains_blocked"),
              validStoredCompanionDomains(admitted), validStoredCompanionDomains(blocked), row.string("stages") != nil,
              let created = row.double("created_at"), created.isFinite,
              ["text", "null"].contains(row.string("_phone_model") ?? ""),
              ["integer", "real", "null"].contains(row.string("_phone_confidence") ?? ""),
              row.double("confidence").map(\.isFinite) ?? true else { return nil }
        for name in ["objects_searched", "objects_retrieved", "evidence_admitted", "claims_consulted",
                     "contradictions_surfaced", "objects_transmitted"] {
            guard row.string("_phone_\(name)") == "integer" else { return nil }
        }
        return Receipt(row: row)
    }

    private static func validStoredCompanionDomains(_ raw: String) -> Bool {
        raw.isEmpty || raw.split(separator: ",", omittingEmptySubsequences: false)
            .allSatisfy { Domain(rawValue: String($0)) != nil }
    }

    private static func companionSourcesAreAdmitted(answer: StoredTurn, receipt: Receipt, scope: CompanionHistoryScope,
                                                      connection: Connection) throws -> Bool {
        guard let data = answer.sourcesJSON.data(using: .utf8),
              let sources = try? JSONDecoder().decode([CompanionSourceReferences].self, from: data) else { return false }
        var objects = Set<ObjectID>(), claims = Set<ClaimID>()
        for source in sources {
            objects.insert(source.objectID)
            objects.formUnion(source.representedObjectIDs ?? [])
            if let claim = source.claimID { claims.insert(claim) }
        }
        return try companionReferencesAreAdmitted(objects: objects, claims: claims, receipt: receipt, scope: scope, connection: connection)
    }

    private static func companionReferencesAreAdmitted(objects initialObjects: Set<ObjectID>, claims initialClaims: Set<ClaimID>,
                                                        receipt: Receipt, scope: CompanionHistoryScope,
                                                        connection: Connection) throws -> Bool {
        var objects = initialObjects, claims = initialClaims
        let trace = try connection.query(
            """
            SELECT re.receipt_id AS receipt_id, re.evidence_id AS linked_id,
                   e.id AS evidence_id, e.object_id AS object_id FROM receipt_evidence re
            LEFT JOIN evidence e ON e.id = re.evidence_id WHERE re.receipt_id = ?
            """, [.text(receipt.id.value)]
        )
        for row in trace {
            try Task.checkCancellation()
            guard let receiptID = row.string("receipt_id"), sameCompanionID(receiptID, receipt.id.value),
                  let linked = row.string("linked_id"), let evidence = row.string("evidence_id"),
                  sameCompanionID(linked, evidence), let id = row.string("object_id"), validCompanionID(id) else { return false }
            objects.insert(ObjectID(id))
        }
        for row in try connection.query("SELECT receipt_id, claim_id FROM receipt_claim WHERE receipt_id = ?", [.text(receipt.id.value)]) {
            try Task.checkCancellation()
            guard let receiptID = row.string("receipt_id"), sameCompanionID(receiptID, receipt.id.value),
                  let id = row.string("claim_id"), validCompanionID(id) else { return false }
            claims.insert(ClaimID(id))
        }
        for object in objects {
            try Task.checkCancellation()
            guard validCompanionID(object.value),
                  let row = try connection.query("SELECT id, domain FROM object WHERE id = ?", [.text(object.value)]).first,
                  let storedID = row.string("id"), sameCompanionID(storedID, object.value), let raw = row.string("domain"),
                  let domain = Domain(rawValue: raw), scope.domains.contains(domain) else { return false }
        }
        for claim in claims {
            try Task.checkCancellation()
            guard try companionClaimIsAdmitted(claim, scope: scope, connection: connection) else { return false }
        }
        return true
    }

    private static func validCompanionID(_ id: String) -> Bool {
        !id.isEmpty && !id.utf8.contains(0)
    }

    private static func sameCompanionID(_ left: String, _ right: String) -> Bool {
        validCompanionID(left) && validCompanionID(right) && left.utf8.elementsEqual(right.utf8)
    }

    private static func companionEntityIsAdmitted(_ id: String, scope: CompanionHistoryScope,
                                                   connection: Connection) throws -> Bool {
        guard validCompanionID(id),
              let row = try connection.query("SELECT id, domain FROM entity WHERE id = ?", [.text(id)]).first,
              let stored = row.string("id"), sameCompanionID(stored, id), let raw = row.string("domain"),
              let domain = Domain(rawValue: raw), scope.domains.contains(domain) else { return false }
        return true
    }

    /// Match the existing owner claim policy while validating each linked identifier and
    /// domain as TEXT in Swift; malformed SQLite join keys cannot become admission evidence.
    private static func companionClaimIsAdmitted(_ claim: ClaimID, scope: CompanionHistoryScope,
                                                 connection: Connection) throws -> Bool {
        guard validCompanionID(claim.value),
              let row = try connection.query(
                "SELECT id, domain, subject, object_entity, typeof(object_entity) AS target_type FROM claim WHERE id = ?",
                [.text(claim.value)]).first,
              let stored = row.string("id"), sameCompanionID(stored, claim.value), let raw = row.string("domain"),
              let domain = Domain(rawValue: raw), scope.domains.contains(domain), let subject = row.string("subject"),
              try companionEntityIsAdmitted(subject, scope: scope, connection: connection) else { return false }
        switch row.string("target_type") {
        case "null": break
        case "text":
            guard let target = row.string("object_entity"),
                  try companionEntityIsAdmitted(target, scope: scope, connection: connection) else { return false }
        default: return false
        }
        var admittedSupport = false
        let links = try connection.query("SELECT claim_id, evidence_id, stance FROM claim_evidence WHERE claim_id = ?", [.text(claim.value)])
        for link in links {
            try Task.checkCancellation()
            guard let linkedClaim = link.string("claim_id"), sameCompanionID(linkedClaim, claim.value),
                  let evidenceID = link.string("evidence_id"), validCompanionID(evidenceID),
                  let stance = link.string("stance"), Stance(rawValue: stance) != nil,
                  let evidence = try connection.query("SELECT id, object_id FROM evidence WHERE id = ?", [.text(evidenceID)]).first,
                  let storedEvidence = evidence.string("id"), sameCompanionID(storedEvidence, evidenceID),
                  let objectID = evidence.string("object_id"), validCompanionID(objectID),
                  let object = try connection.query("SELECT id, domain FROM object WHERE id = ?", [.text(objectID)]).first,
                  let storedObject = object.string("id"), sameCompanionID(storedObject, objectID),
                  let objectRaw = object.string("domain"), let objectDomain = Domain(rawValue: objectRaw) else { return false }
            if stance == Stance.supports.rawValue && scope.domains.contains(objectDomain) { admittedSupport = true }
        }
        return admittedSupport
    }

    private static func companionPayloadDigest(question: StoredTurn, answer: StoredTurn) -> String {
        // Versioned UTF-8 framing makes the marker independent of JSON encoder escaping.
        // A nil tag differs from an empty string; lengths preserve every field boundary.
        // Judgements are excluded: the owner can add or withdraw them.
        let fields: [String?] = [question.id, question.conversationID, String(question.ordinal), question.role,
            question.text, question.sourcesJSON, question.verdictsJSON, question.receiptID?.value, question.model, question.error,
            answer.id, answer.conversationID, String(answer.ordinal), answer.role, answer.text, answer.sourcesJSON,
            answer.verdictsJSON, answer.receiptID?.value, answer.model, answer.error]
        var bytes = Array("OpenCore companion payload v1\u{0}".utf8)
        for field in fields {
            guard let field else { bytes.append(0); continue }
            bytes.append(1)
            bytes.append(contentsOf: String(field.utf8.count).utf8)
            bytes.append(58) // ASCII colon follows the decimal byte length.
            bytes.append(contentsOf: field.utf8)
        }
        return Digest.hex(Data(bytes))
    }

    /// Reject partial, reordered, Mac-added or differently scoped turns before using a thread.
    static func companionTurnsAreOwned(_ rows: [Row], scope: CompanionHistoryScope, thread: UUID,
                                       connection: Connection) throws -> Bool {
        guard !rows.isEmpty, rows.count.isMultiple(of: 2) else { return false }
        for row in rows {
            try Task.checkCancellation()
            guard isWellFormedCompanionTurn(row) else { return false }
        }
        for index in stride(from: 0, to: rows.count, by: 2) {
            try Task.checkCancellation()
            let question = StoredTurn(row: rows[index]), answer = StoredTurn(row: rows[index + 1])
            guard question.ordinal == index, answer.ordinal == index + 1,
                  question.role == "you", answer.role == "core", let request = UUID(uuidString: question.id),
                  question.id == request.uuidString, let answerID = UUID(uuidString: answer.id), answer.id == answerID.uuidString,
                  let receiptID = question.receiptID, answer.receiptID == receiptID,
                  receiptID == companionReceiptID(for: request),
                  let receipt = try companionReceipt(receiptID, connection: connection)
            else { return false }
            let prefix = scope.operationPrefix(thread: thread, request: request)
            let operationStages = receipt.stages.filter { $0.name == "companion.operation" }
            guard receipt.query == question.text, Set(receipt.domainsAdmitted).isSubset(of: scope.domains),
                  receipt.stages.contains(where: scope.isDeliveryStage), operationStages.count == 1,
                  let note = operationStages.first?.note, note.hasPrefix(prefix) else { return false }
            let parts = String(note.dropFirst(prefix.count)).components(separatedBy: " Payload v1:")
            guard parts.count == 2, validCompanionDigest(parts[0]),
                  parts[1] == companionPayloadDigest(question: question, answer: answer) else { return false }
        }
        return true
    }

    private static func insertCompanionTurn(_ turn: StoredTurn, connection: Connection) throws {
        try connection.execute(
            """
            INSERT INTO conversation_turn
                (id, conversation_id, ordinal, role, text, sources, verdicts, receipt_id, model, error, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(turn.id), .text(turn.conversationID), .integer(Int64(turn.ordinal)), .text(turn.role),
             .text(turn.text), .text(turn.sourcesJSON), .text(turn.verdictsJSON), SQLValue(text: turn.receiptID?.value),
             SQLValue(text: turn.model), SQLValue(text: turn.error), .real(turn.createdAt.timeIntervalSince1970)]
        )
    }
}
