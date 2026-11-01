import SwiftUI

private enum ModeFilter: String, CaseIterable, Identifiable {
    case all = "All modes"
    case currentSize = "Current size"
    case hiDPI = "HiDPI"
    case oneToOne = "1× render"
    case panelPixels = "Panel pixels"
    case inspectOnly = "Inspect only"
    var id: String { rawValue }
}

private struct ResolutionGroup: Identifiable {
    let width: Int
    let height: Int
    let choices: [ConnectedDisplayModeChoice]
    var id: String { "\(width)x\(height)" }
}

struct ConnectedDisplayModeControlsView: View {
    let display: ConnectedDisplay
    @ObservedObject private var provider = BetterDisplayClient.shared
    @ObservedObject private var controller = ConnectedDisplayModeController.shared
    @State private var selected = ""
    @State private var search = ""
    @State private var filter = ModeFilter.all
    @State private var highestRefreshOnly = false

    private var currentChoice: ConnectedDisplayModeChoice? {
        display.modeChoices.first { $0.id == display.currentModeKey }
    }

    private var selectedChoice: ConnectedDisplayModeChoice? {
        display.modeChoices.first { $0.id == selected }
    }

    private var modeGroups: [ResolutionGroup] {
        let current = currentChoice
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "").lowercased()
        let resolutions = Dictionary(grouping: display.modeChoices) { "\($0.width)x\($0.height)" }
        return resolutions.values.compactMap { choices -> ResolutionGroup? in
            let maximumRefresh = choices.compactMap(\.refreshRate).max()
            let matches = choices.filter { choice in
                let matchesFilter: Bool
                switch filter {
                case .all: matchesFilter = true
                case .currentSize:
                    matchesFilter = choice.width == current?.width && choice.height == current?.height
                case .hiDPI: matchesFilter = choice.isHiDPI
                case .oneToOne: matchesFilter = choice.pixelWidth == choice.width && choice.pixelHeight == choice.height
                case .panelPixels: matchesFilter = matchesPanelPixels(choice)
                case .inspectOnly: matchesFilter = !choice.usableForDesktop
                }
                let searchable = "\(choice.title) id \(choice.modeID) \(choice.isHiDPI ? "HiDPI" : "") \(choice.id)"
                    .replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "").lowercased()
                let matchesRefresh = !highestRefreshOnly || maximumRefresh == nil || choice.refreshRate == maximumRefresh
                return matchesFilter && matchesRefresh && (query.isEmpty || searchable.contains(query))
            }.sorted { lhs, rhs in
                if (lhs.id == display.currentModeKey) != (rhs.id == display.currentModeKey) {
                    return lhs.id == display.currentModeKey
                }
                if lhs.refreshRate != rhs.refreshRate { return (lhs.refreshRate ?? -1) > (rhs.refreshRate ?? -1) }
                if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
                return lhs.id < rhs.id
            }
            guard let first = matches.first else { return nil }
            return ResolutionGroup(width: first.width, height: first.height, choices: matches)
        }.sorted { lhs, rhs in
            let lhsCurrent = lhs.width == current?.width && lhs.height == current?.height
            let rhsCurrent = rhs.width == current?.width && rhs.height == current?.height
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            return lhs.height > rhs.height
        }
    }

    private var catalogLocked: Bool {
        controller.pendingDisplayID != nil || controller.isBusy || provider.isMutating
    }

    var body: some View {
        let groups = modeGroups
        let current = currentChoice
        let visibleCount = groups.reduce(0) { $0 + $1.choices.count }
        GroupBox("Resolution, refresh rate & scaling") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Desktop size determines how much fits on screen. Render pixels are the image macOS draws; HiDPI draws more pixels for the same desktop size. A larger render image does not add pixels to the panel.")
                    .font(.callout).foregroundStyle(.secondary)
                if let width = display.descriptor?.nativeWidth, let height = display.descriptor?.nativeHeight {
                    Text("Reported panel pixels: \(width) × \(height). “Panel pixels” matches that reported size to a mode’s render image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ConnectedDisplayModeFiltersView(
                    search: $search, filter: $filter, highestRefreshOnly: $highestRefreshOnly,
                    hasPanelDimensions: display.descriptor?.nativeWidth != nil && display.descriptor?.nativeHeight != nil,
                    resetFilters: resetFilters)
                Text("\(visibleCount) of \(display.modeChoices.count) exact macOS modes · current desktop size first, then refresh rate")
                    .font(.caption).foregroundStyle(.secondary)
                ConnectedDisplayModeCatalogView(
                    groups: groups, selected: selected, currentKey: display.currentModeKey,
                    currentWidth: current?.width, currentHeight: current?.height,
                    panelWidth: display.descriptor?.nativeWidth, panelHeight: display.descriptor?.nativeHeight,
                    isLocked: catalogLocked, select: { selected = $0 })
                if let choice = selectedChoice {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected: \(choice.title)").font(.callout).fontWeight(.medium)
                        Text("Exact mode: \(choice.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if !choice.usableForDesktop {
                            Text("Inspection only. macOS does not mark this mode as usable for the desktop.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !groups.contains(where: { $0.choices.contains(where: { $0.id == selected }) }) {
                            Text("The selected mode is outside the current filters. Reset filters to show its row.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Test Selected Mode", systemImage: "display") { controller.preview(display: display, choiceID: selected) }
                        .disabled(selectedChoice?.usableForDesktop != true || selected == display.currentModeKey || catalogLocked || display.mirrored || !display.active)
                    if controller.pendingDisplayID != nil {
                        Button("Keep · \(controller.remainingSeconds)s") { controller.keep() }
                        Button("Revert", role: .cancel) { controller.revert() }
                    }
                }
                Text("Select a row, test it, then Keep or Revert. If you do not confirm within 15 seconds, OpenCore attempts to restore the captured modes and screen layout.")
                    .font(.caption).foregroundStyle(.secondary)
                if let pendingID = controller.pendingDisplayID, pendingID != display.id {
                    Text("The active preview is on another display. Keep and Revert apply to that preview.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if display.mirrored { Text("Mode previews are unavailable while displays are mirrored. Change mirroring in Display Settings first.").font(.callout).foregroundStyle(.secondary) }
                if let message = controller.message { Text(message).font(.callout).textSelection(.enabled) }
                Text("Keep lasts for this login session. No permanent display configuration is written. All modes come directly from this macOS connection; no resolution or refresh combinations are invented.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .onAppear { selected = display.currentModeKey ?? "" }
        .onChange(of: display.id) { _, _ in
            selected = display.currentModeKey ?? ""
            resetFilters()
        }
        .onChange(of: display.currentModeKey) { _, key in selected = key ?? "" }
        .onChange(of: display.modeChoices) { _, choices in
            if !choices.contains(where: { $0.id == selected }) { selected = display.currentModeKey ?? "" }
        }
    }

    private func resetFilters() {
        search = ""
        filter = .all
        highestRefreshOnly = false
    }

    private func matchesPanelPixels(_ choice: ConnectedDisplayModeChoice) -> Bool {
        choice.pixelWidth == display.descriptor?.nativeWidth && choice.pixelHeight == display.descriptor?.nativeHeight
    }
}

private struct ConnectedDisplayModeFiltersView: View {
    @Binding var search: String
    @Binding var filter: ModeFilter
    @Binding var highestRefreshOnly: Bool
    let hasPanelDimensions: Bool
    let resetFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search resolution, Hz or mode ID", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search macOS display modes")
                Button("Reset filters", action: resetFilters)
                    .disabled(search.isEmpty && filter == .all && !highestRefreshOnly)
            }
            // Chosen chip width lets the visible filters wrap in a narrow pane.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], spacing: 6) {
                ForEach(ModeFilter.allCases) { option in
                    ConnectedDisplayModeFilterButton(option: option, isSelected: filter == option,
                                                     hasPanelDimensions: hasPanelDimensions) {
                        filter = option
                    }
                }
            }
            Toggle("Highest reported Hz per desktop size", isOn: $highestRefreshOnly)
                .toggleStyle(.checkbox)
                .help("Show only the highest refresh rate macOS offers for each desktop size. Sizes without any reported rate remain visible.")
        }
    }
}

private struct ConnectedDisplayModeFilterButton: View {
    let option: ModeFilter
    let isSelected: Bool
    let hasPanelDimensions: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Label(option.rawValue, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? Color.accentColor : Color.secondary)
        .disabled(option == .panelPixels && !hasPanelDimensions)
        .help(option == .panelPixels ? "Match render dimensions to the panel pixels reported by the display descriptor. Unavailable when those dimensions are not reported." : option.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectedDisplayModeCatalogView: View {
    let groups: [ResolutionGroup]
    let selected: String
    let currentKey: String?
    let currentWidth: Int?
    let currentHeight: Int?
    let panelWidth: Int?
    let panelHeight: Int?
    let isLocked: Bool
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ConnectedDisplayModeResolutionHeader(
                            group: group, isCurrentSize: group.width == currentWidth && group.height == currentHeight)
                        ForEach(group.choices) { choice in
                            ConnectedDisplayModeChoiceRow(
                                choice: choice, isSelected: choice.id == selected,
                                isCurrent: choice.id == currentKey,
                                matchesPanelPixels: choice.pixelWidth == panelWidth && choice.pixelHeight == panelHeight,
                                select: { select(choice.id) })
                                .disabled(isLocked)
                        }
                    }
                }
                if groups.isEmpty {
                    ContentUnavailableView("No matching modes", systemImage: "magnifyingglass", description: Text("Reset the filters to see every exact mode offered by this connection."))
                }
            }.padding(6)
        }
        // Chosen viewport bounds keep even large catalogs lazy and leave
        // confirmation/recovery controls visible outside the scrolling list.
        .frame(height: 340)
        .background(Color.primary.opacity(0.025), in: .rect(cornerRadius: 8))
    }
}

private struct ConnectedDisplayModeResolutionHeader: View {
    let group: ResolutionGroup
    let isCurrentSize: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(group.width) × \(group.height) desktop").font(.headline)
            Text("\(group.choices.count) modes").font(.caption).foregroundStyle(.secondary)
            if isCurrentSize { Text("Current size").font(.caption).foregroundStyle(.tint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.regularMaterial)
    }
}

private struct ConnectedDisplayModeChoiceRow: View {
    let choice: ConnectedDisplayModeChoice
    let isSelected: Bool
    let isCurrent: Bool
    let matchesPanelPixels: Bool
    let select: () -> Void

    private var refreshLabel: String {
        choice.refreshRate.map { "\($0.formatted(.number.precision(.fractionLength(0...3)))) Hz" } ?? "Refresh not reported"
    }

    private var scaleLabel: String {
        if choice.isHiDPI { return "HiDPI" }
        return choice.width == choice.pixelWidth && choice.height == choice.pixelHeight ? "1× render" : "Scaled render"
    }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(choice.width) × \(choice.height) · \(refreshLabel)").font(.headline).monospacedDigit()
                        Text(scaleLabel).font(.caption).foregroundStyle(.secondary)
                        if isCurrent { Text("Current").font(.caption).fontWeight(.semibold) }
                        if isSelected { Text("Selected").font(.caption).foregroundStyle(.tint) }
                    }
                    Text("Render image: \(choice.pixelWidth) × \(choice.pixelHeight) pixels\(matchesPanelPixels ? " · matches reported panel pixels" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Mode ID \(choice.modeID) · flags 0x\(String(choice.ioFlags, radix: 16))\(choice.usableForDesktop ? "" : " · inspection only")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.025), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Exact mode: \(choice.id)")
        .accessibilityLabel("Select \(choice.title), mode ID \(choice.modeID)\(choice.usableForDesktop ? "" : ", inspection only")")
        .accessibilityValue(isCurrent ? "Current mode" : (isSelected ? "Selected mode" : "Available mode"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
