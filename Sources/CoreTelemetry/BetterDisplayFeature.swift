import Foundation

/// A feature advertised by the installed CLI, not a claim that a particular display supports it.
public struct BetterDisplayFeature: Identifiable, Equatable, Sendable {
    public let id: String
    public let explanation: String

    public init(id: String, explanation: String) {
        self.id = id
        self.explanation = explanation
    }

    public var isReadOnly: Bool {
        if explanation.localizedCaseInsensitiveContains("Information retrieval feature") { return true }
        // Installed help uses both "Use with get" and "Use with `get`". Inspect only
        // explicit usage clauses so a description mentioning both set and get stays writable.
        let usageWords = explanation.components(separatedBy: ".").flatMap { sentence -> [String] in
            guard let range = sentence.range(of: "Use with ", options: .caseInsensitive) else { return [] }
            return sentence[range.upperBound...].lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let operations = Set(usageWords)
        return operations.contains("get") && operations.isDisjoint(with: ["set", "perform", "toggle", "feed"])
    }

    public var requiresValue: Bool { !explanation.contains("No value must be specified") }
    public var isBoolean: Bool { explanation.contains("Bool value") }
    public var requiresAdditionalContext: Bool {
        explanation.localizedCaseInsensitiveContains("specifier") ||
        explanation.localizedCaseInsensitiveContains("target display") ||
        ["moveTo", "mirror", "stream", "pip", "contentStreamWindow", "videoFilter", "framebufferBoolProperty", "framebufferNumericProperty", "control"].contains(id)
    }

    public var offeredAsWrite: Bool {
        !isReadOnly && !requiresAdditionalContext && !Self.specialized.contains(id) &&
        (isBoolean || explanation.contains("contiguous range") || explanation.contains("Specific values must") || !requiresValue)
    }

    /// Only an explicit comma-separated list of quoted tokens becomes picker options.
    /// A range such as `1` to `5` stays a description, with no invented intermediate values.
    public var advertisedValues: [String] {
        for marker in ["Valid values are ", "Available values: "] {
            guard let range = explanation.range(of: marker) else { continue }
            var quoted = false
            var list = ""
            for character in explanation[range.upperBound...] {
                if character == "`" { quoted.toggle() }
                if character == "." && !quoted { break }
                list.append(character)
            }
            guard !quoted else { return [] }
            let tokens = list.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var values: [String] = []
            for token in tokens {
                guard token.count >= 3, token.first == "`", token.last == "`" else { return [] }
                let value = String(token.dropFirst().dropLast())
                guard !value.contains("`"), !value.contains(where: { $0.isNewline }),
                      !value.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
                values.append(value)
            }
            return Set(values).count == values.count ? values : []
        }
        return []
    }

    // These have purpose-built controls with identity/range/mode validation instead.
    public static let specialized: Set<String> = ["ddc", "ddcAlt", "changeInputSource", "connectionMode", "displayModeNumber", "resolution", "resolutionHorizontal", "resolutionVertical", "refreshRate", "hiDPI"]

    public static func catalog(_ help: String) -> [Self] {
        help.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("- `"), let split = line.range(of: "` - ") else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 3)..<split.lowerBound])
            let text = String(line[split.upperBound...])
            guard text.contains("Device (display) specific feature"), !text.contains("Not a device"),
                  !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return Self(id: id, explanation: text)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
