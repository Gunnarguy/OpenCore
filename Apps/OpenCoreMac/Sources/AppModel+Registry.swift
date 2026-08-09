import CoreIngest
import CoreModel
import CoreStore
import Foundation

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
    ) async -> String {
        guard let store else { return "store is not open" }
        guard let command = server.command else { return "this server has no launchable command" }

        // Only variables the registry declares, so a stray key in the dictionary cannot smuggle
        // an unexpected variable into the child process.
        let declared = server.package?.environment.map(\.name) ?? []

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

            let config = MCPServerConfig(
                name: name,
                command: command,
                arguments: server.arguments,
                environmentNames: declared,
                allowedTools: [],
                domain: domain
            )

            var source = MCPClientConnector(config: config).source
            source.config = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            try await store.upsert(source)
            await refresh()

            let missing = config.missingEnvironment
            if missing.isEmpty {
                return "Added \(name). Next: Discover its tools on the MCP tab and tick the ones you allow."
            }
            return "Added \(name), but these are still unset: \(missing.joined(separator: ", "))."
        } catch {
            return "failed: \(error)"
        }
    }
}
