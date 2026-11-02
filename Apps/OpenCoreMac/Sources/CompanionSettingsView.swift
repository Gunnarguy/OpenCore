import CoreCompanion
import CoreCompanionHost
import CoreModel
import CorePresentation
import CoreStore
import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionHostController {
    var addresses: [String] = []
    var selectedAddress = ""
    var status = "Companion connection is off"
    var invitation: String?
    var invitationExpires: Date?
    var devices: [CompanionDevice] = []
    var enabled = false
    var ready = false
    var busy = false
    var issuingInvitation = false
    var projectOnly = false
    var failure: String?
    var invitationScope = ""
    private var server: CompanionServer?
    private var authority: CompanionAuthority?
    private var hostPublicKey: Data?
    private var generation = UUID()
    private var deviceRefresh = UUID()
    private var resuming: Task<Void, Never>?
    private var opened: (store: Store, settings: AppSettings)?
    private static let keepOnKey = "companion.keepOn"
    /// How often a kept-on connection looks for Tailscale coming back. **Chosen, not measured:**
    /// short enough that a phone connects soon after, long enough to cost nothing while it is off.
    private static let resumeInterval: Duration = .seconds(30)

    /// A paired phone has to reach the Mac without someone opening Settings first. Runs only once the
    /// owner has turned the connection on, and stops when they turn it off. The listener still binds
    /// only a tailnet address, and every peer still has to prove a paired device key.
    func resume(store: Store, settings: AppSettings) {
        guard resuming == nil, UserDefaults.standard.bool(forKey: Self.keepOnKey) else { return }
        resuming = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.enabled, !self.busy {
                    self.refreshAddresses()
                    if !self.selectedAddress.isEmpty { await self.start(store: store, settings: settings) }
                }
                try? await Task.sleep(for: Self.resumeInterval)
            }
        }
    }

    func refreshAddresses() {
        addresses = Self.tailnetAddresses()
        if !addresses.contains(selectedAddress) { selectedAddress = addresses.first ?? "" }
    }
    func start(store: Store, settings: AppSettings) async {
        guard !busy, !enabled else { return }
        busy = true; defer { busy = false }
        let token = UUID(); generation = token
        failure = nil
        opened = (store, settings)
        do {
            // Require the selected literal address to be assigned to a currently up tunnel.
            guard Self.tailnetAddresses().contains(selectedAddress) else { throw CompanionError.disconnected }
            let key: P256.KeyAgreement.PrivateKey
            if let data = try CompanionKeychain.read("host.agreement-key") { key = try P256.KeyAgreement.PrivateKey(rawRepresentation: data) }
            else { key = P256.KeyAgreement.PrivateKey(); try CompanionKeychain.write(key.rawRepresentation, account: "host.agreement-key") }
            let saved = try CompanionKeychain.read("host.devices")
            let paired = try saved.map { try JSONDecoder().decode([CompanionDevice].self, from: $0) } ?? []
            let authority = CompanionAuthority(devices: paired) { [weak self] devices in
                try CompanionKeychain.write(try JSONEncoder().encode(devices), account: "host.devices")
                // The authority finishes its actor turn before this refresh can read it.
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    await self.refreshDevices()
                }
            }
            let broker = CompanionBroker(store: store, tuning: settings.tuning,
                generation: .init(reasoningLevel: settings.fmReasoningLevelRaw, includeSchemaInPrompt: settings.fmIncludeSchemaInPrompt),
                onAuditFailure: { message in await AppModel.shared.recordAuditFailure(message) },
                onDeliveryFailure: { message in await AppModel.shared.recordAuditFailure(message) })
            let server = CompanionServer(authority: authority, hostKey: key) { request, device, progress in
                try await broker.prepare(request, device: device, progress: progress)
            }
            self.authority = authority; self.server = server; hostPublicKey = key.publicKey.x963Representation
            status = "Starting companion connection…"
            enabled = true; ready = false
            try await server.start(host: selectedAddress) { [weak self] message in
                await self?.setStatus(message, generation: token)
            }
            await refreshDevices()
        } catch { failure = error.localizedDescription; status = "Companion connection could not start"; enabled = false }
    }
    private func setStatus(_ message: CompanionServer.Status, generation: UUID) {
        guard generation == self.generation else { return }
        status = message.rawValue
        ready = message == .ready
        if message == .ready {
            failure = nil
            UserDefaults.standard.set(true, forKey: Self.keepOnKey)
            if let opened { resume(store: opened.store, settings: opened.settings) }
        }
        if message == .failed || message == .stopped { enabled = false }
    }
    func stop() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        generation = UUID()
        // Only this path, which a person pressed. A tunnel going away stops the listener and keeps this.
        UserDefaults.standard.set(false, forKey: Self.keepOnKey)
        resuming?.cancel(); resuming = nil
        await server?.stop(); server = nil; authority = nil; enabled = false
        invitation = nil; invitationExpires = nil; ready = false; status = "Companion connection is off"
    }
    func issueInvitation() async {
        guard ready, !issuingInvitation, let authority, let hostPublicKey else { return }
        issuingInvitation = true; defer { issuingInvitation = false }
        let token = generation, address = selectedAddress, limited = projectOnly
        let domains = limited ? Set([Domain.project.rawValue, Domain.publicRecord.rawValue]) : Set(Domain.allCases.map(\.rawValue))
        invitation = nil; invitationExpires = nil; invitationScope = ""
        let (code, expiry) = await authority.issue(domains: domains)
        guard generation == token, ready else { await authority.cancelInvitation(); return }
        do {
            invitation = try CompanionInvitation(host: address, port: 47821, hostPublicKey: hostPublicKey, code: code, expiresAt: expiry).encoded()
            invitationExpires = expiry
            invitationScope = limited ? "Project and public only" : "All Mac owner browsing domains"
        } catch { await authority.cancelInvitation(); failure = error.localizedDescription }
    }
    func refreshDevices() async {
        guard let authority else { return }
        let token = UUID(), generation = generation
        deviceRefresh = token
        let latest = await authority.pairedDevices()
        guard self.generation == generation, deviceRefresh == token else { return }
        devices = latest
    }
    func revoke(_ id: UUID) async {
        guard enabled, let server else { failure = "Enable the companion connection before revoking a device."; return }
        do { try await server.revoke(id); await refreshDevices() } catch { failure = error.localizedDescription }
    }
    private static func tailnetAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var values = Set<String>(), cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name).hasPrefix("utun"),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if CompanionEndpoint.isTailnetAddress(text) { values.insert(text) }
        }
        return values.sorted()
    }
}

struct CompanionSettingsView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    private var controller: CompanionHostController { model.companionHost }
    @State private var confirmingPair = false

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 18) {
            Label("OpenCore on iPhone", systemImage: "iphone.and.arrow.forward").font(.title2.bold())
            Text("Your Mac holds the store and generates answers. The companion reads over your tailnet after in-person pairing and Face ID. MCP permissions stay separate.")
                .foregroundStyle(.secondary)
            Label(controller.status, systemImage: controller.enabled ? "network" : "network.slash")
            if let failure = controller.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if controller.addresses.isEmpty {
                Text("Connect this Mac to Tailscale, then refresh. A LAN or wildcard address cannot be used.")
            } else {
                Picker("Tailscale interface", selection: $controller.selectedAddress) {
                    ForEach(controller.addresses, id: \.self) { Text($0).tag($0) }
                }.disabled(controller.enabled)
            }
            HStack {
                Button("Refresh interfaces") { controller.refreshAddresses() }.disabled(controller.enabled)
                Button(controller.enabled ? "Turn off companion connection" : "Enable companion connection") {
                    Task {
                        if controller.enabled { await controller.stop() }
                        else if let store = model.store { await controller.start(store: store, settings: settings) }
                    }
                }.disabled(controller.busy || (!controller.enabled && (model.store == nil || controller.selectedAddress.isEmpty)))
            }
            Divider()
            Toggle("Limit newly paired devices to project and public data", isOn: $controller.projectOnly)
            Text(controller.projectOnly ? "The device cannot read other domains." : "Newly paired devices receive the Mac owner's full browsing access, including sensitive and mixed memory. Query admission still applies to answers.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Pair an iPhone…") { confirmingPair = true }.disabled(!controller.ready || controller.issuingInvitation)
                .confirmationDialog("Authorize a phone to read your OpenCore history?", isPresented: $confirmingPair, titleVisibility: .visible) {
                    Button("Generate in-person pairing code") { Task { await controller.issueInvitation() } }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("Only give this one-use code to your own phone. It expires in two minutes. Revoking a phone immediately closes its active connection.") }
            if let invitation = controller.invitation {
                Text("Paste this code into OpenCore on your iPhone.").font(.headline)
                Text("Access in this code: \(controller.invitationScope). Changing the limit above affects future codes.").font(.caption)
                HStack {
                    Button("Copy pairing code", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invitation, forType: .string)
                    }
                    ShareLink("Share pairing code", item: invitation)
                }
                Text(invitation).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                if let expires = controller.invitationExpires { Text("Expires \(expires.formatted(date: .omitted, time: .shortened))").font(.caption) }
            }
            HStack {
                Text("Paired devices").font(.headline)
                Spacer()
                Button("Refresh devices") { Task { await controller.refreshDevices() } }
            }
            if controller.devices.isEmpty { Text("No paired devices loaded.").foregroundStyle(.secondary) }
            ForEach(controller.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text("Paired \(device.pairedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                        Text("Access: \(device.domains.isEmpty ? "none" : device.domains.sorted().joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { Task { await controller.revoke(device.id) } }
                        .disabled(!controller.enabled || controller.busy)
                }
            }
            if !controller.enabled && !controller.devices.isEmpty {
                Text("Enable the companion connection to revoke a device.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Once on, the connection stays on across launches and reconnects when Tailscale comes back, until you turn it off here. Keep OpenCore running for phone access. This release has read-only phone commands; store actions and computer control are later phases.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).openCoreGlassCard(cornerRadius: 18, tint: Pastel.aqua)
        .task { controller.refreshAddresses() }
    }
}
