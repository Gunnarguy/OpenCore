import CoreCompanion
import SwiftUI

struct PhoneHomeView: View {
    @Environment(PhoneModel.self) private var model
    var body: some View {
        Group {
            if model.isConnected { PhoneReadView(section: .home) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Image("BrandMark").resizable().scaledToFit().frame(width: 88, height: 88).clipShape(.rect(cornerRadius: 22)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Your knowledge.\nWithin reach.").font(.largeTitle.bold())
                            Text("The same history, evidence and receipts, connected to your Mac.").font(.title3).foregroundStyle(.secondary)
                        }
                        ConnectionStatusView().padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: .rect(cornerRadius: 20))
                        NavigationLink { PhoneConnectionView() } label: {
                            Label(model.state == .unpaired ? "Pair your Mac" : "Unlock companion", systemImage: model.state == .unpaired ? "link" : "faceid")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent).tint(.blue)
                        VStack(alignment: .leading, spacing: 18) {
                            Label("Answers grounded in your sources", systemImage: "text.quote")
                            Label("Claims, beliefs and time travel", systemImage: "clock.arrow.circlepath")
                            Label("Receipts you can inspect", systemImage: "receipt")
                        }.font(.subheadline).foregroundStyle(.secondary)
                        Text("The Mac holds your store. This phone holds a device key and session data while unlocked.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(24)
                }.navigationTitle("OpenCore")
            }
        }
    }
}
