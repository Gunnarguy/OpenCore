import CoreIngest
import CoreModel
import SwiftUI

/// The catalogue. Browse every server published to the official MCP registry, configure one,
/// and add it as a source.
///
/// Being able to *use* any MCP server is only half the value if finding one means already
/// knowing its name. This is the other half.
@MainActor
@Observable
final class MCPStoreModel {
    var query = ""
    var servers: [RegistryServer] = []
    var cursor: String?
    var loading = false
    var error: String?
    var selected: RegistryServer?

    /// Hide what this screen cannot add. On by default: roughly 60% of the registry is
    /// published as remote endpoints only, and the Add path here needs a launchable package, so
    /// the default view was mostly things that dead-end.
    ///
    /// A toggle rather than a permanent filter, and one that reports what it removed, because
    /// silently dropping half a catalogue is how a registry starts looking broken.
    var usableOnly = true

    /// Servers to show, and how many the filter is holding back.
    var visible: [RegistryServer] {
        usableOnly ? servers.filter { $0.launchability.canLaunch && !$0.isDeprecated } : servers
    }

    var hiddenCount: Int { servers.count - visible.count }

    /// Values the user typed for a selected server's environment variables. Held only until
    /// save, then written to the keychain and dropped.
    var environmentValues: [String: String] = [:]
    var chosenDomain: Domain = .personal
    var localName = ""

    private let registry = MCPRegistry()

    func load(reset: Bool = true) async {
        if reset { servers = []; cursor = nil }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await registry.servers(search: query.isEmpty ? nil : query, cursor: reset ? nil : cursor)
            servers += page.servers
            cursor = page.nextCursor
        } catch {
            self.error = "\(error)"
        }
    }

    func select(_ server: RegistryServer) {
        selected = server
        // Registry names are reverse-DNS ("io.github.owner/thing"); the last path component is
        // what a person would call it.
        localName = server.name.split(separator: "/").last.map(String.init) ?? server.name
        environmentValues = [:]
        for variable in server.package?.environment ?? [] {
            environmentValues[variable.name] = variable.defaultValue ?? ""
        }
    }
}

struct MCPStoreView: View {
    @Environment(AppModel.self) private var model
    @State private var store = MCPStoreModel()

    var body: some View {
        @Bindable var store = store
        HSplitView {
            catalogue
                .frame(minWidth: 300, idealWidth: 360)
            detail
                .frame(minWidth: 340)
        }
        .navigationTitle("MCP Store")
        .searchable(text: $store.query, prompt: "Search 9,000+ servers")
        .onSubmit(of: .search) { Task { await store.load() } }
        .task { if store.servers.isEmpty { await store.load() } }
    }

    private var catalogue: some View {
        List(selection: Binding(get: { store.selected?.id }, set: { id in
            if let match = store.servers.first(where: { $0.id == id }) { store.select(match) }
        })) {
            if let error = store.error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }

            // `SwiftUI.Section` spelled out: the app's own top-level `enum Section` shadows it
            // module-wide, and the error it produces names `CodingKeyRepresentable` rather than
            // anything to do with lists.
            SwiftUI.Section {
                ForEach(store.visible) { server in
                    MCPStoreRow(server: server).tag(server.id)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Only what OpenCore can add", isOn: $store.usableOnly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    // Says what it removed rather than just removing it. The count is the whole
                    // point: "hiding 31" is information, a shorter list on its own is not.
                    if store.hiddenCount > 0 {
                        Text("hiding \(store.hiddenCount) remote-only or deprecated")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    // The registry sorts by name and offers no ranking parameter, so this
                    // ordering is within what has been loaded. Saying so keeps the top row from
                    // reading as "the best server in the catalogue".
                    Text("verified publishers and launchable servers first, within loaded results")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .textCase(nil)
                .padding(.vertical, 2)
            }
            if store.cursor != nil {
                Button("Load more") { Task { await store.load(reset: false) } }
                    .disabled(store.loading)
            }
            if store.loading { HStack { ProgressView().controlSize(.small); Text("loading").font(.caption) } }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let server = store.selected {
            MCPStoreDetail(server: server, store: store)
        } else {
            EmptyState(message: "Pick a server.\n\nNothing is installed and nothing is called until you choose its tools.")
        }
    }
}

private struct MCPStoreRow: View {
    let server: RegistryServer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(server.title).font(.callout.weight(.medium)).lineLimit(1)

                // What the registry actually checked before publishing this name. Not a quality
                // score, and the help text says so: a domain-verified server can still be bad,
                // it just cannot be anonymous.
                Label(server.trust.label, systemImage: server.trust.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(server.trust == .domain ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12), in: .capsule)
                    .foregroundStyle(server.trust == .domain ? Color.green : Color.secondary)
                    .help(server.trust == .domain
                        ? "The publisher proved control of this DNS domain. It says who they are, not whether the server is good."
                        : "The publisher proved control of this GitHub account. A real check, and a cheap one: anyone can create an account.")

                if server.isDeprecated {
                    Text("deprecated")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: .capsule)
                        .foregroundStyle(.orange)
                }
                if !server.launchability.canLaunch {
                    Text("remote")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .help("Published as an endpoint rather than a package. OpenCore can reach hosted servers, but adding one is a CLI step today, not this screen.")
                }
            }
            Text(server.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(server.name).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                if !server.requiredEnvironment.isEmpty {
                    Text("\(server.requiredEnvironment.count) credential\(server.requiredEnvironment.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MCPStoreDetail: View {
    let server: RegistryServer
    @Bindable var store: MCPStoreModel
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var outcome: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.title).font(.title3.weight(.semibold))
                    Text(server.name).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    Text(server.description).font(.callout).foregroundStyle(.secondary)
                    if let repo = server.repositoryURL, let url = URL(string: repo) {
                        Link(repo, destination: url).font(.caption)
                    }
                }

                if let reason = server.launchability.reason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
                } else {
                    launchSection
                    credentialsSection
                    addSection
                }

                if let outcome {
                    Text(outcome).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launches as").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(([server.command ?? ""] + server.arguments).joined(separator: " "))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            Text("Reconstructed from the registry's package metadata. OpenCore installs nothing; the package is fetched at launch the same way any other client would.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        let variables = server.package?.environment ?? []
        if !variables.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Credentials").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(variables) { variable in
                    MCPCredentialField(variable: variable, value: Binding(
                        get: { store.environmentValues[variable.name] ?? "" },
                        set: { store.environmentValues[variable.name] = $0 }
                    ))
                }
                Text("Secrets go to your keychain, keyed to this server. The OpenCore database stores only the variable names.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                TextField("local name", text: $store.localName).textFieldStyle(.roundedBorder).frame(width: 160)
                Picker("Domain", selection: $store.chosenDomain) {
                    ForEach(Domain.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Button("Add source") { Task { await add() } }
                    .disabled(adding || store.localName.isEmpty)
                if adding { ProgressView().controlSize(.small) }
            }
            Text("Adding records the server. It calls nothing yet: next you run Discover on the MCP tab and tick the tools you allow.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func add() async {
        adding = true
        defer { adding = false }
        outcome = await model.addRegistryServer(server, name: store.localName, domain: store.chosenDomain, environment: store.environmentValues)
    }
}

private struct MCPCredentialField: View {
    let variable: RegistryServer.EnvironmentVariable
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(variable.name).font(.caption.monospaced())
                if variable.isRequired {
                    Text("required").font(.caption2).foregroundStyle(.orange)
                }
                if variable.isSecret {
                    Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Masked when the registry marks it secret, so a shoulder-surfer does not read an
            // API key off the screen while you paste it.
            if variable.isSecret {
                SecureField(variable.description.isEmpty ? variable.name : variable.description, text: $value)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(variable.description.isEmpty ? variable.name : variable.description, text: $value)
                    .textFieldStyle(.roundedBorder)
            }
            if !variable.description.isEmpty {
                Text(variable.description).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
