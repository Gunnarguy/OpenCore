import Foundation

/// A failed or changed CLI format is different from a successful empty result.
public enum BetterDisplayEvidenceError: Error, Sendable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Invalid BetterDisplay evidence: \(reason)"
        }
    }
}

/// Identity reported by the installed BetterDisplay CLI. Names alone never identify a target.
public struct BetterDisplayIdentity: Sendable, Equatable {
    public let uuid: String
    public let displayID: UInt32?
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let serialNumber: UInt32?
    public let name: String
    public let deviceType: String

    public static func decodeList(_ text: String) throws -> [Self] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw BetterDisplayEvidenceError.invalid("missing identity response") }
        // Version 5.1.1 emits comma-separated JSON objects without enclosing brackets.
        // Wrapping only an object-starting response also accepts a genuine single object.
        let normalized: String
        if source.hasPrefix("[") { normalized = source }
        else if source.hasPrefix("{") { normalized = "[\(source)]" }
        else { throw BetterDisplayEvidenceError.invalid("identity response is not JSON objects") }
        try rejectTrailingJSONCommas(normalized)
        return try JSONDecoder().decode([IdentityRecord].self, from: Data(normalized.utf8)).compactMap(\.identity)
    }

    public static func matching(displayID: UInt32, vendorID: UInt32, productID: UInt32,
                                serialNumber: UInt32, in identities: [Self]) -> Self? {
        guard displayID > 0, vendorID > 0, productID > 0 else { return nil }
        let candidates = identities.filter { $0.deviceType == "Display" && $0.displayID == displayID }
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.vendorID == vendorID, candidate.productID == productID,
              serialNumber == 0 || candidate.serialNumber == serialNumber,
              identities.filter({ $0.uuid == candidate.uuid }).count == 1 else { return nil }
        return candidate
    }
}

private struct IdentityRecord: Decodable {
    let identity: BetterDisplayIdentity?
    private enum CodingKeys: String, CodingKey {
        case uuid = "UUID", displayID, vendor, model, serial, name, deviceType
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let deviceType = try values.decode(String.self, forKey: .deviceType)
        guard deviceType == "Display" else { identity = nil; return }
        let uuid = try values.decode(String.self, forKey: .uuid)
        let name = try values.decode(String.self, forKey: .name)
        guard UUID(uuidString: uuid) != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BetterDisplayEvidenceError.invalid("display is missing a UUID or name")
        }
        func identifier(_ key: CodingKeys) throws -> UInt32? {
            guard values.contains(key), try !values.decodeNil(forKey: key) else { return nil }
            if let raw = try? values.decode(String.self, forKey: key) {
                guard isDecimal(raw), let result = UInt32(raw) else {
                    throw BetterDisplayEvidenceError.invalid("invalid \(key.stringValue) identifier")
                }
                return result
            }
            return try values.decode(UInt32.self, forKey: key)
        }
        identity = BetterDisplayIdentity(uuid: uuid, displayID: try identifier(.displayID),
                                        vendorID: try identifier(.vendor), productID: try identifier(.model),
                                        serialNumber: try identifier(.serial), name: name, deviceType: deviceType)
    }
}

/// Raw VCP readings and advertised enum values. A successful read does not prove write support.
public struct BetterDisplayDDCFeature: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let current: Int?
    public let maximum: Int?
    public let acceptedValues: [Int]
    public let readFailed: Bool
    public let target: String?

    public func updatingCurrent(_ value: Int?, readFailed: Bool = false) -> Self {
        let valid = value.flatMap { value -> Int? in
            guard (0...65535).contains(value), id != 0xD6 || (1...4).contains(value), id == 0xD6 || !acceptedValues.isEmpty || maximum.map({ value <= $0 }) != false else { return nil }
            return value
        }
        return Self(id: id, name: name, current: valid, maximum: maximum, acceptedValues: acceptedValues,
                    readFailed: readFailed || valid == nil, target: target)
    }

    public static func scalar(_ text: String?) -> Int? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(raw) else { return nil }
        return Int(value)
    }

    public static func parseReport(_ text: String) throws -> [Self] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let header = lines.first,
              header.range(of: #"^DDC capabilities report for Display [0-9]+(?: \(.+\))?$"#, options: .regularExpression) != nil else {
            throw BetterDisplayEvidenceError.invalid("missing DDC report header")
        }
        var result: [Self] = []
        var seen = Set<Int>()
        var section: DDCSection?
        for line in lines.dropFirst() {
            if line.hasPrefix("VCP ") {
                if let section { result.append(try section.finish()) }
                let parts = line.split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "VCP", parts[1].hasPrefix("0x"),
                      parts[1].count == 4,
                      parts[1].dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let code = Int(parts[1].dropFirst(2), radix: 16),
                      parts[2].first == "(", parts[2].last == ")",
                      String(parts[2].dropFirst().dropLast()) == String(code), seen.insert(code).inserted else {
                    throw BetterDisplayEvidenceError.invalid("invalid or duplicate VCP section")
                }
                section = DDCSection(id: code)
            } else {
                guard section != nil else { throw BetterDisplayEvidenceError.invalid("DDC content outside a VCP section") }
                try section?.consume(line)
            }
        }
        if let section { result.append(try section.finish()) }
        return result
    }
}

private struct DDCSection {
    let id: Int
    var name: String?
    var current: Int?
    var maximum: Int?
    var acceptedValues: [Int]?
    var readFailed = false
    var target: String?
    var mappedTargetsSeen = false

    mutating func consume(_ line: String) throws {
        func tail(_ prefix: String) -> String? { line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil }
        if let raw = tail("- Parsed as command ") {
            guard name == nil, validToken(raw) else { throw BetterDisplayEvidenceError.invalid("invalid command name") }
            name = raw
        } else if let raw = tail("- Default control target ") {
            guard target == nil, validToken(raw) else { throw BetterDisplayEvidenceError.invalid("invalid control target") }
            target = raw
        } else if let raw = tail("- Mapped control targets: ") {
            guard !mappedTargetsSeen, !raw.isEmpty,
                  raw.components(separatedBy: ", ").allSatisfy(validToken) else {
                throw BetterDisplayEvidenceError.invalid("invalid mapped control targets")
            }
            mappedTargetsSeen = true
        } else if let raw = tail("- Accepted distinct values: ") {
            guard acceptedValues == nil else { throw BetterDisplayEvidenceError.invalid("duplicate accepted values") }
            let values = try raw.components(separatedBy: ", ").map(parseVCPNumber)
            guard !values.isEmpty, Set(values).count == values.count else {
                throw BetterDisplayEvidenceError.invalid("invalid accepted values")
            }
            acceptedValues = values
        } else if let raw = tail("- Current value: ") {
            guard current == nil, raw.hasSuffix(".") else { throw BetterDisplayEvidenceError.invalid("invalid current value") }
            current = try parseVCPNumber(String(raw.dropLast()))
        } else if let raw = tail("- Maximum value: ") {
            guard maximum == nil, raw.hasSuffix(".") else { throw BetterDisplayEvidenceError.invalid("invalid maximum value") }
            maximum = try parseVCPNumber(String(raw.dropLast()))
        } else if line == "- Reading current value failed." {
            guard !readFailed else { throw BetterDisplayEvidenceError.invalid("duplicate failed reading") }
            readFailed = true
        } else {
            throw BetterDisplayEvidenceError.invalid("unrecognized DDC report line")
        }
    }

    func finish() throws -> BetterDisplayDDCFeature {
        if readFailed {
            guard current == nil, maximum == nil else { throw BetterDisplayEvidenceError.invalid("failed read also has measurements") }
        } else {
            guard let current, let maximum else { throw BetterDisplayEvidenceError.invalid("incomplete DDC reading") }
            // Enum maxima can be counts rather than ranges. A real input/preset report
            // includes current values outside both its enum list and maximum; preserve them.
            guard acceptedValues != nil || current <= maximum else {
                throw BetterDisplayEvidenceError.invalid("continuous current exceeds maximum")
            }
        }
        return BetterDisplayDDCFeature(id: id, name: name ?? String(format: "VCP 0x%02X", id), current: current,
                                       maximum: maximum, acceptedValues: acceptedValues ?? [], readFailed: readFailed,
                                       target: target)
    }
}

/// The CLI's option identifier is opaque text, including connection IDs larger than Int64.
public struct BetterDisplayListedOption: Sendable, Equatable {
    public let id: String
    public let label: String

    public var isUnsafe: Bool {
        label.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .contains { $0.caseInsensitiveCompare("Unsafe") == .orderedSame || $0.caseInsensitiveCompare("Invalid") == .orderedSame }
    }

    public static func parseList(_ text: String) throws -> [Self] {
        var result: [Self] = []
        var seen = Set<UInt64>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let delimiter = line.range(of: " - ") else { throw BetterDisplayEvidenceError.invalid("missing option separator") }
            let id = String(line[..<delimiter.lowerBound])
            let label = String(line[delimiter.upperBound...])
            guard isDecimal(id), let numericID = UInt64(id), seen.insert(numericID).inserted,
                  !label.trimmingCharacters(in: .whitespaces).isEmpty,
                  !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw BetterDisplayEvidenceError.invalid("invalid or duplicate option identifier/label")
            }
            result.append(Self(id: id, label: label))
        }
        return result
    }
}

private func isDecimal(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
}

private func rejectTrailingJSONCommas(_ text: String) throws {
    // Foundation's decoder accepts trailing commas. Do not turn truncated CLI output
    // into a successful partial inventory; commas inside quoted names remain ordinary text.
    var quoted = false
    var escaped = false
    var afterComma = false
    for character in text {
        if quoted {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted = false }
        } else if character == "\"" {
            quoted = true
            afterComma = false
        } else if !character.isWhitespace {
            if afterComma && (character == "]" || character == "}") {
                throw BetterDisplayEvidenceError.invalid("trailing JSON comma")
            }
            afterComma = character == ","
        }
    }
}

private func validToken(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
}

private func parseVCPNumber(_ text: String) throws -> Int {
    // MCCS VCP values are unsigned 16-bit protocol fields, not estimated display limits.
    guard isDecimal(text), let value = UInt16(text) else { throw BetterDisplayEvidenceError.invalid("invalid VCP numeric field") }
    return Int(value)
}
