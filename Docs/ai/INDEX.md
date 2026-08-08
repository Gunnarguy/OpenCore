# Docs/ai — navigation

OpenCore is an evidence-native runtime for personal intelligence: it stores what it knows,
where each belief came from, how confident it is, and what changed its mind.

**Read `STATE.md` first for any substantive work. Load the rest only when the task needs it.**

| Document | Consult when |
|---|---|
| [STATE.md](STATE.md) | Always, before substantive work. Current objective, verified state, exact next action. |
| [PROJECT.md](PROJECT.md) | You need scope, constraints, or what this project deliberately is not. |
| [../ARCHITECTURE.md](../ARCHITECTURE.md) | You are changing `CoreGraph`, `CoreStore`, or retrieval. The canonical architecture doc, with every claim labelled by how it was verified. |
| [DECISIONS.md](DECISIONS.md) | You are about to change something that looks arbitrary. It probably is not. |
| [RUNBOOK.md](RUNBOOK.md) | You need to build, test, run, or recover. Commands here are verified. |
| [../CONNECTORS.md](../CONNECTORS.md) | You are adding or debugging a data source. |
| [../MCP.md](../MCP.md) | You are touching `CoreMCP` or wiring an MCP client. |
| [../ROADMAP.md](../ROADMAP.md) | Summary only. **Roadmap truth is the Notion database**, id in that file. |

There is deliberately no `Docs/ai/ARCHITECTURE.md`. `Docs/ARCHITECTURE.md` already exists and is
good; duplicating it would create two documents that drift apart, which is the exact failure
this project exists to make visible.

Last context-system audit: 2026-08-08.
