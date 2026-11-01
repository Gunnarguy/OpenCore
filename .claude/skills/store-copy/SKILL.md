---
name: store-copy
description: Measure OpenCore against a private copy of the real store, without touching the live one. Use to test a change on real shapes, compare before and after, reproduce a wrong answer, or get a number for a claim in a document.
---

# Measure on a store copy

Tests use temporary stores. Real shapes come from a copy. **Never point a command that writes at the
live store**: `~/Library/Application Support/OpenCore/opencore.sqlite3`.

## Make the copy

The store is about 100 MB. Read `~/.agents/STORAGE.md` if the disk is low.

```bash
LIVE="$HOME/Library/Application Support/OpenCore/opencore.sqlite3"
mkdir -p /private/tmp/opencore-copy
sqlite3 "file:$LIVE?mode=ro" ".backup '/private/tmp/opencore-copy/store.sqlite3'"
sqlite3 /private/tmp/opencore-copy/store.sqlite3 "pragma integrity_check;"
```

`.backup` is the consistent way to copy a store in WAL mode. A `cp` of the one file loses what is in the
WAL. Read the live store directly only with `sqlite3 "file:$LIVE?mode=ro"`.

## Run against it

Every command takes `--db`. Binary from the last build:

```bash
OC=/private/tmp/opencore-build/out/Products/Debug/opencore
DB=/private/tmp/opencore-copy/store.sqlite3
$OC doctor --db $DB
$OC ask --db $DB "What was I working on recently?"
```

Compare `shasum "$LIVE"` before and after a session, so "the live store was not touched" is a measurement.
It can change on its own if the app or a sync is running.

## Before and after

Answers that differ between processes are a finding, so run a question in several fresh processes and
count distinct outputs:

```bash
for i in $(seq 12); do $OC ask --db $DB "QUESTION" 2>/dev/null | sed '/^── receipt/,$d' | shasum; done | sort -u | wc -l
```

The `sed` cuts everything from the receipt line down, because a receipt's code and timings differ on
every run. Without it every run counts as distinct.

For a rebuild, use `safe-rebuild` and pass `--db` so the rehearsal starts from the copy.

## Limits of a copy

- `private-names.json` is read from beside the store, so results depend on whether it is installed there.
- A copy has no connectors behind it. Re-running the pipeline over stored objects stands in for a sync,
  and it is not a sync.
- Vectors are in the copy, and new passages have none until `embed` runs.

## Afterwards

The copy holds the owner's private history. Say what you measured, never quote its contents in a tracked
file, a test fixture or a commit, and delete it when done:

```bash
rm -rf /private/tmp/opencore-copy
```

Label the result `[measured]` with the date and that it came from a copy.
