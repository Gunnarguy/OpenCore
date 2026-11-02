import CoreCompanion
import Foundation
import Observation

@MainActor
@Observable
final class PhoneModel {
    enum State: Equatable { case unpaired, locked, connecting, connected, offline }
    var state: State = .unpaired
    var failure: String?
    var busy = false
    var obscured = false
    var sessionID = UUID()
    var lastReachable: Date?
    var invitationText = ""
    var deviceName = "My iPhone"
    var streamedDraft: CompanionPage?
    private var recovery = CompanionRecoveryState()
    var resumableRead: (id: UUID, section: CompanionSection)? {
        get { recovery.pending }
        set { recovery.pending = newValue }
    }
    var recoveredPage: CompanionPage? { recovery.page }
    private let client = CompanionClient()
    private var invitation: CompanionInvitation?
    private var identity: CompanionPhoneIdentity?
    private var expiry: Task<Void, Never>?
    private var operation = UUID()
    private var activeRead: (id: UUID, section: CompanionSection)?
    var isConnected: Bool { state == .connected }

    init() {
        lastReachable = UserDefaults.standard.object(forKey: "companion.lastReachable") as? Date
        #if targetEnvironment(simulator)
        failure = "Pairing requires Face ID and a Secure Enclave on a physical iPhone. You can explore the screens here in Simulator."
        #else
        do {
            if let data = try CompanionKeychain.read("phone.paired-host") {
                invitation = try JSONDecoder().decode(CompanionInvitation.self, from: data)
                state = .locked
            }
        } catch { failure = "OpenCore could not access secure pairing storage. Unlock your iPhone and reopen the app, or pair again on your Mac." }
        #endif
    }
    func pair() async {
        do {
            let value = try CompanionInvitation.decode(invitationText)
            guard value.expiresAt > Date() else { throw CompanionError.expired }
            await connect(to: value, isNewPairing: true)
        } catch { failure = error.localizedDescription }
    }
    func connect() async {
        guard let invitation else { return }
        await connect(to: invitation, isNewPairing: false)
    }
    private func connect(to invitation: CompanionInvitation, isNewPairing: Bool) async {
        guard !busy else { return }
        recovery.beginConnection(isNewPairing: isNewPairing)
        streamedDraft = nil
        let token = UUID(); operation = token
        busy = true; state = .connecting
        defer { if operation == token { busy = false } }
        do {
            let identity = try await CompanionPhoneIdentity.unlock()
            guard operation == token, !Task.isCancelled else { identity.invalidate(); return }
            self.identity = identity
            try await client.connect(invitation: invitation, deviceID: identity.id, deviceName: String(deviceName.prefix(80)), publicKey: identity.publicKey) { data in
                try await identity.sign(data)
            }
            guard operation == token, !Task.isCancelled else { await client.disconnect(); return }
            var saved = invitation; saved.code = "" // A used pairing code is never retained as a credential.
            try CompanionKeychain.write(try JSONEncoder().encode(saved), account: "phone.paired-host")
            self.invitation = saved; invitationText = ""
            sessionID = UUID(); state = .connected; failure = nil
            markReachable()
            expiry?.cancel()
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)); await self?.lock() } catch { }
            }
        } catch {
            guard operation == token else { return }
            identity?.invalidate(); identity = nil; state = self.invitation == nil ? .unpaired : .offline
            failure = error is CancellationError ? nil : error.localizedDescription
            await client.disconnect()
        }
    }
    func lock() async {
        if let activeRead { resumableRead = activeRead }
        activeRead = nil
        operation = UUID(); expiry?.cancel(); expiry = nil
        identity?.invalidate(); identity = nil
        streamedDraft = nil; recovery.endSession(); invitationText = ""
        state = invitation == nil ? .unpaired : .locked
        busy = false; sessionID = UUID()
        await client.disconnect()
    }
    func forgetPairing() async {
        await lock()
        do {
            try CompanionKeychain.delete("phone.paired-host")
            invitation = nil; resumableRead = nil; state = .unpaired
            try CompanionPhoneIdentity.forgetIdentity()
        }
        catch { failure = error.localizedDescription }
    }
    func read(_ request: CompanionRequest) async throws -> CompanionPage {
        guard state == .connected else { throw CompanionError.disconnected }
        guard !busy else { throw CompanionError.busy }
        busy = true; let token = operation
        streamedDraft = nil
        activeRead = (request.resumeID ?? request.id, request.section)
        defer { if token == operation { busy = false; streamedDraft = nil; activeRead = nil } }
        do {
            let result = try await client.request(request) { [weak self] page in await self?.receiveProgress(page, token: token) }
            guard token == operation, state == .connected, !Task.isCancelled else { throw CancellationError() }
            resumableRead = nil; markReachable(); return result
        } catch {
            if token == operation {
                resumableRead = (request.resumeID ?? request.id, request.section)
                recovery.endSession()
                state = .offline; failure = error.localizedDescription
                identity?.invalidate(); identity = nil; sessionID = UUID()
            }
            throw error
        }
    }
    func resumeInterruptedRead() async {
        guard let pending = resumableRead else { return }
        let token = operation, session = sessionID, epoch = recovery.epoch
        do {
            let page = try await read(CompanionRequest(section: pending.section, resumeID: pending.id))
            guard token == operation, session == sessionID, state == .connected, !Task.isCancelled else { return }
            recovery.publish(page, ifCurrent: epoch)
        } catch {
            guard token == operation, session == sessionID, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
    private func receiveProgress(_ page: CompanionPage, token: UUID) {
        guard token == operation, state == .connected else { return }
        streamedDraft = page
    }
    private func markReachable() {
        lastReachable = Date(); UserDefaults.standard.set(lastReachable, forKey: "companion.lastReachable")
    }
}
