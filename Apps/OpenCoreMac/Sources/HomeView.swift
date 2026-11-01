import AppKit
import CoreModel
import CoreReason
import CoreSearch
import CoreStore
import SwiftUI

/// The Command Center.
///
/// The rule this screen is built to: **every line either says something specific about your
/// data, or it is not here.**
struct HomeView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @Binding var section: Section

    @State private var snapshot: HomeSnapshot?
    @State private var draft = ""
    @State private var inlinePassages: [AppModel.PassageRow] = []
    @State private var inlineFMSentences: [(text: String, source: Int?)] = []
    @State private var inlineFMVerdicts: [Grounding.Verdict] = []
    @State private var inlineFMInsufficient = false
    @State private var isSynthesizingInlineFM = false
    @State private var isSearchingInline = false
    @State private var inlineSearchTask: Task<Void, Never>?
    @State private var inlineRequestID = UUID()
    @State private var copiedResumeRepo: String?
    @State private var fleetFilter: FleetFilter = .all
    @State private var showingGuidePopover = false
    @State private var guideTab: GuideTab = .purpose
    @State private var showAllFleetInline = false
    @State private var machineCheck: MachineCheckTopic?
    @State private var pendingMachineDestination: Section?

    enum FleetFilter: String, CaseIterable, Identifiable {
        case all = "All Repos"
        case attention = "Attention"
        case current = "Current"

        var id: String { rawValue }
    }

    enum GuideTab: String, CaseIterable, Identifiable {
        case purpose = "What OpenCore Does (3 Jobs)"
        case pipeline = "Engine Pipeline & Jargon Translator"

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if settings.showJarvisDeck {
                    JarvisCommandDeckCard { spokenQuery in
                        draft = spokenQuery
                        runInlineSearchAndReason()
                    }
                }
                ask
                if model.answer != nil || !inlinePassages.isEmpty || isSearchingInline || isSynthesizingInlineFM {
                    inlineResultsPanel
                }
                if let snapshot {
                    WhatChangedCard(snapshot: snapshot, previousVisit: model.previousVisit)
                }
                compactStatusAndTelemetryBar
                hazardAlertBanner
                if settings.showOptionalConnectorsBanner, let snapshot {
                    attention(snapshot)
                }
                // Everything below is the operator console. It stays one toggle away in
                // Settings and is off by default, because this screen answers "what changed
                // in my history" and these answer a different question.
                if settings.showHardwareAndControlDeck {
                    visualHardwareAndControlDeck
                }
                if settings.showOperatorWorkspaces {
                    executiveWorkspaceLauncherGrid
                    if !model.fleetCards.isEmpty || model.isLoadingFleet {
                        if showAllFleetInline {
                            if settings.showVisualFleetMatrix {
                                visualFleetMatrixCard
                            }
                            liveFleetSection
                        } else {
                            attentionReposSpotlightSection
                        }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: settings.commandCenterMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Command Center")
        .sheet(item: $machineCheck, onDismiss: {
            if let destination = pendingMachineDestination {
                pendingMachineDestination = nil
                model.navigate(to: destination)
            }
        }) { topic in
            MachineChecksView(initialTopic: topic) { destination in
                pendingMachineDestination = destination
                machineCheck = nil
            }
        }
        .sheet(item: Bindable(model).activeAuditRepo) { repo in
            ReadOnlyRepoAuditSheet(
                repo: repo,
                output: model.activeAuditOutput,
                isLoading: model.isRunningRepoAudit
            ) {
                model.activeAuditRepo = nil
            }
        }
        // Keyed on `model.dataGeneration` so it loads when the database finishes opening and
        // refreshes automatically after any sync, correction, or rebuild.
        .task(id: model.dataGeneration) {
            guard let store = model.store else { return }
            do {
                snapshot = try await store.homeSnapshot(since: model.previousVisit)
            } catch {
                model.state = .failed("Could not load Home: \(error)")
            }
            if model.machineHealth == nil {
                await model.refreshMachineHealth()
            }
            if model.fleetCards.isEmpty {
                await model.refreshFleetStatus()
            }
        }
    }

    // MARK: - 4 Dedicated Workspace Launch Cards (Executive Summary Grid)

    private var executiveWorkspaceLauncherGrid: some View {
        let totalRepos = model.fleetCards.count
        let currentCount = model.fleetCards.filter(\.isHandoffCurrent).count
        let dirtyCount = model.fleetCards.filter(\.isDirty).count
        let staleCount = model.fleetCards.filter(\.isHandoffStale).count
        let eco = model.agentEcosystem
        let mem = UnifiedMemoryMonitor.shared
        let ctrl = ComputerControlManager.shared
        let hw = HardwareInspectorManager.shared

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            // 1. Repo Fleet & Handoffs (⌘3)
            Button {
                model.navigate(to: .repoFleet)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill.badge.gearshape")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Pastel.mint)
                        Text("Repo Fleet & Handoffs")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("⌘3")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(totalRepos) Repos →")
                            .openCorePastelBadge(Pastel.mint)
                    }
                    Text("\(currentCount) current · \(dirtyCount) uncommitted dirty · \(staleCount) git ahead of STATE.md")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    GeometryReader { geo in
                        let denom = CGFloat(max(totalRepos, 1))
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Pastel.mint.gradient)
                                .frame(width: max(8, geo.size.width * CGFloat(currentCount) / denom))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Pastel.aqua.gradient)
                                .frame(width: max(8, geo.size.width * CGFloat(dirtyCount) / denom))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Pastel.peach.gradient)
                                .frame(width: max(8, geo.size.width * CGFloat(staleCount) / denom))
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if settings.showCrossAgentHub {
            // 2. Coding Agents Hub (⌘4)
            Button {
                model.navigate(to: .codingAgents)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Pastel.lavender)
                        Text("Coding Agents Hub")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("⌘4")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Claude · Codex · AGY →")
                            .openCorePastelBadge(Pastel.lavender)
                    }
                    if let eco {
                        Text("\(eco.sharedAgentsSkills.count) shared skills · \(eco.codexMemoryTaskSections) handbook tasks · \(eco.codexRolloutSummaryCount) rollouts · \(eco.claudeHooksCount) hook files")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Unified skills, MEMORY.md handbook, rollout summaries & kit-bridge parity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("Claude Code (~/.claude)")
                            .openCorePastelBadge(Pastel.peach)
                        Text("Codex (~/.codex)")
                            .openCorePastelBadge(Pastel.aqua)
                        Text("Antigravity (~/.gemini)")
                            .openCorePastelBadge(Pastel.lavender)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            }

            // 3. Computer Use Studio (⌘5) & AI Models + RAM (⌘6)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder.rectangular")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Pastel.sky)
                    Text("Computer Use & Local AI Models")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        model.navigate(to: .computerControl)
                    } label: {
                        Text("Computer Use (⌘5) →")
                            .font(.caption2.weight(.bold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton(prominent: true, tint: Pastel.sky)

                    Button {
                        model.navigate(to: .aiModelsRAM)
                    } label: {
                        Text("Models & RAM (⌘6) →")
                            .font(.caption2.weight(.bold))
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton(tint: Pastel.lavender)
                }
                Text("Task selection: \(ctrl.taskModelID) · Unified Memory: \(String(format: "%.1f GiB free / %.0f GiB", mem.freeGiB, mem.totalRAMGiB)) · 13 Specialist Models")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(ctrl.isDryRun ? "DRY-RUN SELECTED" : "LIVE MODE SELECTED")
                        .openCorePastelBadge(ctrl.isDryRun ? Pastel.mint : Pastel.rose)
                    Text("Recording unavailable")
                        .openCorePastelBadge(Pastel.sky)
                    Text("Planner preview")
                        .openCorePastelBadge(Pastel.lavender)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .openCoreGlassCard(cornerRadius: 12, tint: Pastel.sky)

            // 4. Hardware, USB & Storage (⌘7)
            Button {
                model.navigate(to: .hardwareUSB)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Pastel.aqua)
                        Text("Hardware, USB & Storage")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("⌘7")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(hw.devices.count) USB · \(hw.controllers.count) xHCI →")
                            .openCorePastelBadge(Pastel.aqua)
                    }
                    Text("\(hw.devices.count) USB devices · \(hw.controllers.count) host controllers · \(hw.thunderboltDevices.count) Thunderbolt routes")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("IOKit Live Bus Tree")
                            .openCorePastelBadge(Pastel.aqua)
                        Text("Link Speed Spectrum")
                            .openCorePastelBadge(Pastel.mint)
                        Text("Disk Sparklines")
                            .openCorePastelBadge(Pastel.butter)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Focused "Needs Attention Right Now" Repo Tray on Command Center

    private var attentionReposSpotlightSection: some View {
        let attentionRepos = model.fleetCards.filter { $0.isDirty || $0.isHandoffStale }
        let displayed = Array((attentionRepos.isEmpty ? model.fleetCards : attentionRepos).prefix(4))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .foregroundStyle(Pastel.aqua)
                Text(attentionRepos.isEmpty ? "Active Repositories Spotlight" : "Repositories Needing Attention (\(attentionRepos.count) dirty or git ahead)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAllFleetInline = true
                    }
                } label: {
                    Text("Expand All \(model.fleetCards.count) Here")
                        .font(.caption2)
                }
                .controlSize(.small)
                .openCoreGlassButton()

                Button {
                    model.navigate(to: .repoFleet)
                } label: {
                    Label("Open Full Fleet Workspace (\(model.fleetCards.count) Repos · ⌘3)", systemImage: "arrow.right.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .openCoreGlassButton(prominent: true, tint: Pastel.mint)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: settings.fleetGridLayout.minCardWidth), spacing: 12)], spacing: 12) {
                ForEach(displayed) { card in
                    FleetRepoCardView(
                        card: card,
                        truncateLongText: settings.truncateLongRepoText,
                        isCopiedResume: copiedResumeRepo == card.id,
                        onOpenDossier: { model.openEntity(named: card.name) },
                        onAskInChat: {
                            model.askInChat("Summarize the current objective, recent commits, Claude & Codex memories, and open blockers for \(card.name)")
                        },
                        onCopyResumeBrief: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(card.sessionResumePrompt, forType: .string)
                            copiedResumeRepo = card.id
                        },
                        onOpenTerminal: {
                            OperatorConsoleService.openInTerminal(rootPath: card.root)
                        },
                        onRevealFinder: {
                            OperatorConsoleService.revealInFinder(path: card.root)
                        },
                        onOpenStateDoc: {
                            OperatorConsoleService.openFile(path: card.statePath)
                        },
                        onSyncRepo: {
                            Task { await model.syncSingleRepository(card) }
                        },
                        onReadOnlyAudit: {
                            Task { await model.auditRepository(card) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Compact 1-Line Status, Corpus Telemetry & Actions Bar

    private var compactStatusAndTelemetryBar: some View {
        let mcpCount = model.sources.filter { $0.handle.hasPrefix("mcp:") }.count
        return HStack(spacing: 8) {
            CompactCounterPill(
                label: "Objects",
                value: model.objectCount.formatted(),
                symbol: "cube.box.fill",
                tint: .accentColor,
                helpText: "Immutable raw files, commits, notes, and calendar events in SQLite"
            ) { model.navigate(to: .corpus) }

            CompactCounterPill(
                label: "Passages",
                value: model.chunkCount.formatted(),
                symbol: "doc.text.magnifyingglass",
                tint: .blue,
                helpText: "Searchable 200-400 word paragraphs with BM25 + 512-d vector embeddings"
            ) { model.navigate(to: .passages) }

            CompactCounterPill(
                label: "Entities",
                value: model.entityCount.formatted(),
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .indigo,
                helpText: "Deduplicated projects, people, and technologies across sources"
            ) { model.navigate(to: .entities) }

            CompactCounterPill(
                label: "Claims",
                value: model.claimCount.formatted(),
                symbol: "checkmark.seal.fill",
                tint: .green,
                helpText: "Extracted statements and inferences with source spans; a matching span does not prove an interpretation true"
            ) { model.navigate(to: .claims) }

            CompactCounterPill(
                label: "MCP",
                value: "\(mcpCount)",
                symbol: "powerplug.fill",
                tint: .purple,
                helpText: "Stored MCP sources; this count does not verify connectivity. OpenCore separately exposes an 8-tool outbound server"
            ) { model.navigate(to: .mcp) }

            if let health = model.machineHealth {
                let onlinePeers = health.tailnetPeers.filter(\.reachable).map(\.alias).joined(separator: "·")
                let lowDisk = health.isDiskSpaceLow(thresholdGiB: settings.lowDiskWarningThresholdGiB)
                HStack(spacing: 5) {
                    Image(systemName: lowDisk || health.dataVolumeFreeGiB == nil ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(lowDisk || health.dataVolumeFreeGiB == nil ? .orange : .green)
                    Text(health.freeSpaceSummary)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                    Text("· \(health.simulatorSummary) · \(health.claudeMemoryFileCount + health.codexRolloutCount) agent mem · \(onlinePeers)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .openCoreGlassCard(cornerRadius: 8)
                .help("Read-only Mac Guard: /System/Volumes/Data free space, booted simulators, unified Claude + Codex memory files, and reachable Tailnet hosts.")
            }

            Spacer(minLength: 4)

            Button {
                Task { await model.syncAllWorkspaceAndSources() }
            } label: {
                Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .controlSize(.small)
            .openCoreGlassButton(prominent: true)
            .help("Sync all local repository docs, Claude + Codex + Antigravity memories, MACHINE-MAP.md, GitHub API, Calendar, Reminders, Notes, and 512-d vectors")

            Button {
                showingGuidePopover.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("How OpenCore Works (6-layer pipeline & glossary)")
            .popover(isPresented: $showingGuidePopover, arrowEdge: .bottom) {
                architectureGuideSection
                    .frame(width: 780)
                    .padding(8)
            }
        }
    }

    // MARK: - Cross-Agent Unification & Memory Hub (Claude Code · Codex · Antigravity)

    private func crossAgentUnificationCard(_ eco: AgentEcosystemSnapshot) -> some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return VStack(alignment: .leading, spacing: 10) {
            // Single-line header + right-aligned quick inspect buttons
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .foregroundStyle(Pastel.lavender)
                Text("Cross-Agent Unification Hub")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text("Claude Code · Codex · Antigravity (agy)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Pastel.lavender)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Pastel.lavender.opacity(0.12), in: .capsule)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    OperatorConsoleService.openFile(path: "\(home)/.codex/memories/MEMORY.md")
                } label: {
                    Label("Codex MEMORY.md", systemImage: "book.closed.fill")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Open ~/.codex/memories/MEMORY.md (Consolidated Codex Handbook)")

                Button {
                    OperatorConsoleService.openFile(path: "\(home)/.agents/briefs/codex-antigravity-parity.md")
                } label: {
                    Label("Parity Brief", systemImage: "doc.badge.gearshape")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Open ~/.agents/briefs/codex-antigravity-parity.md")

                Button {
                    OperatorConsoleService.openFile(path: "\(home)/.agents/MACHINE-MAP.md")
                } label: {
                    Label("MACHINE-MAP (\(eco.machineMapSizeKB) KB)", systemImage: "map.fill")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Open ~/.agents/MACHINE-MAP.md")

                Button {
                    Task { await model.syncCrossAgentMemories() }
                } label: {
                    Label("Sync Agent Memories", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .controlSize(.mini)
                .openCoreGlassButton(prominent: true)
                .help("Ingest all Claude project memories, Codex MEMORY.md + 51 rollout summaries, and Antigravity rules into OpenCore")
            }

            // 3-Column Agent Comparison Grid (strict single-line rows inside each column)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // 1. Claude Code
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                        Text("CLAUDE CODE (~/.claude)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.peach)
                            .lineLimit(1)
                        Spacer()
                        Text("\(eco.claudeHooksCount) hook files")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Pastel.mint)
                    }
                    Text("\(eco.claudeSkills.count) Skills · \(eco.claudeMemoryFileCount) Memory Files")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text("Across \(eco.claudeMemoryProjectCount) project slugs · fleet.py + here.py")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 9, tint: .orange)

                // 2. Codex
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(.cyan).frame(width: 7, height: 7)
                        Text("CODEX (~/.codex + ~/.agents)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.aqua)
                            .lineLimit(1)
                        Spacer()
                        Text(eco.codexMemoryStateCommit.isEmpty ? "active" : "@\(eco.codexMemoryStateCommit)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Pastel.aqua)
                    }
                    Text("\(eco.codexMemoryTaskSections) Handbook Sections · \(eco.codexRolloutSummaryCount) Rollouts")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text("\(eco.sharedAgentsSkills.count) shared + \(eco.codexProceduralSkills.count) procedural skills · \(eco.codexHooksCount) hook files (execution unverified)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 9, tint: .cyan)

                // 3. Antigravity (agy)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(.purple).frame(width: 7, height: 7)
                        Text("ANTIGRAVITY (agy · ~/.gemini)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.lavender)
                            .lineLimit(1)
                        Spacer()
                        Text(eco.agyKitBridgeExists ? "kit-bridge ON" : "bridge off")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(eco.agyKitBridgeExists ? .green : .secondary)
                    }
                    Text("\(eco.skillsInSyncCount)/\(eco.sharedAgentsSkills.count) Same-Source Skill Folders + \(eco.agySkillsCount) AGY Skills")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text("Reads/writes same STATE.md, CLAUDE.md & AGENTS.md")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 9, tint: .purple)
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 12)
    }

    /// Every warning opens the matching review panel; numbered names alone do not prove an iCloud conflict.
    @ViewBuilder
    private var hazardAlertBanner: some View {
        if let health = model.machineHealth,
           health.isDiskSpaceLow(thresholdGiB: settings.lowDiskWarningThresholdGiB) || health.dataVolumeFreeGiB == nil || health.bootedSimulators.count > 1 || !health.icloudConflictFiles.isEmpty || health.simulatorCheckError != nil || health.numberedFileScanError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if health.isDiskSpaceLow(thresholdGiB: settings.lowDiskWarningThresholdGiB),
                   let free = health.dataVolumeFreeGiB, let used = health.dataVolumeUsedPercent {
                    Note(
                        tint: .orange,
                        headline: String(format: "Low Data Volume Space: %.1f GiB free (%d%% used)", free, used),
                        detail: "Below your \(settings.lowDiskWarningThresholdGiB.formatted()) GiB warning level. Review model downloads, build files and storage locations."
                    ) { machineCheck = .storage }
                } else if health.dataVolumeFreeGiB == nil {
                    Note(tint: .orange, headline: "Data volume space could not be measured", detail: "Open storage details to retry the check.") { machineCheck = .storage }
                }
                if health.bootedSimulators.count > 1 {
                    Note(
                        tint: .orange,
                        headline: "\(health.bootedSimulators.count) simulators are running",
                        detail: "Booted: \(health.bootedSimulators.map(\.name).joined(separator: ", ")). Shut down unused devices when done."
                    ) { machineCheck = .simulators }
                }
                if !health.icloudConflictFiles.isEmpty {
                    Note(
                        tint: .orange,
                        headline: "\(health.icloudConflictFiles.count) possible duplicate files\(health.icloudConflictFiles.count >= OperatorConsoleService.numberedFileScanLimit ? " (scan limit reached)" : "")",
                        detail: health.icloudConflictFiles.prefix(3).joined(separator: ", ")
                    ) { machineCheck = .duplicates }
                }
                if let error = health.numberedFileScanError {
                    Note(tint: .orange, headline: "Numbered-file scan incomplete", detail: error) { machineCheck = .duplicates }
                }
                if let error = health.simulatorCheckError {
                    Note(tint: .orange, headline: "Simulator status unavailable", detail: error) { machineCheck = .simulators }
                }
            }
        }
    }

    // MARK: - Interactive Architecture & Jargon Explainer

    private var architectureGuideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Label("How OpenCore Works", systemImage: "cpu.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.accentColor)

                Picker("Guide", selection: $guideTab) {
                    ForEach(GuideTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)

                Spacer()

                Button {
                    showingGuidePopover = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close guide")
            }

            if guideTab == .purpose {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    GuideJobCard(
                        number: "1",
                        title: "\"Where Was I?\" Across All Repos",
                        engineBadge: "fleet.py + here.py + Codex Memories",
                        detail: "Reads live git state, CLAUDE.md, AGENTS.md, STATE.md, ~/.claude/projects/*/memory, and ~/.codex/memories so every repo's goal, commit, and lessons sit in one place.",
                        symbol: "folder.fill.badge.gearshape",
                        tint: .accentColor
                    )
                    GuideJobCard(
                        number: "2",
                        title: "Zero-Hallucination On-Device Q&A",
                        engineBadge: "Hybrid RRF + /usr/bin/fm + Grounding",
                        detail: "Searches commits, notes, calendar, and docs by keyword (BM25) and meaning (512-d vectors), then synthesizes cited answers with Apple's on-device Foundation Model (/usr/bin/fm).",
                        symbol: "checkmark.shield.fill",
                        tint: .green
                    )
                    GuideJobCard(
                        number: "3",
                        title: "Privacy-Firewalled Memory for AI Agents",
                        engineBadge: "CoreMCP (8 Tools) + Domain Firewall",
                        detail: "Gives Claude Code, Codex, and Antigravity read-only access to your project memory while blocking medical, financial, personal, and credential domains.",
                        symbol: "lock.shield.fill",
                        tint: .purple
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every piece of data flows through 6 inspectable layers. Click any layer to open it:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 10)], spacing: 10) {
                        PipelineStageCard(
                            step: "1. Raw Input",
                            humanName: "Synced Items",
                            engineName: "Floor Objects (CoreObject)",
                            meaning: "Immutable raw files, GitHub commits, Apple Notes, Calendar events, and MCP payloads. Nothing edits or deletes them.",
                            action: {
                                showingGuidePopover = false
                                model.navigate(to: .sources)
                            }
                        )
                        PipelineStageCard(
                            step: "2. Search Index",
                            humanName: "Searchable Paragraphs",
                            engineName: "Passages (Chunk + Embedding)",
                            meaning: "200-400 word slices indexed in SQLite FTS5 (BM25 exact words) and Apple NLEmbedding (512-d semantic vectors), fused by RRF.",
                            action: {
                                showingGuidePopover = false
                                model.navigate(to: .passages)
                            }
                        )
                        PipelineStageCard(
                            step: "3. Things",
                            humanName: "Projects, People & Tools",
                            engineName: "Entities (CoreEntity)",
                            meaning: "Canonical things resolved across sources so 'OpenCore', 'opencore repo', and 'OpenCoreMac' map to one dossier.",
                            action: {
                                showingGuidePopover = false
                                model.navigate(to: .entities)
                            }
                        )
                        PipelineStageCard(
                            step: "4. Statements",
                            humanName: "Extracted Facts",
                            engineName: "Claims (CoreClaim + Evidence)",
                            meaning: "Structured (Subject, Predicate, Value) rows with an exact byte range in the source file and an Authority rank.",
                            action: {
                                showingGuidePopover = false
                                model.navigate(to: .claims)
                            }
                        )
                        PipelineStageCard(
                            step: "5. Truth & Conflicts",
                            humanName: "Reality Checks & Diffs",
                            engineName: "Beliefs & Contradictions",
                            meaning: "Compares live git HEAD against STATE.md, IOKit USB links against descriptors, and highlights conflicting claims.",
                            action: {
                                showingGuidePopover = false
                                model.navigate(to: .contradictions)
                            }
                        )
                        PipelineStageCard(
                            step: "6. Audit & Time",
                            humanName: "Proof Receipts & Two-Clock History",
                            engineName: "Receipts & Bitemporal Time Travel",
                            meaning: "Receipts record which source objects the answer path transmitted. Bitemporal tracks Knowledge Time (when learned) vs World Time (when true).",
                            action: {
                                showingGuidePopover = false
                                model.navigate(to: .timeline)
                            }
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Unified Ask & Search (Fact Graph + Hybrid Passages + On-Device /usr/bin/fm)

    private var ask: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Ask anything across your repos, Claude/Codex memories & notes (runs /usr/bin/fm on-device) or press ⌘K…", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit(runInlineSearchAndReason)
            if !draft.isEmpty {
                Button {
                    draft = ""
                    clearInlineResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(action: runInlineSearchAndReason) {
                Label("Ask On-Device (/usr/bin/fm)", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .controlSize(.small)
            .openCoreGlassButton(prominent: true)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Retrieves hybrid passages + structured claims and synthesizes a cited answer on-device via Apple Foundation Models (/usr/bin/fm)")

            Button(action: handOff) {
                Label("Multi-Turn Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .controlSize(.small)
            .openCoreGlassButton()
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Hand off this question to multi-turn Grounded Chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .openCoreGlassCard(cornerRadius: 12)
    }

    private func clearInlineResults() {
        inlineSearchTask?.cancel()
        inlineRequestID = UUID()
        model.clearAnswer()
        inlinePassages = []
        inlineFMSentences = []
        inlineFMVerdicts = []
        inlineFMInsufficient = false
        isSynthesizingInlineFM = false
        isSearchingInline = false
    }

    private var inlineResultsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("On-Device Answer & Evidence", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                if isSearchingInline || isSynthesizingInlineFM {
                    ProgressView().controlSize(.small)
                    Text(isSynthesizingInlineFM ? "Synthesizing with Apple Foundation Model (/usr/bin/fm)…" : "Searching passages & claims…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Continue in Multi-Turn Chat →") {
                        handOff()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Button("Clear") {
                    clearInlineResults()
                }
                .controlSize(.mini)
            }

            if let answer = model.answer, let activity = answer.activity, activity.totalEvents > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(answer.summary).font(.caption.weight(.semibold))
                    ActivityRows(activity: activity)
                }
            }

            // 1. On-Device Foundation Model (/usr/bin/fm) Synthesized Answer
            if !inlineFMSentences.isEmpty || inlineFMInsufficient {
                let groundedCount = inlineFMVerdicts.filter(\.isGrounded).count
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("ON-DEVICE FOUNDATION MODEL SYNTHESIS", systemImage: "cpu.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Pastel.mint)
                        Text("[/usr/bin/fm · GroundedAnswer schema · \(groundedCount)/\(inlineFMVerdicts.count) sentences grounded · on-device synthesis]")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if inlineFMInsufficient && inlineFMSentences.isEmpty {
                        Text("The retrieved passages do not directly state the answer to that question.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(inlineFMSentences.enumerated()), id: \.offset) { idx, item in
                            let verdict = idx < inlineFMVerdicts.count ? inlineFMVerdicts[idx] : nil
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: (verdict?.isGrounded ?? true) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle((verdict?.isGrounded ?? true) ? .green : .orange)
                                Text(item.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                if let src = item.source, src >= 1, src <= inlinePassages.count {
                                    let hit = inlinePassages[src - 1]
                                    Button("[\(src)] \(hit.title)") {
                                        model.inspectObject(hit.objectID, highlight: item.text)
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption2.monospaced())
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 10, tint: .green)
            }

            // 2. Deterministic Fact Graph Answer (Reasoner)
            if let answer = model.answer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("DIRECT FACT GRAPH ANSWER (DETERMINISTIC REASONER)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text("[queryClass: \(answer.receipt.queryClass.rawValue) · \(answer.receipt.objectsSearched) objects scanned · \(answer.receipt.claimsConsulted) claims checked]")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(answer.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 10, tint: .accentColor)
            }

            // 3. Top Retrieved Passages
            if !inlinePassages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CITED SOURCE PARAGRAPHS (PASSAGES · \(inlinePassages.count))")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(inlinePassages.prefix(4).enumerated()), id: \.element.id) { idx, hit in
                        HStack(alignment: .top, spacing: 10) {
                            Text("[\(idx + 1)]")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(hit.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Chip(hit.kind)
                                    Chip(hit.authority)
                                }
                                Text(hit.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Inspect Source") {
                                model.inspectObject(hit.objectID, highlight: draft)
                            }
                            .controlSize(.mini)
                            .openCoreGlassButton()
                        }
                        .padding(10)
                        .openCoreGlassCard(cornerRadius: 8)
                    }
                }
            }
        }
        .padding(16)
        .openCoreGlassCard(cornerRadius: 14)
    }

    // MARK: - Visual Hardware, USB Topology & Computer Control Deck

    private var visualHardwareAndControlDeck: some View {
        let hw = HardwareInspectorManager.shared
        let ctrl = ComputerControlManager.shared
        let health = model.machineHealth

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
            ],
            spacing: 10
        ) {
            // 1. Storage & Disk I/O Visual Gauge Card
            Button {
                machineCheck = .storage
            } label: {
                let usedPct = health?.dataVolumeUsedPercent.map { Double($0) / 100 }
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 5)
                            .frame(width: 40, height: 40)
                        Circle()
                            .trim(from: 0, to: min(max(usedPct ?? 0, 0), 1))
                            .stroke(
                                (health?.isDiskSpaceLow(thresholdGiB: settings.lowDiskWarningThresholdGiB) ?? false) ? Pastel.peach : Pastel.mint,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 40, height: 40)
                        Text(health?.dataVolumeUsedPercent.map { "\($0)%" } ?? "—")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("STORAGE & I/O")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.mint)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        Text(health?.freeSpaceSummary ?? "Disk space not measured")
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(hw.mountedExternalVolumes.count) vol · \(formatUSBTransferRate(hw.totalActiveThroughputBytesPerSecond))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 11, tint: .green)
            }
            .buttonStyle(.plain)
            .help("Measured /System/Volumes/Data free space + mounted external USB volumes & live block-storage throughput (⌘4)")

            // 2. USB & Thunderbolt Bus Spectrum Card
            Button {
                model.navigate(to: .hardwareUSB)
            } label: {
                let speeds = USBSpeed.allCases.filter { s in s != .unknown && hw.devices.contains(where: { $0.speed == s }) }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Pastel.aqua)
                        Text("USB & TB BUS (⌘4)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.aqua)
                            .lineLimit(1)
                        Spacer()
                        if !hw.performanceLimitedDevices.isEmpty {
                            Text("\(hw.performanceLimitedDevices.count) limit")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Pastel.peach)
                                .lineLimit(1)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(hw.devices.count) Devices")
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("· \(hw.controllers.count) xHCI · \(hw.thunderboltDevices.count) TB")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    GeometryReader { geo in
                        let total = max(hw.devices.count, 1)
                        HStack(spacing: 2) {
                            ForEach(speeds, id: \.self) { sp in
                                let c = hw.devices.filter { $0.speed == sp }.count
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(sp.color.gradient)
                                    .frame(width: max(geo.size.width * CGFloat(c) / CGFloat(total) - 2, 8))
                            }
                        }
                    }
                    .frame(height: 7)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 11, tint: .cyan)
            }
            .buttonStyle(.plain)
            .help("Open Live Hardware, USB & Thunderbolt Bus Topology Map (⌘4)")

            // 3. Local Automation Hub 0.3.5 + Computer Control Card
            Button {
                model.navigate(to: .computerControl)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Pastel.lavender)
                        Text("LOCAL HUB + AUTOMATION (⌘5)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.lavender)
                            .lineLimit(1)
                        Spacer()
                        Text(ctrl.isDryRun ? "DRY-RUN" : "LIVE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ctrl.isDryRun ? Pastel.mint : Pastel.peach)
                            .lineLimit(1)
                    }
                    Text("\(ctrl.models.count) Models · \(ctrl.routines.count) Routines · \(ctrl.runs.count) Runs")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Live Hub settings, routines and guide")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 11, tint: .purple)
            }
            .buttonStyle(.plain)
            .help("Open Local Automation Hub 0.3.5 + Screen Vision Studio (⌘5)")

            // 4. Tailnet Cluster & Simulator RAM Visual Card
            Button {
                Task { await model.refreshMachineHealth(checkTailnet: true) }
            } label: {
                let peers = health?.tailnetPeers ?? []
                let simulatorSummary = health?.simulatorSummary ?? "Checking simulators…"
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Pastel.periwinkle)
                        Text("TAILNET & SIMS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.periwinkle)
                            .lineLimit(1)
                        Spacer()
                        Text(simulatorSummary)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle((health?.bootedSimulators.count ?? 0) > 1 ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        ForEach(peers) { peer in
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(peer.reachable ? Pastel.mint : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(peer.alias)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(peer.reachable ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text("\(health?.numberedFileSummary ?? "Duplicate scan pending") · \(health?.sharedSkillCount ?? 15) skills")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .leading)
                .openCoreGlassCard(cornerRadius: 11, tint: .indigo)
            }
            .buttonStyle(.plain)
            .help("Click to re-verify Tailnet SSH nodes, booted simulators, and iCloud conflict files")
        }
    }

    // MARK: - Visual Fleet Matrix & Ground-Truth Proportion Chart

    private var visualFleetMatrixCard: some View {
        let total = max(model.fleetCards.count, 1)
        let syncedClean = model.fleetCards.filter { $0.isHandoffCurrent && !$0.isDirty }
        let dirtyRepos = model.fleetCards.filter(\.isDirty)
        let staleClean = model.fleetCards.filter { $0.isHandoffStale && !$0.isDirty }
        let otherRepos = model.fleetCards.filter { !$0.isHandoffCurrent && !$0.isHandoffStale && !$0.isDirty }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Visual Repository Fleet Matrix (100% Git & Filesystem Ground Truth)", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("Current & Clean: \(syncedClean.count)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.cyan).frame(width: 7, height: 7)
                        Text("Dirty Tree: \(dirtyRepos.count)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                        Text("Git Ahead of STATE.md: \(staleClean.count)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                    }
                    if !otherRepos.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(.secondary).frame(width: 7, height: 7)
                            Text("Doc Overview: \(otherRepos.count)")
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Proportional visual bar
            GeometryReader { geo in
                HStack(spacing: 3) {
                    if !syncedClean.isEmpty {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Pastel.mint.gradient)
                            .frame(width: max(geo.size.width * CGFloat(syncedClean.count) / CGFloat(total) - 2, 16))
                    }
                    if !dirtyRepos.isEmpty {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Pastel.aqua.gradient)
                            .frame(width: max(geo.size.width * CGFloat(dirtyRepos.count) / CGFloat(total) - 2, 16))
                    }
                    if !staleClean.isEmpty {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Pastel.peach.gradient)
                            .frame(width: max(geo.size.width * CGFloat(staleClean.count) / CGFloat(total) - 2, 16))
                    }
                    if !otherRepos.isEmpty {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: max(geo.size.width * CGFloat(otherRepos.count) / CGFloat(total) - 2, 16))
                    }
                }
            }
            .frame(height: 12)

            // Interactive wrapping grid of mini-pills for every repository in the fleet (zero horizontal clipping)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.fleetCards) { card in
                    let pillColor: Color = card.isDirty ? Pastel.aqua : (card.isHandoffCurrent ? Pastel.mint : (card.isHandoffStale ? Pastel.peach : Pastel.ice))
                    Button {
                        Task { await model.auditRepository(card) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(pillColor)
                                .frame(width: 6, height: 6)
                            Text(card.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            if card.dirty > 0 {
                                Text("(\(card.dirty)Δ)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Pastel.aqua)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(pillColor.opacity(0.14), in: .capsule)
                        .overlay {
                            Capsule().strokeBorder(pillColor.opacity(0.32), lineWidth: 0.75)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(card.name): \(card.branch) @ \(card.head) · \(card.handoffBadgeText) · Dirty files: \(card.dirty). Click for read-only here.py orientation card.")
                }
            }
        }
        .padding(14)
        .openCoreGlassCard(cornerRadius: 12)
    }

    private var filteredFleetCards: [FleetRepoCard] {
        switch fleetFilter {
        case .all:
            return model.fleetCards
        case .attention:
            return model.fleetCards.filter { $0.isHandoffStale || $0.isDirty || $0.stateStatus == "missing" }
        case .current:
            return model.fleetCards.filter { $0.isHandoffCurrent }
        }
    }

    private var liveFleetSection: some View {
        let staleCount = model.fleetCards.filter(\.isHandoffStale).count
        let dirtyCount = model.fleetCards.filter(\.isDirty).count
        let currentCount = model.fleetCards.filter(\.isHandoffCurrent).count
        let attentionCount = model.fleetCards.filter { $0.isHandoffStale || $0.isDirty || $0.stateStatus == "missing" }.count

        return VStack(alignment: .leading, spacing: 10) {
            // Row 1: Single-line Header + Filter Picker + Refresh Button (Zero Wrapping)
            HStack(alignment: .center, spacing: 10) {
                Text("Live Repository Fleet & Cross-Agent Handoffs")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text("\(model.fleetCards.count) repos · \(currentCount) current · \(staleCount) git ahead · \(dirtyCount) dirty")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if model.isLoadingFleet {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 8)

                Picker("Filter", selection: $fleetFilter) {
                    Text("All (\(model.fleetCards.count))").tag(FleetFilter.all)
                    Text("Attention (\(attentionCount))").tag(FleetFilter.attention)
                    Text("Current (\(currentCount))").tag(FleetFilter.current)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                Button {
                    Task {
                        await model.refreshMachineHealth(checkTailnet: true)
                        await model.refreshFleetStatus()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .openCoreGlassButton()
                .disabled(model.isLoadingFleet)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: settings.fleetGridLayout.minCardWidth), spacing: 12)], spacing: 12) {
                ForEach(filteredFleetCards) { card in
                    FleetRepoCardView(
                        card: card,
                        truncateLongText: settings.truncateLongRepoText,
                        isCopiedResume: copiedResumeRepo == card.id,
                        onOpenDossier: { model.openEntity(named: card.name) },
                        onAskInChat: {
                            model.askInChat("Summarize the current objective, recent commits, Claude & Codex memories, and open blockers for \(card.name)")
                        },
                        onCopyResumeBrief: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(card.sessionResumePrompt, forType: .string)
                            copiedResumeRepo = card.id
                        },
                        onOpenTerminal: {
                            OperatorConsoleService.openInTerminal(rootPath: card.root)
                        },
                        onRevealFinder: {
                            OperatorConsoleService.revealInFinder(path: card.root)
                        },
                        onOpenStateDoc: {
                            OperatorConsoleService.openFile(path: card.statePath)
                        },
                        onSyncRepo: {
                            Task { await model.syncSingleRepository(card) }
                        },
                        onReadOnlyAudit: {
                            Task { await model.auditRepository(card) }
                        }
                    )
                }
            }
        }
    }

    private func runInlineSearchAndReason() {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        clearInlineResults()
        let requestID = UUID()
        inlineRequestID = requestID
        isSearchingInline = true
        inlineFMSentences = []
        inlineFMVerdicts = []
        inlineFMInsufficient = false
        inlineSearchTask = Task {
            await model.ask(query)
            guard !Task.isCancelled, inlineRequestID == requestID else { return }
            let rows: [AppModel.PassageRow]
            if let result = await model.searchPassages(query) {
                guard !Task.isCancelled, inlineRequestID == requestID else { return }
                rows = result.rows
                inlinePassages = rows
            } else {
                guard !Task.isCancelled, inlineRequestID == requestID else { return }
                rows = []
                inlinePassages = []
            }
            isSearchingInline = false

            guard !rows.isEmpty else { return }
            isSynthesizingInlineFM = true
            let sources: [GroundingSource] = rows.prefix(6).enumerated().map { idx, hit in
                GroundingSource(
                    index: idx + 1,
                    title: hit.title,
                    text: hit.text,
                    objectID: hit.objectID,
                    authority: Authority.allCases.first { $0.label == hit.authority } ?? .authoredArtifact,
                    uri: nil
                )
            }
            let grounding = Grounding()
            if let fm = await Conversation.generateWithFoundationModelsCLI(question: query, sources: sources) {
                guard !Task.isCancelled, inlineRequestID == requestID else { return }
                inlineFMInsufficient = fm.insufficient
                inlineFMSentences = fm.sentences
                inlineFMVerdicts = fm.sentences.map {
                    grounding.verify(sentence: $0.text, citedSource: $0.source, sources: sources)
                }
            } else {
                guard !Task.isCancelled, inlineRequestID == requestID else { return }
                let fallback = Conversation.deterministicSynthesis(from: sources)
                inlineFMSentences = fallback
                inlineFMVerdicts = fallback.map {
                    grounding.verify(sentence: $0.text, citedSource: $0.source, sources: sources)
                }
            }
            isSynthesizingInlineFM = false
        }
    }

    private func handOff() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        model.askInChat(question)
    }

    /// Compact single-line banner for optional unconfigured sources (never wraps 12 MCP server names across 3 lines).
    @ViewBuilder
    private func attention(_ snapshot: HomeSnapshot) -> some View {
        if !snapshot.neverSynced.isEmpty {
            let preview = snapshot.neverSynced.prefix(3).joined(separator: ", ")
            let extraCount = max(0, snapshot.neverSynced.count - 3)
            Button {
                model.navigate(to: .sources)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "powerplug")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(snapshot.neverSynced.count) optional connectors pending first sync")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("(\(preview)\(extraCount > 0 ? " + \(extraCount) more" : ""))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("Manage in Sources →")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .openCoreGlassCard(cornerRadius: 9)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Never synced: \(snapshot.neverSynced.joined(separator: ", "))")
        }
    }
}

// MARK: - Pieces

/// What changed, which is what this screen is for.
///
/// Three questions, in the order a person asks them: what have I been doing, what does OpenCore
/// now believe differently, and what does it know it does not know. An empty column says so
/// rather than disappearing, because "nothing changed" is an answer.
private struct WhatChangedCard: View {
    @Environment(\.appModel) private var model
    let snapshot: HomeSnapshot
    let previousVisit: Date?

    private var heading: String {
        guard let previousVisit else { return "What changed in the last \(snapshot.windowDays) days" }
        return "What changed since \(previousVisit.formatted(date: .abbreviated, time: .shortened))"
    }

    private var subheading: String {
        var parts: [String] = []
        if let events = snapshot.eventsSinceVisit { parts.append("\(events) event\(events == 1 ? "" : "s")") }
        if let beliefs = snapshot.beliefChangesSinceVisit { parts.append("\(beliefs) belief change\(beliefs == 1 ? "" : "s")") }
        if let synced = snapshot.lastSyncedAt {
            parts.append("newest sync \(synced.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never synced")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.headline)
                Text(subheading).font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { columns }
                VStack(alignment: .leading, spacing: 12) { columns }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 14, tint: Pastel.sky)
    }

    @ViewBuilder private var columns: some View {
        Column(title: "Recent activity", detail: "last \(snapshot.windowDays) days", symbol: "clock.arrow.circlepath", tint: Pastel.mint,
               emptyText: "Nothing recorded in this window.", isEmpty: snapshot.work.isEmpty && snapshot.other.isEmpty) {
            ForEach((snapshot.work + snapshot.other).prefix(6)) { row in
                Button { model.openEntity(named: row.subject) } label: {
                    HStack(spacing: 8) {
                        Text(row.subject).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(row.upkeep > 0 ? "\(row.events) \(row.verb) +\(row.upkeep) upkeep" : "\(row.events) \(row.verb)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Latest \(row.lastAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }

        Column(title: "Belief changes", detail: "\(snapshot.beliefChanges.count) in window", symbol: "arrow.triangle.branch", tint: Pastel.lavender,
               emptyText: "No beliefs changed in this window.", isEmpty: snapshot.beliefChanges.isEmpty) {
            ForEach(snapshot.beliefChanges.prefix(6)) { change in
                Button { model.navigate(to: .beliefs) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(change.subject) \(change.predicate.replacingOccurrences(of: "_", with: " "))")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(change.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }

        Column(title: "Open contradictions", detail: "\(snapshot.openContradictions)", symbol: "exclamationmark.bubble", tint: Pastel.peach,
               emptyText: "Nothing is contradicted right now.", isEmpty: snapshot.contradictionRows.isEmpty) {
            ForEach(snapshot.contradictionRows.prefix(6)) { row in
                Button { model.navigate(to: .contradictions) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(row.subject) \(row.predicate.replacingOccurrences(of: "_", with: " "))")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(row.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private struct Column<Content: View>: View {
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let emptyText: String
        let isEmpty: Bool
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(tint).font(.caption)
                    Text(title).font(.subheadline.weight(.bold))
                    Spacer(minLength: 4)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                if isEmpty {
                    Text(emptyText).font(.caption).foregroundStyle(.secondary)
                } else {
                    content
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompactCounterPill: View {
    let label: String
    let value: String
    let symbol: String
    let tint: Color
    let helpText: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .openCoreGlassCard(cornerRadius: 8, tint: hovering ? tint : nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
    }
}

private struct GuideJobCard: View {
    let number: String
    let title: String
    let engineBadge: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.16), in: .rect(cornerRadius: 6))
                Text("JOB \(number)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Spacer()
                Text(engineBadge)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: .capsule)
            }
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .openCoreGlassCard(cornerRadius: 10)
    }
}

private struct PipelineStageCard: View {
    let step: String
    let humanName: String
    let engineName: String
    let meaning: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(step.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.4)
                }
                Text(humanName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(engineName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.accentColor)
                Text(meaning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .openCoreGlassCard(cornerRadius: 10, tint: hovering ? .accentColor : nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct Note: View {
    let tint: Color
    let headline: String
    let detail: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .openCoreGlassCard(cornerRadius: 10, tint: tint)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct FleetRepoCardView: View {
    let card: FleetRepoCard
    var truncateLongText: Bool = false
    let isCopiedResume: Bool
    let onOpenDossier: () -> Void
    let onAskInChat: () -> Void
    let onCopyResumeBrief: () -> Void
    let onOpenTerminal: () -> Void
    let onRevealFinder: () -> Void
    let onOpenStateDoc: () -> Void
    let onSyncRepo: () -> Void
    let onReadOnlyAudit: () -> Void

    private var handoffColor: Color {
        switch card.stateStatus {
        case "current": .green
        case "stale": .orange
        case "missing": card.fallbackOverview != nil ? .blue : .secondary
        default: .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1 (Single Line): Repo Name + Handoff Badge + Working Tree Pill + Active Agent Badges
            HStack(spacing: 6) {
                Button(action: onOpenDossier) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        Text(card.name)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(card.name) Entity Dossier in OpenCore")

                Text(card.handoffBadgeText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(handoffColor)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(handoffColor.opacity(0.14), in: .capsule)
                    .help(card.handoffProvenanceHelp)

                if card.git {
                    Text(card.dirty == 0 ? "● clean" : "▲ \(card.dirty) dirty")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(card.dirty == 0 ? .green : .cyan)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((card.dirty == 0 ? Pastel.mint : Pastel.aqua).opacity(0.12), in: .capsule)
                        .help(card.dirtySample.isEmpty ? "Working tree is clean" : "Modified: \(card.dirtySample.joined(separator: ", "))")
                }

                Spacer(minLength: 4)

                // Active Cross-Agent Coverage Pills (Claude / Codex / AGY)
                HStack(spacing: 3) {
                    ForEach(card.activeAgents, id: \.self) { agent in
                        let agentColor: Color = agent == "Claude" ? .orange : (agent == "Codex" ? .cyan : .purple)
                        Text(agent)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(agentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(agentColor.opacity(0.12), in: .capsule)
                    }
                }
                .help("Unified instructions & memory coverage: \(card.hasClaudeMD ? "CLAUDE.md " : "")\(card.hasAgentsMD ? "AGENTS.md " : "")\(card.hasGeminiMD ? "GEMINI.md " : "")· \(card.memoryFiles) Claude mem · \(card.codexRolloutCount) Codex rollouts")
            }

            // Row 2: Git branch @ head + handoff source + memory/rollout/session counters
            HStack(spacing: 6) {
                if card.git, !card.head.isEmpty {
                    Text("\(card.branch) @ \(card.head)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(Pastel.sky)
                        .lineLimit(1)
                    if !card.headWhen.isEmpty {
                        Text("(\(card.headWhen))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if card.unpushed > 0 {
                        Text("· ↑\(card.unpushed)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Pastel.peach)
                            .lineLimit(1)
                    }
                }
                if !card.primaryObjectiveSource.isEmpty {
                    Text("· \(card.primaryObjectiveSource)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Pastel.ice)
                        .lineLimit(1)
                }
                if !card.lastStop.isEmpty {
                    Text("· \(card.lastStop)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if card.memoryFiles > 0 || card.codexRolloutCount > 0 || card.sessions > 0 {
                    Text("\(card.memoryFiles)c/\(card.codexRolloutCount)x mem · \(card.sessions) sess")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Pastel.ice)
                        .lineLimit(1)
                        .help("\(card.memoryFiles) Claude memory file(s) · \(card.codexRolloutCount) Codex rollout summary file(s) · \(card.sessions) recorded session(s)")
                }
            }

            if !card.desc.isEmpty {
                Text(card.desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(truncateLongText ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Structured Aligned Metadata Rows (GOAL / NEXT / STOP) — full text by default, or user-configurable
            VStack(alignment: .leading, spacing: 6) {
                if let obj = card.primaryObjective {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("GOAL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.mint)
                            .frame(width: 42, alignment: .leading)
                        Text(obj)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(truncateLongText ? 2 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let nxt = card.primaryNextAction {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("NEXT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.sky)
                            .frame(width: 42, alignment: .leading)
                        Text(nxt)
                            .font(.caption)
                            .foregroundStyle(Pastel.ice)
                            .lineLimit(truncateLongText ? 2 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !card.lastStopMsg.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("STOP")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Pastel.lavender)
                            .frame(width: 42, alignment: .leading)
                        Text(card.lastStopMsg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(truncateLongText ? 1 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            // Row 4 (Single Line): Non-destructive 1-click Operator Action Bar (fixedSize so buttons never truncate)
            HStack(spacing: 6) {
                Button(action: onCopyResumeBrief) {
                    Label(
                        isCopiedResume ? "Copied" : "Resume Brief",
                        systemImage: isCopiedResume ? "checkmark" : "doc.on.clipboard"
                    )
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.mini)
                .openCoreGlassButton(prominent: true, tint: Pastel.sky)
                .help("Copies a unified session orientation brief (branch, HEAD, dirty files, STATE.md status, objective, next step, last stop) to paste into Claude, Codex, or Antigravity")

                Button(action: onOpenTerminal) {
                    Label("Terminal", systemImage: "terminal")
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Open \(card.homeRel) in Terminal.app")

                Button(action: onRevealFinder) {
                    Label("Finder", systemImage: "folder")
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Reveal \(card.homeRel) in Finder")

                if card.stateExists {
                    Button(action: onOpenStateDoc) {
                        Label("STATE.md", systemImage: "doc.text")
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .controlSize(.mini)
                    .openCoreGlassButton()
                    .help("Open \(card.shortStateRel) in default viewer")
                }

                Button(action: onReadOnlyAudit) {
                    Label("Inspect", systemImage: "magnifyingglass.circle")
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Run read-only here.py orientation card + last 5 git commits")

                Spacer(minLength: 4)

                Button(action: onSyncRepo) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Sync \(card.name)'s docs and memories into OpenCore")

                Button(action: onAskInChat) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption2)
                }
                .controlSize(.mini)
                .openCoreGlassButton()
                .help("Ask Grounded Chat about \(card.name)")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: card.isDirty ? .cyan : (card.isHandoffStale ? .orange : nil))
    }
}

private struct ReadOnlyRepoAuditSheet: View {
    let repo: FleetRepoCard
    let output: String?
    let isLoading: Bool
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(repo.name) · Read-Only Orientation Card")
                        .font(.headline)
                    Text("\(repo.homeRel) · [here.py + git log -n 5]")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let output {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Output", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .openCoreGlassButton()
                }
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Running read-only here.py inspection…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(output ?? "No output.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .openCoreGlassCard(cornerRadius: 10)
            }
        }
        .padding(20)
        .frame(width: 720, height: 500)
    }
}

// MARK: - Dedicated Workspace ⌘3: Repo Fleet & Handoffs

struct RepoFleetWorkspaceView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings
    @State private var fleetFilter: HomeView.FleetFilter = .all
    @State private var searchQuery = ""
    @State private var copiedResumeRepo: String?

    private var filteredCards: [FleetRepoCard] {
        let base: [FleetRepoCard]
        switch fleetFilter {
        case .all:
            base = model.fleetCards
        case .attention:
            base = model.fleetCards.filter { $0.isHandoffStale || $0.isDirty || $0.stateStatus == "missing" }
        case .current:
            base = model.fleetCards.filter { $0.isHandoffCurrent }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.desc.localizedCaseInsensitiveContains(q) ||
            $0.branch.localizedCaseInsensitiveContains(q) ||
            $0.objective.joined(separator: " ").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        let total = max(model.fleetCards.count, 1)
        let syncedClean = model.fleetCards.filter { $0.isHandoffCurrent && !$0.isDirty }
        let dirtyRepos = model.fleetCards.filter { $0.isDirty }
        let staleClean = model.fleetCards.filter { $0.isHandoffStale && !$0.isDirty }
        let attentionCount = model.fleetCards.filter { $0.isHandoffStale || $0.isDirty || $0.stateStatus == "missing" }.count

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header & Controls Bar
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Pastel.mint)
                        .frame(width: 42, height: 42)
                        .background(Pastel.mint.opacity(0.15), in: .rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Repository Fleet & Cross-Agent Handoffs")
                                .font(.title3.weight(.bold))
                            Text("\(model.fleetCards.count) Repositories")
                                .openCorePastelBadge(Pastel.mint)
                            Text("fleet.py + here.py")
                                .openCorePastelBadge(Pastel.sky)
                        }
                        Text("Every repository's live git branch, uncommitted file count, STATE.md / HANDOFF.md currency, and 1-click resume brief.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task {
                            await model.refreshMachineHealth(checkTailnet: true)
                            await model.refreshFleetStatus()
                        }
                    } label: {
                        Label(model.isLoadingFleet ? "Scanning…" : "Refresh Fleet", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.mint)
                    .disabled(model.isLoadingFleet)
                }
                .padding(14)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)

                // Visual Fleet Health Matrix Bar + Repo Chips
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Label("Fleet Health Matrix", systemImage: "chart.bar.xaxis")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle().fill(Pastel.mint).frame(width: 7, height: 7)
                                Text("\(syncedClean.count) Current & Clean").font(.caption2.monospaced())
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Pastel.aqua).frame(width: 7, height: 7)
                                Text("\(dirtyRepos.count) Uncommitted Dirty").font(.caption2.monospaced())
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Pastel.peach).frame(width: 7, height: 7)
                                Text("\(staleClean.count) Git Ahead of STATE.md").font(.caption2.monospaced())
                            }
                        }
                    }

                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            if !syncedClean.isEmpty {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Pastel.mint.gradient)
                                    .frame(width: max(geo.size.width * CGFloat(syncedClean.count) / CGFloat(total) - 2, 16))
                            }
                            if !dirtyRepos.isEmpty {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Pastel.aqua.gradient)
                                    .frame(width: max(geo.size.width * CGFloat(dirtyRepos.count) / CGFloat(total) - 2, 16))
                            }
                            if !staleClean.isEmpty {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Pastel.peach.gradient)
                                    .frame(width: max(geo.size.width * CGFloat(staleClean.count) / CGFloat(total) - 2, 16))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 12)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(model.fleetCards) { card in
                            let pillColor: Color = card.isDirty ? Pastel.aqua : (card.isHandoffCurrent ? Pastel.mint : (card.isHandoffStale ? Pastel.peach : Pastel.ice))
                            Button {
                                Task { await model.auditRepository(card) }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(pillColor).frame(width: 6, height: 6)
                                    Text(card.name)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    if card.dirty > 0 {
                                        Text("(\(card.dirty)Δ)")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Pastel.aqua)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(pillColor.opacity(0.14), in: .capsule)
                                .overlay {
                                    Capsule().strokeBorder(pillColor.opacity(0.32), lineWidth: 0.75)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
                .openCoreGlassCard(cornerRadius: 12)

                // Search & Filter Bar
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search repositories by name, branch, or objective…", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.callout)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .openCoreGlassCard(cornerRadius: 9)

                    Picker("Filter", selection: $fleetFilter) {
                        Text("All (\(model.fleetCards.count))").tag(HomeView.FleetFilter.all)
                        Text("Attention (\(attentionCount))").tag(HomeView.FleetFilter.attention)
                        Text("Current (\(syncedClean.count))").tag(HomeView.FleetFilter.current)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 290)

                    Picker("Columns", selection: Bindable(settings).fleetGridLayout) {
                        ForEach(AppSettings.FleetGridLayout.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    .frame(width: 195)
                }

                // Repository Cards Grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: settings.fleetGridLayout.minCardWidth), spacing: 12)], spacing: 12) {
                    ForEach(filteredCards) { card in
                        FleetRepoCardView(
                            card: card,
                            truncateLongText: settings.truncateLongRepoText,
                            isCopiedResume: copiedResumeRepo == card.id,
                            onOpenDossier: { model.openEntity(named: card.name) },
                            onAskInChat: {
                                model.askInChat("Summarize the current objective, recent commits, Claude & Codex memories, and open blockers for \(card.name)")
                            },
                            onCopyResumeBrief: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(card.sessionResumePrompt, forType: .string)
                                copiedResumeRepo = card.id
                            },
                            onOpenTerminal: {
                                OperatorConsoleService.openInTerminal(rootPath: card.root)
                            },
                            onRevealFinder: {
                                OperatorConsoleService.revealInFinder(path: card.root)
                            },
                            onOpenStateDoc: {
                                OperatorConsoleService.openFile(path: card.statePath)
                            },
                            onSyncRepo: {
                                Task { await model.syncSingleRepository(card) }
                            },
                            onReadOnlyAudit: {
                                Task { await model.auditRepository(card) }
                            }
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: settings.commandCenterMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Repo Fleet & Handoffs")
        .sheet(item: Bindable(model).activeAuditRepo) { repo in
            ReadOnlyRepoAuditSheet(
                repo: repo,
                output: model.activeAuditOutput,
                isLoading: model.isRunningRepoAudit
            ) {
                model.activeAuditRepo = nil
            }
        }
        .task {
            if model.fleetCards.isEmpty {
                await model.refreshFleetStatus()
            }
        }
    }
}

// MARK: - Dedicated Workspace ⌘4: Coding Agents Hub (Claude Code · Codex · Antigravity)

struct CodingAgentsWorkspaceView: View {
    @Environment(\.appModel) private var model
    @Environment(\.appSettings) private var settings

    var body: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let eco = model.agentEcosystem

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Pastel.lavender)
                        .frame(width: 42, height: 42)
                        .background(Pastel.lavender.opacity(0.15), in: .rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Coding Agents Unification Hub")
                                .font(.title3.weight(.bold))
                            Text("Claude Code · Codex · Antigravity (agy)")
                                .openCorePastelBadge(Pastel.lavender)
                            Text("Source files preserved · local index updated")
                                .openCorePastelBadge(Pastel.mint)
                        }
                        Text("Inspect shared skills (~/.agents/skills), Codex procedural skills, MEMORY.md handbook, rollout summaries, and kit-bridge parity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await model.syncCrossAgentMemories() }
                    } label: {
                        Label("Sync Agent Memories into OpenCore", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(prominent: true, tint: Pastel.lavender)
                }
                .padding(14)
                .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)

                // Quick-Open Anchor Files Bar
                HStack(spacing: 10) {
                    Button {
                        OperatorConsoleService.openFile(path: "\(home)/.codex/memories/MEMORY.md")
                    } label: {
                        Label("Open Codex MEMORY.md (\(eco?.codexMemoryTaskSections.description ?? "not loaded") Tasks)", systemImage: "book.closed.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(tint: Pastel.aqua)

                    Button {
                        OperatorConsoleService.openFile(path: "\(home)/.agents/briefs/codex-antigravity-parity.md")
                    } label: {
                        Label("Open Codex ↔ Antigravity Parity Brief", systemImage: "doc.badge.gearshape")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(tint: Pastel.lavender)

                    Button {
                        OperatorConsoleService.openFile(path: "\(home)/.agents/MACHINE-MAP.md")
                    } label: {
                        Label("Open MACHINE-MAP.md (\(eco?.machineMapSizeKB.description ?? "not loaded") KB)", systemImage: "map.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(tint: Pastel.mint)

                    Button {
                        OperatorConsoleService.openFile(path: "\(home)/.claude/CLAUDE.md")
                    } label: {
                        Label("Open ~/.claude/CLAUDE.md", systemImage: "doc.text.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(tint: Pastel.peach)

                    Button {
                        OperatorConsoleService.openFile(path: "\(home)/.gemini/config/rules/gunnar.md")
                    } label: {
                        Label("Open Antigravity gunnar.md", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .openCoreGlassButton(tint: Pastel.periwinkle)

                    Spacer()
                }

                if let eco {
                    // 3-Column Agent Comparison Deck
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        // 1. Claude Code
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle().fill(Pastel.peach).frame(width: 8, height: 8)
                                Text("CLAUDE CODE (~/.claude)")
                                    .font(.caption.weight(.bold).monospaced())
                                    .foregroundStyle(Pastel.peach)
                                Spacer()
                                Text("\(eco.claudeHooksCount) hook files")
                                    .openCorePastelBadge(Pastel.mint)
                            }
                            Text("\(eco.claudeSkills.count) Skills · \(eco.claudeMemoryFileCount) Project Memory Files")
                                .font(.subheadline.weight(.bold))
                            Text("Spans \(eco.claudeMemoryProjectCount) project slugs in ~/.claude/projects/*/memory plus fleet.py & here.py.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            Button {
                                OperatorConsoleService.revealInFinder(path: "\(home)/.claude")
                            } label: {
                                Label("Reveal ~/.claude in Finder", systemImage: "folder")
                                    .font(.caption2)
                            }
                            .controlSize(.mini)
                            .openCoreGlassButton()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.peach)

                        // 2. Codex
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle().fill(Pastel.aqua).frame(width: 8, height: 8)
                                Text("CODEX (~/.codex + ~/.agents)")
                                    .font(.caption.weight(.bold).monospaced())
                                    .foregroundStyle(Pastel.aqua)
                                Spacer()
                                Text(eco.codexMemoryStateCommit.isEmpty ? "Active" : "@\(eco.codexMemoryStateCommit)")
                                    .openCorePastelBadge(Pastel.aqua)
                            }
                            Text("\(eco.codexMemoryTaskSections) Handbook Sections · \(eco.codexRolloutSummaryCount) Rollouts")
                                .font(.subheadline.weight(.bold))
                            Text("\(eco.sharedAgentsSkills.count) shared skills + \(eco.codexProceduralSkills.count) procedural skills · \(eco.codexHooksCount) hook files (execution unverified).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            Button {
                                OperatorConsoleService.revealInFinder(path: "\(home)/.codex/memories")
                            } label: {
                                Label("Reveal ~/.codex/memories in Finder", systemImage: "folder")
                                    .font(.caption2)
                            }
                            .controlSize(.mini)
                            .openCoreGlassButton()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.aqua)

                        // 3. Antigravity
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle().fill(Pastel.lavender).frame(width: 8, height: 8)
                                Text("ANTIGRAVITY (agy · ~/.gemini)")
                                    .font(.caption.weight(.bold).monospaced())
                                    .foregroundStyle(Pastel.lavender)
                                Spacer()
                                Text(eco.agyKitBridgeExists ? "kit-bridge ON" : "bridge off")
                                    .openCorePastelBadge(eco.agyKitBridgeExists ? Pastel.mint : Pastel.butter)
                            }
                            Text("\(eco.skillsInSyncCount)/\(eco.sharedAgentsSkills.count) Same-Source Skill Folders + \(eco.agySkillsCount) AGY Skills")
                                .font(.subheadline.weight(.bold))
                            Text("Reads and updates the exact same STATE.md, CLAUDE.md, and AGENTS.md handoffs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            Button {
                                OperatorConsoleService.revealInFinder(path: "\(home)/.gemini/config")
                            } label: {
                                Label("Reveal ~/.gemini/config in Finder", systemImage: "folder")
                                    .font(.caption2)
                            }
                            .controlSize(.mini)
                            .openCoreGlassButton()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.lavender)
                    }

                    // Shared Skills Directory (~/.agents/skills)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Shared Cross-Agent Skills (~/.agents/skills · \(eco.sharedAgentsSkills.count))", systemImage: "wrench.and.screwdriver.fill")
                                .font(.headline)
                            Spacer()
                            Button {
                                OperatorConsoleService.revealInFinder(path: "\(home)/.agents/skills")
                            } label: {
                                Label("Open ~/.agents/skills Folder", systemImage: "folder")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .openCoreGlassButton()
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                            ForEach(eco.sharedAgentsSkills, id: \.self) { skill in
                                let inClaude = eco.claudeSkills.contains(skill)
                                Button {
                                    OperatorConsoleService.openFile(path: "\(home)/.agents/skills/\(skill)/SKILL.md")
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "Sparkles")
                                            .font(.caption)
                                            .foregroundStyle(Pastel.mint)
                                        Text(skill)
                                            .font(.caption.weight(.bold).monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(inClaude ? "Claude+Codex+AGY" : "Codex+AGY")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(inClaude ? Pastel.mint : Pastel.aqua)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background((inClaude ? Pastel.mint : Pastel.aqua).opacity(0.14), in: .capsule)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .openCoreGlassCard(cornerRadius: 9)
                                }
                                .buttonStyle(.plain)
                                .help("Click to open ~/.agents/skills/\(skill)/SKILL.md")
                            }
                        }
                    }
                    .padding(14)
                    .openCoreGlassCard(cornerRadius: 12)

                    // Codex Procedural Skills (~/.codex/memories/skills)
                    if !eco.codexProceduralSkills.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Codex Procedural Memory Skills (~/.codex/memories/skills · \(eco.codexProceduralSkills.count))", systemImage: "brain.head.profile")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    OperatorConsoleService.revealInFinder(path: "\(home)/.codex/memories/skills")
                                } label: {
                                    Label("Open Procedural Skills Folder", systemImage: "folder")
                                        .font(.caption)
                                }
                                .controlSize(.small)
                                .openCoreGlassButton()
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                                ForEach(eco.codexProceduralSkills, id: \.self) { skill in
                                    Button {
                                        OperatorConsoleService.openFile(path: "\(home)/.codex/memories/skills/\(skill)/SKILL.md")
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "bolt.horizontal.circle.fill")
                                                .foregroundStyle(Pastel.aqua)
                                            Text(skill)
                                                .font(.caption.weight(.bold).monospaced())
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text("Open SKILL.md →")
                                                .font(.caption2)
                                                .foregroundStyle(Pastel.aqua)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .openCoreGlassCard(cornerRadius: 9, tint: Pastel.aqua)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(14)
                        .openCoreGlassCard(cornerRadius: 12)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: settings.commandCenterMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Coding Agents Hub")
        .task {
            if model.machineHealth == nil {
                await model.refreshMachineHealth()
            }
        }
    }
}

// MARK: - Hand-off

@MainActor
final class PendingQuestion {
    static let shared = PendingQuestion()
    var text: String?

    func take() -> String? {
        defer { text = nil }
        return text
    }
}

@MainActor
final class PendingEntity {
    static let shared = PendingEntity()
    var name: String?

    func take() -> String? {
        defer { name = nil }
        return name
    }
}
