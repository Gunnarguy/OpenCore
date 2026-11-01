---
name: verify-release
description: Prove an OpenCore change and judge whether the tree is ready to commit or install. Use before saying anything is done, before a commit, before installing the app or CLI, or when someone asks whether it builds, passes, or is safe to ship.
---

# Verify and release readiness

Report only what you ran and read. A label is earned by doing the thing.

## Verify

```bash
pgrep -f swift-build                    # must print nothing: one build at a time
swift build --scratch-path /private/tmp/opencore-build && swift test --scratch-path /private/tmp/opencore-build
```

App files changed: `./script/build_and_run.sh --build-only`, then look for `BUILD SUCCEEDED`.

Read the `Test run with` lines, one per binary, and add them up. `swift test` printing a failure in the
last binary with earlier ones green is a failure. Each binary also prints `Executed 0 tests` from XCTest,
which means nothing.

**A test that touches the clock or a date gets run more than once.** Repeat it with `--filter NAME
--skip-build`. A date compared after a trip through the store fails about half the time if the fixture
came from `Date()`, and one such test once read as passing.

A behaviour change needs its test proved: disable the change with a small reversible edit, watch the
named test fail, restore the edit, confirm the file's hash. Never use `git checkout` or `git stash` on a
file for this, because the tree can hold uncommitted work.

## Ready to commit

```bash
script/check_sensitive.sh                 # exit 0 needed; 2 means it could not run, which is not clean
python3 script/codemap.py affected        # refresh any slice this change made stale
```

Then `Docs/ai/STATE.md` and the Notion row. See `publish-check` for a hit. Commit only on the owner's word.

## Ready to install

Installing is the owner's step, because it changes what clients and the live store run.

| Check | Why |
|---|---|
| `--apply-rehearsal` not needed by this change, or already read | Rebuild is its own decision, see `safe-rebuild` |
| No migration, or one that is additive and registered in `Database.migrations` | Older `opencore mcp` binaries keep opening the store |
| `Local/private-names.json` installed beside the store | Without it repositories are left out of a sync and the Hub reads as not running |
| The owner knows scheduled sync starts about 20 s after launch | That is when the live store starts changing |

```bash
./script/build_and_run.sh --verify        # replaces /Applications/OpenCore.app and launches it
```

The CLI is separate, and `Docs/ai/RUNBOOK.md` has the install. Clients keep the old binary until they
reconnect, so a change has not reached MCP until then.

## Say plainly

Not launched, not installed, not applied: name each one that is true. "Builds" says nothing about a
screen, and a test with the fetch as a closure says nothing about a real Notes library.
