import CoreTelemetry
import SwiftUI

/// Uses the provider's automatic brightness route without inventing DDC capabilities.
struct ProviderBrightnessControlView: View {
    let display: ConnectedDisplay
    let feature: BetterDisplayFeature
    @ObservedObject var store: BetterDisplayControlStore
    @ObservedObject private var provider = BetterDisplayClient.shared
    @ObservedObject private var modes = ConnectedDisplayModeController.shared
    @State private var percent = ""
    @State private var confirm = false

    private var requested: Int? {
        guard let value = Int(percent.trimmingCharacters(in: .whitespaces)), (0...100).contains(value) else { return nil }
        return value
    }
    private var busy: Bool {
        store.isLoading || store.isApplying || store.hasLiveWork || store.readingsStale || provider.isMutating || modes.isBusy || modes.pendingDisplayID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Brightness through BetterDisplay", systemImage: "sun.max").font(.headline)
            Text("Uses BetterDisplay’s automatic brightness control for this selected screen. Its configured route may combine hardware adjustment and software dimming, as keyboard brightness can.")
            Text("A missing capability report does not disable this provider route. Returned values describe provider state; they do not verify the monitor’s physical brightness.")
                .foregroundStyle(.secondary)
            Button("Read provider brightness") { Task { await store.readFeature(feature, display: display) } }.disabled(busy)
            if store.valueFeatureID == feature.id, let value = store.featureValue {
                Text("Provider response: \(value.trimmingCharacters(in: .whitespacesAndNewlines))").textSelection(.enabled)
            }
            if let requested {
                HStack {
                    Slider(value: Binding(get: { Double(requested) }, set: { percent = String(Int($0.rounded())) }), in: 0...100, step: 1)
                        .accessibilityLabel("Requested BetterDisplay brightness")
                    Text("\(requested)%").font(.title3.monospacedDigit()).frame(minWidth: 54)
                }.disabled(busy)
            }
            Text("Requested setting · applied only when you confirm below").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Requested brightness, 0–100%", text: $percent).frame(maxWidth: 260)
                Button("Set brightness…") { confirm = true }.disabled(busy || requested == nil)
            }
            if store.featureFeedbackID == feature.id, let feedback = store.featureFeedback { Text(feedback).textSelection(.enabled) }
            if store.valueFeatureID == feature.id, let error = store.featureReadError { Text(error).foregroundStyle(.orange) }
            Text("Keyboard targeting stays in BetterDisplay. This action targets the screen selected in OpenCore.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .task { await store.readFeature(feature, display: display) }
        .onChange(of: store.featureValue) { _, raw in
            guard percent.isEmpty, store.valueFeatureID == feature.id,
                  let raw, let normalized = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  normalized.isFinite, (0...1).contains(normalized) else { return }
            percent = String(Int((normalized * 100).rounded()))
        }
        .confirmationDialog("Set BetterDisplay brightness on \(display.title)? Hardware readback may remain unavailable. Compare the visible result before treating it as verified.", isPresented: $confirm, titleVisibility: .visible) {
            if let requested {
                Button("Set to \(requested)%") { Task { await store.writeFeature(feature, value: "\(requested)%", display: display) } }
            }
        }
    }
}
