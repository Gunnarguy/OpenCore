# OpenCore — Repository Operating Protocol

An evidence-native store for personal history. Swift 6, SwiftPM engine plus an XcodeGen'd
macOS app. Zero external dependencies, deliberately.

## Orientation

- **Read `Docs/ai/STATE.md` at the start of substantive work.** It carries the current
  objective, last verified state, and the exact next action. It is written to stand without
  any prior transcript.
- Load the rest **only when the task needs it**. `Docs/ai/INDEX.md` says which document
  answers which question. Do not load all project documentation by default.
- Repository source, tests, and configuration outrank every document here. When a doc and the
  code disagree, the code is right and the doc is a bug to fix.
- `Docs/ARCHITECTURE.md` before changing `CoreGraph`, `CoreStore`, or retrieval.
- **Roadmap truth is the Notion database**, not `Docs/ROADMAP.md`. Ids are in that file.

## Before your first action

1. **This repo lives in iCloud-synced `~/Documents`.** Two failure modes look like code bugs:
   - `.git` is a file pointing at `.git.nosync`. That is on purpose, to keep the object store
     out of iCloud after it corrupted a sibling repo's index. Do not "fix" it.
   - Always build with `--scratch-path` / `-derivedDataPath` **outside `~/Documents`**. iCloud
     stamps extended attributes on build inputs and `codesign` rejects them.
     Use `/private/tmp/opencore-build`.
   - Nonsensical duplicate-symbol errors usually mean iCloud wrote `Foo 2.swift`. Look for it
     before debugging the code.

2. **Xcode is at `/Applications/Xcode-beta.app`.** Prefix builds with
   `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Non-negotiables

These are the project's whole thesis. A change that breaks one is wrong even if it compiles.

- **Objects are the floor.** Nothing derived may be the only copy of anything. If a change
  makes `opencore rebuild` unable to reconstruct a layer, the change is wrong.
- **Never delete to record a change of mind.** Retraction and supersession are columns.
- **Authority never multiplies.** It is an ordinal tier. If you find yourself writing
  `confidence * authority`, stop — that is the exact mistake the type prevents.
- **Unmeasured stays `nil`.** Never write a plausible default into a receipt field. "not
  measured" is the correct rendering and it is load-bearing.
- **Only functional predicates contradict.** Widening that set manufactures conflicts out of
  ordinary multi-valued data.
- **Every SQL string lives in `CoreStore`.** If a layer above it needs data, add a typed method
  there rather than reaching into the database.
- **Connectors produce objects and nothing else.** No claims, no entities, no interpretation.
- **Counter-evidence is a row**, never an absence.
- **Nothing but MCP messages may reach stdout** anywhere in the `opencore mcp` call path.
  Every log line goes to stderr. A stray `print` corrupts the JSON-RPC stream, and the
  symptom is a client that hangs rather than an error you can find.
- **An MCP caller is not the user.** Sensitive domains stay unreachable through the server
  regardless of query wording, because the query text is written by a model and a model
  asking about a diagnosis is not consent. Only `--unsafe-expose-sensitive` lifts it.
- **A chosen constant says it is chosen.** RRF k, MMR λ, chunk size, the language-share
  floor: every one carries a comment saying it was picked rather than measured. Removing
  that comment is a bigger change than changing the number.
- **Ingest goes through `IngestPipeline`.** Adding a derivation stage anywhere else means
  the CLI, the app, or `rebuild` silently stops performing it.

## Context governance

Route information to one home. Do not duplicate a fact across layers without a reason.

| Information | Goes to |
|---|---|
| Repository-wide invariant | this file |
| Path-specific requirement | `.claude/rules/` |
| Repeatable procedure | `.claude/skills/` |
| Current objective, verified state, next action | `Docs/ai/STATE.md` |
| Stable scope and constraints | `Docs/ai/PROJECT.md` |
| Rationale that code cannot show | `Docs/ai/DECISIONS.md` |
| Verified operational command | `Docs/ai/RUNBOOK.md` |
| System structure | `Docs/ARCHITECTURE.md` |
| Recurring learned quirk | auto memory |
| Broad exploration whose intermediate output is not needed | isolated subagent |
| Ephemeral reasoning | this conversation only |

Remove stale or contradictory context when you find it rather than adding a correction beside
it. `Docs/ai/DECISIONS.md` is append-only; everything else is maintained in place.

## Documentation discipline

- Every claim in `Docs/` carries `[measured]`, `[test]`, `[source]` or `[design]`. Do not
  upgrade a label without actually doing the thing.
- The README's "What is not true yet" section is not a disclaimer to trim. It is the point.
  Add to it when you find a new limitation.
- Never quote an accuracy number. None has been measured. When one exists it will come from
  the eval harness (Notion, v0.3) and will carry its corpus and date.
- A bug found and fixed gets a regression test that names the original failure in a comment.
  See the OpenClinic domain-classification test for the pattern.
- `RUNBOOK.md` marks commands verified or unverified. Do not promote one without running it.

## Commands

The two needed every session. Everything else, including app builds and recovery procedures,
is in `Docs/ai/RUNBOOK.md` with its verification status.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --scratch-path /private/tmp/opencore-build
```

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /private/tmp/opencore-build
```

The built CLI lands at `/private/tmp/opencore-build/out/Products/Debug/opencore`, not
`.build/debug/`, when using `--scratch-path`.

## Verification and handoff

- Verify material changes with the actual build and test commands before claiming completion.
  Never report a command passed unless you ran it and read the output.
- Before ending substantial unfinished work, and after any change of objective, update
  `Docs/ai/STATE.md` so a fresh session can continue **without this transcript**. The
  `project-handoff` skill does this.
- Prefer an isolated Explore subagent for broad repository research whose intermediate output
  is not needed in the main context. `project-orient` wraps that.
- Use separate git worktrees for parallel write-capable sessions in this checkout.

## Working style

- Say plainly when something is unverified rather than hedging.
- Verify root causes before claiming them. Find the line that makes it true.
- Do not commit or push unless asked.
- No em-dashes in user-facing text.
