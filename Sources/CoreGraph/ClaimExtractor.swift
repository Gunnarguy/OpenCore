import CoreModel
import CoreStore
import Foundation

/// Derives claims and events from objects, with evidence attached to every one.
///
/// Extraction is rule-based and deterministic. That is not a placeholder for "LLM later":
/// it is the design. A claim produced by a rule has a `derivation` you can audit and a
/// confidence that means something, and it is reproducible — rerun it on the same objects
/// and you get the same claims. A model in this position produces claims nobody can
/// reproduce or attribute, which is the failure mode the whole project exists to avoid.
///
/// A model may later *propose* claims. It enters at `Authority.modelInference`, the bottom
/// tier, and is outranked by every rule here.
public struct ClaimExtractor: Sendable {
    private let store: Store
    private let now: Date

    public init(store: Store, now: Date = Date()) {
        self.store = store
        self.now = now
    }

    public struct Outcome: Sendable {
        public var claims: Int = 0
        public var events: Int = 0
        public var evidence: Int = 0
    }

    /// A repository with no pushes in this long is called dormant rather than active.
    /// Named because it is a judgement call, not a fact, and it belongs somewhere findable.
    public static let dormantAfter: TimeInterval = 180 * 24 * 3600

    /// Above this many accepted attendees, an event is a broadcast and `met_with` is not
    /// asserted for it.
    ///
    /// **Chosen, not measured**, and the gap it sits in was measured. On the real corpus the
    /// attendee counts run 2, 2, 2, 4, 12, 22, then 37, 39, 84, 94, 110, 240, 270, 297, 4004.
    /// 25 falls in the empty space between a 22-person huddle and a 37-person team gathering,
    /// so it separates the two populations rather than cutting through one. Any value from 23
    /// to 36 behaves identically on this corpus, which is the honest way to say that the exact
    /// number is not load-bearing and the existence of a boundary is.
    ///
    /// The event still produces a timeline entry, `attended` claims, and stays retrievable.
    /// Only the assertion that you *met* everyone present is withheld.
    public static let metWithCeiling = 25

    /// A private record cannot publish a previously unknown technology/provider name as
    /// public vocabulary. Existing independently public entities keep their own evidence.
    static func technologyDomain(for object: CoreObject) -> Domain {
        [.project, .publicRecord].contains(object.domain) ? .publicRecord : object.domain
    }

    @discardableResult
    public func extract(from objects: [CoreObject]) async throws -> Outcome {
        var claims: [CoreClaim] = []
        var events: [CoreEvent] = []
        var evidence: [Evidence] = []
        var links: [(ClaimID, EvidenceID, Stance, Double)] = []

        for object in objects {
            switch object.kind {
            case .repository:
                try await extractRepositoryClaims(object, into: &claims, &events, &evidence, &links)
            case .file where object.externalID.hasSuffix("#languages"):
                try await extractLanguageClaims(object, into: &claims, &evidence, &links)
            case .commit:
                try await extractCommitEvent(object, into: &events)
                try await extractCommitClaims(object, into: &claims, &evidence, &links)
            case .calendarEvent:
                try await extractCalendarClaims(object, into: &claims, &events, &evidence, &links)
            case .note, .document, .file:
                try await extractTimelineEvent(object, into: &events)
                if object.kind == .document, object.externalID.hasSuffix("#readme") {
                    extractReadmeClaims(object, into: &claims, &evidence, &links)
                } else {
                    extractStructuredDocumentClaims(object, into: &claims, &evidence, &links)
                }
                extractREAClaims(object, into: &claims, &evidence, &links)
            default:
                break
            }
            extractModelProposedClaims(object, into: &claims, &evidence, &links)
        }

        try await separateRewrittenSpans(&evidence, &links)
        try await store.save(evidence)
        try await store.save(claims)
        try await store.save(events)
        for link in links {
            try await store.link(claim: link.0, to: link.1, stance: link.2, weight: link.3)
        }

        // Edges mirror entity-to-entity claims so graph traversal does not have to
        // re-interpret claim rows on every hop.
        for claim in claims {
            if let target = claim.objectEntity {
                try await store.addEdge(from: claim.subject, relation: claim.predicate, to: target, weight: claim.confidence, claim: claim.id)
            }
        }

        return Outcome(claims: claims.count, events: events.count, evidence: evidence.count)
    }

    /// Gives a rewritten line its own evidence row.
    ///
    /// An evidence id is its object and byte range, and a range outlives the text under it. A
    /// revision that changes a value of the same length at the same offset, such as a commit hash
    /// in a handoff, reached the row the old value rests on. The snippet was overwritten, so the
    /// old claim cited the sentence that replaced it, and the two claims then shared their
    /// evidence, so the retired one recorded nothing against it.
    ///
    /// Only a collision takes a new id, because a receipt links to the id every other row has now.
    /// The whole-object row stays shared: that is what a repository reading is, and
    /// `BeliefEngine` writes its counter-evidence separately.
    private func separateRewrittenSpans(
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        var separated: [EvidenceID: EvidenceID] = [:]
        for index in evidence.indices where evidence[index].range != nil {
            let item = evidence[index]
            guard let held = try await store.evidence(id: item.id), held.snippet != item.snippet else { continue }
            let own = Evidence(objectID: item.objectID, range: item.range, snippet: item.snippet, authority: item.authority, reading: item.snippet)
            separated[item.id] = own.id
            evidence[index] = own
        }
        guard !separated.isEmpty else { return }
        links = links.map { ($0.0, separated[$0.1] ?? $0.1, $0.2, $0.3) }
    }

    // MARK: - Repository

    private func extractRepositoryClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ events: inout [CoreEvent],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        let bareName = object.externalID.split(separator: "/").last.map(String.init) ?? object.externalID
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        let item = Evidence(
            objectID: object.id,
            snippet: String(object.text.prefix(280)),
            authority: object.authority
        )
        evidence.append(item)

        // primary_language. Functional: a repo has exactly one at a time, so when GitHub
        // reports a different one later, that is a genuine contradiction with a real
        // temporal resolution rather than two facts sitting side by side.
        //
        // **Dated by the push it was read after, not by `authoredAt`.** That field is the
        // repository's creation date, so every reading of a repository's language shared one
        // `validFrom`: a language that changed tied with its predecessor and stayed an open
        // contradiction forever. Both of the store's unresolved contradictions were this. A
        // language can only change through a push, so the push date orders readings, and it stays
        // a world time that compares fairly with a dated document. `observedAt` carries the rest:
        // GitHub recomputes a language after the push, so two readings can share this date, and
        // `BeliefEngine` orders a record's readings by when each was read.
        let pushedAt = object.metadata["pushed_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
        if let language = object.metadata["language"] {
            let languageEntity = CoreEntity(kind: .technology, canonicalName: language, domain: Self.technologyDomain(for: object)).id
            let claim = try await reading(of: object, dated: pushedAt ?? object.authoredAt) { from in
                CoreClaim(
                    subject: subject,
                    predicate: Predicate.primaryLanguage,
                    objectEntity: languageEntity,
                    confidence: 0.98,
                    authority: object.authority,
                    derivation: .observed,
                    validity: Validity(validFrom: from, observedAt: now),
                    domain: object.domain
                )
            }
            claims.append(claim)
            links.append((claim.id, item.id, .supports, 1.0))
        }

        // status. Derived, not observed, and its confidence says so.
        let archived = object.metadata["archived"] == "true"
        let lastWork = try await lastWorkDate(repository: object.externalID, pushedAt: pushedAt)
        let statusValue: String
        let statusConfidence: Double
        // When the status became true. For `dormant` that is the moment the silence passed the
        // threshold, not the last push. Dating it from the push gave `active` and `dormant` the
        // same `validFrom` whenever a repository simply went quiet, so the two tied, the verdict
        // was "no temporal ordering", and the belief stayed `active` forever. Measured
        // 2026-10-30: zero active-to-dormant beliefs in the whole store.
        let statusFrom: Date?
        if archived {
            statusValue = "archived"
            statusConfidence = 1.0
            statusFrom = pushedAt
        } else if let lastWork, now.timeIntervalSince(lastWork) > Self.dormantAfter {
            statusValue = "dormant"
            statusConfidence = 0.75
            statusFrom = lastWork.addingTimeInterval(Self.dormantAfter)
        } else {
            statusValue = "active"
            statusConfidence = 0.85
            statusFrom = lastWork
        }

        let statusClaim = try await reading(of: object, dated: statusFrom) { from in
            CoreClaim(
                subject: subject,
                // Keeps its `validFrom`, unlike the commit claims. `status` IS in
                // `Predicate.functional`, so supersession reads its world time to decide which of
                // two statuses is later. Stripping it would collapse the ordering onto
                // `observedAt`, which is the sync time, and two statuses learned in one sync would
                // tie and be reported as an unresolvable contradiction. That would break the one
                // real contradiction in the store to tidy up a duplicate-row count.
                predicate: Predicate.status,
                literal: statusValue,
                confidence: statusConfidence,
                authority: archived ? object.authority : .derivedPattern,
                derivation: archived ? .observed : .inferred,
                validity: Validity(validFrom: from, observedAt: now),
                domain: object.domain
            )
        }
        claims.append(statusClaim)
        links.append((statusClaim.id, item.id, .supports, 1.0))

        if let createdAt = object.authoredAt {
            events.append(CoreEvent(
                subject: subject,
                verb: "created",
                detail: "Repository \(object.externalID) created",
                occurredAt: createdAt,
                domain: object.domain,
                authority: object.authority
            ))
        }
    }

    /// A claim for what a repository record says now, allowing for the record going back.
    ///
    /// **The defect.** A claim id is its value and date, and a retracted claim stays retracted. A
    /// record that returned to a value at the same date reproduced the old id, so nothing changed:
    /// a language read Python, then HTML, then Python under one `pushed_at` stayed HTML, and a
    /// repository archived, restored and archived with no push stayed `active`. Neither can be put
    /// right by clearing `retracted_at`, because the retraction happened, a past checkout reads it,
    /// and a correction needs that column to hold.
    ///
    /// So a value this record said earlier and then stopped saying is a new reading, dated by this
    /// read: all that is known about when it came back is that it had by now. After that the row
    /// is reused, or each later sync would mint another. A value the record never stopped saying
    /// is left as it is, even when retired, so whatever retired it stands: a correction, or a
    /// document that outranked it.
    private func reading(of object: CoreObject, dated validFrom: Date?, claim: (Date?) -> CoreClaim) async throws -> CoreClaim {
        let proposed = claim(validFrom)
        guard let held = try await store.claim(proposed.id) else { return proposed }
        let readings = try await store.claims(key: proposed.claimKey, readFrom: object.id)
            .filter { $0.authority != .modelInference }
        guard let last = readings.last else { return proposed }
        if last.literal == proposed.literal, last.objectEntity == proposed.objectEntity {
            return held.validity.isCurrent ? proposed : last
        }
        return claim(now)
    }

    /// The last time a repository saw real work, as far as the floor can tell.
    ///
    /// `pushed_at` alone calls a README correction a revival. The newest commit that is not
    /// upkeep answers the question being asked. With no commits on the floor, `pushed_at` is
    /// all there is. With commits that are all upkeep, the real work is older than anything
    /// stored, so the oldest stored commit is the latest date that can honestly be claimed.
    private func lastWorkDate(repository: String, pushedAt: Date?) async throws -> Date? {
        // No cap. `commits` keeps the newest rows, so at its default of 200 "the oldest stored
        // commit" was the 200th newest, and a bot making 201 upkeep commits hid the real work
        // behind them. The fallback date then slid forward with every new bot commit, which read
        // `active` for good and minted a status row per sync.
        let commits = try await store.commits(repository: repository, notAfter: now, limit: .max)
        guard let oldest = commits.last else { return pushedAt }
        return commits.first { !CommitNature.isUpkeep(title: $0.title, author: $0.author) }?.authoredAt ?? oldest.authoredAt
    }

    // MARK: - Languages

    private func extractLanguageClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        guard let repo = object.metadata["repo"] else { return }
        let bareName = repo.split(separator: "/").last.map(String.init) ?? repo
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        let byteCounts = object.metadata
            .filter { $0.key.hasPrefix("lang_") }
            .compactMap { key, value -> (String, Int)? in
                guard let count = Int(value) else { return nil }
                return (String(key.dropFirst(5)), count)
            }
        let total = max(1, byteCounts.reduce(0) { $0 + $1.1 })

        let item = Evidence(objectID: object.id, snippet: String(object.text.prefix(280)), authority: object.authority)
        evidence.append(item)

        for (language, bytes) in byteCounts {
            let share = Double(bytes) / Double(total)
            // Below 5% is usually a config file or a vendored script, not a thing the
            // project is built with. Recorded as a threshold rather than silently applied.
            guard share >= 0.05 else { continue }

            let languageEntity = CoreEntity(kind: .technology, canonicalName: language, domain: Self.technologyDomain(for: object)).id
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.builtWith,
                objectEntity: languageEntity,
                // Confidence tracks the measured share. A 90% language is a stronger claim
                // about what the project is than a 6% one, and this is the one place in
                // the extractor where a number is genuinely derived rather than chosen.
                confidence: min(0.99, 0.5 + share / 2),
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, item.id, .supports, share))
        }
    }

    // MARK: - Commits as claims

    /// 651 commits produced zero claims. They produced timeline events and nothing else, so
    /// the single largest source in the store contributed nothing the system could believe.
    ///
    /// Two claims come out of a commit without guessing, because both read structured fields
    /// rather than interpreting prose:
    ///
    /// - `contributed_to(person, repository)` from the author field.
    /// - `has_component(repository, scope)` from a Conventional Commits scope. `feat(Retrieval):`
    ///   is an author explicitly naming a part of their own system, which is a stronger signal
    ///   than anything that could be inferred from the message body.
    ///
    /// Claim ids are derived from subject, predicate and object, so 340 commits by one author
    /// collapse to one claim carrying 340 pieces of evidence. That is the correct shape: the
    /// belief is single, the support for it accumulates.
    private func extractCommitClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        guard let repo = object.metadata["repo"] else { return }
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
        let repository = CoreEntity(kind: .project, canonicalName: repoName, domain: object.domain).id

        let item = Evidence(
            objectID: object.id,
            snippet: String(object.title.prefix(200)),
            authority: object.authority
        )
        var used = false

        if let author = object.metadata["author"], author != "unknown", author.count > 1 {
            let person = CoreEntity(kind: .person, canonicalName: author, domain: object.domain).id
            let claim = CoreClaim(
                subject: person,
                predicate: Predicate.contributedTo,
                objectEntity: repository,
                confidence: 0.99,
                authority: object.authority,
                derivation: .observed,
                // **No `validFrom`, deliberately.** `ClaimID` is derived partly from it, so
                // dating this claim with the commit's timestamp minted a fresh claim row per
                // commit for one unchanging fact. Measured on the real store: 647 rows
                // covering 33 actual facts, which filled the Claims screen's window before
                // anything else could be reached.
                //
                // "X contributed to Y" is not true *from* a date, it is true and each commit
                // is evidence for it. The dates are not lost: every commit is linked below as
                // its own evidence row, which is finer-grained than one date on the claim and
                // is where a connector's per-instance detail belongs.
                //
                // Safe here specifically because `contributed_to` is not in
                // `Predicate.functional`, so nothing adjudicates it and no ranking reads its
                // world time. See `extractRepositoryClaims` for the case where it is not safe.
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, item.id, .supports, 1.0))
            used = true
        }

        if let scope = Self.conventionalCommitScope(object.title) {
            let component = CoreEntity(kind: .concept, canonicalName: scope, domain: object.domain).id
            let claim = CoreClaim(
                subject: repository,
                predicate: Predicate.hasComponent,
                objectEntity: component,
                // Below the author claim: a scope is a convention an author may abandon or
                // rename, where an author field is a fact about the commit itself.
                confidence: 0.9,
                authority: object.authority,
                derivation: .observed,
                // Undated for the same reason as the author claim above, and also not
                // functional: a repository has many components.
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, item.id, .supports, 0.9))
            used = true
        }

        // Same rule as the calendar path: evidence only once something references it.
        if used { evidence.append(item) }
    }

    /// The scope from a Conventional Commit subject: `feat(Retrieval): ...` yields `Retrieval`.
    ///
    /// Deliberately strict. It requires a recognised type, a parenthesised scope and a colon,
    /// because a loose parenthesis match would turn `fix (finally) the thing` into a component
    /// called "finally".
    static func conventionalCommitScope(_ subject: String) -> String? {
        let types = ["feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert"]
        guard let openParen = subject.firstIndex(of: "("),
              let closeParen = subject[openParen...].firstIndex(of: ")"),
              subject.index(after: closeParen) < subject.endIndex,
              subject[subject.index(after: closeParen)] == ":"
        else { return nil }

        let type = subject[subject.startIndex..<openParen].trimmingCharacters(in: .whitespaces).lowercased()
        guard types.contains(type.hasSuffix("!") ? String(type.dropLast()) : type) else { return nil }

        let scope = subject[subject.index(after: openParen)..<closeParen].trimmingCharacters(in: .whitespaces)
        // A scope is a component name, not a sentence.
        guard scope.count > 1, scope.count <= 40, !scope.contains(" ") || scope.split(separator: " ").count <= 2 else {
            return nil
        }
        return scope
    }

    // MARK: - Calendar

    /// Calendar is the richest non-GitHub source, and the only one that yields real claims
    /// without a model: an attendee list is structured data, not prose.
    ///
    /// What it produces: a person entity per named attendee, a `met_with` claim from the
    /// calendar owner to each of them, an `attended` claim from each attendee to the event's
    /// calendar, and an event on the timeline.
    ///
    /// What it deliberately does not produce: anything about *why* you met, how often, or what
    /// it means. Frequency across events is a pattern, and a pattern is an inference this
    /// extractor has no business making at `observed` authority.
    private func extractCalendarClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ events: inout [CoreEvent],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) async throws {
        guard let occurredAt = object.authoredAt else { return }

        let calendarName = object.metadata["calendar"] ?? "Calendar"
        // The calendar itself is the subject anchor: "Work" and "Family" are meaningfully
        // different contexts and worth being separate entities.
        let calendar = CoreEntity(kind: .concept, canonicalName: calendarName, domain: object.domain).id

        events.append(CoreEvent(
            subject: calendar,
            verb: "attended",
            detail: object.title,
            occurredAt: occurredAt,
            domain: object.domain,
            authority: object.authority
        ))

        // **Who accepted, not who was invited**, and the difference is the whole rule here.
        //
        // Measured 2026-08-14: this used to read `attendees`, the raw invite list, and assert
        // `met_with` at `derivation: .observed` and confidence 0.9 for every name on it. A
        // company-wide yoga invite therefore stated as observed fact that the user had met
        // 4,004 people. Nine broadcast events produced **5,175 of the store's 5,216 met_with
        // claims**; six real meetings produced the other 44.
        //
        // That is the exact failure this extractor refuses elsewhere. It declines to derive
        // claims from notes because "inferring facts from prose without a model is exactly the
        // guessing this extractor refuses to do", and then inferred *met* from a distribution
        // list, which is the same guess wearing structured data as an alibi. What an invite
        // list observes is that someone was invited. Meeting is an inference on top of it.
        //
        // A **missing** key means the object predates the connector recording status: nobody
        // looked, so nothing is asserted. Unmeasured stays nil rather than becoming "everyone
        // attended", which is what reading the invite list amounted to. Those objects yield a
        // timeline entry and stay fully retrievable; they simply stop claiming who was met.
        // Re-syncing the calendar is what fills this in.
        guard let acceptedField = object.metadata["attendees_accepted"] else { return }

        // ASCII 31 separated, matching what the connector wrote. A comma would split names
        // containing one.
        let attendees = acceptedField
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }

        // Evidence only once there is a claim to attach it to. Creating it unconditionally
        // left 558 orphaned rows on the first run of this code: a solo calendar event
        // produces a timeline entry and no claims, so its evidence pointed at nothing.
        guard !attendees.isEmpty else { return }

        let item = Evidence(objectID: object.id, snippet: String(object.text.prefix(280)), authority: object.authority)
        evidence.append(item)

        for name in attendees {
            let person = CoreEntity(kind: .person, canonicalName: name, domain: .personal).id

            let attended = CoreClaim(
                subject: person,
                predicate: Predicate.attended,
                objectEntity: calendar,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: occurredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(attended)
            links.append((attended.id, item.id, .supports, 1.0))

            // Accepting a 270-person town hall is attending it. It is not meeting 270 people,
            // so `met_with` carries a size gate that `attended` does not.
            guard attendees.count <= Self.metWithCeiling else { continue }

            let met = CoreClaim(
                subject: calendar,
                predicate: Predicate.metWith,
                objectEntity: person,
                confidence: 0.9,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: occurredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(met)
            links.append((met.id, item.id, .supports, 1.0))

            events.append(CoreEvent(
                subject: person,
                verb: "met",
                detail: object.title,
                occurredAt: occurredAt,
                domain: object.domain,
                authority: object.authority
            ))
        }
    }

    // MARK: - Notes, reminders, local documents

    /// A timeline entry and nothing more.
    ///
    /// These are prose. Without a model there is no honest way to turn "buy milk" or a design
    /// note into a claim, and inventing one at `observed` authority would be worse than
    /// leaving the source claim-free: it would put a guess in the same table as a fact read
    /// out of structured data.
    private func extractTimelineEvent(_ object: CoreObject, into events: inout [CoreEvent]) async throws {
        events.append(contentsOf: ObjectPresentation.timelineEvents(for: object))
    }

    // MARK: - Commits

    private func extractCommitEvent(_ object: CoreObject, into events: inout [CoreEvent]) async throws {
        guard let repo = object.metadata["repo"], let occurredAt = object.authoredAt else { return }
        let bareName = repo.split(separator: "/").last.map(String.init) ?? repo
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        events.append(CoreEvent(
            subject: subject,
            verb: "committed",
            detail: object.title,
            occurredAt: occurredAt,
            domain: object.domain,
            authority: object.authority
        ))
    }

    // MARK: - Span-verified README extraction

    /// Compute and verify the exact UTF-8 byte range of `substring` inside `text`.
    ///
    /// Returns `nil` when `substring` is empty, absent from `text`, or does not round-trip
    /// byte-for-byte from `text.utf8[range]`. Every prose-derived or REA-derived claim passes
    /// through this gate so a claim with an unaligned or fabricated span cannot be constructed.
    public static func verifiedByteRange(of substring: String, in text: String) -> Range<Int>? {
        guard !substring.isEmpty, let range = text.range(of: substring) else { return nil }
        let startByte = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound.samePosition(in: text.utf8) ?? text.utf8.startIndex)
        let endByte = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound.samePosition(in: text.utf8) ?? text.utf8.startIndex)
        guard startByte < endByte else { return nil }
        let bytes = Array(text.utf8)
        guard endByte <= bytes.count else { return nil }
        let roundTrip = String(decoding: bytes[startByte..<endByte], as: UTF8.self)
        guard roundTrip == substring else { return nil }
        return startByte..<endByte
    }

    private static let canonicalTechnologies: [(canonicalName: String, surface: String)] = [
        ("SwiftUI", "swiftui"),
        ("SQLite", "sqlite"),
        ("FTS5", "fts5"),
        ("FastAPI", "fastapi"),
        ("PDFKit", "pdfkit"),
        ("Vision", "vision ocr"),
        ("Pinecone", "pinecone"),
        ("Streamlit", "streamlit"),
        ("Jupyter", "jupyter"),
        ("Docker", "docker"),
        ("CloudKit", "cloudkit"),
        ("Ghidra", "ghidra"),
    ]

    /// Canonical technology frameworks explicitly named in a README, paired with the line in
    /// `text` that mentions each one so `ClaimExtractor` can attach a byte-verified span.
    public static func readmeTechnologies(in text: String) -> [(canonicalName: String, matchedSpan: String)] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var results: [(canonicalName: String, matchedSpan: String)] = []
        for (canonical, surface) in canonicalTechnologies {
            for rawLine in lines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, containsWholePhrase(surface, in: trimmed.lowercased()) else { continue }
                if verifiedByteRange(of: trimmed, in: text) != nil {
                    results.append((canonical, trimmed))
                    break
                }
            }
        }
        return results
    }

    private static func containsWholePhrase(_ phrase: String, in lowercasedText: String) -> Bool {
        var searchStart = lowercasedText.startIndex
        while let match = lowercasedText.range(of: phrase, range: searchStart..<lowercasedText.endIndex) {
            let beforeOK = match.lowerBound == lowercasedText.startIndex || {
                let prev = lowercasedText[lowercasedText.index(before: match.lowerBound)]
                return !prev.isLetter && !prev.isNumber
            }()
            let afterOK = match.upperBound == lowercasedText.endIndex || {
                let next = lowercasedText[match.upperBound]
                return !next.isLetter && !next.isNumber
            }()
            if beforeOK && afterOK { return true }
            searchStart = match.upperBound
        }
        return false
    }

    private static func stripMarkup(_ line: String) -> String {
        let withoutTags = line
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        return withoutTags
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#*_>`")))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Extract span-verified claims from a repository's `#readme` document:
    /// 1. Explicit lifecycle status (`status = archived` or `deprecated`) in the lead section
    ///    (before the first `## ` heading), which allows `BeliefEngine` to catch cross-source
    ///    contradictions when a repository's README says `"Archived..."` while GitHub's
    ///    `archived` flag is still `false` and `pushed_at` inferred `status = active`.
    /// 2. Explicit framework/technology mentions (`built_with`) with exact UTF-8 byte ranges.
    private func extractReadmeClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) {
        let repoFull = object.metadata["repo"] ?? String(object.externalID.dropLast("#readme".count))
        let bareName = repoFull.split(separator: "/").last.map(String.init) ?? repoFull
        let subject = CoreEntity(kind: .project, canonicalName: bareName, domain: object.domain).id

        // 1. Lead-section explicit lifecycle status.
        let lines = object.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for rawLine in lines.prefix(35) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            let clean = Self.stripMarkup(trimmed).lowercased()
            guard !clean.isEmpty else { continue }

            let explicitArchived = clean.hasPrefix("archived ")
                || clean == "archived"
                || clean.contains("repository is archived")
                || clean.contains("project is archived")
                || clean.contains("status: archived")
                || clean.contains("[archived]")
                || clean.contains("no longer maintained")
            let explicitDeprecated = !explicitArchived && (
                clean.hasPrefix("deprecated ")
                || clean.contains("status: deprecated")
                || clean.contains("[deprecated]")
            )

            if explicitArchived || explicitDeprecated,
               let byteRange = Self.verifiedByteRange(of: trimmed, in: object.text) {
                let statusLiteral = explicitArchived ? "archived" : "deprecated"
                let ev = Evidence(
                    objectID: object.id,
                    range: byteRange,
                    snippet: String(trimmed.prefix(280)),
                    authority: object.authority
                )
                evidence.append(ev)
                let claim = CoreClaim(
                    subject: subject,
                    predicate: Predicate.status,
                    literal: statusLiteral,
                    confidence: 0.95,
                    authority: object.authority,
                    derivation: .observed,
                    validity: Validity(validFrom: object.authoredAt, observedAt: now),
                    domain: object.domain
                )
                claims.append(claim)
                links.append((claim.id, ev.id, .supports, 1.0))
                break
            }
        }

        // 2. Span-verified technology claims.
        for (techName, matchedLine) in Self.readmeTechnologies(in: object.text) {
            guard let byteRange = Self.verifiedByteRange(of: matchedLine, in: object.text) else { continue }
            let techEntity = CoreEntity(kind: .technology, canonicalName: techName, domain: Self.technologyDomain(for: object)).id
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(matchedLine.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.builtWith,
                objectEntity: techEntity,
                confidence: 0.85,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 0.85))
        }
    }

    // MARK: - Non-GitHub structured documents and local repository docs

    public struct StructuredDocumentExtraction: Sendable {
        public let subject: CoreEntity
        public let aliases: [EntityAlias]
        public let status: (value: String, matchedSpan: String)?
        public let primaryLanguage: (entity: CoreEntity, matchedSpan: String)?
        public let technologies: [(entity: CoreEntity, matchedSpan: String)]
        public let contributors: [(entity: CoreEntity, matchedSpan: String)]
        public let objective: (value: String, matchedSpan: String)?
        public let lastVerifiedCommit: (value: String, matchedSpan: String)?
        public let nextAction: (value: String, matchedSpan: String)?
        public let verifyCommand: (value: String, matchedSpan: String)?
        public let descriptions: [(value: String, matchedSpan: String)]
    }

    private static let canonicalLanguages: [(canonicalName: String, surface: String)] = [
        ("Swift", "swift"),
        ("Python", "python"),
        ("TypeScript", "typescript"),
        ("JavaScript", "javascript"),
        ("Rust", "rust"),
        ("Go", "go"),
        ("C++", "c++"),
        ("C", "c"),
        ("Java", "java"),
        ("Kotlin", "kotlin"),
        ("Ruby", "ruby"),
        ("SQL", "sql"),
        ("Shell", "shell"),
    ]

    private static let anchorDocNames: Set<String> = [
        "readme.md", "claude.md", "agents.md", "state.md", "handoff.md", "last-stop.md",
    ]

    private static let genericContainerNames: Set<String> = [
        "docs", "doc", "ai", ".claude", ".agents", ".codex", ".state", "sources", "tests",
        "github", "documents", "projects", "notes", "desktop", "tmp", "private",
        "users", "state", "current state", "handoff", "session handoff",
        "readme", "claude", "agents", "architecture", "overview", "instructions",
        "memory", "last-stop",
    ]

    /// Resolves a `~/.claude/projects/<slug>/memory/<file>.md` path to the canonical project name.
    /// Temporary scratchpads, worktrees, and SSH scratch folders return `nil`.
    ///
    /// The path is the only input, so the answer can't depend on which account runs it or on what
    /// is installed beside the store. That is the reproducibility the type promises, and it is why
    /// this reads neither `NSUserName()` nor `LocalPrivateNames`: `rebuild` from the same objects
    /// has to reach the same subjects on any machine.
    public static func claudeMemoryProjectName(from path: String) -> String? {
        guard path.contains("/.claude/projects/"), path.contains("/memory") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let projectsIndex = parts.firstIndex(of: "projects"),
              projectsIndex + 1 < parts.count
        else { return nil }
        let slug = parts[projectsIndex + 1]
        let lowerSlug = slug.lowercased()
        if lowerSlug.hasPrefix("-private-tmp")
            || lowerSlug.hasPrefix("ssh-")
            || lowerSlug.contains("scratch")
            || lowerSlug.contains("worktrees")
            || lowerSlug.contains("conductor-workspaces")
            || lowerSlug.contains("--git-nosync") {
            return nil
        }
        if slug.hasSuffix("-Apps-OpenCoreMac") { return "OpenCore" }
        for container in ["-Documents-GitHub-", "-Claude-Projects-", "-Documents-Projects-"] {
            if let range = slug.range(of: container) {
                let tail = String(slug[range.upperBound...])
                if !tail.isEmpty { return tail }
            }
        }
        if slug.hasPrefix("-Applications-") {
            let tail = String(slug.dropFirst("-Applications-".count))
            return tail.isEmpty ? nil : tail
        }
        // The home folder is `-Users-<account>`. A folder directly inside it is named by what
        // follows, and only a tail with no dash is certainly one folder rather than a nested path.
        guard slug.hasPrefix("-Users-") else { return nil }
        let afterRoot = slug.dropFirst("-Users-".count)
        guard let accountEnd = afterRoot.firstIndex(of: "-") else { return "Machine-Global" }
        let tail = afterRoot[afterRoot.index(after: accountEnd)...]
        return tail.isEmpty || tail.contains("-") ? nil : String(tail)
    }

    /// Deterministic extraction from local repository docs (`README.md`, `CLAUDE.md`, `STATE.md`)
    /// and structured `Key: Value` headers (`Project:`, `Status:`, `Primary Language:`,
    /// `Built with:`, `Owner:`, `Author:`, `Objective:`, `Last verified commit:`, `Next action:`,
    /// `Verify:`) in `.file`, `.note`, and `.document` objects.
    ///
    /// Returns `nil` unless both a concrete project subject and at least one byte-verified claim
    /// are present, so ordinary prose notes never mint empty project entities.
    public static func structuredDocumentExtraction(from object: CoreObject) -> StructuredDocumentExtraction? {
        guard object.kind == .note || object.kind == .document || object.kind == .file else { return nil }
        if object.kind == .document, object.externalID.hasSuffix("#readme") { return nil }
        if object.kind == .file, object.externalID.hasSuffix("#languages") { return nil }
        if isREAFindingsMarkdown(object) || !parseREARecords(from: object.text).isEmpty { return nil }

        let lines = object.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let headerWindow = Array(lines.prefix(90))

        let claudeMemoryProject = claudeMemoryProjectName(from: object.externalID)
            ?? (object.uri.flatMap { claudeMemoryProjectName(from: $0) })
            ?? (object.metadata["root"].flatMap { claudeMemoryProjectName(from: $0) })

        var explicitProjectRaw: String? = claudeMemoryProject
        var statusMatch: (value: String, matchedSpan: String)?
        var primaryLanguageMatch: (canonicalName: String, matchedSpan: String)?
        var explicitTechMatches: [(canonicalName: String, matchedSpan: String)] = []
        var contributorMatches: [(canonicalName: String, matchedSpan: String)] = []
        var objectiveMatch: (value: String, matchedSpan: String)?
        var lastVerifiedCommitMatch: (value: String, matchedSpan: String)?
        var nextActionMatch: (value: String, matchedSpan: String)?
        var verifyCommandMatch: (value: String, matchedSpan: String)?
        var descriptionMatches: [(value: String, matchedSpan: String)] = []

        for rawLine in headerWindow {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, verifiedByteRange(of: trimmed, in: object.text) != nil else { continue }
            guard let (key, value) = parseHeaderKeyValue(trimmed) else { continue }

            switch key {
            case "project", "repository", "repo":
                if explicitProjectRaw == nil, value.count >= 2, value.count <= 80 {
                    explicitProjectRaw = value
                }
            case "description":
                if claudeMemoryProject != nil, object.title.lowercased() != "memory.md" {
                    let cleanDesc = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                    if cleanDesc.count >= 8 {
                        let slug = (object.title as NSString).deletingPathExtension
                        let formatted = "[Claude Memory · \(slug)] \(String(cleanDesc.prefix(220)))"
                        if !descriptionMatches.contains(where: { $0.value == formatted }) {
                            descriptionMatches.append((formatted, trimmed))
                        }
                    }
                }
            case "status", "state", "lifecycle":
                let lowerVal = value.lowercased()
                let normalized: String? = if lowerVal.hasPrefix("archived") || lowerVal == "retired" {
                    "archived"
                } else if lowerVal.hasPrefix("deprecated") {
                    "deprecated"
                } else if lowerVal.hasPrefix("dormant") || lowerVal.hasPrefix("inactive") {
                    "dormant"
                } else if lowerVal.hasPrefix("active") {
                    "active"
                } else {
                    nil
                }
                if let normalized, statusMatch == nil {
                    statusMatch = (normalized, trimmed)
                }
            case "primary language", "primary_language", "language":
                if primaryLanguageMatch == nil, let lang = matchCanonicalLanguage(in: value) {
                    primaryLanguageMatch = (lang, trimmed)
                }
            case "built with", "built_with", "stack", "tech stack":
                for (canonical, surface) in canonicalTechnologies + canonicalLanguages {
                    if containsWholePhrase(surface, in: value.lowercased()),
                       !explicitTechMatches.contains(where: { $0.canonicalName == canonical }) {
                        explicitTechMatches.append((canonical, trimmed))
                    }
                }
            case "owner", "author", "maintainer":
                let cleanAuthor = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "@`\"'")))
                if cleanAuthor.count > 1, cleanAuthor.count <= 50,
                   cleanAuthor.lowercased() != "unknown", cleanAuthor.lowercased() != "none",
                   !contributorMatches.contains(where: { $0.canonicalName == cleanAuthor }) {
                    contributorMatches.append((cleanAuthor, trimmed))
                }
            case "last verified commit", "last_verified_commit", "verified commit":
                if lastVerifiedCommitMatch == nil,
                   let sha = parseCommitSHA(from: value) {
                    lastVerifiedCommitMatch = (sha, trimmed)
                }
            case "objective", "current objective":
                if objectiveMatch == nil, value.count >= 6 {
                    let cleanObj = String(value.prefix(240))
                    objectiveMatch = (cleanObj, trimmed)
                }
            case "next action", "exact next action", "next_action":
                if nextActionMatch == nil, value.count >= 6 {
                    let cleanNext = String(value.prefix(240))
                    nextActionMatch = (cleanNext, trimmed)
                }
            case "verify", "verify command", "verify_command":
                if verifyCommandMatch == nil, value.count >= 4 {
                    let cleanCmd = String(value.prefix(240))
                    verifyCommandMatch = (cleanCmd, trimmed)
                }
            default:
                break
            }
        }

        let lowerTitle = object.title.lowercased()
        let isAnchorDoc = anchorDocNames.contains(lowerTitle)
        guard explicitProjectRaw != nil || isAnchorDoc else { return nil }

        let resolvedRawSubject: String? = explicitProjectRaw ?? inferAnchorDocProjectName(object: object, lines: headerWindow)
        guard let rawSubject = resolvedRawSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSubject.isEmpty
        else { return nil }

        let bareName = rawSubject.split(separator: "/").last.map(String.init) ?? rawSubject
        guard bareName.count >= 2, bareName.count <= 60,
              !genericContainerNames.contains(bareName.lowercased())
        else { return nil }

        // Parse structured markdown sections in STATE.md, HANDOFF.md, CLAUDE.md, and AGENTS.md:
        // `## Current Objective` / `## Objective`, `## Exact Next Action` / `## Next Action`,
        // and `## Verify` / `## Commands` fenced blocks.
        if isAnchorDoc {
            var currentHeading = ""
            var inCodeBlock = false
            for rawLine in lines.prefix(220) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    inCodeBlock.toggle()
                    continue
                }
                if !inCodeBlock, trimmed.hasPrefix("## ") {
                    currentHeading = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    continue
                }
                guard !trimmed.isEmpty, verifiedByteRange(of: trimmed, in: object.text) != nil else { continue }

                if inCodeBlock {
                    if verifyCommandMatch == nil,
                       (currentHeading == "verify" || currentHeading == "commands" || currentHeading.hasPrefix("verify ")) {
                        if !trimmed.hasPrefix("#") && trimmed.count >= 4 {
                            verifyCommandMatch = (String(trimmed.prefix(240)), trimmed)
                        }
                    }
                    continue
                }

                if objectiveMatch == nil,
                   (currentHeading == "current objective" || currentHeading == "objective") {
                    let clean = stripListPrefix(stripMarkup(trimmed))
                    if clean.count >= 8 {
                        objectiveMatch = (String(clean.prefix(240)), trimmed)
                    }
                } else if nextActionMatch == nil,
                          (currentHeading == "exact next action" || currentHeading == "next action" || currentHeading == "next steps") {
                    let clean = stripListPrefix(stripMarkup(trimmed))
                    if clean.count >= 8 {
                        nextActionMatch = (String(clean.prefix(240)), trimmed)
                    }
                }
            }
        }

        // Lead-section lifecycle status for anchor docs and explicit project notes when no
        // `Status:` key-value line was already matched.
        if statusMatch == nil {
            for rawLine in lines.prefix(35) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") { break }
                let clean = stripMarkup(trimmed).lowercased()
                guard !clean.isEmpty else { continue }

                let explicitArchived = clean.hasPrefix("archived ")
                    || clean == "archived"
                    || clean.contains("repository is archived")
                    || clean.contains("project is archived")
                    || clean.contains("status: archived")
                    || clean.contains("[archived]")
                    || clean.contains("no longer maintained")
                let explicitDeprecated = !explicitArchived && (
                    clean.hasPrefix("deprecated ")
                    || clean.contains("status: deprecated")
                    || clean.contains("[deprecated]")
                )
                if (explicitArchived || explicitDeprecated),
                   verifiedByteRange(of: trimmed, in: object.text) != nil {
                    statusMatch = (explicitArchived ? "archived" : "deprecated", trimmed)
                    break
                }
            }
        }

        var mergedTechs = explicitTechMatches
        for (techName, span) in readmeTechnologies(in: object.text) {
            if !mergedTechs.contains(where: { $0.canonicalName == techName }) {
                mergedTechs.append((techName, span))
            }
        }

        let hasAnyClaim = statusMatch != nil
            || primaryLanguageMatch != nil
            || !mergedTechs.isEmpty
            || !contributorMatches.isEmpty
            || objectiveMatch != nil
            || lastVerifiedCommitMatch != nil
            || nextActionMatch != nil
            || verifyCommandMatch != nil
            || !descriptionMatches.isEmpty
        guard hasAnyClaim else { return nil }

        let firstSeen = object.authoredAt ?? object.ingestedAt
        let lastSeen = object.ingestedAt
        let subjectEntity = CoreEntity(
            kind: .project,
            canonicalName: bareName,
            domain: object.domain,
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen
        )

        var aliases: [EntityAlias] = [
            EntityAlias(entityID: subjectEntity.id, surface: bareName, confidence: 1.0),
        ]
        if rawSubject != bareName {
            aliases.append(EntityAlias(entityID: subjectEntity.id, surface: rawSubject, confidence: 1.0))
        }

        let primaryLangEntity = primaryLanguageMatch.map { match in
            let entity = CoreEntity(
                kind: .technology,
                canonicalName: match.canonicalName,
                domain: Self.technologyDomain(for: object),
                firstSeenAt: firstSeen,
                lastSeenAt: lastSeen
            )
            return (entity: entity, matchedSpan: match.matchedSpan)
        }

        let techEntities = mergedTechs.map { match in
            let entity = CoreEntity(
                kind: .technology,
                canonicalName: match.canonicalName,
                domain: Self.technologyDomain(for: object),
                firstSeenAt: firstSeen,
                lastSeenAt: lastSeen
            )
            return (entity: entity, matchedSpan: match.matchedSpan)
        }

        let contributorEntities = contributorMatches.map { match in
            let entity = CoreEntity(
                kind: .person,
                canonicalName: match.canonicalName,
                domain: .personal,
                firstSeenAt: firstSeen,
                lastSeenAt: lastSeen
            )
            return (entity: entity, matchedSpan: match.matchedSpan)
        }

        return StructuredDocumentExtraction(
            subject: subjectEntity,
            aliases: aliases,
            status: statusMatch,
            primaryLanguage: primaryLangEntity,
            technologies: techEntities,
            contributors: contributorEntities,
            objective: objectiveMatch,
            lastVerifiedCommit: lastVerifiedCommitMatch,
            nextAction: nextActionMatch,
            verifyCommand: verifyCommandMatch,
            descriptions: descriptionMatches
        )
    }

    private static func parseCommitSHA(from rawValue: String) -> String? {
        let tokens = rawValue
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 7 && $0.count <= 40 }
        for token in tokens {
            let lower = token.lowercased()
            let isHex = lower.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
            if isHex { return lower }
        }
        return nil
    }

    private static func stripListPrefix(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        if out.hasPrefix("- ") || out.hasPrefix("* ") {
            out = String(out.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if let dotIdx = out.firstIndex(of: "."),
                  out.distance(from: out.startIndex, to: dotIdx) <= 3,
                  out[..<dotIdx].allSatisfy(\.isNumber),
                  out.index(after: dotIdx) < out.endIndex,
                  out[out.index(after: dotIdx)].isWhitespace {
            out = String(out[out.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static func parseHeaderKeyValue(_ line: String) -> (key: String, value: String)? {
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") {
            cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        guard !cleaned.hasPrefix("#"), !cleaned.hasPrefix("//"), !cleaned.hasPrefix("http"),
              let colon = cleaned.firstIndex(of: ":")
        else { return nil }
        let key = cleaned[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = cleaned[cleaned.index(after: colon)...]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`")))
        guard !key.isEmpty, key.count <= 28, !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func matchCanonicalLanguage(in rawValue: String) -> String? {
        let lower = rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (canonical, surface) in canonicalLanguages {
            if lower == surface || lower.hasPrefix(surface + " ") || lower.hasPrefix(surface + ",") {
                return canonical
            }
        }
        return nil
    }

    private static func inferAnchorDocProjectName(object: CoreObject, lines: [String]) -> String? {
        if let rel = object.metadata["relative_path"] {
            let parts = rel.split(separator: "/").map(String.init)
            if parts.count >= 2, !genericContainerNames.contains(parts[0].lowercased()) {
                return parts[0]
            }
        }
        for rawLine in lines.prefix(15) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let token = heading
                .components(separatedBy: CharacterSet(charactersIn: "\u{2014}:()"))
                .first?
                .components(separatedBy: " - ")
                .first?
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`*"))) ?? ""
            if token.count >= 2, token.count <= 40, token.split(separator: " ").count <= 3,
               !genericContainerNames.contains(token.lowercased()) {
                return token
            }
        }
        // Walk path components from the file's directory upward so nested anchor docs like
        // `/Users/.../Documents/GitHub/OpenCore/Docs/ai/STATE.md` resolve to `OpenCore`.
        let candidatePaths = [object.externalID, object.metadata["root"]].compactMap { $0 }
        for path in candidatePaths {
            let parts = path.split(separator: "/").map(String.init)
            // The account folder is never a project, and it is found by position so this reads
            // the same under any account.
            let accountIndex = parts.first?.lowercased() == "users" ? 1 : nil
            for (index, component) in parts.enumerated().reversed() where index != accountIndex {
                let lower = component.lowercased()
                if anchorDocNames.contains(lower) || lower.hasSuffix(".md") { continue }
                if !genericContainerNames.contains(lower), component.count >= 2, component.count <= 60 {
                    return component
                }
            }
        }
        return nil
    }

    private func extractStructuredDocumentClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) {
        guard let extracted = Self.structuredDocumentExtraction(from: object) else { return }
        let subject = extracted.subject.id

        if let status = extracted.status,
           let byteRange = Self.verifiedByteRange(of: status.matchedSpan, in: object.text) {
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(status.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.status,
                literal: status.value,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        if let primary = extracted.primaryLanguage,
           let byteRange = Self.verifiedByteRange(of: primary.matchedSpan, in: object.text) {
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(primary.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.primaryLanguage,
                objectEntity: primary.entity.id,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        for tech in extracted.technologies {
            guard let byteRange = Self.verifiedByteRange(of: tech.matchedSpan, in: object.text) else { continue }
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(tech.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.builtWith,
                objectEntity: tech.entity.id,
                confidence: 0.85,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 0.85))
        }

        for contributor in extracted.contributors {
            guard let byteRange = Self.verifiedByteRange(of: contributor.matchedSpan, in: object.text) else { continue }
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(contributor.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: contributor.entity.id,
                predicate: Predicate.contributedTo,
                objectEntity: subject,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        if let objective = extracted.objective,
           let byteRange = Self.verifiedByteRange(of: objective.matchedSpan, in: object.text) {
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(objective.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.objective,
                literal: objective.value,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        if let verifiedCommit = extracted.lastVerifiedCommit,
           let byteRange = Self.verifiedByteRange(of: verifiedCommit.matchedSpan, in: object.text) {
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(verifiedCommit.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.lastVerifiedCommit,
                literal: verifiedCommit.value,
                confidence: 0.98,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        if let nextAction = extracted.nextAction,
           let byteRange = Self.verifiedByteRange(of: nextAction.matchedSpan, in: object.text) {
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(nextAction.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.nextAction,
                literal: nextAction.value,
                confidence: 0.92,
                authority: object.authority,
                derivation: .observed,
                // Dated like the objective above it, because it is functional now and time is what
                // orders one revision against the next.
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        if let verifyCmd = extracted.verifyCommand,
           let byteRange = Self.verifiedByteRange(of: verifyCmd.matchedSpan, in: object.text) {
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(verifyCmd.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.verifyCommand,
                literal: verifyCmd.value,
                confidence: 0.95,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }

        for desc in extracted.descriptions {
            guard let byteRange = Self.verifiedByteRange(of: desc.matchedSpan, in: object.text) else { continue }
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(desc.matchedSpan.prefix(280)),
                authority: object.authority
            )
            evidence.append(ev)
            let claim = CoreClaim(
                subject: subject,
                predicate: Predicate.describes,
                literal: desc.value,
                confidence: 0.92,
                authority: object.authority,
                derivation: .observed,
                validity: Validity(validFrom: object.authoredAt, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }
    }

    // MARK: - REA Evidence Bundles & FINDINGS.md

    /// Entities referenced by an REA JSON evidence bundle (`predicate_type == "rea.analysis"`)
    /// or an REA `FINDINGS.md` ledger, so `EntityResolver` registers them before `ClaimExtractor`
    /// writes claims against their `EntityID`s.
    public static func reaEntities(from object: CoreObject) -> [(CoreEntity, EntityAlias)] {
        var out: [(CoreEntity, EntityAlias)] = []
        let firstSeen = object.authoredAt ?? object.ingestedAt
        let lastSeen = object.ingestedAt

        for record in parseREARecords(from: object.text) {
            if let subjectDict = record["subject"] as? [String: Any],
               let subjectName = subjectDict["name"] as? String, !subjectName.isEmpty {
                let entity = CoreEntity(
                    kind: .project,
                    canonicalName: subjectName,
                    domain: object.domain,
                    firstSeenAt: firstSeen,
                    lastSeenAt: lastSeen
                )
                out.append((entity, EntityAlias(entityID: entity.id, surface: subjectName, confidence: 1.0)))
            }
            if let providerDict = record["provider"] as? [String: Any],
               let providerName = providerDict["name"] as? String, !providerName.isEmpty {
                let entity = CoreEntity(
                    kind: .technology,
                    canonicalName: providerName,
                    domain: Self.technologyDomain(for: object),
                    firstSeenAt: firstSeen,
                    lastSeenAt: lastSeen
                )
                out.append((entity, EntityAlias(entityID: entity.id, surface: providerName, confidence: 1.0)))
            }
            if let norm = record["normalized_result"] as? [String: Any],
               let proc = norm["procedure"] as? [String: Any],
               let procName = proc["name"] as? String, !procName.isEmpty {
                let entity = CoreEntity(
                    kind: .concept,
                    canonicalName: procName,
                    domain: object.domain,
                    firstSeenAt: firstSeen,
                    lastSeenAt: lastSeen
                )
                out.append((entity, EntityAlias(entityID: entity.id, surface: procName, confidence: 0.95)))
                if let subjectDict = record["subject"] as? [String: Any],
                   let subjectName = subjectDict["name"] as? String, !subjectName.isEmpty {
                    let projectEntity = CoreEntity(
                        kind: .project,
                        canonicalName: subjectName,
                        domain: object.domain,
                        firstSeenAt: firstSeen,
                        lastSeenAt: lastSeen
                    )
                    let joined = procName.hasPrefix("_") ? "\(subjectName)\(procName)" : "\(subjectName)_\(procName)"
                    out.append((projectEntity, EntityAlias(entityID: projectEntity.id, surface: joined, confidence: 0.95)))
                }
            }
        }

        if isREAFindingsMarkdown(object) {
            for (sectionTarget, rawHead) in parseREAFindingsTargets(from: object.text) {
                let entity = CoreEntity(
                    kind: .project,
                    canonicalName: sectionTarget,
                    domain: object.domain,
                    firstSeenAt: firstSeen,
                    lastSeenAt: lastSeen
                )
                out.append((entity, EntityAlias(entityID: entity.id, surface: sectionTarget, confidence: 1.0)))
                if rawHead != sectionTarget {
                    out.append((entity, EntityAlias(entityID: entity.id, surface: rawHead, confidence: 0.95)))
                }
            }
        }

        return out
    }

    private static func parseREARecords(from text: String) -> [[String: Any]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("\"rea.analysis\"") else { return [] }

        // Direct JSON object or MCP record wrapper where a JSON block follows a summary header.
        let candidates: [String]
        if let braceIndex = trimmed.firstIndex(of: "{") {
            candidates = [trimmed, String(trimmed[braceIndex...])]
        } else {
            candidates = [trimmed]
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if (json["predicate_type"] as? String) == "rea.analysis" {
                return [json]
            }
            if let records = json["records"] as? [[String: Any]] {
                return records.filter { ($0["predicate_type"] as? String) == "rea.analysis" }
            }
        }
        return []
    }

    private static func isREAFindingsMarkdown(_ object: CoreObject) -> Bool {
        let lowerTitle = object.title.lowercased()
        let lowerExt = object.externalID.lowercased()
        return (lowerTitle == "findings.md" || lowerExt.hasSuffix("/findings.md") || lowerExt == "findings.md")
            && object.text.contains("| Class |")
    }

    private static func parseREAFindingsTargets(from text: String) -> [(canonical: String, rawHead: String)] {
        var targets: [(canonical: String, rawHead: String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("## ") else { continue }
            let header = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let head = header.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ":" }).first.map(String.init) ?? header
            let name = head.split(separator: "/").last.map(String.init) ?? head
            if !name.isEmpty, name.lowercased() != "verdict", name.lowercased() != "reconstruction" {
                targets.append((name, head))
            }
        }
        return targets
    }

    private func extractREAClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) {
        // 1. Structured REA evidence bundle (`predicate_type == "rea.analysis"`).
        for record in Self.parseREARecords(from: object.text) {
            guard let subjectDict = record["subject"] as? [String: Any],
                  let subjectName = subjectDict["name"] as? String, !subjectName.isEmpty
            else { continue }

            let subjectEntity = CoreEntity(kind: .project, canonicalName: subjectName, domain: object.domain).id
            let confidenceClass = (record["confidence"] as? String)?.lowercased() ?? "observed"
            // Never turn an `unknown` record into a claim.
            if confidenceClass == "unknown" { continue }

            let isObserved = confidenceClass == "observed" || confidenceClass == "seen"
            let derivation: Derivation = isObserved ? .observed : .inferred
            let claimAuthority: Authority = isObserved ? object.authority : min(object.authority, .derivedPattern)
            let claimConfidence: Double = isObserved ? 0.98 : 0.80

            let evidenceIDString = (record["evidence_id"] as? String) ?? subjectName
            guard let byteRange = Self.verifiedByteRange(of: evidenceIDString, in: object.text)
                ?? Self.verifiedByteRange(of: subjectName, in: object.text)
            else { continue }

            let procDict = (record["normalized_result"] as? [String: Any])?["procedure"] as? [String: Any]
            let procName = procDict?["name"] as? String
            let procAddress = procDict?["address"] as? String
            let procSignature = procDict?["signature"] as? String

            let snippetParts = [
                subjectName,
                procName,
                procSignature,
                procAddress,
                evidenceIDString,
            ].compactMap { $0 }.joined(separator: " · ")

            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(snippetParts.prefix(280)),
                authority: claimAuthority
            )
            evidence.append(ev)

            if let providerDict = record["provider"] as? [String: Any],
               let providerName = providerDict["name"] as? String, !providerName.isEmpty {
                let providerEntity = CoreEntity(kind: .technology, canonicalName: providerName, domain: Self.technologyDomain(for: object)).id
                let usesClaim = CoreClaim(
                    subject: subjectEntity,
                    predicate: Predicate.uses,
                    objectEntity: providerEntity,
                    confidence: claimConfidence,
                    authority: claimAuthority,
                    derivation: derivation,
                    validity: Validity(observedAt: now),
                    domain: object.domain
                )
                claims.append(usesClaim)
                links.append((usesClaim.id, ev.id, .supports, 1.0))
            }

            if let procName, !procName.isEmpty {
                let procEntity = CoreEntity(kind: .concept, canonicalName: procName, domain: object.domain).id
                let compClaim = CoreClaim(
                    subject: subjectEntity,
                    predicate: Predicate.hasComponent,
                    objectEntity: procEntity,
                    confidence: claimConfidence,
                    authority: claimAuthority,
                    derivation: derivation,
                    validity: Validity(observedAt: now),
                    domain: object.domain
                )
                claims.append(compClaim)
                links.append((compClaim.id, ev.id, .supports, 1.0))

                let detail = [procSignature, procAddress, "[\(evidenceIDString)]"]
                    .compactMap { $0 }
                    .joined(separator: " @ ")
                if !detail.isEmpty {
                    let descClaim = CoreClaim(
                        subject: procEntity,
                        predicate: Predicate.describes,
                        literal: detail,
                        confidence: claimConfidence,
                        authority: claimAuthority,
                        derivation: derivation,
                        validity: Validity(observedAt: now),
                        domain: object.domain
                    )
                    claims.append(descClaim)
                    links.append((descClaim.id, ev.id, .supports, 1.0))
                }
            }
        }

        // 2. REA `FINDINGS.md` markdown ledger (`seen`, `inferred`, `unknown`).
        guard Self.isREAFindingsMarkdown(object) else { return }
        var currentTarget: String?
        for rawLine in object.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let head = header.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ":" }).first.map(String.init) ?? header
                let name = head.split(separator: "/").last.map(String.init) ?? head
                if !name.isEmpty, name.lowercased() != "verdict", name.lowercased() != "reconstruction" {
                    currentTarget = name
                }
                continue
            }
            guard let targetName = currentTarget, line.hasPrefix("|"), line.hasSuffix("|") else { continue }
            let columns = line
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Expected columns: ["", "#", "Class", "Finding", "Evidence", ""]
            guard columns.count >= 5 else { continue }
            let findingClass = columns[2].trimmingCharacters(in: CharacterSet(charactersIn: "` ")).lowercased()
            let findingText = columns[3]
            guard !findingText.isEmpty, findingClass == "seen" || findingClass == "inferred" else {
                // Header rows, separator rows, and `unknown` rows never produce claims.
                continue
            }
            guard let byteRange = Self.verifiedByteRange(of: line, in: object.text) else { continue }

            let isSeen = findingClass == "seen"
            let derivation: Derivation = isSeen ? .observed : .inferred
            let claimAuthority: Authority = isSeen ? object.authority : min(object.authority, .derivedPattern)
            let claimConfidence: Double = isSeen ? 0.95 : 0.80

            let targetEntity = CoreEntity(kind: .project, canonicalName: targetName, domain: object.domain).id
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(line.prefix(280)),
                authority: claimAuthority
            )
            evidence.append(ev)

            let claim = CoreClaim(
                subject: targetEntity,
                predicate: Predicate.describes,
                literal: findingText,
                confidence: claimConfidence,
                authority: claimAuthority,
                derivation: derivation,
                validity: Validity(observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, 1.0))
        }
    }

    // MARK: - Model-Proposed Claims (`v0.6` #11, `Authority.modelInference`)

    public static let modelProposedClaimsMetadataKey = "model_proposed_claims"

    public static func decodedModelProposals(from object: CoreObject) -> [ProposedClaimRecord] {
        guard let raw = object.metadata[modelProposedClaimsMetadataKey],
              let data = raw.data(using: .utf8),
              let records = try? JSONDecoder().decode([ProposedClaimRecord].self, from: data)
        else { return [] }
        return records
    }

    /// Entities referenced by byte-verified model-proposed claims on `object` so
    /// `EntityResolver` registers them before `ClaimExtractor` writes claims against their IDs.
    public static func modelProposedEntities(from object: CoreObject) -> [(CoreEntity, EntityAlias)] {
        let records = decodedModelProposals(from: object)
        guard !records.isEmpty else { return [] }
        let firstSeen = object.authoredAt ?? object.ingestedAt
        let lastSeen = object.ingestedAt
        var out: [(CoreEntity, EntityAlias)] = []

        for record in records {
            let subjectName = record.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = record.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = record.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = record.verbatimQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subjectName.isEmpty,
                  !value.isEmpty,
                  Predicate.allVocabulary.contains(predicate),
                  verifiedByteRange(of: quote, in: object.text) != nil
            else { continue }

            let subjectDomain = record.subjectKind == .technology ? Self.technologyDomain(for: object) : object.domain
            let subjectEntity = CoreEntity(
                kind: record.subjectKind,
                canonicalName: subjectName,
                domain: subjectDomain,
                firstSeenAt: firstSeen,
                lastSeenAt: lastSeen
            )
            out.append((subjectEntity, EntityAlias(entityID: subjectEntity.id, surface: subjectName, confidence: 0.85)))

            if let valueKind = record.valueKind {
                let valueDomain = valueKind == .technology ? Self.technologyDomain(for: object) : object.domain
                let valueEntity = CoreEntity(
                    kind: valueKind,
                    canonicalName: value,
                    domain: valueDomain,
                    firstSeenAt: firstSeen,
                    lastSeenAt: lastSeen
                )
                out.append((valueEntity, EntityAlias(entityID: valueEntity.id, surface: value, confidence: 0.85)))
            }
        }
        return out
    }

    /// Deterministically validate and emit `Authority.modelInference` claims from
    /// `object.metadata["model_proposed_claims"]`.
    ///
    /// Every proposal is gated by:
    /// 1. Controlled predicate vocabulary (`Predicate.allVocabulary`).
    /// 2. Exact UTF-8 byte-span verification (`verifiedByteRange(of:in:)`) inside `object.text`.
    /// 3. `Authority.modelInference` (ordinal tier `0`, outranked by every deterministic rule)
    ///    and `Derivation.inferred`.
    private func extractModelProposedClaims(
        _ object: CoreObject,
        into claims: inout [CoreClaim],
        _ evidence: inout [Evidence],
        _ links: inout [(ClaimID, EvidenceID, Stance, Double)]
    ) {
        let records = Self.decodedModelProposals(from: object)
        guard !records.isEmpty else { return }

        for record in records {
            let subjectName = record.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = record.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = record.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = record.verbatimQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subjectName.isEmpty,
                  !value.isEmpty,
                  Predicate.allVocabulary.contains(predicate),
                  let byteRange = Self.verifiedByteRange(of: quote, in: object.text)
            else { continue }

            let subjectDomain = record.subjectKind == .technology ? Self.technologyDomain(for: object) : object.domain
            let subjectEntityID = CoreEntity(
                kind: record.subjectKind,
                canonicalName: subjectName,
                domain: subjectDomain
            ).id

            let targetEntityID: EntityID?
            let literalValue: String?
            if let valueKind = record.valueKind {
                let valueDomain = valueKind == .technology ? Self.technologyDomain(for: object) : object.domain
                targetEntityID = CoreEntity(
                    kind: valueKind,
                    canonicalName: value,
                    domain: valueDomain
                ).id
                literalValue = nil
            } else {
                targetEntityID = nil
                literalValue = value
            }

            let clampedConfidence = min(0.84, max(0.30, record.confidence))
            let ev = Evidence(
                objectID: object.id,
                range: byteRange,
                snippet: String(quote.prefix(280)),
                authority: .modelInference
            )
            evidence.append(ev)

            // Functional predicates keep `validFrom: object.authoredAt` so temporal ordering
            // works when two modelInference claims from different dates disagree; non-functional
            // predicates stay undated so repeated mentions collapse to one claim with multiple
            // evidence links.
            let validFrom = Predicate.functional.contains(predicate) ? object.authoredAt : nil
            let claim = CoreClaim(
                subject: subjectEntityID,
                predicate: predicate,
                objectEntity: targetEntityID,
                literal: literalValue,
                confidence: clampedConfidence,
                authority: .modelInference,
                derivation: .inferred,
                validity: Validity(validFrom: validFrom, observedAt: now),
                domain: object.domain
            )
            claims.append(claim)
            links.append((claim.id, ev.id, .supports, clampedConfidence))
        }
    }
}
