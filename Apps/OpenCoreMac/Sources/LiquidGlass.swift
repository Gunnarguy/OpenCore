import AppKit
import CoreModel
import CorePresentation
import SwiftUI

typealias Pastel = CorePresentation.Pastel

/// Liquid Glass surfaces and cross-screen navigation components (macOS 26 / 27+).
struct OpenCoreGlassCluster<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

@MainActor
private struct OpenCoreGlassCardModifier: ViewModifier {
    @Environment(\.appSettings) private var prefs
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let isLight = prefs.isEffectiveLightMode
        let resolvedTint = Pastel.resolve(tint)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let cardOpacity = prefs.glassCardOpacity
        let borderGlow = prefs.glassBorderGlow
        let tintStrength = isLight ? min(prefs.glassTintStrength * 0.75, 0.14) : prefs.glassTintStrength
        let baseSurface = isLight
            ? Color(red: 0.98, green: 0.985, blue: 1.00).opacity(max(0.90, cardOpacity))
            : Color(red: 0.08, green: 0.10, blue: 0.14).opacity(cardOpacity)
        content
            .background {
                ZStack {
                    shape.fill(baseSurface)
                    shape.fill(.ultraThinMaterial)
                    if let resolvedTint {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    resolvedTint.opacity(interactive ? tintStrength * 1.4 : tintStrength),
                                    resolvedTint.opacity(tintStrength * 0.25),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    prefs.pastelAccent.color.opacity(tintStrength * 0.45),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            (resolvedTint ?? prefs.pastelAccent.color).opacity(
                                isLight
                                    ? (resolvedTint == nil ? 0.28 : 0.42)
                                    : (resolvedTint == nil ? borderGlow * 0.55 : borderGlow)
                            ),
                            (resolvedTint ?? Pastel.ice).opacity(
                                isLight
                                    ? 0.16
                                    : (resolvedTint == nil ? borderGlow * 0.20 : borderGlow * 0.35)
                            )
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .shadow(color: isLight ? Color.black.opacity(0.05) : Color.clear, radius: 5, x: 0, y: 2)
    }
}

@MainActor
private struct OpenCoreGlassBarModifier: ViewModifier {
    @Environment(\.appSettings) private var prefs
    let cornerRadius: CGFloat
    let tint: Color?

    @ViewBuilder func body(content: Content) -> some View {
        let resolvedTint = Pastel.resolve(tint) ?? prefs.pastelAccent.color
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), prefs.useNativeLiquidGlassBars {
            GlassEffectContainer(spacing: 10) {
                content
                    .glassEffect(
                        .regular.tint(resolvedTint.opacity(0.14)),
                        in: shape
                    )
            }
        } else {
            content.openCoreGlassCard(cornerRadius: cornerRadius, tint: resolvedTint)
        }
    }
}

@MainActor
private struct OpenCorePastelBadgeModifier: ViewModifier {
    @Environment(\.appSettings) private var prefs
    let tint: Color

    @ViewBuilder func body(content: Content) -> some View {
        let isLight = prefs.isEffectiveLightMode
        let resolved = Pastel.resolve(tint) ?? tint
        let pillBase = isLight
            ? Color.white.opacity(0.92)
            : Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.85)
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(resolved)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(pillBase, in: .capsule)
            .background(resolved.opacity(isLight ? 0.13 : 0.18), in: .capsule)
            .overlay(
                Capsule().strokeBorder(resolved.opacity(isLight ? 0.36 : 0.45), lineWidth: 0.9)
            )
    }
}

extension View {
    /// Distinguished macOS 27 Liquid Glass content card:
    /// Adapts dynamically between Dark Obsidian and Light Frost surfaces with adaptive foreground colors.
    @ViewBuilder
    @MainActor
    func openCoreGlassCard(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(OpenCoreGlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Applies a distinguished macOS 27 Liquid Glass functional bar (`GlassEffectContainer` + `.glassEffect(.regular, in: ...)`).
    @ViewBuilder
    @MainActor
    func openCoreGlassBar(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil
    ) -> some View {
        modifier(OpenCoreGlassBarModifier(cornerRadius: cornerRadius, tint: tint))
    }

    /// Applies an interactive Liquid Glass capsule pill on macOS 26/27+ with luminous pastel foreground legibility.
    @ViewBuilder
    func openCoreGlassCapsule(
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        let resolvedTint = Pastel.resolve(tint)
        if #available(macOS 26.0, *) {
            self
                .foregroundStyle(resolvedTint ?? .primary)
                .glassEffect(
                    .regular.tint(resolvedTint?.opacity(0.16)).interactive(interactive),
                    in: .capsule
                )
        } else {
            self
                .foregroundStyle(resolvedTint ?? .primary)
                .background(
                    (resolvedTint ?? Color.secondary).opacity(0.16),
                    in: .capsule
                )
                .overlay(
                    Capsule().strokeBorder((resolvedTint ?? Color.white).opacity(0.28), lineWidth: 0.75)
                )
        }
    }

    /// High-contrast pastel pill badge for metadata, speeds, and statuses (adapts to Light Frost & Dark Obsidian).
    @ViewBuilder
    @MainActor
    func openCorePastelBadge(_ tint: Color = Pastel.sky) -> some View {
        modifier(OpenCorePastelBadgeModifier(tint: tint))
    }

    /// Applies `.buttonStyle(.glass)` on macOS 26/27+ and `.buttonStyle(.bordered)` on macOS 15,
    /// plus automatic live interaction telemetry on every click.
    @ViewBuilder
    func openCoreGlassButton(prominent: Bool = false, tint: Color? = nil, telemetryLabel: String? = nil) -> some View {
        let resolvedTint = Pastel.resolve(tint)
        let tracked = self.simultaneousGesture(
            TapGesture().onEnded {
                Task { @MainActor in
                    ActionFeedbackCenter.shared.notifyRawTap(label: telemetryLabel)
                }
            }
        )
        if #available(macOS 26.0, *) {
            if prominent {
                if let resolvedTint {
                    tracked.buttonStyle(.glassProminent).tint(resolvedTint)
                } else {
                    tracked.buttonStyle(.glassProminent)
                }
            } else {
                if let resolvedTint {
                    tracked.buttonStyle(.glass).tint(resolvedTint)
                } else {
                    tracked.buttonStyle(.glass)
                }
            }
        } else {
            if prominent {
                tracked.buttonStyle(.borderedProminent)
            } else {
                tracked.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Live Button & Action Telemetry Center ("See What's Literally Happening on Every Click")

@MainActor
@Observable
final class ActionFeedbackCenter {
    static let shared = ActionFeedbackCenter()

    enum Status: String, Sendable {
        case received = "RECEIVED"
        case running = "RUNNING"
        case completed = "COMPLETED"
        case noOpExplained = "NO-OP (0 CHANGES)"
        case simulated = "DRY-RUN SIMULATED"
        case warning = "NOTICE"

        var tint: Color {
            switch self {
            case .received: return Pastel.ice
            case .running: return Pastel.butter
            case .completed: return Pastel.mint
            case .noOpExplained: return Pastel.aqua
            case .simulated: return Pastel.sky
            case .warning: return Pastel.peach
            }
        }

        var symbol: String {
            switch self {
            case .received: return "hand.tap"
            case .running: return "bolt.horizontal.circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .noOpExplained: return "info.circle.fill"
            case .simulated: return "shield.lefthalf.filled"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    struct Event: Identifiable, Sendable {
        let id = UUID()
        var timestamp: Date
        var buttonTitle: String
        var commandOrQuery: String
        var outcomeExplanation: String
        var status: Status
        var durationMs: Int?
    }

    var currentEvent: Event?
    var history: [Event] = []
    var totalInteractionsCount: Int = 0
    var isHistoryExpanded: Bool = false
    private var lastExplicitTimestamp: Date = .distantPast

    private init() {
        let welcome = Event(
            timestamp: Date(),
            buttonTitle: "Live Action Telemetry Ready",
            commandOrQuery: "Action feedback",
            outcomeExplanation: "Instrumented operations report their results here. A received click alone does not confirm that an operation completed.",
            status: .received,
            durationMs: nil
        )
        currentEvent = welcome
        history = [welcome]
    }

    func notifyRawTap(label: String?) {
        totalInteractionsCount += 1
        let now = Date()
        // Only show generic tap if an explicit rich telemetry call didn't just fire within 80ms
        guard now.timeIntervalSince(lastExplicitTimestamp) > 0.08 else { return }
        let event = Event(
            timestamp: now,
            buttonTitle: label ?? "UI Control Activated",
            commandOrQuery: "Tap received",
            outcomeExplanation: "This control received a click. Its operation has not reported an outcome.",
            status: .received,
            durationMs: nil
        )
        currentEvent = event
        history.insert(event, at: 0)
        if history.count > 60 { history.removeLast() }
    }

    func record(
        button: String,
        command: String,
        outcome: String,
        status: Status = .completed,
        durationMs: Int? = nil
    ) {
        let now = Date()
        lastExplicitTimestamp = now
        totalInteractionsCount += 1
        let event = Event(
            timestamp: now,
            buttonTitle: button,
            commandOrQuery: command,
            outcomeExplanation: outcome,
            status: status,
            durationMs: durationMs
        )
        currentEvent = event
        // Replace generic tap if it was recorded a few milliseconds ago
        if let first = history.first,
           first.buttonTitle == "UI Control Activated",
           now.timeIntervalSince(first.timestamp) < 0.25 {
            history[0] = event
        } else {
            history.insert(event, at: 0)
        }
        if history.count > 60 { history.removeLast() }
    }

    func runAsync(
        button: String,
        command: String,
        operation: () async -> (outcome: String, status: Status)
    ) async {
        let start = Date()
        lastExplicitTimestamp = start
        totalInteractionsCount += 1
        let runningEvent = Event(
            timestamp: start,
            buttonTitle: button,
            commandOrQuery: command,
            outcomeExplanation: "Executing operation now...",
            status: .running,
            durationMs: nil
        )
        currentEvent = runningEvent
        history.insert(runningEvent, at: 0)
        if history.count > 60 { history.removeLast() }

        let result = await operation()
        let elapsedMs = max(1, Int(Date().timeIntervalSince(start) * 1000.0))
        lastExplicitTimestamp = Date()
        let finishedEvent = Event(
            timestamp: Date(),
            buttonTitle: button,
            commandOrQuery: command,
            outcomeExplanation: result.outcome,
            status: result.status,
            durationMs: elapsedMs
        )
        currentEvent = finishedEvent
        if let idx = history.firstIndex(where: { $0.id == runningEvent.id }) {
            history[idx] = finishedEvent
        } else {
            history.insert(finishedEvent, at: 0)
        }
    }
}

struct ActionFeedbackBar: View {
    @State private var center = ActionFeedbackCenter.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        if let ev = center.currentEvent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if ev.status == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: ev.status.symbol)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(ev.status.tint)
                    }

                    Text(ev.status.rawValue)
                        .openCorePastelBadge(ev.status.tint)

                    Text(ev.buttonTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(ev.outcomeExplanation)
                        .font(.caption)
                        .foregroundStyle(Pastel.ice)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(ev.commandOrQuery)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 320, alignment: .trailing)

                    if let ms = ev.durationMs {
                        Text("\(ms) ms")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.mint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Pastel.mint.opacity(0.14), in: .capsule)
                    }

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            center.isHistoryExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.rectangle")
                            Text("Log (\(center.history.count))")
                            Image(systemName: center.isHistoryExpanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption2.monospaced().weight(.semibold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton()
                }

                if center.isHistoryExpanded {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(center.history.prefix(15)) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Self.timeFormatter.string(from: item.timestamp))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 76, alignment: .leading)
                                    Text(item.status.rawValue)
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(item.status.tint)
                                        .frame(width: 118, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.buttonTitle)
                                                .font(.caption.weight(.bold))
                                            Text("(\(item.commandOrQuery))")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                            if let ms = item.durationMs {
                                                Text("· \(ms) ms")
                                                    .font(.caption2.monospaced().weight(.semibold))
                                                    .foregroundStyle(Pastel.mint)
                                            }
                                        }
                                        Text(item.outcomeExplanation)
                                            .font(.caption)
                                            .foregroundStyle(Pastel.ice)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .openCoreGlassCard(cornerRadius: 10, tint: ev.status.tint)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

/// Clickable entity pill that jumps directly to that entity's dossier in `EntityView`.
struct EntityLinkChip: View {
    @Environment(\.appModel) private var model
    let name: String
    var entityID: EntityID?
    var symbol: String? = "arrow.up.forward.app"
    var prominent: Bool = false

    @State private var hovering = false

    var body: some View {
        Button {
            if let entityID {
                model.openEntity(id: entityID)
            } else {
                model.openEntity(named: name)
            }
            ActionFeedbackCenter.shared.record(
                button: "Open Entity: \(name)",
                command: "Open entity dossier",
                outcome: "Requested the dossier for '\(name)'. The read has not completed.",
                status: .received
            )
        } label: {
            HStack(spacing: 5) {
                Text(name)
                    .font(prominent ? .callout.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(hovering ? Pastel.sky : .primary)
                    .lineLimit(1)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(hovering ? Pastel.sky : .secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                hovering ? Pastel.sky.opacity(0.18) : Color.white.opacity(0.07),
                in: .capsule
            )
            .overlay(
                Capsule().strokeBorder(hovering ? Pastel.sky.opacity(0.45) : Color.white.opacity(0.14), lineWidth: 0.8)
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(name) in Entities")
    }
}
