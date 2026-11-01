import Foundation
import Testing
@testable import CoreTelemetry

// Original failure: USB/Thunderbolt enumeration never represented monitor outputs at all.
// Their descriptor data must also stay attached to the correct monitor, not the first USB path.
@Test("display descriptors match vendor, product and serial without guessing between twins")
func displayDescriptorsRespectIdentity() throws {
    func reading(_ serial: Int) throws -> DisplayRegistryReading {
        try #require(DisplayRegistryReading(attributes: ["ProductAttributes": [
            "LegacyManufacturerID": 4660, "ProductID": 2748, "SerialNumber": serial,
            "ManufacturerID": "EXA", "ProductName": "Example 27"
        ]]))
    }
    let a = try reading(1), b = try reading(2)
    #expect(DisplayRegistryReading.matching(vendorID: 4660, productID: 2748, serialNumber: 2, onlineMatchCount: 1, in: [a,b]) == b)
    #expect(DisplayRegistryReading.matching(vendorID: 4660, productID: 2748, serialNumber: 0, onlineMatchCount: 1, in: [a,b]) == nil)
    #expect(DisplayRegistryReading.matching(vendorID: 4660, productID: 2748, serialNumber: 3, onlineMatchCount: 1, in: [a]) == nil)
    #expect(DisplayRegistryReading.matching(vendorID: 1138, productID: 2748, serialNumber: 1, onlineMatchCount: 1, in: [a]) == nil)
    #expect(DisplayRegistryReading.matching(vendorID: 4660, productID: 2748, serialNumber: 0, onlineMatchCount: 1, in: [a]) == a)
    // A missing second descriptor must not attach the first one's details to both screens.
    #expect(DisplayRegistryReading.matching(vendorID: 4660, productID: 2748, serialNumber: 0, onlineMatchCount: 2, in: [a]) == nil)
    #expect(DisplayRegistryReading.matching(vendorID: 4660, productID: 2748, serialNumber: 1, onlineMatchCount: 2, in: [a]) == nil)
}

@Test("unknown display descriptor measurements remain absent")
func displayUnknownsStayAbsent() throws {
    #expect(DisplayRegistryReading(attributes: [:]) == nil)
    let reading = try #require(DisplayRegistryReading(attributes: [
        "ProductAttributes": ["LegacyManufacturerID": 4660, "ProductID": 2748, "SerialNumber": 0],
        "MaximumRefreshRate": 0, "MinimumRefreshRate": -1, "NativeFormatHorizontalPixels": true
    ]))
    #expect(reading.maximumRefresh == nil && reading.minimumRefresh == nil)
    #expect(reading.nativeWidth == nil && reading.serialNumber == nil)
    #expect(DisplayRegistryReading(attributes: ["ProductAttributes": ["LegacyManufacturerID": 4660, "ProductID": 2748.9]]) == nil)
    let fractional = try #require(DisplayRegistryReading(attributes: [
        "ProductAttributes": ["LegacyManufacturerID": 4660, "ProductID": 2748],
        "NativeFormatHorizontalPixels": 0.5, "MaximumRefreshRate": Double.infinity
    ]))
    #expect(fractional.nativeWidth == nil && fractional.maximumRefresh == nil)
}
