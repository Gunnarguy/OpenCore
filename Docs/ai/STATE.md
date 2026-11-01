# Current State

Updated: 2026-10-31
Branch/worktree: main, ~/Documents/GitHub/OpenCore
`main` matches `origin/main`. The 16 earlier local commits were squashed into one on 2026-10-31 at the owner's word, and the full history is the bundle in `~/Backups/OpenCore-2026-10-31`. Do not commit, stash or check out anything
without the owner's word.

Installed 2026-10-31 from this code: `/Applications/OpenCore.app`, `~/.local/bin/opencore`,
`~/.local/libexec/opencore/opencore` and `private-names.json`. A fresh installed `opencore mcp` listed 8
tools [measured]. Running clients keep the old image until reconnected. The store and the old install are
backed up in `AuditBackups/before-install-2026-10-31`, and the bundle and `Local/` are in
`~/Backups/OpenCore-2026-10-31` on the always-on machine.

Last verified 2026-10-31 on this tree: `swift test` exit 0, 590 tests; `./script/build_and_run.sh
--build-only` exit 0; `script/check_sensitive.sh` exit 0.

## Objective

[design] Stop hardening and start building, toward one app whose features reach every surface. Rebuild
and the Computer Use app side are reviewed. Home, the rest of hardening and currency stay open and are
named below. The feature-by-surface audit is in Notion, row "Ubiquity audit, 2026-10-31".

## Exact Next Action

[measured] The app first launched at 18:53 PDT on 2026-10-31 and its first sync ran: objects 9,537 to
9,738, claims 944 to 1,084, no crash in 80 s. The owner looks through its screens on dry run and reports
what he sees. Fix only what that finds. The iPhone companion then goes to Codex from the
Notion row "iPhone companion: full fidelity and control from an iPhone, connected to the MacBook", whose
first step is three owner decisions.

Older public commits, from before the squash, still hold private terms in their history. Rewriting public
history is his call.
Start any feature at `python3 script/codemap.py find <words>`.

## What Was Reviewed and What Was Not

Each reviewed item was built, adversarially reviewed and repaired, with temporary mutations proving
its tests fail when the behaviour is removed.

| Item | State | Where |
|---|---|---|
| Private names out of the tree | Reviewed. [test] | `LocalPrivateNames`, `script/check_sensitive.py` |
| Focused answers | Reviewed. [test, measured on a copy] | `QueryFocus`, `Reasoner.assemble`, `Conversation.claimSources`, `MCPServer.ask` |
| Time-aware questions | Reviewed. [test, measured on a copy] | `TemporalIntent`, `WindowReport`, `Store.activity`, `Store.freshness`, `PassageSearch(window:)` |
| Fresh store | Reviewed. [test] for the decisions, app side never run | `SourceSync`, `SyncLane`, `SyncCoordinator`, `SyncSchedule`, `AppModel+Schedule` |
| Honest beliefs | Reviewed. [test, measured on a copy] | `BeliefEngine.revisions(among:)`, `CommitNature`, `BeliefAlerts`, `MCPServer.admittedReason` |
| Rebuild | Reviewed. [test, measured on a copy] Maintenance screen never seen. Never applied to the live store | `RebuildRehearsal`, `RebuildDiff`, `RebuildExplanation`, `RebuildNarrative`, `safe-rebuild` |
| **Home** | **Open. NOT reviewed.** In the tree: `WhatChangedCard`, `Store.homeSnapshot`, `FailureBanner`, decks behind settings. [test] for the data, screen never seen | `HomeView`, `HomeSnapshot` |
| **Hardening** | **Open. NOT reviewed.** Some of it is in the tree, list below | Notion row "Hardening" |
| **Currency** | **Open. NOT done.** Nothing in the tree is claimed for it. Only APIs the reviewed items touched were checked | Notion row "WWDC26 currency" |

Hardening, read in the code on 2026-10-31 [source]:

- In the tree, unreviewed: `JSONValue.intValue` uses `Int(exactly:)`, so `limit: 1e300` and `id: 1e300`
  no longer trap. MCP limits are clamped, blocked counts are hidden from MCP callers, a bad `as_of` is
  refused, and the Spotlight gate matches MCP.
- Still open: `migrate()` has no transaction and no newer-store check. Unknown domains fall to
  `.project` at `Chunks.swift` and `Store.swift:82`. There are two `isClaimAdmitted` functions, in
  `Reasoner` and `MCPServer`. The Gemini key is in the URL (`Conversation.swift`), opt-in.
- Carried from the 2026-10-30 brief, not re-read: the setting that opens `restricted`.
- Computer Use Studio, 2026-10-31 [test for the decisions in `ComputerUseControl`, source for the views,
  never launched and never run live]: a step does its own action or is disabled with a reason, one Stop
  (bar above every section, ⌘.) cancels local work and posts `/api/tasks/stop`, the saved dry-run default is
  read at launch and going live asks first, and Eject has a confirmation that says who has the volume open.
- The Local Hub is a separate repository and needs `admit_control` on `desktop_type` and
  `desktop_press`, a wider policy regex, and its token off the open bootstrap GET.

## Do Not Do Yet

- [design] **An apply to the live store is the owner's decision.** [measured 2026-10-31, on a copy] A
  rehearsal took 29 s: 8 beliefs change, 15 slots get their first belief, 161 claims retired, 146 added,
  386 authority changes, 18 claims narrower, 0 wider, 2 open contradictions to 0, 6 of 6 linked receipts
  trace and 24 of 30 have no links. An apply on a copy kept every recorded belief's id and decision time
  (`memory checkout 2026-10-30` 87 lines before and after), and a second rehearsal found 0 changes,
  `decided_at` included. `opencore rebuild --explain DIR` gives each change by id and reason.
- [source] **Keep live computer control on dry run** until the Local Hub gaps above are fixed.
- [source] Do not test layout by writing to a physical monitor.

## What Installing Changes

Nothing here has reached the running app or MCP clients. Clients run `~/.local/bin/opencore`, and
running sessions hold the old image for days. `./script/build_and_run.sh --verify` replaces and
launches the app, and scheduled sync is on by default, so the live store starts changing about
20 seconds after launch. No migration was added, so older `opencore mcp` binaries keep working.

Until `private-names.json` is installed beside the store, repositories only it can name are left out
of a sync and the Local Hub reads as not running. It is not installed today [measured]:

```bash
cp Local/private-names.json ~/Library/Application\ Support/OpenCore/private-names.json
```

## Active Constraints

- [source] `.git` points at `.git.nosync` deliberately.
- [source] Build the app only through `script/build_and_run.sh`, which stages outside iCloud.
- [source] One build at a time, `--scratch-path /private/tmp/opencore-build`. Run `pgrep -f swift-build` first.
- [source] The repository is public. See `.claude/rules/sensitive.md`.
- [measured] Pre-repair store backup: `~/Library/Application Support/OpenCore/AuditBackups/20261024T000644Z`.
- [measured] Tree backup and git bundle of 2026-10-30 are at `~/Backups/OpenCore-2026-10-30` on the
  always-on machine. The bundle includes gitignored `Local/` with the real names.

## Verification

[test] 2026-10-31, on the final tree: `swift build` complete. Two full `swift test` runs each passed
554 tests, 0 failed (71, 45, 58, 22, 109 and 249 across the six binaries).
`./script/build_and_run.sh --build-only`: BUILD SUCCEEDED, exit 0. The app was not launched or
installed.

[measured] Rebuild review, 2026-10-31, on `/private/tmp` copies, deleted afterwards. A rehearsal's numbers
are explained by id in `--explain`: retired 161 (105 same statement on a new date, 37 same statement under
a new subject name, 14 replaced by another value, 5 no longer derived), added 146 (105, 40 and 1 new value),
386 authority changes all following object authority, 18 domains lowered all from mixed-domain sources, 603
new passages all on restricted ledger objects that were never chunked. Repairs: 7 quarantined statements
were coming back at `project` under new ids while the report said 0 raised, the store's 14 contradiction
rows and 5 belief versions were being lost, 2 cited evidence rows changed text, and the stale check could
not see a later quarantine. Each has a test proved by a temporary mutation, except the `quick_check` line
in `verifyBackup`, which no test fails without. A swap on a copy left object rows, receipts and traces
hash-identical, passed `integrity_check`, `foreign_key_check` and both FTS integrity checks, and a second
rehearsal found 0 changes. A correction made on a copy replayed through rehearse and apply.

[measured] One test failed 5 of 6 runs on 2026-10-31, after 539 had been reported passing. It compared
a `Date()` with one read back from the 1970-based column, and about half of current dates lose their
last bit there. The product was right and the fixture is fixed, then passed 10 of 10. A single green
run is not proof that a date comparison holds.

[measured] 2026-10-31, on a `/private/tmp` copy: `sqlite3 ".backup"` in under a second, integrity ok,
9,537 objects, 944 claims, schema version 6. "What was I working on recently?" answered from the
event log in under 0.1 s and named the store as stale. The live store's hash was unchanged afterwards.
The newest admitted event is from 2026-10-23, so the live store is stale until something syncs.

[measured] Earlier the same day, each on a copy: a chat turn traced 5 claim rows and 3 evidence rows
through `opencore trace`. "Which projects use Swift" went from no claims to 32. One question gave 2
distinct outputs in 12 fresh processes before and 1 after. A rehearsed rebuild gave 4 contradiction
rows, 0 open, and current functional claims with no support went from 9 to 0.

## Blockers / Unknowns

- Unverified: the app has not been launched with any of this. Nobody has seen Home, Maintenance, the
  banner or the Sources rows. `NSBackgroundActivityScheduler`, real EventKit and real Notes reads, and
  notification delivery have never run. Verify: RUNBOOK, "Manual check for scheduled sync".
- Unknown: why Apple Notes returned nothing on 2026-08-14. Verify: Sources, Re-read All Notes. The
  locale theory is ruled out [measured].
- Unknown: whether a model repeats a caveat. Chat gives it counter-evidence and nothing forces it to
  repeat it. One real case: it did not.
- Unknown: whether the schedule's `.utility` quality of service fires often enough on a Mac in use.
- Limit: without a rebuild, the live store keeps its 14 old contradiction rows, a frozen objective
  for OpenCore and 9 current claims with no support. That is the cost of not applying yet.
- Limit: `personal` stays closed to local ask, so notes, calendar and reminders can't be asked about,
  and "who contributed to X" shows nobody because every person is `personal`. Opening it is the
  owner's decision (brief item 7).
- Limit: benchmark v1 has no status, time, personal or follow-up cases (brief item 8).
- Limit: the app and the operator console have no test target. Logic goes in a package module to be
  tested.

## Where to Look

`Docs/ai/INDEX.md` routes the documents. `Docs/ai/codemap/INDEX.md` maps features to files. The builder
brief in auto memory has the full list of risks and the ranked features, and its line numbers are hints.
