# Current State

Updated: 2026-08-08 13:10 PT
Branch/worktree: `main`, primary checkout (not a linked worktree)
Last verified commit: `6925546`

## Objective

The MCP client is done. **Next objective: the eval harness** — the second and last item
classified `force multiplier` on the roadmap, and the one every unmeasured constant in this
repository is waiting on.

## Status

v0.3's headline work has landed and is verified against a real server. OpenCore now both
serves MCP and consumes it, so any of the ~9,650 registry servers can be a source without
writing a connector for it.

Nothing is in flight. The tree is clean and the next objective has not been started.

## Completed

- v0.1 (`43c1581`), v0.2 (`80fa667`) — see `Docs/ROADMAP.md`.
- `3e02ba6` — Claude Context OS: `Docs/ai/`, rules, skills, lifecycle hooks.
- `6925546` — SessionStart staleness counts source commits, not all commits.
- **MCP client** (this session, uncommitted at time of writing → see git log):
  `CoreJSONRPC` extracted so client and server share types without CoreIngest depending on the
  reasoning stack; `StdioTransport`; `MCPClient` with `initialize` → `server/discover`
  fallback; `MCPClientConnector` with default-deny tool policy; migration 3 (`source.config`);
  `mcp-source discover|add|list|remove` and `sync mcp`.

## Active Constraints

- **Objects are the floor.** `opencore rebuild` must reconstruct every derived layer.
- **Zero external dependencies**, including all MCP code.
- **Unmeasured stays `nil`.** No accuracy number may be quoted; none has been measured.
- **Authority never multiplies.** Ordinal tier, not a probability.
- **Default-deny for MCP tools.** Never derive an allowlist automatically, however strong the
  server's annotation looks. Widening this is a safety regression, not a convenience.

## Working Set

For the next objective (eval harness):

- `Benchmarks/` does not exist yet. OpenIntelligence's `Benchmarks/rag_eval_v1.jsonl` is the
  reference format worth copying.
- `Sources/CoreSearch/PassageSearch.swift`: every constant to be replaced by measurement lives
  here — RRF `k=60`, MMR `λ=0.7`, the `0.02` signal scaling.
- `Sources/CoreModel/Receipt.swift`: `confidence` is `nil` and stays that way until the harness
  produces a calibrated number.
- `Sources/CoreModel/Chunker.swift`: 1200-char target, 150 overlap, both chosen.

## Verification

Last run 2026-08-08, all green:

- `swift build --scratch-path /private/tmp/opencore-build` -> clean
- `swift test --scratch-path /private/tmp/opencore-build` -> **32 tests passed** (7 + 25)
- `mcp-source discover` against OpenCore's own MCP server -> 6 tools, protocol 2025-11-25
- `sync mcp selftest` -> 3 objects, 5 chunks; re-sync -> `0 new, 0 changed, 3 unchanged`
- `mcp-source remove selftest` -> cascaded all 3 objects
- macOS app: not rebuilt this session; last verified at `80fa667`

## Blockers / Unknowns

- **Unknown:** whether the client works against a third-party MCP server. It has only been run
  against OpenCore's own, which is a real server but one we wrote. *Verify:* install any
  registry server (a filesystem or fetch server needs no credentials) and run `discover`
  then `sync mcp`.
- **Unknown:** whether Calendar, Reminders and Notes work against real data. Unchanged from
  before; must be run from the built app, not the CLI.
- **Known gap:** the MCP *server* still implements `2025-11-25`. The *client* handles both
  generations. Server upgrade tracked Critical in Notion.
- **Known gap:** only GitHub produces claims. MCP, files, notes and calendar are retrievable
  but invisible to `claims`, `contradictions`, and `memory log`.

## Exact Next Action

Create `Benchmarks/` with a ground-truthed fixture corpus and
`Sources/opencore/EvalCommands.swift` exposing `opencore eval`. Report recall@k, MRR and nDCG
per retrieval stage over `PassageSearch`, so the lexical and dense legs can be scored
separately and RRF's contribution measured rather than assumed. Start with 20 hand-written
question/expected-passage pairs against the existing GitHub corpus; that is enough to detect a
regression and to answer the first real question — does the dense leg beat BM25 alone here.

---

## Addendum 2026-08-08 14:20 — app parity

The app had fallen far behind the engine. Now wired: **Passages** (PassageSearch with the dense
leg, RRF and MMR, showing per-leg ranks), **Time travel** (`beliefs(asOfKnowledge:)`), **MCP**
(discover → tick tools → allowlist → sync), **Maintenance** (diagnostics + rebuild with
before/after invariant check). App builds; 10 sidebar sections.

**Known rule violation, deliberate and recorded rather than hidden:** `AppModel+Maintenance.swift`
contains `DELETE FROM <table>` and `SELECT id FROM object LIMIT ... OFFSET ?`, duplicating
`Sources/opencore/main.swift:611-617`. This breaks `.claude/rules/store.md` ("every SQL string
lives in CoreStore") and the two copies will drift. **Fix:** add `Store.dropDerivedLayers()`
and `Store.allObjects(pageSize:)` to `CoreStore`, then delete both inline copies. Small, and it
should happen before anything else touches rebuild.

**Not verified:** the four new views have been type-checked and the app builds, but none has
been clicked through against real data.
