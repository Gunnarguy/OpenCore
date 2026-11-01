# Runbook

Every command below is marked **verified** (run successfully in this repository, with the date)
or **unverified** (derived from configuration, never executed here). Do not promote an
unverified command without running it.

## Environment

Xcode 27.0 release (`27A266a`, Swift 6.4, `MacOSX27.0.sdk`) at `/Applications/Xcode.app` (already active via `xcode-select`).

**Build outputs must live outside `~/Documents`.** This repository is inside iCloud-synced
`~/Documents`; iCloud stamps extended attributes on build inputs and `codesign` rejects them.
Use `/private/tmp/...` for every scratch and derived-data path.

## Build and test — verified 2026-10-31 [test]

```bash
swift build --scratch-path /private/tmp/opencore-build
```

```bash
swift test --scratch-path /private/tmp/opencore-build
```

Observed 2026-10-31: 539 Swift tests passed (71, 45, 58, 22, 109 and 234 across the six binaries),
three full runs in a row. One build at a time: run `pgrep -f swift-build` first.

When a comparison of dates fails only sometimes, suspect the column. A `Date` read back from a
1970-based `REAL` loses its last bit about half the time [measured], so build a fixture's date from
`Date(timeIntervalSince1970:)`.

The CLI binary lands at `/private/tmp/opencore-build/out/Products/Debug/opencore`, **not**
`.build/debug/`, when `--scratch-path` is used. This surprises people every time.

## Before committing [test]

```bash
script/check_sensitive.sh
script/check_sensitive.sh --history
```

The repository is public. The first checks the working tree and any staged change; the second
lists unpushed commits with a private term in a file, a file name, a message or an author field.
Exit 2 means the check could not run. Terms are the gitignored `Local/sensitive-terms.txt` plus
every name in `Local/private-names.json`. See the `publish-check` skill.

## Private names [source]

Names the program needs and this repository must not hold live in `private-names.json` beside the
store. `Docs/private-names.example.json` shows the shape, and `Local/private-names.json` holds the
real one, gitignored.

```bash
cp Local/private-names.json ~/Library/Application\ Support/OpenCore/private-names.json
```

Until it is installed, or while it is unreadable or states fewer than all three repository lists:

- [test] Repositories this build can't name are left out of a sync, and what is stored is not
  changed. `opencore sync agent-memory` says so on stderr, and the app records it in the feedback
  log. They are not marked `.restricted`, because `Store.retainedImportDomain` never lowers that.
- [source] The extra fleet cards do not appear and no peer is probed.
- [source] The Local Hub reads as not running, because `localAutomation.hubIdentity` is what it is
  checked against before its token is fetched. Its catalog and guide are not read, and no automation
  profiles are listed.

The file is read once per process, so a running app or `opencore mcp` needs a restart to see it.

A repository that gets listed after it was marked `.restricted` stays `.restricted`. Only an
explicit retag can lower it, and that action does not exist yet.

## Measure on a copy of the store — verified 2026-10-31 [measured]

```bash
LIVE="$HOME/Library/Application Support/OpenCore/opencore.sqlite3"
mkdir -p /private/tmp/opencore-copy
sqlite3 "file:$LIVE?mode=ro" ".backup '/private/tmp/opencore-copy/store.sqlite3'"
```

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore ask --db /private/tmp/opencore-copy/store.sqlite3 "What was I working on recently?"
```

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore rebuild --db /private/tmp/opencore-copy/store.sqlite3 --work-dir /private/tmp/opencore-rehearsal
```

The copy took under a second, the rehearsal 19 s and 215 MB, and `shasum` of the live store matched
before and after. The copy holds private history, so delete it when done. See the `store-copy` skill.

## Find a feature [measured]

```bash
python3 script/codemap.py find sync
python3 script/codemap.py owner Sources/CoreGraph/SourceSync.swift
python3 script/codemap.py check
```

After changing code: `python3 script/codemap.py affected`, then `refresh <id>` once the slice is right.

## macOS app — `--build-only` verified 2026-10-31, `--verify` last run 2026-10-23 [test]

```bash
./script/build_and_run.sh --build-only
```

```bash
./script/build_and_run.sh --verify
```

[source] The script stages source inputs at `/private/tmp/OpenCore-review-source`, generates
the Xcode project there, and builds at `/private/tmp/opencore-review-dd`. Staging inputs as well
as outputs avoids iCloud's code-signing attributes. It verifies the signature before installation.

[measured] `--verify` built, backed up the previous `/Applications/OpenCore.app`, replaced it
and launched the new app on 2026-10-23. Previous bundles are retained under
`/private/tmp/OpenCore-app-backups/`.

[source] Launching a new app turns scheduled sync on by default, and the first pass starts about 20 s
after launch, so an install is also the moment the live store starts changing. `--build-only` builds
and signs and touches neither `/Applications` nor the store.

`.xcodeproj` is gitignored and regenerated from `project.yml`. Never hand-edit it.

## First run — verified 2026-08-08

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore doctor
```

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore sync github --commits 40
```

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore embed
```

Measured: 691 objects and 966 chunks from 21 repositories in 16–20s; embedding all 966 passages
took 25s on device.

Use `--db /private/tmp/opencore-demo/oc.sqlite3` on any command to work against a scratch store
instead of the real one at `~/Library/Application Support/OpenCore/opencore.sqlite3`.

## Saved chats — verified 2026-08-10

Every chat turn is written to the store as it completes, so a thread can be reopened later.

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore chats
```

Lists saved threads, most recently used first, with turn counts and the id `--resume` takes.

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore chat "FOLLOW-UP QUESTION" --resume THREAD_ID
```

Resuming restores the visible history **and** replays the exchanges into the model's
`Transcript`, so the model has the conversation rather than only the reader having it.

Verified: a thread went 2 turns to 4 on resume rather than forking a new one, and
`opencore trace <code>` now resolves a receipt printed by `chat`, which it previously could not.

**Retrieval still runs on the raw follow-up text.** "What language did you just say it uses"
retrieves nothing useful and correctly answers "the sources retrieved do not answer that". The
model has the context and is refusing to answer from memory, which is the design working;
query rewriting for follow-ups is a tracked gap, not a bug in resume.

## MCP installation and connection [source]

**The binary is not relocatable on its own.** It loads migrations from
`OpenCore_CoreStore.bundle`, which must sit beside it, or it dies with
`unable to find bundle named OpenCore_CoreStore`. Install both:

```bash
mkdir -p ~/.local/libexec/opencore
cp /private/tmp/opencore-build/out/Products/Debug/opencore ~/.local/libexec/opencore/
cp -R /private/tmp/opencore-build/out/Products/Debug/OpenCore_CoreStore.bundle ~/.local/libexec/opencore/
```

[measured] On 2026-10-23, both `~/.local/bin/opencore` and
`~/.local/libexec/opencore/opencore`, with their adjacent resource bundles, were updated using
verified staged replacements. Original binaries and bundles are retained in the audit backup
directory named below. Release configuration has not been verified.

Do **not** point a client at `/private/tmp/opencore-build`. That path is periodically cleaned,
and the failure arrives weeks later as a client that silently lists no tools.

Config lives at `~/Library/Application Support/Claude/claude_desktop_config.json`. Merge, never
overwrite: it also holds window state, folder grants and per-account preferences.

```json
{ "mcpServers": { "opencore": { "command": "~/.local/libexec/opencore/opencore", "args": ["mcp"] } } }
```

[source] An existing client can keep an old process or a closed transport after replacement.
Reconnect it before testing the new server. In Codex's desktop app, Settings > MCP servers
provides Restart ([official instructions](https://learn.chatgpt.com/docs/extend/mcp)).
Other clients may require their own reconnect or relaunch. Do not restart a user's active
agent session without considering its work in progress.

[measured] A fresh installed process negotiated initialization, listed 8 tools and answered
`core_dossier` against the live store with only JSON-RPC on stdout. This audit chat's original
connection reported `Transport closed`; the computer-use tool refuses access to Codex itself,
so the in-app Restart control was not exercised.

Verify the server by hand before blaming the client:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"core_ask","arguments":{"query":"what is OpenCore built with"}}}' | ~/.local/libexec/opencore/opencore mcp 2>/dev/null
```

Measured: negotiates the client's version, then returns 92 claims with evidence and authority.
Tool arguments are `query` for `core_ask` and `core_search`, `entity` for `core_claims`,
`receipt` for `core_trace`.

## Exercising the MCP server — verified 2026-08-08

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /private/tmp/opencore-build/out/Products/Debug/opencore mcp 2>/dev/null
```

stderr carries the logs; stdout carries only JSON-RPC. Redirecting stderr away is what makes the
output parseable.

## Recovery

**Nonsensical build failure** — duplicate symbols, "invalid redeclaration", a codesign
"resource fork ... not allowed" error. iCloud wrote a conflict copy such as `Foo 2.swift` and
the build is compiling it for real. Find and delete it:

```bash
find . -name "* 2.*" -not -path "./.git.nosync/*"
```

**Derived layers look wrong, or an extraction rule changed** [test] — rehearse on a copy. `rebuild`
never writes to the store it is pointed at. Reviewed and proved on a copy on 2026-10-31:

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore rebuild --work-dir /private/tmp/opencore-rehearsal
```

It copies the store, re-derives the copy, carries across corrections, user assertions, model
proposals, quarantine, contradictions, belief history, cited text, receipt links, vectors and
first-known dates, and prints the difference with a reason for each change. `opencore rebuild
--explain DIR` lists every change by id. Without `--work-dir` the copies go in `Rehearsals/` beside
the store and need about twice its size. To apply, on the owner's word only:

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore rebuild --apply-rehearsal /path/to/rehearsal
```

Apply is one transaction, so a running `opencore mcp` sees the old graph or the new one. It
refuses a report with blockers (a claim readable by more callers, a lost correction, contradiction,
belief version or claim row, a past answer that no longer traces) and refuses if the store moved
after the rehearsal. It first copies the store to `before-apply-*.sqlite3` in the rehearsal
directory and proves the copy, and that file is the way back. The app's Maintenance screen runs the
same two steps. See the `safe-rebuild` skill.

**Agent-memory policy repair** — verified 2026-10-23 [test, measured]:

```bash
~/.local/bin/opencore repair-agent-memory
```

[source] The default is read-only. Applying requires a new backup path; the command creates
its own consistent SQLite snapshot with private permissions before changing policies:

```bash
~/.local/bin/opencore repair-agent-memory --apply --backup /ABSOLUTE/NEW/backup.sqlite3
```

[measured] The audit first tested a copy, then repaired the live store in 6.42 seconds:
556 floor policies, 11 historical policies, 518 quarantined claim rows and 603 restricted
audit-floor snapshots. Original 7,469 objects, 20 versions, 26 receipts, 813 claim rows and
7,231 events were preserved. There were zero live correction rows; correction preservation
was tested separately. Store integrity remained `ok`.

[measured] The pre-repair store, original installed binaries/bundles, and preservation hashes
are retained at
`~/Library/Application Support/OpenCore/AuditBackups/20261024T000644Z`.
The SQLite snapshot is mode 0600. **Do not rerun the repair as an attempt to replay the 556
quarantined objects.** Reviewed derivation recovery remains a separate roadmap item.

**Store corruption or a requested reset** [design] — do not delete the Application Support
directory. It may contain unique original imports, conversations, corrections, receipts and
credential recovery material. Stop writers, preserve a consistent snapshot and the directory,
check integrity on a copy, and choose a recovery plan against that copy. A source being
available today does not guarantee historical source versions can be fetched again.

**`gh repo create --source=.` fails with "not a git repository"** — `gh` does not follow the
`.git` gitdir pointer this repository uses. Create the repo by name and add the remote by hand.

## Git layout

`.git` is a **file** containing `gitdir: .git.nosync`, deliberately, to keep the object store
out of iCloud sync. Do not "fix" it. Ordinary git commands work normally.

## Not verified here

- **Scheduled sync.** The decisions are tested: `SourceSync`, `SyncLane`, `SyncCoordinator`,
  `SyncSchedule`, both Apple connectors. `AppModel+Schedule` and the Sources screen are built and
  have never run, and `NSBackgroundActivityScheduler` has never fired in this app. A source
  advancing unattended over days is unobserved. Calendar and Reminders must run from the app, not
  the CLI: EventKit reads usage strings from the calling binary's `Info.plist` and a SwiftPM
  executable has none, so the request is denied by TCC with no prompt.
- **Notes sync.** `source.last_synced` says 2026-08-14 with 0 objects, and why is not established.
  It now fails loudly on an empty reply, and a partial read keeps the date where it was. The app
  gained the Apple Events entitlement, so the Automation prompt may appear for the first time. A
  person raises it: the schedule leaves Notes out until a read someone started has brought something
  back, because only EventKit has a status to read beforehand and the read waits up to 300 s.
- **Calendars entitlement.** `com.apple.security.personal-information.calendars` is added because
  Apple lists it for reading calendars under the Hardened Runtime. The 2026-08-14 sync worked
  without it, so it fixes nothing observed. Whether Reminders needs it too is not established.

### Manual check for scheduled sync, unverified

Run by the owner, because it needs the app, its permission prompts and days of running.

1. Install with `./script/build_and_run.sh --verify`.
2. Sources, then Apple Calendar, Apple Reminders and Apple Notes, once each. Answer any prompt.
   Each row under the toggle should show a result. A row showing the failed read is a result too.
3. Sources, Re-read Whole Calendar. Every event should now carry the field, and `attended` claims
   should exist for any event with named accepted attendees:

   ```bash
   DB=~/Library/Application\ Support/OpenCore/opencore.sqlite3
   sqlite3 "file:$DB?mode=ro" "select count(*) from object where kind='calendarEvent' and json_extract(metadata,'\$.attendees_accepted') is not null;"
   sqlite3 "file:$DB?mode=ro" "select count(*) from claim where predicate='attended';"
   ```

4. Leave the app running. Over three days `source.last_synced` should advance with nobody touching
   it, Calendar and Reminders about hourly and Notes about every six hours:

   ```bash
   sqlite3 "file:$DB?mode=ro" "select handle, datetime(last_synced_at,'unixepoch','localtime') from source where handle in ('calendar','reminders','apple-notes');"
   ```

5. Click a source during a scheduled pass. It should refuse with a banner naming the running sync.

- **Release builds.** Only Debug has been built.
- **CI.** There is none yet.


## Coherence navigation regressions [test, measured]

Verified 2026-10-23 in the installed Debug app after `./script/build_and_run.sh --verify`.
Evidence logs: `~/Documents/Codex/2026-10-23/hm/work/opencore-coherence/`.
Repeat these checks after changing navigation or inspector presentation:

1. From Command Center, open **How it connects**, choose a project from loaded records, then
   **Statements**. The subject banner stays visible; the view uses that exact subject, not a
   filtered global 400-row page. OpenCore had 27 current statements in this check.
2. Open **Decisions** through the related-view strip. The subject stays the same. OpenCore had
   six decision records. **Inspect evidence** opens the pane; **Inspect original** opens the
   source record within that pane. Close remains available throughout.
3. From a scoped statement view, inspect evidence, then use **Statements** for that same subject
   in the pane. It closes the pane without adding an identical Back hop. Back/Forward restore
   the prior destination and its subject.
4. From scoped Claims, open Corpus and click its global Statements total. The subject banner
   clears and the global page loads. Back through Corpus restores the former subject scope.
5. Open Quick Jump with Command-K and type **workflow**. The results change with the query.
   Choose **How OpenCore fits together**; Quick Jump closes before the map opens. Close the map
   and repeat. Keyboard selection is stored by result identity when async rows are inserted.
6. Check the Originals total in Corpus: it clears record filters and scrolls to the originals
   browser. It must not open source configuration.
7. After visiting scoped Statements and Decisions, open Knowledge Graph and its Statements
   and Decisions & Revisions tabs. Each retained scope has its own visible subject banner.
   **Show all subjects** clears the matching tab scope without leaving Knowledge Graph.

[source] Empty Claims/Beliefs/Receipts messages are placed inside their content, so they do
not cover the controls required to populate the view. An empty-store native fixture was not run.
[source] The old automatic inspector hung during actual interaction. The explicit bounded
split is intentional; compilation alone is insufficient to validate a replacement.


## Native Model Lab and local runtime checks [test, measured]

Verified 2026-10-23. Open **AI Models & RAM → Model Lab**. Recommendations have named Load
controls. Loading waits for confirmed readiness. **Use for a task** selects the planner and
opens Scoped Tasks & Saved Routines. Compatible scopes remain explicit.

**Run skill checks** loads a card and runs synthetic fixtures; **Compare installed models**
checks the installed catalog. **Set up & compare** additionally downloads missing packages.
Do not invoke that action just to refresh scores. **Stop checks** unloads the active worker
and retains stopped attempts. Expand **See every trial and its evidence** to inspect exact
revision, fixture, output, elapsed time and errors. A completed run may contain failed trials.

[source] The Hub owns weights and model-checks.json under Application Support, with its
server snapshot in ~/Applications/Local Hub.app. OpenCore never copies the weights into its
store. The related repo's docs/MODEL-QUALIFICATION.md defines fixtures, versions and limits.

[test] Hub verification: `scripts/python -m pytest -q`, `node --check hub/static/app.js`, and
`scripts/python scripts/update-guide.py --check`. Final pass: 106 tests. Native OpenCore:
`./script/build_and_run.sh --verify`, then strict deep code-sign verification. Model evidence
and limitations are in the current chat's outputs/OpenCore-model-results.md. Never print the
Hub bootstrap token while probing its POST endpoints.

[measured] Native load/composer routing, per-card start, Stop during loading and service
restart were exercised. Qwen wrote a real scratch file with exact independent readback;
Fara's browser diagnostic clicked a filled form from a masked screenshot and found the
matching saved record. These checks establish those paths only. No TCC grants, native
recording, arbitrary desktop click loop or real-account task was exercised.

## Command Center Mac warnings [test, measured]

Verified 2026-10-23 in the installed app. Click **Low Data Volume Space** or the storage
gauge to open **Mac checks → Storage**. Capacity comes from /System/Volumes/Data; the warning
uses the Settings threshold. The seven folder sizes cover known model and build locations,
not the entire Mac. **Show in Finder** reveals the selected location. **Manage downloaded
models…** and **USB & disk details…** dismiss the sheet before opening their workspace.

Click **possible duplicate files** to open the matching topic. Each candidate has separate
Finder buttons for the numbered file and its matching base filename. Both README paths in
A private repository and two nested build folders were revealed successfully.
These are filename candidates; neither contents nor conflict status is established by the scan.
**Refresh checks** retains the topic. **Simulators** shows the successful empty state on this
Mac; no device was booted or removed. Failed checks show unavailable/incomplete status.

[test] `swift test --scratch-path /private/tmp/opencore-build` passed all 178 tests, including
five machine-check regressions. `./script/build_and_run.sh --verify` built, installed and
launched successfully; `codesign --verify --deep --strict /Applications/OpenCore.app` and
`git diff --check` passed. Logs are under the current chat's work/opencore-models/warning-*.
No model downloads, deletions, merges or cleanup actions ran in this repair.

## Rank every model and remove downloads [test, measured]

Verified 2026-10-23 on Apple M3 Pro, Mac15,6, 18 GiB RAM, macOS 27.0 (26A428).
Open **AI Models & RAM → Model Lab → Rank every model**. Choose a job to see the full
13-model catalog, comparable placements, pass counts, median response time, measured MLX
peak and download size. **Compare installed models** runs without downloading weights.
The current 70-trial pass covers all 13 choices with matching hardware/runtime provenance.
Do not turn these small suites into a general intelligence or desktop reliability score.

[measured] Four native comparisons checked: exact files (Qwen 4B first), readable controls
(Apple first), screenshot targets (Holo 3B first) and screenshot reading (Qwen2.5-VL only
tested choice). Missing memory remains unmeasured. Worker is left unloaded after this pass.

[measured] **Storage & delete downloads** lists all 12 downloaded packages, largest first.
**Delete download…** opens a confirmation naming the model and its file size. A native
Qwen2.5-VL 5.65 GB confirmation was canceled; all installation metadata remained unchanged.
No live model was deleted. The API's actual removal path passed with disposable owned files
in an isolated test store, preserving its qualification file and routines. Apple deletion is
explicitly rejected. After user-confirmed removal, refresh actual free space; logical bytes
removed and immediate APFS availability can differ. **Unload** alone leaves model files on disk.

[test] Hub full suite: `scripts/python -m pytest -q` → 113 passed. Final portable ranking
guards: `scripts/python -m pytest -q tests/test_model_rankings.py` → 6 passed. Both app
signatures pass strict deep verification; four native source files and three Hub runtime files
match installed staging/snapshot. Logs: current chat work/opencore-models/ranking-*.
Exact results: current chat outputs/OpenCore-ranking-storage-verification.json,
OpenCore-machine-rankings.json and OpenCore-machine-ranking-summary.json.

## Hardware detail reading layout [test, measured]

Verified 2026-10-23: `./script/build_and_run.sh --verify` -> built, installed and launched.
`codesign --verify --deep --strict /Applications/OpenCore.app` -> passed. Both layout source
files match /private/tmp/OpenCore-review-source; `git diff --check` -> passed.

[measured] Open **Hardware, USB & Disk -> Devices -> USB3.0 Hub** (VIA Labs,
0x2109:0x0817). Scroll to **Device Details** and **Power Usage**. Labels and values now
form two nearby leading columns, independent of the inspector's right edge. Click
**Explain Serial Number** -> the unique-ID explanation expands below the row.

[source] HardwareDetailValueRow supplies text-scaled label/value widths, selectable wrapping
values, and a stacked fallback when horizontal space is insufficient. The two shared helpers
cover device, speed, power, controller, Thunderbolt and overview statistics. Focused read-only
review found no defects. Native narrow-window, larger-text and VoiceOver checks remain
unverified: CUA resizing was blocked by menu/window state. No model/data logic changed.
Evidence: current chat outputs/OpenCore-hardware-layout-verification.json and
work/opencore-models/hardware-layout-install.log.

## User-requested model cleanup [measured]

2026-10-23: the existing Local Hub POST /api/models/delete API removed eight selected catalog
downloads, totaling 29,183,295,809 file bytes. Holo 7B, UI-TARS 7B, OS-Atlas 7B, UGround 2B,
both Raptor tiers, ShowUI 2B and Qwen 1.7B were removed. Qwen 4B, Holo 3B, Qwen2.5-VL 7B and
Fara remain (15,015,008,885 logical bytes), plus Apple's OS-managed model.

[measured] GET /api/status and owned folder checks -> eight folders absent, exactly four
downloads retained with unchanged metadata. Data-volume free bytes rose from 7,198,044,160
to 36,375,384,064 immediately after removal. Model-checks.json checksum, 37 task/routine/
recording/knowledge/scratch record files and non-model settings/state were unchanged.
Evidence: current chat outputs/OpenCore-model-removal-verification.json.

[source] **Compare installed models** avoids downloads. **Set up & compare** fetches missing
packages; do not run it to refresh the display after this cleanup. Saved check results remain
visible for removed packages, which need an explicit download before running again.

## Connected monitors [test, measured]

2026-10-23: `swift test --scratch-path /private/tmp/opencore-build --filter DisplayRegistry`
-> 2 passed. `./script/build_and_run.sh --verify` -> final build/install/launch passed.
`codesign --verify --deep --strict /Applications/OpenCore.app`, `git diff --check` and seven
production source/staging byte comparisons -> passed. Review fixes reject ambiguous online
twins/reused serials and nonintegral descriptor values instead of assigning or truncating them.

[measured] Open **Hardware, USB & Disk → View → Displays**. In a narrow list pane View is a
menu; in a wide pane it is segmented. The installed native UI exposes the Displays option,
3 Displays count and hardware sidebar total 21. The same production inventory code run as a
read-only probe returned the primary external monitor (2560×1440 @60 Hz, 5120×2880 render, 30 modes),
Apple built-in (1800×1169 @120 Hz, 60 modes) and a second external monitor (1920×1080 @60 Hz, 159 modes).
Both external descriptors matched vendor/product/serial without ambiguity.

[source] Details preserve nearby label/value columns, current desktop versus render dimensions,
separate descriptor claims, offered modes, and a Display Settings action. Quartz/AppKit enumerate
online monitors separately from USB devices/cameras; display reconfiguration notifications refresh
the inventory. Service Connections remains for MCP/services; its orientation points to Hardware
for monitors. The generic screen inventory works independently of an optional Apple Silicon
IOMobileFramebufferShim descriptor match. Unknown connector/dock paths remain unknown.

[measured] Native detail/settings click-through was blocked by "Sky Computer Use native pipe
closed before response", persisting after a CUA runtime reset. OpenCore stayed alive with no
new crash report. After reconnecting, verify selection, expansions, search, Refresh, Settings
destination and real display attach/remove. These are unverified, as are VoiceOver and actual
physical cable attribution. No mode/firmware changes or model downloads ran.

[source, measured] Evidence: current chat outputs/OpenCore-displays-verification.json and
work/opencore-models/{display-runtime.json,display-tests.log,displays-install-final.log}.
Public API reference checked: https://developer.apple.com/documentation/coregraphics/quartz-display-services.

## Live monitor controls and hardware browser [source, test, measured]

2026-10-23: open **Hardware, USB & Disk → 3 Displays → the primary external monitor**. USB/Displays count
buttons switch to those lists. The hardware browser now uses its own HSplitView instead of a
nested navigation sidebar. It stays present when the app sidebar hides. Mode selection persists.

[source] Monitor detail starts with a compact current-mode header and four sections:
**Picture**, **Resolution & Signal**, **Inputs & Power**, **Advanced**. Picture controls use a
two-column grid with a one-column fallback. Headers stack and section tabs become a menu when
narrow. Full explanations expand beside their setting; provider boilerplate/raw reports live in
Advanced. Installed Dark-mode cards, monitor navigation, Inputs & Power explanations and sidebar
hide/show were verified in the native UI. Hiding app navigation preserves the hardware list and
controls. Narrow resize, Light mode and VoiceOver are not qualified; AX text sometimes lagged
the visible screenshot, so pixel checks do not establish accessibility correctness.

[source] Brightness/contrast/RGB/volume sliders send automatically through a latest-value queue.
The chosen 250 ms coalescing interval avoids a packet per event. Ranges are checked against the
current monitor, and each command gets immediate bounded settlement/readback beside its row.
The chosen 2-second polling interval refreshes visible monitor readings and a selected Advanced
feature. Successful picture edits no longer require a manual full reload. Full refreshes update
the existing snapshot; they do not remove/recreate every control row during an edit.

[source, test] A stopped picture session invalidates unsent/taken preflight edits before SET.
Already-admitted changes finish readback; local cancellation cannot retract them. Operation
leases, exact UUID/native identity matching, unknown-outcome locks, mode-preview exclusion and
UInt16/continuous range checks remain in force. Older readbacks retain feedback for a newer queued
value. D6 power reads accept only readable states 1...4, including when no enum is advertised
and maximum is 1; write-only 5 and invalid 24 are unavailable. Read errors and last mutation outcomes stay separate; a successful GET cannot erase a
failed SET. Disruptive input/power retain explicit named confirmations. Presets apply on selection.

[source] Guide text covers reported DDC controls/diagnostics and the 141 installed provider
features. Monitor power is a screen power request; input chooses its video source; Display
Application means a picture-use preset, not a Mac app. Standard MCCS option names are qualified;
The primary monitor's unmapped current values remain unmapped. Signal help explains bit depth, RGB/YCbCr,
4:4:4/4:2:2/4:2:0, full/limited range and SDR/HDR. Configured inputs are not a socket inventory.

[test] `swift test --scratch-path /private/tmp/opencore-build --filter
'DisplayControlUpdateTests|BetterDisplay|DisplayMode|DisplayMutation|DisplayRegistry'`
-> 45 tests passed, 0 failed. Final build/install/launch and strict signature passed; final review
found no defect
following corrections to generation, reentrancy, queued feedback, numeric bounds and read/write
outcome separation. Use `./script/build_and_run.sh --verify` for install/launch; current chat's
work/opencore-models/live-controls-final-install.log records the final result.

[measured] Before the repair, the actual productionStore DDC path changed the primary monitor's brightness
100→95→100 with exact readback; the problem was staged-only UI/manual refresh/feedback placement.
After repair, three queued values coalesced to 97, actual readback 97 arrived in 0.613 s in this one
probe, readingsStale=false, and original 100 was restored/verified. Canceling an unsent edit left 100
unchanged; live polling returned 100 with no read error. This is a command/readback measurement,
not an instrument measurement of panel luminance or a latency distribution. The actual installed
brightness slider also changed 100→99→100 with independent CLI readbacks and visible green
per-control verification. No input/power,
color preset, rotation, signal or native mode changes were exercised.

[measured] Prior read-only probe: primary monitor 65 exact Quartz / 79 provider desktop / 2 compatible
signal modes, 23 DDC features; built-in 132 / 132 / 1 and the second monitor 443 / 464 / 5 with DDC query failures
preserved. BetterDisplay 5.1.1 (53784), native notification integration, no helper/listener install or
security/license preference change. Complex target/controller/stream/property commands remain
inspect-only with Open BetterDisplay. Native mode preview remains app-only with a chosen 15-second
Keep/Revert period after verified apply and session-only Keep; physical rollback remains untested.

[source, measured] REA Mach-O evidence, installed help and original read-only reports remain at
current chat work/opencore-models. Ghidra string analysis timed out; no decompilation/firmware claim.
Evidence: outputs/OpenCore-live-monitor-controls-verification.json and
work/opencore-models/{brightness-roundtrip-before.json,live-controls-roundtrip.json,
live-controls-tests.log,live-controls-final-install.log}. Roadmap 40349a74-d54f-819d-b694-f1ff4499d8d5.

[measured] With auto polling paused and 250 ms gaps, sequential power/power/input/input/power/
power queries returned 24,24,5,5,5,5 while the primary monitor stayed visibly on. No power action ran;
the cause is unqualified. Invalid power values now render Unavailable in the final installed UI.
Roadmap follow-up 40349a74-d54f-81fe-8929-f48959e6a921 tracks isolated power-read qualification,
remaining physical input/power/mode rollback checks and accessibility/layout limits. The parent
controls row remains In Progress for that qualification.

## USB-C / DisplayPort controls missing [source, test, measured]

2026-10-24: user screenshots show the primary monitor 2560×1440 at120Hz with a failed DDC capability request.
That video-mode observation does not qualify the hardware-control channel. At the initial disconnected checkpoint,
`system_profiler SPDisplaysDataType -json`, BetterDisplay `get -identifiers` and native OpenCore
saw only the built-in screen. The primary monitor subsequently reconnected; see the live DP probe below.

[source, test] Empty/failed reads cannot certify a successful hardware-read timestamp. Empty
external discovery retries at a chosen30-second interval with backoff after provider/load failures.
The new panel offers Retry control discovery, Open BetterDisplay and official DDC setup guidance.
A successful capability list with no controls in one category has different copy. The built-in
screen uses Apple guidance and does not trigger external-DDC discovery retries.

[measured] Safe next probe: inventory identifiers, match current display/vendor/product/serial,
then GET ddcCapabilities and direct brightness VCP current/max. A failed capabilities report alone
does not establish whether individual commands work. BetterDisplay Settings → Displays → select
monitor → Device Control → DDC Control → Detect DDC Capabilities is the documented inspection path.
Do not auto-configure/reset saved controls or write power/input as part of this diagnosis.

[test, measured]46 focused tests, final app build/install/launch, strict signature, diff check and
four source/staging comparisons passed. Native built-in guidance/no false successful timestamp
verified. That initial disconnected checkpoint did not qualify the external panel. Subsequent native
Primary-monitor recovery/video-summary rendering is verified in the reconnect evidence below; physical
DDC success remains unqualified.
Evidence: current chat outputs/OpenCore-displayport-controls-verification.json and
work/opencore-models/displayport-*. Reference checked2026-10-24:
https://betterdisplay.pro/guide/interface-reference/settings/displays/display/device-control/ddc/.

## Primary monitor reconnected over DisplayPort [measured, source]

2026-10-24: match the monitor by its current UUID, display id, vendor, product and serial as
BetterDisplay reports them; the values are not recorded here. The old HDMI UUID/product must not be
reused.
Direct read-only BetterDisplay probe (OpenCore polling paused) returned displayInformation and
identifiers, but failed ddcCapabilities, ddcCapabilitiesString, luminance current/max, input and
power. This failure occurs outside OpenCore. It does not identify whether monitor, cable, provider
configuration or timing causes it. No hardware writes were performed.

[measured] Video report:2560×1440 at120Hz,DisplayPort,HBR2,4 lanes,5.40Gbps/lane,17.28Gbps
effective capacity,8 bits/sample,RGBFullRange,SDR,noDSC. These are provider/link reports, not measured
traffic or a physical-port inventory. Generic hardwareBrightness1.0/hardwareContrast.75 return
success, but may be saved control values; they are not verified hardware readback when direct GETs fail.

[source, measured] Installed UI exposes available video summary beside the unavailable-DDC panel;
expanded native primary-monitor rows verified. DDCController is configured, but that alone proves no live
command/read support. Ask for Detect DDC Capabilities result in BetterDisplay Settings. Native tool
only exposes About/Quit for its menu-bar app and cannot capture/open its settings window; no bypass.
Evidence: outputs/OpenCore-displayport-reconnection-verification.json and
work/opencore-models/{displayport-monitor-probe.json,displayport-link-summary-install.log}.

## Configured provider brightness without DDC discovery [source]

2026-10-24: user identifies the primary monitor's exact model and revision and BetterDisplay keyboard routing to the
pointer display. Native settings confirm hardware0x10,configured0–100,Prefer hardware enabled,
Combined brightness active. Missing capabilities/GET failure must not prohibit supported writes.
Picture now exposes an explicit BetterDisplay automatic-brightness route when DDC discovery is
empty. Percent entry0–100, confirmation and existing identity/mutation/mode guards apply. Values
and outcomes are provider state, not physical panel verification. No default/current value or
automatic write is fabricated. Section changes stop unrelated Advanced polling; mutation feedback
uses its own feature ID. Keyboard routing remains BetterDisplay-owned; UI targets selected monitor.
That revision's exact board/panel part numbers remain unqualified. Research: current chat
outputs/monitor-investigation.md. Native Auto source selection is documented for this model;
its priority with multiple active sources and software command are not qualified.

## Visible monitor controls [source]

2026-10-24: Hardware → Displays → select a screen. Picture uses sliders and visible preset
cards with purpose, effect, useful situations and limits beside each control. Reported enum
choices retain their exact codes; input/power choices stage a request and require confirmation.
Resolution & Signal exposes searchable exact macOS rows grouped by desktop size, with current,
HiDPI/1× render/panel-pixel/inspection filters and highest-reported-Hz filtering. Reset filters
shows the complete catalog. Selecting a row never applies it; Test/Keep/Revert retain the
15-second recovery interval. Panel-pixel matches are descriptor evidence, not maximum proof.
Signal format choices have a bounded visible list; incompatible/unsafe items stay inspection-only.
Advanced shows a searchable provider definition library and visible enumerated values. A provider
definition does not prove monitor support; read errors and setup requirements remain explicit.
Provider brightness can populate a requested slider from normalized provider state, then requires
Set confirmation. It is not a physical luminance readback. Native keyboard routing remains owned
by BetterDisplay. Evidence reports may still expand; control choices do not use menu pickers.

## Advanced capability filters [source]

2026-10-24: Advanced starts at For this screen, using the selected connection’s explicit
Capabilities report and advertised DDC codes. Not confirmed holds missing evidence, including
hardware controls when DDC discovery fails. Unavailable holds explicit negative prerequisites and
failed provider value reads; failure can be transient. Other tools holds reports, protections,
configuration/recovery and dedicated controls. Scope buttons show counts; search applies within
the selected scope and clears when changing scope. A selected control explains its classification.
No-value actions are not probed with GET. Read failure hides generic writes here but does not
remove Picture’s configured brightness fallback. Provider values are not hardware measurements.
Fresh connection identity resets failure history; rereading can clear a failed check. Switching
ports must not reuse old evidence. No broad automatic probing or physical writes run on entry.
