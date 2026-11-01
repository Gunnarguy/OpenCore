//
//  ContentView.swift
//  USB - Ultra USB Inspector
//
//  Created by Gunnar Hostetler on 1/30/26.
//

import Combine
import AppKit
@preconcurrency import DiskArbitration
import IOKit
import IOKit.storage
import IOKit.usb
import IOKit.hid
import CoreAudio
import AVFoundation
import CoreHID
import CoreTelemetry
import FoundationModels
import SwiftUI

// MARK: - IOKit USB Constants
let kUSBVendorID = "idVendor"
let kUSBProductID = "idProduct"
let kUSBVendorString = "USB Vendor Name"
let kUSBProductString = "USB Product Name"
let kUSBSerialNumberString = "USB Serial Number"
let kUSBDeviceSpeed = "Device Speed"
let kUSBDeviceClass = "bDeviceClass"
let kUSBDeviceSubClass = "bDeviceSubClass"
let kUSBDeviceProtocol = "bDeviceProtocol"
let kUSBMaxPower = "bMaxPower"
let kUSBDevicePropertyLocationID = "locationID"
let kIOBlockStorageStatisticsKey = "Statistics"
let kIOBlockStorageBytesReadKey = "Bytes (Read)"
let kIOBlockStorageBytesWrittenKey = "Bytes (Write)"
let kIOBlockStorageReadErrorsKey = "Errors (Read)"
let kIOBlockStorageWriteErrorsKey = "Errors (Write)"
let kIOBlockStorageReadRetriesKey = "Retries (Read)"
let kIOBlockStorageWriteRetriesKey = "Retries (Write)"
let kIOBlockStorageReadOperationsKey = "Operations (Read)"
let kIOBlockStorageWriteOperationsKey = "Operations (Write)"
let kIOBlockStorageTotalReadTimeKey = "Total Time (Read)"
let kIOBlockStorageTotalWriteTimeKey = "Total Time (Write)"

// MARK: - USB Device Class Descriptions (with layman explanations)
let usbClassDescriptions: [Int: (name: String, description: String, icon: String, layman: String)] = [
    0: ("Multi-Function", "Composite device with multiple features", "square.stack.3d.up", "This device does several things at once (like a webcam with a built-in microphone)"),
    1: ("Audio Device", "Sound input/output device", "speaker.wave.2", "Plays or records sound – like speakers, headphones, or a microphone"),
    2: ("Network/Serial", "Communications adapter", "network", "Connects to networks or other devices – like a USB ethernet adapter or modem"),
    3: ("Input Device", "Keyboard, mouse, or controller", "keyboard", "Something you use to control your computer – keyboard, mouse, game controller, etc."),
    5: ("Haptic Device", "Force feedback controller", "gamecontroller", "A controller that vibrates or pushes back, like a rumble gamepad"),
    6: ("Camera/Scanner", "Image capture device", "camera", "Captures photos or scans documents – like a camera or flatbed scanner"),
    7: ("Printer", "Printing device", "printer", "Prints documents or images on paper"),
    8: ("Storage", "Data storage device", "externaldrive", "Stores your files – USB drives, external hard drives, SD card readers"),
    9: ("USB Hub", "Port expander", "arrow.triangle.branch", "Adds more USB ports to your computer – plug in multiple devices"),
    10: ("Data Transfer", "Raw data channel", "waveform", "Transfers raw data for network or serial connections"),
    11: ("Smart Card Reader", "Security card reader", "creditcard", "Reads security cards for authentication or payments"),
    13: ("Biometric", "Security scanner", "touchid", "Scans fingerprints or other biometric data for security"),
    14: ("Webcam", "Video capture device", "video", "Records video – webcams, capture cards, video cameras"),
    15: ("Health Device", "Medical sensor", "heart.text.square", "Monitors health – like a heart rate monitor or glucose meter"),
    16: ("A/V Device", "Audio/video combo device", "video.badge.waveform", "Handles both audio and video together – like a webcam with microphone"),
    17: ("USB-C Info", "Capability advertisement", "info.circle", "Tells your computer what this USB-C port/device can do"),
    18: ("USB-C Bridge", "Connection bridge", "point.3.connected.trianglepath.dotted", "Converts or bridges different connection types through USB-C"),
    220: ("Test Device", "Diagnostic tool", "wrench.and.screwdriver", "Used for testing and troubleshooting USB connections"),
    224: ("Wireless Adapter", "Bluetooth/wireless", "wifi", "Adds wireless capabilities – like a Bluetooth dongle or wireless adapter"),
    239: ("Misc Device", "General purpose", "ellipsis.circle", "A general-purpose device that doesn't fit other categories"),
    254: ("Special Purpose", "Application-specific", "wrench", "Designed for a specific app or purpose"),
    255: ("Custom Device", "Manufacturer-specific", "shippingbox", "Uses the manufacturer's own special features")
]

struct USBVendorProfile {
    let canonicalName: String
    let companySummary: String
    let usbContext: String
}

struct USBDescriptorMeaning: Hashable {
    let technicalLabel: String
    let plainEnglish: String
    let macBehavior: String
    let uniqueness: String
    let tags: [String]
}

struct USBProductCatalogEntry {
    let vendorIDs: Set<Int>
    let vendorTokens: [String]
    let productTokens: [String]
    let category: String
    let summary: String
    let highlights: [String]
    let badges: [String]
}

struct StorageVolumeInfo: Identifiable, Hashable {
    let bsdName: String
    let wholeDiskBSDName: String
    let volumeName: String
    let mediaName: String
    let fileSystem: String
    let mountPath: String
    let capacityBytes: Int64
    let availableBytes: Int64
    let isWholeDisk: Bool
    let isMounted: Bool
    let isLeaf: Bool
    let deviceModel: String
    let deviceProtocol: String
    let volumeUUID: String
    let mediaUUID: String

    var id: String { bsdName }

    var displayName: String {
        if !volumeName.isEmpty { return volumeName }
        if !mediaName.isEmpty { return mediaName }
        return bsdName
    }

    var roleDescription: String {
        if isWholeDisk { return "Physical disk" }
        if isMounted { return "Mounted volume" }
        if !fileSystem.isEmpty { return "Partition / container" }
        return "Disk component"
    }

    var mountDescription: String {
        isMounted ? mountPath : "Not mounted in Finder"
    }

    var capacityDescription: String {
        formatByteCount(capacityBytes)
    }

    var availableDescription: String {
        availableBytes > 0 ? formatByteCount(availableBytes) : "Unknown"
    }

    var subtitle: String {
        var parts: [String] = [roleDescription]
        if !fileSystem.isEmpty { parts.append(fileSystem) }
        if capacityBytes > 0 { parts.append(capacityDescription) }
        return orderedUniqueStrings(parts).joined(separator: " • ")
    }
}

enum StorageTrafficDirection: String, Hashable {
    case idle
    case reading
    case writing
    case mixed

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .reading: return "Reading"
        case .writing: return "Writing"
        case .mixed: return "Read + Write"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "pause.circle"
        case .reading: return "arrow.down.circle.fill"
        case .writing: return "arrow.up.circle.fill"
        case .mixed: return "arrow.up.and.down.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .reading: return .blue
        case .writing: return .orange
        case .mixed: return .purple
        }
    }

    var explanation: String {
        switch self {
        case .idle:
            return "No meaningful block-level disk traffic was observed in the current sample window."
        case .reading:
            return "macOS is actively pulling data off this device right now."
        case .writing:
            return "macOS is actively pushing data onto this device right now."
        case .mixed:
            return "macOS is reading from and writing to this device in the same sample window."
        }
    }
}

struct BlockStorageCounters: Hashable {
    let bytesRead: Int64
    let bytesWritten: Int64
    let readErrors: Int64
    let writeErrors: Int64
    let readRetries: Int64
    let writeRetries: Int64
    let readOperations: Int64
    let writeOperations: Int64
    let totalReadTimeNanoseconds: Int64
    let totalWriteTimeNanoseconds: Int64
}

struct BlockStorageSample: Hashable {
    let sampleDate: Date
    let counters: BlockStorageCounters
}

struct VolumeCapacitySample: Hashable {
    let sampleDate: Date
    let availableBytes: Int64
    let capacityBytes: Int64
}

struct LiveMountedVolumeState: Identifiable, Hashable {
    let bsdName: String
    let sampleDate: Date
    let capacityBytes: Int64
    let availableBytes: Int64
    let availableBytesPerSecond: Double
    let isReadOnly: Bool
    let formatDescription: String

    var id: String { bsdName }

    var usedBytes: Int64 {
        max(capacityBytes - availableBytes, 0)
    }

    var usageFraction: Double? {
        guard capacityBytes > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(capacityBytes), 0), 1)
    }

    var usageDescription: String {
        guard capacityBytes > 0 else { return "Capacity unknown" }
        return "\(formatByteCount(usedBytes)) used of \(formatByteCount(capacityBytes))"
    }

    var freeDescription: String {
        guard capacityBytes > 0 else { return "Free space unknown" }
        return "\(formatByteCount(availableBytes)) free"
    }

    var freeChangeDescription: String? {
        guard abs(availableBytesPerSecond) >= 8_192 else { return nil }
        let direction = availableBytesPerSecond > 0 ? "Free space rising" : "Free space dropping"
        return "\(direction) at \(formatTransferRate(abs(availableBytesPerSecond)))"
    }

    var accessibilitySummary: String {
        isReadOnly ? "Read-only" : "Writable"
    }
}

struct LiveWholeDiskActivity: Identifiable, Hashable {
    let wholeDiskBSDName: String
    let sampleDate: Date
    let direction: StorageTrafficDirection
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let readOperationsPerSecond: Double
    let writeOperationsPerSecond: Double
    let totalBytesRead: Int64
    let totalBytesWritten: Int64
    let totalReadErrors: Int64
    let totalWriteErrors: Int64
    let totalReadRetries: Int64
    let totalWriteRetries: Int64
    let readErrorDelta: Int64
    let writeErrorDelta: Int64
    let readRetryDelta: Int64
    let writeRetryDelta: Int64
    let averageReadLatencyMilliseconds: Double?
    let averageWriteLatencyMilliseconds: Double?
    let lastActiveAt: Date?

    var id: String { wholeDiskBSDName }

    var isBusy: Bool {
        direction != .idle
    }

    var throughputSummary: String {
        switch direction {
        case .idle:
            return "Idle"
        case .reading:
            return "\(formatTransferRate(readBytesPerSecond)) read"
        case .writing:
            return "\(formatTransferRate(writeBytesPerSecond)) write"
        case .mixed:
            return "\(formatTransferRate(readBytesPerSecond)) read • \(formatTransferRate(writeBytesPerSecond)) write"
        }
    }

    var operationSummary: String {
        switch direction {
        case .idle:
            return "No active I/O operations detected"
        case .reading:
            return "\(formatOperationRate(readOperationsPerSecond)) read ops"
        case .writing:
            return "\(formatOperationRate(writeOperationsPerSecond)) write ops"
        case .mixed:
            return "\(formatOperationRate(readOperationsPerSecond)) read ops • \(formatOperationRate(writeOperationsPerSecond)) write ops"
        }
    }

    var latencySummary: String? {
        var parts: [String] = []
        if let averageReadLatencyMilliseconds, averageReadLatencyMilliseconds > 0.01 {
            parts.append(String(format: "%.1f ms read latency", averageReadLatencyMilliseconds))
        }
        if let averageWriteLatencyMilliseconds, averageWriteLatencyMilliseconds > 0.01 {
            parts.append(String(format: "%.1f ms write latency", averageWriteLatencyMilliseconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var reliabilitySummary: String? {
        var parts: [String] = []
        if readErrorDelta > 0 || writeErrorDelta > 0 {
            parts.append("Errors changed by +\(readErrorDelta + writeErrorDelta) in this sample")
        }
        if readRetryDelta > 0 || writeRetryDelta > 0 {
            parts.append("Retries changed by +\(readRetryDelta + writeRetryDelta) in this sample")
        }
        if totalReadErrors > 0 || totalWriteErrors > 0 {
            parts.append("Total errors: \(totalReadErrors + totalWriteErrors)")
        }
        if totalReadRetries > 0 || totalWriteRetries > 0 {
            parts.append("Total retries: \(totalReadRetries + totalWriteRetries)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

struct DeviceStorageActivity: Hashable {
    let deviceID: String
    let sampleDate: Date
    let direction: StorageTrafficDirection
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let readOperationsPerSecond: Double
    let writeOperationsPerSecond: Double
    let activeDiskCount: Int
    let wholeDiskBSDNames: [String]
    let busiestDiskBSDName: String?
    let lastActiveAt: Date?

    var isBusy: Bool {
        direction != .idle
    }

    var compactBadgeText: String? {
        guard isBusy else { return nil }
        switch direction {
        case .idle:
            return nil
        case .reading:
            return "Read \(formatTransferRate(readBytesPerSecond))"
        case .writing:
            return "Write \(formatTransferRate(writeBytesPerSecond))"
        case .mixed:
            return "Busy \(formatTransferRate(max(readBytesPerSecond, writeBytesPerSecond)))"
        }
    }

    var summary: String {
        switch direction {
        case .idle:
            if let lastActiveAt {
                return "Idle right now. Last meaningful storage activity was \(relativeTimestampDescription(lastActiveAt))."
            }
            return "Idle right now. No recent block-level storage activity has been sampled yet."
        case .reading:
            return "macOS is currently reading from this device at about \(formatTransferRate(readBytesPerSecond))."
        case .writing:
            return "macOS is currently writing to this device at about \(formatTransferRate(writeBytesPerSecond))."
        case .mixed:
            return "macOS is reading and writing at the same time: \(formatTransferRate(readBytesPerSecond)) read and \(formatTransferRate(writeBytesPerSecond)) write."
        }
    }
}

private func normalizedLookupToken(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

private func stringContainsAny(_ value: String, fragments: [String]) -> Bool {
    let normalizedValue = normalizedLookupToken(value)
    return fragments.contains { normalizedValue.contains(normalizedLookupToken($0)) }
}

private func orderedUniqueStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []

    for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        if seen.insert(trimmed).inserted {
            result.append(trimmed)
        }
    }

    return result
}

private func naturalLanguageList(_ values: [String]) -> String {
    let uniqueValues = orderedUniqueStrings(values)

    switch uniqueValues.count {
    case 0:
        return ""
    case 1:
        return uniqueValues[0]
    case 2:
        return "\(uniqueValues[0]) and \(uniqueValues[1])"
    default:
        return uniqueValues.dropLast().joined(separator: ", ") + ", and " + (uniqueValues.last ?? "")
    }
}

private func hexByte(_ value: Int) -> String {
    String(format: "%02Xh", value & 0xFF)
}

private func formatByteCount(_ value: Int64) -> String {
    guard value > 0 else { return "Unknown" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: value)
}

private func formatUSBPowerAssumingFiveVolts(_ milliamps: Int) -> String {
    guard milliamps > 0 else { return "Not reported" }
    let watts = Double(milliamps) * 5.0 / 1000.0
    return "\(milliamps) mA (\(String(format: "%.2f", watts)) W @ 5V)"
}

private func decodeUSBPortTypeCode(from value: Any?) -> Int? {
    if let int = intValue(value) {
        return int
    }

    if let data = value as? Data, !data.isEmpty {
        return data.reduce(0) { partialResult, byte in
            (partialResult << 8) | Int(byte)
        }
    }

    return nil
}

private func usbPortTypeCodeDescription(_ code: Int?) -> String {
    guard let code else { return "Not published" }

    switch code {
    case 0:
        return "Code 0 (basic downstream port classification)"
    case 5:
        return "Code 5 (modern host-path classification; public marketing label not exposed)"
    default:
        return "Code \(code) (public label not exposed)"
    }
}

private func powerFactString(for value: Any?) -> String? {
    guard let value else { return nil }

    if let string = value as? String {
        return string
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    if let data = value as? Data, !data.isEmpty {
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    return nil
}

private func formatTransferRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "0 B/s" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(max(bytesPerSecond, 1))) + "/s"
}

private func formatOperationRate(_ operationsPerSecond: Double) -> String {
    guard operationsPerSecond > 0 else { return "0.0" }
    if operationsPerSecond >= 100 {
        return String(format: "%.0f", operationsPerSecond)
    }
    if operationsPerSecond >= 10 {
        return String(format: "%.1f", operationsPerSecond)
    }
    return String(format: "%.2f", operationsPerSecond)
}

private func relativeTimestampDescription(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func resolveStorageTrafficDirection(readBytesPerSecond: Double, writeBytesPerSecond: Double, readOperationsPerSecond: Double, writeOperationsPerSecond: Double) -> StorageTrafficDirection {
    let byteThreshold = 32_768.0
    let operationThreshold = 0.25
    let hasRead = readBytesPerSecond >= byteThreshold || readOperationsPerSecond >= operationThreshold
    let hasWrite = writeBytesPerSecond >= byteThreshold || writeOperationsPerSecond >= operationThreshold

    switch (hasRead, hasWrite) {
    case (false, false):
        return .idle
    case (true, false):
        return .reading
    case (false, true):
        return .writing
    case (true, true):
        return .mixed
    }
}

private func stableUSBDeviceID(vendorID: Int, productID: Int, serialNumber: String, sessionID: UInt64, locationID: UInt32, name: String) -> String {
    if !serialNumber.isEmpty {
        return "usb-\(vendorID)-\(productID)-\(serialNumber)"
    }
    if sessionID > 0 {
        return "usb-session-\(sessionID)"
    }
    return "usb-\(locationID)-\(vendorID)-\(productID)-\(name)"
}

private func registryEntryName(_ service: io_registry_entry_t) -> String {
    var nameBuffer = [CChar](repeating: 0, count: 256)
    guard IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS else { return "" }
    return String(cString: nameBuffer)
}

private func matchesCatalogEntry(_ entry: USBProductCatalogEntry, vendorID: Int, vendorName: String, productName: String) -> Bool {
    let normalizedVendorName = normalizedLookupToken(vendorName)
    let normalizedProductName = normalizedLookupToken(productName)

    let vendorMatches = entry.vendorIDs.isEmpty
        || entry.vendorIDs.contains(vendorID)
        || entry.vendorTokens.contains(where: { normalizedVendorName.contains(normalizedLookupToken($0)) })

    let productMatches = entry.productTokens.isEmpty
        || entry.productTokens.contains(where: { normalizedProductName.contains(normalizedLookupToken($0)) })

    return vendorMatches && productMatches
}

private let usbProductCatalog: [USBProductCatalogEntry] = [
    USBProductCatalogEntry(
        vendorIDs: [0x04E8],
        vendorTokens: ["samsung"],
        productTokens: ["pssd t5", "pssd t7", "pssd t9", "portable ssd"],
        category: "Samsung portable SSD",
        summary: "This looks like a Samsung portable SSD rather than a generic removable disk. These drives usually expose standard USB storage transports and rely on the enclosure bridge for their USB personality.",
        highlights: [
            "Portable SSDs are a good case where the USB transport matters more than the marketing name on the shell.",
            "If this falls back to BOT or negotiates below 10 Gbps, the bridge, cable, hub, or host path is the first thing to question."
        ],
        badges: ["SSD", "Portable"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x152D],
        vendorTokens: ["jmicron"],
        productTokens: ["jms583", "jms580", "jms578", "jms567", "jms56"],
        category: "USB storage bridge",
        summary: "This is likely a JMicron bridge chip sitting between USB and SATA/NVMe media. The bridge is what macOS sees first, which is why the device identity can differ from the actual drive installed inside the enclosure.",
        highlights: [
            "Bridge chips are normal in external SSD enclosures and card readers.",
            "The bridge determines whether you get UAS, BOT, TRIM behavior, and sometimes thermal quirks."
        ],
        badges: ["Bridge", "JMicron"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x174C],
        vendorTokens: ["asmedia"],
        productTokens: ["asm2362", "asm235cm", "asm1153", "asm1051", "asm235"],
        category: "USB storage bridge",
        summary: "This is likely an ASMedia bridge controller. On external enclosures and docks, ASMedia frequently represents the USB-facing bridge silicon rather than the retail product brand.",
        highlights: [
            "ASMedia bridges are common in NVMe/SATA enclosures and multiport docks.",
            "Bridge silicon often explains odd speed ceilings better than the SSD vendor name does."
        ],
        badges: ["Bridge", "ASMedia"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x0BDA],
        vendorTokens: ["realtek"],
        productTokens: ["rtl8153", "rtl8156", "2.5gbe", "gigabit ethernet", "usb 10/100/1000"],
        category: "USB Ethernet adapter",
        summary: "This looks like a Realtek USB Ethernet controller. On docks and dongles, Realtek is usually the networking chip the host talks to directly.",
        highlights: [
            "The controller silicon is often more informative than the retail dock brand for troubleshooting link speed and driver behavior.",
            "2.5 GbE adapters commonly revolve around RTL8156-family parts."
        ],
        badges: ["Ethernet", "Realtek"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [],
        vendorTokens: ["asix"],
        productTokens: ["ax88179", "ax88772"],
        category: "USB Ethernet adapter",
        summary: "This looks like an ASIX USB networking controller, which is a common chipset family in USB Ethernet dongles.",
        highlights: [
            "ASIX controllers are a strong clue that the device is a network bridge rather than a storage or HID accessory."
        ],
        badges: ["Ethernet", "ASIX"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x046D],
        vendorTokens: ["logitech"],
        productTokens: ["unifying receiver", "bolt receiver"],
        category: "Wireless input receiver",
        summary: "This looks like a Logitech wireless receiver that can represent several keyboards, mice, or other input devices behind one tiny USB endpoint.",
        highlights: [
            "The single USB device can be the parent for multiple wireless peripherals that never show up as separate USB cables."
        ],
        badges: ["Receiver", "Input"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x0403],
        vendorTokens: ["ftdi"],
        productTokens: ["ft232", "ft231", "ft2232", "usb serial"],
        category: "USB serial bridge",
        summary: "This looks like an FTDI USB-to-serial bridge, which usually means the USB layer is just carrying a UART-style control or console channel for embedded hardware.",
        highlights: [
            "Serial bridges are common in dev boards, lab gear, CNC equipment, and firmware consoles."
        ],
        badges: ["Serial", "FTDI"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x10C4],
        vendorTokens: ["silicon labs"],
        productTokens: ["cp210", "cp2102", "cp2104", "cp2105"],
        category: "USB serial bridge",
        summary: "This looks like a Silicon Labs CP210x-style USB serial bridge, which is commonly used to expose debug or control channels from embedded devices.",
        highlights: [
            "If you were expecting a disk or camera, a CP210x identity means the device is really offering a serial-style control path."
        ],
        badges: ["Serial", "CP210x"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [0x1A86],
        vendorTokens: ["wch"],
        productTokens: ["ch340", "ch341", "ch9102"],
        category: "USB serial bridge",
        summary: "This looks like a WCH serial bridge, the kind of low-cost USB transport often used by hobbyist boards and embedded adapters.",
        highlights: [
            "These chips are common in maker hardware because they cheaply turn USB into a UART console."
        ],
        badges: ["Serial", "WCH"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [],
        vendorTokens: [],
        productTokens: ["card reader", "sd reader", "cfexpress", "micro sd"],
        category: "Card reader",
        summary: "This looks like a card reader. The USB endpoint is stable, but the actual storage media behind it can change completely depending on what card is inserted.",
        highlights: [
            "Card readers often present as plain mass storage even though the removable media behind them is interchangeable."
        ],
        badges: ["Media", "Reader"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [],
        vendorTokens: [],
        productTokens: ["dock", "docking station", "multiport", "usb-c hub", "travel dock"],
        category: "Dock / hub",
        summary: "This looks like a dock or hub-class product. These often collapse several very different functions into one upstream USB-C or USB link.",
        highlights: [
            "Docks frequently contain storage bridges, Ethernet chips, audio controllers, billboard devices, and multiple downstream hub stages."
        ],
        badges: ["Dock", "Multi-function"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [],
        vendorTokens: [],
        productTokens: ["cam link", "capture", "video capture"],
        category: "Video capture device",
        summary: "This looks like a capture-oriented device. These usually expose video-control and video-streaming interfaces instead of acting like storage.",
        highlights: [
            "Capture devices often negotiate bandwidth-heavy alternate settings on the streaming side."
        ],
        badges: ["Capture", "Video"]
    ),
    USBProductCatalogEntry(
        vendorIDs: [],
        vendorTokens: [],
        productTokens: ["dfu", "fastboot", "recovery"],
        category: "Firmware / recovery interface",
        summary: "This looks like a firmware, bootloader, or recovery-mode interface rather than the device's normal runtime personality.",
        highlights: [
            "Recovery-oriented identities are usually temporary and disappear once the device boots normally."
        ],
        badges: ["Recovery", "Firmware"]
    )
]

private func lookupProductCatalogEntry(vendorID: Int, vendorName: String, productName: String) -> USBProductCatalogEntry? {
    usbProductCatalog.first { entry in
        matchesCatalogEntry(entry, vendorID: vendorID, vendorName: vendorName, productName: productName)
    }
}

private func lookupVendorProfile(vendorID: Int, vendorName: String) -> USBVendorProfile? {
    switch vendorID {
    case 0x04E8:
        return USBVendorProfile(
            canonicalName: "Samsung",
            companySummary: "Samsung commonly shows up in USB land as portable SSDs, flash storage, phones, tablets, and recovery interfaces.",
            usbContext: "When the product string looks like PSSD or T-series storage, it is usually a standard bus-powered external SSD rather than a custom-protocol device."
        )
    case 0x05AC:
        return USBVendorProfile(
            canonicalName: "Apple",
            companySummary: "Apple uses USB for both external accessories and a surprising amount of internal hardware such as cameras, Bluetooth bridges, and recovery paths.",
            usbContext: "On a Mac, Apple-branded USB devices are often built-in infrastructure rather than removable peripherals."
        )
    case 0x046D:
        return USBVendorProfile(
            canonicalName: "Logitech",
            companySummary: "Logitech mostly appears here as input devices, receivers, webcams, conference gear, and USB audio endpoints.",
            usbContext: "If the product string mentions a receiver, Bolt, or Unifying, it is usually multiplexing several input devices over one radio link."
        )
    case 0x0781:
        return USBVendorProfile(
            canonicalName: "SanDisk",
            companySummary: "SanDisk is primarily associated with flash media, thumb drives, SSDs, and memory-card products.",
            usbContext: "Most SanDisk USB devices speak standard mass-storage protocols, so macOS should treat them like disks instead of needing a vendor app."
        )
    case 0x1058:
        return USBVendorProfile(
            canonicalName: "Western Digital",
            companySummary: "Western Digital commonly shows up as external HDDs, SSDs, and bridge-based storage enclosures.",
            usbContext: "With storage hardware, the USB view often reflects the bridge/controller inside the enclosure more than the marketing name on the outside."
        )
    case 0x0BC2:
        return USBVendorProfile(
            canonicalName: "Seagate",
            companySummary: "Seagate is mostly associated with external hard drives, backup drives, and storage appliances.",
            usbContext: "These devices usually surface as standard mass storage and should be understood mainly through the storage transport they negotiated."
        )
    case 0x0951:
        return USBVendorProfile(
            canonicalName: "Kingston",
            companySummary: "Kingston commonly appears as flash drives, card readers, and SSD-related USB storage devices.",
            usbContext: "Most Kingston devices are straightforward storage endpoints with standard descriptors."
        )
    case 0x0BDA:
        return USBVendorProfile(
            canonicalName: "Realtek",
            companySummary: "Realtek is usually the chip vendor behind USB Ethernet adapters, card readers, audio codecs, and combo wireless bridges.",
            usbContext: "If you bought a dock or adapter from another brand, a Realtek vendor ID often means you are seeing the controller silicon rather than the retail brand."
        )
    case 0x174C:
        return USBVendorProfile(
            canonicalName: "ASMedia",
            companySummary: "ASMedia commonly appears as the bridge/controller silicon inside USB storage enclosures, hubs, and docks.",
            usbContext: "An ASMedia vendor ID often identifies the USB bridge chip rather than the SSD or enclosure brand on the box."
        )
    case 0x152D:
        return USBVendorProfile(
            canonicalName: "JMicron",
            companySummary: "JMicron frequently shows up as the USB-to-SATA/NVMe bridge inside external storage enclosures and card readers.",
            usbContext: "Seeing JMicron usually means this is a bridge board translating USB into another storage bus behind the scenes."
        )
    case 0x8087:
        return USBVendorProfile(
            canonicalName: "Intel",
            companySummary: "Intel vendor IDs often appear on wireless/Bluetooth combo controllers, internal bridges, or platform-management hardware.",
            usbContext: "On Macs and PCs alike, an Intel USB endpoint is often internal infrastructure rather than a removable gadget."
        )
    case 0x0A5C:
        return USBVendorProfile(
            canonicalName: "Broadcom",
            companySummary: "Broadcom commonly appears as Bluetooth, Wi-Fi, or internal bridge silicon inside laptops and accessories.",
            usbContext: "If the device is internal and wireless-related, Broadcom is often the radio/controller rather than a user-facing peripheral."
        )
    case 0x045E:
        return USBVendorProfile(
            canonicalName: "Microsoft",
            companySummary: "Microsoft commonly shows up as keyboards, mice, controllers, webcams, and docking accessories.",
            usbContext: "These devices usually speak standard HID, audio, or video classes rather than exotic vendor-specific protocols."
        )
    case 0x18D1:
        return USBVendorProfile(
            canonicalName: "Google",
            companySummary: "Google vendor IDs often appear on Android phones, developer devices, and recovery/fastboot interfaces.",
            usbContext: "When the class looks vendor-specific or application-specific, the device may be in a debug, sideload, or firmware-update mode."
        )
    case 0x054C:
        return USBVendorProfile(
            canonicalName: "Sony",
            companySummary: "Sony commonly appears as cameras, controllers, phones, and media devices.",
            usbContext: "Depending on the class, Sony hardware may present as imaging, HID, storage, or a vendor-specific service interface."
        )
    case 0x04A9:
        return USBVendorProfile(
            canonicalName: "Canon",
            companySummary: "Canon most often appears as cameras, printers, scanners, and imaging gear.",
            usbContext: "Imaging devices sometimes expose multiple interfaces for control, still capture, and streaming/video paths."
        )
    case 0x0403:
        return USBVendorProfile(
            canonicalName: "FTDI",
            companySummary: "FTDI is best known for USB-to-serial bridges used in embedded development, lab hardware, and debugging tools.",
            usbContext: "If you see FTDI, the USB link is often just a transport wrapper around a serial console or control channel."
        )
    case 0x10C4:
        return USBVendorProfile(
            canonicalName: "Silicon Labs",
            companySummary: "Silicon Labs commonly appears as USB-to-UART bridges, radios, and embedded-device support interfaces.",
            usbContext: "This usually means the device is exposing a control/debug path rather than a consumer-friendly USB class."
        )
    case 0x1A86:
        return USBVendorProfile(
            canonicalName: "WCH",
            companySummary: "WCH is commonly seen on low-cost USB-to-serial bridges such as CH340-family chips used in hobbyist hardware.",
            usbContext: "These are often tiny bridge chips that make microcontrollers and dev boards look like serial devices over USB."
        )
    default:
        break
    }

    let normalizedVendorName = normalizedLookupToken(vendorName)

    if normalizedVendorName.contains("samsung") {
        return USBVendorProfile(
            canonicalName: "Samsung",
            companySummary: "Samsung commonly shows up in USB land as portable SSDs, flash storage, phones, tablets, and recovery interfaces.",
            usbContext: "When the product string looks like PSSD or T-series storage, it is usually a standard bus-powered external SSD rather than a custom-protocol device."
        )
    }

    if normalizedVendorName.contains("realtek") {
        return USBVendorProfile(
            canonicalName: "Realtek",
            companySummary: "Realtek is usually the chip vendor behind USB Ethernet adapters, card readers, audio codecs, and combo wireless bridges.",
            usbContext: "If you bought a dock or adapter from another brand, a Realtek vendor ID often means you are seeing the controller silicon rather than the retail brand."
        )
    }

    if normalizedVendorName.contains("asmedia") {
        return USBVendorProfile(
            canonicalName: "ASMedia",
            companySummary: "ASMedia commonly appears as the bridge/controller silicon inside USB storage enclosures, hubs, and docks.",
            usbContext: "An ASMedia vendor ID often identifies the USB bridge chip rather than the SSD or enclosure brand on the box."
        )
    }

    return nil
}

private func descriptorMeaningFor(classCode: Int, subClass: Int, protocolCode: Int, isDeviceLevel: Bool) -> USBDescriptorMeaning {
    switch classCode {
    case -1:
        return USBDescriptorMeaning(
            technicalLabel: "Unclassified USB device",
            plainEnglish: "macOS did not expose enough descriptor detail to give this device a confident class-level identity.",
            macBehavior: "The raw registry data is still useful, but the top-level role has to be inferred from names, drivers, and surrounding context.",
            uniqueness: "This usually happens with incomplete descriptors, unusual bridges, or vendor-specific hardware.",
            tags: ["unknown"]
        )
    case 0x00:
        return USBDescriptorMeaning(
            technicalLabel: "Composite / interface-defined device",
            plainEnglish: "The device descriptor intentionally leaves the real job description to its individual interfaces.",
            macBehavior: "macOS will inspect each interface separately and can attach different drivers to different functions on the same physical device.",
            uniqueness: "This is normal for docks, webcams with microphones, printers/scanners, and other multi-function USB hardware.",
            tags: ["composite"]
        )
    case 0x01:
        let technicalLabel: String
        let plainEnglish: String
        let uniqueness: String

        switch subClass {
        case 0x01:
            technicalLabel = "Audio Control Interface"
            plainEnglish = "This is the control side of a USB audio device, where it advertises mixers, clocking, input/output topology, and routing."
            uniqueness = "Audio devices often pair this with one or more streaming interfaces that carry the actual sound data."
        case 0x02:
            technicalLabel = "Audio Streaming Interface"
            plainEnglish = "This interface carries the actual audio stream for speakers, microphones, headsets, or audio interfaces."
            uniqueness = "Alternate settings often change bandwidth, channel count, or sample-rate capability."
        case 0x03:
            technicalLabel = "MIDI Streaming Interface"
            plainEnglish = "This interface carries MIDI note/control events rather than raw PCM audio."
            uniqueness = "A MIDI streaming interface is about musical control messages, not speaker or microphone audio data."
        default:
            technicalLabel = "USB Audio Interface"
            plainEnglish = "This is part of a USB audio device and is likely involved in sound routing or streaming."
            uniqueness = "USB audio devices often split control and streaming into separate interfaces."
        }

        return USBDescriptorMeaning(
            technicalLabel: technicalLabel,
            plainEnglish: plainEnglish,
            macBehavior: "macOS will typically expose this through Sound settings, Core Audio apps, conferencing apps, or DAWs.",
            uniqueness: uniqueness,
            tags: ["audio"] + (subClass == 0x03 ? ["midi"] : [])
        )
    case 0x02:
        return USBDescriptorMeaning(
            technicalLabel: "Communication / CDC Control Interface",
            plainEnglish: "This is the control plane for a communication-oriented USB function such as networking, tethering, modem behavior, or management.",
            macBehavior: "macOS may pair this with a CDC data interface and surface it as a network adapter, tethering path, or control channel.",
            uniqueness: "CDC devices often split control and data across separate interfaces, so the real payload may live elsewhere in the interface list.",
            tags: ["network", "communication"]
        )
    case 0x03:
        let technicalLabel: String
        let plainEnglish: String
        let uniqueness: String
        var tags = ["hid", "input"]

        switch (subClass, protocolCode) {
        case (0x01, 0x01):
            technicalLabel = "Boot Keyboard Interface"
            plainEnglish = "This is the keyboard-compatible HID path that can work even before full OS-level drivers are involved."
            uniqueness = "The boot protocol is a stripped-down keyboard mode designed for maximum compatibility."
            tags.append("keyboard")
        case (0x01, 0x02):
            technicalLabel = "Boot Mouse Interface"
            plainEnglish = "This is the mouse-compatible HID path for pointer movement and buttons."
            uniqueness = "The boot protocol is the simplest pointer mode and is meant to work in firmware and recovery environments too."
            tags.append("mouse")
        default:
            technicalLabel = "Generic HID Interface"
            plainEnglish = "This interface carries human-input-style events such as keys, buttons, pointing data, pen input, or controller actions."
            uniqueness = "HID is the standard class for keyboards, mice, tablets, game controllers, and many small control surfaces."
        }

        return USBDescriptorMeaning(
            technicalLabel: technicalLabel,
            plainEnglish: plainEnglish,
            macBehavior: "macOS routes this through the HID stack, so it behaves like input hardware instead of mounting like a disk.",
            uniqueness: uniqueness,
            tags: tags
        )
    case 0x05:
        return USBDescriptorMeaning(
            technicalLabel: "Physical / Haptics Interface",
            plainEnglish: "This interface is for physical-feedback or haptics-oriented behavior rather than generic file or network traffic.",
            macBehavior: "You usually see this behind specialized controllers or force-feedback accessories rather than as a standalone endpoint in Finder.",
            uniqueness: "It is rare in everyday peripherals compared with HID, audio, or mass storage.",
            tags: ["haptics"]
        )
    case 0x06:
        return USBDescriptorMeaning(
            technicalLabel: "Still Imaging Interface",
            plainEnglish: "This is an imaging-oriented interface used by cameras, scanners, or photo-import devices."
                ,
            macBehavior: "macOS may surface it to image-capture workflows, camera utilities, or photo import tools rather than as a mounted disk.",
            uniqueness: "Imaging devices may expose both storage-like and camera-control interfaces on the same hardware.",
            tags: ["imaging", "camera"]
        )
    case 0x07:
        return USBDescriptorMeaning(
            technicalLabel: "Printer Interface",
            plainEnglish: "This interface is meant for print jobs and printer status/control traffic.",
            macBehavior: "macOS may expose it through the printing stack rather than through Finder or Disk Utility.",
            uniqueness: "Printers often show up as multi-function composite devices when scanning or faxing features are present too.",
            tags: ["printer"]
        )
    case 0x08:
        let commandSet: String
        switch subClass {
        case 0x01: commandSet = "RBC"
        case 0x02: commandSet = "MMC/ATAPI"
        case 0x03: commandSet = "QIC"
        case 0x04: commandSet = "UFI"
        case 0x05: commandSet = "SFF-8070i"
        case 0x06: commandSet = "SCSI Transparent"
        default: commandSet = "class-defined"
        }

        let technicalLabel: String
        let uniqueness: String
        var tags = ["storage"]

        switch protocolCode {
        case 0x50:
            technicalLabel = "Bulk-Only Mass Storage"
            uniqueness = "BOT is the older compatibility storage transport; it works well, but fast SSDs usually perform better over UAS."
            tags.append("bot")
        case 0x62:
            technicalLabel = "UAS Mass Storage"
            uniqueness = "UAS supports command queuing and lower overhead than BOT, which is why it is a good sign for modern SSD performance."
            tags.append("uas")
        default:
            technicalLabel = "Mass Storage Interface"
            uniqueness = "\(commandSet) describes the command set, while the protocol byte explains how those storage commands move over USB."
        }

        return USBDescriptorMeaning(
            technicalLabel: technicalLabel,
            plainEnglish: "This is the storage transport macOS uses for disks, flash media, card readers, and external storage enclosures.",
            macBehavior: "Finder, Disk Utility, backup tools, and file-copy operations talk through this interface when the device is acting like a disk.",
            uniqueness: uniqueness,
            tags: tags
        )
    case 0x09:
        let technicalLabel: String
        let uniqueness: String

        switch protocolCode {
        case 0x00:
            technicalLabel = isDeviceLevel ? "Full-Speed USB Hub" : "Hub Interface"
            uniqueness = "This is the classic hub path for older low/full-speed downstream devices."
        case 0x01:
            technicalLabel = isDeviceLevel ? "High-Speed Hub (single TT)" : "Hub Interface"
            uniqueness = "Single-TT hubs share one transaction translator for USB 2.0-era traffic, which can become a bottleneck with several slower devices attached."
        case 0x02:
            technicalLabel = isDeviceLevel ? "High-Speed Hub (multi TT)" : "Hub Interface"
            uniqueness = "Multi-TT hubs isolate low/full-speed traffic better than single-TT hubs, which can help mixed-device performance."
        default:
            technicalLabel = "USB Hub"
            uniqueness = "Hub descriptors matter because every downstream device inherits this upstream path's limits."
        }

        return USBDescriptorMeaning(
            technicalLabel: technicalLabel,
            plainEnglish: "This device fans one upstream USB connection out into multiple downstream ports.",
            macBehavior: "Anything plugged into the hub depends on this path for bandwidth, latency, and power budget.",
            uniqueness: uniqueness,
            tags: ["hub"]
        )
    case 0x0A:
        return USBDescriptorMeaning(
            technicalLabel: "CDC Data Interface",
            plainEnglish: "This is the data plane for a communications or networking USB function.",
            macBehavior: "macOS may pair it with a CDC control interface to create tethering, serial-over-USB, or network-style behavior.",
            uniqueness: "On composite devices, this often looks boring by itself because the control interface is what explains the higher-level role."
            ,
            tags: ["network", "communication"]
        )
    case 0x0B:
        return USBDescriptorMeaning(
            technicalLabel: "Smart Card Interface",
            plainEnglish: "This interface is for chip cards, security tokens, or authentication readers.",
            macBehavior: "macOS may route it into security middleware or token software rather than treating it like generic storage.",
            uniqueness: "Smart-card devices often matter more for identity/auth workflows than for bulk data transfer.",
            tags: ["security"]
        )
    case 0x0E:
        let technicalLabel: String
        let plainEnglish: String
        let uniqueness: String

        switch subClass {
        case 0x01:
            technicalLabel = "Video Control Interface"
            plainEnglish = "This is the control side of a webcam or capture device, where formats, camera controls, and streaming setup are described."
            uniqueness = "Video devices usually expose a separate streaming interface that actually carries the pixels."
        case 0x02:
            technicalLabel = "Video Streaming Interface"
            plainEnglish = "This interface carries the live video stream for a webcam, camera, or capture device."
            uniqueness = "Alternate settings often control how much USB bandwidth the video stream is allowed to consume."
        default:
            technicalLabel = "USB Video Interface"
            plainEnglish = "This is part of a video-oriented USB device such as a webcam or capture path."
            uniqueness = "Video gear often splits control and streaming across separate interfaces."
        }

        return USBDescriptorMeaning(
            technicalLabel: technicalLabel,
            plainEnglish: plainEnglish,
            macBehavior: "macOS will typically surface this to camera, conferencing, or capture apps rather than to Finder.",
            uniqueness: uniqueness,
            tags: ["video", "camera"]
        )
    case 0x0F:
        return USBDescriptorMeaning(
            technicalLabel: "Personal Healthcare Interface",
            plainEnglish: "This interface is intended for healthcare or biometric-style device traffic.",
            macBehavior: "Whether it is usable on macOS depends heavily on the vendor software and the exact device class implementation.",
            uniqueness: "Healthcare-class USB gear often carries specialized, standards-based data rather than everyday consumer traffic."
            ,
            tags: ["health"]
        )
    case 0x10:
        return USBDescriptorMeaning(
            technicalLabel: "Audio/Video Interface",
            plainEnglish: "This interface is part of a device that combines audio and video behavior under the USB AV class model.",
            macBehavior: "macOS will usually treat it like conferencing, capture, or media-routing hardware rather than like storage.",
            uniqueness: "It is effectively a media-oriented composite role even if the device does not present as a classic composite class at the top level."
            ,
            tags: ["audio", "video"]
        )
    case 0x11:
        return USBDescriptorMeaning(
            technicalLabel: "USB-C Billboard Device",
            plainEnglish: "A billboard device mostly exists to report USB-C capability or alternate-mode failure/status rather than to move everyday user data.",
            macBehavior: "You often see this on docks, adapters, and displays that want to tell the host something about DisplayPort Alt Mode or USB-C negotiation.",
            uniqueness: "Billboard devices are gold for troubleshooting odd USB-C behavior because they can surface why a mode did not come up."
            ,
            tags: ["usb-c", "billboard"]
        )
    case 0x12:
        return USBDescriptorMeaning(
            technicalLabel: "USB Type-C Bridge Interface",
            plainEnglish: "This is a bridge/control path used by USB-C or alternate-mode infrastructure inside a dock, retimer, or adapter.",
            macBehavior: "macOS usually treats this as plumbing rather than as something you interact with directly.",
            uniqueness: "You care about it when you are debugging docks, muxes, cable behavior, or Type-C mode switching."
            ,
            tags: ["usb-c", "bridge"]
        )
    case 0xDC:
        return USBDescriptorMeaning(
            technicalLabel: "Diagnostic / Debug Interface",
            plainEnglish: "This interface exists for tracing, debug, compliance, or design-for-test workflows rather than for normal end-user features.",
            macBehavior: "Unless you are using a development or validation toolchain, macOS may simply expose the raw endpoint without a friendly consumer role.",
            uniqueness: "These interfaces are intentionally technical and are often only meaningful to firmware, silicon, or manufacturing tools."
            ,
            tags: ["diagnostic"]
        )
    case 0xE0:
        let technicalLabel: String
        let plainEnglish: String
        let uniqueness: String
        var tags = ["wireless"]

        switch (subClass, protocolCode) {
        case (0x01, 0x01):
            technicalLabel = "Bluetooth Controller Interface"
            plainEnglish = "This is the USB transport path for a Bluetooth radio/controller."
            uniqueness = "Bluetooth-over-USB often appears on internal combo radios and some external dongles."
            tags.append("bluetooth")
        default:
            technicalLabel = "Wireless Controller Interface"
            plainEnglish = "This is a wireless-control interface rather than a generic storage or input endpoint."
            uniqueness = "Wireless controller classes are infrastructure-oriented and often back another user-facing feature such as Bluetooth or tethering."
        }

        return USBDescriptorMeaning(
            technicalLabel: technicalLabel,
            plainEnglish: plainEnglish,
            macBehavior: "macOS will route this into the wireless stack rather than exposing it as a file-oriented device.",
            uniqueness: uniqueness,
            tags: tags
        )
    case 0xEF:
        return USBDescriptorMeaning(
            technicalLabel: "Miscellaneous USB Interface",
            plainEnglish: "This class bucket is used for a grab bag of standards that do not fit the older core USB classes cleanly.",
            macBehavior: "The exact behavior depends heavily on the subclass/protocol pair and can range from tethering to interface association metadata.",
            uniqueness: "When a device lands here, the subclass/protocol bytes usually matter more than the base class name itself.",
            tags: ["misc"]
        )
    case 0xFE:
        if subClass == 0x01 && protocolCode == 0x01 {
            return USBDescriptorMeaning(
                technicalLabel: "Device Firmware Update (DFU)",
                plainEnglish: "This interface exists for firmware flashing, recovery, or low-level maintenance rather than for the device's normal runtime job.",
                macBehavior: "You usually see DFU only during update, restore, or rescue workflows.",
                uniqueness: "It is common on dev boards, instruments, and embedded products that need field-updatable firmware.",
                tags: ["firmware", "recovery"]
            )
        }

        return USBDescriptorMeaning(
            technicalLabel: "Application-Specific Interface",
            plainEnglish: "This interface follows an application-focused USB spec rather than the classic consumer classes like storage or HID.",
            macBehavior: "macOS may need an app, framework, or domain-specific driver to make real use of it.",
            uniqueness: "Application-specific interfaces are common in lab gear, firmware tools, and specialist hardware."
            ,
            tags: ["application-specific"]
        )
    case 0xFF:
        return USBDescriptorMeaning(
            technicalLabel: "Vendor-Specific Interface",
            plainEnglish: "The vendor is using a private protocol instead of a standard USB class definition.",
            macBehavior: "macOS can see the endpoint, but meaningful behavior often depends on vendor software, a DriverKit extension, or a custom utility.",
            uniqueness: "This is where the raw IDs, names, and driver owner matter most because the class bytes intentionally stop helping."
            ,
            tags: ["vendor-specific"]
        )
    default:
        return USBDescriptorMeaning(
            technicalLabel: "USB Class \(hexByte(classCode))",
            plainEnglish: "This is a less common USB class that the app does not have a richer local translation for yet.",
            macBehavior: "The raw class, subclass, and protocol bytes are still shown so you can reason about it precisely.",
            uniqueness: "Rare USB classes often make sense only in the context of a particular industry spec or vendor product line.",
            tags: ["other"]
        )
    }
}

private func productCategoryHint(vendorID: Int, vendorName: String, productName: String, meaning: USBDescriptorMeaning, isHub: Bool) -> String? {
    if stringContainsAny(productName, fragments: ["portable ssd", "pssd", "ssd", "nvme"]) {
        return stringContainsAny(productName, fragments: ["nvme"]) ? "External NVMe / SSD storage" : "Portable SSD"
    }

    if stringContainsAny(productName, fragments: ["hard drive", "desktop drive", "portable drive", "hdd", "disk"]) {
        return "External hard drive"
    }

    if stringContainsAny(productName, fragments: ["card reader", "sd reader", "micro sd", "cfexpress", "compactflash"]) {
        return "Card reader"
    }

    if stringContainsAny(productName, fragments: ["dock", "docking"]) {
        return "USB dock"
    }

    if isHub || stringContainsAny(productName, fragments: ["hub"]) {
        return "USB hub"
    }

    if stringContainsAny(productName, fragments: ["ethernet", "lan", "gigabit", "2.5gbe", "5gbe", "10gbe"]) {
        return "USB network adapter"
    }

    if stringContainsAny(productName, fragments: ["keyboard"]) {
        return "Keyboard"
    }

    if stringContainsAny(productName, fragments: ["mouse", "trackpad", "trackball"]) {
        return "Mouse / pointing device"
    }

    if stringContainsAny(productName, fragments: ["receiver", "unifying", "bolt receiver", "dongle"]) && meaning.tags.contains(where: { ["hid", "input"].contains($0) }) {
        return "Input receiver"
    }

    if stringContainsAny(productName, fragments: ["camera", "webcam", "capture", "cam", "facetime"]) {
        return "Camera / capture device"
    }

    if stringContainsAny(productName, fragments: ["mic", "microphone", "headset", "speaker", "dac", "audio"]) {
        return "Audio device"
    }

    if stringContainsAny(productName, fragments: ["bluetooth", "bt"]) {
        return "Bluetooth adapter"
    }

    if stringContainsAny(productName, fragments: ["phone", "iphone", "ipad", "pixel", "android"]) {
        return "Phone / tablet connection"
    }

    if meaning.tags.contains("storage") { return "Storage device" }
    if meaning.tags.contains("hub") { return "USB hub" }
    if meaning.tags.contains("video") { return "Video device" }
    if meaning.tags.contains("audio") { return "Audio device" }
    if meaning.tags.contains("network") { return "Network adapter" }
    if meaning.tags.contains("bluetooth") { return "Bluetooth adapter" }
    if meaning.tags.contains(where: { ["hid", "input"].contains($0) }) { return "Input device" }
    if meaning.tags.contains("usb-c") || meaning.tags.contains("billboard") { return "USB-C infrastructure device" }
    if meaning.tags.contains("firmware") { return "Firmware / recovery interface" }
    if meaning.tags.contains("vendor-specific") { return "Vendor-specific accessory" }

    let normalizedVendorName = normalizedLookupToken(vendorName)
    if vendorID == 0x04E8 || normalizedVendorName.contains("samsung") {
        if stringContainsAny(productName, fragments: ["t5", "t7", "t9"]) {
            return "Samsung portable SSD"
        }
    }

    return nil
}

private func specificProductHint(vendorID: Int, vendorName: String, productName: String) -> String? {
    let normalizedVendorName = normalizedLookupToken(vendorName)

    if (vendorID == 0x04E8 || normalizedVendorName.contains("samsung")) && stringContainsAny(productName, fragments: ["pssd", "t5", "t7", "t9"]) {
        return "Samsung's T-series portable SSDs normally expose standard USB mass-storage interfaces, so the protocol choice here tells you more than any Samsung-specific driver would."
    }

    if stringContainsAny(productName, fragments: ["unifying", "bolt receiver"]) {
        return "This looks like a small receiver that can multiplex several wireless input devices behind one USB plug."
    }

    if stringContainsAny(productName, fragments: ["card reader"]) {
        return "Card readers often look like generic mass storage even though the removable media behind them can change completely from one moment to the next."
    }

    if stringContainsAny(productName, fragments: ["dock", "hub"]) {
        return "Docks and hubs often bundle networking, storage bridges, video plumbing, and USB-C control paths into one composite shell."
    }

    if stringContainsAny(productName, fragments: ["facetime"]) {
        return "This is likely an internal Apple camera path rather than a removable webcam."
    }

    return nil
}

private func interfaceOwnerExplanation(_ owner: String) -> String? {
    let normalizedOwner = normalizedLookupToken(owner)
    guard !normalizedOwner.isEmpty else { return nil }

    if normalizedOwner.contains("massstorage") {
        return "macOS handed this interface to its mass-storage stack, so this is the path your file system and Disk Utility depend on."
    }

    if normalizedOwner.contains("audio") {
        return "macOS attached its audio stack here, so this interface is participating in sound input/output rather than general data transfer."
    }

    if normalizedOwner.contains("bluetooth") {
        return "macOS attached its Bluetooth stack here, which means this interface is acting as radio transport rather than a user-facing USB endpoint."
    }

    if normalizedOwner.contains("hid") {
        return "macOS attached the HID stack here, so the interface is being treated as input hardware."
    }

    if normalizedOwner.contains("cdc") || normalizedOwner.contains("network") {
        return "macOS is treating this interface as communication/network plumbing instead of a normal file or input device."
    }

    return "macOS currently shows this interface as owned by \(owner)."
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

private func int64Value(_ value: Any?) -> Int64? {
    if let int = value as? Int64 { return int }
    if let int = value as? Int { return Int64(int) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func uint32Value(_ value: Any?) -> UInt32? {
    if let number = value as? NSNumber { return number.uint32Value }
    if let int = value as? Int { return UInt32(int) }
    if let string = value as? String, let int = UInt32(string) { return int }
    return nil
}

private func uint64Value(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let int = value as? Int { return UInt64(int) }
    if let string = value as? String, let int = UInt64(string) { return int }
    return nil
}

private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String { return NSString(string: string).boolValue }
    return nil
}

private func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func firstInt(in properties: [String: Any], keys: [String]) -> Int? {
    for key in keys {
        if let value = intValue(properties[key]) { return value }
    }
    return nil
}

private func firstUInt32(in properties: [String: Any], keys: [String]) -> UInt32? {
    for key in keys {
        if let value = uint32Value(properties[key]) { return value }
    }
    return nil
}

private func firstUInt64(in properties: [String: Any], keys: [String]) -> UInt64? {
    for key in keys {
        if let value = uint64Value(properties[key]) { return value }
    }
    return nil
}

private func firstBool(in properties: [String: Any], keys: [String]) -> Bool? {
    for key in keys {
        if let value = boolValue(properties[key]) { return value }
    }
    return nil
}

private func firstString(in properties: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = stringValue(properties[key]), !value.isEmpty { return value }
    }
    return nil
}

private func rawPropertyStrings(from properties: [String: Any]) -> [String: String] {
    properties.compactMapValues { value -> String? in
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = value as? Data, data.count < 128 {
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        if let array = value as? [Any] {
            return array.map { "\($0)" }.joined(separator: ", ")
        }
        if value is NSDictionary || value is [String: Any] { return nil }
        return String(describing: value)
    }
}

private func normalizedDescriptorPowerMilliamps(rawValue: Int, bcdUSB: Int) -> Int {
    guard rawValue > 0 else { return 0 }
    return bcdUSB >= 0x300 ? rawValue * 8 : rawValue * 2
}

private func formatBitsPerSecond(_ bitsPerSecond: Int64) -> String {
    guard bitsPerSecond > 0 else { return "Unknown" }

    let units: [(threshold: Double, suffix: String)] = [
        (1_000_000_000, "Gbps"),
        (1_000_000, "Mbps"),
        (1_000, "Kbps")
    ]

    let value = Double(bitsPerSecond)
    for unit in units where value >= unit.threshold {
        let scaled = value / unit.threshold
        if abs(scaled.rounded() - scaled) < 0.05 {
            return "\(Int(scaled.rounded())) \(unit.suffix)"
        }
        return String(format: "%.1f %@", scaled, unit.suffix)
    }

    return "\(bitsPerSecond) bps"
}

// MARK: - USB Interface Model
struct USBInterfaceInfo: Identifiable, Hashable {
    let interfaceNumber: Int
    let alternateSetting: Int
    let interfaceClass: Int
    let interfaceSubClass: Int
    let interfaceProtocol: Int
    let endpointCount: Int
    let exclusiveOwner: String
    let speed: USBSpeed
    let rawProperties: [String: String]

    var id: String {
        "\(interfaceNumber)-\(alternateSetting)-\(interfaceClass)-\(interfaceSubClass)-\(interfaceProtocol)"
    }

    var classInfo: (name: String, description: String, icon: String, layman: String) {
        usbClassDescriptions[interfaceClass] ?? ("Unknown Interface", "Unrecognized interface class", "questionmark.circle", "macOS exposed this interface, but its function isn't obvious")
    }

    var meaning: USBDescriptorMeaning {
        descriptorMeaningFor(classCode: interfaceClass, subClass: interfaceSubClass, protocolCode: interfaceProtocol, isDeviceLevel: false)
    }

    var technicalSignature: String {
        "Class \(hexByte(interfaceClass)) • Subclass \(hexByte(interfaceSubClass)) • Protocol \(hexByte(interfaceProtocol))"
    }

    var ownerExplanation: String? {
        interfaceOwnerExplanation(exclusiveOwner)
    }

    var summary: String {
        var parts = ["Interface \(interfaceNumber)"]
        if endpointCount > 0 {
            parts.append("\(endpointCount) endpoints")
        }
        if speed != .unknown {
            parts.append(speed.shortDescription)
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - USB Controller Model
struct USBController: Identifiable, Hashable {
    let id: String
    let name: String
    let className: String
    let locationID: UInt32
    let busPowerAvailable: Int
    let isBuiltIn: Bool
    let controllerType: String
    let pciInfo: String
    let supportsUSB3: Bool
    let rawProperties: [String: String]

    var powerDescription: String {
        if busPowerAvailable > 0 {
            return "\(busPowerAvailable) mA available (\(Double(busPowerAvailable) * 5.0 / 1000.0) W @ 5V)"
        }
        return "Bus powered"
    }

    var displayName: String {
        if name.hasPrefix("AppleUSB") || name.hasPrefix("IOUSB") {
            if isBuiltIn {
                return supportsUSB3 ? "Built-in USB 3 Controller" : "Built-in USB 2 Controller"
            }
            return controllerType
        }
        return name
    }

    var technicalNameDescription: String? {
        displayName == name ? nil : name
    }

    var usageSummary: String {
        if supportsUSB3 {
            return "Use this view when you want to see which ports, hubs, and devices are sharing the same high-speed USB controller."
        }
        return "Use this view when something feels slow and you want to confirm it landed on an older USB 2-era controller path."
    }
}

// MARK: - Thunderbolt Device Model
struct ThunderboltDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let vendorName: String
    let deviceName: String
    let uid: String
    let routeString: String
    let linkSpeed: Int // Gbps
    let linkWidth: Int
    let generation: Int
    let isConnected: Bool
    let rawProperties: [String: String]

    var generationString: String {
        switch generation {
        case 1: return "Thunderbolt 1"
        case 2: return "Thunderbolt 2"
        case 3: return "Thunderbolt 3"
        case 4: return "Thunderbolt 4"
        case 5: return "Thunderbolt 5"
        default: return "Thunderbolt"
        }
    }

    var speedDescription: String {
        if linkSpeed > 0 {
            return "\(linkSpeed) Gbps × \(linkWidth) lanes"
        }
        switch generation {
        case 1: return "10 Gbps (bi-directional)"
        case 2: return "20 Gbps (bi-directional)"
        case 3, 4: return "40 Gbps (bi-directional)"
        case 5: return "80-120 Gbps (bi-directional)"
        default: return "Unknown"
        }
    }

    var color: Color {
        switch generation {
        case 1, 2: return .blue
        case 3: return .purple
        case 4: return .indigo
        case 5: return .pink
        default: return .gray
        }
    }

    private var normalizedRegistryName: String {
        normalizedLookupToken(name)
    }

    var isPortEntry: Bool {
        normalizedRegistryName.contains("iothunderboltport") || name.contains("Port@")
    }

    var isSwitchEntry: Bool {
        normalizedRegistryName.contains("switch")
    }

    var portNumber: Int? {
        guard isPortEntry, let suffix = name.split(separator: "@").last else { return nil }
        return Int(suffix)
    }

    var displayName: String {
        if isPortEntry, let portNumber {
            return "Thunderbolt Port \(portNumber)"
        }

        if !deviceName.isEmpty && deviceName != name {
            if !vendorName.isEmpty && !normalizedLookupToken(deviceName).contains(normalizedLookupToken(vendorName)) {
                return "\(vendorName) \(deviceName)"
            }
            return deviceName
        }

        if isSwitchEntry {
            return routeString == "0" ? "Built-in Thunderbolt Router" : "Thunderbolt Switch"
        }

        return name
    }

    var roleTitle: String {
        if isPortEntry {
            return "Port on this Mac"
        }
        if isSwitchEntry {
            return routeString == "0" ? "Routing node inside the Mac" : "Thunderbolt routing / switch node"
        }
        return "Connected Thunderbolt-side device"
    }

    var userFacingSubtitle: String {
        orderedUniqueStrings([roleTitle, generationString, vendorName]).joined(separator: " • ")
    }

    var howToUseSummary: String {
        if isPortEntry {
            return "This is a Thunderbolt-capable port path on the Mac. Open it when you need to trace which Thunderbolt route a dock, display, or SSD is using."
        }
        if isSwitchEntry {
            return "This is Thunderbolt plumbing rather than a Finder-visible device. It matters when you are diagnosing docks, display chains, cable paths, or routing weirdness."
        }
        return "This is the Thunderbolt-side endpoint or routed device entry. Use it to reason about connection status and bandwidth for docks, displays, and top-end external storage."
    }

    var whenToIgnoreSummary: String? {
        if isPortEntry {
            return "You can usually ignore this if everything works. It becomes useful when you are tracing a cable/port path or comparing routes."
        }
        if isSwitchEntry {
            return "You can usually ignore this if you are just looking for files or normal removable devices. It is mainly for advanced path diagnosis."
        }
        return nil
    }

    var checklist: [String] {
        if isPortEntry {
            return [
                "Use this to answer which Thunderbolt-capable port or lane a dock or display chain is actually using.",
                "If a dock or SSD feels off, compare the reported link speed here with what you expected.",
                "This is infrastructure, not a Finder-visible disk or app-level peripheral."
            ]
        }

        if isSwitchEntry {
            return [
                "Think of this as traffic plumbing inside the Mac, dock, or routed Thunderbolt path.",
                "Open this when you need to trace a dock, display chain, or cable path rather than a normal USB storage device.",
                "If you are looking for something to eject or open in Finder, this usually is not the entry you want."
            ]
        }

        return [
            "Use this for docks, displays, capture gear, and high-end Thunderbolt storage rather than normal USB flash drives.",
            "Current link speed is the first thing to check if performance feels lower than expected.",
            "If this looks disconnected or weird, suspect the cable, dock power, adapter chain, or downstream device."
        ]
    }
}

struct USBPowerDetails: Hashable {
    let reportedDeviceCurrentMilliamps: Int
    let sinkAllocationMilliamps: Int
    let wakePortCurrentLimitMilliamps: Int
    let sleepPortCurrentLimitMilliamps: Int
    let hubPowerSupplyMilliamps: Int
    let usbPortTypeCode: Int?
    let usbBusCurrentPoolID: UInt64
    let overCurrentEventCount: Int
    let powerRegistryFacts: [String]
}

// MARK: - USB Device Model
struct USBDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let vendorID: Int
    let productID: Int
    let vendorName: String
    let productName: String
    let serialNumber: String
    let speed: USBSpeed
    let deviceClass: Int
    let deviceSubClass: Int
    let deviceProtocol: Int
    let maxPower: Int
    let descriptorMaxPowerMilliamps: Int
    let usbVersion: String
    let bcdUSB: Int
    let locationID: UInt32
    let isHub: Bool
    let portCount: Int

    // Extended properties
    let bcdDevice: Int
    let currentAvailable: Int
    let extraCurrentInSleep: Int
    let busPowerAvailable: Int
    let isCaptive: Bool
    let isInternal: Bool
    let sleepCurrent: Int
    let sessionID: UInt64
    let currentConfiguration: Int
    let linkSpeedBitsPerSecond: Int64
    let portType: String
    let powerDetails: USBPowerDetails
    let parentControllerName: String
    let interfaces: [USBInterfaceInfo]
    let rawProperties: [String: String]
    var storageVolumes: [StorageVolumeInfo] = []

    var vendorIDHex: String { String(format: "0x%04X", vendorID) }
    var productIDHex: String { String(format: "0x%04X", productID) }
    var negotiatedSpeedDescription: String {
        if linkSpeedBitsPerSecond > 0 {
            return formatBitsPerSecond(linkSpeedBitsPerSecond)
        }
        return speed.shortDescription
    }

    var logName: String {
        if !serialNumber.isEmpty {
            return "\(name) [\(serialNumber)]"
        }
        return name
    }

    var isCompositeDevice: Bool {
        deviceClass == 0 && interfaces.count > 1
    }

    var effectiveClass: Int {
        if deviceClass != 0 {
            return deviceClass
        }

        let interfaceClasses = Set(interfaces.map(\.interfaceClass).filter { $0 != 0 })
        if interfaceClasses.count == 1, let interfaceClass = interfaceClasses.first {
            return interfaceClass
        }

        if !interfaces.isEmpty {
            return 0
        }

        return -1
    }

    var classSource: String {
        if deviceClass != 0 {
            return "From the device descriptor"
        }
        if interfaces.isEmpty {
            return "Composite device with no interface descriptors exposed"
        }
        let uniqueClasses = Set(interfaces.map(\.interfaceClass).filter { $0 != 0 })
        if uniqueClasses.count == 1 {
            return "Derived from interface descriptors"
        }
        return "Composite device exposing multiple interface types"
    }

    var isPerformanceLimited: Bool {
        bcdUSB >= 0x300 && (speed == .low || speed == .full || speed == .high)
    }

    var performanceDiscrepancyReason: String? {
        guard isPerformanceLimited else { return nil }
        return "Advertises USB \(usbVersion) capability but negotiated at \(negotiatedSpeedDescription) (cable, hub, or port bottleneck)."
    }

    var vendorProfile: USBVendorProfile? {
        lookupVendorProfile(vendorID: vendorID, vendorName: vendorName)
    }

    var productCatalogEntry: USBProductCatalogEntry? {
        lookupProductCatalogEntry(vendorID: vendorID, vendorName: vendorName, productName: productName.isEmpty ? name : productName)
    }

    var vendorDisplayName: String {
        if !vendorName.isEmpty { return vendorName }
        return vendorProfile?.canonicalName ?? ""
    }

    var controllerGroupName: String {
        parentControllerName.isEmpty ? "Unattributed USB Path" : parentControllerName
    }

    var portPathComponents: [Int] {
        var path: [Int] = []
        var loc = locationID >> 20
        while loc > 0 {
            let port = Int(loc & 0xF)
            if port > 0 {
                path.append(port)
            }
            loc >>= 4
        }
        return path.reversed()
    }

    var depthInTopology: Int {
        portPathComponents.count
    }

    var mountedVolumes: [StorageVolumeInfo] {
        storageVolumes.filter(\.isMounted)
    }

    var wholeDiskVolumes: [StorageVolumeInfo] {
        storageVolumes.filter(\.isWholeDisk)
    }

    var sortedStorageVolumes: [StorageVolumeInfo] {
        storageVolumes.sorted {
            if $0.wholeDiskBSDName != $1.wholeDiskBSDName {
                return $0.wholeDiskBSDName.localizedCaseInsensitiveCompare($1.wholeDiskBSDName) == .orderedAscending
            }
            if $0.isWholeDisk != $1.isWholeDisk {
                return $0.isWholeDisk && !$1.isWholeDisk
            }
            if $0.isMounted != $1.isMounted {
                return $0.isMounted && !$1.isMounted
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var volumeSummary: String {
        let mountedCount = mountedVolumes.count
        if mountedCount == 0 {
            if !storageVolumes.isEmpty {
                return "\(storageVolumes.count) disk objects found"
            }
            return "No Finder volumes mapped"
        }
        if mountedCount == 1, let volume = mountedVolumes.first {
            return volume.displayName
        }
        return "\(mountedCount) mounted volumes"
    }

    var primaryMeaning: USBDescriptorMeaning {
        if deviceClass == 0 {
            if interfaces.count == 1, let interface = interfaces.first {
                return interface.meaning
            }

            if interfaces.count > 1 {
                return descriptorMeaningFor(classCode: 0, subClass: 0, protocolCode: 0, isDeviceLevel: true)
            }
        }

        return descriptorMeaningFor(classCode: effectiveClass, subClass: deviceSubClass, protocolCode: deviceProtocol, isDeviceLevel: true)
    }

    var functionLabels: [String] {
        let labels = interfaces.map { $0.meaning.technicalLabel.replacingOccurrences(of: " Interface", with: "") }
        if !labels.isEmpty {
            return orderedUniqueStrings(labels)
        }

        return orderedUniqueStrings([primaryMeaning.technicalLabel.replacingOccurrences(of: " Interface", with: "")])
    }

    var translatedCategory: String {
        if let catalogCategory = productCatalogEntry?.category {
            return catalogCategory
        }

        if let hint = productCategoryHint(vendorID: vendorID, vendorName: vendorName, productName: productName.isEmpty ? name : productName, meaning: primaryMeaning, isHub: isHub) {
            return hint
        }

        if isCompositeDevice {
            return "Multi-function USB device"
        }

        return primaryMeaning.technicalLabel
    }

    var translationHeadline: String {
        if isCompositeDevice {
            let functionSummary = naturalLanguageList(Array(functionLabels.prefix(3)))
            if !functionSummary.isEmpty {
                return "Multi-function device: \(functionSummary)"
            }
        }

        return translatedCategory
    }

    var rowSubtitle: String {
        var parts: [String] = []

        if !vendorDisplayName.isEmpty {
            parts.append(vendorDisplayName)
        }

        parts.append(translatedCategory)

        if isCompositeDevice {
            let functionSummary = naturalLanguageList(Array(functionLabels.prefix(2)))
            if !functionSummary.isEmpty {
                parts.append(functionSummary)
            }
        } else if primaryMeaning.technicalLabel != translatedCategory {
            parts.append(primaryMeaning.technicalLabel)
        }

        if !mountedVolumes.isEmpty {
            parts.append(volumeSummary)
        }

        return orderedUniqueStrings(parts).joined(separator: " • ")
    }

    var translationSummary: String {
        var sentences: [String] = []
        let productLabel = productName.isEmpty ? name : productName

        if !productLabel.isEmpty && productLabel != translatedCategory {
            sentences.append("macOS identifies this device as “\(productLabel)”.")
        }

        if isCompositeDevice {
            let functionSummary = naturalLanguageList(functionLabels)
            if !functionSummary.isEmpty {
                sentences.append("This one physical USB address exposes \(interfaces.count) separate interfaces that together look like \(functionSummary).")
            } else {
                sentences.append("This one physical USB address exposes \(interfaces.count) separate interfaces.")
            }
            sentences.append("Because the top-level device class is interface-defined, the interface breakdown below is more trustworthy than the device-class byte alone.")
        } else {
            sentences.append(primaryMeaning.plainEnglish)
            sentences.append(primaryMeaning.macBehavior)
        }

        if isPerformanceLimited {
            sentences.append("It advertises USB \(usbVersion), but the current connection negotiated at only \(negotiatedSpeedDescription).")
        }

        if !mountedVolumes.isEmpty {
            let volumeNames = naturalLanguageList(mountedVolumes.map(\.displayName))
            if !volumeNames.isEmpty {
                sentences.append("Finder currently maps this device to \(volumeNames).")
            }
        }

        return sentences.joined(separator: " ")
    }

    var vendorContext: String? {
        let productHint = specificProductHint(vendorID: vendorID, vendorName: vendorName, productName: productName.isEmpty ? name : productName)

        if let productCatalogEntry {
            var parts = [productCatalogEntry.summary]
            if let vendorProfile {
                parts.append(vendorProfile.companySummary)
                parts.append(vendorProfile.usbContext)
            }
            if let productHint {
                parts.append(productHint)
            }
            return orderedUniqueStrings(parts).joined(separator: " ")
        }

        if let vendorProfile {
            if let productHint {
                return "\(vendorProfile.companySummary) \(vendorProfile.usbContext) \(productHint)"
            }
            return "\(vendorProfile.companySummary) \(vendorProfile.usbContext)"
        }

        return productHint
    }

    var userFacingBehaviors: [String] {
        let tagSet = Set(interfaces.flatMap { $0.meaning.tags } + primaryMeaning.tags)
        var behaviors: [String] = []

        if isCompositeDevice {
            behaviors.append("macOS can split this one physical accessory into several logical interfaces, each with its own driver and purpose.")
        }
        if tagSet.contains("storage") {
            behaviors.append("Should behave like external storage in Finder, Disk Utility, backup tools, or file-copy workflows.")
        }
        if tagSet.contains("audio") {
            behaviors.append("Should show up in Sound settings or pro-audio apps as audio input/output or MIDI-related hardware.")
        }
        if tagSet.contains("video") || tagSet.contains("camera") {
            behaviors.append("Should appear to camera, conferencing, or capture apps as a video source instead of as a disk.")
        }
        if tagSet.contains("network") || tagSet.contains("communication") {
            behaviors.append("May create a network/tethering-style interface in macOS instead of a Finder-visible device.")
        }
        if tagSet.contains("hid") || tagSet.contains("input") {
            behaviors.append("Feeds input events into macOS rather than exposing a filesystem or media volume.")
        }
        if tagSet.contains("bluetooth") {
            behaviors.append("Acts as transport for the Bluetooth stack rather than as a user-facing USB app/device on its own.")
        }
        if tagSet.contains("hub") {
            behaviors.append("Everything plugged downstream shares this upstream path's speed, latency, and power constraints.")
        }
        if tagSet.contains("usb-c") || tagSet.contains("billboard") {
            behaviors.append("Mostly exists to describe USB-C or alternate-mode capability state, not to move normal user data.")
        }
        if tagSet.contains("firmware") || tagSet.contains("recovery") {
            behaviors.append("Mostly matters during firmware update, restore, or maintenance workflows.")
        }
        if tagSet.contains("vendor-specific") {
            behaviors.append("May require a vendor app, DriverKit extension, or specialist utility before it becomes useful.")
        }
        if !mountedVolumes.isEmpty {
            behaviors.append("Finder currently maps this USB device to \(volumeSummary), so you can tell which mounted storage falls under this physical device.")
        }

        if behaviors.isEmpty {
            behaviors.append(primaryMeaning.macBehavior)
        }

        return orderedUniqueStrings(behaviors)
    }

    var translatedHighlights: [String] {
        var highlights: [String] = []

        if let productHint = specificProductHint(vendorID: vendorID, vendorName: vendorName, productName: productName.isEmpty ? name : productName) {
            highlights.append(productHint)
        }

        if let productCatalogEntry {
            highlights.append(contentsOf: productCatalogEntry.highlights)
        }

        if isCompositeDevice {
            let functionSummary = naturalLanguageList(functionLabels)
            if !functionSummary.isEmpty {
                highlights.append("Interface mix: \(functionSummary).")
            }
        } else {
            highlights.append(primaryMeaning.uniqueness)
        }

        if let ownerExplanation = interfaces.compactMap(\.ownerExplanation).first {
            highlights.append(ownerExplanation)
        }

        if interfaces.contains(where: { $0.meaning.tags.contains("uas") }) {
            highlights.append("This device is speaking UAS, the newer queued USB storage transport favored by faster SSDs and enclosures.")
        }

        if interfaces.contains(where: { $0.meaning.tags.contains("bot") }) {
            highlights.append("This device is using BOT, the older compatibility storage transport, rather than UAS.")
        }

        if isPerformanceLimited {
            highlights.append("Performance note: the descriptors advertise USB \(usbVersion), but this link is currently only \(negotiatedSpeedDescription).")
        }

        if descriptorMaxPowerMilliamps > 0 {
            if maxPower > 0 && descriptorMaxPowerMilliamps != maxPower {
                highlights.append("Power note: the descriptor asks for \(descriptorMaxPowerMilliamps) mA, and macOS negotiated \(maxPower) mA.")
            } else {
                highlights.append("Power note: the descriptor asks for \(descriptorMaxPowerMilliamps) mA.")
            }
        }

        if !mountedVolumes.isEmpty {
            highlights.append("Volume map: \(naturalLanguageList(mountedVolumes.map(\.displayName)))")
        }

        return orderedUniqueStrings(highlights)
    }

    var translationBadges: [String] {
        var badges = [translatedCategory]

        if let productCatalogEntry {
            badges.append(contentsOf: productCatalogEntry.badges)
        }

        if isCompositeDevice {
            badges.append("Composite")
        } else if primaryMeaning.technicalLabel != translatedCategory {
            badges.append(primaryMeaning.technicalLabel.replacingOccurrences(of: " Interface", with: ""))
        }

        if interfaces.contains(where: { $0.meaning.tags.contains("uas") }) {
            badges.append("UAS")
        }
        if interfaces.contains(where: { $0.meaning.tags.contains("bot") }) {
            badges.append("BOT")
        }
        if interfaces.contains(where: { $0.meaning.tags.contains("bluetooth") }) {
            badges.append("Bluetooth")
        }
        if interfaces.contains(where: { $0.meaning.tags.contains("midi") }) {
            badges.append("MIDI")
        }
        if !mountedVolumes.isEmpty {
            badges.append("Finder-mapped")
        }

        badges.append(negotiatedSpeedDescription)
        return orderedUniqueStrings(badges)
    }

    var translationSearchText: String {
        let volumeTerms = storageVolumes.flatMap { [$0.displayName, $0.mountPath, $0.bsdName, $0.wholeDiskBSDName] }
        return ([rowSubtitle, translationHeadline, translationSummary, vendorContext ?? ""] + userFacingBehaviors + translatedHighlights + functionLabels + volumeTerms).joined(separator: " ")
    }

    var bcdDeviceString: String {
        if bcdDevice > 0 {
            let major = (bcdDevice >> 8) & 0xFF
            let minor = (bcdDevice >> 4) & 0x0F
            let patch = bcdDevice & 0x0F
            return "\(major).\(minor)\(patch > 0 ? ".\(patch)" : "")"
        }
        return "N/A"
    }

    var powerDescription: String {
        if maxPower > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(maxPower)) negotiated budget"
        }
        return "N/A"
    }

    var descriptorPowerDescription: String {
        if descriptorMaxPowerMilliamps > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(descriptorMaxPowerMilliamps)) requested in descriptor"
        }
        return "Not reported"
    }

    var powerAvailableDescription: String {
        if busPowerAvailable > 0 {
            return formatUSBPowerAssumingFiveVolts(busPowerAvailable)
        } else if currentAvailable > 0 {
            return formatUSBPowerAssumingFiveVolts(currentAvailable)
        }
        return "Standard bus power"
    }

    var bestAvailableAwakeCurrentMilliamps: Int {
        [busPowerAvailable, currentAvailable, powerDetails.wakePortCurrentLimitMilliamps].max() ?? 0
    }

    var powerNegotiationSummary: String {
        if powerDetails.sinkAllocationMilliamps > 0 {
            return "macOS published UsbPowerSinkAllocation for this path, so the current budget shown here is closer to a negotiated sink allowance than a plain descriptor request."
        }
        if powerDetails.reportedDeviceCurrentMilliamps > 0 {
            return "macOS published a device current value for this path, but not a richer sink-allocation contract."
        }
        if descriptorMaxPowerMilliamps > 0 {
            return "macOS only exposed the descriptor-requested current here, so this is more of a requested ceiling than a fully explained negotiated contract."
        }
        return "macOS did not publish a clear current budget for this device path."
    }

    var pdVisibilitySummary: String {
        let normalizedFacts = powerDetails.powerRegistryFacts.map(normalizedLookupToken)
        let hasExplicitVoltageOrPDKey = normalizedFacts.contains {
            $0.contains("voltage") || $0.contains("pdo") || $0.contains("pd ") || $0.contains("pd=") || $0.contains("typec")
        }

        if hasExplicitVoltageOrPDKey {
            return "macOS exposed some PD- or Type-C-adjacent registry keys on this path, but not a clean public USB PD contract object."
        }

        if powerDetails.sinkAllocationMilliamps > 0 || bestAvailableAwakeCurrentMilliamps > 0 {
            return "macOS exposed current budgets and port limits for this path, but not an explicit PD voltage/current contract. The watt figures here assume the standard 5V USB bus unless the OS publishes more."
        }

        return "macOS did not publish an explicit USB Power Delivery contract for this path."
    }

    var portTypeDescription: String {
        if let code = powerDetails.usbPortTypeCode {
            return usbPortTypeCodeDescription(code)
        }

        if !portType.isEmpty, portType != "Standard" {
            return portType
        }

        return "Not published"
    }

    var wakePortLimitDescription: String {
        powerDetails.wakePortCurrentLimitMilliamps > 0 ? formatUSBPowerAssumingFiveVolts(powerDetails.wakePortCurrentLimitMilliamps) : "Not published"
    }

    var sleepPortLimitDescription: String {
        powerDetails.sleepPortCurrentLimitMilliamps > 0 ? formatUSBPowerAssumingFiveVolts(powerDetails.sleepPortCurrentLimitMilliamps) : "Not published"
    }

    var hubPowerSupplyDescription: String {
        powerDetails.hubPowerSupplyMilliamps > 0 ? formatUSBPowerAssumingFiveVolts(powerDetails.hubPowerSupplyMilliamps) : "Not published"
    }

    var currentPoolDescription: String {
        powerDetails.usbBusCurrentPoolID > 0 ? String(format: "0x%016llX", powerDetails.usbBusCurrentPoolID) : "Not published"
    }

    var overCurrentHistoryDescription: String {
        if powerDetails.overCurrentEventCount > 0 {
            return powerDetails.overCurrentEventCount == 1 ? "1 over-current event published" : "\(powerDetails.overCurrentEventCount) over-current events published"
        }
        return "No over-current events published"
    }

    var closestPublishedIntakeDescription: String {
        if powerDetails.sinkAllocationMilliamps > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(powerDetails.sinkAllocationMilliamps)) sink allocation"
        }

        if powerDetails.reportedDeviceCurrentMilliamps > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(powerDetails.reportedDeviceCurrentMilliamps)) reported device current"
        }

        if maxPower > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(maxPower)) negotiated budget"
        }

        return "Not published"
    }

    var chargingCeilingDescription: String {
        if bestAvailableAwakeCurrentMilliamps > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(bestAvailableAwakeCurrentMilliamps)) published awake port ceiling"
        }

        if powerDetails.hubPowerSupplyMilliamps > 0 {
            return "\(formatUSBPowerAssumingFiveVolts(powerDetails.hubPowerSupplyMilliamps)) upstream hub supply"
        }

        return "Not published"
    }

    var drawInterpretationSummary: String {
        if powerDetails.sinkAllocationMilliamps > 0 {
            return "This is the best public clue macOS is giving for how much current this path is letting the device take right now."
        }

        if powerDetails.reportedDeviceCurrentMilliamps > 0 {
            return "macOS is publishing a device current value here, but it still is not clearly labeled as a live real-time meter."
        }

        if bestAvailableAwakeCurrentMilliamps > 0 {
            return "macOS is only giving a charging ceiling for the port path here, not the device's actual instantaneous draw."
        }

        return "macOS is not publishing either a live draw value or a clear charging ceiling for this path."
    }

    var classInfo: (name: String, description: String, icon: String, layman: String) {
        if effectiveClass == -1 {
            return ("Unknown Type", "macOS did not expose enough descriptor information to classify this device", "questionmark.circle", "We couldn't identify what type of device this is yet")
        }
        return usbClassDescriptions[effectiveClass] ?? ("Unknown Type", "Unrecognized device class", "questionmark.circle", "We couldn't identify what type of device this is")
    }

    var theoreticalBandwidth: (speed: String, practical: String, realWorld: String) {
        switch speed {
        case .low: return ("1.5 Mbps", "~0.19 MB/s", "Basic keyboards and mice – very slow by today's standards")
        case .full: return ("12 Mbps", "~1.5 MB/s", "Old USB 1.1 – a 1GB file would take ~11 minutes")
        case .high: return ("480 Mbps", "~40-50 MB/s", "Standard USB 2.0 – a 1GB file takes ~20 seconds")
        case .super_: return ("5 Gbps", "~400-450 MB/s", "Fast USB 3.0 – a 1GB file takes ~2-3 seconds")
        case .superPlus: return ("10 Gbps", "~900-1000 MB/s", "Very fast – a 1GB file in about 1 second")
        case .superPlusBy2: return ("20 Gbps", "~2000 MB/s", "Blazing fast – a 4K movie in seconds")
        case .usb4: return ("40 Gbps", "~3500-4000 MB/s", "USB4-class performance for high-end storage, docks, and displays")
        case .unknown: return ("Unknown", "N/A", "Speed couldn't be determined")
        }
    }

    var connectionQuality: (rating: String, score: Int, color: Color, issues: [String], summary: String) {
        var score = 100
        var issues: [String] = []

        if speed == .unknown {
            score -= 35
            issues.append("⚠️ macOS did not expose a negotiated USB speed for this device")
        }

        if descriptorMaxPowerMilliamps > 0 && busPowerAvailable > 0 && descriptorMaxPowerMilliamps > busPowerAvailable {
            score -= 25
            issues.append("🔌 The device requests \(descriptorMaxPowerMilliamps) mA, but the port only advertises \(busPowerAvailable) mA")
        } else if maxPower > 0 && busPowerAvailable > 0 && maxPower > busPowerAvailable {
            score -= 15
            issues.append("🔋 The negotiated power budget is larger than the port's advertised budget")
        }

        if powerDetails.overCurrentEventCount > 0 {
            score -= min(20, powerDetails.overCurrentEventCount * 5)
            issues.append("⚠️ The upstream USB port path has logged \(powerDetails.overCurrentEventCount) over-current events")
        }

        if vendorID == 0 && productID == 0 {
            score -= 15
            issues.append("❓ The device did not publish vendor/product IDs, which usually means incomplete descriptors")
        }

        if isPerformanceLimited {
            score -= 25
            issues.append("🐢 This device advertises USB \(usbVersion) capability but negotiated below SuperSpeed – the cable, port, or hub is likely limiting it")
        }

        if deviceClass == 0 && interfaces.isEmpty {
            score -= 10
            issues.append("🧩 The device reports itself as composite, but macOS did not expose interface descriptors to classify it")
        } else if isCompositeDevice {
            issues.append("🧩 Composite device exposing \(interfaces.count) separate USB interfaces")
        }

        if serialNumber.isEmpty && !isHub && !isInternal {
            score -= 3
            issues.append("ℹ️ No serial number was published for this external device")
        }

        let rating: String
        let color: Color
        let summary: String

        if score >= 90 {
            rating = "Excellent"
            color = Pastel.mint
            summary = "Everything looks great! This device is working at its best."
        } else if score >= 70 {
            rating = "Good"
            color = Pastel.butter
            summary = "Working fine with minor notes. Should perform well for most uses."
        } else if score >= 50 {
            rating = "Fair"
            color = Pastel.peach
            summary = "Some issues detected. The device may not perform optimally."
        } else {
            rating = "Poor"
            color = Pastel.rose
            summary = "Significant problems found. Consider using a different port, cable, or device."
        }

        return (rating, score, color, issues.isEmpty ? ["✅ All systems go – device is working perfectly"] : issues, summary)
    }

    var locationDescription: String {
        if portPathComponents.isEmpty {
            return "Root"
        }
        return portPathComponents.map(String.init).joined(separator: " → ")
    }

    var hierarchyPathLabel: String {
        if portPathComponents.isEmpty {
            return "Root path"
        }

        let label = portPathComponents.count == 1 ? "Port" : "Path"
        return "\(label) \(locationDescription)"
    }

    var hierarchyIdentityLine: String {
        var parts = [hierarchyPathLabel]

        if vendorID != 0 || productID != 0 {
            parts.append("\(vendorIDHex):\(productIDHex)")
        }

        if !serialNumber.isEmpty {
            parts.append("SN \(serialNumber)")
        } else if let volume = mountedVolumes.first {
            parts.append(volume.displayName)
        } else if let volume = sortedStorageVolumes.first {
            parts.append(volume.wholeDiskBSDName)
        } else if isInternal {
            parts.append("Internal")
        }

        return orderedUniqueStrings(parts).joined(separator: " • ")
    }
}

// MARK: - USB Speed Enum
enum USBSpeed: Int, CaseIterable {
    case unknown = -1
    case low = 0          // 1.5 Mbps
    case full = 1         // 12 Mbps
    case high = 2         // 480 Mbps
    case super_ = 3       // 5 Gbps
    case superPlus = 4    // 10 Gbps
    case superPlusBy2 = 5 // 20 Gbps
    case usb4 = 6         // 40 Gbps

    static func resolve(deviceSpeed: Int?, usbSpeed: Int?, linkSpeedBitsPerSecond: Int64) -> USBSpeed {
        if linkSpeedBitsPerSecond >= 40_000_000_000 { return .usb4 }
        if linkSpeedBitsPerSecond >= 20_000_000_000 { return .superPlusBy2 }
        if linkSpeedBitsPerSecond >= 10_000_000_000 { return .superPlus }
        if linkSpeedBitsPerSecond >= 5_000_000_000 { return .super_ }
        if linkSpeedBitsPerSecond >= 480_000_000 { return .high }
        if linkSpeedBitsPerSecond >= 12_000_000 { return .full }
        if linkSpeedBitsPerSecond >= 1_500_000 { return .low }

        if let deviceSpeed {
            switch deviceSpeed {
            case 0: return .low
            case 1: return .full
            case 2: return .high
            case 3: return .super_
            case 4: return .superPlus
            case 5: return .superPlusBy2
            default: break
            }
        }

        if let usbSpeed {
            switch usbSpeed {
            case 0: return .low
            case 1: return .full
            case 2: return .high
            case 3: return .super_
            case 4, 5: return .superPlus
            default: break
            }
        }

        return .unknown
    }

    var nominalBitsPerSecond: Int64? {
        switch self {
        case .unknown: return nil
        case .low: return 1_500_000
        case .full: return 12_000_000
        case .high: return 480_000_000
        case .super_: return 5_000_000_000
        case .superPlus: return 10_000_000_000
        case .superPlusBy2: return 20_000_000_000
        case .usb4: return 40_000_000_000
        }
    }

    var description: String {
        switch self {
        case .unknown: return "Unknown Speed"
        case .low: return "Low Speed (USB 1.0)"
        case .full: return "Full Speed (USB 1.1)"
        case .high: return "High Speed (USB 2.0)"
        case .super_: return "SuperSpeed (USB 3.0)"
        case .superPlus: return "SuperSpeed+ (USB 3.1/3.2)"
        case .superPlusBy2: return "SuperSpeed+ 2x2 (USB 3.2)"
        case .usb4: return "USB4 (40 Gbps class)"
        }
    }

    var laymanDescription: String {
        switch self {
        case .unknown: return "Speed unknown – may need a better cable or port"
        case .low: return "Very Slow – only good for basic keyboards/mice"
        case .full: return "Slow – outdated USB 1.1, fine for simple devices"
        case .high: return "Medium – standard USB 2.0, good for most devices"
        case .super_: return "Fast – great for flash drives and external storage"
        case .superPlus: return "Very Fast – excellent for SSDs and video capture"
        case .superPlusBy2: return "Blazing Fast – top-tier speed for demanding tasks"
        case .usb4: return "Extreme – workstation-class USB performance for top-end docks and storage"
        }
    }

    var shortDescription: String {
        switch self {
        case .unknown: return "Unknown"
        case .low: return "1.5 Mbps"
        case .full: return "12 Mbps"
        case .high: return "480 Mbps"
        case .super_: return "5 Gbps"
        case .superPlus: return "10 Gbps"
        case .superPlusBy2: return "20 Gbps"
        case .usb4: return "40 Gbps"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return Pastel.ice
        case .low: return Pastel.rose
        case .full: return Pastel.peach
        case .high: return Pastel.butter
        case .super_: return Pastel.mint
        case .superPlus: return Pastel.sky
        case .superPlusBy2: return Pastel.lavender
        case .usb4: return Pastel.periwinkle
        }
    }

    var usbVersionString: String {
        switch self {
        case .unknown: return "?"
        case .low, .full: return "1.x"
        case .high: return "2.0"
        case .super_: return "3.0/3.1 Gen 1"
        case .superPlus: return "3.1 Gen 2/3.2 Gen 2"
        case .superPlusBy2: return "3.2 Gen 2x2"
        case .usb4: return "USB4"
        }
    }

    var maxPowerDelivery: String {
        switch self {
        case .unknown: return "Unknown"
        case .low, .full: return "100 mA (0.5W)"
        case .high: return "500 mA (2.5W)"
        case .super_, .superPlus, .superPlusBy2: return "900 mA (4.5W) / Up to 3A with USB-C PD"
        case .usb4: return "USB4 base power with USB-C PD support for much higher delivery"
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .low: return "tortoise"
        case .full: return "hare"
        case .high: return "bolt"
        case .super_: return "bolt.fill"
        case .superPlus: return "bolt.horizontal.fill"
        case .superPlusBy2: return "bolt.horizontal.circle.fill"
        case .usb4: return "bolt.badge.clock"
        }
    }
}

// MARK: - USB Manager
typealias HardwareInspectorManager = USBManager

func formatUSBTransferRate(_ bytesPerSecond: Double) -> String {
    formatTransferRate(bytesPerSecond)
}

final class USBManager: ObservableObject, @unchecked Sendable {
    static let shared = USBManager()
    @Published var devices: [USBDevice] = []
    var performanceLimitedDevices: [USBDevice] {
        devices.filter { $0.isPerformanceLimited }
    }
    var mountedExternalVolumes: [StorageVolumeInfo] {
        devices.flatMap(\.mountedVolumes)
    }
    var totalActiveThroughputBytesPerSecond: Double {
        liveDeviceActivity.values.reduce(0.0) { $0 + $1.readBytesPerSecond + $1.writeBytesPerSecond }
    }
    @Published var hidDevices: [MacOS27HIDDeviceInfo] = []
    @Published var audioPeripherals: [MacOS27AudioPeripheralInfo] = []
    @Published var videoPeripherals: [MacOS27VideoPeripheralInfo] = []
    @Published var fmHardwareStatus: MacOS27FoundationModelsHardwareStatus = .probe()
    @Published var aiHardwareDiagnosis: String = ""
    @Published var isRunningAIDiagnosis: Bool = false
    @Published var controllers: [USBController] = []
    @Published var thunderboltDevices: [ThunderboltDevice] = []
    @Published var liveDiskActivity: [String: LiveWholeDiskActivity] = [:]
    @Published var liveVolumeState: [String: LiveMountedVolumeState] = [:]
    @Published var liveDeviceActivity: [String: DeviceStorageActivity] = [:]
    @Published var lastUpdated: Date = Date()
    @Published var isScanning: Bool = false
    @Published var scanLog: [String] = []

    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var diskArbitrationSession: DASession?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activityTimer: AnyCancellable?
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var refreshQueuedWhileScanning = false
    private var isSamplingLiveStorage = false
    private var previousBlockStorageSamples: [String: BlockStorageSample] = [:]
    private var previousVolumeCapacitySamples: [String: VolumeCapacitySample] = [:]
    private var lastActiveDiskTimestamps: [String: Date] = [:]
    private let liveMonitoringQueue = DispatchQueue(label: "USBManager.LiveMonitoring", qos: .utility)

    init() {
        refreshAll()
        setupUSBNotifications()
        setupDiskArbitrationMonitoring()
        setupWorkspaceVolumeNotifications()
        startLiveStorageMonitoring()
    }

    deinit {
        activityTimer?.cancel()
        pendingRefreshWorkItem?.cancel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let diskArbitrationSession {
            DASessionSetDispatchQueue(diskArbitrationSession, nil)
        }
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port = notificationPort { IONotificationPortDestroy(port) }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.scanLog.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
            if self.scanLog.count > 100 { self.scanLog.removeFirst() }
        }
    }

    private func scheduleRefresh(reason: String, delay: TimeInterval = 0.35) {
        log(reason)

        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshAll()
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func setupUSBNotifications() {
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notificationPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        let matchingDict = IOServiceMatching("IOUSBHostDevice")
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingDict,
            { (refcon, iterator) in
                while case let device = IOIteratorNext(iterator), device != 0 { IOObjectRelease(device) }
                guard let refcon = refcon else { return }
                Unmanaged<USBManager>.fromOpaque(refcon).takeUnretainedValue().scheduleRefresh(reason: "USB device attach/change detected")
            }, selfPtr, &addedIterator)

        while case let device = IOIteratorNext(addedIterator), device != 0 { IOObjectRelease(device) }

        let matchingDict2 = IOServiceMatching("IOUSBHostDevice")
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDict2,
            { (refcon, iterator) in
                while case let device = IOIteratorNext(iterator), device != 0 { IOObjectRelease(device) }
                guard let refcon = refcon else { return }
                Unmanaged<USBManager>.fromOpaque(refcon).takeUnretainedValue().scheduleRefresh(reason: "USB device removal detected")
            }, selfPtr, &removedIterator)

        while case let device = IOIteratorNext(removedIterator), device != 0 { IOObjectRelease(device) }
    }

    private func setupDiskArbitrationMonitoring() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }

        diskArbitrationSession = session
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context, let bsdName = DADiskGetBSDName(disk) else { return }
            let manager = Unmanaged<USBManager>.fromOpaque(context).takeUnretainedValue()
            manager.scheduleRefresh(reason: "Disk appeared: \(String(cString: bsdName))")
        }, selfPtr)

        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context, let bsdName = DADiskGetBSDName(disk) else { return }
            let manager = Unmanaged<USBManager>.fromOpaque(context).takeUnretainedValue()
            manager.scheduleRefresh(reason: "Disk disappeared: \(String(cString: bsdName))")
        }, selfPtr)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context, let bsdName = DADiskGetBSDName(disk) else { return }
            let manager = Unmanaged<USBManager>.fromOpaque(context).takeUnretainedValue()
            manager.scheduleRefresh(reason: "Volume mount/name changed: \(String(cString: bsdName))")
        }, selfPtr)

        DASessionSetDispatchQueue(session, liveMonitoringQueue)
    }

    private func setupWorkspaceVolumeNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh(reason: "Finder mounted a volume")
            }
        )

        workspaceObservers.append(
            notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh(reason: "Finder unmounted a volume")
            }
        )

        workspaceObservers.append(
            notificationCenter.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh(reason: "Finder renamed a volume")
            }
        )
    }

    func startLiveStorageMonitoring(interval: TimeInterval? = nil) {
        activityTimer?.cancel()
        let requested = interval ?? (UserDefaults.standard.object(forKey: "usb.pollingInterval") as? Double ?? 1.0)
        let seconds = min(5, max(0.5, requested.isFinite ? requested : 1.0))
        activityTimer = Timer.publish(every: seconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.sampleLiveStorageMetrics()
            }
    }

    func refreshAll() {
        if isScanning {
            refreshQueuedWhileScanning = true
            return
        }

        isScanning = true
        log("Starting full scan...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = self?.scanUSBDevices() ?? []
            let controllers = self?.scanUSBControllers() ?? []
            let thunderbolt = self?.scanThunderboltDevices() ?? []
            let hid = self?.scanHIDDevices(correlatingWith: devices) ?? []
            let audio = self?.scanAudioPeripherals() ?? []
            let video = self?.scanVideoPeripherals() ?? []
            let fmStatus = MacOS27FoundationModelsHardwareStatus.probe()

            DispatchQueue.main.async {
                self?.hidDevices = hid
                self?.audioPeripherals = audio
                self?.videoPeripherals = video
                self?.fmHardwareStatus = fmStatus
                let previousDevices = self?.devices ?? []
                let previousDeviceLookup = Dictionary(uniqueKeysWithValues: previousDevices.map { ($0.id, $0) })
                let currentDeviceLookup = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
                let connectedDevices = devices.filter { previousDeviceLookup[$0.id] == nil }
                let disconnectedDevices = previousDevices.filter { currentDeviceLookup[$0.id] == nil }

                self?.devices = devices
                self?.controllers = controllers
                self?.thunderboltDevices = thunderbolt
                self?.lastUpdated = Date()
                self?.isScanning = false
                if !connectedDevices.isEmpty {
                    self?.log("Connected: \(connectedDevices.map(\.logName).joined(separator: ", "))")
                }
                if !disconnectedDevices.isEmpty {
                    self?.log("Disconnected: \(disconnectedDevices.map(\.logName).joined(separator: ", "))")
                }
                self?.log("Scan complete: \(devices.count) USB devices, \(controllers.count) controllers, \(thunderbolt.count) Thunderbolt devices")
                self?.sampleLiveStorageMetrics(force: true)

                if self?.refreshQueuedWhileScanning == true {
                    self?.refreshQueuedWhileScanning = false
                    self?.refreshAll()
                }
            }
        }
    }

    private func sampleLiveStorageMetrics(force: Bool = false) {
        let deviceSnapshot = devices
        let storageDevices = deviceSnapshot.filter { !$0.storageVolumes.isEmpty }

        guard !storageDevices.isEmpty else {
            if !liveDiskActivity.isEmpty { liveDiskActivity = [:] }
            if !liveVolumeState.isEmpty { liveVolumeState = [:] }
            if !liveDeviceActivity.isEmpty { liveDeviceActivity = [:] }
            previousBlockStorageSamples = [:]
            previousVolumeCapacitySamples = [:]
            lastActiveDiskTimestamps = [:]
            return
        }

        guard !isSamplingLiveStorage else { return }
        isSamplingLiveStorage = true

        let previousBlockSamples = previousBlockStorageSamples
        let previousVolumeSamples = previousVolumeCapacitySamples
        let previousLastActive = lastActiveDiskTimestamps

        liveMonitoringQueue.async { [weak self] in
            guard let self else { return }

            let now = Date()
            let diskResult = self.collectLiveDiskActivity(
                for: storageDevices,
                at: now,
                previousSamples: previousBlockSamples,
                previousLastActive: previousLastActive
            )
            let volumeResult = self.collectMountedVolumeStates(
                for: storageDevices,
                at: now,
                previousSamples: previousVolumeSamples
            )
            let deviceActivity = self.aggregateDeviceActivity(for: storageDevices, diskActivity: diskResult.activities)

            DispatchQueue.main.async {
                self.liveDiskActivity = diskResult.activities
                self.liveVolumeState = volumeResult.states
                self.liveDeviceActivity = deviceActivity
                self.previousBlockStorageSamples = diskResult.samples
                self.previousVolumeCapacitySamples = volumeResult.samples
                self.lastActiveDiskTimestamps = diskResult.lastActive
                self.isSamplingLiveStorage = false
            }
        }
    }

    private func collectLiveDiskActivity(
        for devices: [USBDevice],
        at now: Date,
        previousSamples: [String: BlockStorageSample],
        previousLastActive: [String: Date]
    ) -> (activities: [String: LiveWholeDiskActivity], samples: [String: BlockStorageSample], lastActive: [String: Date]) {
        let wholeDiskNames = Set(devices.flatMap { $0.sortedStorageVolumes.map(\.wholeDiskBSDName) }.filter { !$0.isEmpty })
        var activities: [String: LiveWholeDiskActivity] = [:]
        var nextSamples: [String: BlockStorageSample] = [:]
        var nextLastActive: [String: Date] = [:]

        for wholeDiskBSDName in wholeDiskNames.sorted() {
            guard let counters = blockStorageCounters(forWholeDiskBSDName: wholeDiskBSDName) else { continue }

            let currentSample = BlockStorageSample(sampleDate: now, counters: counters)
            nextSamples[wholeDiskBSDName] = currentSample

            let previousSample = previousSamples[wholeDiskBSDName]
            let sampleDuration = max(previousSample.map { now.timeIntervalSince($0.sampleDate) } ?? 0, 0.001)

            let readBytesDelta = max(counters.bytesRead - (previousSample?.counters.bytesRead ?? counters.bytesRead), 0)
            let writeBytesDelta = max(counters.bytesWritten - (previousSample?.counters.bytesWritten ?? counters.bytesWritten), 0)
            let readOperationsDelta = max(counters.readOperations - (previousSample?.counters.readOperations ?? counters.readOperations), 0)
            let writeOperationsDelta = max(counters.writeOperations - (previousSample?.counters.writeOperations ?? counters.writeOperations), 0)
            let readErrorsDelta = max(counters.readErrors - (previousSample?.counters.readErrors ?? counters.readErrors), 0)
            let writeErrorsDelta = max(counters.writeErrors - (previousSample?.counters.writeErrors ?? counters.writeErrors), 0)
            let readRetriesDelta = max(counters.readRetries - (previousSample?.counters.readRetries ?? counters.readRetries), 0)
            let writeRetriesDelta = max(counters.writeRetries - (previousSample?.counters.writeRetries ?? counters.writeRetries), 0)
            let readTimeDelta = max(counters.totalReadTimeNanoseconds - (previousSample?.counters.totalReadTimeNanoseconds ?? counters.totalReadTimeNanoseconds), 0)
            let writeTimeDelta = max(counters.totalWriteTimeNanoseconds - (previousSample?.counters.totalWriteTimeNanoseconds ?? counters.totalWriteTimeNanoseconds), 0)

            let readBytesPerSecond = Double(readBytesDelta) / sampleDuration
            let writeBytesPerSecond = Double(writeBytesDelta) / sampleDuration
            let readOperationsPerSecond = Double(readOperationsDelta) / sampleDuration
            let writeOperationsPerSecond = Double(writeOperationsDelta) / sampleDuration
            let direction = resolveStorageTrafficDirection(
                readBytesPerSecond: readBytesPerSecond,
                writeBytesPerSecond: writeBytesPerSecond,
                readOperationsPerSecond: readOperationsPerSecond,
                writeOperationsPerSecond: writeOperationsPerSecond
            )

            let lastActiveAt: Date?
            if direction == .idle {
                lastActiveAt = previousLastActive[wholeDiskBSDName]
            } else {
                lastActiveAt = now
                nextLastActive[wholeDiskBSDName] = now
            }

            let averageReadLatencyMilliseconds = readOperationsDelta > 0
                ? Double(readTimeDelta) / Double(readOperationsDelta) / 1_000_000.0
                : nil
            let averageWriteLatencyMilliseconds = writeOperationsDelta > 0
                ? Double(writeTimeDelta) / Double(writeOperationsDelta) / 1_000_000.0
                : nil

            activities[wholeDiskBSDName] = LiveWholeDiskActivity(
                wholeDiskBSDName: wholeDiskBSDName,
                sampleDate: now,
                direction: direction,
                readBytesPerSecond: readBytesPerSecond,
                writeBytesPerSecond: writeBytesPerSecond,
                readOperationsPerSecond: readOperationsPerSecond,
                writeOperationsPerSecond: writeOperationsPerSecond,
                totalBytesRead: counters.bytesRead,
                totalBytesWritten: counters.bytesWritten,
                totalReadErrors: counters.readErrors,
                totalWriteErrors: counters.writeErrors,
                totalReadRetries: counters.readRetries,
                totalWriteRetries: counters.writeRetries,
                readErrorDelta: readErrorsDelta,
                writeErrorDelta: writeErrorsDelta,
                readRetryDelta: readRetriesDelta,
                writeRetryDelta: writeRetriesDelta,
                averageReadLatencyMilliseconds: averageReadLatencyMilliseconds,
                averageWriteLatencyMilliseconds: averageWriteLatencyMilliseconds,
                lastActiveAt: lastActiveAt
            )
        }

        return (activities, nextSamples, nextLastActive)
    }

    private func collectMountedVolumeStates(
        for devices: [USBDevice],
        at now: Date,
        previousSamples: [String: VolumeCapacitySample]
    ) -> (states: [String: LiveMountedVolumeState], samples: [String: VolumeCapacitySample]) {
        let mountedVolumes = devices.flatMap { $0.sortedStorageVolumes }.filter(\.isMounted)
        var states: [String: LiveMountedVolumeState] = [:]
        var nextSamples: [String: VolumeCapacitySample] = [:]

        for volume in mountedVolumes {
            guard let state = liveMountedVolumeState(for: volume, at: now, previousSample: previousSamples[volume.bsdName]) else { continue }
            states[volume.bsdName] = state
            nextSamples[volume.bsdName] = VolumeCapacitySample(
                sampleDate: now,
                availableBytes: state.availableBytes,
                capacityBytes: state.capacityBytes
            )
        }

        return (states, nextSamples)
    }

    private func aggregateDeviceActivity(
        for devices: [USBDevice],
        diskActivity: [String: LiveWholeDiskActivity]
    ) -> [String: DeviceStorageActivity] {
        var result: [String: DeviceStorageActivity] = [:]

        for device in devices {
            let diskNames = Array(Set(device.sortedStorageVolumes.map(\.wholeDiskBSDName))).sorted()
            let matchingDisks = diskNames.compactMap { diskActivity[$0] }
            guard !matchingDisks.isEmpty else { continue }

            let totalReadBytesPerSecond = matchingDisks.reduce(0) { $0 + $1.readBytesPerSecond }
            let totalWriteBytesPerSecond = matchingDisks.reduce(0) { $0 + $1.writeBytesPerSecond }
            let totalReadOperationsPerSecond = matchingDisks.reduce(0) { $0 + $1.readOperationsPerSecond }
            let totalWriteOperationsPerSecond = matchingDisks.reduce(0) { $0 + $1.writeOperationsPerSecond }
            let direction = resolveStorageTrafficDirection(
                readBytesPerSecond: totalReadBytesPerSecond,
                writeBytesPerSecond: totalWriteBytesPerSecond,
                readOperationsPerSecond: totalReadOperationsPerSecond,
                writeOperationsPerSecond: totalWriteOperationsPerSecond
            )
            let busiestDiskBSDName = matchingDisks.max {
                max($0.readBytesPerSecond, $0.writeBytesPerSecond) < max($1.readBytesPerSecond, $1.writeBytesPerSecond)
            }?.wholeDiskBSDName

            result[device.id] = DeviceStorageActivity(
                deviceID: device.id,
                sampleDate: matchingDisks.map(\.sampleDate).max() ?? Date(),
                direction: direction,
                readBytesPerSecond: totalReadBytesPerSecond,
                writeBytesPerSecond: totalWriteBytesPerSecond,
                readOperationsPerSecond: totalReadOperationsPerSecond,
                writeOperationsPerSecond: totalWriteOperationsPerSecond,
                activeDiskCount: matchingDisks.filter(\.isBusy).count,
                wholeDiskBSDNames: diskNames,
                busiestDiskBSDName: busiestDiskBSDName,
                lastActiveAt: matchingDisks.compactMap(\.lastActiveAt).max()
            )
        }

        return result
    }

    private func liveMountedVolumeState(
        for volume: StorageVolumeInfo,
        at now: Date,
        previousSample: VolumeCapacitySample?
    ) -> LiveMountedVolumeState? {
        guard volume.isMounted else { return nil }

        let volumeURL = URL(fileURLWithPath: volume.mountPath, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey
        ]

        let resourceValues = try? volumeURL.resourceValues(forKeys: resourceKeys)
        let capacityBytes = Int64(resourceValues?.volumeTotalCapacity ?? Int(volume.capacityBytes))
        let availableBytes = Int64(resourceValues?.volumeAvailableCapacity ?? Int(volume.availableBytes))
        let isReadOnly = resourceValues?.volumeIsReadOnly ?? false
        let formatDescription = resourceValues?.volumeLocalizedFormatDescription ?? volume.fileSystem
        let sampleDuration = max(previousSample.map { now.timeIntervalSince($0.sampleDate) } ?? 0, 0.001)
        let availableBytesPerSecond = previousSample.map {
            Double(availableBytes - $0.availableBytes) / sampleDuration
        } ?? 0

        return LiveMountedVolumeState(
            bsdName: volume.bsdName,
            sampleDate: now,
            capacityBytes: capacityBytes,
            availableBytes: availableBytes,
            availableBytesPerSecond: availableBytesPerSecond,
            isReadOnly: isReadOnly,
            formatDescription: formatDescription
        )
    }

    private func blockStorageCounters(forWholeDiskBSDName wholeDiskBSDName: String) -> BlockStorageCounters? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, wholeDiskBSDName) else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let media = IOIteratorNext(iterator)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        var current = media
        var shouldReleaseCurrent = false

        while true {
            if let properties = registryProperties(for: current),
               let counters = parseBlockStorageCounters(from: properties) {
                if shouldReleaseCurrent {
                    IOObjectRelease(current)
                }
                return counters
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                if shouldReleaseCurrent {
                    IOObjectRelease(current)
                }
                return nil
            }

            if shouldReleaseCurrent {
                IOObjectRelease(current)
            }

            current = parent
            shouldReleaseCurrent = true
        }
    }

    private func parseBlockStorageCounters(from properties: [String: Any]) -> BlockStorageCounters? {
        guard let stats = properties[kIOBlockStorageStatisticsKey] as? [String: Any] else { return nil }

        return BlockStorageCounters(
            bytesRead: int64Value(stats[kIOBlockStorageBytesReadKey]) ?? 0,
            bytesWritten: int64Value(stats[kIOBlockStorageBytesWrittenKey]) ?? 0,
            readErrors: int64Value(stats[kIOBlockStorageReadErrorsKey]) ?? 0,
            writeErrors: int64Value(stats[kIOBlockStorageWriteErrorsKey]) ?? 0,
            readRetries: int64Value(stats[kIOBlockStorageReadRetriesKey]) ?? 0,
            writeRetries: int64Value(stats[kIOBlockStorageWriteRetriesKey]) ?? 0,
            readOperations: int64Value(stats[kIOBlockStorageReadOperationsKey]) ?? 0,
            writeOperations: int64Value(stats[kIOBlockStorageWriteOperationsKey]) ?? 0,
            totalReadTimeNanoseconds: int64Value(stats[kIOBlockStorageTotalReadTimeKey]) ?? 0,
            totalWriteTimeNanoseconds: int64Value(stats[kIOBlockStorageTotalWriteTimeKey]) ?? 0
        )
    }

    // MARK: - Scan USB Controllers
    private func scanUSBControllers() -> [USBController] {
        var controllersByID: [String: USBController] = [:]

        let controllerClasses = ["AppleUSBXHCI", "AppleUSBEHCI", "AppleUSBOHCI", "AppleUSBUHCI", "IOUSBController", "AppleUSB20XHCIPort", "IOUSBHostController"]

        for className in controllerClasses {
            let matchingDict = IOServiceMatching(className)
            var iterator: io_iterator_t = 0

            if IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }

                while case let service = IOIteratorNext(iterator), service != 0 {
                    defer { IOObjectRelease(service) }

                    if let controller = createController(from: service, className: className) {
                        controllersByID[controller.id] = controller
                    }
                }
            }
        }

        return controllersByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createController(from service: io_service_t, className: String) -> USBController? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        var name = className
        if IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS {
            name = String(cString: nameBuffer)
        }

        let busPower = firstInt(in: props, keys: ["Bus Power Available", "AAPL,current-available"]) ?? 0
        let locationID = firstUInt32(in: props, keys: ["locationID"]) ?? 0
        let isBuiltIn = firstBool(in: props, keys: ["Built-In", "built-in"]) ?? (props["built-in"] != nil)

        var controllerType = "Unknown"
        if className.contains("XHCI") { controllerType = "xHCI (USB 3.0+)" }
        else if className.contains("EHCI") { controllerType = "EHCI (USB 2.0)" }
        else if className.contains("OHCI") || className.contains("UHCI") { controllerType = "OHCI/UHCI (USB 1.x)" }

        let rawProps = rawPropertyStrings(from: props)
        let stableID = locationID > 0 ? "controller-\(String(format: "%08X", locationID))" : "controller-\(name)"

        return USBController(
            id: stableID,
            name: name,
            className: className,
            locationID: locationID,
            busPowerAvailable: busPower,
            isBuiltIn: isBuiltIn,
            controllerType: controllerType,
            pciInfo: firstString(in: props, keys: ["pcidebug"]) ?? "",
            supportsUSB3: className.contains("XHCI") || name.contains("3.0"),
            rawProperties: rawProps
        )
    }

    // MARK: - Scan Thunderbolt
    private func scanThunderboltDevices() -> [ThunderboltDevice] {
        var devicesByID: [String: ThunderboltDevice] = [:]

        let matchingDict = IOServiceMatching("IOThunderboltPort")
        var iterator: io_iterator_t = 0

        if IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }

                if let tbDevice = createThunderboltDevice(from: service) {
                    devicesByID[tbDevice.id] = tbDevice
                }
            }
        }

        let matchingDict2 = IOServiceMatching("IOThunderboltSwitch")
        var iterator2: io_iterator_t = 0

        if IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict2, &iterator2) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator2) }

            while case let service = IOIteratorNext(iterator2), service != 0 {
                defer { IOObjectRelease(service) }

                if let tbDevice = createThunderboltDevice(from: service) {
                    devicesByID[tbDevice.id] = tbDevice
                }
            }
        }

        return devicesByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createThunderboltDevice(from service: io_service_t) -> ThunderboltDevice? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        var name = "Thunderbolt Device"
        if IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS {
            name = String(cString: nameBuffer)
        }

        let uid = firstString(in: props, keys: ["UID", "Thunderbolt Device UID"]) ?? ""
        let vendorName = firstString(in: props, keys: ["Device Vendor Name", "Vendor Name"]) ?? ""
        let deviceName = firstString(in: props, keys: ["Device Model Name", "Device Name"]) ?? name

        var generation = 0
        if let gen = firstInt(in: props, keys: ["Thunderbolt Generation"]) { generation = gen }
        else if name.contains("Thunderbolt 4") || vendorName.contains("Thunderbolt 4") { generation = 4 }
        else if name.contains("Thunderbolt 3") { generation = 3 }
        else if name.contains("Thunderbolt 2") { generation = 2 }
        else if name.contains("Thunderbolt 1") || name.contains("Light Peak") { generation = 1 }

        let routeString = firstString(in: props, keys: ["Route String"]) ?? String(firstInt(in: props, keys: ["Route String", "Port Number"]) ?? 0)
        let rawProps = rawPropertyStrings(from: props)
        let stableID: String
        if !uid.isEmpty {
            stableID = uid
        } else if !routeString.isEmpty {
            stableID = "tb-\(routeString)-\(name)"
        } else {
            stableID = "tb-\(name)"
        }

        return ThunderboltDevice(
            id: stableID,
            name: name,
            vendorName: vendorName,
            deviceName: deviceName,
            uid: uid,
            routeString: routeString,
            linkSpeed: firstInt(in: props, keys: ["Link Speed"]) ?? 0,
            linkWidth: firstInt(in: props, keys: ["Link Width"]) ?? 0,
            generation: generation,
            isConnected: (firstInt(in: props, keys: ["Power State"]) ?? 1) > 0,
            rawProperties: rawProps
        )
    }

    // MARK: - Scan USB Devices
    private func scanUSBDevices() -> [USBDevice] {
        let storageVolumesByDevice = scanStorageVolumes()
        var devicesByID: [String: USBDevice] = [:]

        for className in ["IOUSBHostDevice", kIOUSBDeviceClassName] {
            let matchingDict = IOServiceMatching(className)
            var iterator: io_iterator_t = 0

            guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while case let usbDevice = IOIteratorNext(iterator), usbDevice != 0 {
                defer { IOObjectRelease(usbDevice) }
                if var device = createUSBDevice(from: usbDevice) {
                    device.storageVolumes = storageVolumesByDevice[device.id] ?? []
                    devicesByID[device.id] = device
                }
            }
        }

        return devicesByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanStorageVolumes() -> [String: [StorageVolumeInfo]] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [:] }

        var volumesByDevice: [String: [StorageVolumeInfo]] = [:]
        let matchingDict = IOServiceMatching(kIOMediaClass)
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }

            guard let volume = createStorageVolume(from: media, session: session) else { continue }

            var stableID = resolveUSBDeviceStableID(for: media)

            if stableID == nil && !volume.wholeDiskBSDName.isEmpty && volume.wholeDiskBSDName != volume.bsdName {
                if let wholeDiskMatch = IOBSDNameMatching(kIOMainPortDefault, 0, volume.wholeDiskBSDName) {
                    var wholeIterator: io_iterator_t = 0
                    if IOServiceGetMatchingServices(kIOMainPortDefault, wholeDiskMatch, &wholeIterator) == KERN_SUCCESS {
                        defer { IOObjectRelease(wholeIterator) }
                        let wholeMedia = IOIteratorNext(wholeIterator)
                        if wholeMedia != 0 {
                            stableID = resolveUSBDeviceStableID(for: wholeMedia)
                            IOObjectRelease(wholeMedia)
                        }
                    }
                }
            }

            guard let stableID else { continue }
            volumesByDevice[stableID, default: []].append(volume)
        }

        for key in volumesByDevice.keys {
            volumesByDevice[key]?.sort {
                if $0.wholeDiskBSDName != $1.wholeDiskBSDName {
                    return $0.wholeDiskBSDName.localizedCaseInsensitiveCompare($1.wholeDiskBSDName) == .orderedAscending
                }
                if $0.isWholeDisk != $1.isWholeDisk {
                    return $0.isWholeDisk && !$1.isWholeDisk
                }
                if $0.isMounted != $1.isMounted {
                    return $0.isMounted && !$1.isMounted
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        return volumesByDevice
    }

    private func createStorageVolume(from media: io_service_t, session: DASession) -> StorageVolumeInfo? {
        guard let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media) else { return nil }
        guard let bsdPointer = DADiskGetBSDName(disk) else { return nil }

        let description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        let bsdName = String(cString: bsdPointer)
        let wholeDiskBSDName: String
        if let wholeDisk = DADiskCopyWholeDisk(disk), let wholeBSDName = DADiskGetBSDName(wholeDisk) {
            wholeDiskBSDName = String(cString: wholeBSDName)
        } else {
            wholeDiskBSDName = bsdName
        }

        let volumeURL = description[kDADiskDescriptionVolumePathKey as String] as? URL
        var capacityBytes = firstUInt64(in: description, keys: [kDADiskDescriptionMediaSizeKey as String]).map(Int64.init) ?? 0
        var availableBytes: Int64 = 0

        if let volumeURL,
           let resourceValues = try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            if let total = resourceValues.volumeTotalCapacity {
                capacityBytes = Int64(total)
            }
            if let available = resourceValues.volumeAvailableCapacity {
                availableBytes = Int64(available)
            }
        }

        let fileSystem = firstString(in: description, keys: [kDADiskDescriptionVolumeKindKey as String]) ?? ""
        let volumeName = firstString(in: description, keys: [kDADiskDescriptionVolumeNameKey as String]) ?? ""
        let mediaName = firstString(in: description, keys: [kDADiskDescriptionMediaNameKey as String]) ?? ""
        let mountPath = volumeURL?.path ?? ""
        let isWholeDisk = firstBool(in: description, keys: [kDADiskDescriptionMediaWholeKey as String]) ?? false
        let isLeaf = firstBool(in: description, keys: [kDADiskDescriptionMediaLeafKey as String]) ?? false
        let isMounted = !mountPath.isEmpty

        if !isWholeDisk && !isMounted && fileSystem.isEmpty && !isLeaf {
            return nil
        }

        return StorageVolumeInfo(
            bsdName: bsdName,
            wholeDiskBSDName: wholeDiskBSDName,
            volumeName: volumeName,
            mediaName: mediaName,
            fileSystem: fileSystem,
            mountPath: mountPath,
            capacityBytes: capacityBytes,
            availableBytes: availableBytes,
            isWholeDisk: isWholeDisk,
            isMounted: isMounted,
            isLeaf: isLeaf,
            deviceModel: firstString(in: description, keys: [kDADiskDescriptionDeviceModelKey as String]) ?? "",
            deviceProtocol: firstString(in: description, keys: [kDADiskDescriptionDeviceProtocolKey as String]) ?? "",
            volumeUUID: (description[kDADiskDescriptionVolumeUUIDKey as String] as? UUID)?.uuidString ?? "",
            mediaUUID: (description[kDADiskDescriptionMediaUUIDKey as String] as? UUID)?.uuidString ?? ""
        )
    }

    private func resolveUSBDeviceStableID(for service: io_service_t) -> String? {
        var current = service
        var shouldReleaseCurrent = false

        while true {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 || IOObjectConformsTo(current, kIOUSBDeviceClassName) != 0 {
                let properties = registryProperties(for: current) ?? [:]
                let vendorID = firstInt(in: properties, keys: [kUSBVendorID]) ?? 0
                let productID = firstInt(in: properties, keys: [kUSBProductID]) ?? 0
                let serialNumber = firstString(in: properties, keys: [kUSBSerialNumberString, "kUSBSerialNumberString"]) ?? ""
                let sessionID = firstUInt64(in: properties, keys: ["sessionID"]) ?? 0
                let locationID = firstUInt32(in: properties, keys: [kUSBDevicePropertyLocationID]) ?? 0
                let fallbackName = firstString(in: properties, keys: [kUSBProductString, kUSBVendorString, "USB Product Name", "USB Vendor Name"]) ?? registryEntryName(current)

                if shouldReleaseCurrent {
                    IOObjectRelease(current)
                }

                return stableUSBDeviceID(
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serialNumber,
                    sessionID: sessionID,
                    locationID: locationID,
                    name: fallbackName
                )
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                if shouldReleaseCurrent {
                    IOObjectRelease(current)
                }
                return nil
            }

            if shouldReleaseCurrent {
                IOObjectRelease(current)
            }

            current = parent
            shouldReleaseCurrent = true
        }
    }

    private func registryProperties(for service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return props
    }

    private func powerFacts(from properties: [String: Any]) -> [String] {
        let interestingKeys = [
            "Device Current",
            "UsbPowerSinkAllocation",
            "AAPL,current-available",
            "Current Available",
            "Bus Power Available",
            "AAPL,current-extra-in-sleep",
            "Sleep Current",
            "AAPL,sleep-current",
            "kUSBWakePortCurrentLimit",
            "kUSBSleepPortCurrentLimit",
            "kUSBHubPowerSupply",
            "USBPortType",
            "port-type",
            "usb-port-type",
            "UsbBusCurrentPoolID"
        ]

        return interestingKeys.compactMap { key in
            guard let value = powerFactString(for: properties[key]) else { return nil }
            return "\(key)=\(value)"
        }
    }

    private func portStatisticFacts(from statistics: [String: Any]) -> [String] {
        var facts: [String] = []

        if let overCurrentCount = firstInt(in: statistics, keys: ["kPortStatOverCurrentCount"]) {
            facts.append("kPortStatOverCurrentCount=\(overCurrentCount)")
        }

        if let connectCount = firstInt(in: statistics, keys: ["kPortStatConnectCount"]) {
            facts.append("kPortStatConnectCount=\(connectCount)")
        }

        if let powerStateTimes = statistics["kPortStatPowerStateTime"] as? [String: Any] {
            let summary = powerStateTimes
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            if !summary.isEmpty {
                facts.append("kPortStatPowerStateTime=\(summary)")
            }
        }

        return facts
    }

    private func collectUSBPowerDetails(
        for service: io_service_t,
        baseProperties: [String: Any],
        reportedDeviceCurrent: Int,
        sinkAllocation: Int
    ) -> USBPowerDetails {
        var wakePortCurrentLimit = firstInt(in: baseProperties, keys: ["kUSBWakePortCurrentLimit"]) ?? 0
        var sleepPortCurrentLimit = firstInt(in: baseProperties, keys: ["kUSBSleepPortCurrentLimit"]) ?? 0
        var hubPowerSupply = firstInt(in: baseProperties, keys: ["kUSBHubPowerSupply"]) ?? 0
        var usbPortTypeCode = decodeUSBPortTypeCode(from: baseProperties["USBPortType"])
            ?? decodeUSBPortTypeCode(from: baseProperties["usb-port-type"])
            ?? decodeUSBPortTypeCode(from: baseProperties["port-type"])
        var usbBusCurrentPoolID = firstUInt64(in: baseProperties, keys: ["UsbBusCurrentPoolID"]) ?? 0
        var overCurrentEventCount = 0
        var registryFacts = powerFacts(from: baseProperties)

        if let portStatistics = baseProperties["port-statistics"] as? [String: Any] {
            overCurrentEventCount = firstInt(in: portStatistics, keys: ["kPortStatOverCurrentCount"]) ?? 0
            registryFacts.append(contentsOf: portStatisticFacts(from: portStatistics))
        }

        var current = service
        var shouldReleaseCurrent = false

        defer {
            if shouldReleaseCurrent {
                IOObjectRelease(current)
            }
        }

        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }

            if shouldReleaseCurrent {
                IOObjectRelease(current)
            }

            current = parent
            shouldReleaseCurrent = true

            guard let parentProperties = registryProperties(for: current) else { continue }

            if wakePortCurrentLimit == 0 {
                wakePortCurrentLimit = firstInt(in: parentProperties, keys: ["kUSBWakePortCurrentLimit"]) ?? 0
            }
            if sleepPortCurrentLimit == 0 {
                sleepPortCurrentLimit = firstInt(in: parentProperties, keys: ["kUSBSleepPortCurrentLimit"]) ?? 0
            }
            if hubPowerSupply == 0 {
                hubPowerSupply = firstInt(in: parentProperties, keys: ["kUSBHubPowerSupply"]) ?? 0
            }
            if usbPortTypeCode == nil {
                usbPortTypeCode = decodeUSBPortTypeCode(from: parentProperties["USBPortType"])
                    ?? decodeUSBPortTypeCode(from: parentProperties["usb-port-type"])
                    ?? decodeUSBPortTypeCode(from: parentProperties["port-type"])
            }
            if usbBusCurrentPoolID == 0 {
                usbBusCurrentPoolID = firstUInt64(in: parentProperties, keys: ["UsbBusCurrentPoolID"]) ?? 0
            }

            registryFacts.append(contentsOf: powerFacts(from: parentProperties))

            if let portStatistics = parentProperties["port-statistics"] as? [String: Any] {
                if overCurrentEventCount == 0 {
                    overCurrentEventCount = firstInt(in: portStatistics, keys: ["kPortStatOverCurrentCount"]) ?? 0
                }
                registryFacts.append(contentsOf: portStatisticFacts(from: portStatistics))
            }
        }

        return USBPowerDetails(
            reportedDeviceCurrentMilliamps: reportedDeviceCurrent,
            sinkAllocationMilliamps: sinkAllocation,
            wakePortCurrentLimitMilliamps: wakePortCurrentLimit,
            sleepPortCurrentLimitMilliamps: sleepPortCurrentLimit,
            hubPowerSupplyMilliamps: hubPowerSupply,
            usbPortTypeCode: usbPortTypeCode,
            usbBusCurrentPoolID: usbBusCurrentPoolID,
            overCurrentEventCount: overCurrentEventCount,
            powerRegistryFacts: orderedUniqueStrings(registryFacts)
        )
    }

    private func createUSBDevice(from service: io_service_t) -> USBDevice? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else { return nil }

        let vendorID = firstInt(in: props, keys: [kUSBVendorID]) ?? 0
        let productID = firstInt(in: props, keys: [kUSBProductID]) ?? 0
        let vendorName = firstString(in: props, keys: [kUSBVendorString, "USB Vendor Name", "kUSBVendorString"]) ?? ""
        let productName = firstString(in: props, keys: [kUSBProductString, "USB Product Name", "kUSBProductString"]) ?? ""
        let serialNumber = firstString(in: props, keys: [kUSBSerialNumberString, "kUSBSerialNumberString"]) ?? ""
        let deviceSpeed = firstInt(in: props, keys: [kUSBDeviceSpeed, "Device Speed", "speed"])
        let usbSpeed = firstInt(in: props, keys: ["USBSpeed"])
        let linkSpeedBitsPerSecond = Int64(firstInt(in: props, keys: ["UsbLinkSpeed"]) ?? 0)
        let deviceClass = firstInt(in: props, keys: [kUSBDeviceClass]) ?? 0
        let deviceSubClass = firstInt(in: props, keys: [kUSBDeviceSubClass]) ?? 0
        let deviceProtocol = firstInt(in: props, keys: [kUSBDeviceProtocol]) ?? 0
        let bcdUSB = firstInt(in: props, keys: ["bcdUSB"]) ?? 0
        let descriptorMaxPower = normalizedDescriptorPowerMilliamps(rawValue: firstInt(in: props, keys: [kUSBMaxPower, "bMaxPower"]) ?? 0, bcdUSB: bcdUSB)
        let deviceCurrent = firstInt(in: props, keys: ["Device Current"]) ?? 0
        let sinkAllocation = firstInt(in: props, keys: ["UsbPowerSinkAllocation"]) ?? 0
        let maxPower = sinkAllocation > 0 ? sinkAllocation : (deviceCurrent > 0 ? deviceCurrent : descriptorMaxPower)
        let bcdDevice = firstInt(in: props, keys: ["bcdDevice"]) ?? 0
        let locationID = firstUInt32(in: props, keys: [kUSBDevicePropertyLocationID]) ?? 0

        // Extended properties
        let currentAvailable = firstInt(in: props, keys: ["AAPL,current-available", "Current Available"]) ?? 0
        let extraCurrent = firstInt(in: props, keys: ["AAPL,current-extra-in-sleep"]) ?? 0
        let busPower = firstInt(in: props, keys: ["Bus Power Available"]) ?? 0
        let isCaptive = firstBool(in: props, keys: ["non-removable", "Captive"]) ?? false
        let isInternal = firstBool(in: props, keys: ["internal", "Built-In"]) ?? false
        let sleepCurrent = firstInt(in: props, keys: ["Sleep Current", "AAPL,sleep-current"]) ?? 0
        let sessionID = firstUInt64(in: props, keys: ["sessionID"]) ?? 0
        let currentConfiguration = firstInt(in: props, keys: ["kUSBCurrentConfiguration"]) ?? 0
        let portType = firstString(in: props, keys: ["port-type", "Port Type", "USBPortType"]) ?? "Standard"
        let powerDetails = collectUSBPowerDetails(
            for: service,
            baseProperties: props,
            reportedDeviceCurrent: deviceCurrent,
            sinkAllocation: sinkAllocation
        )
        let interfaces = scanUSBInterfaces(for: service)
        let speed = USBSpeed.resolve(deviceSpeed: deviceSpeed, usbSpeed: usbSpeed, linkSpeedBitsPerSecond: linkSpeedBitsPerSecond)

        // Determine device name
        var name = productName.isEmpty ? vendorName : productName
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            if IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS {
                name = String(cString: nameBuffer)
            }
        }
        if name.isEmpty || name == "IOUSBHostDevice" {
            name = "USB Device (\(String(format: "%04X:%04X", vendorID, productID)))"
        }

        // USB version
        let usbVersion: String
        if bcdUSB > 0 {
            let major = (bcdUSB >> 8) & 0xFF
            let minor = (bcdUSB >> 4) & 0x0F
            let patch = bcdUSB & 0x0F
            usbVersion = "\(major).\(minor)\(patch > 0 ? ".\(patch)" : "")"
        } else {
            usbVersion = speed.usbVersionString
        }

        // Try to determine parent controller
        var parentName = ""
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            var parentNameBuffer = [CChar](repeating: 0, count: 256)
            if IORegistryEntryGetName(parent, &parentNameBuffer) == KERN_SUCCESS {
                parentName = String(cString: parentNameBuffer)
            }
        }

        // Raw properties for debugging/advanced view
        let rawProps = rawPropertyStrings(from: props)

        let effectiveClass = deviceClass == 0 ? Set(interfaces.map { $0.interfaceClass }.filter { $0 != 0 }).first ?? 0 : deviceClass
        let isHub = effectiveClass == 9
        let portCount = firstInt(in: props, keys: ["Ports", "PortCount"]) ?? 0
        let stableID = stableUSBDeviceID(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            sessionID: sessionID,
            locationID: locationID,
            name: name
        )

        return USBDevice(
            id: stableID,
            name: name,
            vendorID: vendorID,
            productID: productID,
            vendorName: vendorName,
            productName: productName,
            serialNumber: serialNumber,
            speed: speed,
            deviceClass: deviceClass,
            deviceSubClass: deviceSubClass,
            deviceProtocol: deviceProtocol,
            maxPower: maxPower,
            descriptorMaxPowerMilliamps: descriptorMaxPower,
            usbVersion: usbVersion,
            bcdUSB: bcdUSB,
            locationID: locationID,
            isHub: isHub,
            portCount: portCount,
            bcdDevice: bcdDevice,
            currentAvailable: currentAvailable,
            extraCurrentInSleep: extraCurrent,
            busPowerAvailable: busPower,
            isCaptive: isCaptive,
            isInternal: isInternal,
            sleepCurrent: sleepCurrent,
            sessionID: sessionID,
            currentConfiguration: currentConfiguration,
            linkSpeedBitsPerSecond: linkSpeedBitsPerSecond,
            portType: portType,
            powerDetails: powerDetails,
            parentControllerName: parentName,
            interfaces: interfaces,
            rawProperties: rawProps
        )
    }

    private func scanUSBInterfaces(for service: io_service_t) -> [USBInterfaceInfo] {
        var interfaces: [USBInterfaceInfo] = []
        var iterator: io_iterator_t = 0

        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return interfaces
        }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let interface = createUSBInterface(from: child) {
                interfaces.append(interface)
            }
        }

        return interfaces.sorted {
            if $0.interfaceNumber == $1.interfaceNumber {
                return $0.alternateSetting < $1.alternateSetting
            }
            return $0.interfaceNumber < $1.interfaceNumber
        }
    }

    private func createUSBInterface(from service: io_service_t) -> USBInterfaceInfo? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any],
              let interfaceClass = firstInt(in: props, keys: ["bInterfaceClass"]) else {
            return nil
        }

        let speed = USBSpeed.resolve(
            deviceSpeed: nil,
            usbSpeed: firstInt(in: props, keys: ["USBSpeed"]),
            linkSpeedBitsPerSecond: 0
        )

        return USBInterfaceInfo(
            interfaceNumber: firstInt(in: props, keys: ["bInterfaceNumber"]) ?? 0,
            alternateSetting: firstInt(in: props, keys: ["bAlternateSetting"]) ?? 0,
            interfaceClass: interfaceClass,
            interfaceSubClass: firstInt(in: props, keys: ["bInterfaceSubClass"]) ?? 0,
            interfaceProtocol: firstInt(in: props, keys: ["bInterfaceProtocol"]) ?? 0,
            endpointCount: firstInt(in: props, keys: ["bNumEndpoints"]) ?? 0,
            exclusiveOwner: firstString(in: props, keys: ["UsbExclusiveOwner"]) ?? "",
            speed: speed,
            rawProperties: rawPropertyStrings(from: props)
        )
    }
}

// MARK: - View Mode
enum ViewMode: String, CaseIterable {
    case devices = "Devices"
    case displays = "Displays"
    case controllers = "Controllers"
    case thunderbolt = "Thunderbolt"
    case macos27 = "macOS 27 Suite"
    case rawData = "Overview & Log"

    var icon: String {
        switch self {
        case .devices: return "cable.connector"
        case .displays: return "display"
        case .controllers: return "cpu"
        case .thunderbolt: return "bolt.horizontal"
        case .macos27: return "apple.intelligence"
        case .rawData: return "list.bullet.rectangle"
        }
    }
}

struct USBHierarchyNode: Identifiable, Hashable {
    let device: USBDevice
    let children: [USBHierarchyNode]?

    var id: String { device.id }
}

struct USBHierarchySection: Identifiable, Hashable {
    let controllerName: String
    let controller: USBController?
    let roots: [USBHierarchyNode]
    let visibleDeviceCount: Int

    var id: String {
        controller?.id ?? controllerName
    }
}

private func usbPathIsPrefix(_ prefix: [Int], of candidate: [Int]) -> Bool {
    guard prefix.count <= candidate.count else { return false }
    return zip(prefix, candidate).allSatisfy(==)
}

private func usbHierarchySort(_ lhs: USBDevice, _ rhs: USBDevice) -> Bool {
    if lhs.portPathComponents != rhs.portPathComponents {
        return lhs.portPathComponents.lexicographicallyPrecedes(rhs.portPathComponents)
    }

    if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    return lhs.hierarchyIdentityLine.localizedCaseInsensitiveCompare(rhs.hierarchyIdentityLine) == .orderedAscending
}

private func usbDirectParent(of candidate: USBDevice, within devices: [USBDevice]) -> USBDevice? {
    guard !candidate.portPathComponents.isEmpty else { return nil }

    return devices
        .filter {
            $0.id != candidate.id &&
            $0.controllerGroupName == candidate.controllerGroupName &&
            $0.isHub &&
            !$0.portPathComponents.isEmpty &&
            $0.portPathComponents.count < candidate.portPathComponents.count &&
            usbPathIsPrefix($0.portPathComponents, of: candidate.portPathComponents)
        }
        .max { lhs, rhs in
            lhs.portPathComponents.count < rhs.portPathComponents.count
        }
}

private func buildUSBHierarchyTree(from devices: [USBDevice]) -> [USBHierarchyNode] {
    let sortedDevices = devices.sorted(by: usbHierarchySort)

    func children(for parent: USBDevice?) -> [USBHierarchyNode] {
        let matchingDevices = sortedDevices.filter { candidate in
            let directParent = usbDirectParent(of: candidate, within: sortedDevices)
            if let parent {
                return directParent?.id == parent.id
            }
            return directParent == nil
        }

        return matchingDevices.map { device in
            let nestedChildren = children(for: device)
            return USBHierarchyNode(device: device, children: nestedChildren.isEmpty ? nil : nestedChildren)
        }
    }

    return children(for: nil)
}

private func buildUSBHierarchySections(devices: [USBDevice], controllers: [USBController]) -> [USBHierarchySection] {
    let groupedDevices = Dictionary(grouping: devices, by: \.controllerGroupName)

    return groupedDevices.keys.sorted().compactMap { controllerName in
        let controllerDevices = groupedDevices[controllerName] ?? []
        let roots = buildUSBHierarchyTree(from: controllerDevices)
        guard !roots.isEmpty else { return nil }

        return USBHierarchySection(
            controllerName: controllerName,
            controller: controllers.first { $0.name == controllerName },
            roots: roots,
            visibleDeviceCount: controllerDevices.count
        )
    }
}

// MARK: - Content View
struct USBInspectorProContentView: View {
    @ObservedObject private var usbManager = USBManager.shared
    @ObservedObject private var displayInventory = ConnectedDisplayInventory.shared
    @State private var selectedDisplayID: UInt32?
    @State private var selectedDeviceID: USBDevice.ID?
    @State private var selectedControllerID: USBController.ID?
    @State private var selectedThunderboltID: ThunderboltDevice.ID?
    @State private var searchText = ""
    @AppStorage("hardware.viewMode") private var viewMode: ViewMode = .devices
    @State private var showRawProperties = false

    var filteredDevices: [USBDevice] {
        if searchText.isEmpty { return usbManager.devices }
        return usbManager.devices.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.vendorName.localizedCaseInsensitiveContains(searchText) ||
            $0.productName.localizedCaseInsensitiveContains(searchText) ||
            $0.classInfo.name.localizedCaseInsensitiveContains(searchText) ||
            $0.classSource.localizedCaseInsensitiveContains(searchText) ||
            $0.vendorIDHex.localizedCaseInsensitiveContains(searchText) ||
            $0.productIDHex.localizedCaseInsensitiveContains(searchText) ||
            $0.serialNumber.localizedCaseInsensitiveContains(searchText) ||
            $0.translationSearchText.localizedCaseInsensitiveContains(searchText) ||
            $0.interfaces.contains {
                $0.classInfo.name.localizedCaseInsensitiveContains(searchText) ||
                $0.meaning.technicalLabel.localizedCaseInsensitiveContains(searchText) ||
                $0.meaning.plainEnglish.localizedCaseInsensitiveContains(searchText) ||
                $0.exclusiveOwner.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var hierarchyDevices: [USBDevice] {
        guard !searchText.isEmpty else { return usbManager.devices }

        var includedIDs = Set(filteredDevices.map(\.id))
        guard !includedIDs.isEmpty else { return [] }

        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for device in usbManager.devices where includedIDs.contains(device.id) {
                if let parent = usbDirectParent(of: device, within: usbManager.devices), includedIDs.insert(parent.id).inserted {
                    madeProgress = true
                }
            }
        }

        return usbManager.devices.filter { includedIDs.contains($0.id) }
    }

    var deviceHierarchySections: [USBHierarchySection] {
        buildUSBHierarchySections(devices: hierarchyDevices, controllers: usbManager.controllers)
    }

    var selectedDevice: USBDevice? {
        guard let selectedDeviceID else { return nil }
        return usbManager.devices.first { $0.id == selectedDeviceID }
    }

    var selectedController: USBController? {
        guard let selectedControllerID else { return nil }
        return usbManager.controllers.first { $0.id == selectedControllerID }
    }

    var selectedThunderbolt: ThunderboltDevice? {
        guard let selectedThunderboltID else { return nil }
        return usbManager.thunderboltDevices.first { $0.id == selectedThunderboltID }
    }

    func attachedDevices(for controller: USBController) -> [USBDevice] {
        usbManager.devices.filter { $0.controllerGroupName == controller.name }
    }

    func activeStorageDeviceCount(for controller: USBController) -> Int {
        attachedDevices(for: controller).filter { usbManager.liveDeviceActivity[$0.id]?.isBusy == true }.count
    }

    func performanceLimitedDeviceCount(for controller: USBController) -> Int {
        attachedDevices(for: controller).filter(\.isPerformanceLimited).count
    }

    var body: some View {
        // This browser must stay visible even when the app's outer sidebar is hidden.
        // Nested navigation sidebars shared collapse behavior and stranded an empty detail.
        HSplitView {
            VStack(spacing: 0) {
                // Mode Picker
                ViewThatFits(in: .horizontal) {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()

                Divider()

                // Stats Header
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { viewMode = .devices } label: {
                            StatBadge(label: "USB", count: usbManager.devices.count, color: Pastel.sky)
                        }.buttonStyle(.plain).help("Show USB devices")
                        Button { viewMode = .displays } label: {
                            StatBadge(label: "Displays", count: displayInventory.displays.count, color: Pastel.aqua)
                        }.buttonStyle(.plain).help("Show connected monitors and their controls")
                        StatBadge(label: "Controllers", count: usbManager.controllers.count, color: Pastel.mint)
                        StatBadge(label: "TB", count: usbManager.thunderboltDevices.count, color: Pastel.lavender)
                        StatBadge(label: "HID", count: usbManager.hidDevices.count, color: Pastel.aqua)
                        StatBadge(label: "AV", count: usbManager.audioPeripherals.count + usbManager.videoPeripherals.count, color: Pastel.periwinkle)
                        StatBadge(label: "Active I/O", count: usbManager.liveDeviceActivity.values.filter { $0.isBusy }.count, color: Pastel.peach)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                Divider()

                // Content based on mode
                Group {
                    switch viewMode {
                    case .devices:
                        deviceListView
                    case .displays:
                        displayListView
                    case .controllers:
                        controllerListView
                    case .thunderbolt:
                        thunderboltListView
                    case .macos27:
                        macos27SidebarListView
                    case .rawData:
                        rawDataListView
                    }
                }

                Divider()

                // Footer
                footerView
            }
            // Chosen reading widths; this is an always-present hardware browser, not navigation chrome.
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 620, maxHeight: .infinity)
            detailView.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $searchText, prompt: "Search...")
        .navigationTitle("Hardware, Displays & USB")
        .onAppear {
            if viewMode == .displays, selectedDisplayID == nil { selectedDisplayID = displayInventory.displays.first?.id }
        }
        .onChange(of: displayInventory.displays) { _, displays in
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first?.id
            }
        }
        .onChange(of: viewMode) { _, mode in
            if mode == .displays {
                displayInventory.refresh()
                if selectedDisplayID == nil { selectedDisplayID = displayInventory.displays.first?.id }
            }
        }
        .onChange(of: usbManager.devices) { _, devices in
            if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
                self.selectedDeviceID = nil
            }
        }
        .onChange(of: usbManager.controllers) { _, controllers in
            if let selectedControllerID, !controllers.contains(where: { $0.id == selectedControllerID }) {
                self.selectedControllerID = nil
            }
        }
        .onChange(of: usbManager.thunderboltDevices) { _, thunderboltDevices in
            if let selectedThunderboltID, !thunderboltDevices.contains(where: { $0.id == selectedThunderboltID }) {
                self.selectedThunderboltID = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showRawProperties.toggle() }) {
                    Image(systemName: showRawProperties ? "doc.text.fill" : "doc.text")
                }
                .help("Toggle raw properties")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { usbManager.refreshAll(); displayInventory.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    // MARK: - Device List
    var displayListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected screens").font(.headline).padding(.horizontal)
            Text("Pick a monitor to inspect its current desktop, scaling and reported modes.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal)
            if let error = displayInventory.error {
                Text(error).foregroundStyle(.orange).padding(.horizontal)
            }
            if let updated = displayInventory.updated {
                Text("Last successful scan: \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            List(selection: $selectedDisplayID) {
                ForEach(displayInventory.displays.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }) { display in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.title).fontWeight(.semibold)
                            Text(display.desktopMode).font(.caption).foregroundStyle(.secondary)
                            Text(display.main ? "Main display" : (display.builtIn ? "Built-in" : "External monitor"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: display.builtIn ? "laptopcomputer" : "display") }
                    .tag(display.id)
                }
            }
            if displayInventory.displays.isEmpty, displayInventory.error == nil {
                Text("macOS returned no online displays. Refresh to check again.").foregroundStyle(.secondary).padding()
            }
        }
        .padding(.top, 12)
    }

    var deviceListView: some View {
        Group {
            if deviceHierarchySections.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "No USB Devices" : "No Matching Devices", systemImage: searchText.isEmpty ? "cable.connector" : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty ? "Connect a USB device or refresh the scan to populate the hierarchy." : "Try a broader search term or clear the search to see the full controller and hub tree.")
                }
            } else {
                List(selection: $selectedDeviceID) {
                    ForEach(deviceHierarchySections) { section in
                        SwiftUI.Section {
                            OutlineGroup(section.roots, children: \.children) { node in
                                DeviceRow(device: node.device, activity: usbManager.liveDeviceActivity[node.device.id])
                                    .tag(node.device.id)
                            }
                        } header: {
                            DeviceHierarchySectionHeader(section: section)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Controller List
    var controllerListView: some View {
        VStack(spacing: 12) {
            UsageGuideCard(
                icon: "cpu",
                title: "How to use Controllers",
                summary: "This tab is about path ownership. Open it when you need to know which chip owns a slow device, which hubs share the same bandwidth, or which branch a problem device lives under.",
                accent: .blue,
                tips: [
                    "If a drive is slower than expected, check whether it landed on an older controller.",
                    "Use Port Map to see what is hanging off the same controller before blaming the device itself.",
                    "Use Devices On This Controller when you want the full shared-bandwidth picture."
                ]
            )
            .padding(.horizontal)
            .padding(.top, 12)

            List(usbManager.controllers, selection: $selectedControllerID) { controller in
                ControllerRow(
                    controller: controller,
                    attachedDeviceCount: attachedDevices(for: controller).count,
                    activeDeviceCount: activeStorageDeviceCount(for: controller),
                    slowDeviceCount: performanceLimitedDeviceCount(for: controller)
                )
                .tag(controller.id)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Thunderbolt List
    var thunderboltListView: some View {
        VStack(spacing: 12) {
            UsageGuideCard(
                icon: "bolt.horizontal.fill",
                title: "How to use Thunderbolt",
                summary: "This tab is for docks, displays, USB4/Thunderbolt paths, and route diagnosis. Some entries are just ports or routing nodes, so not everything here is a user-facing gadget.",
                accent: .purple,
                tips: [
                    "If a dock, display, or premium SSD feels wrong, check the current link speed here first.",
                    "Port and switch entries are infrastructure. They help you trace the route, not open files in Finder.",
                    "If the names look kernel-ish, click in anyway: the detail page now translates what the entry actually is."
                ]
            )
            .padding(.horizontal)
            .padding(.top, 12)

            if usbManager.thunderboltDevices.isEmpty {
                ContentUnavailableView {
                    Label("No Thunderbolt Devices", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("No Thunderbolt ports or devices detected. Thunderbolt ports look like USB-C but have a ⚡ lightning bolt symbol next to them.")
                }
            } else {
                List(usbManager.thunderboltDevices, selection: $selectedThunderboltID) { device in
                    ThunderboltRow(device: device)
                        .tag(device.id)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Raw Data List
    var rawDataListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scan Log")
                    .font(.headline)
                    .padding(.horizontal)

                ForEach(usbManager.scanLog.reversed(), id: \.self) { log in
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Footer
    var footerView: some View {
        HStack {
            if usbManager.isScanning {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Scanning...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Updated: \(usbManager.lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                let activeCount = usbManager.liveDeviceActivity.values.filter { $0.isBusy }.count
                if activeCount > 0 {
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(activeCount == 1 ? "1 storage device active" : "\(activeCount) storage devices active")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Detail View
    @ViewBuilder
    var detailView: some View {
        switch viewMode {
        case .displays:
            if let display = displayInventory.displays.first(where: { $0.id == selectedDisplayID }) {
                ConnectedDisplayDetailView(display: display)
            } else {
                ContentUnavailableView("Select a Display", systemImage: "display", description: Text("Select a connected monitor to see its live mode, identity and connection evidence."))
            }
        case .devices:
            if let device = selectedDevice {
                DeviceDetailView(
                    device: device,
                    allDevices: usbManager.devices,
                    deviceActivity: usbManager.liveDeviceActivity[device.id],
                    allDeviceActivityLookup: usbManager.liveDeviceActivity,
                    diskActivityLookup: usbManager.liveDiskActivity,
                    volumeStateLookup: usbManager.liveVolumeState,
                    showRaw: showRawProperties,
                    onRefresh: usbManager.refreshAll
                )
            } else {
                ContentUnavailableView {
                    Label("Select a Device", systemImage: "cable.connector")
                } description: {
                    Text("Click on any USB device in the list to see detailed information about its speed, power usage, and capabilities.")
                }
            }
        case .controllers:
            if let controller = selectedController {
                ControllerDetailView(
                    controller: controller,
                    devices: usbManager.devices,
                    deviceActivityLookup: usbManager.liveDeviceActivity,
                    volumeStateLookup: usbManager.liveVolumeState,
                    showRaw: showRawProperties
                )
            } else {
                ContentUnavailableView {
                    Label("Select a Controller", systemImage: "cpu")
                } description: {
                    Text("Use Controllers to answer which chip owns a path, which devices are sharing bandwidth, and whether a slow device is stuck behind an older controller or hub chain.")
                }
            }
        case .thunderbolt:
            if let device = selectedThunderbolt {
                ThunderboltDetailView(device: device, showRaw: showRawProperties)
            } else {
                ContentUnavailableView {
                    Label("Select a Thunderbolt Device", systemImage: "bolt.horizontal")
                } description: {
                    Text("Use Thunderbolt to trace docks, displays, and high-speed SSD paths. Port and switch entries are routing infrastructure, while some entries represent actual connected devices.")
                }
            }
        case .macos27:
            MacOS27HardwareSuiteDetailView(
                manager: usbManager,
                selectedDevice: selectedDevice,
                selectedController: selectedController,
                selectedThunderbolt: selectedThunderbolt,
                onSelectDevice: { id in
                    selectedDeviceID = id
                    viewMode = .devices
                }
            )
        case .rawData:
            RawDataOverview(manager: usbManager)
        }
    }
}

// MARK: - Stat Badge
struct StatBadge: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        let resolved = Pastel.resolve(color) ?? color
        HStack(spacing: 5) {
            Text("\(count)")
                .fontWeight(.bold)
                .foregroundStyle(resolved)
            Text(label)
                .foregroundStyle(.primary.opacity(0.9))
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(resolved.opacity(0.15), in: .capsule)
        .overlay(Capsule().strokeBorder(resolved.opacity(0.35), lineWidth: 0.8))
    }
}

struct UsageGuideCard: View {
    let icon: String
    let title: String
    let summary: String
    let accent: Color
    let tips: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(accent)
                Text(title)
                    .font(.headline)
            }

            Text(summary)
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.caption)
                            .foregroundColor(accent)
                            .padding(.top, 3)
                        Text(tip)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(accent.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Device Row
struct DeviceRow: View {
    let device: USBDevice
    let activity: DeviceStorageActivity?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.classInfo.icon)
                .font(.title2)
                .foregroundColor(device.speed.color)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)

                if !device.rowSubtitle.isEmpty {
                    Text(device.rowSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(device.hierarchyIdentityLine)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let activity, let badgeText = activity.compactBadgeText {
                    Text(badgeText)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(activity.direction.color)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(device.negotiatedSpeedDescription)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(device.speed.color.opacity(0.2))
                        .cornerRadius(4)

                    if device.isPerformanceLimited {
                        Text("Below spec")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    if device.isInternal {
                        Image(systemName: "internaldrive")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if device.isCompositeDevice {
                        Image(systemName: "square.stack.3d.up")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Quality indicator
            Circle()
                .fill(device.connectionQuality.color)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

struct DeviceHierarchySectionHeader: View {
    let section: USBHierarchySection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.blue)
                Text(section.controllerName)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(section.visibleDeviceCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let controller = section.controller {
                Text(controller.controllerType)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("Controller or host path grouping")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .textCase(nil)
    }
}

struct USBHierarchyBranchView: View {
    let node: USBHierarchyNode
    var showVolumes: Bool = true
    var deviceActivityLookup: [String: DeviceStorageActivity] = [:]
    var volumeStateLookup: [String: LiveMountedVolumeState] = [:]

    var body: some View {
        let deviceActivity = deviceActivityLookup[node.device.id]

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.device.classInfo.icon)
                    .foregroundColor(node.device.speed.color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(node.device.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if !node.device.rowSubtitle.isEmpty {
                        Text(node.device.rowSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(node.device.hierarchyIdentityLine)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let deviceActivity, let badgeText = deviceActivity.compactBadgeText {
                        Text(badgeText)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(deviceActivity.direction.color)
                    }

                    if let children = node.children, !children.isEmpty {
                        Text(children.count == 1 ? "1 downstream child" : "\(children.count) downstream children")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(node.device.negotiatedSpeedDescription)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(node.device.speed.color.opacity(0.18))
                    .cornerRadius(5)
            }

            if showVolumes && !node.device.mountedVolumes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.device.mountedVolumes) { volume in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "internaldrive")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .frame(width: 14)

                                Text(volume.displayName)
                                    .font(.caption)

                                Spacer()

                                Text(volume.bsdName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let liveVolume = volumeStateLookup[volume.bsdName] {
                                HStack(spacing: 8) {
                                    Text(liveVolume.freeDescription)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    if let freeChangeDescription = liveVolume.freeChangeDescription {
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(freeChangeDescription)
                                            .font(.caption2)
                                            .foregroundColor(freeChangeDescription.contains("dropping") ? .orange : .green)
                                    }
                                }
                                .padding(.leading, 22)
                            }
                        }
                    }
                }
                .padding(.leading, 28)
            }

            if let children = node.children, !children.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(children) { child in
                        USBHierarchyBranchView(
                            node: child,
                            showVolumes: showVolumes,
                            deviceActivityLookup: deviceActivityLookup,
                            volumeStateLookup: volumeStateLookup
                        )
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct USBPortOccupancy: Identifiable, Hashable {
    let portNumber: Int
    let occupant: USBDevice?
    let descendantCount: Int

    var id: Int { portNumber }
}

struct USBPortMapView: View {
    let basePath: [Int]
    let observedDevices: [USBDevice]
    let knownPortCount: Int?
    var deviceActivityLookup: [String: DeviceStorageActivity] = [:]

    private var occupancies: [USBPortOccupancy] {
        let grouped = Dictionary(grouping: observedDevices.filter { candidate in
            candidate.portPathComponents.count > basePath.count &&
            usbPathIsPrefix(basePath, of: candidate.portPathComponents)
        }) { candidate in
            candidate.portPathComponents[basePath.count]
        }

        let visiblePorts: [Int]
        if let knownPortCount, knownPortCount > 0 {
            visiblePorts = Array(1...max(knownPortCount, grouped.keys.max() ?? 0))
        } else {
            visiblePorts = grouped.keys.sorted()
        }

        return visiblePorts.map { portNumber in
            let portDevices = (grouped[portNumber] ?? []).sorted { lhs, rhs in
                if lhs.portPathComponents.count != rhs.portPathComponents.count {
                    return lhs.portPathComponents.count < rhs.portPathComponents.count
                }
                return usbHierarchySort(lhs, rhs)
            }

            return USBPortOccupancy(
                portNumber: portNumber,
                occupant: portDevices.first,
                descendantCount: max(portDevices.count - 1, 0)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Observed port occupancy")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if occupancies.isEmpty {
                Text("No downstream devices are currently visible on this branch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(occupancies) { occupancy in
                    HStack(alignment: .top, spacing: 12) {
                        Text("Port \(occupancy.portNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 52, alignment: .leading)

                        if let occupant = occupancy.occupant {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(occupant.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text(occupant.hierarchyIdentityLine)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                if let activity = deviceActivityLookup[occupant.id], let badgeText = activity.compactBadgeText {
                                    Text(badgeText)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundColor(activity.direction.color)
                                }

                                if occupancy.descendantCount > 0 {
                                    Text(occupancy.descendantCount == 1 ? "1 downstream device continues through this branch" : "\(occupancy.descendantCount) downstream devices continue through this branch")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Text(occupant.negotiatedSpeedDescription)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(occupant.speed.color.opacity(0.18))
                                .cornerRadius(5)
                        } else {
                            Text("Empty / no device observed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Controller Row
struct ControllerRow: View {
    let controller: USBController
    let attachedDeviceCount: Int
    let activeDeviceCount: Int
    let slowDeviceCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundColor(controller.supportsUSB3 ? .green : .yellow)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if let technicalName = controller.technicalNameDescription {
                    Text(technicalName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(controller.controllerType)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(controller.supportsUSB3 ? Color.green.opacity(0.2) : Color.yellow.opacity(0.2))
                        .cornerRadius(4)

                    if controller.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text(attachedDeviceCount == 1 ? "1 device" : "\(attachedDeviceCount) devices")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if activeDeviceCount > 0 {
                        Text(activeDeviceCount == 1 ? "1 active" : "\(activeDeviceCount) active")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    if slowDeviceCount > 0 {
                        Text(slowDeviceCount == 1 ? "1 limited" : "\(slowDeviceCount) limited")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thunderbolt Row
struct ThunderboltRow: View {
    let device: ThunderboltDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.title2)
                .foregroundColor(device.color)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if !device.userFacingSubtitle.isEmpty {
                    Text(device.userFacingSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(device.generationString)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(device.color.opacity(0.2))
                        .cornerRadius(4)

                    Text(device.roleTitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device Detail View
struct VolumeEjectRequest: Identifiable {
    let volume: StorageVolumeInfo
    let otherMountedVolumes: [String]
    var id: String { volume.id }
}

/// Names the volume, says who has it open, and only then offers Eject. A sheet and not a dialog,
/// because the check can take seconds and a dialog's text can't change while it is up.
struct VolumeEjectSheet: View {
    let request: VolumeEjectRequest
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var use: ComputerVolumeUse?

    private var review: ComputerEjectReview {
        ComputerEjectReview.make(volumeName: request.volume.displayName, use: use, otherMountedVolumes: request.otherMountedVolumes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.headline)
            Text(request.volume.mountPath).font(.caption.monospaced()).foregroundStyle(.secondary)
            if use == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking what is using this volume...").font(.callout)
                }
            } else if review.warnings.isEmpty {
                Text("Nothing in your account has files open here.").font(.callout)
            }
            ForEach(review.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This check sees only processes in your own account.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(review.confirmTitle) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(use == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: request.id) {
            let path = request.volume.mountPath
            use = await Task.detached(priority: .userInitiated) { () -> ComputerVolumeUse in
                do {
                    // -b and -w keep a stalled volume from hanging the check, and it still found a
                    // file held open on a card. Chosen, not measured: 25 s, because lsof has taken
                    // 20 s here. Cancel doesn't stop it, so it can run on to that limit.
                    let run = try BoundedProcess.run(executable: "/usr/sbin/lsof", arguments: ["-n", "-P", "-b", "-w", "-Fpc", "--", path], timeout: 25)
                    return ComputerVolumeUse.parse(stdout: run.stdoutText, stderr: run.stderrText, status: run.status, timedOut: run.timedOut)
                } catch {
                    return ComputerVolumeUse(state: .unknown(reason: error.localizedDescription))
                }
            }.value
        }
    }
}

struct DeviceDetailView: View {
    let device: USBDevice
    let allDevices: [USBDevice]
    let deviceActivity: DeviceStorageActivity?
    let allDeviceActivityLookup: [String: DeviceStorageActivity]
    let diskActivityLookup: [String: LiveWholeDiskActivity]
    let volumeStateLookup: [String: LiveMountedVolumeState]
    let showRaw: Bool
    let onRefresh: () -> Void
    @State private var expandedSections: Set<String> = ["translation", "activity", "speed", "device", "volumes", "interfaces", "power", "quality"]
    @State private var volumeActionStatus: String?
    @State private var ejectRequest: VolumeEjectRequest?

    private func isPrefixPath(_ prefix: [Int], of candidate: [Int]) -> Bool {
        guard prefix.count <= candidate.count else { return false }
        return zip(prefix, candidate).allSatisfy(==)
    }

    private func directParent(for candidate: USBDevice) -> USBDevice? {
        guard !candidate.portPathComponents.isEmpty else { return nil }

        return allDevices
            .filter {
                $0.id != candidate.id &&
                $0.controllerGroupName == candidate.controllerGroupName &&
                $0.isHub &&
                !$0.portPathComponents.isEmpty &&
                $0.portPathComponents.count < candidate.portPathComponents.count &&
                isPrefixPath($0.portPathComponents, of: candidate.portPathComponents)
            }
            .max { lhs, rhs in
                lhs.portPathComponents.count < rhs.portPathComponents.count
            }
    }

    private var upstreamChain: [USBDevice] {
        var chain: [USBDevice] = []
        var current = directParent(for: device)

        while let node = current {
            chain.append(node)
            current = directParent(for: node)
        }

        return chain.reversed()
    }

    private var downstreamChildren: [USBDevice] {
        guard device.isHub else { return [] }
        return allDevices
            .filter { directParent(for: $0)?.id == device.id }
            .sorted {
                if $0.portPathComponents != $1.portPathComponents {
                    return $0.portPathComponents.lexicographicallyPrecedes($1.portPathComponents)
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var liveWholeDiskActivity: [LiveWholeDiskActivity] {
        Array(Set(device.sortedStorageVolumes.map(\.wholeDiskBSDName)))
            .sorted()
            .compactMap { diskActivityLookup[$0] }
    }

    private func revealInFinder(_ volume: StorageVolumeInfo) {
        guard volume.isMounted else { return }
        _ = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.mountPath)
        volumeActionStatus = "Opened \(volume.displayName) in Finder."
    }

    private func openVolume(_ volume: StorageVolumeInfo) {
        guard volume.isMounted else { return }
        let url = URL(fileURLWithPath: volume.mountPath)
        if NSWorkspace.shared.open(url) {
            volumeActionStatus = "Opened \(volume.displayName)."
        } else {
            volumeActionStatus = "macOS couldn't open \(volume.displayName)."
        }
    }

    private func copyMountPath(_ volume: StorageVolumeInfo) {
        guard volume.isMounted else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(volume.mountPath, forType: .string)
        volumeActionStatus = "Copied mount path for \(volume.displayName)."
    }

    private func ejectVolume(_ volume: StorageVolumeInfo) {
        guard volume.isMounted else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.mountPath))
            volumeActionStatus = "Requested eject for \(volume.displayName)."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                onRefresh()
            }
        } catch {
            volumeActionStatus = "macOS couldn't eject \(volume.displayName): \(error.localizedDescription) Close anything using it and try again."
        }
    }

    private func binding(for section: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                deviceHeader

                // On-Device FoundationModels AI Advisor bar for this device
                DeviceAIAdvisorCard(device: device, manager: USBManager.shared)

                Divider()

                CollapsibleSection(title: "🧠 Translation Layer", icon: "lightbulb", isExpanded: binding(for: "translation")) {
                    translationSection
                }

                if !device.storageVolumes.isEmpty {
                    CollapsibleSection(title: "📈 Live Activity", icon: "waveform.path.ecg", isExpanded: binding(for: "activity")) {
                        liveActivitySection
                    }
                }

                // Connection Quality Card
                qualityCard

                // Speed Section
                CollapsibleSection(title: "⚡ How Fast Is It?", icon: device.speed.icon, isExpanded: binding(for: "speed")) {
                    SpeedDetailView(device: device)
                }

                // Device Info Section
                CollapsibleSection(title: "📋 Device Details", icon: "info.circle", isExpanded: binding(for: "device")) {
                    deviceInfoSection
                }

                if !device.storageVolumes.isEmpty {
                    CollapsibleSection(title: "🗂 Finder & Disk Mapping", icon: "externaldrive", isExpanded: binding(for: "volumes")) {
                        volumeSection
                    }
                }

                if !device.interfaces.isEmpty {
                    CollapsibleSection(title: "🧩 Interface Breakdown", icon: "square.stack.3d.up", isExpanded: binding(for: "interfaces")) {
                        interfaceSection
                    }
                }

                // Technical Details
                CollapsibleSection(title: "🔧 Developer Info", icon: "gearshape.2", isExpanded: binding(for: "technical")) {
                    technicalSection
                }

                // Power Section
                CollapsibleSection(title: "🔋 Power Usage", icon: "bolt.fill", isExpanded: binding(for: "power")) {
                    powerSection
                }

                // Topology Section
                CollapsibleSection(title: "🔌 Connection Path", icon: "point.3.connected.trianglepath.dotted", isExpanded: binding(for: "topology")) {
                    topologySection
                }

                // Raw Properties
                if showRaw {
                    CollapsibleSection(title: "📄 Raw System Data", icon: "doc.text", isExpanded: binding(for: "raw")) {
                        rawPropertiesSection
                    }
                }

                Spacer(minLength: 50)
            }
            .padding(24)
        }
        .frame(minWidth: 450)
    }

    var deviceHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(device.speed.color.opacity(0.2))
                    .frame(width: 70, height: 70)
                Image(systemName: device.classInfo.icon)
                    .font(.system(size: 32))
                    .foregroundColor(device.speed.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.title2)
                    .fontWeight(.bold)

                HStack(spacing: 8) {
                    if !device.vendorDisplayName.isEmpty {
                        Text(device.vendorDisplayName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)
                    }

                    Text(device.classInfo.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(device.negotiatedSpeedDescription)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(device.speed.color.opacity(0.15))
                        .cornerRadius(6)
                }

                Text(device.translationHeadline)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let deviceActivity {
                    HStack(spacing: 6) {
                        Image(systemName: deviceActivity.direction.icon)
                            .font(.caption)
                            .foregroundColor(deviceActivity.direction.color)

                        Text(deviceActivity.isBusy ? (deviceActivity.compactBadgeText ?? deviceActivity.direction.label) : "Idle right now")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(deviceActivity.direction.color)
                    }
                }

                // Layman-friendly explanation
                Text(device.classInfo.layman)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()

                Text(device.classSource)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    var liveActivitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let deviceActivity {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: deviceActivity.direction.icon)
                        .foregroundColor(deviceActivity.direction.color)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(deviceActivity.direction.label)
                            .font(.headline)
                        Text(deviceActivity.summary)
                            .font(.callout)
                    }
                }

                if deviceActivity.direction == .idle, let lastActiveAt = deviceActivity.lastActiveAt {
                    Text("Last active \(relativeTimestampDescription(lastActiveAt)).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Waiting for the first live storage sample from macOS.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Divider()

            if liveWholeDiskActivity.isEmpty {
                Text("This device has Finder-visible storage objects, but macOS has not exposed a block-storage counter sample yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(liveWholeDiskActivity) { diskActivity in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(diskActivity.wholeDiskBSDName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            MetadataPill(text: diskActivity.direction.label, accent: diskActivity.direction.color)
                        }

                        Text(diskActivity.direction.explanation)
                            .font(.callout)

                        DetailRow(label: "Throughput", value: diskActivity.throughputSummary)
                        DetailRow(label: "Operations", value: diskActivity.operationSummary)

                        if let latencySummary = diskActivity.latencySummary {
                            DetailRow(label: "Latency", value: latencySummary)
                        }

                        if let reliabilitySummary = diskActivity.reliabilitySummary {
                            Text(reliabilitySummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let lastActiveAt = diskActivity.lastActiveAt, !diskActivity.isBusy {
                            Text("Last active \(relativeTimestampDescription(lastActiveAt)).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                }
            }

            Text("Powered by IOBlockStorageDriver statistics plus live mounted-volume capacity sampling.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    var translationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(device.translationHeadline)
                .font(.title3)
                .fontWeight(.semibold)

            if !device.translationBadges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(device.translationBadges.prefix(6)), id: \.self) { badge in
                            MetadataPill(text: badge, accent: device.speed.color)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text(device.translationSummary)
                .font(.callout)

            if let vendorContext = device.vendorContext {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vendor Context")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(vendorContext)
                        .font(.callout)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("What This Means on Your Mac")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(Array(device.userFacingBehaviors.prefix(4)), id: \.self) { behavior in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(device.speed.color)
                            .padding(.top, 3)
                        Text(behavior)
                            .font(.callout)
                    }
                }
            }

            if !device.translatedHighlights.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("What Makes This One Interesting")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(Array(device.translatedHighlights.prefix(4)), id: \.self) { highlight in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundColor(.secondary)
                                .padding(.top, 7)
                            Text(highlight)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }

    var qualityCard: some View {
        let quality = device.connectionQuality
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(quality.color)
                    .frame(width: 12, height: 12)
                Text("Connection Quality: \(quality.rating)")
                    .font(.headline)
                Spacer()
                Text("\(quality.score)/100")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(quality.color.opacity(0.2))
                    .cornerRadius(6)
            }

            // Summary explanation
            Text(quality.summary)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            // Detailed findings
            ForEach(quality.issues, id: \.self) { issue in
                Text(issue)
                    .font(.callout)
                    .foregroundColor(quality.score >= 80 ? .primary : .secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What is this device?
            if !device.productName.isEmpty || !device.vendorName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("📦 What is this?")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(device.productName.isEmpty ? device.vendorName : device.productName)
                        .font(.callout)
                    if !device.vendorName.isEmpty && !device.productName.isEmpty {
                        Text("Made by \(device.vendorName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Divider()
            }

            DetailRowWithHelp(label: "Serial Number", value: device.serialNumber.isEmpty ? "None" : device.serialNumber, help: "A unique ID for this specific device – useful for tracking or warranty")
            DetailRowWithHelp(label: "Device Version", value: device.bcdDeviceString, help: "The hardware/firmware version of this device")
            DetailRowWithHelp(label: "USB Version", value: device.usbVersion, help: "Which USB standard this device was built for")
            DetailRowWithHelp(label: "Negotiated Link", value: device.negotiatedSpeedDescription, help: "The actual link speed macOS reports for this connection")
            DetailRowWithHelp(label: "Classification", value: device.classSource, help: "Whether the device type came from the device descriptor or from interface descriptors")
            if !device.storageVolumes.isEmpty {
                DetailRowWithHelp(label: "Finder Volumes", value: device.volumeSummary, help: "Which mounted disks or disk objects macOS currently maps back to this physical USB device")
            }
            if device.currentConfiguration > 0 {
                DetailRowWithHelp(label: "Configuration", value: "\(device.currentConfiguration)", help: "The active USB configuration selected by macOS")
            }
            if device.isHub {
                DetailRowWithHelp(label: "Available Ports", value: "\(device.portCount) ports", help: "How many devices you can plug into this hub")
            }
        }
    }

    var volumeSection: some View {
        let groupedVolumes = Dictionary(grouping: device.sortedStorageVolumes, by: \.wholeDiskBSDName)
        let sortedWholeDisks = groupedVolumes.keys.sorted()

        return VStack(alignment: .leading, spacing: 12) {
            Text("This maps Finder-visible disks and volumes back to the physical USB device, so you can see what storage objects fall under this hardware.")
                .font(.caption)
                .foregroundColor(.secondary)
                .sheet(item: $ejectRequest) { request in
                    VolumeEjectSheet(request: request) { ejectVolume(request.volume) }
                }

            if let volumeActionStatus {
                Text(volumeActionStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(sortedWholeDisks, id: \.self) { wholeDiskBSDName in
                let group = groupedVolumes[wholeDiskBSDName] ?? []
                let wholeDisk = group.first(where: \.isWholeDisk)
                let children = group.filter { !$0.isWholeDisk }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Image(systemName: "externaldrive")
                            .foregroundColor(device.speed.color)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(wholeDisk?.displayName ?? wholeDiskBSDName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(wholeDisk?.subtitle ?? wholeDiskBSDName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(wholeDiskBSDName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let wholeDisk {
                        let transportDetails = orderedUniqueStrings([wholeDisk.deviceProtocol, wholeDisk.deviceModel]).joined(separator: " • ")
                        if !transportDetails.isEmpty {
                            Text(transportDetails)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let diskActivity = diskActivityLookup[wholeDiskBSDName] {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                MetadataPill(text: diskActivity.direction.label, accent: diskActivity.direction.color)
                                Spacer()
                                Text(diskActivity.throughputSummary)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(diskActivity.direction.color)
                            }

                            Text(diskActivity.operationSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let latencySummary = diskActivity.latencySummary {
                                Text(latencySummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let reliabilitySummary = diskActivity.reliabilitySummary {
                                Text(reliabilitySummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(10)
                        .background(diskActivity.direction.color.opacity(0.08))
                        .cornerRadius(8)
                    }

                    if children.isEmpty {
                        Text("No mounted Finder volumes are currently hanging off this disk object.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(children) { volume in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: volume.isMounted ? "internaldrive.fill" : "internaldrive")
                                        .font(.caption)
                                        .foregroundColor(volume.isMounted ? .green : .secondary)
                                    Text(volume.displayName)
                                        .font(.callout)
                                    Spacer()
                                    Text(volume.bsdName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Text(volume.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if volume.isMounted {
                                    if let liveState = volumeStateLookup[volume.bsdName] {
                                        Text(liveState.usageDescription)
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        if let usageFraction = liveState.usageFraction {
                                            ProgressView(value: usageFraction)
                                                .tint(device.speed.color)
                                        }

                                        HStack(spacing: 8) {
                                            Text(liveState.freeDescription)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)

                                            Text("•")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)

                                            Text(liveState.accessibilitySummary)
                                                .font(.caption2)
                                                .foregroundColor(liveState.isReadOnly ? .orange : .green)

                                            if let freeChangeDescription = liveState.freeChangeDescription {
                                                Text("•")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                Text(freeChangeDescription)
                                                    .font(.caption2)
                                                    .foregroundColor(freeChangeDescription.contains("dropping") ? .orange : .green)
                                            }
                                        }
                                    }

                                    Text(volume.mountDescription)
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if volume.availableBytes > 0 {
                                        Text("\(volume.availableDescription) free")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    HStack(spacing: 8) {
                                        Button("Open") { openVolume(volume) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        Button("Reveal") { revealInFinder(volume) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        Button("Copy Path") { copyMountPath(volume) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        Button("Eject…") {
                                            ejectRequest = VolumeEjectRequest(
                                                volume: volume,
                                                otherMountedVolumes: children.filter { $0.isMounted && $0.id != volume.id }.map(\.displayName))
                                        }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .tint(.orange)
                                    }
                                    .disabled(!volume.isMounted)
                                    .help(volume.isMounted ? "Actions for this mounted volume" : "Mount this volume in Disk Utility before using these actions.")
                                }
                            }
                            .padding(.leading, 26)
                        }
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
        }
    }

    var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS exposes composite-device functions as separate IOUSBHostInterface descriptors. This is the most reliable way to understand what a multi-function USB device actually does.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(device.interfaces) { interface in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Image(systemName: interface.classInfo.icon)
                            .foregroundColor(interface.speed.color)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(interface.meaning.technicalLabel)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(interface.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    Text(interface.meaning.plainEnglish)
                        .font(.callout)

                    Text(interface.meaning.macBehavior)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !interface.exclusiveOwner.isEmpty {
                        Text("Claimed by \(interface.exclusiveOwner)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let ownerExplanation = interface.ownerExplanation {
                        Text(ownerExplanation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(interface.meaning.uniqueness)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        Text(interface.technicalSignature)
                        if interface.alternateSetting > 0 {
                            Text("Alt \(interface.alternateSetting)")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
        }
    }

    var technicalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🔧 For Developers & Troubleshooting")
                .font(.caption)
                .foregroundColor(.secondary)

            DetailRow(label: "Vendor ID", value: device.vendorIDHex)
            DetailRow(label: "Product ID", value: device.productIDHex)
            DetailRow(label: "Primary Role", value: device.primaryMeaning.technicalLabel)
            DetailRow(label: "Device Class", value: "\(device.deviceClass) (\(device.classInfo.name))")
            DetailRow(label: "SubClass", value: "\(device.deviceSubClass)")
            DetailRow(label: "Protocol", value: "\(device.deviceProtocol)")
            DetailRow(label: "Interfaces", value: "\(device.interfaces.count)")
            DetailRow(label: "Negotiated Link", value: device.negotiatedSpeedDescription)
            DetailRow(label: "Port Type", value: device.portTypeDescription)
            if device.currentConfiguration > 0 {
                DetailRow(label: "Configuration", value: "\(device.currentConfiguration)")
            }
            if device.sessionID > 0 {
                DetailRow(label: "Session ID", value: String(format: "0x%016llX", device.sessionID))
            }
        }
    }

    var powerSection: some View {
        let comparisonPower = device.descriptorMaxPowerMilliamps > 0 ? device.descriptorMaxPowerMilliamps : device.maxPower
        let awakeBudget = device.bestAvailableAwakeCurrentMilliamps

        return VStack(alignment: .leading, spacing: 12) {
            Text("⚡ What power did macOS actually publish for this USB path?")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("This section separates descriptor requests, negotiated current budgeting, port current limits, and hub supply clues. Watt figures assume the normal 5V USB bus unless macOS publishes a richer PD contract, which it usually does not in these public registry properties.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Closest answer to 'how much is it taking?' ")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                DetailRow(label: "Closest published intake", value: device.closestPublishedIntakeDescription)
                DetailRow(label: "Port charging ceiling", value: device.chargingCeilingDescription)

                Text(device.drawInterpretationSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            if comparisonPower > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Power Budget")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if awakeBudget > 0 {
                            Text(comparisonPower > awakeBudget ? "⚠️ Above published port limit" : "✅ Within published port limit")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }

                    if awakeBudget > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.2))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(comparisonPower > awakeBudget ? Color.red : Color.green)
                                    .frame(width: geo.size.width * min(CGFloat(comparisonPower) / CGFloat(awakeBudget), 1.0))
                            }
                        }
                        .frame(height: 10)
                    }

                    Text("Negotiated budget: \(device.powerDescription)")
                        .font(.callout)

                    Text(device.powerNegotiationSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Published by macOS")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                DetailRow(label: "Descriptor request", value: device.descriptorPowerDescription)
                DetailRow(label: "Negotiated budget", value: device.powerDescription)
                if device.powerDetails.sinkAllocationMilliamps > 0 {
                    DetailRow(label: "Sink allocation", value: formatUSBPowerAssumingFiveVolts(device.powerDetails.sinkAllocationMilliamps))
                }
                if device.powerDetails.reportedDeviceCurrentMilliamps > 0 {
                    DetailRow(label: "Device current", value: formatUSBPowerAssumingFiveVolts(device.powerDetails.reportedDeviceCurrentMilliamps))
                }
                DetailRow(label: "Advertised available current", value: device.powerAvailableDescription)
                DetailRow(label: "Wake port limit", value: device.wakePortLimitDescription)
                DetailRow(label: "Sleep port limit", value: device.sleepPortLimitDescription)
                if device.powerDetails.hubPowerSupplyMilliamps > 0 {
                    DetailRow(label: "Hub power supply", value: device.hubPowerSupplyDescription)
                }
                DetailRow(label: "Port type code", value: device.portTypeDescription)
                if device.powerDetails.usbBusCurrentPoolID > 0 {
                    DetailRow(label: "Current pool", value: device.currentPoolDescription)
                }
                DetailRow(label: "Over-current history", value: device.overCurrentHistoryDescription)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("PD / USB-C visibility")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(device.pdVisibilitySummary)
                    .font(.callout)

                if comparisonPower > 500 {
                    Label("High-power device – may need a powered hub or direct connection", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if comparisonPower > 100 {
                    Label("Normal power usage – works with any USB port", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if comparisonPower > 0 {
                    Label("Low power device – very efficient!", systemImage: "leaf.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            if device.sleepCurrent > 0 || device.extraCurrentInSleep > 0 || device.powerDetails.sleepPortCurrentLimitMilliamps > 0 || device.powerDetails.wakePortCurrentLimitMilliamps > 0 {
                Divider()
                Text("Sleep / wake behavior")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                if device.sleepCurrent > 0 {
                    Text("The device says it uses \(formatUSBPowerAssumingFiveVolts(device.sleepCurrent)) to stay ready while the Mac sleeps.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if device.extraCurrentInSleep > 0 {
                    Text("The device can request an extra \(formatUSBPowerAssumingFiveVolts(device.extraCurrentInSleep)) during sleep.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if device.powerDetails.wakePortCurrentLimitMilliamps > 0 {
                    Text("The upstream port publishes an awake current limit of \(device.wakePortLimitDescription).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if device.powerDetails.sleepPortCurrentLimitMilliamps > 0 {
                    Text("The upstream port publishes a sleep-state current limit of \(device.sleepPortLimitDescription).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !device.powerDetails.powerRegistryFacts.isEmpty {
                Divider()

                DisclosureGroup("Exact registry power fields") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(device.powerDetails.powerRegistryFacts, id: \.self) { fact in
                            Text(fact)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    var topologySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🔌 Where is this device connected?")
                .font(.subheadline)
                .fontWeight(.medium)

            // Plain English connection path
            VStack(alignment: .leading, spacing: 6) {
                if !device.parentControllerName.isEmpty {
                    Label("Connected through \(device.parentControllerName)", systemImage: "arrow.turn.down.right")
                        .font(.callout)
                }

                if !device.storageVolumes.isEmpty {
                    Label("Finder currently maps this hardware to \(device.volumeSummary)", systemImage: "externaldrive.badge.checkmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    if device.isInternal {
                        Label("Built-in", systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    if device.isCaptive {
                        Label("Permanently attached", systemImage: "cable.connector")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                    if !device.isInternal && !device.isCaptive {
                        Label("External / Removable", systemImage: "eject")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }

            if !upstreamChain.isEmpty || !downstreamChildren.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Topology")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    if !upstreamChain.isEmpty {
                        Text(([device.controllerGroupName] + upstreamChain.map(\.name) + [device.name]).joined(separator: " → "))
                            .font(.callout)
                    } else {
                        Text("\(device.controllerGroupName) → \(device.name)")
                            .font(.callout)
                    }

                    if !downstreamChildren.isEmpty {
                        Text("Downstream from this hub")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(downstreamChildren) { child in
                            HStack {
                                Image(systemName: child.classInfo.icon)
                                    .font(.caption)
                                    .foregroundColor(child.speed.color)
                                Text(child.name)
                                    .font(.caption)
                                Spacer()
                                Text(child.locationDescription)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
            }

            if device.isHub {
                Divider()

                USBPortMapView(
                    basePath: device.portPathComponents,
                    observedDevices: allDevices.filter {
                        $0.id != device.id &&
                        $0.controllerGroupName == device.controllerGroupName &&
                        usbPathIsPrefix(device.portPathComponents, of: $0.portPathComponents)
                    },
                    knownPortCount: device.portCount > 0 ? device.portCount : nil,
                    deviceActivityLookup: allDeviceActivityLookup
                )
            }

            Divider()

            // Technical details (collapsed)
            DisclosureGroup("Technical Details") {
                VStack(spacing: 6) {
                    DetailRow(label: "Location ID", value: String(format: "0x%08X", device.locationID))
                    DetailRow(label: "Port Path", value: device.locationDescription)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    var rawPropertiesSection: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(device.rawProperties.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(alignment: .top) {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 200, alignment: .leading)
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Speed Detail View
struct SpeedDetailView: View {
    let device: USBDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Main speed display
            HStack {
                Image(systemName: device.speed.icon)
                    .font(.title)
                    .foregroundColor(device.speed.color)

                VStack(alignment: .leading) {
                    Text(device.speed.laymanDescription)
                        .font(.headline)
                    Text(device.speed.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(device.negotiatedSpeedDescription)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(device.speed.color)
            }

            // Real-world explanation
            Text(device.theoreticalBandwidth.realWorld)
                .font(.callout)
                .foregroundColor(.secondary)
                .italic()
                .padding(.vertical, 4)

            if device.linkSpeedBitsPerSecond > 0 {
                Text("macOS reports a negotiated link of \(device.negotiatedSpeedDescription). Compare that with the advertised USB version to spot cable, hub, or port bottlenecks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Speed bar with labels
            VStack(alignment: .leading, spacing: 4) {
                Text("How fast is this compared to other USB?")
                    .font(.caption)
                    .foregroundColor(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.2))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [device.speed.color.opacity(0.7), device.speed.color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * speedPercentage)
                    }
                }
                .frame(height: 12)

                HStack {
                    Text("🐢 Slowest")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("🚀 Fastest")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Plain English speed info
            VStack(alignment: .leading, spacing: 6) {
                DetailRowWithHelp(
                    label: "Negotiated Link",
                    value: device.negotiatedSpeedDescription,
                    help: "The actual speed macOS says the connection negotiated at"
                )
                DetailRowWithHelp(
                    label: "Advertised USB Version",
                    value: device.usbVersion,
                    help: "What the device descriptor says this hardware was built to support"
                )
                DetailRowWithHelp(
                    label: "Max Speed",
                    value: device.theoreticalBandwidth.speed,
                    help: "The fastest this connection can theoretically go"
                )
                DetailRowWithHelp(
                    label: "Real-World Speed",
                    value: device.theoreticalBandwidth.practical,
                    help: "What you'll actually see when copying files"
                )
                DetailRowWithHelp(
                    label: "Power Delivery",
                    value: device.speed.maxPowerDelivery,
                    help: "How much power this USB version can provide for charging"
                )
            }
        }
    }

    var speedPercentage: CGFloat {
        let reference = Double(device.linkSpeedBitsPerSecond > 0 ? device.linkSpeedBitsPerSecond : (device.speed.nominalBitsPerSecond ?? 0))
        guard reference > 0 else { return 0.02 }
        return CGFloat(min(max(reference / 40_000_000_000, 0.02), 1.0))
    }
}

// MARK: - Controller Detail View
struct ControllerDetailView: View {
    let controller: USBController
    let devices: [USBDevice]
    let deviceActivityLookup: [String: DeviceStorageActivity]
    let volumeStateLookup: [String: LiveMountedVolumeState]
    let showRaw: Bool

    var attachedDevices: [USBDevice] {
        devices
            .filter { $0.controllerGroupName == controller.name }
            .sorted(by: usbHierarchySort)
    }

    var attachedHierarchy: [USBHierarchyNode] {
        buildUSBHierarchyTree(from: attachedDevices)
    }

    var attachedHubCount: Int {
        attachedDevices.filter(\.isHub).count
    }

    var storageDeviceCount: Int {
        attachedDevices.filter { !$0.storageVolumes.isEmpty }.count
    }

    var activeStorageCount: Int {
        attachedDevices.filter { deviceActivityLookup[$0.id]?.isBusy == true }.count
    }

    var performanceLimitedDeviceCount: Int {
        attachedDevices.filter(\.isPerformanceLimited).count
    }

    var controllerChecklist: [String] {
        [
            "Start with Port Map if you are asking which branch, hub, or downstream path a problem device sits on.",
            "Use Devices On This Controller to see what is sharing bandwidth and bus power with the device you care about.",
            controller.supportsUSB3 ? "If something is still slow here, the bottleneck is more likely the cable, hub, enclosure, or negotiated link." : "If a fast modern drive is attached here, this controller alone can explain a USB 2-style ceiling."
        ]
    }

    var practicalTakeaway: String {
        if attachedDevices.isEmpty {
            return "Nothing is attached here right now, so this controller is not part of your current external-device story."
        }
        if !controller.supportsUSB3 {
            return "This is the first place to look when a supposedly fast device feels capped at old-school USB 2 performance."
        }
        if performanceLimitedDeviceCount > 0 {
            return "At least one attached device is negotiating below what its descriptors suggest, so use the port map and branch tree to inspect the shared path."
        }
        return "This controller looks healthy. Use it mainly to understand shared paths, hubs, and branch ownership rather than to hunt for an obvious controller-side bottleneck."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(controller.supportsUSB3 ? Color.green.opacity(0.2) : Color.yellow.opacity(0.2))
                            .frame(width: 70, height: 70)
                        Image(systemName: "cpu")
                            .font(.system(size: 32))
                            .foregroundColor(controller.supportsUSB3 ? .green : .yellow)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(controller.controllerType)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let technicalName = controller.technicalNameDescription {
                            Text(technicalName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        // Layman explanation
                        Text(controller.usageSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()
                }

                Divider()

                // What does this mean?
                VStack(alignment: .leading, spacing: 8) {
                    UsageGuideCard(
                        icon: "cpu",
                        title: "How to use this page",
                        summary: practicalTakeaway,
                        accent: .blue,
                        tips: controllerChecklist
                    )
                }

                DetailSection(title: "🧠 Quick Answers") {
                    DetailRow(label: "Attached devices", value: "\(attachedDevices.count)")
                    DetailRow(label: "Hubs on this controller", value: "\(attachedHubCount)")
                    DetailRow(label: "Storage devices here", value: "\(storageDeviceCount)")
                    DetailRow(label: "Storage devices active now", value: "\(activeStorageCount)")
                    DetailRow(label: "Devices below expected link", value: "\(performanceLimitedDeviceCount)")
                }

                DetailSection(title: "📋 Controller Details") {
                    DetailRow(label: "Type", value: controller.controllerType)
                    DetailRow(label: "Location", value: controller.isBuiltIn ? "Built into your Mac" : "External (add-on card or hub)")
                    DetailRow(label: "Speed Support", value: controller.supportsUSB3 ? "✅ USB 3.0+ (up to 10+ Gbps)" : "⚠️ USB 2.0 only (max 480 Mbps)")
                }

                DetailSection(title: "⚡ Power Available") {
                    Text(controller.powerDescription)
                        .font(.callout)
                    Text("This is how much power devices connected to this controller can draw.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !attachedDevices.isEmpty {
                    DetailSection(title: "🧭 Port Map") {
                        USBPortMapView(
                            basePath: [],
                            observedDevices: attachedDevices,
                            knownPortCount: nil,
                            deviceActivityLookup: deviceActivityLookup
                        )
                    }
                }

                if !attachedDevices.isEmpty {
                    DetailSection(title: "🔗 Devices On This Controller") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nested by hub and port path so same-named devices are easier to distinguish.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ForEach(attachedHierarchy) { node in
                                USBHierarchyBranchView(
                                    node: node,
                                    deviceActivityLookup: deviceActivityLookup,
                                    volumeStateLookup: volumeStateLookup
                                )
                            }
                        }
                    }
                }

                if !controller.pciInfo.isEmpty {
                    DetailSection(title: "🔧 Technical: PCI Information") {
                        Text(controller.pciInfo)
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                if showRaw && !controller.rawProperties.isEmpty {
                    DetailSection(title: "📄 Raw System Data") {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(controller.rawProperties.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                HStack(alignment: .top) {
                                    Text(key)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 200, alignment: .leading)
                                    Text(value)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 50)
            }
            .padding(24)
        }
        .frame(minWidth: 450)
    }
}

// MARK: - Thunderbolt Detail View
struct ThunderboltDetailView: View {
    let device: ThunderboltDevice
    let showRaw: Bool

    var speedExplanation: String {
        switch device.generation {
        case 4: return "Thunderbolt 4 is the latest – up to 40 Gbps, supports daisy-chaining, external GPUs, and multiple 4K displays."
        case 3: return "Thunderbolt 3 offers up to 40 Gbps – great for external drives, docks, and displays."
        case 2: return "Thunderbolt 2 offers up to 20 Gbps – still capable for external drives and displays."
        case 1: return "Original Thunderbolt offers up to 10 Gbps – faster than USB 3.0."
        default: return "macOS didn't expose an explicit Thunderbolt generation here, so this view keeps the interpretation conservative and leans on the raw registry data."
        }
    }

    var practicalTakeaway: String {
        if let whenToIgnoreSummary = device.whenToIgnoreSummary {
            return whenToIgnoreSummary
        }
        return device.howToUseSummary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(device.color.opacity(0.2))
                            .frame(width: 70, height: 70)
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 32))
                            .foregroundColor(device.color)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(device.userFacingSubtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if device.displayName != device.name {
                            Text(device.name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(speedExplanation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    Text(device.speedDescription)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(device.color.opacity(0.2))
                        .cornerRadius(8)
                }

                Divider()

                UsageGuideCard(
                    icon: "bolt.horizontal.fill",
                    title: "How to use this page",
                    summary: device.howToUseSummary,
                    accent: device.color,
                    tips: device.checklist
                )

                DetailSection(title: "🧠 What this entry actually is") {
                    DetailRow(label: "Role", value: device.roleTitle)
                    DetailRow(label: "Why it matters", value: practicalTakeaway)
                    if !device.routeString.isEmpty {
                        DetailRow(label: "Route", value: device.routeString)
                    }
                }

                DetailSection(title: "📦 Device Info") {
                    DetailRow(label: "Display name", value: device.displayName)
                    if !device.vendorName.isEmpty {
                        DetailRow(label: "Made by", value: device.vendorName)
                    }
                    if !device.deviceName.isEmpty && device.deviceName != device.name {
                        DetailRow(label: "Model", value: device.deviceName)
                    }
                    DetailRow(label: "Status", value: device.isConnected ? "✅ Connected and working" : "⚠️ Disconnected")
                }

                DetailSection(title: "⚡ Bandwidth Clues") {
                    DetailRow(label: "Generation", value: device.generationString)
                    DetailRow(label: "Maximum Speed", value: device.speedDescription)
                    if device.linkSpeed > 0 {
                        DetailRow(label: "Current Link Speed", value: "\(device.linkSpeed) Gbps")
                    }
                    if device.linkWidth > 0 {
                        DetailRow(label: "Lane Width", value: "\(device.linkWidth)x lanes")
                        Text("More lanes = more bandwidth. Thunderbolt uses multiple lanes for higher throughput.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }

                if showRaw && !device.rawProperties.isEmpty {
                    DetailSection(title: "📄 Raw System Data") {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(device.rawProperties.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                HStack(alignment: .top) {
                                    Text(key)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 200, alignment: .leading)
                                    Text(value)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 50)
            }
            .padding(24)
        }
        .frame(minWidth: 450)
    }
}

// MARK: - Raw Data Overview
struct RawDataOverview: View {
    @ObservedObject private var displayInventory = ConnectedDisplayInventory.shared
    @ObservedObject var manager: USBManager

    var classGroups: [Int: [USBDevice]] {
        Dictionary(grouping: manager.devices) { $0.effectiveClass }
    }

    var sortedClassIDs: [Int] {
        classGroups.keys.sorted()
    }

    var hierarchySections: [USBHierarchySection] {
        buildUSBHierarchySections(devices: manager.devices, controllers: manager.controllers)
    }

    @ViewBuilder
    func deviceClassRow(for classID: Int) -> some View {
        let devices = classGroups[classID] ?? []
        let info: (name: String, description: String, icon: String, layman: String) = devices.first?.classInfo ?? ("Class \(classID)", "", "questionmark.circle", "Unknown device type")

        HStack {
            Image(systemName: info.icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(info.name)
            Spacer()
            Text("\(devices.count)")
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    func hierarchyRow(for section: USBHierarchySection) -> some View {
        let controller = section.controller

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.blue)
                Text(section.controllerName)
                    .font(.headline)
                Spacer()
                Text("\(section.visibleDeviceCount) devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let controller {
                Text(controller.controllerType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Controller at the top, then hubs, then downstream devices and Finder-visible volumes underneath each branch.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(section.roots) { node in
                USBHierarchyBranchView(
                    node: node,
                    deviceActivityLookup: manager.liveDeviceActivity,
                    volumeStateLookup: manager.liveVolumeState
                )
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("System Displays, USB & Thunderbolt Overview")
                    .font(.title2)
                    .fontWeight(.bold)

                Divider()

                DetailSection(title: "Summary") {
                    DetailRow(label: "Connected Displays", value: "\(displayInventory.displays.count)")
                    DetailRow(label: "Total USB Devices", value: "\(manager.devices.count)")
                    DetailRow(label: "USB Controllers", value: "\(manager.controllers.count)")
                    DetailRow(label: "Thunderbolt Devices", value: "\(manager.thunderboltDevices.count)")
                    DetailRow(label: "USB Hubs", value: "\(manager.devices.filter { $0.isHub }.count)")
                    DetailRow(label: "Internal Devices", value: "\(manager.devices.filter { $0.isInternal }.count)")
                    DetailRow(label: "Composite Devices", value: "\(manager.devices.filter { $0.isCompositeDevice }.count)")
                    DetailRow(label: "USB 3+ Running Slow", value: "\(manager.devices.filter { $0.isPerformanceLimited }.count)")
                    DetailRow(label: "Mapped Finder Volumes", value: "\(manager.devices.flatMap(\.mountedVolumes).count)")
                    DetailRow(label: "Storage Devices Busy Now", value: "\(manager.liveDeviceActivity.values.filter { $0.isBusy }.count)")
                    DetailRow(label: "Volumes With Free-Space Movement", value: "\(manager.liveVolumeState.values.filter { $0.freeChangeDescription != nil }.count)")
                }

                DetailSection(title: "Speed Distribution") {
                    ForEach(USBSpeed.allCases.filter { $0 != .unknown }, id: \.self) { speed in
                        let count = manager.devices.filter { $0.speed == speed }.count
                        if count > 0 {
                            HStack {
                                Circle()
                                    .fill(speed.color)
                                    .frame(width: 10, height: 10)
                                Text(speed.description)
                                Spacer()
                                Text("\(count)")
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }

                DetailSection(title: "Device Classes") {
                    ForEach(sortedClassIDs, id: \.self) { classID in
                        deviceClassRow(for: classID)
                    }
                }

                DetailSection(title: "What Falls Under What") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(hierarchySections) { section in
                            hierarchyRow(for: section)
                        }
                    }
                }

                DetailSection(title: "Scan Log") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(manager.scanLog.suffix(20).reversed(), id: \.self) { log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 50)
            }
            .padding(24)
        }
    }
}

// MARK: - Collapsible Section
struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(isExpanded ? 12 : 12, corners: isExpanded ? [.topLeft, .topRight] : .allCorners)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(12, corners: [.bottomLeft, .bottomRight])
            }
        }
    }
}

// MARK: - Detail Section
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                content
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

// MARK: - Detail Row
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HardwareDetailValueRow(value: value) {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail Row with Help Text
struct DetailRowWithHelp: View {
    let label: String
    let value: String
    let help: String
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HardwareDetailValueRow(value: value) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label)
                        .foregroundStyle(.secondary)
                    Button("Explain \(label)", systemImage: "questionmark.circle") { showHelp.toggle() }
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .buttonStyle(.plain)
                        .help("Explain \(label)")
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showHelp {
                Text(help)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 4)
                    .frame(maxWidth: 860, alignment: .leading)
            }
        }
    }
}

// MARK: - Metadata Pill
struct MetadataPill: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .openCorePastelBadge(accent)
    }
}

// MARK: - Corner Radius Extension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        return path
    }
}



// MARK: - macOS 27 (WWDC 2026) Hardware, CoreHID, CoreAudio, AVFoundation & FoundationModels Suite

struct MacOS27HIDDeviceInfo: Identifiable, Hashable {
    let id: String
    let productName: String
    let manufacturer: String
    let transport: String
    let vendorID: Int
    let productID: Int
    let locationID: UInt32
    let primaryUsagePage: Int
    let primaryUsage: Int
    let usageDescription: String
    let versionNumber: Int
    let serialNumber: String
    let isBuiltIn: Bool
    let maxInputReportSize: Int
    let maxOutputReportSize: Int
    let maxFeatureReportSize: Int
    let correlatedUSBDeviceID: String?
    let correlatedUSBDeviceName: String?

    var vendorProductHex: String {
        String(format: "0x%04X:0x%04X", vendorID, productID)
    }
}

struct MacOS27AudioPeripheralInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let uid: String
    let transportType: String
    let sampleRateHz: Double
    let inputChannels: Int
    let outputChannels: Int
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
}

struct MacOS27VideoPeripheralInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let modelID: String
    let transportType: Int32
    let isExternal: Bool
    let isConnected: Bool
    let formatsSummary: String
}

struct MacOS27FoundationModelsHardwareStatus: Hashable {
    let onDeviceAvailable: Bool
    let availabilityLabel: String
    let variantDisplayName: String
    let contextSizeTokens: Int
    let capabilities: [String]
    let pccAvailable: Bool
    let pccStatusLabel: String
    let spotlightToolAvailable: Bool
    let visionToolsAvailable: Bool

    static func probe() -> MacOS27FoundationModelsHardwareStatus {
        let model = SystemLanguageModel.default
        let onDeviceReady = model.isAvailable
        let availabilityLabel = String(describing: model.availability)
        var variantName = "SystemLanguageModel.default"
        let contextTokens = model.contextSize
        var caps: [String] = []
        var pccReady = false
        var pccLabel = "OS-managed"

        if #available(macOS 27.0, *) {
            variantName = model.variant.displayName
            let c = model.capabilities
            if c.contains(.guidedGeneration) { caps.append("Guided Generation") }
            if c.contains(.toolCalling) { caps.append("Tool Calling") }
            if c.contains(.reasoning) { caps.append("Reasoning (.light/.moderate/.deep)") }
            if c.contains(.vision) { caps.append("Vision Attachments") }

            let pcc = PrivateCloudComputeLanguageModel()
            pccReady = pcc.isAvailable
            pccLabel = String(describing: pcc.availability)
        } else {
            caps = ["Guided Generation", "Tool Calling"]
        }

        return MacOS27FoundationModelsHardwareStatus(
            onDeviceAvailable: onDeviceReady,
            availabilityLabel: availabilityLabel,
            variantDisplayName: variantName,
            contextSizeTokens: contextTokens,
            capabilities: caps,
            pccAvailable: pccReady,
            pccStatusLabel: pccLabel,
            spotlightToolAvailable: true,
            visionToolsAvailable: true
        )
    }
}

extension USBManager {
    func scanHIDDevices(correlatingWith usbDevices: [USBDevice]) -> [MacOS27HIDDeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let devSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        func propInt(_ dev: IOHIDDevice, _ key: String) -> Int {
            (IOHIDDeviceGetProperty(dev, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        func propString(_ dev: IOHIDDevice, _ key: String) -> String {
            (IOHIDDeviceGetProperty(dev, key as CFString) as? String) ?? ""
        }

        var results: [MacOS27HIDDeviceInfo] = []
        for dev in devSet {
            let vendorID = propInt(dev, kIOHIDVendorIDKey)
            let productID = propInt(dev, kIOHIDProductIDKey)
            let locationID = UInt32(bitPattern: Int32(truncatingIfNeeded: propInt(dev, kIOHIDLocationIDKey)))
            let product = propString(dev, kIOHIDProductKey)
            let manufacturer = propString(dev, kIOHIDManufacturerKey)
            let transport = propString(dev, kIOHIDTransportKey)
            let serial = propString(dev, kIOHIDSerialNumberKey)
            let usagePage = propInt(dev, kIOHIDPrimaryUsagePageKey)
            let usage = propInt(dev, kIOHIDPrimaryUsageKey)
            let version = propInt(dev, kIOHIDVersionNumberKey)
            let builtIn = propInt(dev, kIOHIDBuiltInKey) != 0
            let maxIn = propInt(dev, kIOHIDMaxInputReportSizeKey)
            let maxOut = propInt(dev, kIOHIDMaxOutputReportSizeKey)
            let maxFeat = propInt(dev, kIOHIDMaxFeatureReportSizeKey)

            let correlated = usbDevices.first {
                ($0.locationID != 0 && $0.locationID == locationID) ||
                ($0.vendorID != 0 && $0.vendorID == vendorID && $0.productID == productID)
            }

            let displayName = !product.isEmpty ? product : (!manufacturer.isEmpty ? "\(manufacturer) HID" : String(format: "HID 0x%04X:0x%04X", vendorID, productID))
            let id = "\(displayName)-\(vendorID)-\(productID)-\(locationID)-\(usagePage)-\(usage)"

            results.append(
                MacOS27HIDDeviceInfo(
                    id: id,
                    productName: displayName,
                    manufacturer: manufacturer.isEmpty ? "Unknown" : manufacturer,
                    transport: transport.isEmpty ? "System" : transport,
                    vendorID: vendorID,
                    productID: productID,
                    locationID: locationID,
                    primaryUsagePage: usagePage,
                    primaryUsage: usage,
                    usageDescription: Self.describeHIDUsage(page: usagePage, usage: usage),
                    versionNumber: version,
                    serialNumber: serial,
                    isBuiltIn: builtIn,
                    maxInputReportSize: maxIn,
                    maxOutputReportSize: maxOut,
                    maxFeatureReportSize: maxFeat,
                    correlatedUSBDeviceID: correlated?.id,
                    correlatedUSBDeviceName: correlated?.name
                )
            )
        }

        return results.sorted {
            if $0.transport != $1.transport {
                return $0.transport < $1.transport
            }
            return $0.productName.localizedCaseInsensitiveCompare($1.productName) == .orderedAscending
        }
    }

    static func describeHIDUsage(page: Int, usage: Int) -> String {
        switch (page, usage) {
        case (0x01, 0x01): return "Generic Desktop · Pointer"
        case (0x01, 0x02): return "Generic Desktop · Mouse"
        case (0x01, 0x04): return "Generic Desktop · Joystick"
        case (0x01, 0x05): return "Generic Desktop · Game Pad"
        case (0x01, 0x06): return "Generic Desktop · Keyboard"
        case (0x01, 0x07): return "Generic Desktop · Keypad"
        case (0x01, 0x08): return "Generic Desktop · Multi-axis Controller"
        case (0x01, 0x80): return "Generic Desktop · System Control"
        case (0x07, _): return "Keyboard / Keypad (Page 0x07)"
        case (0x08, _): return "LED Indicator (Page 0x08)"
        case (0x09, _): return "Button Control (Page 0x09)"
        case (0x0B, _): return "Telephony / Headset (Page 0x0B)"
        case (0x0C, 0x01): return "Consumer Control · Media / Volume"
        case (0x0C, _): return "Consumer Device (Page 0x0C)"
        case (0x0D, 0x04): return "Digitizer · Touch Screen"
        case (0x0D, 0x05): return "Digitizer · Touch Pad / Trackpad"
        case (0x0D, _): return "Digitizer / Stylus (Page 0x0D)"
        case (0x20, _): return "Sensor (Page 0x20)"
        case (0x84, _), (0x85, _): return "Power / Battery HID (Page \(String(format: "0x%02X", page)))"
        default:
            if page >= 0xFF00 {
                return String(format: "Vendor-Defined HID (Page 0x%04X · Usage 0x%02X)", page, usage)
            }
            return String(format: "HID Page 0x%02X · Usage 0x%02X", page, usage)
        }
    }

    func scanAudioPeripherals() -> [MacOS27AudioPeripheralInfo] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var devID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
            return devID
        }

        let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)

        func cfStringProp(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
                  let cf = value?.takeRetainedValue() else { return "" }
            return cf as String
        }

        func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
            let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawPtr.deallocate() }
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, rawPtr) == noErr else { return 0 }
            let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
            return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        }

        var results: [MacOS27AudioPeripheralInfo] = []
        for id in deviceIDs {
            let name = cfStringProp(id, kAudioObjectPropertyName)
            let manufacturer = cfStringProp(id, kAudioObjectPropertyManufacturer)
            let uid = cfStringProp(id, kAudioDevicePropertyDeviceUID)

            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var sampleRate: Float64 = 0
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            _ = AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rateSize, &sampleRate)

            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportCode: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &transportSize, &transportCode)

            let transportLabel: String
            switch transportCode {
            case kAudioDeviceTransportTypeUSB: transportLabel = "USB Audio"
            case kAudioDeviceTransportTypeThunderbolt: transportLabel = "Thunderbolt"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transportLabel = "Bluetooth"
            case kAudioDeviceTransportTypeBuiltIn: transportLabel = "Built-in"
            case kAudioDeviceTransportTypeVirtual: transportLabel = "Virtual"
            case kAudioDeviceTransportTypeAggregate: transportLabel = "Aggregate"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transportLabel = "Display Audio"
            default: transportLabel = "System Audio"
            }

            let inCh = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outCh = channelCount(id, scope: kAudioObjectPropertyScopeOutput)

            results.append(
                MacOS27AudioPeripheralInfo(
                    id: uid.isEmpty ? "audio-\(id)" : uid,
                    name: name.isEmpty ? "Audio Device \(id)" : name,
                    manufacturer: manufacturer.isEmpty ? "Apple / System" : manufacturer,
                    uid: uid,
                    transportType: transportLabel,
                    sampleRateHz: sampleRate,
                    inputChannels: inCh,
                    outputChannels: outCh,
                    isDefaultInput: id == defaultIn,
                    isDefaultOutput: id == defaultOut
                )
            )
        }
        return results
    }

    func scanVideoPeripherals() -> [MacOS27VideoPeripheralInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { dev in
            MacOS27VideoPeripheralInfo(
                id: dev.uniqueID,
                name: dev.localizedName,
                manufacturer: dev.manufacturer,
                modelID: dev.modelID,
                transportType: dev.transportType,
                isExternal: dev.deviceType == .external,
                isConnected: dev.isConnected,
                formatsSummary: "\(dev.formats.count) capture formats"
            )
        }
    }

    @MainActor
    func diagnoseHardwareWithFoundationModels(device: USBDevice? = nil, controller: USBController? = nil, thunderbolt: ThunderboltDevice? = nil) async {
        guard !isRunningAIDiagnosis else { return }
        isRunningAIDiagnosis = true
        defer { isRunningAIDiagnosis = false }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            aiHardwareDiagnosis = "Apple on-device FoundationModel is unavailable (\(model.availability))."
            return
        }

        let targetSummary: String
        if let device {
            targetSummary = """
            USB Device: \(device.name) (\(device.vendorIDHex):\(device.productIDHex), Vendor: \(device.vendorDisplayName))
            Category: \(device.translatedCategory) | Headline: \(device.translationHeadline)
            Advertised USB: \(device.usbVersion) | Negotiated Link: \(device.negotiatedSpeedDescription) (Performance Limited: \(device.isPerformanceLimited))
            Controller: \(device.controllerGroupName) | Path: \(device.hierarchyPathLabel)
            Power: Negotiated \(device.powerDescription), Descriptor \(device.descriptorPowerDescription), Wake Limit \(device.wakePortLimitDescription), Over-current events: \(device.powerDetails.overCurrentEventCount)
            Interfaces (\(device.interfaces.count)): \(device.interfaces.map { "\($0.meaning.technicalLabel) [owner: \($0.exclusiveOwner.isEmpty ? "none" : $0.exclusiveOwner)]" }.joined(separator: "; "))
            Mounted Volumes: \(device.volumeSummary)
            Quality Score: \(device.connectionQuality.score)/100 (\(device.connectionQuality.issues.joined(separator: " | ")))
            """
        } else if let controller {
            targetSummary = """
            USB Controller: \(controller.displayName) (\(controller.controllerType), Class: \(controller.className))
            Supports USB 3+: \(controller.supportsUSB3) | Power: \(controller.powerDescription)
            """
        } else if let thunderbolt {
            targetSummary = """
            Thunderbolt Node: \(thunderbolt.displayName) (\(thunderbolt.roleTitle), Generation: \(thunderbolt.generationString))
            Route: \(thunderbolt.routeString) | Speed: \(thunderbolt.speedDescription) | Connected: \(thunderbolt.isConnected)
            """
        } else {
            let slowCount = devices.filter(\.isPerformanceLimited).count
            targetSummary = """
            Full Mac Bus Summary: \(devices.count) USB devices across \(controllers.count) controllers, \(thunderboltDevices.count) Thunderbolt entries, \(hidDevices.count) CoreHID devices, \(audioPeripherals.count) CoreAudio devices, \(videoPeripherals.count) AVFoundation cameras.
            Devices negotiating below spec: \(slowCount).
            Devices: \(devices.map { "\($0.name) (\($0.negotiatedSpeedDescription) on \($0.controllerGroupName))" }.joined(separator: ", "))
            """
        }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "You are OpenCore's macOS 27 Hardware & USB/Thunderbolt Diagnostic Engineer. Provide a concise, concrete 3-bullet hardware assessment covering (1) Link & Bandwidth Health (including UAS vs BOT or USB 2 fallback if applicable), (2) Power & Controller Path Ownership, and (3) Actionable recommendation. No em dashes."
            )
            if #available(macOS 27.0, *) {
                let response = try await session.respond(
                    to: targetSummary,
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 320),
                    contextOptions: ContextOptions(includeSchemaInPrompt: false, reasoningLevel: .light)
                )
                aiHardwareDiagnosis = response.content.replacingOccurrences(of: "-", with: "-")
            } else {
                let response = try await session.respond(to: targetSummary)
                aiHardwareDiagnosis = response.content.replacingOccurrences(of: "-", with: "-")
            }
        } catch {
            aiHardwareDiagnosis = "Hardware diagnosis error: \(error.localizedDescription)"
        }
    }
}

extension USBInspectorProContentView {
    var macos27SidebarListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                UsageGuideCard(
                    icon: "apple.intelligence",
                    title: "macOS 27 Hardware & AI Frameworks",
                    summary: "Combines CoreHID, CoreAudio, AVFoundation Capture, and macOS 27 FoundationModels (SystemLanguageModel.Variant, ContextOptions.ReasoningLevel, PrivateCloudComputeLanguageModel, SpotlightSearchTool, and Vision OCRTool) with the live IOKit USB/Thunderbolt bus.",
                    accent: Pastel.lavender,
                    tips: [
                        "Click any CoreHID row to jump directly to its parent physical USB device when correlated.",
                        "Use the FoundationModels Hardware Advisor to diagnose link speeds, power allocations, and interface drivers on-device.",
                        "Inspect CoreAudio and AVFoundation peripherals alongside USB controllers to trace pro-audio and capture gear."
                    ]
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE COREHID DEVICES (\(usbManager.hidDevices.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Pastel.aqua)

                    ForEach(usbManager.hidDevices) { hid in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: hid.usageDescription.contains("Keyboard") ? "keyboard" : (hid.usageDescription.contains("Mouse") || hid.usageDescription.contains("Pointer") || hid.usageDescription.contains("Trackpad") ? "magicmouse" : "gamecontroller"))
                                    .foregroundStyle(Pastel.aqua)
                                Text(hid.productName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(hid.transport)
                                    .openCorePastelBadge(Pastel.sky)
                            }
                            Text("\(hid.usageDescription) • \(hid.vendorProductHex)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let usbName = hid.correlatedUSBDeviceName, let usbID = hid.correlatedUSBDeviceID {
                                Button {
                                    selectedDeviceID = usbID
                                    viewMode = .devices
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link")
                                        Text("USB: \(usbName)")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Pastel.mint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .openCoreGlassCard(cornerRadius: 10, tint: Pastel.aqua)
                    }
                }
            }
            .padding(12)
        }
    }
}

struct DeviceAIAdvisorCard: View {
    let device: USBDevice
    @ObservedObject var manager: USBManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "apple.intelligence")
                    .font(.title3)
                    .foregroundStyle(Pastel.lavender)
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS 27 FoundationModels Hardware Advisor")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Pastel.lavender)
                    Text("\(manager.fmHardwareStatus.variantDisplayName) • \(manager.fmHardwareStatus.contextSizeTokens) ctx tokens • On-Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await manager.diagnoseHardwareWithFoundationModels(device: device)
                    }
                } label: {
                    HStack(spacing: 5) {
                        if manager.isRunningAIDiagnosis {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(manager.isRunningAIDiagnosis ? "Analyzing..." : "Diagnose Device")
                    }
                }
                .openCoreGlassButton(prominent: true)
                .disabled(manager.isRunningAIDiagnosis)
            }

            if !manager.aiHardwareDiagnosis.isEmpty {
                Text(manager.aiHardwareDiagnosis)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
    }
}

struct MacOS27HardwareSuiteDetailView: View {
    @ObservedObject var manager: USBManager
    let selectedDevice: USBDevice?
    let selectedController: USBController?
    let selectedThunderbolt: ThunderboltDevice?
    let onSelectDevice: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Visual Interactive Topology Canvas
                USBVisualTopologyCanvas(manager: manager, onSelectDevice: onSelectDevice)

                // macOS 27 FoundationModels SDK Status Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("macOS 27.0 SDK (27A266a) · Apple Intelligence & Hardware Suite", systemImage: "apple.intelligence")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Pastel.lavender)
                        Spacer()
                        Button {
                            Task {
                                await manager.diagnoseHardwareWithFoundationModels(
                                    device: selectedDevice,
                                    controller: selectedController,
                                    thunderbolt: selectedThunderbolt
                                )
                            }
                        } label: {
                            Label(manager.isRunningAIDiagnosis ? "Running Diagnosis..." : "Diagnose Full Bus with FoundationModels", systemImage: "wand.and.stars")
                        }
                        .openCoreGlassButton(prominent: true)
                        .disabled(manager.isRunningAIDiagnosis)
                    }

                    HStack(spacing: 10) {
                        MetadataPill(text: "Variant: \(manager.fmHardwareStatus.variantDisplayName)", accent: Pastel.lavender)
                        MetadataPill(text: "Context: \(manager.fmHardwareStatus.contextSizeTokens) tok", accent: Pastel.sky)
                        MetadataPill(text: manager.fmHardwareStatus.onDeviceAvailable ? "On-Device Ready" : "Unavailable", accent: manager.fmHardwareStatus.onDeviceAvailable ? Pastel.mint : Pastel.rose)
                        MetadataPill(text: "PCC: \(manager.fmHardwareStatus.pccAvailable ? "Available" : manager.fmHardwareStatus.pccStatusLabel)", accent: Pastel.periwinkle)
                        MetadataPill(text: "_Vision_FoundationModels (OCRTool + BarcodeReaderTool)", accent: Pastel.aqua)
                        MetadataPill(text: "_CoreSpotlight_FoundationModels (SpotlightSearchTool)", accent: Pastel.peach)
                    }

                    if !manager.aiHardwareDiagnosis.isEmpty {
                        Text(manager.aiHardwareDiagnosis)
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.lavender)

                // CoreHID Inspector Table
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("CoreHID & IOHIDManager Live Human Interface Devices (\(manager.hidDevices.count))", systemImage: "keyboard.badge.eye")
                            .font(.headline)
                            .foregroundStyle(Pastel.aqua)
                        Spacer()
                        Text("Correlated with IOUSBHost Location ID & VID:PID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(manager.hidDevices) { hid in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: hid.usageDescription.contains("Keyboard") ? "keyboard" : (hid.usageDescription.contains("Mouse") || hid.usageDescription.contains("Trackpad") ? "magicmouse" : "cpu"))
                                .font(.title3)
                                .foregroundStyle(Pastel.aqua)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(hid.productName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(hid.transport)
                                        .openCorePastelBadge(Pastel.sky)
                                    Text(hid.usageDescription)
                                        .openCorePastelBadge(Pastel.aqua)
                                    if hid.isBuiltIn {
                                        Text("Built-in")
                                            .openCorePastelBadge(Pastel.ice)
                                    }
                                }
                                Text("Manufacturer: \(hid.manufacturer) • \(hid.vendorProductHex) • Loc: \(String(format: "0x%08X", hid.locationID)) • Reports In/Out/Feat: \(hid.maxInputReportSize)/\(hid.maxOutputReportSize)/\(hid.maxFeatureReportSize) B")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let usbID = hid.correlatedUSBDeviceID, let usbName = hid.correlatedUSBDeviceName {
                                Button {
                                    onSelectDevice(usbID)
                                } label: {
                                    Label("Inspect \(usbName)", systemImage: "arrow.up.right.square")
                                        .font(.caption.weight(.semibold))
                                }
                                .openCoreGlassButton()
                            }
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
                .openCoreGlassCard(cornerRadius: 14, tint: Pastel.aqua)

                // CoreAudio & AVFoundation Peripherals
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("CoreAudio Hardware (\(manager.audioPeripherals.count))", systemImage: "hifispeaker.2.fill")
                            .font(.headline)
                            .foregroundStyle(Pastel.mint)

                        ForEach(manager.audioPeripherals) { audio in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(audio.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(audio.transportType)
                                        .openCorePastelBadge(Pastel.mint)
                                }
                                Text("\(audio.manufacturer) • \(String(format: "%.1f kHz", audio.sampleRateHz / 1000.0)) • \(audio.inputChannels) in / \(audio.outputChannels) out")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .openCoreGlassCard(cornerRadius: 14, tint: Pastel.mint)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("AVFoundation Video Capture (\(manager.videoPeripherals.count))", systemImage: "video.fill")
                            .font(.headline)
                            .foregroundStyle(Pastel.peach)

                        if manager.videoPeripherals.isEmpty {
                            Text("No video capture devices reported by AVCaptureDevice.DiscoverySession.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(manager.videoPeripherals) { cam in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(cam.name)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(cam.isExternal ? "External USB/TB" : "Built-in / Continuity")
                                            .openCorePastelBadge(cam.isExternal ? Pastel.peach : Pastel.sky)
                                    }
                                    Text("\(cam.manufacturer) • \(cam.modelID) • \(cam.formatsSummary)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .openCoreGlassCard(cornerRadius: 14, tint: Pastel.peach)
                }
            }
            .padding(24)
        }
    }
}

struct USBVisualTopologyCanvas: View {
    @ObservedObject var manager: USBManager
    let onSelectDevice: (String) -> Void

    var sections: [USBHierarchySection] {
        buildUSBHierarchySections(devices: manager.devices, controllers: manager.controllers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Interactive Bus & Port Topology Map", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                    .foregroundStyle(Pastel.sky)
                Spacer()
                Text("\(manager.controllers.count) Host Controllers • \(manager.devices.count) USB Devices • \(manager.thunderboltDevices.count) Thunderbolt Nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if sections.isEmpty {
                Text("No active USB device branches currently attached. Connect a USB-C / USB device or Thunderbolt dock to see its live bus path.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "cpu.fill")
                                        .foregroundStyle(Pastel.mint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(section.controller?.displayName ?? section.controllerName)
                                            .font(.subheadline.weight(.bold))
                                        Text(section.controller?.controllerType ?? "Host Controller Path")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(section.visibleDeviceCount)")
                                        .openCorePastelBadge(Pastel.mint)
                                }
                                .padding(10)
                                .background(Pastel.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                                ForEach(section.roots) { root in
                                    Button {
                                        onSelectDevice(root.device.id)
                                    } label: {
                                        USBHierarchyBranchView(
                                            node: root,
                                            showVolumes: true,
                                            deviceActivityLookup: manager.liveDeviceActivity,
                                            volumeStateLookup: manager.liveVolumeState
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(width: 340, alignment: .topLeading)
                            .padding(12)
                            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.sky)
                        }
                    }
                }
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
    }
}

struct HardwareUSBView: View {
    var body: some View {
        USBInspectorProContentView()
    }
}
