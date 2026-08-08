---
name: project-orient
description: Reconstruct task-relevant OpenCore context without loading the repository into the main conversation. Use at the start of substantive work, when resuming after /clear or a compaction, or when a request touches an area you have not read yet.
---

# Orient

Produce a compact orientation for one task. **Not a repository encyclopedia.**

## Steps

1. **Read `Docs/ai/STATE.md`.** Note the objective, the exact next action, and anything in
   Blockers / Unknowns.
2. **Decide whether the user's request supersedes the recorded objective.** If it does, say so
   explicitly — STATE will need updating at handoff, and continuing against a stale objective
   is the main way these systems mislead.
3. **Delegate the repository reading.** Use an Explore subagent for anything broader than two
   or three known files. The point is keeping intermediate exploration out of this context.
   Scope it to the task: name the modules, do not ask for a survey.
4. **Load durable docs only as the task requires**, per `Docs/ai/INDEX.md`:
   - touching `CoreGraph` / `CoreStore` / retrieval → `Docs/ARCHITECTURE.md`
   - a data source → `Docs/CONNECTORS.md`
   - `CoreMCP` → `Docs/MCP.md`
   - something that looks arbitrary → `Docs/ai/DECISIONS.md` before changing it
5. **Resolve conflicts against evidence.** Source, tests and configuration outrank every
   document. A doc that disagrees with the code is a bug to fix, and fixing it is part of the
   work, not a follow-up.
6. **Check the constraints that most often get violated**, from `CLAUDE.md`: objects are the
   floor, authority never multiplies, unmeasured stays nil, SQL lives in `CoreStore`, stdout is
   sacred in `CoreMCP`.

## Return

Six short sections, nothing else:

- **Objective** — this task, and whether it supersedes STATE's
- **Relevant architecture** — only the parts that bear on it
- **Files likely involved** — path plus one clause on why
- **Constraints** — the invariants this task could violate
- **Risks** — what would break quietly rather than loudly
- **Recommended next action** — one concrete step

If the task is small and obviously scoped, say so and return three lines. Orientation that
costs more than the task is a net loss.
