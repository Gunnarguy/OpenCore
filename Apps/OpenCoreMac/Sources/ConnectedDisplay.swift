import Foundation
import CoreGraphics
import CoreTelemetry

struct ConnectedDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let builtIn: Bool
    let main: Bool
    let active: Bool
    let mirrored: Bool
    let desktopMode: String
    let renderSize: String?
    let refreshRate: Double?
    let arrangement: String
    let modes: [String]
    let modeChoices: [ConnectedDisplayModeChoice]
    let currentModeKey: String?
    let descriptor: DisplayRegistryReading?

    var connectionIdentity: DisplayConnectionIdentity {
        DisplayConnectionIdentity(displayID: id, vendorID: vendorID, productID: productID,
                                  serialNumber: serialNumber, builtIn: builtIn)
    }

    var manufacturer: String {
        switch descriptor?.manufacturer {
        case "SAM": "Samsung"
        case "ACR": "Acer"
        case "APP": "Apple"
        default: descriptor?.manufacturer ?? (builtIn ? "Apple" : "Not reported")
        }
    }

    var title: String { manufacturer == "Not reported" || name.hasPrefix(manufacturer) ? name : "\(manufacturer) \(name)" }

    static func modeName(_ mode: CGDisplayMode) -> String {
        ConnectedDisplayModeChoice(mode).title
    }
}
