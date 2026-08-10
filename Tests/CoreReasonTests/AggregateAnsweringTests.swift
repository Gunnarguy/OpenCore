import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreReason

/// **The bug.** Asked "how many of my apps are built with Swift", chat answered **2** against
/// a true **12**, on 2026-08-10. Nothing malfunctioned: the answer path retrieves
/// `AnswerLimits.maximumSourceNumber` (6) passages and hands them to the model, the model
/// counted the Swift ones among those six, and the receipt, citations and grounding check all
/// came back clean. A confidently wrong number behind a valid receipt is the worst failure
/// available to this project, because nothing in the output looks wrong.
///
/// Widening the window is not the fix and was never available: that constant is welded to the
/// citation field of the guided-generation schema, and the next question counts something
/// bigger anyway. A count has to be computed over every row.
///
/// Four independent guards, asserted separately below so that deleting any one of them fails a
/// test rather than quietly regressing behind the others:
///
/// 1. the classifier routes a counting question to `.aggregate` at all,
/// 2. the count covers the whole population rather than a retrieved window,
/// 3. the domain firewall applies to counts exactly as it applies to passages,
/// 4. a qualifier the resolver cannot place declines instead of reporting the bare total.
@Suite("Counting questions")
struct AggregateAnsweringTests {
    private static func temporaryStore() async throws -> Store {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3")
        return try await Store.open(at: path)
    }

    /// Twelve Swift repositories, ten in other languages, one with no language recorded, and
    /// one private note. Deliberately more than any passage window: a correct answer here
    /// cannot come from the top-k.
    private static func seed(_ store: Store) async throws {
        let source = Source(
            kind: .github, handle: "tester", displayName: "test",
            defaultAuthority: .authoredArtifact, defaultDomain: .project
        )
        try await store.upsert(source)

        var objects: [CoreObject] = []
        for index in 0..<12 {
            objects.append(CoreObject(
                sourceID: source.id, kind: .repository, externalID: "me/swift\(index)",
                title: "swift\(index)", text: "a repository", domain: .project,
                authority: .authoredArtifact, metadata: ["language": "Swift", "archived": "false"]
            ))
        }
        for index in 0..<10 {
            objects.append(CoreObject(
                sourceID: source.id, kind: .repository, externalID: "me/python\(index)",
                title: "python\(index)", text: "a repository", domain: .project,
                authority: .authoredArtifact, metadata: ["language": "Python", "archived": "true"]
            ))
        }
        objects.append(CoreObject(
            sourceID: source.id, kind: .repository, externalID: "me/mystery",
            title: "mystery", text: "a repository", domain: .project,
            authority: .authoredArtifact, metadata: ["archived": "false"]
        ))
        objects.append(CoreObject(
            sourceID: source.id, kind: .note, externalID: "note1", title: "a note",
            text: "private thoughts", domain: .personal, authority: .authoredArtifact,
            metadata: ["completed": "true"]
        ))
        try await store.ingest(objects)
    }

    @Test("a counting question is classified as an aggregate rather than as a lookup")
    func countingQuestionsAreClassified() {
        let classifier = QueryClassifier()
        #expect(classifier.classify("how many of my apps are built with swift").queryClass == .aggregate)
        #expect(classifier.classify("how much of my work is Swift").queryClass == .aggregate)
        #expect(classifier.classify("number of repositories I own").queryClass == .aggregate)

        // `.causal` markers must survive being checked second. "How come" is not "how many",
        // and reading it as a count would route a why-question into a `GROUP BY`.
        #expect(classifier.classify("how come I replaced Pinecone").queryClass == .causal)
    }

    @Test("the count covers every matching object, not the handful a search would return")
    func countIsOverTheWholePopulation() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)

        let answer = try await AggregateAnswering(store: store)
            .answer("how many of my apps are built with swift", admitting: [.project, .publicRecord])

        // 12, and specifically not 6: `AnswerLimits.maximumSourceNumber` is the number the
        // broken path was structurally incapable of exceeding.
        #expect(answer?.count == 12)
        #expect(answer!.count > AnswerLimits.maximumSourceNumber)

        // The repository with no language recorded is held out of the denominator's meaning
        // rather than counted as "not Swift". Unmeasured is not zero.
        #expect(answer?.breakdown.total == 23)
        #expect(answer?.breakdown.unclassified == 1)
    }

    @Test("a yes/no field is counted by its true bucket, and negation flips it")
    func booleanFieldsCountTheirTrueBucket() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)
        let answering = AggregateAnswering(store: store)

        let archived = try await answering
            .answer("how many of my repos are archived", admitting: [.project, .publicRecord])
        #expect(archived?.count == 10)

        // Ignoring the negation would answer the exact opposite with a confident number, which
        // is the original defect reintroduced one level down.
        let notArchived = try await answering
            .answer("how many of my repos are not archived", admitting: [.project, .publicRecord])
        #expect(notArchived?.count == 13)
    }

    @Test("a count obeys the domain firewall exactly as retrieval does")
    func countsAreFirewalled() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)
        let answering = AggregateAnswering(store: store)

        // A count is a disclosure. Answering "1" here would reveal the existence of personal
        // material to a project-domain query while retrieving no passage, and so tripping none
        // of the checks that guard the passage path.
        let blocked = try await answering.answer("how many notes do I have", admitting: [.project, .publicRecord])
        #expect(blocked == nil)

        let admitted = try await answering.answer("how many notes do I have", admitting: [.personal])
        #expect(admitted?.count == 1)
    }

    @Test("a qualifier the resolver cannot place declines instead of reporting the bare total")
    func unplaceableQualifiersDecline() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)

        // The population resolves and the total is 23, so returning 23 would be the easy thing
        // to do. It would also silently answer a different question than the one asked, which
        // is the same class of defect as counting six passages. Declining hands the question to
        // retrieval, which is allowed to fail visibly.
        let answer = try await AggregateAnswering(store: store)
            .answer("how many of my apps did I write on a train", admitting: [.project, .publicRecord])
        #expect(answer == nil)
    }

    @Test("a counted answer states its denominator and never claims a source it did not read")
    func countedAnswersDoNotClaimSources() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)

        let answer = try await AggregateAnswering(store: store)
            .answer("how many of my apps are built with swift", admitting: [.project, .publicRecord])
        let sentence = try #require(answer?.sentence)

        // A bare "12" invites the reader to supply a denominator, and they will supply the
        // wrong one.
        #expect(sentence.contains("12 of 23"))
        #expect(sentence.contains("unaccounted for"))

        // The receipt for a counted answer must not borrow the retrieval shape: no passage was
        // read and no model was called, and a receipt saying otherwise is the original bug
        // wearing the fix's clothes.
        let receipt = Conversation.countedReceipt(
            question: "how many of my apps are built with swift",
            domain: .project, counted: try #require(answer), milliseconds: 1
        )
        #expect(receipt.objectsRetrieved == 0)
        #expect(receipt.evidenceAdmitted == 0)
        #expect(receipt.model == nil)
        #expect(receipt.confidence == nil)
        #expect(receipt.objectsSearched == 23)
    }
}

/// The counting fix was originally wired into `Conversation` only, which is the chat path.
/// `Reasoner` backs **both** `opencore ask` and `core_ask` over MCP, so for a day the same
/// question answered "12 of 22" in the app and returned a claim list to any MCP client.
///
/// These assert the two properties that make the `Reasoner` path trustworthy rather than merely
/// present: a counted answer is *distinguishable* from an empty one, and a count obeys the same
/// firewall as retrieval even when the caller is a model rather than the user.
@Suite("Counting through the Reasoner")
struct ReasonerAggregateTests {
    private static func temporaryStore() async throws -> Store {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencore-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3")
        return try await Store.open(at: path)
    }

    private static func seed(_ store: Store) async throws {
        let source = Source(
            kind: .github, handle: "tester", displayName: "test",
            defaultAuthority: .authoredArtifact, defaultDomain: .project
        )
        try await store.upsert(source)
        var objects: [CoreObject] = []
        for index in 0..<12 {
            objects.append(CoreObject(
                sourceID: source.id, kind: .repository, externalID: "me/swift\(index)",
                title: "swift\(index)", text: "a repository", domain: .project,
                authority: .authoredArtifact, metadata: ["language": "Swift"]
            ))
        }
        // Personal material, to prove a count cannot reach what retrieval cannot.
        for index in 0..<7 {
            objects.append(CoreObject(
                sourceID: source.id, kind: .note, externalID: "note\(index)", title: "note",
                text: "private", domain: .personal, authority: .authoredArtifact,
                metadata: ["list": "Inbox"]
            ))
        }
        try await store.ingest(objects)
    }

    @Test("a counted answer is marked as counted rather than looking like an empty one")
    func countedAnswersAreDistinguishable() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)

        let answer = try await Reasoner(store: store)
            .answer("how many of my apps are built with swift")

        // Both a count and a found-nothing answer have no points and no passages. A caller that
        // tells them apart by emptiness will eventually render a correct count as "no evidence".
        let counted = try #require(answer.counted)
        #expect(counted.count == 12)
        #expect(answer.points.isEmpty)
        #expect(answer.insufficientEvidence == nil)
        #expect(answer.summary.contains("12 of 12"))
    }

    @Test("the counted receipt is saved, so trace resolves an answer that cites nothing")
    func countedReceiptsArePersisted() async throws {
        let store = try await Self.temporaryStore()
        try await Self.seed(store)

        let answer = try await Reasoner(store: store).answer("how many apps do I have")

        // A receipt is only worth having if it can be looked up later. `Reasoner` saves it on
        // the retrieval path, and the counted path must not be the one exception.
        let found = try await store.receipt(code: answer.receipt.shortCode)
        #expect(found != nil)
        #expect(found?.queryClass == .aggregate)
        #expect(found?.objectsRetrieved == 0)
        #expect(found?.model == nil)
    }

    /// Five medical appointments, which only a query naming a medical term may reach.
    private static func seedMedical(_ store: Store) async throws {
        let source = Source(
            kind: .calendar, handle: "cal", displayName: "cal",
            defaultAuthority: .authoredArtifact, defaultDomain: .personal
        )
        try await store.upsert(source)
        try await store.ingest((0..<5).map { index in
            CoreObject(
                sourceID: source.id, kind: .calendarEvent, externalID: "appt\(index)",
                // The calendar is named "Doctor" so the word in the question resolves to a
                // facet value. Without that it lands in the residue check and the resolver
                // declines, which is correct behaviour but would make this test pass for the
                // wrong reason: blocked-by-firewall and declined-as-unplaceable both read as
                // `counted == nil`, and only one of them is what is being asserted here.
                title: "appointment", text: "an appointment", domain: .medical,
                authority: .authoredArtifact, metadata: ["calendar": "Doctor"]
            )
        })
    }

    @Test("an external caller cannot count what it is not allowed to retrieve")
    func countsRespectTheExternalCallerFirewall() async throws {
        // One store, one question, asked twice. This needed two isolated stores until
        // 2026-08-10, because `Receipt.id` was derived from the query plus a millisecond and
        // the second save collided. That is fixed, and asking twice here is now also a small
        // standing check that it stays fixed on a real code path rather than only in
        // `ReceiptIdentityTests`.
        let store = try await Self.temporaryStore()
        try await Self.seedMedical(store)
        let reasoner = Reasoner(store: store)

        // Medical rather than personal on purpose. `.personal` is not in `Domain.sensitive`, so
        // `externalCaller` does not re-base it and the two callers would classify identically;
        // a test written against notes passes for a reason that has nothing to do with the
        // firewall. Only medical, financial and relationship exercise the downgrade.
        //
        // Answering "5" to a model here is the disclosure the firewall exists to refuse, and it
        // would happen while retrieving zero passages and so tripping none of the checks that
        // guard the passage path. A count is a disclosure.
        let external = try await reasoner
            .answer("how many doctor appointments do I have", externalCaller: true)
        #expect(external.counted == nil)

        // The same question typed by the person whose records these are is answerable, because
        // naming a sensitive domain is consent when a human does it. If this ever returns nil
        // too, the firewall has become a blanket refusal and the distinction it exists to draw
        // has been lost.
        let local = try await reasoner
            .answer("how many doctor appointments do I have", externalCaller: false)
        #expect(local.counted?.count == 5)
    }
}
