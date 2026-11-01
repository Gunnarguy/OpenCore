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
| [codemap/INDEX.md](codemap/INDEX.md) | You have a feature to change and need its files. `python3 script/codemap.py find <words>` searches it. Read this before grepping. |
| [../private-names.example.json](../private-names.example.json) | You need the shape of the private names file. The real one lives beside the store and in the gitignored `Local/`. |

There is deliberately no `Docs/ai/ARCHITECTURE.md`. `Docs/ARCHITECTURE.md` already exists and is
good; duplicating it would create two documents that drift apart, which is the exact failure
this project exists to make visible.

Skills: `verify-release` to prove a change or get ready to install, `store-copy` to measure on real
data, `safe-rebuild` for any rebuild, `publish-check` before a commit or push, `project-handoff` to
update `STATE.md`.

Rules load by path: `.claude/rules/app.md` for the app, `operator.md` for the operator console.

Last context-system audit: 2026-10-31. It covered these documents, not the Runbook's dated operator
sections, which record what was true on their dates.
