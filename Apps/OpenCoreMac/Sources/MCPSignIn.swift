import AppKit
import AuthenticationServices
import CoreIngest
import Foundation

/// The "Sign in" button, and the only part of OAuth that has to happen in the app.
///
/// `ASWebAuthenticationSession` needs a presentation anchor, so the browser sheet cannot come
/// from the CLI. Everything else, discovery, registration, the token exchange and refresh,
/// lives in `MCPOAuth` where both surfaces can reach it. The app signs in once and writes the
/// token to the keychain; `opencore sync` reads it from there. That is the same split the
/// environment-variable credentials already use.
///
/// **The password is never seen by OpenCore.** The sheet is a real browser session owned by
/// the system: the user types their credentials into Notion's own page, and what comes back
/// is an authorization code, not a password.
@MainActor
final class MCPSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case cancelled
        case noCode
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .noCode: "The server redirected back without an authorization code."
            case .stateMismatch:
                "The sign-in response did not match the request that started it, so it was rejected."
            }
        }
    }

    /// Must match the value registered with the authorization server.
    static let redirectURI = "opencore://oauth/callback"
    static let callbackScheme = "opencore"

    private var session: ASWebAuthenticationSession?

    /// Run the whole flow and leave a usable token in the keychain.
    func signIn(server: String, endpoint: URL) async throws {
        let metadata = try await MCPOAuth.discover(endpoint: endpoint)

        // Reuse a previous registration when there is one. Registering afresh on every sign-in
        // would litter the authorization server with abandoned clients.
        let client: MCPOAuth.Client
        if let existing = MCPOAuth.storedClient(server: server) {
            client = existing
        } else {
            client = try await MCPOAuth.register(metadata, redirectURI: Self.redirectURI)
            try MCPOAuth.store(client, server: server)
        }

        let pkce = MCPOAuth.PKCE()
        let state = UUID().uuidString
        let authorize = try MCPOAuth.authorizationURL(
            metadata, client: client, pkce: pkce,
            redirectURI: Self.redirectURI, state: state, resource: endpoint
        )

        let callback = try await present(authorize)

        // Check `state` before touching the code. This is the CSRF guard: without it, an
        // attacker can hand the app a code from a session the user never started.
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw SignInError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SignInError.noCode
        }

        let token = try await MCPOAuth.exchange(
            code: code, metadata: metadata, client: client,
            pkce: pkce, redirectURI: Self.redirectURI, resource: endpoint
        )
        try MCPOAuth.store(token, server: server)
    }

    /// Sign out by forgetting the token. The registration is kept, so signing back in does not
    /// create a second client on the authorization server.
    static func signOut(server: String) {
        try? Keychain.delete(account: MCPOAuth.keychainAccount(server: server))
    }

    static func isSignedIn(server: String) -> Bool {
        MCPOAuth.stored(server: server) != nil
    }

    // MARK: - The sheet

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                // `callbackURLScheme:` is deprecated as of macOS 14.4 in favour of a
                // `Callback` value, which also supports https-host callbacks. A custom scheme
                // is right here: OpenCore is a native app with no web domain to prove.
                callback: .customScheme(Self.callbackScheme)
            ) { @Sendable callback, error in
                // **`@Sendable` is load-bearing and this crashed without it.**
                //
                // `ASWebAuthenticationSessionCompletionHandler` carries neither
                // `NS_SWIFT_SENDABLE` nor `NS_SWIFT_UI_ACTOR` in the SDK, so a closure literal
                // written inside this `@MainActor` type inherited main-actor isolation, and
                // Swift 6 emitted an executor check to enforce it. AuthenticationServices
                // invokes the block on its XPC reply queue
                // (`com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent`), the check
                // failed, and the process trapped in `_dispatch_assert_queue_fail` before any
                // of this code ran.
                //
                // Marking the closure `@Sendable` opts it out of inheriting isolation, which
                // is the truth: this runs on whatever queue the framework chooses. Resuming a
                // continuation is safe from any executor, and nothing else here touches
                // main-actor state.
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: SignInError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SignInError.noCode)
                }
            }
            session.presentationContextProvider = self
            // Do not reuse whatever the browser already has. A shared cookie jar is how
            // someone ends up silently connecting the wrong account, which for a store of
            // personal history is the worst possible quiet failure.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }
    }

    /// `ASWebAuthenticationPresentationContextProviding` is declared `NS_SWIFT_UI_ACTOR`, so
    /// this requirement is already main-actor isolated and satisfying it from a `@MainActor`
    /// type needs nothing special. The previous `nonisolated` + `MainActor.assumeIsolated`
    /// was defending against a constraint the SDK does not impose, and would itself have
    /// trapped had the framework ever called it off the main thread.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}
