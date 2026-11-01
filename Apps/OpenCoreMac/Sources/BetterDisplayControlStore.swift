import AppKit
import Combine
import CoreTelemetry

struct BetterDisplaySnapshot {
    let identity: BetterDisplayIdentity
    let version: String
    let features: [BetterDisplayFeature]
    var reports: [String: String]
    var errors: [String: String]
    var ddc: [BetterDisplayDDCFeature]
    var connectionModes: [BetterDisplayListedOption]
    var desktopModes: [BetterDisplayListedOption]
    var captured: Date

    func section(_ name: String) -> [(String, String)] {
        let lines = (reports["displayInformation"] ?? "").components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: name) else { return [] }
        return lines.dropFirst(start + 2).prefix(while: { !$0.isEmpty }).compactMap { line in
            guard let split = line.range(of: ": ") else { return nil }
            return (String(line[..<split.lowerBound]), String(line[split.upperBound...]))
        }
    }
}

@MainActor
final class BetterDisplayControlStore: ObservableObject {
    @Published private(set) var snapshot: BetterDisplaySnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var status: String?
    @Published private(set) var progress = ""
    @Published private(set) var featureValue: String?
    @Published private(set) var valueFeatureID: String?
    @Published private(set) var featureFeedback: String?
    @Published private(set) var featureFeedbackID: String?
    @Published private(set) var featureReadError: String?
    @Published private(set) var signalFeedback: String?
    @Published private(set) var failedFeatureReads: Set<String> = []
    private var featureEvidenceIdentity: BetterDisplayIdentity?
    private var watchedFeature: BetterDisplayFeature?
    @Published private(set) var error: String?
    @Published private(set) var readingsStale = true
    @Published private(set) var ddcFeedback: [Int: DisplayControlFeedback] = [:]
    @Published private(set) var applyingDDC: Int?
    @Published private(set) var lastLiveUpdate: Date?
    @Published private(set) var liveReadError: String?
    @Published var autoRefresh = true
    @Published private(set) var liveQueue = DisplayControlUpdateQueue()
    private var liveTask: Task<Void, Never>?
    private var liveTaskID = UUID()
    private var visible = false
    private var mutationRevision = UUID()
    var hasLiveWork: Bool { liveTask != nil || !liveQueue.isEmpty }
    private let client = BetterDisplayClient.shared
    private var loadID = UUID()
    private var featureReadID = UUID()
    private var nextDiscoveryAttempt = Date.distantPast
    private var lastDiscoveryFailed = false
    private let reports = ["displayInformation", "ddcCapabilities", "ddcCapabilitiesString", "displayModeList", "connectionModeList", "connectionModeListAll", "inputSourceList", "configuredControllerList", "EDIDReport", "refreshRateList"]

    func load(_ display: ConnectedDisplay) async {
        guard !isApplying, !hasLiveWork else { return }
        let token = UUID()
        loadID = token
        featureReadID = UUID() // A previous connection's read must not repopulate new evidence.
        // Chosen backoff: unavailable controls retry discovery without flooding full reports.
        nextDiscoveryAttempt = Date().addingTimeInterval(30)
        error = nil
        featureValue = nil
        isLoading = true
        readingsStale = true
        defer { if loadID == token { isLoading = false } }
        do {
            guard Bundle(url: URL(fileURLWithPath: "/Applications/BetterDisplay.app"))?.bundleIdentifier == "pro.betterdisplay.BetterDisplay" else {
                throw failure("BetterDisplay is not installed at its verified application location.")
            }
            progress = "Checking installed BetterDisplay commands…"
            let help = try await client.request(["help"], parameters: [:])
            let identity = try await identify(display)
            var captured = BetterDisplaySnapshot(identity: identity, version: String(help.components(separatedBy: .newlines).first ?? "BetterDisplay"), features: BetterDisplayFeature.catalog(help), reports: [:], errors: [:], ddc: [], connectionModes: [], desktopModes: [], captured: Date())
            for report in reports where help.contains("`\(report)`") {
                try Task.checkCancellation()
                progress = "Reading \(report)…"
                do { captured.reports[report] = try await client.get(report, uuid: identity.uuid) }
                catch is CancellationError { throw CancellationError() }
                catch { captured.errors[report] = error.localizedDescription }
            }
            if let report = captured.reports["ddcCapabilities"] {
                do { captured.ddc = try BetterDisplayDDCFeature.parseReport(report) }
                catch { captured.errors["ddcCapabilities"] = error.localizedDescription }
            }
            if let report = captured.reports["connectionModeList"] {
                do { captured.connectionModes = try BetterDisplayListedOption.parseList(report) }
                catch { captured.errors["connectionModeList"] = error.localizedDescription }
            }
            if let report = captured.reports["displayModeList"] {
                do { captured.desktopModes = try BetterDisplayListedOption.parseList(report) }
                catch { captured.errors["displayModeList"] = error.localizedDescription }
            }
            let currentIdentity = try await identify(display)
            guard currentIdentity == identity else { throw failure("The monitor connection changed while reading its controls. Refresh to inspect the new connection.") }
            guard token == loadID else { return }
            if featureEvidenceIdentity != captured.identity {
                failedFeatureReads = []
                featureEvidenceIdentity = captured.identity
            }
            snapshot = captured
            lastDiscoveryFailed = false
            readingsStale = false
            updateReadHealth(captured.ddc, builtIn: display.builtIn)
            status = "Read \(captured.ddc.count) DDC features and \(captured.desktopModes.count) BetterDisplay modes. No settings changed."
        } catch is CancellationError { }
        catch { if token == loadID { self.error = error.localizedDescription; lastDiscoveryFailed = true } }
    }

    func readFeature(_ feature: BetterDisplayFeature, display: ConnectedDisplay, quiet: Bool = false) async {
        guard !isApplying, feature.requiresValue || feature.isReadOnly else { return }
        let token = UUID()
        let readingLoadID = loadID
        var sent = false
        featureReadID = token
        if !quiet { featureValue = nil; featureReadError = nil }
        valueFeatureID = feature.id
        do {
            let identity = try await identify(display)
            guard snapshot?.identity == identity else { throw failure("The inspected display identity changed. Refresh before using these controls.") }
            sent = true
            let value = try await client.get(feature.id, uuid: identity.uuid)
            guard featureReadID == token, loadID == readingLoadID, snapshot?.identity == identity else { return }
            failedFeatureReads.remove(feature.id)
            featureValue = value
            if !quiet { status = "Read \(feature.id) from \(display.title)." }
            featureReadError = nil
        } catch is CancellationError { }
        catch { if featureReadID == token, loadID == readingLoadID { if sent { failedFeatureReads.insert(feature.id) }; featureValue = nil; featureReadError = error.localizedDescription; if !quiet { status = error.localizedDescription } } }
    }

    func watchFeature(_ feature: BetterDisplayFeature?) { watchedFeature = feature; clearFeatureReading() }
    func clearFeatureReading() { featureReadID = UUID(); featureValue = nil; valueFeatureID = nil; featureFeedback = nil; featureFeedbackID = nil; featureReadError = nil }

    func queueLiveDDC(_ feature: BetterDisplayDDCFeature, value: Int, display: ConnectedDisplay) {
        guard MonitorControlGuide.liveCodes.contains(feature.id), !isLoading, !readingsStale,
              !isApplying || MonitorControlGuide.liveCodes.contains(applyingDDC ?? -1),
              !client.hasUncertainMutation, snapshot?.ddc.contains(where: { $0.id == feature.id }) == true,
              let maximum = feature.maximum, !feature.readFailed, feature.current != nil,
              value >= 0, value <= maximum else { return }
        liveQueue.enqueue(code: feature.id, value: value)
        ddcFeedback[feature.id] = .init(.queued, "Waiting to send \(value)…")
        guard liveTask == nil else { return }
        // This task owns only a bounded queue of picture edits. View disappearance discards
        // unsent values; an admitted hardware write finishes readback instead of being retracted.
        let taskID = UUID()
        liveTaskID = taskID
        liveTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.liveTaskID == taskID { self.liveTask = nil } }
            while !Task.isCancelled, !self.liveQueue.isEmpty {
                // Chosen coalescing interval prevents a packet for every slider event.
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, let update = self.liveQueue.takeNext(),
                      let current = self.snapshot?.ddc.first(where: { $0.id == update.code }) else { return }
                await self.writeDDC(current, value: update.value, display: display, liveUpdate: update)
                if self.readingsStale || self.client.hasUncertainMutation {
                    self.discardPendingLiveEdits(reason: "Not sent because the previous change needs a confirmed reading.")
                    return
                }
            }
        }
    }

    func stopLiveControls() {
        visible = false
        cancelUnsentPictureEdits()
    }

    func cancelUnsentPictureEdits() {
        discardPendingLiveEdits(reason: "Not sent because you left the picture controls.")
        if applyingDDC == nil { liveTask?.cancel(); liveTask = nil }
    }

    private func discardPendingLiveEdits(reason: String) {
        for feature in snapshot?.ddc ?? [] where liveQueue.contains(feature.id) {
            ddcFeedback[feature.id] = .init(.unavailable, reason)
        }
        liveQueue.removeAll()
    }

    func monitor(_ display: ConnectedDisplay) async {
        visible = true
        defer { stopLiveControls() }
        while !Task.isCancelled, visible {
            // Chosen polling interval. A direct write always gets its own immediate readback.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard autoRefresh, !isApplying, !isLoading, !hasLiveWork, !client.isMutating,
                  ConnectedDisplayModeController.shared.pendingDisplayID == nil else { continue }
            let emptyDiscovery = !display.builtIn && snapshot?.ddc.isEmpty == true
            if readingsStale || emptyDiscovery {
                if (!lastDiscoveryFailed && readingsStale) || Date() >= nextDiscoveryAttempt {
                    await load(display)
                }
            } else { await refreshLiveReadings(display) }
            if let watchedFeature, !isApplying, !hasLiveWork, !Task.isCancelled {
                await readFeature(watchedFeature, display: display, quiet: true)
            }
        }
    }

    func refreshLiveReadings(_ display: ConnectedDisplay) async {
        guard !isApplying, !isLoading, let original = snapshot else { return }
        let revision = mutationRevision
        let generation = loadID
        do {
            let identity = try await identify(display)
            guard identity == original.identity else { throw failure("The monitor identity changed. Refresh its complete controls.") }
            var updates: [Int: Int?] = [:]
            for feature in original.ddc where Self.writableDDC.contains(feature.id) {
                try Task.checkCancellation()
                guard revision == mutationRevision, !isApplying, !hasLiveWork else { return }
                let raw = try? await client.get("ddc", uuid: identity.uuid, extra: ["vcp": String(feature.id), "value": nil])
                updates.updateValue(feature.updatingCurrent(BetterDisplayDDCFeature.scalar(raw)).current, forKey: feature.id)
            }
            guard try await identify(display) == identity else { throw failure("The monitor connection changed during the live reading.") }
            guard revision == mutationRevision, generation == loadID, !isApplying, !isLoading,
                  !hasLiveWork, snapshot?.identity == identity else { return }
            for (code, value) in updates { updateDDC(code, value: value) }
            let health = DisplayControlReadHealth(values: Array(updates.values))
            if health.hasReadings { lastLiveUpdate = Date() }
            liveReadError = display.builtIn && health.attempted == 0 ? nil : health.message
            // Full signal/EDID reports can remain stale after a connection/configuration change.
            // A subset of successful picture reads cannot certify those reports as refreshed.
        } catch is CancellationError { }
        catch { if revision == mutationRevision { liveReadError = error.localizedDescription; readingsStale = true } }
    }

    private func updateDDC(_ code: Int, value: Int?) {
        guard var current = snapshot, let index = current.ddc.firstIndex(where: { $0.id == code }) else { return }
        current.ddc[index] = current.ddc[index].updatingCurrent(value, readFailed: value == nil)
        snapshot = current
    }

    func writeDDC(_ feature: BetterDisplayDDCFeature, value: Int, display: ConnectedDisplay, liveUpdate: DisplayControlUpdateQueue.Update? = nil) async {
        guard !isApplying, !isLoading else { return }
        guard Self.writableDDC.contains(feature.id), value >= 0, value <= 65535 else { return }
        guard feature.acceptedValues.isEmpty ? (!feature.readFailed && feature.current != nil && (feature.maximum ?? 0) > 0 && value <= (feature.maximum ?? 0)) : feature.acceptedValues.contains(value) else {
            ddcFeedback[feature.id] = .init(.unavailable, "This value is outside the monitor's reported range/choices.")
            return
        }
        applyingDDC = feature.id
        ddcFeedback[feature.id] = .init(.sending, "Sending \(value) to \(display.title)…")
        defer { applyingDDC = nil }
        let pictureOnly = MonitorControlGuide.liveCodes.contains(feature.id)
        let succeeded = await modify(display, pictureOnly: pictureOnly) { identity, lease in
            if pictureOnly {
                let rawMax = try await self.client.get("ddc", uuid: identity.uuid, extra: ["vcp": String(feature.id), "max": nil])
                guard let maximum = BetterDisplayDDCFeature.scalar(rawMax), maximum > 0, value <= maximum else {
                    throw self.failure("The monitor's current hardware range no longer admits this value.")
                }
            } else {
                let report = try await self.client.get("ddcCapabilities", uuid: identity.uuid)
                guard let fresh = try BetterDisplayDDCFeature.parseReport(report).first(where: { $0.id == feature.id }),
                      fresh.acceptedValues.isEmpty ? (!fresh.readFailed && fresh.current != nil && (fresh.maximum ?? 0) > 0 && value <= (fresh.maximum ?? 0)) : fresh.acceptedValues.contains(value) else {
                    throw self.failure("This value is no longer advertised. Refresh the monitor controls.")
                }
            }
            if let liveUpdate, !self.liveQueue.isCurrent(liveUpdate) {
                throw self.failure("Not sent: you left this monitor before the hardware request began.")
            }
            try Task.checkCancellation()
            _ = try await self.client.request(["set"], parameters: ["UUID": identity.uuid, "ddc": nil, "vcp": String(feature.id), "value": String(value)], lease: lease)
            var actual: Int?
            for attempt in 0..<3 {
                // Chosen short settlement delays accommodate hardware applying a queued command.
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 120 : 250))
                let raw = try? await self.client.get("ddc", uuid: identity.uuid, extra: ["vcp": String(feature.id), "value": nil])
                actual = feature.updatingCurrent(BetterDisplayDDCFeature.scalar(raw)).current
                if DisplayControlFeedback.readback(code: feature.id, requested: value, actual: actual).state == .verified { break }
            }
            self.updateDDC(feature.id, value: actual)
            if actual != nil { self.lastLiveUpdate = Date() }
            self.publishDDCFeedback(feature.id, .readback(code: feature.id, requested: value, actual: actual))
            self.status = self.ddcFeedback[feature.id]?.message
            if actual == nil { self.readingsStale = true }
        }
        if !succeeded { publishDDCFeedback(feature.id, .init(.unavailable, status ?? "The change was not confirmed.")) }
    }

    private func publishDDCFeedback(_ code: Int, _ feedback: DisplayControlFeedback) {
        if let pending = liveQueue.value(for: code) {
            ddcFeedback[code] = .init(.queued, "\(feedback.message) Newest value \(pending) is queued next.")
        } else { ddcFeedback[code] = feedback }
    }

    func writeFeature(_ feature: BetterDisplayFeature, value: String, display: ConnectedDisplay) async {
        guard snapshot?.features.contains(feature) == true, feature.offeredAsWrite, value.utf8.count <= 512,
              !value.contains(where: { $0.isNewline || $0 == "\0" }),
              feature.requiresValue ? !value.trimmingCharacters(in: .whitespaces).isEmpty : true else { status = "Choose a supported feature and provide its required value."; return }
        clearFeatureReading()
        valueFeatureID = feature.id
        let succeeded = await modify(display) { identity, lease in
            var parameters: [String: String?] = ["UUID": identity.uuid]
            parameters.updateValue(feature.requiresValue ? value : nil, forKey: feature.id)
            _ = try await self.client.request([feature.requiresValue ? "set" : "perform"], parameters: parameters, lease: lease)
            if feature.requiresValue {
                do {
                    let actual = try await self.client.get(feature.id, uuid: identity.uuid)
                    self.featureValue = actual
                    self.valueFeatureID = feature.id
                    self.status = "BetterDisplay accepted \(feature.id). Readback: \(actual.trimmingCharacters(in: .whitespacesAndNewlines)). Compare with the requested value; this is not a physical measurement."
                } catch { self.status = "BetterDisplay accepted \(feature.id); readback is unavailable. Physical completion is unverified." }
            } else { self.status = "BetterDisplay accepted \(feature.id). This action has no verified readback." }
        }
        featureFeedbackID = feature.id
        featureFeedback = succeeded ? status : (status ?? "The change was not verified.")
    }

    func setConnectionMode(_ option: BetterDisplayListedOption, display: ConnectedDisplay) async {
        guard snapshot?.connectionModes.contains(option) == true, !option.isUnsafe else { status = "Choose a current compatible connection mode."; return }
        signalFeedback = "Sending the selected signal mode…"
        await modify(display) { identity, lease in
            let current = try BetterDisplayListedOption.parseList(await self.client.get("connectionModeList", uuid: identity.uuid))
            guard current.contains(option) else { throw self.failure("The compatible connection modes changed. Refresh and choose again.") }
            _ = try await self.client.request(["set"], parameters: ["UUID": identity.uuid, "connectionMode": option.id], lease: lease)
            let actual = try? await self.client.get("connectionMode", uuid: identity.uuid)
            self.status = "Connection mode request accepted. Returned mode: \(actual?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"). Read the current link report to verify the result."
        }
        signalFeedback = status
    }

    @discardableResult
    private func modify(_ display: ConnectedDisplay, pictureOnly: Bool = false, action: (BetterDisplayIdentity, UUID) async throws -> Void) async -> Bool {
        guard !isApplying, !isLoading else { status = "Wait for the current monitor operation."; return false }
        guard !readingsStale else { status = "Refresh the monitor's control readings before making another change."; return false }
        isApplying = true
        mutationRevision = UUID()
        defer { isApplying = false; ConnectedDisplayInventory.shared.refresh() }
        do {
            guard ConnectedDisplayModeController.shared.pendingDisplayID == nil, !ConnectedDisplayModeController.shared.isBusy else { throw failure("Keep or revert the native mode preview before changing another display setting.") }
            let lease = try client.reserveMutation()
            defer { client.releaseMutation(lease) }
            let identity = try await identify(display)
            guard snapshot?.identity == identity else { throw failure("The display identity changed. Refresh before changing anything.") }
            try Task.checkCancellation()
            if !pictureOnly { readingsStale = true }
            try await action(identity, lease)
            guard try await identify(display) == identity else { throw failure("The display identity changed during this request.") }
            if !pictureOnly { try await refreshReports(identity, display: display) }
            return true
        } catch {
            status = "Change not verified: \(error.localizedDescription)"
            if client.hasUncertainMutation { readingsStale = true }
            return false
        }
    }

    private func refreshReports(_ identity: BetterDisplayIdentity, display: ConnectedDisplay) async throws {
        guard var refreshed = snapshot, refreshed.identity == identity else { throw failure("No matching snapshot to refresh.") }
        for report in reports where refreshed.features.contains(where: { $0.id == report }) {
            do {
                refreshed.reports[report] = try await client.get(report, uuid: identity.uuid)
                refreshed.errors.removeValue(forKey: report)
            } catch is CancellationError { throw CancellationError() }
            catch { refreshed.reports.removeValue(forKey: report); refreshed.errors[report] = error.localizedDescription }
        }
        refreshed.ddc = try refreshed.reports["ddcCapabilities"].map(BetterDisplayDDCFeature.parseReport) ?? []
        refreshed.connectionModes = try refreshed.reports["connectionModeList"].map(BetterDisplayListedOption.parseList) ?? []
        refreshed.desktopModes = try refreshed.reports["displayModeList"].map(BetterDisplayListedOption.parseList) ?? []
        guard try await identify(display) == identity else { throw failure("The monitor connection changed while refreshing reports.") }
        refreshed.captured = Date()
        snapshot = refreshed
        updateReadHealth(refreshed.ddc, builtIn: display.builtIn)
        readingsStale = false
    }

    private func updateReadHealth(_ features: [BetterDisplayDDCFeature], builtIn: Bool) {
        let values = features.filter { Self.writableDDC.contains($0.id) }.map {
            $0.readFailed ? nil : $0.updatingCurrent($0.current).current
        }
        let health = DisplayControlReadHealth(values: values)
        lastLiveUpdate = health.hasReadings ? Date() : nil
        liveReadError = builtIn && health.attempted == 0 ? nil : health.message
    }

    private func identify(_ display: ConnectedDisplay) async throws -> BetterDisplayIdentity {
        let native = ConnectedDisplayInventory.shared
        native.refresh()
        guard let current = native.displays.first(where: { $0.id == display.id }), current.connectionIdentity == display.connectionIdentity else {
            throw failure("The display was removed or replaced. Select it again before changing settings.")
        }
        let identities = try BetterDisplayIdentity.decodeList(await client.get("identifiers"))
        guard let match = BetterDisplayIdentity.matching(displayID: display.id, vendorID: display.vendorID, productID: display.productID, serialNumber: display.serialNumber, in: identities) else {
            throw failure("BetterDisplay did not uniquely match this screen's ID, vendor, product and serial. No command was sent to a guessed monitor.")
        }
        return match
    }

    // Known standard adjustable VCPs; every value must also come from this device's report.
    static let writableDDC: Set<Int> = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x8D, 0xD6, 0xDC]
    private func failure(_ message: String) -> NSError { NSError(domain: "OpenCore.DisplayControls", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
