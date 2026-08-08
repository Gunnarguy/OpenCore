import CoreIngest
import CoreModel
import SwiftUI

/// Credentials and app-level configuration.
///
/// The whole screen is built around one idea: **show which source is actually in effect.**
/// A token can come from four places with a precedence order, and without surfacing the winner
/// "why is it still using the old token" is unanswerable. Saved and working are also different
/// facts, so saving verifies against the API and reports the account name rather than a
/// reassuring checkmark.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var tokenField = ""
    @State private var status: TokenStatus = .unknown
    @State private var source: CredentialSource = .none
    @State private var checking = false

    enum TokenStatus: Equatable {
        case unknown
        case absent
        case present(login: String)
        case invalid(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                gitHubPanel
                storePanel
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
        .task { await refreshToken() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(.title2.weight(.semibold))
            Text("Credentials live in your keychain, never in the OpenCore database.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - GitHub

    private var gitHubPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.callout.weight(.medium))
                Spacer()
                if checking { ProgressView().controlSize(.small) }
            }

            TokenStatusLine(status: status, source: source)

            HStack(spacing: 8) {
                SecureField("ghp_… or github_pat_…", text: $tokenField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
                Button("Save") { Task { await save() } }
                    .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if case .present = status {
                    Button("Clear", role: .destructive) { Task { await clear() } }
                        .disabled(checking)
                }
            }

            Text("""
            A classic token needs the `repo` scope for private repositories, or `public_repo` \
            for public ones only. A fine-grained token needs read access to Contents and Metadata. \
            Saving verifies it against the API before reporting success.
            """)
            .font(.caption)
            .foregroundStyle(.tertiary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Where a token is looked for, in order")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(SettingsView.precedence.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Text(entry.0).font(.caption.monospaced())
                        Text(entry.1).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text("""
                The environment wins over the keychain on purpose, so a one-off \
                GITHUB_TOKEN=… run overrides a saved token without changing it.
                """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    static let precedence: [(String, String)] = [
        ("--token", "passed to the CLI"),
        ("GITHUB_TOKEN", "environment variable"),
        ("keychain", "what this screen saves; the only one the app can use on its own"),
        ("gh auth token", "the GitHub CLI, if it is installed and signed in"),
    ]

    // MARK: - Store

    private var storePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Store", systemImage: "internaldrive").font(.callout.weight(.medium))
            if let path = model.storePath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("not opened").font(.caption).foregroundStyle(.tertiary).italic()
            }
            Text("""
            One SQLite file, shared with the opencore CLI. It holds your objects, claims and \
            receipts. It holds no credentials, and it is not encrypted, so treat it as you \
            would the documents it was built from.
            """)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    // MARK: - Actions

    private func refreshToken() async {
        checking = true
        defer { checking = false }

        let resolved = GitHubConnector.resolveTokenWithSource()
        source = resolved.source
        guard let token = resolved.token else {
            status = .absent
            return
        }
        // Resolved is not the same as valid. A revoked token resolves perfectly.
        if let login = await GitHubConnector.verify(token: token) {
            status = .present(login: login)
        } else {
            status = .invalid("the token found via \(resolved.source.rawValue) was rejected by GitHub")
        }
    }

    private func save() async {
        checking = true
        defer { checking = false }

        let candidate = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }

        // Verify before storing. Saving a bad token and discovering it at the next sync wastes
        // the user's time and makes the failure look like a connector bug.
        guard let login = await GitHubConnector.verify(token: candidate) else {
            status = .invalid("GitHub rejected that token. Check its scopes and that it has not expired.")
            return
        }

        do {
            try Keychain.write(candidate, to: .githubToken)
            tokenField = ""
            status = .present(login: login)
            source = GitHubConnector.resolveTokenWithSource().source
        } catch {
            status = .invalid("\(error)")
        }
    }

    private func clear() async {
        do {
            try Keychain.delete(.githubToken)
            tokenField = ""
            await refreshToken()
        } catch {
            status = .invalid("\(error)")
        }
    }
}

/// Split out because the status line mixes several ternaries over different types, which is
/// the shape that reliably exhausts the SwiftUI type checker.
private struct TokenStatusLine: View {
    let status: SettingsView.TokenStatus
    let source: CredentialSource

    private var symbol: String {
        switch status {
        case .unknown: "hourglass"
        case .absent: "exclamationmark.triangle"
        case .present: "checkmark.circle"
        case .invalid: "xmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .unknown: .secondary
        case .absent: .orange
        case .present: .green
        case .invalid: .red
        }
    }

    private var message: String {
        switch status {
        case .unknown: "checking"
        case .absent: "No token found. GitHub sync will not work until you add one."
        case .present(let login): "Authenticated as \(login), via \(source.rawValue)."
        case .invalid(let reason): reason
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
