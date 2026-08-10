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
