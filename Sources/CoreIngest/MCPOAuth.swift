import CoreJSONRPC
import CryptoKit
import Foundation

/// OAuth 2.1 for hosted MCP servers.
///
/// This is what makes a "Sign in" button possible instead of asking someone to create an
/// integration in a developer portal, copy a token, and paste it into a config file. The
/// difference is `registration_endpoint`: with **dynamic client registration** OpenCore
/// registers itself with the server at runtime, so there is no client id to obtain in advance
/// and nothing for the user to set up. They approve a browser sheet and it is done.
///
/// Verified against Notion 2026-08-09: `https://mcp.notion.com` advertises authorize, token
/// and register endpoints and supports `S256`.
///
/// **No secret is ever written to the store or a log.** Tokens live in the keychain under the
/// same account scheme the environment-variable path already uses.
public enum MCPOAuth {
    // MARK: - Discovery

    /// Where a server says to authenticate.
    public struct Metadata: Sendable, Codable {
        public var issuer: String
        public var authorizationEndpoint: URL
        public var tokenEndpoint: URL
        public var registrationEndpoint: URL?
        public var codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }

        /// PKCE with SHA-256 is mandatory in OAuth 2.1. A server offering only `plain` is
        /// downgrading the exchange, and this refuses rather than complying quietly.
        public var supportsS256: Bool {
            codeChallengeMethodsSupported.map { $0.contains("S256") } ?? false
        }
    }

    public enum OAuthError: Error, CustomStringConvertible {
        case noMetadata(URL)
        case noDynamicRegistration(String)
        case pkceUnsupported(String)
        case server(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .noMetadata(let url): "no OAuth metadata at \(url.absoluteString)"
            case .noDynamicRegistration(let issuer):
                "\(issuer) does not support dynamic client registration, so a client id must be configured by hand"
            case .pkceUnsupported(let issuer): "\(issuer) does not advertise PKCE S256"
            case .server(let detail): "authorization server said: \(detail)"
            case .malformed(let detail): "malformed response: \(detail)"
            }
        }
    }

    /// Find the authorization server for an MCP endpoint.
    ///
    /// Tries the protected-resource document first, because that is the one an MCP server
    /// points at from its `WWW-Authenticate` challenge and it may delegate to a different
    /// issuer. Falls back to treating the endpoint's own origin as the issuer, which is what
    /// Notion does.
    public static func discover(endpoint: URL, resourceMetadata: URL? = nil) async throws -> Metadata {
        var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        origin?.path = ""
        origin?.query = nil
        origin?.fragment = nil

        var issuers: [URL] = []
        if let resourceMetadata, let found = try? await authorizationServer(from: resourceMetadata) {
            issuers.append(found)
        }
        if let base = origin?.url { issuers.append(base) }

        for issuer in issuers {
            for path in [".well-known/oauth-authorization-server", ".well-known/openid-configuration"] {
                let url = issuer.appendingPathComponent(path)
                if let metadata: Metadata = try? await getJSON(url) { return metadata }
            }
        }
        throw OAuthError.noMetadata(endpoint)
    }

    private static func authorizationServer(from resourceMetadata: URL) async throws -> URL? {
        struct Resource: Decodable {
            let authorizationServers: [String]?
            enum CodingKeys: String, CodingKey { case authorizationServers = "authorization_servers" }
        }
        let resource: Resource = try await getJSON(resourceMetadata)
        return resource.authorizationServers?.first.flatMap(URL.init(string:))
    }

    // MARK: - Dynamic client registration

    public struct Client: Sendable, Codable {
        public var clientID: String
        public var clientSecret: String?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }

    /// Register OpenCore with the authorization server, right now, with no prior arrangement.
    ///
    /// `token_endpoint_auth_method: none` because this is a native public client: it cannot
    /// keep a secret on a user's Mac, and claiming otherwise would be security theatre. PKCE
    /// is what actually protects the exchange.
    public static func register(
        _ metadata: Metadata,
        redirectURI: String,
        clientName: String = "OpenCore"
    ) async throws -> Client {
        guard let endpoint = metadata.registrationEndpoint else {
            throw OAuthError.noDynamicRegistration(metadata.issuer)
        }
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.server(String(data: data, encoding: .utf8)?.prefix(300).description ?? "registration failed")
        }
        return try JSONDecoder().decode(Client.self, from: data)
    }

    // MARK: - PKCE

    /// A code verifier and its S256 challenge.
    ///
    /// The verifier never leaves this process until the token exchange, so an attacker who
    /// intercepts the redirect holds an authorization code they cannot spend.
    public struct PKCE: Sendable {
        public let verifier: String
        public var challenge: String {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return Data(digest).base64URLEncoded
        }

        public init() {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            verifier = Data(bytes).base64URLEncoded
        }
    }

    /// The URL to open in the browser sheet.
    public static func authorizationURL(
        _ metadata: Metadata,
        client: Client,
        pkce: PKCE,
        redirectURI: String,
        state: String,
        resource: URL
    ) throws -> URL {
        guard metadata.supportsS256 else { throw OAuthError.pkceUnsupported(metadata.issuer) }
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // RFC 8707. Binds the token to this MCP server so it cannot be replayed against
            // another resource that trusts the same issuer.
            .init(name: "resource", value: resource.absoluteString),
        ]
        guard let url = components?.url else { throw OAuthError.malformed("could not build authorization URL") }
        return url
    }

    // MARK: - Tokens

    public struct Token: Sendable, Codable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            if let seconds = try container.decodeIfPresent(Double.self, forKey: .expiresIn) {
                expiresAt = Date().addingTimeInterval(seconds)
            } else {
                expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(accessToken, forKey: .accessToken)
            try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
            try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        }

        /// Treated as expired a minute early, so a sync does not start with a token that dies
        /// halfway through and fails as though the server were broken.
        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date().addingTimeInterval(60) >= expiresAt
        }
    }

    public static func exchange(
        code: String,
        metadata: Metadata,
        client: Client,
        pkce: PKCE,
        redirectURI: String,
        resource: URL
    ) async throws -> Token {
        try await token(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": client.clientID,
            "code_verifier": pkce.verifier,
            "resource": resource.absoluteString,
        ], metadata: metadata, client: client)
    }

    public static func refresh(
        _ token: Token,
        metadata: Metadata,
        client: Client,
        resource: URL
    ) async throws -> Token {
        guard let refreshToken = token.refreshToken else {
            throw OAuthError.server("token expired and the server issued no refresh token; sign in again")
        }
        var refreshed = try await self.token(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientID,
            "resource": resource.absoluteString,
        ], metadata: metadata, client: client)
        // Servers may omit the refresh token on rotation, meaning "keep using the old one".
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        return refreshed
    }

    private static func token(
        form: [String: String],
        metadata: Metadata,
        client: Client
    ) async throws -> Token {
        var body = form
        if let secret = client.clientSecret { body["client_secret"] = secret }

        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // The body carries `error` and `error_description`, which are far more useful than
            // the status code and are what a person needs to see.
            throw OAuthError.server(String(data: data, encoding: .utf8)?.prefix(300).description ?? "token request failed")
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    // MARK: - Storage

    /// Keychain account for a server's OAuth token. Distinct from the environment-variable
    /// accounts so a server can have both without either overwriting the other.
    public static func keychainAccount(server: String) -> String { "mcp-oauth:\(server)" }

    public static func store(_ token: Token, server: String) throws {
        let data = try JSONEncoder().encode(token)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OAuthError.malformed("could not encode token")
        }
        try Keychain.write(text, toAccount: keychainAccount(server: server))
    }

    /// The registered client is a credential too, and it must survive to refresh a token: a
    /// refresh request carries `client_id`, so losing it turns an expiring token into a forced
    /// re-authorization.
    public static func clientKeychainAccount(server: String) -> String { "mcp-oauth-client:\(server)" }

    public static func store(_ client: Client, server: String) throws {
        let data = try JSONEncoder().encode(client)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OAuthError.malformed("could not encode client registration")
        }
        try Keychain.write(text, toAccount: clientKeychainAccount(server: server))
    }

    public static func storedClient(server: String) -> Client? {
        guard let text = Keychain.read(account: clientKeychainAccount(server: server)),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Client.self, from: data)
    }

    /// A valid access token, refreshing first if it is close to expiry.
    ///
    /// Returns nil rather than throwing when there is simply no sign-in yet, because "never
    /// signed in" is a normal state with an obvious remedy and not an error worth a stack of
    /// context.
    public static func validAccessToken(server: String, endpoint: URL) async throws -> String? {
        guard let token = stored(server: server) else { return nil }
        guard token.isExpired else { return token.accessToken }
        guard let client = storedClient(server: server) else { return nil }

        let metadata = try await discover(endpoint: endpoint)
        let refreshed = try await refresh(token, metadata: metadata, client: client, resource: endpoint)
        try store(refreshed, server: server)
        return refreshed.accessToken
    }

    public static func stored(server: String) -> Token? {
        guard let text = Keychain.read(account: keychainAccount(server: server)),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Token.self, from: data)
    }

    // MARK: - Encoding

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.noMetadata(url)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Data {
    /// base64url without padding, per RFC 7636. Plain base64 would be rejected: `+` and `/`
    /// are not URL-safe and `=` is not permitted in a code challenge.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
