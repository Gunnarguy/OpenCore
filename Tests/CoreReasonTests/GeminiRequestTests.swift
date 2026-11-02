import Foundation
import Testing
@testable import CoreReason

// The fallback put its credential in the URL, exposing it in URL-oriented diagnostics and logs.
@Test("Gemini credentials occur only in the auth header while URL and body retain their contracts")
func geminiCredentialIsNotPartOfTheURL() throws {
    let fixtureKey = "fixture-header-token_27"
    let body = Data(#"{"contents":[{"parts":[{"text":"Fixture prompt."}]}]}"#.utf8)
    let request = try #require(GeminiRequest.make(apiKey: fixtureKey, body: body))
    let url = try #require(request.url)
    #expect(url.scheme == "https")
    #expect(url.host == "generativelanguage.googleapis.com")
    #expect(url.query == nil)
    #expect(url.fragment == nil)
    #expect(url.user == nil)
    #expect(url.password == nil)
    #expect(!url.absoluteString.contains(fixtureKey))
    #expect(!String(describing: request).contains(fixtureKey))
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == fixtureKey)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == body)
    #expect(request.timeoutInterval == 15)
}

// Moving an unchecked value into a header must not permit CR/LF or other control injection.
@Test("invalid Gemini header tokens are rejected without constructing a network request")
func geminiHeaderRejectsControlCharacters() {
    for token in ["", " ", "fixture token", "token\r\nX-Injected: yes", "token\n", "token\t", "token\0", "token\u{7f}", "tokené"] {
        #expect(GeminiRequest.make(apiKey: token, body: Data()) == nil)
    }
    #expect(GeminiRequest.make(apiKey: "fixture-token_27.valid", body: Data()) != nil)
}
