---
name: project-context-audit
description: Find and repair drift between OpenCore's durable context and repository reality. Use periodically, after a large refactor, when resuming a long-idle branch, or when a document and the code appear to disagree.
---

# Context audit

Context entropy is the failure mode this whole system exists to prevent, and it is also the one
this project has already been bitten by: two full sessions of OpenIntelligence work went to
removing twelve user-facing claims the code no longer supported. Run this before that happens
here.

## Check

**Staleness**
- Does `STATE.md` name files that no longer exist?
- Is its recorded HEAD far behind the current branch?
- Does its objective match what the repository actually shows in progress?
- Do `RUNBOOK.md` commands still work? Re-run any marked verified that look suspect.
- Does `Docs/ARCHITECTURE.md` describe a component that was removed or renamed?

**Contradiction**
- Any `[measured]` claim whose measurement no longer holds after a change?
- Any accuracy or performance number quoted anywhere? There must be none until the eval
  harness exists.
- Does `CLAUDE.md` contradict a `.claude/rules/` file?
- Does auto memory contradict version-controlled truth? Version control wins; fix the memory.
- Do the Notion roadmap and the code disagree about what shipped? **Both directions are
  possible** — the repo has been the stale side before.

**Duplication**
- The same fact in two places, with no operational reason. Pick the home from the routing
  table in `CLAUDE.md` and delete the other copy.
- `CLAUDE.md` growing past ~150 lines. Move detail into rules, skills, or `Docs/ai/`.
- An unconditional rule that should carry `paths` frontmatter.

**Drift specific to this project**
- A constant that lost its "chosen, not measured" comment. That comment is load-bearing.
- A receipt field that acquired a default where it should be `nil`.
- SQL that escaped `CoreStore`.
- A `print` anywhere reachable from `opencore mcp`.
- A derivation stage added outside `IngestPipeline`.

**Safety**
- Any credential, token, or `.env` value in a tracked file, in `Docs/`, or in memory.
- Any hook that became destructive or gained network access.

## Repair

Fix what the evidence makes unambiguous, directly. For anything ambiguous, write the
uncertainty with its verification path rather than guessing:

```
Unknown: whether PassageSearch's 0.02 signal scaling is still appropriate after chunking changed.
Verify: eval harness, once it exists. Until then it stays labelled as chosen.
```

Never turn uncertainty into invented project history.

## Report

What was repaired, what remains ambiguous, and whether `Docs/ai/INDEX.md`'s audit date should
be updated. Update it only if the audit was genuinely completed.
