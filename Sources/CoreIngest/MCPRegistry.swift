import CoreModel
import Foundation

/// A server as published to the official MCP registry.
public struct RegistryServer: Sendable, Identifiable, Hashable {
    public let name: String
    public let title: String
    public let description: String
    public let version: String
    public let repositoryURL: String?
    public let package: Package?
    /// Remote endpoints. A server with only these and no `package` cannot be launched as a
    /// subprocess, which is the only transport OpenCore's client speaks.
    public let remotes: [String]
    public let isLatest: Bool

    public var id: String { name + "@" + version }

    public struct Package: Sendable, Hashable {
        public let registryType: String
        public let identifier: String
        public let runtimeHint: String?
        public let runtimeArguments: [String]
        public let environment: [EnvironmentVariable]
        public let transport: String
    }

    public struct EnvironmentVariable: Sendable, Hashable, Identifiable {
        public let name: String
        public let description: String
        public let isRequired: Bool
        /// The registry's own flag. Drives whether the field is masked and whether OpenCore
        /// warns that the value belongs in the keychain rather than anywhere it can be read.
        public let isSecret: Bool
        public let defaultValue: String?

        public var id: String { name }
    }

    /// Whether OpenCore can actually run this one.
    ///
    /// Reported as a reason rather than a bool, because "cannot use" with no explanation is
    /// the kind of dead end that makes a catalogue feel broken.
    public var launchability: Launchability {
        guard let package else {
            return remotes.isEmpty
                ? .no("no package and no endpoint published")
                : .no("remote-only (\(remotes.joined(separator: ", "))); OpenCore's client speaks stdio")
        }
        guard package.transport == "stdio" else {
            return .no("declares \(package.transport) transport, not stdio")
        }
        guard command != nil else {
            return .no("no runtime hint for a \(package.registryType) package")
        }
        return .yes
    }

    public enum Launchability: Sendable, Hashable {
        case yes
        case no(String)

        public var canLaunch: Bool { if case .yes = self { return true }; return false }
        public var reason: String? { if case .no(let why) = self { return why }; return nil }
    }

    /// Best-effort reconstruction of the launch command.
    ///
    /// The registry publishes a package identifier and a runtime hint rather than a literal
    /// command line, so this maps the common ecosystems. It is a starting point the user
    /// edits before saving, not an authority: a wrong guess here produces a server that
    /// fails to launch, which is visible and harmless, and `discover` is the next step
    /// regardless.
    public var command: String? {
        guard let package else { return nil }
        if let hint = package.runtimeHint, !hint.isEmpty { return hint }
        return switch package.registryType {
        case "npm": "npx"
        case "pypi": "uvx"
        case "oci": "docker"
        case "nuget": "dnx"
        default: nil
        }
    }

    public var arguments: [String] {
        guard let package else { return [] }
        // Runtime flags first (`-y` for npx), then the package identifier.
        return package.runtimeArguments + [package.identifier]
    }

    public var requiredEnvironment: [EnvironmentVariable] {
        package?.environment.filter(\.isRequired) ?? []
    }
}

/// Reads the official MCP registry.
///
/// This is the "store" half of MCP support. Being able to *use* any server is only half the
/// value if finding one means knowing its name already; the registry is the catalogue, and
/// it passed 9,652 servers in May 2026.
///
/// Read-only, unauthenticated, and it installs nothing. Adding a server from here writes a
/// configuration; the package itself is fetched by `npx`/`uvx` at launch, the same as it
/// would be from any other client.
public struct MCPRegistry: Sendable {
    public static let baseURL = "https://registry.modelcontextprotocol.io/v0"

    public init() {}

    public struct Page: Sendable {
        public let servers: [RegistryServer]
        public let nextCursor: String?
    }

    public enum RegistryError: Error, CustomStringConvertible {
        case http(Int)
        case offline(String)

        public var description: String {
            switch self {
            case .http(let code): "the registry returned HTTP \(code)"
            case .offline(let detail): "could not reach the registry: \(detail)"
            }
        }
    }

    /// One page of servers, optionally filtered by a search term.
    ///
    /// - Parameter latestOnly: the registry returns every published version, so the same
    ///   server appears repeatedly. Filtering to `isLatest` is what makes the list read as a
    ///   catalogue rather than a changelog.
    public func servers(search: String? = nil, cursor: String? = nil, limit: Int = 50, latestOnly: Bool = true) async throws -> Page {
        var components = URLComponents(string: Self.baseURL + "/servers")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("OpenCore", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RegistryError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegistryError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(Wire.Response.self, from: data)
        var servers = decoded.servers.map(RegistryServer.init(wire:))
        if latestOnly { servers = servers.filter(\.isLatest) }
        return Page(servers: servers, nextCursor: decoded.metadata.nextCursor)
    }
}

// MARK: - Wire types

extension RegistryServer {
    init(wire entry: MCPRegistry.Wire.Entry) {
        let server = entry.server
        name = server.name
        title = server.title ?? server.name
        description = server.description ?? ""
        version = server.version ?? "unknown"
        repositoryURL = server.repository?.url
        remotes = (server.remotes ?? []).map(\.type)
        isLatest = entry.meta?.official?.isLatest ?? true

        if let first = server.packages?.first {
            package = Package(
                registryType: first.registryType ?? "unknown",
                identifier: first.identifier ?? "",
                runtimeHint: first.runtimeHint,
                runtimeArguments: (first.runtimeArguments ?? []).compactMap(\.value),
                environment: (first.environmentVariables ?? []).map {
                    EnvironmentVariable(
                        name: $0.name,
                        description: $0.description ?? "",
                        isRequired: $0.isRequired ?? false,
                        isSecret: $0.isSecret ?? false,
                        defaultValue: $0.default
                    )
                },
                transport: first.transport?.type ?? "stdio"
            )
        } else {
            package = nil
        }
    }
}

extension MCPRegistry {
    enum Wire {
        struct Response: Decodable {
            let servers: [Entry]
            let metadata: Metadata
        }

        struct Metadata: Decodable {
            let nextCursor: String?
            let count: Int?
        }

        struct Entry: Decodable {
            let server: Server
            let meta: Meta?

            private enum CodingKeys: String, CodingKey {
                case server
                case meta = "_meta"
            }
        }

        struct Meta: Decodable {
            let official: Official?

            private enum CodingKeys: String, CodingKey {
                case official = "io.modelcontextprotocol.registry/official"
            }
        }

        struct Official: Decodable {
            let status: String?
            let isLatest: Bool?
        }

        struct Server: Decodable {
            let name: String
            let title: String?
            let description: String?
            let version: String?
            let repository: Repository?
            let packages: [Package]?
            let remotes: [Remote]?
        }

        struct Repository: Decodable {
            let url: String?
            let source: String?
        }

        struct Remote: Decodable {
            let type: String
            let url: String?
        }

        struct Package: Decodable {
            let registryType: String?
            let identifier: String?
            let runtimeHint: String?
            let runtimeArguments: [Argument]?
            let environmentVariables: [EnvVar]?
            let transport: Transport?
        }

        struct Argument: Decodable {
            let value: String?
        }

        struct Transport: Decodable {
            let type: String?
        }

        struct EnvVar: Decodable {
            let name: String
            let description: String?
            let isRequired: Bool?
            let isSecret: Bool?
            let `default`: String?
        }
    }
}
