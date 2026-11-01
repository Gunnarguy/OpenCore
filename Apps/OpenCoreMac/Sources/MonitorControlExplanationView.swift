import CoreTelemetry
import SwiftUI

struct MonitorControlExplanationView: View {
    let guide: MonitorControlGuide
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guide.purpose).font(.callout)
            explanation("What changes", guide.effect)
            explanation("Useful when", guide.useWhen)
            Text(guide.limits).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func explanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
