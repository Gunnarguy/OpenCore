#!/bin/bash
# Stop — handoff safety net.
#
# Fires when substantive source changes exist but Docs/ai/STATE.md was not touched. Asks for
# ONE bounded repair, then never again for that stop.
#
# Recursion protection is the whole risk here: stop_hook_active is true when Claude is already
# continuing because of this hook. Exiting 0 in that case is what prevents an infinite loop.
#
# Read-only. Non-destructive. Never blocks the user indefinitely.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

INPUT=""
[ ! -t 0 ] && INPUT=$(cat 2>/dev/null || true)

# Already looping. Let it stop.
case "$INPUT" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;;
esac

STATE="Docs/ai/STATE.md"

# Only source and schema changes count as substantive. Doc-only edits, and edits to STATE
# itself, are not work that needs a handoff.
CHANGED=$(git status --porcelain 2>/dev/null \
  | awk '{ $1=""; sub(/^ +/, ""); print }' \
  | grep -E '^(Sources/|Tests/|Apps/|Package\.swift)' \
  | wc -l | tr -d ' ')

[ "${CHANGED:-0}" -eq 0 ] && exit 0

# Was STATE.md updated alongside that work, either staged/unstaged or in the last commit?
STATE_DIRTY=$(git status --porcelain -- "$STATE" 2>/dev/null | wc -l | tr -d ' ')
STATE_RECENT=$(git log -1 --name-only --format= 2>/dev/null | grep -cx "$STATE" || true)

if [ "${STATE_DIRTY:-0}" -gt 0 ] || [ "${STATE_RECENT:-0}" -gt 0 ]; then
  exit 0
fi

# Ask for exactly one repair pass.
cat <<JSON
{
  "decision": "block",
  "reason": "${CHANGED} source file(s) changed but ${STATE} was not updated. Run the project-handoff skill: set the current objective, record what you actually verified (command -> result, nothing you did not run), list open blockers with a verification path, and write one exact next action. Then stop. If this work is genuinely trivial or purely exploratory, say so in one line and stop without editing STATE."
}
JSON
exit 0
