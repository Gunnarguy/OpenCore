---
name: project-handoff
description: Update Docs/ai/STATE.md so a fresh session can continue OpenCore without this transcript. Use before ending substantial unfinished work, before a compaction when feasible, and after any change of objective.
---

# Handoff

The test this must pass: **a fresh session reading only `STATE.md` can take the next action
correctly.** Not "can understand what happened" — can act.

## Steps

1. **Identify the active objective.** If it changed during this session, replace the old one.
   Do not append a second objective; STATE holds exactly one.
2. **Inspect actual state**, do not recall it:
   ```bash
   git status --porcelain && git rev-parse --short HEAD && git rev-parse --abbrev-ref HEAD
   ```
   Uncommitted changes that are part of the objective must be listed by path.
3. **Record verification honestly.** Command to result, with the date. If tests were not run
   this session, say when they last were. **Never write that something passed unless you ran it
   and read the output.**
4. **Capture blockers and unknowns with a verification path**, not just the doubt:
   ```
   Unknown: whether the Notes connector works against a real library.
   Verify: run `opencore sync notes` and grant Automation when prompted.
   ```
5. **Move durable rationale out.** If this session decided something whose reasoning the code
   cannot show, append it to `Docs/ai/DECISIONS.md` — date, decision, context, alternatives,
   rationale, consequences. STATE is execution state, not history.
6. **Update the Notion roadmap** if a row's status or evidence level changed. Roadmap truth is
   Notion, not `Docs/ROADMAP.md`. Never upgrade an evidence level without having done the thing.
7. **Write the exact next action.** One executable step. "Continue the MCP client" is not an
   action; "create `Sources/CoreIngest/MCPClientConnector.swift` conforming to `Connector`,
   reusing `JSONValue` from `CoreMCP`" is.
8. **Delete what is now stale.** STATE is maintained in place, not appended to. Aim under ~150
   lines.

## Finally

Reread STATE as though you had never seen this conversation. If any line only makes sense
because you were here, rewrite it.
