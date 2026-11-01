import AppKit
import SwiftUI

struct ConnectedDisplayDetailView: View {
    let display: ConnectedDisplay
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        monitorHeading
                        Button("macOS Display Settings", systemImage: "gearshape") { openDisplaySettings() }
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 12) {
                        monitorHeading
                        Button("macOS Display Settings", systemImage: "gearshape") { openDisplaySettings() }
                    }
                }
                if let actionError { Text(actionError).font(.callout).foregroundStyle(.orange) }
                Divider()
                BetterDisplayControlsView(display: display).id(display.connectionIdentity)
                DisclosureGroup("Screen identity & macOS details") {
                GroupBox("Current desktop on this Mac") {
                    VStack(alignment: .leading, spacing: 10) {
                        DetailRow(label: "Desktop mode", value: display.desktopMode)
                        DetailRow(label: "Render buffer", value: display.renderSize ?? "Not reported")
                        DetailRow(label: "Role", value: display.main ? "Main display" : "Additional display")
                        DetailRow(label: "State", value: display.active ? "Active" : "Online; not active")
                        DetailRow(label: "Mirroring", value: display.mirrored ? "In a mirror set" : "Extended desktop")
                        DetailRow(label: "Arrangement", value: display.arrangement)
                    }.padding(8)
                }
                GroupBox("Connection & identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        DetailRow(label: "Manufacturer", value: display.manufacturer)
                        DetailRow(label: "Reported model", value: display.name)
                        DetailRow(label: "Vendor / product", value: String(format: "0x%04X / 0x%04X", display.vendorID, display.productID))
                        DetailRow(label: "Serial", value: display.descriptor?.serialText ?? (display.serialNumber == 0 ? "Not reported" : String(display.serialNumber)))
                        DetailRow(label: "Native connector data", value: display.builtIn ? "Internal display" : "See BetterDisplay's connection report above")
                        if !display.builtIn {
                            Text("The native screen inventory does not map the exact socket or cable. BetterDisplay's link report adds connection evidence; its configured input labels alone do not prove physical ports.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let descriptor = display.descriptor {
                            if let year = descriptor.year {
                                DetailRow(label: "Manufactured", value: descriptor.week.map { "Week \($0), \(year)" } ?? "\(year)")
                            }
                            DisclosureGroup("Descriptor & registry evidence") {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let w = descriptor.nativeWidth, let h = descriptor.nativeHeight {
                                        DetailRow(label: "Reported native format", value: "\(w) × \(h)")
                                    }
                                    if let low = descriptor.minimumRefresh, let high = descriptor.maximumRefresh {
                                        DetailRow(label: "Reported refresh range", value: "\(low)–\(high) Hz")
                                    }
                                    Text("These descriptor claims can reflect an adapter or display override. They are not measured panel or cable limits, and can differ from the current desktop mode.")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if let path = descriptor.registryPath { Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                                }.padding(.top, 8)
                            }
                        }
                    }.padding(8)
                }
                DisclosureGroup("Modes macOS currently offers (\(display.modes.count))") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if display.modes.isEmpty { Text("No modes were reported.") }
                        ForEach(display.modeChoices) { choice in Text("\(choice.title) · mode ID \(choice.modeID)").textSelection(.enabled) }
                    }.padding(.top, 8)
                }
                Text("Desktop size and render pixels describe scaling, not the panel's physical pixel count. Offered modes apply to this current connection and do not establish the monitor's maximum capability.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Source: live Quartz Display Services, NSScreen and identity-matched IORegistry descriptor fields. No firmware was read or changed.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var monitorHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(display.title, systemImage: display.builtIn ? "laptopcomputer" : "display").font(.title2.bold())
            Text("\(display.main ? "Main display · " : "")\(display.builtIn ? "Built-in screen" : "External monitor")")
                .font(.callout).foregroundStyle(.secondary)
            Text(display.desktopMode).font(.callout).monospacedDigit()
        }
    }

    private func openDisplaySettings() {
        let opened = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
        actionError = opened ? nil : "macOS couldn't open Display Settings. Open System Settings → Displays."
    }
}
