import SwiftUI

struct HardwareDetailValueRow<LabelContent: View>: View {
    let value: String
    @ViewBuilder let label: LabelContent
    // Chosen reading dimensions: keep measurements beside labels instead of at the
    // far edge of a wide inspector. Scale with text and stack below in narrow panes.
    @ScaledMetric(relativeTo: .body) private var labelWidth = 200.0
    @ScaledMetric(relativeTo: .body) private var minimumValueWidth = 180.0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                label.frame(width: labelWidth, alignment: .leading)
                measurement.frame(minWidth: minimumValueWidth, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                measurement
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var measurement: some View {
        Text(value)
            .fontWeight(.medium)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
