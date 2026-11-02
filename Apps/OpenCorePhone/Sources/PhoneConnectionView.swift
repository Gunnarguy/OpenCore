import CoreCompanion
import SwiftUI

struct PhoneConnectionView: View {
    @Environment(PhoneModel.self) private var model
    @State private var forgetting = false
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 16) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 16)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your Mac. With you.").font(.title3.bold())
                        Text("OpenCore companion").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                ConnectionStatusView()
            }
            if let failure = model.failure {
                Section("Connection message") {
                    Text(failure).textSelection(.enabled)
                    Button("Dismiss message") { model.failure = nil }
                }
            }
            if model.state == .connected {
                Section {
                    Button("Lock companion", systemImage: "lock") { Task { await model.lock() } }
                    Text("A session lasts up to five minutes and locks when this app goes into the background. Answers and evidence stay in memory for that session.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.resumableRead != nil {
                    Section("Interrupted read") {
                        Text("A completed response may be recoverable from the Mac for five minutes. Resumed results keep their original generation time.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Try to resume last read") { Task { await model.resumeInterruptedRead() } }.disabled(model.busy)
                        Button("Dismiss interrupted read") { model.resumableRead = nil }
                    }
                }
                if let page = model.recoveredPage {
                    Section("Recovered response") {
                        Text(page.note).font(.footnote)
                        ForEach(CompanionRecord.appendingDistinct(page.records, to: []), id: \.identityBytes) { record in NavigationLink { PhoneRecordDetail(record: record) } label: { PhoneRecordRow(record: record) } }
                    }
                }
            } else if model.state != .unpaired {
                Section {
                    Button("Unlock with Face ID", systemImage: "faceid") { Task { await model.connect() } }
                        .disabled(model.busy)
                    Text("Keep your Mac awake with OpenCore and Tailscale running. A Mac that is asleep, a closed app, and an expired Tailscale sign-in can all prevent a connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Pair in person") {
                Text("On your Mac, open OpenCore → Settings → iPhone Companion. Enable the connection, generate a code, then paste it here within two minutes.")
                    .font(.callout)
                TextField("Name shown on the Mac", text: $model.deviceName).textContentType(.nickname)
                TextField("Pairing code", text: $model.invitationText, axis: .vertical)
                    .lineLimit(3...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive()
                PasteButton(payloadType: String.self) { values in model.invitationText = values.first ?? "" }
                Button("Pair and unlock", systemImage: "link") { Task { await model.pair() } }
                    .disabled(model.busy || model.invitationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Privacy") {
                Label("A device key in the Secure Enclave", systemImage: "key")
                Label("Encrypted connection to your paired Mac", systemImage: "lock.shield")
                Label("No second store on this phone", systemImage: "externaldrive.badge.checkmark")
                Text("The first release reads your history. Sync, corrections and operator controls are later phases. MCP remains a separate read-only channel for models.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.state != .unpaired {
                    Button("Forget this Mac", role: .destructive) { forgetting = true }
                }
            }
        }
        .navigationTitle("Connection")
        .confirmationDialog("Forget the paired Mac?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget pairing", role: .destructive) { Task { await model.forgetPairing() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the pairing and device key, including a key invalidated by Face ID changes. Pair again in person. Revoke the old phone entry on the Mac too.") }
    }
}

struct ConnectionStatusView: View {
    @Environment(PhoneModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .connected: Label("Connected to your Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .connecting: HStack { ProgressView(); Text("Unlocking and connecting…") }
            case .unpaired: Label("Pair with your Mac to begin", systemImage: "link")
            case .locked: Label("Session locked", systemImage: "lock.fill")
            case .offline: Label("Mac unreachable", systemImage: "network.slash").foregroundStyle(.orange)
            }
            if let date = model.lastReachable {
                Text("Last reached \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
