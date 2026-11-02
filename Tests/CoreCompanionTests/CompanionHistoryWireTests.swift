import CoreCompanion
import Foundation
import Testing

private struct LegacyCompanionPage: Decodable {
    let title: String
    let note: String
    let records: [CompanionRecord]
    let metrics: [CompanionField]
    let nextOffset: Int?
    let generatedAt: Date
    let receiptID: String?
}

@Test("phone record identity and pagination preserve distinct UTF-8 identifiers")
func companionRecordPaginationKeepsExactIDs() throws {
    let first = CompanionRecord(id: "\u{00E9}", title: "First")
    let second = CompanionRecord(id: "e\u{0301}", title: "Second")
    #expect(first.identityBytes != second.identityBytes)
    let merged = CompanionRecord.appendingDistinct([second, first, second], to: [first])
    #expect(merged.count == 2)
    #expect(merged.map(\.identityBytes) == [first.identityBytes, second.identityBytes])
    let decoded = try JSONDecoder().decode([CompanionRecord].self, from: JSONEncoder().encode(merged))
    #expect(decoded.map(\.identityBytes) == [first.identityBytes, second.identityBytes])
}

@Test("connecting clears recovered content and a new pairing also drops old resume tokens", arguments: [false, true])
func companionRecoveryStartsClean(isNewPairing: Bool) {
    let id = UUID()
    var recovery = CompanionRecoveryState(pending: (id, .corpus),
        page: CompanionPage(title: "Old Mac", records: [CompanionRecord(id: "fixture", title: "Private fixture")]))
    recovery.beginConnection(isNewPairing: isNewPairing)
    #expect(recovery.page == nil)
    if isNewPairing { #expect(recovery.pending == nil) }
    else { #expect(recovery.pending?.id == id && recovery.pending?.section == .corpus) }
}

@Test("stale recovery completions cannot repopulate a reset session")
func companionRecoveryRejectsStaleCompletion() {
    let page = CompanionPage(title: "Old response")
    var recovery = CompanionRecoveryState()
    let old = recovery.epoch
    recovery.beginConnection(isNewPairing: true)
    recovery.publish(page, ifCurrent: old)
    #expect(recovery.page == nil)
    let current = recovery.epoch
    recovery.publish(page, ifCurrent: current)
    #expect(recovery.page?.title == page.title)
    recovery.endSession()
    recovery.publish(page, ifCurrent: current)
    #expect(recovery.page == nil)
}

@Test("saved-chat wire fields remain compatible with legacy requests and pages")
func companionHistoryWireKeepsLegacyCompatibility() throws {
    let legacyRequest = Data("""
    {"id":"00000000-0000-4000-8000-000000000001","section":"chat","query":"fixture","offset":0,"answerMode":"chat"}
    """.utf8)
    let decoded = try JSONDecoder().decode(CompanionRequest.self, from: legacyRequest)
    #expect(decoded.chatHistoryAction == nil && decoded.chatThreadID == nil)
    let legacyPage = Data("""
    {"title":"Fixture","note":"","records":[],"metrics":[],"generatedAt":0}
    """.utf8)
    let oldPage = try JSONDecoder().decode(CompanionPage.self, from: legacyPage)
    #expect(oldPage.chatHistoryVersion == nil && oldPage.chatThreadID == nil)

    let thread = UUID()
    let newPage = CompanionPage(title: "Fixture", chatHistoryVersion: 1, chatThreadID: thread)
    let bytes = try JSONEncoder().encode(newPage)
    #expect(try JSONDecoder().decode(LegacyCompanionPage.self, from: bytes).title == "Fixture")
    let roundTrip = try JSONDecoder().decode(CompanionPage.self, from: bytes)
    #expect(roundTrip.chatHistoryVersion == 1 && roundTrip.chatThreadID == thread)
}

@Test("unknown saved-chat operations do not decode as a different request")
func companionHistoryWireRejectsUnknownAction() {
    let request = Data("""
    {"id":"00000000-0000-4000-8000-000000000001","section":"chat","query":"","offset":0,"answerMode":"chat","chatHistoryAction":"unknown"}
    """.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(CompanionRequest.self, from: request) }
}

@Test("saved-chat wire preserves request identity and rejects malformed history fields")
func companionHistoryWireValidatesNewFields() throws {
    let thread = UUID(), resume = UUID()
    let request = CompanionRequest(section: .chat, domain: "project", resumeID: resume,
        chatHistoryAction: .open, chatThreadID: thread)
    let decoded = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded.id == request.id && decoded.resumeID == resume)
    #expect(decoded.chatHistoryAction == .open && decoded.chatThreadID == thread && decoded.domain == "project")
    let explicitNull = Data("""
    {"id":"00000000-0000-4000-8000-000000000001","section":"chat","query":"","offset":0,"answerMode":"chat","chatHistoryAction":null,"chatThreadID":null}
    """.utf8)
    let absent = try JSONDecoder().decode(CompanionRequest.self, from: explicitNull)
    #expect(absent.chatHistoryAction == nil && absent.chatThreadID == nil)
    for fields in ["\"chatThreadID\":\"not-a-uuid\"", "\"chatThreadID\":42", "\"chatHistoryAction\":42"] {
        let json = "{\"id\":\"00000000-0000-4000-8000-000000000001\",\"section\":\"chat\",\"query\":\"\",\"offset\":0,\"answerMode\":\"chat\",\(fields)}"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CompanionRequest.self, from: Data(json.utf8)) }
    }
}

@Test("history capability and thread markers must match before a phone displays a reply")
func companionHistoryWireRequiresMatchingThread() {
    let thread = UUID(), other = UUID()
    #expect(CompanionPage(title: "old").supportsChatHistoryList == false)
    #expect(CompanionPage(title: "list", chatHistoryVersion: 1).supportsChatHistoryList)
    #expect(!CompanionPage(title: "list", chatHistoryVersion: 1, chatThreadID: other).supportsChatHistoryList)
    #expect(CompanionPage(title: "answer", chatHistoryVersion: 1, chatThreadID: thread).matchesChatHistory(thread: thread))
    for page in [CompanionPage(title: "missing", chatHistoryVersion: 1),
                 CompanionPage(title: "wrong", chatHistoryVersion: 1, chatThreadID: other),
                 CompanionPage(title: "future", chatHistoryVersion: 2, chatThreadID: thread)] {
        #expect(!page.matchesChatHistory(thread: thread))
    }
}
