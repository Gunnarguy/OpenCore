import SwiftUI

/// One vocabulary for the sidebar, orientation strip, workspace map and command palette.
/// These describe purposes, never runtime availability or proof that a connection works.
struct WorkspaceGuide {
    let shortName: String
    let role: String
    let purpose: String
    let useWhen: String
    let next: Section
    let nextAction: String
}

enum WorkspaceFamily: String, CaseIterable, Identifiable {
    case overview = "Start here"
    case projects = "Continue your work"
    case knowledge = "Follow the evidence"
    case tools = "Use your Mac"
    case review = "Check what changed"
    case connections = "Control access & setup"

    var id: String { rawValue }

    var sections: [Section] {
        switch self {
        case .overview: [.home]
        case .projects: [.repoFleet, .codingAgents]
        case .knowledge: [.sources, .corpus, .passages, .claims, .beliefs, .chat, .receipts]
        case .tools: [.computerControl, .aiModelsRAM, .hardwareUSB]
        case .review: [.entities, .timeline, .timeTravel, .contradictions, .maintenance]
        case .connections: [.mcp, .settings]
        }
    }

    var tint: Color {
        switch self {
        case .overview: Pastel.ice
        case .projects: Pastel.sky
        case .knowledge: Pastel.mint
        case .tools: Pastel.lavender
        case .review: Pastel.peach
        case .connections: Pastel.butter
        }
    }

    var purpose: String {
        switch self {
        case .overview: "Choose a question, a project or a task."
        case .projects: "Find the current handoff and the shared context an agent can use."
        case .knowledge: "Trace original records into excerpts, statements, decisions and answers."
        case .tools: "Choose a supported task, its runtime and the hardware it depends on."
        case .review: "Inspect a topic, compare history, resolve conflicts or diagnose missing data."
        case .connections: "Choose which services are connected and how OpenCore behaves."
        }
    }
}

extension Section {
    var family: WorkspaceFamily {
        // A single exhaustive membership map keeps new sections from disappearing from the map.
        switch self {
        case .home: .overview
        case .repoFleet, .codingAgents: .projects
        case .sources, .corpus, .passages, .claims, .beliefs, .chat, .receipts: .knowledge
        case .computerControl, .aiModelsRAM, .hardwareUSB: .tools
        case .entities, .timeline, .timeTravel, .contradictions, .maintenance: .review
        case .mcp, .settings: .connections
        }
    }

    /// Keep technical screen names available; pair each with a recognizable job.
    var guide: WorkspaceGuide {
        switch self {
        case .home:
            .init(shortName: "Overview", role: "Choose your next move",
                  purpose: "Start with a question, a project to resume or a task on your Mac.",
                  useWhen: "You want to know what needs attention before opening a specific workspace.",
                  next: .repoFleet, nextAction: "Choose a project")
        case .repoFleet:
            .init(shortName: "Projects", role: "Handoffs & working state",
                  purpose: "See where each project stands and pick up from its recorded next step.",
                  useWhen: "You are switching projects or agents and need the branch, handoff and recent context.",
                  next: .codingAgents, nextAction: "Check agent context")
        case .codingAgents:
            .init(shortName: "Agents", role: "Shared working context",
                  purpose: "See which skills, instructions and history your coding agents can discover.",
                  useWhen: "A handoff feels incomplete or you need to check what another agent can actually access.",
                  next: .repoFleet, nextAction: "Return to projects")
        case .sources:
            .init(shortName: "Sources", role: "Where records come from",
                  purpose: "Choose what OpenCore reads and sync it into your local library.",
                  useWhen: "A file, repository or note is missing. Sync brings records in; a source entry alone does not prove a successful sync.",
                  next: .corpus, nextAction: "See imported originals")
        case .corpus:
            .init(shortName: "Originals", role: "Original records · Corpus",
                  purpose: "Find the actual imported record before inspecting what was derived from it.",
                  useWhen: "You want to confirm an item arrived, inspect its text or see its privacy domain and source.",
                  next: .passages, nextAction: "Search source excerpts")
        case .passages:
            .init(shortName: "Excerpts", role: "Searchable text · Passages",
                  purpose: "Find the source excerpts that match a question, then inspect the original.",
                  useWhen: "An answer seems incomplete or you want to read the source words yourself. An excerpt can be searchable without producing a structured claim.",
                  next: .chat, nextAction: "Ask with evidence")
        case .claims:
            .init(shortName: "Statements", role: "Extracted statements · Claims",
                  purpose: "Check what OpenCore extracted, inspect its evidence or correct a statement.",
                  useWhen: "OpenCore says something unexpected about a project or person. Inspect evidence before deciding whether to correct it.",
                  next: .beliefs, nextAction: "See recorded decisions")
        case .beliefs:
            .init(shortName: "Decisions", role: "Decisions & revisions · Beliefs",
                  purpose: "See which statement was selected, why it was selected and how that decision changed.",
                  useWhen: "Two statements disagree or you want to understand a revision. This is a decision history, not a list of guaranteed truths.",
                  next: .claims, nextAction: "Compare extracted statements")
        case .chat:
            .init(shortName: "Answers", role: "Questions grounded in your records",
                  purpose: "Ask a question, then follow its citations back to the evidence.",
                  useWhen: "You want a useful answer across your records. Citations explain the content; receipts explain the recorded retrieval and answer path.",
                  next: .receipts, nextAction: "Inspect answer receipts")
        case .receipts:
            .init(shortName: "Receipts", role: "Recorded answer audit",
                  purpose: "Check what an answer used, what was withheld and what the recorded path measured.",
                  useWhen: "You want to verify an answer's evidence or privacy boundaries. A receipt records a run; it is not a guarantee that the answer is correct.",
                  next: .passages, nextAction: "Search the underlying evidence")
        case .entities:
            .init(shortName: "Topics", role: "Projects, people & technologies",
                  purpose: "Bring the statements, source records and history about one topic together.",
                  useWhen: "You know the project or person you care about and want a dossier instead of searching the entire library.",
                  next: .claims, nextAction: "Browse extracted statements")
        case .timeline:
            .init(shortName: "Events", role: "When things happened",
                  purpose: "Browse dated source events and open their related topics.",
                  useWhen: "You are reconstructing activity during a period. Use Time travel to compare what OpenCore recorded or considered applicable at a date.",
                  next: .timeTravel, nextAction: "Compare past knowledge")
        case .timeTravel:
            .init(shortName: "Time travel", role: "Compare then & now",
                  purpose: "Compare recorded knowledge at a date with statements applicable at that date.",
                  useWhen: "You need to distinguish when something happened from when OpenCore learned about it. Choose the clock before reading a difference.",
                  next: .timeline, nextAction: "Browse dated events")
        case .contradictions:
            .init(shortName: "Checks", role: "Conflicts & stale context",
                  purpose: "Find competing statements and mismatches between recorded context and current state.",
                  useWhen: "A handoff is stale, a working tree changed or two claims conflict. Inspect the mismatch before resolving a claim or updating a handoff.",
                  next: .beliefs, nextAction: "Review recorded decisions")
        case .maintenance:
            .init(shortName: "Health", role: "Store & index health",
                  purpose: "Diagnose missing records or index coverage before choosing a repair.",
                  useWhen: "Search or derived knowledge looks wrong. Check counts and source syncs first. Rebuild is a guarded repair, not a routine refresh.",
                  next: .sources, nextAction: "Check source syncs")
        case .computerControl:
            .init(shortName: "Tasks", role: "Supported tasks & previews",
                  purpose: "Choose a supported Local Hub task or routine and inspect its verification result.",
                  useWhen: "You want to do something on your Mac. Check the scope, selected mode and runtime first. Desktop recording and live coordinate replay remain unavailable.",
                  next: .aiModelsRAM, nextAction: "Check model readiness")
        case .aiModelsRAM:
            .init(shortName: "Models", role: "Runtime readiness & memory",
                  purpose: "See which runtimes support actions, load one and check its diagnostic result.",
                  useWhen: "A task needs a model or a loaded runtime is using memory. Catalog presence is not runtime support, and a diagnostic is not a general accuracy score.",
                  next: .computerControl, nextAction: "Choose a supported task")
        case .hardwareUSB:
            .init(shortName: "Hardware", role: "Displays, devices & storage",
                  purpose: "Inspect connected monitors, their current display modes, devices and storage your Mac can see.",
                  useWhen: "A monitor or peripheral is missing, a link seems slow or you need to inspect a mounted volume before taking an available action. Displays has screen modes; Devices has USB connections.",
                  next: .computerControl, nextAction: "Open task controls")
        case .mcp:
            .init(shortName: "Connections", role: "Service & agent connections",
                  purpose: "Configure service connections and the tools OpenCore is allowed to call.",
                  useWhen: "You need a new service, a connection check or an allowlist change. Physical monitors and cables are under Hardware → Displays. Configuration, live connection and successful tool execution are different states.",
                  next: .sources, nextAction: "Review imported sources")
        case .settings:
            .init(shortName: "Settings", role: "Preferences & service configuration",
                  purpose: "Choose how the app looks, retrieves information and connects to supported local services.",
                  useWhen: "You want to change a preference or check service settings. Data browsing and store repair live in their own workspaces.",
                  next: .maintenance, nextAction: "Check store health")
        }
    }

    static let evidenceSections: [Section] = [.sources, .corpus, .passages, .claims, .beliefs, .receipts, .contradictions, .timeTravel, .maintenance]
}
