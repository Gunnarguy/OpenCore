import CoreCompanion
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import Foundation

/// The Mac view and the phone call the existing engine. This adapter does no SQL,
/// performs no sync, and has no path to the operator console, Hub, monitor or USB.
public actor CompanionBroker {
    public typealias DeliveryFailureHandler = @Sendable (String) async -> Void
    typealias ChatGenerator = @Sendable (CompanionRequest, Conversation, CompanionServer.Progress) async throws -> Turn
    private let store: Store
    private let tuning: RetrievalTuning
    private struct ScopedConversation {
        var domains: Set<Domain>
        var grantID: UUID
        var ownerDomain: String?
        var conversation: Conversation
    }
    private var conversations: [UUID: ScopedConversation] = [:]
    private let generation: Conversation.GenerationConfiguration
    private let now: @Sendable () -> Date
    private let onAuditFailure: Conversation.AuditFailureHandler
    private let onDeliveryFailure: DeliveryFailureHandler
    private let chatGenerator: ChatGenerator?
    private let afterChatPreparation: (@Sendable () async throws -> Void)?
    public init(store: Store, tuning: RetrievalTuning = .default,
                generation: Conversation.GenerationConfiguration = .init(), now: @escaping @Sendable () -> Date = { Date() },
                onAuditFailure: @escaping Conversation.AuditFailureHandler = Conversation.defaultAuditFailureHandler,
                onDeliveryFailure: @escaping DeliveryFailureHandler = { message in
                    FileHandle.standardError.write(Data(("OpenCore companion: " + message + "\n").utf8))
                }) {
        self.store = store; self.tuning = tuning; self.generation = generation
        self.now = now
        self.onAuditFailure = onAuditFailure
        self.onDeliveryFailure = onDeliveryFailure
        self.chatGenerator = nil
        self.afterChatPreparation = nil
    }

    // A controlled generator lets synthetic tests pause after restore without invoking a model.
    init(store: Store, chatGenerator: @escaping ChatGenerator,
         afterChatPreparation: (@Sendable () async throws -> Void)? = nil) {
        self.store = store; self.tuning = .default; self.generation = .init(); self.now = { Date() }
        self.onAuditFailure = Conversation.defaultAuditFailureHandler
        self.onDeliveryFailure = { _ in }
        self.chatGenerator = chatGenerator
        self.afterChatPreparation = afterChatPreparation
    }
    public func prepare(_ request: CompanionRequest, device: CompanionDevice, progress: CompanionServer.Progress = { _ in }) async throws -> CompanionPreparedPage {
        if request.chatHistoryAction != nil || request.chatThreadID != nil {
            guard request.section == .chat else { throw CompanionError.invalidFrame }
        }
        var domains = Set(device.domains.compactMap(Domain.init(rawValue:)))
        if let named = request.domain {
            guard let domain = Domain(rawValue: named), domains.contains(domain) else { throw CompanionError.unauthorized }
            domains = request.section == .chat || request.section == .passages ? domains.intersection(domain.readableDomains) : [domain]
        }
        guard !domains.isEmpty else { throw CompanionError.unauthorized }
        if request.section == .chat {
            if let action = request.chatHistoryAction {
                return try await history(request, action: action, device: device, domains: domains)
            }
            if request.chatThreadID != nil {
                return try await savedChat(request, device: device, domains: domains, progress: progress)
            }
            if request.answerMode == .evidence { return try await evidenceAnswer(request, device: device, domains: domains) }
            return try await chat(request, device: device, domains: domains, progress: progress)
        }
        if request.section == .passages, !request.query.isEmpty {
            let admission = AdmissionPolicy.forQuestion(request.query, ownerDomain: request.domain.flatMap(Domain.init(rawValue:)), maximumDomains: domains)
            let result = try await PassageSearch(store: store, tuning: tuning).search(query: request.query, queryClass: .factual, policy: admission, limit: 40)
            return CompanionPreparedPage(page: CompanionPage(title: request.section.title, note: "\(result.chunksSearched) passages searched. " + result.unavailableSignals.values.sorted().joined(separator: " "),
                records: result.hits.map { hit in
                    CompanionRecord(id: hit.chunk.id.value, title: hit.object.title, body: hit.chunk.text, domain: hit.object.domain.rawValue,
                        date: hit.object.authoredAt, fields: [.init("Score", String(hit.score)), .init("Authority", hit.object.authority.label)], objectID: hit.object.id.value)
                }))
        }
        switch request.section {
        case .home:
            let counts = try await store.ownerCounts(domains: domains)
            let now = Date()
            let activity = try await store.activity(from: now.addingTimeInterval(-7*86_400), to: now,
                domains: domains.filter { !$0.isSensitive }, limit: 40, detailsPerSubject: 3)
            let freshness = try await store.freshness(domains: domains, notAfter: now)
            let records = activity.groups.map { group in
                CompanionRecord(id: group.id.value, title: group.subject.canonicalName,
                    body: group.latest.map { $0.detail }.joined(separator: "\n\n"), domain: group.subject.domain.rawValue,
                    date: group.lastAt, fields: [.init("Events this week", String(group.events)), .init("Upkeep", String(group.upkeep))])
            }
            return CompanionPreparedPage(page: CompanionPage(title: "Your OpenCore", note: "Activity in the past seven days. " + freshness.sources.map { "\($0.label): \($0.lastSyncedAt.map(Self.date) ?? "never synced")" }.joined(separator: " · "),
                records: records, metrics: Self.metrics(counts)))
        case .corpus, .passages:
            if let id = request.recordID {
                guard let object = try await store.object(ObjectID(id)), domains.contains(object.domain) else { throw CompanionError.unauthorized }
                return CompanionPreparedPage(page: CompanionPage(title: object.title, records: [Self.objectRecord(object)]))
            }
            if request.section == .passages {
                let passages = try await store.ownerPassages(domains: domains, offset: request.offset)
                return CompanionPreparedPage(page: Self.paged(request, records: passages.map {
                    CompanionRecord(id: $0.id, title: $0.object.title, body: $0.text, domain: $0.object.domain.rawValue,
                        date: $0.object.authoredAt, fields: [.init("Authority", $0.object.authority.label)], objectID: $0.object.id.value)
                }))
            }
            let objects = try await store.ownerObjects(domains: domains, query: request.query, offset: request.offset)
            let counts = try await store.ownerCounts(domains: domains)
            return CompanionPreparedPage(page: Self.paged(request, records: objects.map(Self.objectRecord), metrics: Self.metrics(counts)))
        case .claims:
            if let id = request.recordID {
                guard let claim = try await store.claim(ClaimID(id)), try await store.ownerAdmitsClaim(claim.id, domains: domains) else { throw CompanionError.unauthorized }
                return CompanionPreparedPage(page: CompanionPage(title: "Claim", records: [try await claimRecord(claim, domains: domains)]))
            }
            let claims = try await store.ownerClaims(domains: domains, query: request.query, offset: request.offset)
            var records: [CompanionRecord] = []
            for claim in claims { records.append(try await claimRecord(claim, domains: domains)) }
            return CompanionPreparedPage(page: Self.paged(request, records: records))
        case .beliefs, .timeTravel:
            let instant = request.asOf ?? Date()
            var records: [CompanionRecord] = []
            for belief in try await store.beliefs(asOfKnowledge: instant) {
                guard let claim = try await store.claim(belief.claimID), try await store.ownerAdmitsClaim(claim.id, domains: domains) else { continue }
                var record = try await claimRecord(claim, domains: domains)
                record.id = belief.id.value; record.date = belief.decidedAt
                record.fields += [.init("Version", String(belief.version)), .init("Decided", Self.date(belief.decidedAt)),
                    .init("Reason", try await admittedReason(belief, domains: domains))]
                records.append(record)
            }
            return CompanionPreparedPage(page: Self.slice(request, records: records, note: "Believed as of \(Self.date(instant))."))
        case .realityChecks:
            var records: [CompanionRecord] = []
            for item in try await store.contradictions() {
                guard try await store.ownerAdmitsClaim(item.claimA, domains: domains),
                      try await store.ownerAdmitsClaim(item.claimB, domains: domains) else { continue }
                records.append(CompanionRecord(id: item.id.value, title: item.resolution.rawValue, body: item.reason,
                    date: item.detectedAt, fields: [.init("Kind", item.kind.rawValue), .init("Claim A", item.claimA.value), .init("Claim B", item.claimB.value)]))
            }
            return CompanionPreparedPage(page: Self.slice(request, records: records))
        case .sources:
            let sources = try await store.sources().filter { domains.contains($0.defaultDomain) }
            return CompanionPreparedPage(page: Self.slice(request, records: sources.map { source in
                CompanionRecord(id: source.id.value, title: source.displayName, body: "Last successful sync: \(source.lastSyncedAt.map(Self.date) ?? "never")",
                    domain: source.defaultDomain.rawValue, date: source.lastSyncedAt,
                    fields: [.init("Kind", source.kind.rawValue), .init("Authority", source.defaultAuthority.label)])
            }, note: "The Mac runs sync. Connector tokens and configuration stay on the Mac."))
        case .timeline:
            let events = try await store.ownerEvents(domains: domains, before: request.asOf ?? Date(), query: request.query, offset: request.offset)
            var records: [CompanionRecord] = []
            for event in events {
                let subject = try await store.entity(event.subject)
                guard subject.map({ domains.contains($0.domain) }) ?? false else { continue }
                records.append(CompanionRecord(id: event.id.value, title: "\(subject?.canonicalName ?? "") · \(event.verb)", body: event.detail,
                    domain: event.domain.rawValue, date: event.occurredAt, fields: [.init("Authority", event.authority.label)]))
            }
            return CompanionPreparedPage(page: Self.paged(request, records: records))
        case .graph:
            if let id = request.recordID {
                guard let entity = try await store.entity(EntityID(id)), domains.contains(entity.domain),
                      let dossier = try await store.dossier(for: entity.id) else { throw CompanionError.unauthorized }
                var records: [CompanionRecord] = []
                for row in dossier.claims where try await store.ownerAdmitsClaim(row.claim.id, domains: domains) {
                    records.append(try await claimRecord(row.claim, domains: domains))
                }
                return CompanionPreparedPage(page: CompanionPage(title: entity.canonicalName, note: entity.kind.rawValue, records: records))
            }
            let entities = try await store.entities().filter { domains.contains($0.domain) && (request.query.isEmpty || $0.canonicalName.localizedCaseInsensitiveContains(request.query)) }
            return CompanionPreparedPage(page: Self.slice(request, records: entities.map {
                CompanionRecord(id: $0.id.value, title: $0.canonicalName, body: $0.kind.rawValue, domain: $0.domain.rawValue,
                    fields: [.init("Kind", $0.kind.rawValue)])
            }))
        case .receipts:
            if let id = request.recordID {
                guard let receipt = try await store.receipt(code: id), Self.admitsReceipt(receipt, device: device, domains: domains) else { throw CompanionError.unauthorized }
                var records = [Self.receiptRecord(receipt)]
                for (evidence, object, score) in try await store.trace(receipt: receipt.id) where domains.contains(object.domain) {
                    records.append(CompanionRecord(id: evidence.id.value, title: object.title, body: evidence.snippet, domain: object.domain.rawValue,
                        date: object.authoredAt, fields: [.init("Score", String(score)), .init("Authority", evidence.authority.label)], objectID: object.id.value))
                }
                return CompanionPreparedPage(page: CompanionPage(title: "Receipt & trace", records: records))
            }
            // No arbitrary latest-N cap: filtering and pagination happen before display.
            let receipts = try await store.receipts(limit: Int.max).filter { Self.admitsReceipt($0, device: device, domains: domains) }
            return CompanionPreparedPage(page: Self.slice(request, records: receipts.map(Self.receiptRecord)))
        case .chat: throw CompanionError.invalidFrame
        }
    }
    private static func admitsReceipt(_ receipt: Receipt, device: CompanionDevice, domains: Set<Domain>) -> Bool {
        guard Set(receipt.domainsAdmitted).isSubset(of: domains) else { return false }
        if Set(Domain.allCases).isSubset(of: domains) { return true }
        // Legacy receipts have no access label for the owner's raw question or stage notes.
        // Their retrieved domains cannot prove that free text is safe for a limited phone.
        return receipt.stages.contains {
            ($0.name == "companion.delivery"
                && $0.note?.hasPrefix("Acknowledged by paired device \(device.id.uuidString) (") == true
                && $0.note?.hasSuffix(" Grant \(device.grantID.uuidString).") == true)
            || ($0.name == "companion.request" && $0.note == Self.requestAuditContext(for: device).first?.note)
        }
    }
    static func requestAuditContext(for device: CompanionDevice) -> [ReceiptStage] {
        // Authentication metadata, not a timed operation or an acknowledgement of delivery.
        [ReceiptStage(name: "companion.request", milliseconds: 0,
            note: "Authenticated request from paired device \(device.id.uuidString). Grant \(device.grantID.uuidString).")]
    }
    /// History remains inside the exact authenticated grant and selected read scope. A stored
    /// source reference is not enough: decode the complete reasoning models before display.
    private func history(_ request: CompanionRequest, action: CompanionChatHistoryAction,
                         device: CompanionDevice, domains: Set<Domain>) async throws -> CompanionPreparedPage {
        guard request.query.isEmpty, request.recordID == nil, request.asOf == nil,
              request.answerMode == .chat else { throw CompanionError.invalidFrame }
        let scope = CompanionHistoryScope(deviceID: device.id, grantID: device.grantID,
            domains: domains, selectedDomain: request.domain.flatMap(Domain.init(rawValue:)))
        switch action {
        case .list:
            guard request.chatThreadID == nil else { throw CompanionError.invalidFrame }
            let page = try await store.companionHistoryPage(scope: scope, offset: request.offset) {
                Self.decodedHistory($0) != nil
            }
            var records: [CompanionRecord] = []
            var revisions: [(UUID, CompanionHistoryRevision)] = []
            for summary in page.threads {
                try Task.checkCancellation()
                guard let snapshot = try await store.companionHistory(scope: scope, thread: summary.id),
                      let exchanges = Self.decodedHistory(snapshot), let first = exchanges.first else { continue }
                let title = first.exchange.question.text.trimmingCharacters(in: .whitespacesAndNewlines)
                records.append(CompanionRecord(id: summary.id.uuidString,
                    title: title.isEmpty ? "Untitled" : String(title.prefix(60)),
                    domain: request.domain, date: exchanges.last?.exchange.answer.createdAt,
                    fields: [.init("Exchanges", String(exchanges.count))]))
                revisions.append((summary.id, snapshot.revision))
            }
            return try await preparedHistoryPage(CompanionPage(title: "Saved Chats", records: records,
                nextOffset: page.nextOffset, chatHistoryVersion: 1), scope: scope, revisions: revisions)
        case .open:
            guard request.offset == 0, let thread = request.chatThreadID,
                  let snapshot = try await store.companionHistory(scope: scope, thread: thread),
                  let exchanges = Self.decodedHistory(snapshot), !exchanges.isEmpty else { throw CompanionError.unauthorized }
            var records: [CompanionRecord] = []
            for item in exchanges {
                try Task.checkCancellation()
                let question = item.exchange.question, answer = item.exchange.answer
                records.append(CompanionRecord(id: "question-" + question.id, title: "You", body: question.text, date: question.createdAt))
                var answerRecord = CompanionRecord(id: answer.id, title: "OpenCore", body: answer.text, date: answer.createdAt,
                    fields: [.init("Prose author", answer.model ?? "No model author"),
                             .init("Ungrounded sentences", String(item.verdicts.filter { !$0.isGrounded }.count))])
                if let warning = answer.error { answerRecord.fields.append(.init("Warning", warning)) }
                records.append(answerRecord)
                records.append(contentsOf: item.sources.map { source in
                    CompanionRecord(id: "source-\(answer.id)-\(source.index)", title: "[\(source.index)] \(source.title)", body: source.text,
                        fields: [.init("Authority", source.authority.label)], objectID: source.objectID.value)
                })
                records.append(Self.receiptRecord(item.exchange.receipt))
            }
            return try await preparedHistoryPage(CompanionPage(title: "Saved Chat", records: records,
                chatHistoryVersion: 1, chatThreadID: thread), scope: scope, revisions: [(thread, snapshot.revision)])
        }
    }

    private func preparedHistoryPage(_ page: CompanionPage, scope: CompanionHistoryScope,
                                     revisions: [(UUID, CompanionHistoryRevision)]) async throws -> CompanionPreparedPage {
        let store = store
        var prepared = CompanionPreparedPage(page: page)
        prepared.validateDisclosure = {
            guard try await store.companionHistoryRevisionsAreAdmitted(scope: scope, revisions: revisions,
                admitting: { Self.decodedHistory($0) != nil }) else { throw CompanionError.unauthorized }
        }
        try await prepared.validateDisclosure()
        return prepared
    }
    private struct DecodedHistoryExchange {
        let exchange: CompanionHistoryExchange
        let sources: [GroundingSource]
        let verdicts: [Grounding.Verdict]
    }
    private static func decodedHistory(_ snapshot: CompanionHistorySnapshot) -> [DecodedHistoryExchange]? {
        let decoder = JSONDecoder()
        var result: [DecodedHistoryExchange] = []
        for exchange in snapshot.exchanges {
            guard let sources = try? decoder.decode([GroundingSource].self, from: Data(exchange.answer.sourcesJSON.utf8)),
                  let verdicts = try? decoder.decode([Grounding.Verdict].self, from: Data(exchange.answer.verdictsJSON.utf8)) else { return nil }
            result.append(DecodedHistoryExchange(exchange: exchange, sources: sources, verdicts: verdicts))
        }
        return result
    }
    private func evidenceAnswer(_ request: CompanionRequest, device: CompanionDevice, domains: Set<Domain>) async throws -> CompanionPreparedPage {
        let instant = now()
        let answer = try await Reasoner(store: store, tuning: tuning, now: instant).answer(request.query,
            asOfWorld: request.asOf, asOfKnowledge: request.asOf, persistReceipt: false, maximumDomains: domains, ownerDomain: request.domain.flatMap(Domain.init(rawValue:)))
        var records = [CompanionRecord(id: "answer", title: "Evidence answer", body: answer.summary)]
        for point in answer.points {
            records.append(CompanionRecord(id: point.claimID?.value ?? UUID().uuidString, title: point.statement,
                fields: [.init("Authority", point.authority.label), .init("Confidence", String(point.confidence)),
                    .init("Supporting evidence", point.supporting.map(\.snippet).joined(separator: "\n\n")),
                    .init("Counter-evidence", point.counter.map(\.snippet).joined(separator: "\n\n"))],
                links: Self.evidenceLinks(point.supporting + point.counter)))
        }
        for hit in answer.passages {
            records.append(CompanionRecord(id: hit.chunk.id.value, title: hit.object.title, body: hit.chunk.text,
                domain: hit.object.domain.rawValue, date: hit.object.authoredAt, objectID: hit.object.id.value))
        }
        let pending = CompanionPage(title: "Evidence answer", note: answer.insufficientEvidence ?? answer.report?.text ?? "Assembled by the same Mac Reasoner.",
            records: records, generatedAt: instant, receiptID: answer.receipt.id.value)
        let store = store, started = Date(), onDeliveryFailure = onDeliveryFailure
        let objectIDs = Set(answer.passages.map { $0.object.id } + answer.points.flatMap { ($0.supporting + $0.counter).map(\.objectID) })
        let passages = Reasoner.passageEvidence(answer.passages)
        guard try await store.companionAdditionalEvidenceIsCompatible(passages.map(\.0)) else { throw CompanionError.unauthorized }
        let linkedEvidence = Reasoner.linkedEvidence(Reasoner.rankedEvidence(answer.points), passages: passages)
        let claims = Set(answer.points.flatMap { $0.claimRows + ($0.claimID.map { [$0] } ?? []) }).sorted { $0.value < $1.value }
        let scope = CompanionHistoryScope(deviceID: device.id, grantID: device.grantID, domains: domains,
            selectedDomain: request.domain.flatMap(Domain.init(rawValue:)))
        return CompanionPreparedPage(page: pending) {
            var receipt = answer.receipt
            receipt.objectsTransmitted = max(receipt.objectsTransmitted, objectIDs.count)
            receipt.stages.append(ReceiptStage(name: "companion.delivery", counters: ["phone_objects": objectIDs.count],
                milliseconds: Int(Date().timeIntervalSince(started) * 1000), note: "Acknowledged by paired device \(device.id.uuidString) (\(device.name)). Grant \(device.grantID.uuidString)."))
            do {
                try await store.saveCompanionReceipt(receipt, scope: scope, representedObjects: objectIDs, referencedClaims: Set(claims),
                    evidence: linkedEvidence, claims: claims, additionalEvidence: passages.map(\.0))
            } catch {
                await onDeliveryFailure("An iPhone answer was acknowledged, but its receipt could not be saved.")
                throw error
            }
            var completed = pending; completed.records.append(Self.receiptRecord(receipt)); return completed
        }
    }
    private func chat(_ request: CompanionRequest, device: CompanionDevice, domains: Set<Domain>, progress: CompanionServer.Progress) async throws -> CompanionPreparedPage {
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return CompanionPreparedPage(page: CompanionPage(title: "Grounded Chat", note: "Ask your Mac about your history. Answers keep their sources, caveats and receipts.")) }
        // A per-device conversation preserves follow-ups; its scope is fixed at creation.
        // A changed domain selection or grant drops the prior context; unchanged selections keep follow-ups.
        let conversation: Conversation
        if let existing = conversations[device.id], existing.domains == domains, existing.grantID == device.grantID, existing.ownerDomain == request.domain {
            conversation = existing.conversation
        }
        else {
            conversation = Conversation(store: store, tuning: tuning, persistHistory: false, maximumDomains: domains,
                auditContext: Self.requestAuditContext(for: device), onAuditFailure: onAuditFailure)
            await conversation.configureGeneration(generation)
            if conversations.count >= 8 { conversations.removeAll() } // Chosen bound for in-memory model sessions.
            conversations[device.id] = ScopedConversation(domains: domains, grantID: device.grantID, ownerDomain: request.domain, conversation: conversation)
        }
        let turn = try await generateChat(request, conversation: conversation, progress: progress)
        return try await prepareChatDelivery(turn, device: device, domains: domains)
    }

    private func savedChat(_ request: CompanionRequest, device: CompanionDevice, domains: Set<Domain>,
                           progress _: CompanionServer.Progress) async throws -> CompanionPreparedPage {
        guard request.answerMode == .chat, request.chatHistoryAction == nil,
              request.recordID == nil, request.asOf == nil, request.offset == 0, request.resumeID == nil,
              !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let thread = request.chatThreadID else { throw CompanionError.invalidFrame }
        let scope = CompanionHistoryScope(deviceID: device.id, grantID: device.grantID, domains: domains,
            selectedDomain: request.domain.flatMap(Domain.init(rawValue:)))

        // Each operation owns a fresh actor, including while awaiting generation and ACK. No
        // unsaved or concurrent request can alter the context used for this answer.
        let conversation = Conversation(store: store, tuning: tuning, id: scope.conversationID(for: thread),
            persistHistory: false, maximumDomains: domains, auditContext: Self.requestAuditContext(for: device),
            onAuditFailure: onAuditFailure)
        let revision: CompanionHistoryRevision
        switch try await store.companionHistoryLookup(scope: scope, thread: thread) {
        case .missing:
            revision = .empty
        case .unavailable:
            throw CompanionError.unauthorized
        case .admitted:
            // Use the revision returned with the snapshot actually replayed by this actor,
            // not the earlier lookup or a refreshed value after generation.
            revision = try await conversation.restoreCompanionHistoryWithRevision(scope: scope, thread: thread).revision
        }
        await conversation.configureGeneration(generation)
        // Until each draft can revalidate every old and new source together, withhold it.
        let turn = try await generateChat(request, conversation: conversation, progress: { _ in })
        var prepared = try await prepareSavedChatDelivery(turn, request: request, device: device, domains: domains,
                                                           expectedRevision: revision)
        try await afterChatPreparation?()
        // The model may have used restored context or new sources that were restricted
        // during generation. Check both together before disclosing the prepared reply.
        guard var receipt = turn.receipt else { throw CompanionError.unauthorized }
        receipt.id = Store.companionReceiptID(for: request.id)
        let deliveredReceipt = receipt, store = store
        let representedObjects = GroundingSource.floorObjects(in: turn.sources)
        let claims = Set(turn.receiptClaims + turn.sources.compactMap(\.claimID))
        let evidenceIDs = turn.receiptEvidence.map(\.0) + turn.receiptPassages.map { $0.0.id }
        let additionalEvidence = turn.receiptPassages.map(\.0), answerID = turn.id, requestID = request.id
        prepared.validateDisclosure = {
            guard try await store.companionPreparedChatIsAdmitted(scope: scope, thread: thread, expectedRevision: revision,
                request: requestID, answerID: answerID, receipt: deliveredReceipt, representedObjects: representedObjects,
                referencedClaims: claims, evidenceIDs: evidenceIDs, additionalEvidence: additionalEvidence)
            else { throw CompanionError.unauthorized }
        }
        try await prepared.validateDisclosure()
        return prepared
    }

    private func generateChat(_ request: CompanionRequest, conversation: Conversation,
                              progress: CompanionServer.Progress) async throws -> Turn {
        if let chatGenerator {
            let turn = try await chatGenerator(request, conversation, progress)
            try Task.checkCancellation()
            return turn
        }
        var final: Turn?
        var lastProgress = Date.distantPast
        for await turn in conversation.send(request.query, ownerDomain: request.domain.flatMap(Domain.init(rawValue:))) {
            try Task.checkCancellation()
            final = turn
            if turn.streaming, !turn.text.isEmpty, Date().timeIntervalSince(lastProgress) >= 0.25 {
                lastProgress = Date()
                try await progress(CompanionPage(title: "Draft", note: "Unverified draft from your Mac. Grounding checks and the receipt arrive when it finishes.",
                    records: [CompanionRecord(id: "draft", title: "Draft", body: turn.text)]))
            }
        }
        try Task.checkCancellation()
        guard let turn = final else { throw CompanionError.disconnected }
        return turn
    }
    /// Kept separate from generation so provenance and acknowledgement can be tested on
    /// temporary stores without running a model or connecting to any device.
    func prepareChatDelivery(_ turn: Turn, device: CompanionDevice, domains: Set<Domain>) async throws -> CompanionPreparedPage {
        try await preparedChatDelivery(turn, device: device, domains: domains, saved: nil)
    }
    private struct SavedDelivery: Sendable {
        let scope: CompanionHistoryScope
        let thread: UUID
        let request: CompanionRequest
        let digest: String
        let expectedRevision: CompanionHistoryRevision
    }
    /// Construct a saved delivery but do not persist it until the phone acknowledges it.
    /// Generation wiring uses this separately from the legacy per-device conversation.
    func prepareSavedChatDelivery(_ turn: Turn, request: CompanionRequest, device: CompanionDevice,
                                  domains: Set<Domain>, expectedRevision: CompanionHistoryRevision) async throws -> CompanionPreparedPage {
        guard request.section == .chat, request.answerMode == .chat, request.chatHistoryAction == nil,
              request.recordID == nil, request.asOf == nil, request.offset == 0, request.resumeID == nil,
              !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let thread = request.chatThreadID, turn.role == .core, var receipt = turn.receipt,
              receipt.query == request.query else { throw CompanionError.invalidFrame }
        let granted = Set(device.domains.compactMap(Domain.init(rawValue:)))
        let selected: Domain?
        if let raw = request.domain {
            guard let domain = Domain(rawValue: raw), granted.contains(domain),
                  domains == granted.intersection(domain.readableDomains) else { throw CompanionError.unauthorized }
            selected = domain
        } else {
            guard domains == granted else { throw CompanionError.unauthorized }
            selected = nil
        }
        guard !domains.isEmpty else { throw CompanionError.unauthorized }
        let scope = CompanionHistoryScope(deviceID: device.id, grantID: device.grantID, domains: domains, selectedDomain: selected)
        let saved = SavedDelivery(scope: scope, thread: thread, request: request,
            digest: CompanionChatFingerprint.hex(request), expectedRevision: expectedRevision)
        var response = turn
        receipt.id = Store.companionReceiptID(for: request.id)
        response.receipt = receipt
        return try await preparedChatDelivery(response, device: device, domains: domains, saved: saved)
    }
    private func preparedChatDelivery(_ turn: Turn, device: CompanionDevice, domains: Set<Domain>,
                                      saved: SavedDelivery?) async throws -> CompanionPreparedPage {
        guard turn.hasDeliverableAnswer, let original = turn.receipt, Set(original.domainsAdmitted).isSubset(of: domains) else { throw CompanionError.unauthorized }
        var transmitted = Set<ObjectID>()
        for id in GroundingSource.floorObjects(in: turn.sources) {
            guard let object = try await store.object(id), domains.contains(object.domain) else { throw CompanionError.unauthorized }
            transmitted.insert(id)
        }
        for (id, _) in turn.receiptEvidence {
            guard let evidence = try await store.evidence(id: id), let object = try await store.object(evidence.objectID), domains.contains(object.domain) else { throw CompanionError.unauthorized }
        }
        for (evidence, _) in turn.receiptPassages {
            guard let object = try await store.object(evidence.objectID), domains.contains(object.domain) else { throw CompanionError.unauthorized }
        }
        guard try await store.companionAdditionalEvidenceIsCompatible(turn.receiptPassages.map(\.0)) else { throw CompanionError.unauthorized }
        let linkedClaims = Set(turn.receiptClaims + turn.sources.compactMap(\.claimID)).sorted { $0.value < $1.value }
        for id in linkedClaims {
            guard try await store.ownerAdmitsClaim(id, domains: domains) else { throw CompanionError.unauthorized }
        }
        var records = [CompanionRecord(id: turn.id.uuidString, title: "OpenCore", body: turn.text,
            fields: [.init("Prose author", turn.modelName ?? "No model author"), .init("Ungrounded sentences", String(turn.ungrounded.count))])]
        if let warning = turn.error { records[0].fields.append(.init("Generation warning", warning)) }
        if let warning = turn.persistenceError { records[0].fields.append(.init("Audit warning", warning)) }
        for source in turn.sources {
            records.append(CompanionRecord(id: "source-\(source.index)", title: "[\(source.index)] \(source.title)", body: source.text,
                fields: [.init("Authority", source.authority.label)], objectID: source.objectID.value))
        }
        let pending = CompanionPage(title: "Grounded Chat", note: "Awaiting delivery acknowledgement", records: records, receiptID: original.id.value)
        let storedAnswer: StoredTurn?
        if let saved {
            let encoder = JSONEncoder()
            let sourcesJSON = String(decoding: try encoder.encode(turn.sources), as: UTF8.self)
            let verdictsJSON = String(decoding: try encoder.encode(turn.verdicts), as: UTF8.self)
            let warnings = [turn.error, turn.persistenceError.map { "Audit warning: " + $0 }].compactMap { $0 }
            storedAnswer = StoredTurn(id: turn.id.uuidString, conversationID: saved.scope.conversationID(for: saved.thread),
                ordinal: 0, role: "core", text: turn.text, sourcesJSON: sourcesJSON, verdictsJSON: verdictsJSON,
                receiptID: original.id, model: turn.modelName, error: warnings.isEmpty ? nil : warnings.joined(separator: "\n"), createdAt: now())
        } else { storedAnswer = nil }
        let store = store
        let onDeliveryFailure = onDeliveryFailure
        let receiptScope = CompanionHistoryScope(deviceID: device.id, grantID: device.grantID, domains: domains, selectedDomain: nil)
        let transmittedObjects = transmitted
        let objectCount = transmitted.count
        var ranked = turn.receiptEvidence
        for (evidence, score) in turn.receiptPassages where !ranked.contains(where: { $0.0 == evidence.id }) { ranked.append((evidence.id, score)) }
        let linkedEvidence = ranked
        let started = Date()
        return CompanionPreparedPage(page: pending) {
            var receipt = original
            // Current cloud and phone chat use this same represented source set, not arbitrary
            // independent sets. The delivery stage keeps its own per-channel count.
            receipt.objectsTransmitted = max(receipt.objectsTransmitted, objectCount)
            receipt.stages.append(ReceiptStage(name: "companion.delivery", counters: ["phone_objects": objectCount],
                milliseconds: Int(Date().timeIntervalSince(started) * 1000), note: "Acknowledged by paired device \(device.id.uuidString) (\(device.name)). Grant \(device.grantID.uuidString)."))
            let delivered: Receipt
            do {
                if let saved, let storedAnswer {
                    delivered = try await store.saveCompanionExchange(scope: saved.scope, thread: saved.thread,
                        request: saved.request.id, requestDigest: saved.digest, question: saved.request.query,
                        answer: storedAnswer, receipt: receipt, expectedRevision: saved.expectedRevision,
                        evidence: linkedEvidence, claims: linkedClaims,
                        additionalEvidence: turn.receiptPassages.map(\.0))
                } else {
                    try await store.saveCompanionReceipt(receipt, scope: receiptScope, representedObjects: transmittedObjects,
                        referencedClaims: Set(linkedClaims), evidence: linkedEvidence, claims: linkedClaims,
                        additionalEvidence: turn.receiptPassages.map(\.0))
                    delivered = receipt
                }
            } catch {
                let message = saved == nil ? "An iPhone answer was acknowledged, but its receipt could not be saved."
                    : "An iPhone answer was acknowledged, but its conversation and receipt could not be saved."
                await onDeliveryFailure(message)
                throw error
            }
            var completed = pending; completed.note = "Generated on your Mac. Delivery acknowledged."
            if let saved { completed.chatHistoryVersion = 1; completed.chatThreadID = saved.thread }
            completed.records.append(Self.receiptRecord(delivered))
            return completed
        }
    }
    private func admittedReason(_ belief: Belief, domains: Set<Domain>) async throws -> String {
        guard let predecessor = belief.supersedes else { return belief.reason }
        guard let previous = try await store.beliefHistory(key: belief.claimKey).first(where: { $0.id == predecessor }),
              try await store.ownerAdmitsClaim(previous.claimID, domains: domains) else { return "Replaced a value outside this device's admitted domains." }
        return belief.reason
    }
    private static func evidenceLinks(_ evidence: [Evidence]) -> [CompanionRecordLink] {
        distinctLinks(evidence.map { CompanionRecordLink(.object, $0.objectID.value, "Open source \($0.objectID.value.prefix(8))") })
    }
    /// Keep the first label for each byte-exact target, so SwiftUI sees one stable identity.
    static func distinctLinks(_ links: [CompanionRecordLink]) -> [CompanionRecordLink] {
        var seen = Set<String>()
        return links.filter { seen.insert($0.id).inserted }
    }
    private func claimRecord(_ claim: CoreClaim, domains: Set<Domain>) async throws -> CompanionRecord {
        let subject = try await store.entity(claim.subject)?.canonicalName ?? "Unknown subject"
        let target = if let id = claim.objectEntity { try await store.entity(id)?.canonicalName ?? "Unknown target" } else { claim.literal ?? "" }
        var supporting: [String] = [], refuting: [String] = [], links: [CompanionRecordLink] = []
        for (evidence, stance, _) in try await store.evidence(for: claim.id) {
            guard let object = try await store.object(evidence.objectID), domains.contains(object.domain) else { continue }
            if stance == .supports { supporting.append(evidence.snippet) } else { refuting.append(evidence.snippet) }
            let link = CompanionRecordLink(.object, object.id.value, object.title)
            links.append(link)
        }
        return CompanionRecord(id: claim.id.value, title: "\(subject) · \(claim.predicate)", body: target,
            domain: claim.domain.rawValue, date: claim.validity.observedAt,
            fields: [.init("Authority", claim.authority.label), .init("Confidence", String(claim.confidence)),
                     .init("Derivation", claim.derivation.rawValue), .init("Valid from", claim.validity.validFrom.map(Self.date) ?? "not recorded"),
                     .init("Valid to", claim.validity.validTo.map(Self.date) ?? "not recorded"),
                     .init("Supporting evidence", supporting.joined(separator: "\n\n")), .init("Counter-evidence", refuting.joined(separator: "\n\n"))], links: Self.distinctLinks(links))
    }
    private static func objectRecord(_ object: CoreObject) -> CompanionRecord {
        CompanionRecord(id: object.id.value, title: object.title, body: object.text, domain: object.domain.rawValue,
            date: object.authoredAt, fields: [.init("Kind", object.kind.rawValue), .init("Authority", object.authority.label),
                .init("Ingested", date(object.ingestedAt)), .init("External ID", object.externalID),
                .init("URI", object.uri ?? "not recorded"),
                .init("Metadata", String(decoding: (try? JSONEncoder().encode(object.metadata)) ?? Data(), as: UTF8.self))])
    }
    public static func receiptRecord(_ receipt: Receipt) -> CompanionRecord {
        let data = (try? JSONEncoder().encode(receipt)) ?? Data()
        return CompanionRecord(id: receipt.id.value, title: "\(receipt.isRequestAudit ? "Cloud request audit" : "Receipt") · \(receipt.shortCode)", body: receipt.query, date: receipt.createdAt,
            fields: [.init("Prose author", receipt.model ?? "No model author"), .init("Outbound activity", receipt.outboundDescription),
                .init("Acknowledged object count", String(receipt.objectsTransmitted)),
                .init("Confidence", receipt.confidence.map(String.init(describing:)) ?? "not measured"),
                .init("Admitted domains", receipt.domainsAdmitted.map(\.rawValue).joined(separator: ", ")),
                .init("Blocked domains", receipt.domainsBlocked.map(\.rawValue).joined(separator: ", ")),
                .init("Complete receipt", String(decoding: data, as: UTF8.self))])
    }
    private static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    private static func metrics(_ counts: (objects: Int, passages: Int, claims: Int, entities: Int)) -> [CompanionField] {
        [.init("Objects", String(counts.objects)), .init("Passages", String(counts.passages)), .init("Admitted claims", String(counts.claims)), .init("Entities", String(counts.entities))]
    }
    private static func paged(_ request: CompanionRequest, records: [CompanionRecord], metrics: [CompanionField] = []) -> CompanionPage {
        CompanionPage(title: request.section.title, records: Array(records.prefix(40)), metrics: metrics, nextOffset: records.count > 40 ? request.offset + 40 : nil)
    }
    private static func slice(_ request: CompanionRequest, records: [CompanionRecord], note: String = "") -> CompanionPage {
        let filtered = records.filter { request.query.isEmpty || $0.title.localizedCaseInsensitiveContains(request.query)
            || $0.body.localizedCaseInsensitiveContains(request.query) || $0.fields.contains(where: { $0.value.localizedCaseInsensitiveContains(request.query) }) }
        let visible = filtered.dropFirst(request.offset)
        var page = paged(request, records: Array(visible.prefix(41))); page.note = note; return page
    }
}
