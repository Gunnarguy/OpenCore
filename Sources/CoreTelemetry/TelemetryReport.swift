import Foundation

/// Renders collected spans.
///
/// Two formats, because the two audiences want different things: a tree for a person trying to
/// understand where the time went, and JSONL for anything that wants to diff two runs.
///
/// Neither writes anywhere. The caller decides the destination, which is what keeps this file
/// incapable of touching stdout on the `opencore mcp` path.
public enum TelemetryReport {

    // MARK: - Tree

    /// A nested, aligned tree with durations and counters.
    ///
    /// Self time is shown only where it is meaningfully different from total, because on a
    /// tree where most nodes are pure delegation an always-present self column is noise that
    /// hides the two rows where it matters.
    public static func tree(_ spans: [TelemetrySpan], droppedCount: Int = 0) -> String {
        guard !spans.isEmpty else { return "no telemetry recorded (set OPENCORE_TELEMETRY=1)" }

        var childrenOf: [UInt64: [TelemetrySpan]] = [:]
        var byID: [UInt64: TelemetrySpan] = [:]
        for span in spans { byID[span.id] = span }

        var roots: [TelemetrySpan] = []
        for span in spans {
            // A span whose parent was dropped by the cap is re-parented to the root rather
            // than vanishing from the report along with it.
            if let parent = span.parentID, byID[parent] != nil {
                childrenOf[parent, default: []].append(span)
            } else {
                roots.append(span)
            }
        }

        var labels: [(depth: Int, span: TelemetrySpan, prefix: String)] = []
        func walk(_ span: TelemetrySpan, depth: Int, prefix: String, isLast: Bool) {
            labels.append((depth, span, prefix))
            let children = childrenOf[span.id] ?? []
            for (index, child) in children.enumerated() {
                let branch = prefix + (depth == 0 ? "" : (isLast ? "   " : "│  "))
                walk(child, depth: depth + 1, prefix: branch, isLast: index == children.count - 1)
            }
        }
        for (index, root) in roots.enumerated() {
            walk(root, depth: 0, prefix: "", isLast: index == roots.count - 1)
        }

        // Two passes: measure the widest rendered name so durations line up in one column.
        var rendered: [(name: String, span: TelemetrySpan)] = []
        for (depth, span, prefix) in labels {
            let connector = depth == 0 ? "" : (isLastChild(span, in: childrenOf, byID: byID) ? "└─ " : "├─ ")
            rendered.append((prefix + connector + span.name, span))
        }
        let width = min(rendered.map(\.name.count).max() ?? 0, 64)

        var lines: [String] = []
        for (name, span) in rendered {
            let padded = name.padding(toLength: max(width, name.count), withPad: " ", startingAt: 0)
            var line = "\(padded)  \(duration(span))  [\(span.category.rawValue)]"

            let counters = span.counters.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            if !counters.isEmpty { line += "  \(counters)" }

            let attributes = span.attributes.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            if !attributes.isEmpty { line += "  \(attributes)" }

            if let failure = span.failure { line += "  FAILED: \(failure.prefix(120))" }
            lines.append(line)
        }

        if droppedCount > 0 {
            lines.append("")
            lines.append("\(droppedCount) span(s) dropped: the buffer cap was reached, so this tree is incomplete.")
        }
        return lines.joined(separator: "\n")
    }

    private static func isLastChild(
        _ span: TelemetrySpan,
        in childrenOf: [UInt64: [TelemetrySpan]],
        byID: [UInt64: TelemetrySpan]
    ) -> Bool {
        guard let parent = span.parentID, let siblings = childrenOf[parent] else { return true }
        return siblings.last?.id == span.id
    }

    private static func duration(_ span: TelemetrySpan) -> String {
        if span.isEvent { return "      ·" }
        guard let milliseconds = span.milliseconds else { return "   open" }
        if milliseconds >= 1000 { return String(format: "%6.2fs", milliseconds / 1000) }
        return String(format: "%5.0fms", milliseconds)
    }

    // MARK: - Summary

    /// Total wall time per category, and the slowest individual spans.
    ///
    /// Category totals sum *self* time, not total, or every row would be inflated by its
    /// children and the percentages would add up to far more than the run took.
    public static func summary(_ spans: [TelemetrySpan]) -> String {
        guard !spans.isEmpty else { return "no telemetry recorded (set OPENCORE_TELEMETRY=1)" }

        var childTime: [UInt64: Double] = [:]
        for span in spans {
            guard let parent = span.parentID, let ms = span.milliseconds else { continue }
            childTime[parent, default: 0] += ms
        }

        var perCategory: [TelemetryCategory: Double] = [:]
        var selfTimes: [(name: String, category: TelemetryCategory, ms: Double)] = []
        for span in spans where !span.isEvent {
            guard let total = span.milliseconds else { continue }
            let selfTime = max(0, total - (childTime[span.id] ?? 0))
            perCategory[span.category, default: 0] += selfTime
            selfTimes.append((span.name, span.category, selfTime))
        }

        let wall = perCategory.values.reduce(0, +)
        var lines = ["time by layer (self time, total \(String(format: "%.2f", wall / 1000))s)"]
        for (category, ms) in perCategory.sorted(by: { $0.value > $1.value }) {
            let share = wall > 0 ? (ms / wall) * 100 : 0
            lines.append(String(format: "  %-8s %8.0fms  %5.1f%%", (category.rawValue as NSString).utf8String!, ms, share))
        }

        lines.append("")
        lines.append("slowest spans by self time")
        for entry in selfTimes.sorted(by: { $0.ms > $1.ms }).prefix(10) {
            lines.append(String(format: "  %8.0fms  %@ [%@]", entry.ms, entry.name, entry.category.rawValue))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSONL

    /// One span per line, for diffing two runs or feeding anything else.
    public static func jsonl(_ spans: [TelemetrySpan]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try spans
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }
}
