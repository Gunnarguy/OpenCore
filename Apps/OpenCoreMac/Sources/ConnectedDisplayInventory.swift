import AppKit
import Combine
import CoreGraphics
import CoreTelemetry
import IOKit

@MainActor
final class ConnectedDisplayInventory: ObservableObject {
    static let shared = ConnectedDisplayInventory()
    @Published private(set) var displays: [ConnectedDisplay] = []
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    private var screenChanges: AnyCancellable?
    private var retainedModes: [CGDirectDisplayID: [String: CGDisplayMode]] = [:]

    private init() {
        screenChanges = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        var count: UInt32 = 0
        let initial = CGGetOnlineDisplayList(0, nil, &count)
        guard initial == .success else { error = "macOS display scan failed (\(initial.rawValue)). Refresh to try again."; return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 {
            let result = CGGetOnlineDisplayList(count, &ids, &count)
            guard result == .success else { error = "macOS display scan failed (\(result.rawValue)). Refresh to try again."; return }
        }
        let descriptors = registryReadings()
        let screens = NSScreen.screens
        var refreshedModes: [CGDirectDisplayID: [String: CGDisplayMode]] = [:]
        displays = ids.prefix(Int(count)).map { id in
            let vendor = CGDisplayVendorNumber(id), product = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
            let onlineMatches = ids.prefix(Int(count)).filter {
                CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product &&
                (serial == 0 || CGDisplaySerialNumber($0) == serial)
            }.count
            let descriptor = DisplayRegistryReading.matching(vendorID: vendor, productID: product, serialNumber: serial, onlineMatchCount: onlineMatches, in: descriptors)
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let mode = CGDisplayCopyDisplayMode(id)
            let offered = Self.copyModes(id).sorted {
                if $0.width * $0.height != $1.width * $1.height { return $0.width * $0.height > $1.width * $1.height }
                return $0.refreshRate > $1.refreshRate
            }
            // Retain original Quartz mode objects. Only exact full-identity duplicates
            // collapse; equal rounded labels must never hide distinct mode IDs.
            var catalog: [String: CGDisplayMode] = [:]
            let choices = offered.compactMap { mode -> ConnectedDisplayModeChoice? in
                let choice = ConnectedDisplayModeChoice(mode)
                guard catalog[choice.id] == nil else { return nil }
                catalog[choice.id] = mode
                return choice
            }
            refreshedModes[id] = catalog
            let bounds = CGDisplayBounds(id)
            return ConnectedDisplay(
                id: id, name: descriptor?.productName ?? screen?.localizedName ?? "Display \(id)",
                vendorID: vendor, productID: product, serialNumber: serial,
                builtIn: CGDisplayIsBuiltin(id) != 0, main: CGDisplayIsMain(id) != 0,
                active: CGDisplayIsActive(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0,
                desktopMode: mode.map(ConnectedDisplay.modeName) ?? "Not reported",
                renderSize: mode.map { "\($0.pixelWidth) × \($0.pixelHeight)" },
                refreshRate: mode.flatMap { $0.refreshRate > 0 ? $0.refreshRate : nil },
                arrangement: "Origin \(Int(bounds.origin.x)), \(Int(bounds.origin.y)) • \(Int(bounds.width)) × \(Int(bounds.height)) desktop points",
                modes: choices.map(\.title), modeChoices: choices,
                currentModeKey: mode.map { ConnectedDisplayModeChoice($0).id }, descriptor: descriptor)
        }.sorted { $0.main != $1.main ? $0.main : $0.id < $1.id }
        error = nil
        updated = Date()
        retainedModes = refreshedModes
    }

    static func copyModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    func retainedMode(displayID: CGDirectDisplayID, choiceID: String) -> CGDisplayMode? {
        retainedModes[displayID]?[choiceID]
    }

    private func registryReadings() -> [DisplayRegistryReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var readings: [DisplayRegistryReading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let attributes = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            var path = [CChar](repeating: 0, count: 4096) // Chosen buffer; failed paths remain absent.
            let result = IORegistryEntryGetPath(service, kIOServicePlane, &path)
            let route = result == KERN_SUCCESS ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            if let reading = DisplayRegistryReading(attributes: attributes, registryPath: route) { readings.append(reading) }
        }
        return readings
    }
}
