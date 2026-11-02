import CoreGraph
import CoreModel
import CoreSearch
import CoreStore
import CoreTelemetry
import Foundation

/// A cited statement in an answer.
public struct AnswerPoint: Sendable {
    public var statement: String
    public var supporting: [Evidence]
    public var counter: [Evidence]
    public var confidence: Double
    public var authority: Authority
    public var derivation: Derivation
    public var claimID: ClaimID?
    /// Carried so an answer can be ordered by what the question named.
    public var subject: EntityID
    public var predicate: String
    /// The entity in the value position, when there is one. A line that joins two things the
    /// question named, such as "OpenCore is built with Swift", is the most direct answer it has.
    public var object: EntityID? = nil
    /// Every claim row behind this line. `claimID` is only the strongest of them: one fact
    /// re-observed five times is one line and five rows, and a receipt counts rows.
    public var claimRows: [ClaimID] = []
}

public struct Answer: Sendable {
    public var summary: String
    public var points: [AnswerPoint]
    /// The passages retrieval actually surfaced.
    ///
    /// Carried alongside the claims because the two answer different questions. A claim says
    /// what the store believes; a passage shows the text it was believed from, including for
    /// sources that produce no claims at all. Without this, asking about a calendar event
    /// returned nothing even though the event was sitting in the index.
    public var passages: [PassageHit]
    public var contradictions: [Contradiction]
    public var receipt: Receipt
    public var insufficientEvidence: String?

    /// Set when the question was a count, computed over every admitted row rather than read off
    /// retrieved passages.
    ///
    /// **Explicit rather than inferred from empty `points`.** A counted answer and an answer
    /// that found nothing both have no points and no passages, and a caller that tells them
    /// apart by emptiness will eventually render "12 of 22 repositories" as "no evidence
    /// found". This is the same reason the counted receipt is a distinct shape instead of a
    /// retrieval receipt with zeroes in it.
    public var counted: AggregateAnswer?

    /// The stretch of time the question named, when it named one. Everything else in this
    /// answer has been filtered to it.
    public var window: QueryTimeWindow?

    /// What happened in `window`, busiest subject first. A question about a stretch of time
    /// is answered from the event log: "what was I working on" is a question about what
    /// happened, and no passage says that.
    public var activity: ActivitySummary?

    /// Which days this answer read and how fresh the store was. Also at the end of `summary` and
    /// `insufficientEvidence`, so a surface printing either one cannot leave it out.
    public var report: WindowReport?

    /// The text retrieval searched, when that was not the question. It is the question without
    /// its time phrase, or empty when the answer is the event log and there was nothing to look
    /// for. A caller running its own retrieval for this answer must use this and `window`, or it
    /// searches all of time beneath an answer that says it did not.
    public var searchedText: String?

    /// Set when the question was about the owner's calendar or reminders. The list is `summary`,
    /// read from objects, with no claims or passages behind it. See `AgendaIntent`.
    public var agenda: AgendaAnswer?

    /// True when the passages are the answer and the claims are only about the projects those
    /// passages came from. With no subject named, a claim like "a project is built with CloudKit" is
    /// context, and leading with it answered a question nobody asked.
    public var passagesLead = false
}

extension Answer {
    /// This answer as a Shortcut or Siri prints it, with `brief` if a model wrote one.
    ///
    /// Here rather than in the app, which has no test target. The window lines sit inside
    /// `summary` and `insufficientEvidence`, and a brief replaces both, so "what did I decide
    /// about retrieval this month" came back filtered to the month with nothing saying so, on a
    /// store that might have stopped syncing.
    public func shortcutText(brief: String?) -> String {
        let code = "[receipt \(receipt.shortCode)]"
        if let counted { return "\(counted.sentence) \(code)" }

        if let brief {
            var parts = [brief]
            if !points.isEmpty {
                parts.append("Stored claims:\n\(shortcutClaims(limit: 4))")
            }
            if let report { parts.append(report.text) }
            return parts.joined(separator: "\n\n") + "\n\(code)"
        }
        if let insufficientEvidence { return "Not enough evidence: \(insufficientEvidence) \(code)" }

        let statements = shortcutClaims(limit: 5)
        return statements.isEmpty ? "\(summary) \(code)" : "\(summary)\nStored claims:\n\(statements)\n\(code)"
    }

    private func shortcutClaims(limit: Int) -> String {
        points.prefix(limit).map { point in
            var lines = ["• \(point.statement) (\(point.authority.label))"]
            if point.derivation == .inferred { lines.append("  Inferred by OpenCore from other records. No source states this.") }
            for evidence in point.counter.prefix(Conversation.caveatsShown) {
                let quote = evidence.snippet.replacingOccurrences(of: "\n", with: " ").prefix(Conversation.caveatLength)
                lines.append("  Counter-evidence: \(quote)")
            }
            let rows = Set(point.claimRows + (point.claimID.map { [$0] } ?? []))
            let standing = contradictions.filter { Reasoner.standsAgainst($0, rows: rows) }.sorted {
                ($0.resolution == .unresolved ? 0 : 1, $0.id.value) < ($1.resolution == .unresolved ? 0 : 1, $1.id.value)
            }
            for contradiction in standing.prefix(Conversation.caveatsShown) {
                let label = contradiction.resolution == .unresolved ? "Open contradiction" : "Overruled"
                let reason = contradiction.reason.replacingOccurrences(of: "\n", with: " ").prefix(Conversation.caveatLength)
                lines.append("  \(label): \(reason)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// Plans a query, gathers evidence, and assembles an answer.
///
/// Runs on `PassageSearch`: both retrieval legs, RRF fusion, MMR. It previously used the
/// object-level `HybridSearch`, which meant the app built embeddings it then never searched
/// and the whole dense path was unreachable from the primary surface.
///
/// No model is involved. Claims are rendered from rows, and passages are quoted verbatim, so
/// every line has something behind it and the receipt's counters are measurements. A language
/// model can be added later to write the prose; it would enter at `Authority.modelInference`
/// and would not be permitted to introduce a claim that is not already in the store.
public struct Reasoner: Sendable {
    let store: Store
    private let search: PassageSearch
    private let classifier = QueryClassifier()
    /// Read once per answer, not once per `Reasoner`. `MCPServer` holds one of these for the life
    /// of a process, and clients keep that process for days, so a captured date meant "last
    /// week" was the week before the server started.
    private let currentDate: @Sendable () -> Date
    private let currentCalendar: @Sendable () -> Calendar

    /// Below this blended score a hit is noise. Named rather than inlined, because a silent
    /// relevance floor is how a system ends up answering confidently from nothing.
    ///
    /// Tuned for RRF output, which is small: a single-leg top hit contributes ~0.016 and
    /// appearing at the top of both contributes ~0.033. The object-level scorer this replaced
    /// produced 0...1 scores and used 0.15, which would have rejected everything here.
    public static let relevanceFloor = 0.005

    public init(
        store: Store,
        search: PassageSearch,
        now: @autoclosure @escaping @Sendable () -> Date = Date(),
        calendar: @autoclosure @escaping @Sendable () -> Calendar = .current
    ) {
        self.store = store
        self.search = search
        self.currentDate = now
        self.currentCalendar = calendar
    }

    /// Convenience for callers that have not built a `PassageSearch` themselves.
    public init(
        store: Store,
        embedder: (any EmbeddingProvider)? = nil,
        tuning: RetrievalTuning = .default,
        now: @autoclosure @escaping @Sendable () -> Date = Date(),
        calendar: @autoclosure @escaping @Sendable () -> Calendar = .current
    ) {
        self.init(
            store: store,
            search: PassageSearch(store: store, embedder: embedder, tuning: tuning),
            now: now(),
            calendar: calendar()
        )
    }

    /// - Parameter externalCaller: `true` when the query text was written by something other
    ///   than the user. Naming a sensitive domain is consent when a person types it and
    ///   nothing at all when a model generates it, so an external caller can neither unlock a
    ///   sensitive domain nor be classified into one.
    public func answer(
        _ query: String,
        limit: Int = 12,
        externalCaller: Bool = false,
        asOfWorld: Date? = nil,
        asOfKnowledge: Date? = nil,
        persistReceipt: Bool = true,
        maximumDomains: Set<Domain>? = nil,
        ownerDomain: Domain? = nil,
        retrievalQuery: String? = nil
    ) async throws -> Answer {
        try await Telemetry.span("answer", .reason, attributes: ["externalCaller": String(externalCaller)]) { answer in
        let recorder = ReceiptRecorder()

        let classification = classifier.classify(query)
        // "As of" moves the clock, so "last week" in a past checkout means the week before that
        // checkout rather than the week before today.
        let calendar = currentCalendar()
        let window = TemporalIntent.window(in: query, now: asOfWorld ?? asOfKnowledge ?? currentDate(), calendar: calendar)
        let surfaces = try await store.aliasSurfaces()
        let (rawDomain, _) = AdmissionPolicy.classifyDomain(query, knownEntitySurfaces: surfaces)
        let policy = AdmissionPolicy.forQuestion(query, knownEntitySurfaces: surfaces, externalCaller: externalCaller,
                                                 ownerDomain: ownerDomain, maximumDomains: maximumDomains)
        let domain = policy.queryDomain
        answer.attribute("queryClass", classification.queryClass.rawValue)
        answer.attribute("matchedOn", classification.matchedOn)
        answer.attribute("domain", domain.rawValue)
        // Downgrading a sensitive query because the caller came in over MCP is a security
        // decision, and one that changes the answer. It is recorded as an event so it appears
        // in the tree rather than only as a differing `domain` attribute nobody compares.
        if externalCaller && rawDomain != domain {
            Telemetry.event("domain.downgraded", .reason, attributes: ["from": rawDomain.rawValue, "to": "project"])
        }

        // A counting question is computed over every admitted row, never read off the passages
        // that happened to be retrieved. Placed after the firewall so the count runs under
        // exactly the domains retrieval would have been allowed to read, which matters more
        // here than in chat: `externalCaller` has already re-based a sensitive query to
        // `.project`, and a count that ignored `policy` would hand an MCP caller a figure
        // derived from rows the same caller is forbidden to retrieve.
        //
        // Not with a window. `AggregateAnswering` counts every row there has ever been. It
        // declines a bare "how many commits last week", because those words are a qualifier it
        // cannot place, but a question that also matches a facet gets through: "how many
        // repositories are archived this month" returned the all-time figure, stated flat,
        // under a question that named a month. The event log is what can be cut by date.
        //
        // "These days" names no span. It asks how things stand, which is what this counts, and
        // sending it to the event log lost a correct figure.
        let countable: String? = if let window { window.meansNow ? window.residualQuery : nil } else { query }
        if classification.queryClass == .aggregate, let countable,
           let counted = try await AggregateAnswering(store: store)
               .answer(countable, admitting: policy.admitted) {
            _ = await recorder.record("count") {
                (counted, ["objects_counted": counted.breakdown.total, "groups": counted.breakdown.counts.count])
            }
            let receipt = counted.receipt(
                query: query,
                domainsAdmitted: policy.admitted.sorted { $0.rawValue < $1.rawValue },
                domainsBlocked: policy.blocked.sorted { $0.rawValue < $1.rawValue },
                milliseconds: await recorder.allStages().reduce(0) { $0 + $1.milliseconds }
            )
            if persistReceipt {
                try await store.save(receipt)
            }
            answer.attribute("counted", counted.matchedOn)
            answer.set("objectsCounted", counted.breakdown.total)
            return Answer(
                summary: counted.sentence,
                points: [],
                passages: [],
                contradictions: [],
                receipt: receipt,
                insufficientEvidence: nil,
                counted: counted
            )
        }

        // After the count, so "how many doctor appointments do I have" stays a count. Calendar and
        // reminders hold dates and flags, and no claims, so this reads them directly.
        // Never for an external caller, whose wording is not the owner's. `ownerDomain` wins when
        // the owner chose a scope, and a limited phone's ceiling still applies through
        // `maximumDomains`: `AgendaAnswering` declines without `.personal`, and the path below runs.
        if !externalCaller, asOfWorld == nil, asOfKnowledge == nil,
           let question = AgendaIntent.read(query, now: currentDate(), calendar: calendar) {
            let owner = AdmissionPolicy.forQuestion(query, ownerDomain: ownerDomain ?? .personal, maximumDomains: maximumDomains)
            let started = DispatchTime.now().uptimeNanoseconds
            if let agenda = try await AgendaAnswering(store: store).answer(question, policy: owner, now: currentDate(), calendar: calendar) {
                let receipt = agenda.receipt(
                    query: query, queryClass: classification.queryClass,
                    domainsAdmitted: owner.admitted.sorted { $0.rawValue < $1.rawValue },
                    domainsBlocked: owner.blocked.sorted { $0.rawValue < $1.rawValue },
                    milliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                )
                if persistReceipt { try await store.save(receipt) }
                answer.attribute("agenda", "true")
                return Answer(summary: agenda.sentence, points: [], passages: [], contradictions: [], receipt: receipt,
                              insufficientEvidence: nil, window: question.window, agenda: agenda)
            }
        }

        // What the question is about, read before retrieval so a name in the question can pull
        // its entity in even when no retrieved passage happens to mention it.
        // Retrieval anchors carry context, never consent. Admission above always uses the
        // current raw question or the owner's explicit selection. External callers cannot add anchors.
        let retrievalText = externalCaller ? query : retrievalQuery ?? query
        let residual = window.map { TemporalIntent.residual(of: retrievalText, removing: [$0.phrase]) } ?? retrievalText
        let focus = try await QueryFocus.read(from: residual, store: store, policy: policy, externalCaller: externalCaller)
        let listedStatus = focus.entities.isEmpty && window == nil ? QueryFocus.statusAsked(in: residual) : nil

        let report = if let window {
            try await store.windowReport(window, domains: policy.admitted, calendar: calendar)
        } else {
            WindowReport?.none
        }

        // A time question with no subject has nothing to search *for*: the words left over are
        // "what was I working on". Its answer is the activity below, and searching for
        // "working" would only attach unrelated passages that happen to fall in the window.
        let asksCount = classification.queryClass == .aggregate
        let hasTopic = window == nil || (!asksCount && (!TemporalIntent.isSubjectless(residual) || !focus.entities.isEmpty))
        // The event log answers a question about a subject or about nothing in particular. A
        // question about a topic is answered by passages from the window, and listing every
        // repository's week above "what did I decide about retrieval" answers something else.
        let readsActivity = window != nil && (!hasTopic || !focus.entities.isEmpty)
        // What the question wanted counted and the event log cannot pick out.
        let uncounted = asksCount ? TemporalIntent.unplacedTerms(in: residual, naming: focus.namedWords) : []

        var activity: ActivitySummary?
        if let window, let report, readsActivity {
            activity = try await recorder.record("activity", note: report.stageNote) {
                let summary = try await store.activity(
                    from: window.start,
                    to: window.end,
                    domains: policy.admitted,
                    subjects: focus.entities.isEmpty ? nil : Set(focus.entities)
                )
                return (summary, ["events_in_window": summary.totalEvents, "subjects": summary.totalSubjects])
            }
        } else if let report {
            // Recorded here too, so a topical answer's trace still shows the days it read.
            await recorder.record("window", note: report.stageNote) {
                ((), ["sources_reported": report.freshness.sources.count, "sources_behind": report.behind.count])
            }
        }

        let outcome = try await recorder.record(
            "retrieve",
            note: "\(classification.queryClass.rawValue) via \(classification.matchedOn)"
        ) {
            let result = try await search.search(
                query: hasTopic ? residual : "",
                queryClass: classification.queryClass,
                policy: policy,
                limit: limit,
                window: window?.interval,
                // A blocked count answers "does this exist" for a term the caller cannot
                // read. A model writing the query can use that as an oracle, one rare word
                // at a time, so only the user sees it.
                reportBlocked: !externalCaller
            )
            return (result, [
                "chunks_searched": result.chunksSearched,
                "lexical": result.lexicalCandidates,
                "dense": result.denseCandidates,
                "fused": result.afterFusion,
                "blocked_by_domain": result.blockedByDomain,
                "retrieved": result.hits.count,
            ])
        }

        let relevant = try await aboutNamedFirst(
            outcome.hits.filter { $0.score >= Self.relevanceFloor },
            focus: hasTopic ? focus : .none,
            policy: policy
        )

        let (points, claimIDs) = try await recorder.record("assemble-claims") {
            let assembled = try await assemble(
                hits: relevant,
                focus: hasTopic ? focus : .none,
                window: window,
                policy: policy,
                listedStatus: listedStatus,
                asOfWorld: asOfWorld,
                asOfKnowledge: asOfKnowledge
            )
            return (assembled, ["claims_consulted": assembled.1.count, "points": assembled.0.count])
        }

        let contradictions = try await recorder.record("check-contradictions") {
            let touching = try await contradictions(touching: claimIDs, policy: policy)
            return (touching, ["surfaced": touching.count, "unresolved": touching.filter { $0.resolution == .unresolved }.count])
        }

        let passageEvidence = Self.passageEvidence(relevant)
        let rankedEvidence = Self.linkedEvidence(Self.rankedEvidence(points), passages: passageEvidence)

        let receipt = Receipt(
            query: query,
            queryClass: classification.queryClass,
            domainsAdmitted: policy.admitted.sorted { $0.rawValue < $1.rawValue },
            domainsBlocked: policy.blocked.sorted { $0.rawValue < $1.rawValue },
            stages: await recorder.allStages(),
            // With no topic the rows read were events, in the units chat writes for this case.
            objectsSearched: hasTopic ? outcome.chunksSearched : (activity?.totalEvents ?? 0),
            objectsRetrieved: relevant.count,
            evidenceAdmitted: rankedEvidence.count,
            claimsConsulted: claimIDs.count,
            contradictionsSurfaced: contradictions.count,
            // No model ran. Recorded as absent rather than as a plausible name.
            model: nil,
            objectsTransmitted: 0,
            // No calibrated confidence exists for this pipeline. Stays nil, renders as
            // "not measured", until an eval harness produces a real number.
            confidence: nil
        )

        if persistReceipt {
            try await store.save(receipt, evidence: rankedEvidence, claims: claimIDs.sorted { $0.value < $1.value },
                                 additionalEvidence: passageEvidence.map(\.0))
        }

        var insufficient: String?
        if relevant.isEmpty && points.isEmpty && (activity?.totalEvents ?? 0) == 0 {
            if let window, let report {
                // A quiet stretch and a store nobody has synced look identical otherwise.
                insufficient = "Nothing recorded from \(window.span(in: calendar)).\n\(report.text)"
            } else {
                insufficient = outcome.hits.isEmpty
                    ? "Nothing matched. \(outcome.chunksSearched) passages searched."
                    : "\(outcome.hits.count) passages matched but none cleared the relevance floor of \(Self.relevanceFloor)."
            }
            if outcome.blockedByDomain > 0 {
                insufficient! += " \(outcome.blockedByDomain) were withheld by domain policy."
            }
        }

        answer.set("hits", outcome.hits.count)
        answer.set("aboveFloor", relevant.count)
        answer.set("points", points.count)
        answer.set("claims", claimIDs.count)
        answer.set("contradictions", contradictions.count)
        answer.attribute("receipt", receipt.shortCode)
        // The gap between hits and aboveFloor is the relevance floor's work. A run where
        // everything retrieved was then discarded looks identical to one that retrieved
        // nothing, unless both numbers are present.
        if relevant.isEmpty && !outcome.hits.isEmpty {
            Telemetry.event("relevanceFloor.rejectedAll", .reason, attributes: [
                "floor": String(Self.relevanceFloor),
                "hits": String(outcome.hits.count),
            ])
        }

        let summary = summarise(
            points: points, passages: relevant, outcome: outcome, window: window, activity: activity,
            uncounted: uncounted, listedStatus: listedStatus, focus: hasTopic ? focus : .none, calendar: calendar
        )
        return Answer(
            summary: report.map { "\(summary)\n\($0.text)" } ?? summary,
            points: points,
            passages: relevant,
            contradictions: contradictions,
            receipt: receipt,
            insufficientEvidence: insufficient,
            window: window,
            activity: activity,
            report: report,
            searchedText: window == nil ? nil : (hasTopic ? residual : ""),
            passagesLead: listedStatus == nil && activity == nil && focus.entities.isEmpty && !relevant.isEmpty
        )
        }
    }

    // MARK: - Assembly

    private func assemble(
        hits: [PassageHit],
        focus: QueryFocus,
        window: QueryTimeWindow?,
        policy: AdmissionPolicy,
        listedStatus: String? = nil,
        asOfWorld: Date? = nil,
        asOfKnowledge: Date? = nil
    ) async throws -> ([AnswerPoint], Set<ClaimID>) {
        // A question that names a subject is about that subject. Pooling every entity that any
        // passage touched is what buried "OpenClinic is active" under a page of other
        // repositories' languages.
        //
        // With no name, the best passages say what it is about and the rest are only near it.
        // Pooling all twelve answered "what did I decide about iCloud" with 50 claims from every
        // project they touched, measured 2026-11-02.
        var subjects = Set(focus.entities)
        if focus.entities.isEmpty, listedStatus == nil {
            for hit in hits.prefix(Self.subjectPassages) {
                subjects.formUnion(try await entities(in: hit.object, policy: policy))
            }
        }

        let currentOnly = asOfWorld == nil && asOfKnowledge == nil
        var rows: [(claim: CoreClaim, subject: CoreEntity)] = []
        var namedWithClaims = Set<EntityID>()
        for subject in subjects.sorted(by: { $0.value < $1.value }) {
            guard let entity = try await store.entity(subject), policy.admits(entity.domain) else { continue }
            for claim in try await store.claims(subject: subject, currentOnly: currentOnly, asOfWorld: asOfWorld, asOfKnowledge: asOfKnowledge) {
                guard try await ClaimAdmission.admits(claim, policy: policy, store: store) else { continue }
                rows.append((claim, entity))
                if focus.names(subject) { namedWithClaims.insert(subject) }
            }
        }

        // A named thing can be what a claim points at rather than what it is about: every fact
        // about Swift reads "OpenClinic is built with Swift", and Swift is the subject of
        // nothing. Reading only subjects answered "which projects use Swift" with no claims at
        // all, on a store with 53 of them.
        //
        // Skipped when another named entity has claims of its own. "Does OpenCore use Swift" is
        // about OpenCore, and every other Swift repository is not part of the answer.
        for named in focus.entities where namedWithClaims.subtracting([named]).isEmpty {
            for claim in try await store.claims(pointingAt: named, currentOnly: currentOnly, asOfWorld: asOfWorld, asOfKnowledge: asOfKnowledge) {
                guard try await ClaimAdmission.admits(claim, policy: policy, store: store),
                      let entity = try await store.entity(claim.subject)
                else { continue }
                rows.append((claim, entity))
            }
        }

        // A claim row can lose its slot and stay current, so the belief says who holds the value now.
        if let listedStatus {
            for claim in try await store.currentClaims(predicate: Predicate.status, literal: listedStatus) {
                guard let belief = try await store.currentBelief(key: "\(claim.subject.value)|\(claim.predicate)"),
                      try await store.claim(belief.claimID)?.literal == listedStatus,
                      try await ClaimAdmission.admits(claim, policy: policy, store: store),
                      let entity = try await store.entity(claim.subject), policy.admits(entity.domain)
                else { continue }
                rows.append((claim, entity))
            }
        }

        var points: [AnswerPoint] = []
        var bySlotValue: [String: Int] = [:]
        var claimIDs: Set<ClaimID> = []
        let retrieved = Set(hits.map(\.object.id))

        for (claim, entity) in rows {
            var supporting: [Evidence] = []
            var insideWindow = window == nil
            for (evidence, _, _) in try await store.evidence(for: claim.id, stance: .supports) {
                if let object = try await store.object(evidence.objectID) {
                    guard policy.admits(object.domain) else { continue }
                    // With no named subject, the date alone is not enough. Subjects were pooled
                    // from the passages, so every claim those repositories had this month came
                    // along: "what did I decide about retrieval this month" opened with a
                    // project's language, from 41 claims, measured 2026-10-31. A claim counts
                    // when a passage this answer retrieved is what supports it.
                    if let window, let authored = object.authoredAt, window.contains(authored),
                       !focus.entities.isEmpty || retrieved.contains(object.id) {
                        insideWindow = true
                    }
                }
                supporting.append(evidence)
            }
            var counter: [Evidence] = []
            for (evidence, _, _) in try await store.evidence(for: claim.id, stance: .refutes) {
                if let object = try await store.object(evidence.objectID), !policy.admits(object.domain) {
                    continue
                }
                counter.append(evidence)
            }
            // A claim is about a window only if something inside it says so. All the claims
            // a repository has ever had are not an answer to what happened last week.
            guard !supporting.isEmpty, insideWindow else { continue }

            claimIDs.insert(claim.id)

            // One line per fact. A push mints a new claim row for an unchanged value,
            // because `ClaimID` includes `validFrom`, so the same sentence arrived several
            // times and filled the list. Measured 2026-10-30: 175 rows in 80 value groups.
            // The rows stay; they are corroboration, so their evidence joins the one line.
            let value = claim.objectEntity?.value ?? claim.literal ?? ""
            let key = "\(claim.subject.value)|\(claim.predicate)|\(value)"
            if let index = bySlotValue[key] {
                let known = Set(points[index].supporting.map(\.id))
                points[index].supporting += supporting.filter { !known.contains($0.id) }
                let knownCounter = Set(points[index].counter.map(\.id))
                points[index].counter += counter.filter { !knownCounter.contains($0.id) }
                points[index].claimRows.append(claim.id)
                if (claim.authority.rawValue, claim.confidence) > (points[index].authority.rawValue, points[index].confidence) {
                    points[index].authority = claim.authority
                    points[index].confidence = claim.confidence
                    points[index].derivation = claim.derivation
                    points[index].claimID = claim.id
                }
                continue
            }
            bySlotValue[key] = points.count
            points.append(AnswerPoint(
                statement: await phrase(claim: claim, subject: entity),
                supporting: supporting,
                counter: counter,
                confidence: claim.confidence,
                authority: claim.authority,
                derivation: claim.derivation,
                claimID: claim.id,
                subject: claim.subject,
                predicate: claim.predicate,
                object: claim.objectEntity,
                claimRows: [claim.id]
            ))
        }

        return (Self.ranked(points, focus: focus), claimIDs)
    }

    /// Entities a retrieved object is about. Repo metadata first, then the object's own external
    /// id, then the title, so a calendar event or a note resolves too rather than only a GitHub
    /// object.
    private func entities(in object: CoreObject, policy: AdmissionPolicy) async throws -> Set<EntityID> {
        var found = Set(try await store.claimSubjects(forObject: object.id))
        for surface in Self.candidateSurfaces(for: object) {
            for (entity, _) in try await store.resolve(surface: surface) where policy.admits(entity.domain) {
                found.insert(entity.id)
            }
        }
        return found
    }

    /// Passages about what the question named come first, and the rest keep their order. Only
    /// reorders: it can show a caller nothing that retrieval did not already admit.
    ///
    /// A repository's README mentioning OpenClinic ranks well for "status of OpenClinic", and
    /// without this it can open an answer that is about a different project.
    func aboutNamedFirst(_ hits: [PassageHit], focus: QueryFocus, policy: AdmissionPolicy) async throws -> [PassageHit] {
        guard !focus.entities.isEmpty else { return hits }
        var about: [PassageHit] = []
        var others: [PassageHit] = []
        for hit in hits {
            if try await entities(in: hit.object, policy: policy).contains(where: focus.names) {
                about.append(hit)
            } else {
                others.append(hit)
            }
        }
        return about + others
    }

    /// The stored claims a question asked for by name, for a caller that has passages of its
    /// own. Nothing unless the question names both a subject and something about it, because
    /// that is the case where the answer is a row and no passage says it.
    func askedClaims(focus: QueryFocus, window: QueryTimeWindow?, policy: AdmissionPolicy) async throws -> [AnswerPoint] {
        guard !focus.entities.isEmpty, !focus.predicates.isEmpty else { return [] }
        let (points, _) = try await assemble(hits: [], focus: focus, window: window, policy: policy)
        return points.filter { focus.asks($0.predicate) }
    }

    /// Contradictions touching `claimIDs`, skipping any whose other side the policy does not
    /// admit: a conflict with a claim the caller cannot read would tell them it exists.
    func contradictions(touching claimIDs: Set<ClaimID>, policy: AdmissionPolicy) async throws -> [Contradiction] {
        var touching: [Contradiction] = []
        for item in try await store.contradictions() where claimIDs.contains(item.claimA) || claimIDs.contains(item.claimB) {
            guard let claimA = try await store.claim(item.claimA),
                  let claimB = try await store.claim(item.claimB),
                  try await ClaimAdmission.admits(claimA, policy: policy, store: store),
                  try await ClaimAdmission.admits(claimB, policy: policy, store: store)
            else { continue }
            touching.append(item)
        }
        return touching
    }

    /// Whether `contradiction` stands against a line made of `rows`, so stating the line flat
    /// would be wrong. If it touches the line, unresolved does, and so does losing. Winning does
    /// not, and neither does `coexistingIntervals`, which has no winner because it was never a
    /// conflict.
    static func standsAgainst(_ contradiction: Contradiction, rows: Set<ClaimID>) -> Bool {
        guard rows.contains(contradiction.claimA) || rows.contains(contradiction.claimB) else { return false }
        if contradiction.resolution == .unresolved { return true }
        return contradiction.winner.map { !rows.contains($0) } ?? false
    }

    /// The other side of a contradiction, as a sentence. The stored reason alone reads "equal
    /// authority and no temporal ordering; both retained", which names neither value.
    func rivalStatement(in contradiction: Contradiction, against rows: Set<ClaimID>) async throws -> String? {
        let rival = rows.contains(contradiction.claimA) ? contradiction.claimB : contradiction.claimA
        guard !rows.contains(rival),
              let claim = try await store.claim(rival),
              let subject = try await store.entity(claim.subject)
        else { return nil }
        return await phrase(claim: claim, subject: subject)
    }

    /// What a receipt links for these lines, in the order they are shown: each line's support,
    /// then what stands against it, each row once. Counter-evidence is linked because a trace
    /// listing only the side that agreed would be a one-sided account of the answer.
    ///
    /// The score is the row's position scaled to 0...1 and says nothing about relevance. It used
    /// to assume about 3 rows per line, which collapsing repeated rows broke: a fact re-observed
    /// five times gives one line and five rows, and `core_trace` printed `[-1.333]`.
    public static func rankedEvidence(_ points: [AnswerPoint]) -> [(EvidenceID, Double)] {
        rankEvidenceIDs(points.flatMap { $0.supporting + $0.counter }.map(\.id))
    }

    /// The order an answer's lines are shown in, and a total order, so the same store gives the
    /// same lines in every process.
    ///
    /// A line joining two things the question named comes first, then the predicates it asked
    /// about, most direct first, then the named subject, and only then authority and confidence.
    /// Sorting on authority alone put `status`, which is derived and sits at a low tier by honest
    /// design, behind every high-confidence language and commit row, where `.prefix(12)` cut it.
    /// A question about status then never saw the answer.
    ///
    /// Asked comes ahead of subject so that "who contributed to OpenCore" leads with the lines
    /// pointing at it. Authority stays a plain ordinal tie-break here, and multiplies nothing.
    ///
    /// The tie-breaks matter because subjects came from a `Set`. OpenClinic and OpenCone tie at
    /// confidence .99, so the answer differed from run to run on an unchanged store.
    static func ranked(_ points: [AnswerPoint], focus: QueryFocus) -> [AnswerPoint] {
        points
            .map { point -> AnswerPoint in
                var point = point
                point.supporting.sort { ($0.authority.rawValue, $1.id.value) > ($1.authority.rawValue, $0.id.value) }
                point.counter.sort { $0.id.value < $1.id.value }
                return point
            }
            .sorted { lhs, rhs in
                func key(_ point: AnswerPoint) -> (Int, Int, Int, Int, Double) {
                    let joinsNames = focus.names(point.subject) && (point.object.map(focus.names) ?? false)
                    return (joinsNames ? 1 : 0, focus.askRank(point.predicate), focus.names(point.subject) ? 1 : 0, point.authority.rawValue, point.confidence)
                }
                let left = key(lhs)
                let right = key(rhs)
                if left != right { return left > right }
                if lhs.statement != rhs.statement { return lhs.statement < rhs.statement }
                return (lhs.claimID?.value ?? "") < (rhs.claimID?.value ?? "")
            }
    }



    /// Names worth trying against the entity index for one object.
    static func candidateSurfaces(for object: CoreObject) -> [String] {
        var surfaces: [String] = []
        if let repo = object.metadata["repo"] {
            surfaces.append(repo)
            if let bare = repo.split(separator: "/").last { surfaces.append(String(bare)) }
        }
        surfaces.append(object.externalID)
        if let bare = object.externalID.split(separator: "/").last { surfaces.append(String(bare)) }
        if let calendar = object.metadata["calendar"] { surfaces.append(calendar) }
        if let folder = object.metadata["folder"] { surfaces.append(folder) }
        surfaces.append(object.title)
        return surfaces.filter { $0.count > 2 }
    }

    /// Render a claim as English. Deliberately dull and templated: the phrasing carries no
    /// information the row does not, so there is nothing for a reader to over-read.
    private func phrase(claim: CoreClaim, subject: CoreEntity) async -> String {
        let objectText: String
        if let objectEntity = claim.objectEntity, let resolved = try? await store.entity(objectEntity) {
            objectText = resolved.canonicalName
        } else {
            objectText = claim.literal ?? "unknown"
        }

        // These values are often whole sentences from a handoff document, which end in their
        // own full stop.
        func sentence(_ text: String) -> String { text.hasSuffix(".") ? text : text + "." }

        return switch claim.predicate {
        case Predicate.objective: sentence("\(subject.canonicalName)'s objective: \(objectText)")
        case Predicate.nextAction: sentence("\(subject.canonicalName)'s next action: \(objectText)")
        case Predicate.lastVerifiedCommit: sentence("\(subject.canonicalName)'s last verified commit is \(objectText)")
        case Predicate.verifyCommand: "\(subject.canonicalName)'s verify command is \(objectText)"
        case Predicate.primaryLanguage: "\(subject.canonicalName) is primarily written in \(objectText)."
        case Predicate.builtWith: "\(subject.canonicalName) is built with \(objectText)."
        case Predicate.status: "\(subject.canonicalName) is \(objectText)."
        case Predicate.dependsOn: "\(subject.canonicalName) depends on \(objectText)."
        case Predicate.uses: "\(subject.canonicalName) uses \(objectText)."
        case Predicate.metWith: "\(subject.canonicalName) met with \(objectText)."
        case Predicate.attended: "\(subject.canonicalName) attended \(objectText)."
        case Predicate.partOf: "\(subject.canonicalName) is part of \(objectText)."
        default: sentence("\(subject.canonicalName) \(claim.predicate.replacingOccurrences(of: "_", with: " ")) \(objectText)")
        }
    }

    /// Opens a count read from the event log when it is not a count of what was asked.
    ///
    /// **The defect.** "How many meetings this month" on a store with no meetings answered "5
    /// events across 3 subjects", the commits of three repositories, in the flat voice of a
    /// computed fact. The event log has no column to count meetings by, so it can only say what
    /// it did count, and it has to say that before the number.
    static func notCountedLine(_ terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return "Not a count of '\(terms.joined(separator: " "))': the event log can only count every event in the window."
    }

    /// How many of the best passages decide what a question naming nothing is about.
    /// **Chosen, not measured:** one passage can be a coincidence, and past two the subjects stop
    /// being what the question asked.
    static let subjectPassages = 2

    private func summarise(
        points: [AnswerPoint],
        passages: [PassageHit],
        outcome: PassageOutcome,
        window: QueryTimeWindow?,
        activity: ActivitySummary?,
        uncounted: [String],
        listedStatus: String? = nil,
        focus: QueryFocus,
        calendar: Calendar
    ) -> String {
        if let listedStatus {
            return points.isEmpty ? "No projects are \(listedStatus)."
                : "\(points.count) project\(points.count == 1 ? " is" : "s are") \(listedStatus)."
        }
        if let window, let activity, activity.totalEvents > 0 {
            let floor = activity.isTruncated ? "At least " : ""
            var summary = Self.notCountedLine(uncounted).map { "\($0) " } ?? ""
            summary += "\(floor)\(activity.totalEvents) event\(activity.totalEvents == 1 ? "" : "s") across "
                + "\(activity.totalSubjects) subject\(activity.totalSubjects == 1 ? "" : "s"), \(window.span(in: calendar))."
            if !points.isEmpty {
                summary += " \(points.count) claim\(points.count == 1 ? "" : "s") from inside that window."
            }
            return summary
        }
        if points.isEmpty && !passages.isEmpty {
            // The honest case for a source that produces no claims: there is text, and the
            // store has concluded nothing from it. Saying so beats saying nothing.
            return "\(passages.count) passage\(passages.count == 1 ? "" : "s") match. No claims have been derived from them."
        }
        guard !points.isEmpty else { return "No claims in the store bear on this question." }
        if focus.entities.isEmpty, !passages.isEmpty, listedStatus == nil {
            return "\(passages.count) passage\(passages.count == 1 ? "" : "s") match, and \(points.count) "
                + "claim\(points.count == 1 ? " is" : "s are") known about where they came from."
        }

        let observed = points.filter { $0.derivation == .observed }.count
        let inferred = points.filter { $0.derivation == .inferred }.count
        var summary = "\(points.count) claim\(points.count == 1 ? "" : "s") bear on this"
        if inferred > 0 { summary += ": \(observed) read directly from source data, \(inferred) inferred" }
        summary += ", from \(passages.count) matching passage\(passages.count == 1 ? "" : "s")."
        return summary
    }
}
