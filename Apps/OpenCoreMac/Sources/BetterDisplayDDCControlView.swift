import CoreTelemetry
import SwiftUI

struct BetterDisplayDDCControlView: View {
    let display: ConnectedDisplay
    let feature: BetterDisplayDDCFeature
    @ObservedObject var store: BetterDisplayControlStore
    @ObservedObject private var provider = BetterDisplayClient.shared
    @ObservedObject private var modes = ConnectedDisplayModeController.shared
    @State private var value = 0.0
    @State private var isDragging = false
    @State private var confirm = false

    private var guide: MonitorControlGuide { .ddc(feature.id, name: feature.name) }
    private var live: Bool { MonitorControlGuide.liveCodes.contains(feature.id) && feature.acceptedValues.isEmpty }
    private var requiresConfirmation: Bool { MonitorControlGuide.needsConfirmation(feature.id) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(guide.title).font(.headline)
                    if live { Text("LIVE").font(.caption.bold()).foregroundStyle(.green) }
                }
                MonitorControlExplanationView(guide: guide)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Monitor reports").foregroundStyle(.secondary)
                    Text(reportedValue).fontWeight(.semibold).monospacedDigit().textSelection(.enabled)
                }.font(.callout)
                if !feature.acceptedValues.isEmpty {
                    Text(requiresConfirmation ? "Choose a requested value below, then confirm with the action button." : "Select a preset to apply it immediately. The result appears in this card.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .top)], alignment: .leading, spacing: 8) {
                        ForEach(feature.acceptedValues, id: \.self) { code in
                            MonitorChoiceTile(title: MonitorControlGuide.option(code: feature.id, value: code),
                                detail: feature.current == code && !feature.readFailed ? "Current monitor reading" : "Advertised by this monitor",
                                selected: value == Double(code)) { stagedValue.wrappedValue = Double(code) }
                                .disabled(controlsBlocked)
                        }
                    }
                    if let current = feature.current, !feature.acceptedValues.contains(current) {
                        Text("The current raw value \(current) is outside this monitor's advertised choices. It has not been replaced with a guessed selection.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if let maximum = feature.maximum, maximum > 0, feature.current != nil, !feature.readFailed {
                    HStack {
                        Slider(value: stagedValue, in: 0...Double(maximum), step: 1, onEditingChanged: { isDragging = $0 })
                            .accessibilityLabel(guide.title)
                        Text(Int(value).formatted()).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
                    }.disabled(liveControlsBlocked)
                    Text(live ? "Drag to adjust · device range 0–\(maximum) · newest value is sent automatically" : "Device range 0–\(maximum) · use Apply to send the selected value")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if requiresConfirmation {
                    Button(feature.id == 0x60 ? "Switch Input…" : "Change Power…") { confirm = true }
                        .disabled(!validValue || controlsBlocked)
                } else if !live && feature.acceptedValues.isEmpty {
                    Button("Apply \(guide.title)") { Task { await store.writeDDC(feature, value: Int(value), display: display) } }
                        .disabled(!validValue || controlsBlocked)
                }
                if let feedback = store.ddcFeedback[feature.id] {
                    Label(feedback.message, systemImage: feedbackIcon(feedback.state))
                        .font(.callout).foregroundStyle(feedbackColor(feedback.state)).textSelection(.enabled)
                }
                Text(String(format: "Hardware DDC · VCP 0x%02X · maximum field %@", feature.id, feature.maximum.map(String.init) ?? "unavailable"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .onAppear { resetStagedValue() }
        .onChange(of: feature.current) { _, _ in
            guard !isDragging, !store.liveQueue.contains(feature.id), store.applyingDDC != feature.id else { return }
            resetStagedValue()
        }
        .confirmationDialog("\(guide.title): \(MonitorControlGuide.option(code: feature.id, value: Int(value))) on \(display.title)? This can remove the Mac picture or control connection. Return using the monitor's physical controls if needed.", isPresented: $confirm, titleVisibility: .visible) {
            Button("Apply to This Monitor") { Task { await store.writeDDC(feature, value: Int(value), display: display) } }
        }
    }

    private var stagedValue: Binding<Double> {
        Binding(get: { value }, set: { newValue in
            value = newValue
            if live { store.queueLiveDDC(feature, value: Int(newValue), display: display) }
            else if !requiresConfirmation, feature.acceptedValues.contains(Int(newValue)) {
                Task { await store.writeDDC(feature, value: Int(newValue), display: display) }
            }
        })
    }
    private var controlsBlocked: Bool { store.isApplying || store.isLoading || store.hasLiveWork || store.readingsStale || provider.isMutating || modes.pendingDisplayID != nil || modes.isBusy }
    private var liveControlsBlocked: Bool {
        store.isLoading || store.readingsStale || provider.hasUncertainMutation ||
        (store.isApplying && !MonitorControlGuide.liveCodes.contains(store.applyingDDC ?? -1)) || (provider.isMutating && !store.isApplying) || modes.pendingDisplayID != nil || modes.isBusy
    }
    private var reportedValue: String {
        guard let current = feature.current, !feature.readFailed else { return "Unavailable" }
        return feature.acceptedValues.isEmpty ? "\(current) / \(feature.maximum.map(String.init) ?? "?")" : MonitorControlGuide.option(code: feature.id, value: current)
    }
    private var validValue: Bool {
        feature.acceptedValues.isEmpty ? (!feature.readFailed && feature.current != nil && (feature.maximum ?? 0) > 0 && value >= 0 && value <= Double(feature.maximum ?? 0)) : feature.acceptedValues.contains(Int(value))
    }
    private func resetStagedValue() {
        if feature.acceptedValues.isEmpty { value = Double(feature.current ?? 0) }
        else { value = feature.current.flatMap { feature.acceptedValues.contains($0) ? Double($0) : nil } ?? -1 }
    }
    private func feedbackIcon(_ state: DisplayControlFeedback.State) -> String {
        switch state { case .queued,.sending: "arrow.triangle.2.circlepath"; case .verified: "checkmark.circle.fill"; case .notApplied,.unavailable: "exclamationmark.triangle" }
    }
    private func feedbackColor(_ state: DisplayControlFeedback.State) -> Color {
        switch state { case .verified: .green; case .queued,.sending: .secondary; case .notApplied,.unavailable: .orange }
    }
}
