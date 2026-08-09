# Current State

Updated: 2026-08-08 16:00 PT
Branch/worktree: `main`, primary checkout (not a linked worktree)
Last verified commit: `daa9c63`

## Objective

**Build the eval harness.** It is the last item classified `force multiplier` on the board,
every retrieval constant in the repository is waiting on it, and it now also gates the decision
about whether to port any more of OpenIntelligence's engine.

## Status

Tree is clean, nothing in flight. v0.3's headline work landed: OpenCore both serves MCP and
consumes it, the registry is browsable in-app, and the macOS app has caught up with the engine
across ten sidebar sections.

The largest risk is no longer missing features. It is that **nothing in the app has been
clicked through against real data.**

## Completed

- v0.1 `43c1581`, v0.2 `80fa667` — see `Docs/ROADMAP.md`.
- `3e02ba6`, `6925546` — Claude Context OS, and a fix to its own staleness check.
- `5aa3448` — MCP client. `CoreJSONRPC` extracted so client and server share types without
  ingestion depending on the reasoning stack; default-deny tool policy; migration 3.
- `4a7e97e` — app parity. The app had never used `PassageSearch` at all: it built embeddings
  it then never searched. Added Passages, Time travel, MCP sources, Maintenance.
- `3ee49cb`, `7b3ae89` — Settings, then real settings. `RetrievalTuning` makes the retrieval
  constants data rather than `static let`; domain matrix; `Exporter`, which had been a README
  promise with no code behind it.
- `daa9c63` — Settings rebuilt on `Form`/`.formStyle(.grouped)`; MCP store over the full
  registry; per-server credentials in the keychain.

Store right now: 1,268 objects, 1,518 chunks, 39 entities, 97 claims, 0 contradictions.

## Active Constraints

- **Objects are the floor.** `opencore rebuild` must reconstruct every derived layer.
- **Zero external dependencies**, including all MCP code.
- **Unmeasured stays `nil`.** No accuracy number may be quoted; none has been measured.
- **Authority never multiplies.** Ordinal tier, not a probability.
- **MCP tools are default-deny.** Never derive an allowlist, however good the metadata looks.
- **OpenCore runs no model.** See `DECISIONS.md`; it is the reason most of OpenIntelligence's
  engine is absent rather than pending.

## Working Set

For the eval harness:

- `Benchmarks/` does not exist yet. OpenIntelligence's `Benchmarks/rag_eval_v1.jsonl` is the
  format worth copying.
- `Sources/CoreSearch/PassageSearch.swift` — `RetrievalTuning` already makes every constant a
  value, so a parameter sweep needs no refactor first.
- `Sources/CoreModel/Receipt.swift` — `confidence` stays `nil` until this produces a real one.

## Verification

Last run 2026-08-08:

- `swift build` and `swift test` -> clean, **32 tests pass** (7 + 25)
- `xcodebuild -scheme OpenCore` -> BUILD SUCCEEDED, 10 sidebar sections
- `opencore export` -> 19 files, 3.2MB, 1,249 objects, no credential patterns in the output
- MCP registry -> one page of 100: 64 latest, 23 launchable over stdio
- `sync mcp selftest` against OpenCore's own server -> 3 objects; re-sync `0 new, 3 unchanged`
- Calendar **has** run against real data: 558 `calendarEvent` objects in the store

## Blockers / Unknowns

- **Nothing in the app has been clicked through.** Every screen compiles; none has been used.
  Riskiest path: MCP store → credentials → Add → Discover → tick tools → Sync. *Verify:* open
  the app and do it. Tracked Critical in Notion.
- **Settings responsiveness is fixed but unconfirmed.** Two real causes removed: `AnyView`
  erasure in the stepper rows, and buttons gated on a background network verify. *Verify:* ask
  the user; profile with Instruments if it still drags.
- **The MCP client has never run against a third-party server**, only OpenCore's own. *Verify:*
  add one from the store and sync it.
- **Known gap:** the MCP *server* still implements `2025-11-25`; the *client* handles both
  generations. Tracked Critical in Notion.
- **Known gap:** only GitHub produces claims. Files, notes, calendar and MCP content are
  retrievable but invisible to `claims`, `contradictions`, and `memory log`.
- **Known rule violation:** rebuild SQL is duplicated between `AppModel+Maintenance.swift` and
  `Sources/opencore/main.swift`, breaking `.claude/rules/store.md`. Fix is
  `Store.dropDerivedLayers()` plus `Store.allObjects(pageSize:)`, about fifteen lines, and it
  should land before anything else touches rebuild.

## Exact Next Action

Create `Benchmarks/rag_eval_v1.jsonl` with 20 hand-written question/expected-passage pairs over
the existing GitHub corpus, and `Sources/opencore/EvalCommands.swift` exposing `opencore eval`.
Report recall@k, MRR and nDCG **per leg** — lexical alone, dense alone, then fused — so the
first real question gets an answer: does the dense leg beat BM25 alone on this corpus, or is
RRF carrying a passenger.

Everything downstream waits on that number: whether reranking is worth adding, whether the
retrieval constants are anywhere near right, and whether OpenIntelligence's Deep Think is worth
porting at all.
