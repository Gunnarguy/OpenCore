---
name: safe-rebuild
description: Rebuild OpenCore's derived layers without risking the store. Rehearse on a copy, read the difference, then apply only on the owner's word. Use whenever derived layers look wrong, after an extraction rule changes, or when someone says rebuild, re-derive or replay.
---

# Safe rebuild

`opencore rebuild` never touches the store it is pointed at. It copies it, re-derives the copy,
carries across what derivation cannot produce, and reports the difference by id. Only
`--apply-rehearsal` changes anything, and that step is the owner's.

Reviewed on 2026-10-31 and proved on a copy, with a stale refusal, a swap, a correction and a second
rehearsal that found 0 changes. It has never been applied to the live store, and that stays the
owner's decision.

## Steps

1. **Rehearse.** A rehearsal needs about twice the store's size, so read `~/.agents/STORAGE.md`
   first. On a throwaway copy, use `--work-dir` under `/private/tmp`:
   ```bash
   /private/tmp/opencore-build/out/Products/Debug/opencore rebuild --work-dir /private/tmp/opencore-rehearsal
   ```
   Add `--db /private/tmp/opencore-copy/store.sqlite3` to start from a copy made with `store-copy`.
2. **Read the report.** It is printed and saved as `rebuild-report.json` beside the two copies.

   | Line | Must be | Why |
   |---|---|---|
   | domains raised | 0 | Anything else blocks the apply, with no override |
   | claim rows dropped | 0 | A row may be retired, never deleted |
   | corrections kept | all | Corrections are the user speaking |
   | corrections undone | 0 | A value the owner corrected would be current again. Anything else blocks |
   | trace broken | 0 | Every receipt's real trace is run. Anything else blocks the apply |
   | contradiction rows lost, belief versions lost | 0 | A change of mind is never deleted, and a recorded version keeps its decision time. Anything else blocks |
   | beliefs changed, beliefs added | read each one | This is the point of the exercise. Each line should be explainable |
   | unexplained changes | 0 | `--explain DIR` lists every change by id and reason |

3. **Show the owner the changed beliefs.** Applying is their decision. Never apply on an agent's
   judgement, and never to the live store from a test.
4. **Apply**, only on their word:
   ```bash
   /private/tmp/opencore-build/out/Products/Debug/opencore rebuild --apply-rehearsal /path/to/rehearsal
   ```
   It refuses if the store moved after the rehearsal (rehearse again) or if the report has
   blockers. The apply is one transaction, so running `opencore mcp` processes see the old graph
   or the new one, never half of each.
5. **The way back** is `before-apply-*.sqlite3` in the rehearsal directory, a proved copy of the store
   from the moment before the apply. Restoring it means quitting every process that has the store open,
   which is the owner's step.

## What not to do

- Do not call `Store.dropDerivedLayers()` to get around a refusal. It refuses because something
  on that store cannot survive a drop.
- Do not replace the database file. Open `opencore mcp` processes would keep reading the old inode.
- Do not delete a rehearsal directory until the owner has confirmed the result is good.
