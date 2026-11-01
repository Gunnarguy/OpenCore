import Foundation

/// Descriptor claims published by the current display path, not measured panel/cable limits.
public struct DisplayRegistryReading: Sendable, Equatable {
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32?
    public let manufacturer: String?
    public let productName: String?
    public let serialText: String?
    public let year: Int?
    public let week: Int?
    public let nativeWidth: Int?
    public let nativeHeight: Int?
    public let minimumRefresh: Int?
    public let maximumRefresh: Int?
    public let registryPath: String?

    public init?(attributes: [String: Any], registryPath: String? = nil) {
        let product = attributes["ProductAttributes"] as? [String: Any] ?? [:]
        func positive(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.doubleValue < Double(Int.max) else { return nil }
            return number.intValue
        }
        guard let vendor = positive(product["LegacyManufacturerID"]), let vendorID = UInt32(exactly: vendor),
              let identifier = positive(product["ProductID"]), let productID = UInt32(exactly: identifier) else { return nil }
        self.vendorID = vendorID
        self.productID = productID
        serialNumber = positive(product["SerialNumber"]).flatMap(UInt32.init(exactly:))
        manufacturer = product["ManufacturerID"] as? String
        productName = product["ProductName"] as? String
        serialText = product["AlphanumericSerialNumber"] as? String
        year = positive(product["YearOfManufacture"])
        week = positive(product["WeekOfManufacture"])
        nativeWidth = positive(attributes["NativeFormatHorizontalPixels"])
        nativeHeight = positive(attributes["NativeFormatVerticalPixels"])
        minimumRefresh = positive(attributes["MinimumRefreshRate"])
        maximumRefresh = positive(attributes["MaximumRefreshRate"])
        self.registryPath = registryPath
    }

    public static func matching(vendorID: UInt32, productID: UInt32, serialNumber: UInt32,
                                onlineMatchCount: Int, in readings: [Self]) -> Self? {
        guard onlineMatchCount == 1 else { return nil }
        let candidates = readings.filter { $0.vendorID == vendorID && $0.productID == productID }
        let matches = serialNumber == 0 ? candidates : candidates.filter { $0.serialNumber == serialNumber }
        // Both the live identity and its descriptor must be unique. One missing descriptor
        // must not make two identical online monitors look uniquely identifiable.
        return matches.count == 1 ? matches.first : nil
    }
}
