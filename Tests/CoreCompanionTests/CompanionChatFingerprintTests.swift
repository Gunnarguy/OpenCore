import CoreCompanion
import Foundation
import Testing
@testable import CoreCompanionHost

@Test("a phone request fingerprint has a stable independently computed UTF-8 vector")
func companionChatFingerprintMatchesIndependentVector() throws {
    let thread = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
    var request = CompanionRequest(section: .chat, query: "café\u{0}fixture", domain: "project", chatThreadID: thread)
    request.id = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
    #expect(CompanionChatFingerprint.hex(request) == "4a8b2e5afce9c2a38a87d60c5ed32122322646232f04fd04335b1c1e04eefd2b")
    request.asOf = Date(timeIntervalSinceReferenceDate: 1.5)
    #expect(CompanionChatFingerprint.hex(request) == "16725eb12d106f02aa9deca1796ca199ba874cf04b5831a65b0d102211e1614a")
    let roundTrip = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
    #expect(roundTrip.id == request.id && roundTrip.chatThreadID == request.chatThreadID && roundTrip.asOf == request.asOf)
    #expect(CompanionChatFingerprint.hex(roundTrip) == CompanionChatFingerprint.hex(request))
}

@Test("every phone request field changes the durable fingerprint")
func companionChatFingerprintBindsEveryWireField() {
    let original = CompanionRequest(section: .chat, query: "fixture", domain: "project", chatThreadID: UUID())
    let expected = CompanionChatFingerprint.hex(original)
    var variants: [CompanionRequest] = []
    var next = original; next.id = UUID(); variants.append(next)
    next = original; next.section = .home; variants.append(next)
    next = original; next.query += "x"; variants.append(next)
    next = original; next.recordID = ""; variants.append(next)
    next = original; next.domain = nil; variants.append(next)
    next = original; next.asOf = Date(timeIntervalSinceReferenceDate: 1); variants.append(next)
    next = original; next.offset = 1; variants.append(next)
    next = original; next.answerMode = .evidence; variants.append(next)
    next = original; next.resumeID = UUID(); variants.append(next)
    next = original; next.chatHistoryAction = .list; variants.append(next)
    next = original; next.chatThreadID = UUID(); variants.append(next)
    #expect(expected.count == 64)
    for variant in variants { #expect(CompanionChatFingerprint.hex(variant) != expected) }
    #expect(CompanionChatFingerprint.hex(original) == expected)
}

@Test("phone request fingerprints retain exact string bytes and adjacent instants")
func companionChatFingerprintRetainsExactValues() {
    var first = CompanionRequest(section: .chat, query: "café", chatThreadID: UUID())
    var second = first
    second.query = "cafe\u{301}"
    #expect(CompanionChatFingerprint.hex(first) != CompanionChatFingerprint.hex(second))
    first.asOf = Date(timeIntervalSinceReferenceDate: 1.0)
    second = first
    second.asOf = Date(timeIntervalSinceReferenceDate: 1.0.nextUp)
    #expect(first.asOf?.timeIntervalSinceReferenceDate != second.asOf?.timeIntervalSinceReferenceDate)
    #expect(CompanionChatFingerprint.hex(first) != CompanionChatFingerprint.hex(second))
}
