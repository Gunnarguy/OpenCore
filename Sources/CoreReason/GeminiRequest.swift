import Foundation

/// Pure construction: caller opt-in and domain admission stay at the generation call site.
enum GeminiRequest {
    static func make(apiKey: String, body: Data) -> URLRequest? {
        // Opaque visible-ASCII token only. Reject whitespace/control bytes rather than allowing
        // a malformed environment value to become an injected HTTP header.
        guard !apiKey.isEmpty, apiKey.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body
        request.timeoutInterval = 15 // Chosen bound, retained from the existing fallback.
        return request
    }
}
