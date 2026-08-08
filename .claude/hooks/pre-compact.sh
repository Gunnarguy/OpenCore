#!/bin/bash
# PreCompact — checkpoint reminder, not a transcript archive.
#
# Compaction is about to discard detail. If there is unfinished work in the tree and the
# handoff has not been refreshed, say so once. This NEVER blocks compaction: a context system
# that prevents compaction until the window fails is worse than one that writes a good
# checkpoint and moves on.
#
# Read-only. No network.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

STATE="Docs/ai/STATE.md"
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

[ "${DIRTY:-0}" -eq 0 ] && exit 0

echo "Compacting with ${DIRTY} uncommitted file(s)."
echo "Before detail is lost, make sure ${STATE} carries: the current objective, what was"
echo "actually verified (command -> result), open blockers, and one exact next action."
echo "Any decision made this session whose rationale the code cannot show belongs in"
echo "Docs/ai/DECISIONS.md. The project-handoff skill does all of this."
exit 0
