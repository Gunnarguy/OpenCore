import Foundation
import Testing
@testable import CoreTelemetry

@Suite("BetterDisplayEvidence")
struct BetterDisplayEvidenceTests {
    private let firstUUID = "00000000-0000-4000-8000-000000000001"
    private let secondUUID = "00000000-0000-4000-8000-000000000002"

    private func identity(_ id: String = "3", serial: String = "123456789", uuid: String? = nil) -> String {
        """
        {"UUID":"\(uuid ?? firstUUID)","deviceType":"Display","displayID":"\(id)","vendor":"4660","model":"2748","serial":"\(serial)","name":"Example 27"}
        """
    }

    // Original format trap: the installed CLI emits adjacent comma-separated objects,
    // and includes DisplayGroup records without physical display identity fields.
    @Test("identifier lists accept the installed object stream and ignore display groups")
    func decodesInstalledIdentifierFormat() throws {
        let object = identity()
        let group = #"{"deviceType":"DisplayGroup","name":"Home Setup","tagID":"-1001"}"#
        let expected = try BetterDisplayIdentity.decodeList(object)
        #expect(try BetterDisplayIdentity.decodeList("\(object),\(group)") == expected)
        #expect(try BetterDisplayIdentity.decodeList("[\(object),\(group)]") == expected)
        #expect(try BetterDisplayIdentity.decodeList("[]").isEmpty)
        #expect(expected.first?.displayID == 3 && expected.first?.serialNumber == 123456789)
        #expect(throws: (any Error).self) { try BetterDisplayIdentity.decodeList("\(object),") }
        #expect(throws: (any Error).self) { try BetterDisplayIdentity.decodeList("Failed.") }
        #expect(throws: (any Error).self) { try BetterDisplayIdentity.decodeList("") }
    }

    @Test("monitor targeting requires matching live IDs and rejects ambiguous twins")
    func matchingRejectsTwinsAndMismatches() throws {
        let a = try #require(BetterDisplayIdentity.decodeList(identity()).first)
        let b = try #require(BetterDisplayIdentity.decodeList(identity("2", serial: "42", uuid: secondUUID)).first)
        func match(_ list: [BetterDisplayIdentity], id: UInt32 = 3, vendor: UInt32 = 4660,
                   product: UInt32 = 2748, serial: UInt32 = 123456789) -> BetterDisplayIdentity? {
            BetterDisplayIdentity.matching(displayID: id, vendorID: vendor, productID: product, serialNumber: serial, in: list)
        }
        #expect(match([a, b]) == a)
        #expect(match([a, b], id: 2) == nil)
        #expect(match([a], vendor: 1138) == nil)
        #expect(match([a], product: 762) == nil)
        #expect(match([a], serial: 42) == nil)
        #expect(match([a, a]) == nil)
        #expect(match([a], id: 0) == nil)
        #expect(match([a], serial: 0) == a)
        let noID = try #require(BetterDisplayIdentity.decodeList(identity().replacingOccurrences(of: #""displayID":"3","#, with: "")).first)
        #expect(match([noID]) == nil)
        let sameUUID = try #require(BetterDisplayIdentity.decodeList(identity("4")).first)
        #expect(match([a, sameUUID]) == nil)
    }

    @Test("invalid identity numbers are rejected rather than truncated or wrapped")
    func identityNumericIntegrity() throws {
        for raw in ["3.5", "-1", "4294967296", "NaN", "Infinity"] {
            #expect(throws: (any Error).self) { try BetterDisplayIdentity.decodeList(identity(raw)) }
        }
        let numeric = identity().replacingOccurrences(of: #""displayID":"3""#, with: #""displayID":3.5"#)
        #expect(throws: (any Error).self) { try BetterDisplayIdentity.decodeList(numeric) }
        let bool = identity().replacingOccurrences(of: #""displayID":"3""#, with: #""displayID":true"#)
        #expect(throws: (any Error).self) { try BetterDisplayIdentity.decodeList(bool) }
    }

    // Original evidence quirk: one monitor reports input current 5, enum 17/18/15 and max 3.
    // A range clamp or enum membership check would silently rewrite the actual reading.
    @Test("DDC reports preserve enum quirks zero readings and explicit read failures")
    func ddcPreservesActualReadings() throws {
        let report = """
        DDC capabilities report for Display 47 (Example 27)
        VCP 0x08 (8)
        - Parsed as command restoreFactoryColorDefaults
        - Current value: 0.
        - Maximum value: 0.
        VCP 0x60 (96)
        - Parsed as command inputSelect
        - Default control target hardwareInputSource
        - Mapped control targets: hardwareInputSource
        - Accepted distinct values: 17, 18, 15
        - Current value: 5.
        - Maximum value: 3.
        VCP 0xFD (253)
        - Reading current value failed.
        """
        let values = try BetterDisplayDDCFeature.parseReport(report)
        let zero = try #require(values.first { $0.id == 8 })
        #expect(zero.current == 0 && zero.maximum == 0 && !zero.readFailed)
        let input = try #require(values.first { $0.id == 96 })
        #expect(input.current == 5 && input.maximum == 3 && input.acceptedValues == [17, 18, 15])
        #expect(input.target == "hardwareInputSource")
        let failed = try #require(values.first { $0.id == 253 })
        #expect(failed.current == nil && failed.maximum == nil && failed.readFailed)
        #expect(failed.name == "VCP 0xFD")
    }

    @Test("DDC empty success is distinguishable from failed or malformed evidence")
    func ddcFailureIsNotEmptySuccess() throws {
        #expect(try BetterDisplayDDCFeature.parseReport("DDC capabilities report for Display 47 (Example 27)\n").isEmpty)
        for text in ["", "Failed.", "VCP 0x10 (16)\n- Current value: 20.",
                     "DDC capabilities report for Display 47\nVCP 0x10 (17)\n- Reading current value failed.",
                     "DDC capabilities report for Display 47\nVCP 0x10 (16)\n- Current value: 20.",
                     "DDC capabilities report for Display 47\nVCP 0x10 (16)\n- Surprise write support: Yes"] {
            #expect(throws: (any Error).self) { try BetterDisplayDDCFeature.parseReport(text) }
        }
    }

    @Test("DDC numeric corruption and inconsistent measurements reject the entire report")
    func ddcNumericIntegrity() throws {
        func report(_ current: String, maximum: String = "100") -> String {
            "DDC capabilities report for Display 47\nVCP 0x10 (16)\n- Current value: \(current).\n- Maximum value: \(maximum)."
        }
        for value in ["1.5", "NaN", "Inf", "-1", "65536", "18446744073709551616", "101"] {
            #expect(throws: (any Error).self) { try BetterDisplayDDCFeature.parseReport(report(value)) }
        }
        #expect(throws: (any Error).self) { try BetterDisplayDDCFeature.parseReport(report("50", maximum: "49.5")) }
        #expect(throws: (any Error).self) { try BetterDisplayDDCFeature.parseReport(report("50") + "\n- Reading current value failed.") }
        #expect(throws: (any Error).self) { try BetterDisplayDDCFeature.parseReport(report("50") + "\nVCP 0x10 (16)\n- Reading current value failed.") }
        #expect(throws: (any Error).self) { try BetterDisplayDDCFeature.parseReport(report("50") + "\n- Current value: 20.") }
    }

    @Test("mode option IDs preserve unsigned precision and duplicate labels remain distinct")
    func optionIdentityAndUnsafeFlags() throws {
        let values = try BetterDisplayListedOption.parseList("""
        18446744073709551615 - 2560x1440 60Hz
        9223372036854775808 - 2560x1440 60Hz
        45 - 400x300 HiDPI 75Hz 10bpc Unsafe
        46 - 400x300 HiDPI 75Hz Invalid
        47 - NotUnsafe or Invalidated
        """)
        #expect(values.map(\.id) == ["18446744073709551615", "9223372036854775808", "45", "46", "47"])
        #expect(values[0].label == values[1].label)
        #expect(values[2].isUnsafe && values[3].isUnsafe && !values[4].isUnsafe)
        #expect(try BetterDisplayListedOption.parseList("").isEmpty)
    }

    @Test("one malformed option or repeated numeric ID invalidates the whole list")
    func optionsAreAllOrNothing() throws {
        for broken in ["broken", "2 - ", "-2 - HDMI", "2.5 - HDMI", "18446744073709551616 - HDMI",
                       "1 - second", "01 - second", "3 - control\u{0}text"] {
            #expect(throws: (any Error).self) { try BetterDisplayListedOption.parseList("1 - HDMI\n" + broken) }
        }
    }
}
