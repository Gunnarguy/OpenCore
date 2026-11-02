import Foundation

/// A wire ID, kept outside JSONValue's Double representation. Numeric construction is
/// sealed by RPCIntegerToken; an unvalidated string can never become a raw JSON fragment.
public enum RPCID: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    case string(String)
    case integer(RPCIntegerToken)
    case null

    public static func int(_ value: Int) -> Self {
        // String(Int) is always a JSON integer; this path never parses peer input.
        .integer(try! RPCIntegerToken.parse(String(value)))
    }

    public static func number(_ literal: String) throws -> Self {
        .integer(try RPCIntegerToken.parse(literal))
    }

    public var description: String {
        switch self { case .string: "RPC string id"; case .integer: "RPC integer id"; case .null: "RPC null id" }
    }
    public var debugDescription: String { description }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        // Swift String equality normalizes Unicode. JSON IDs compare decoded code points.
        case (.string(let left), .string(let right)): left.utf8.elementsEqual(right.utf8)
        case (.integer(let left), .integer(let right)): left == right
        case (.null, .null): true
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let value): hasher.combine(0); hasher.combine(Data(value.utf8))
        case .integer(let value): hasher.combine(1); hasher.combine(value)
        case .null: hasher.combine(2)
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .string(let value): try JSONEncoder().encode(value)
        case .integer(let value): Data(value.literal.utf8)
        case .null: Data("null".utf8)
        }
    }
}

/// Validated JSON number whose mathematical value is an integer. No exponent expansion,
/// fixed-width conversion, Double or Decimal participates in validation or equality.
public struct RPCIntegerToken: Sendable, Hashable {
    fileprivate let literal: String
    private let negative: Bool
    private let digits: String
    private let exponent: SignedDecimal

    private init(literal: String, negative: Bool, digits: String, exponent: SignedDecimal) {
        self.literal = literal; self.negative = negative; self.digits = digits; self.exponent = exponent
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.negative == rhs.negative && lhs.digits == rhs.digits && lhs.exponent == rhs.exponent
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(negative); hasher.combine(digits); hasher.combine(exponent)
    }

    fileprivate static func parse(_ text: String) throws -> Self {
        guard !text.isEmpty, text.utf8.count <= RPCWireObject.maximumBytes else { throw wireParseError() }
        let bytes = Array(text.utf8)
        var index = 0
        let negative = bytes[index] == 0x2D
        if negative { index += 1 }
        let start = index
        guard index < bytes.count else { throw wireParseError() }
        if bytes[index] == 0x30 { index += 1 }
        else {
            guard (0x31...0x39).contains(bytes[index]) else { throw wireParseError() }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        var digits = Array(bytes[start..<index])
        var fractionCount = 0
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let fraction = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > fraction else { throw wireParseError() }
            fractionCount = index - fraction
            digits.append(contentsOf: bytes[fraction..<index])
        }
        var exponent = SignedDecimal.zero
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            var exponentNegative = false
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                exponentNegative = bytes[index] == 0x2D; index += 1
            }
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > start else { throw wireParseError() }
            exponent = SignedDecimal(negative: exponentNegative, magnitude: Array(bytes[start..<index]))
        }
        guard index == bytes.count else { throw wireParseError() }
        let significant = Array(digits.drop(while: { $0 == 0x30 }))
        if significant.isEmpty {
            return .init(literal: text, negative: false, digits: "0", exponent: .zero)
        }
        var end = significant.count
        while end > 0, significant[end - 1] == 0x30 { end -= 1 }
        let trailingZeros = significant.count - end
        exponent = exponent.adding(trailingZeros - fractionCount)
        guard !exponent.negative else { throw invalidWireID() }
        return .init(literal: text, negative: negative,
            digits: String(decoding: significant[..<end], as: UTF8.self), exponent: exponent)
    }
}

/// Signed decimal exponent with arbitrary digit count. Only bounded mantissa-length offsets
/// are added; no exponent is ever used as an allocation size or converted to a machine integer.
private struct SignedDecimal: Sendable, Hashable {
    let negative: Bool
    let magnitude: [UInt8]
    static let zero = SignedDecimal(negative: false, magnitude: [0x30])
    init(negative: Bool, magnitude: [UInt8]) {
        let trimmed = Array(magnitude.drop(while: { $0 == 0x30 }))
        self.magnitude = trimmed.isEmpty ? [0x30] : trimmed
        self.negative = !trimmed.isEmpty && negative
    }
    func adding(_ offset: Int) -> Self {
        guard offset != 0 else { return self }
        // Offset is bounded by the chosen message-byte budget, never Int.min or an exponent.
        let other = SignedDecimal(negative: offset < 0, magnitude: Array(String(abs(offset)).utf8))
        if negative == other.negative {
            var left = magnitude.reversed().makeIterator(), right = other.magnitude.reversed().makeIterator()
            var output: [UInt8] = [], carry = 0
            while true {
                let a = left.next(), b = right.next()
                if a == nil, b == nil, carry == 0 { break }
                let sum = Int(a.map { $0 - 0x30 } ?? 0) + Int(b.map { $0 - 0x30 } ?? 0) + carry
                output.append(UInt8(sum % 10) + 0x30); carry = sum / 10
            }
            return .init(negative: negative, magnitude: output.reversed())
        }
        let leftIsLarger = magnitude.count != other.magnitude.count
            ? magnitude.count > other.magnitude.count : !magnitude.lexicographicallyPrecedes(other.magnitude)
        let larger = leftIsLarger ? self : other, smaller = leftIsLarger ? other : self
        var small = smaller.magnitude.reversed().makeIterator(), output: [UInt8] = [], borrow = 0
        for byte in larger.magnitude.reversed() {
            var difference = Int(byte - 0x30) - Int(small.next().map { $0 - 0x30 } ?? 0) - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 { difference += 10 }
            output.append(UInt8(difference) + 0x30)
        }
        return .init(negative: larger.negative, magnitude: output.reversed())
    }
}

/// A single JSON object with its exact ID separated from ordinary JSONValue fields. A batch
/// dispatcher must split batches before calling this; this is deliberately not a batch parser.
public struct RPCWireObject: Sendable {
    // Chosen application budgets, not protocol maxima or total process-memory guarantees.
    public static let maximumBytes = 8 * 1024 * 1024
    private static let maximumDepth = 128
    public let id: RPCID?
    public let fields: [String: JSONValue]
    public var value: JSONValue { .object(fields) }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { throw wireParseError() }
        var scanner = ObjectScanner(bytes: Array(data), maximumDepth: maximumDepth)
        let scanned = try scanner.scan()
        // Strict scanning has validated the complete original syntax. Reject ambiguity before
        // any masking; duplicate short IDs must not cause repeated tail shifts in a large body.
        guard !scanned.duplicate else { throw RPCError(code: -32600, message: "Duplicate RPC envelope field") }
        var id: RPCID?, invalidID: RPCError?
        var masked = scanner.bytes
        for span in scanned.ids.reversed() {
            let token = Data(scanner.bytes[span])
            let parsed: RPCID?
            var mask = true
            if token.first == 0x22 {
                guard let string = try? JSONDecoder().decode(String.self, from: token) else { throw wireParseError() }
                parsed = .string(string)
            } else if token == Data("null".utf8) { parsed = .null }
            else if token.first == 0x2D || token.first.map(isDigit) == true {
                do { parsed = try .number(String(decoding: token, as: UTF8.self)) }
                catch let error as RPCError where error.code == -32600 {
                    // Fractional but syntactically valid. Defer semantic rejection until the
                    // rest of the original document has passed syntax validation too.
                    parsed = nil; invalidID = error
                }
            } else {
                // Leave wrong-kind tokens untouched so Foundation validates their original
                // syntax along with the whole document before semantic rejection.
                parsed = nil; invalidID = invalidWireID(); mask = false
            }
            id = parsed
            // Same-length JSON placeholder: linear work, no repeated tail shifts or growth.
            if mask {
                masked[span.lowerBound] = 0x30
                for index in (span.lowerBound + 1)..<span.upperBound { masked[index] = 0x20 }
            }
        }
        // The strict scanner already established original syntax. Wrong ID types/fractions
        // must not be reclassified as parse errors by ordinary Double payload decoding.
        if let invalidID { throw invalidID }
        let source = scanned.ids.isEmpty ? text : String(decoding: masked, as: UTF8.self)
        guard let value = try? JSONValue.parse(source), var fields = value.objectValue else { throw wireParseError() }
        fields["id"] = nil
        return .init(id: id, fields: fields)
    }

    public static func encode(id: RPCID?, fields: [String: JSONValue]) throws -> Data {
        guard fields["id"] == nil else { throw RPCError(code: -32600, message: "RPC id must be supplied separately") }
        let body = try JSONEncoder().encode(JSONValue.object(fields))
        guard let id else {
            guard body.count <= maximumBytes else { throw wireParseError() }
            return body
        }
        var data = Data("{\"id\":".utf8)
        data.append(try id.encoded())
        if !fields.isEmpty { data.append(0x2C) }
        data.append(contentsOf: body.dropFirst())
        guard data.count <= maximumBytes else { throw wireParseError() }
        return data
    }
}

private struct ObjectScanner {
    let bytes: [UInt8]
    let maximumDepth: Int
    private var index = 0
    init(bytes: [UInt8], maximumDepth: Int) { self.bytes = bytes; self.maximumDepth = maximumDepth }

    struct Scanned { let ids: [Range<Int>]; let duplicate: Bool }
    private var ids: [Range<Int>] = []
    private var duplicate = false
    mutating func scan() throws -> Scanned {
        whitespace()
        let object = index < bytes.count && bytes[index] == 0x7B
        try value(depth: 0, top: object)
        whitespace(); guard index == bytes.count else { throw wireParseError() }
        guard object else { throw RPCError(code: -32600, message: "RPC envelope must be one object") }
        return .init(ids: ids, duplicate: duplicate)
    }
    private mutating func value(depth: Int, top: Bool = false) throws {
        guard index < bytes.count else { throw wireParseError() }
        switch bytes[index] {
        case 0x22: _ = try string()
        case 0x7B:
            guard depth < maximumDepth else { throw wireParseError() }
            index += 1; whitespace()
            if take(0x7D) { return }
            var keys = Set<Data>()
            while true {
                let span = try string()
                // string() has validated syntax/Unicode before this second key decode.
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[span]))
                if top, !keys.insert(Data(key.utf8)).inserted { duplicate = true }
                whitespace(); guard take(0x3A) else { throw wireParseError() }; whitespace()
                let start = index
                try value(depth: depth + 1)
                if top, key.utf8.elementsEqual([0x69, 0x64]) { ids.append(start..<index) }
                whitespace()
                if take(0x7D) { return }
                guard take(0x2C) else { throw wireParseError() }; whitespace()
                // Next iteration requires a string key; a trailing comma cannot close.
            }
        case 0x5B:
            guard depth < maximumDepth else { throw wireParseError() }
            index += 1; whitespace()
            if take(0x5D) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if take(0x5D) { return }
                guard take(0x2C) else { throw wireParseError() }; whitespace()
            }
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        case 0x2D, 0x30...0x39: try number()
        default: throw wireParseError()
        }
    }
    private mutating func literal(_ literal: String) throws {
        for byte in literal.utf8 { guard take(byte) else { throw wireParseError() } }
    }
    private mutating func number() throws {
        _ = take(0x2D)
        guard index < bytes.count else { throw wireParseError() }
        if !take(0x30) {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { throw wireParseError() }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if take(0x2E) {
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > start else { throw wireParseError() }
        }
        if take(0x65) || take(0x45) {
            if !take(0x2B) { _ = take(0x2D) }
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > start else { throw wireParseError() }
        }
    }
    private mutating func string() throws -> Range<Int> {
        let start = index
        guard take(0x22) else { throw wireParseError() }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 0x22 {
                let span = start..<index
                guard (try? JSONDecoder().decode(String.self, from: Data(bytes[span]))) != nil else { throw wireParseError() }
                return span
            }
            guard byte >= 0x20 else { throw wireParseError() }
            if byte == 0x5C {
                guard index < bytes.count else { throw wireParseError() }
                let escape = bytes[index]; index += 1
                if escape == 0x75 {
                    for _ in 0..<4 {
                        guard index < bytes.count, isDigit(bytes[index]) || (0x41...0x46).contains(bytes[index]) || (0x61...0x66).contains(bytes[index]) else { throw wireParseError() }
                        index += 1
                    }
                } else {
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) else { throw wireParseError() }
                }
            }
        }
        throw wireParseError()
    }
    private mutating func whitespace() { while index < bytes.count, isWhitespace(bytes[index]) { index += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
}

private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
private func isWhitespace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0D, 0x0A].contains(byte) }
private func wireParseError() -> RPCError { .init(code: -32700, message: "Malformed or over-budget RPC JSON") }
private func invalidWireID() -> RPCError { .init(code: -32600, message: "Invalid MCP request id") }
