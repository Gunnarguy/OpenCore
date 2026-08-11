import CoreIngest
import CoreModel
import CoreStore
import Foundation

/// Whether a server was recorded, and what to tell the reader either way.
///
/// A plain string could not distinguish "added, go and choose its tools" from "refused, here is
/// why", and the caller has to know: moving the reader on to the next step when nothing was
/// written would hide the reason it was not.
enum RegistryAddOutcome: Sendable {
    case added(String)
    case refused(String)

    var message: String {
        switch self {
        case .added(let text), .refused(let text): text
        }
    }

    var didAdd: Bool {
        if case .added = self { return true }
        return false
    }
}

extension AppModel {
    /// Turn a registry listing into a configured source.
    ///
    /// Credential values go to the keychain, keyed per server, and are never held on the
    /// config or written to the store. The config records only the variable *names*, which is
    /// the same contract the CLI has always had.
    ///
    /// Deliberately does **not** set an allowlist. Adding a server records it; choosing which
    /// of its tools may run is a separate, human step, because an MCP server can expose tools
    /// that send messages or delete data and no amount of registry metadata makes that safe to
    /// infer.
    func addRegistryServer(
        _ server: RegistryServer,
        name: String,
        domain: Domain,
        environment: [String: String]
    ) async -> RegistryAddOutcome {
        guard let store else { return .refused("store is not open") }

        // Both ways in. A hosted server needs no command and no environment variables: it
        // authenticates with OAuth after it is added, which is why the return message below
        // sends the reader somewhere different depending on which one this is.
        let reachability = server.reachability
        guard reachability.isUsable else {
            return .refused(reachability.reason.map { "cannot add this server: \($0)" } ?? "cannot add this server")
        }

        // Only variables the registry declares, so a stray key in the dictionary cannot smuggle
        // an unexpected variable into the child process. A hosted server declares none.
        let declared = reachability.isHosted ? [] : (server.package?.environment.map(\.name) ?? [])

        do {
            for variable in declared {
                let value = (environment[variable] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let account = Keychain.mcpAccount(server: name, variable: variable)
                if value.isEmpty {
                    try Keychain.delete(account: account)
                } else {
                    try Keychain.write(value, toAccount: account)
                }
            }

            let config: MCPServerConfig
            switch reachability {
            case .connect(let endpoint):
                config = MCPServerConfig(
                    name: name,
                    url: endpoint,
                    // Unused when `url` is set, and empty rather than a placeholder so a
                    // misconfigured source fails as "no endpoint" instead of trying to launch
                    // a program called something plausible.
                    command: "",
                    allowedTools: [],
                    domain: domain
                )
            case .launch(let command, let arguments):
                config = MCPServerConfig(
                    name: name,
                    command: command,
                    arguments: arguments,
                    environmentNames: declared,
                    allowedTools: [],
                    domain: domain
                )
            case .no:
                return .refused("cannot add this server")
            }

            var source = MCPClientConnector(config: config).source
            source.config = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            try await store.upsert(source)
            await refresh()

            // A hosted server cannot list its tools until it is signed in, so sending the reader
            // to Discover first would hand them a failure. The order is the opposite of the
            // subprocess case and saying so is the difference between the flow working and the
            // reader concluding it is broken.
            if reachability.isHosted {
                return .added("Added \(name). Next: sign in on its row, then Choose tools and tick the ones you allow.")
            }

            let missing = config.missingEnvironment
            if missing.isEmpty {
                return .added("Added \(name). Next: Choose tools on its row and tick the ones you allow.")
            }
            return .added("Added \(name), but these are still unset: \(missing.joined(separator: ", ")).")
        } catch {
            return .refused("failed: \(error)")
        }
    }
}
