import CoreModel
import CoreStore
import Foundation
import Testing

@testable import CoreGraph

/// **The bug.** `extractCalendarClaims` read the raw invite list and asserted `met_with` at
/// `derivation: .observed`, confidence 0.9, for every name on it. Measured 2026-08-14 on the
/// real store: a company-wide yoga invite produced **4,004 claims stating the user had met
/// those people**, and nine broadcast events produced **5,175 of the store's 5,216 met_with
/// claims**. Six actual meetings produced the other 44.
///
/// What an invite list observes is that someone was invited. Meeting is an inference on top of
/// that, and a false one at scale. The same file refuses to derive claims from notes because
/// "inferring facts from prose without a model is exactly the guessing this extractor refuses
/// to do"; this was the same guess with structured data as an alibi.
///
/// Two independent guards now, asserted separately below because either one passing alone would
/// still leave the store full of false claims:
///
/// 1. Only people who **accepted** count. `EKParticipant.participantStatus` was being dropped by
///    the connector, and it is the only field separating a person you met from a person who
///    received an invitation.
/// 2. Only events **at or below `metWithCeiling`**. Accepting a 270-person town hall is
///    attending it; it is not meeting 270 people.

private func temporaryStore() async throws -> Store {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencore-calendar-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3")
    return try await Store.open(at: path)
}

private let source = Source(
    kind: .calendar, handle: "Calendar", displayName: "Calendar",
    defaultAuthority: .authoredArtifact, defaultDomain: .personal
)

private let occurred = Date(timeIntervalSince1970: 1_754_000_000)

/// `invited` are all names on the event; `accepted` is the subset who said yes. `accepted: nil`
/// models an object written before the connector recorded status at all.
private func event(_ title: String, invited: [String], accepted: [String]?) -> CoreObject {
    var metadata: [String: String] = [
        "calendar": "Work",
        "all_day": "false",
        "attendee_count": String(invited.count),
        "attendees": invited.joined(separator: "\u{1F}"),
    ]
    if let accepted { metadata["attendees_accepted"] = accepted.joined(separator: "\u{1F}") }

    return CoreObject(
        sourceID: source.id,
        kind: .calendarEvent,
        externalID: "event:\(title)",
        title: title,
        text: "\(title)\nInvited: \(invited.count), accepted: \(accepted?.count ?? 0)",
        authoredAt: occurred,
        domain: .personal,
        authority: .authoredArtifact,
        metadata: metadata
    )
}

private func metWith(in store: Store) async throws -> [CoreClaim] {
    try await store.allClaims(currentOnly: true, limit: 10_000)
        .filter { $0.predicate == Predicate.metWith }
}

@Test("being invited is not meeting: only people who accepted are counted")
func onlyAcceptedAttendeesAreMet() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    _ = try await IngestPipeline(store: store).run(objects: [
        event("Design review", invited: ["Ada", "Grace", "Alan", "Edsger"], accepted: ["Ada", "Grace"]),
    ])

    let met = try await metWith(in: store)
    #expect(met.count == 2)

    // Named, not just counted. A guard that kept the right *number* while picking the wrong
    // people would pass a count assertion and be useless.
    let names = try await withNames(met, in: store)
    #expect(names == ["Ada", "Grace"])
}

@Test("a broadcast invitation produces no claim that anyone was met")
func broadcastEventsAssertNoMeeting() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    // Everyone accepted, so acceptance alone does not save this: it is the size that makes
    // "met" false. This is the yoga invite in miniature.
    let crowd = (1...ClaimExtractor.metWithCeiling + 1).map { "Person \($0)" }
    _ = try await IngestPipeline(store: store).run(objects: [
        event("Global town hall", invited: crowd, accepted: crowd),
    ])

    #expect(try await metWith(in: store).isEmpty)

    // But the event is not discarded. It stays on the timeline, because "you were at this" is
    // true and only "you met these people" was not. Withholding a false claim must not cost
    // the true record underneath it.
    let timeline = try await store.events(
        from: occurred.addingTimeInterval(-86_400),
        to: occurred.addingTimeInterval(86_400)
    )
    #expect(timeline.contains { $0.detail.contains("Global town hall") })
}

@Test("an event at the ceiling still counts, and one above it does not")
func theBoundaryIsWhereItSaysItIs() async throws {
    let atLimit = try await temporaryStore()
    try await atLimit.upsert(source)
    let exactly = (1...ClaimExtractor.metWithCeiling).map { "Person \($0)" }
    _ = try await IngestPipeline(store: atLimit).run(objects: [
        event("Team gathering", invited: exactly, accepted: exactly),
    ])
    #expect(try await metWith(in: atLimit).count == ClaimExtractor.metWithCeiling)

    let over = try await temporaryStore()
    try await over.upsert(source)
    let oneMore = (1...ClaimExtractor.metWithCeiling + 1).map { "Person \($0)" }
    _ = try await IngestPipeline(store: over).run(objects: [
        event("All hands", invited: oneMore, accepted: oneMore),
    ])
    #expect(try await metWith(in: over).isEmpty)
}

@Test("an event recorded before attendance was captured asserts nothing about who was met")
func missingStatusAssertsNothing() async throws {
    let store = try await temporaryStore()
    try await store.upsert(source)

    // `accepted: nil` is an object from before the connector recorded participant status. The
    // old code read the invite list here, which is how "nobody looked" silently became
    // "everyone attended". Unmeasured stays nil.
    _ = try await IngestPipeline(store: store).run(objects: [
        event("Old meeting", invited: ["Ada", "Grace"], accepted: nil),
    ])

    #expect(try await metWith(in: store).isEmpty)
}

private func withNames(_ claims: [CoreClaim], in store: Store) async throws -> [String] {
    var names: [String] = []
    for claim in claims {
        guard let id = claim.objectEntity, let entity = try await store.entity(id) else { continue }
        names.append(entity.canonicalName)
    }
    return names.sorted()
}
