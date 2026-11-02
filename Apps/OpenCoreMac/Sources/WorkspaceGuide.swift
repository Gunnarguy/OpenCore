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

/// The app is three places. Ask is why it exists, Mac is the console beside it, and Evidence is how
/// an answer proves itself, so it stays folded until someone wants to look.
enum WorkspaceFamily: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case mac = "Mac"
    case evidence = "Evidence"
    case setup = "Settings"

    var id: String { rawValue }

    var sections: [Section] {
        switch self {
        case .ask: [.ask]
        case .mac: [.macOverview, .repoFleet, .codingAgents, .computerControl, .aiModelsRAM, .hardwareUSB]
        case .evidence: [.sources, .corpus, .passages, .claims, .beliefs, .receipts, .entities, .timeline, .timeTravel, .contradictions, .maintenance]
        case .setup: [.settings]
        }
    }

    var tint: Color {
        switch self {
        case .ask: Pastel.ice
        case .mac: Pastel.lavender
        case .evidence: Pastel.mint
        case .setup: Pastel.butter
        }
    }

    var purpose: String {
        switch self {
        case .ask: "Ask about your life and work, and see how it knows."
        case .mac: "Your projects, agents, models and hardware."
        case .evidence: "Trace any answer back to the records it came from."
        case .setup: "Preferences, connections and the iPhone companion."
        }
    }
}

extension Section {
    var family: WorkspaceFamily {
        // A single exhaustive membership map keeps new sections from disappearing from the map.
        switch self {
        case .ask: .ask
        case .macOverview, .repoFleet, .codingAgents, .computerControl, .aiModelsRAM, .hardwareUSB: .mac
        case .sources, .corpus, .passages, .claims, .beliefs, .receipts, .entities, .timeline, .timeTravel, .contradictions, .maintenance: .evidence
        case .settings: .setup
        }
    }

    /// Keep technical screen names available; pair each with a recognizable job.
    var guide: WorkspaceGuide {
        switch self {
        case .ask:
            .init(shortName: "Ask", role: "Ask about your life and work",
                  purpose: "Ask a question, then follow its citations back to the evidence.",
                  useWhen: "You want an answer from your records. Why? shows what an answer used and what was withheld.",
                  next: .receipts, nextAction: "Inspect answer receipts")
        case .macOverview:
            .init(shortName: "Overview", role: "Your Mac at a glance",
                  purpose: "See disk, memory, hardware and projects that need attention.",
                  useWhen: "You want to know what needs attention on this Mac before opening a specific screen.",
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
                  next: .ask, nextAction: "Ask with evidence")
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
            .init(shortName: "Computer Use", role: "Supported tasks & previews",
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
        case .settings:
            .init(shortName: "Settings", role: "Preferences & service configuration",
                  purpose: "Choose how the app looks, retrieves information and connects to supported local services.",
                  useWhen: "You want to change a preference or check service settings. Data browsing and store repair live in their own workspaces.",
                  next: .maintenance, nextAction: "Check store health")
        }
    }

    static let evidenceSections = WorkspaceFamily.evidence.sections
}
