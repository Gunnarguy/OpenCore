#!/bin/bash
# SessionStart — bounded orientation.
#
# Prints repository identity, git state, and the recorded objective and next action.
# Deliberately does NOT dump project documents into startup context: it points at
# Docs/ai/STATE.md rather than reproducing it.
#
# Read-only. No network. Never fails the session: every failure path exits 0.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

STATE="Docs/ai/STATE.md"

# `source` is one of startup, resume, clear, compact, fork. Keep resumed sessions quiet:
# they already have the context, and re-printing it is pure noise.
SOURCE=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
  SOURCE=$(printf '%s' "$INPUT" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
case "$SOURCE" in
  resume|compact) exit 0 ;;
esac

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

echo "OpenCore | ${BRANCH} @ ${HEAD} | ${DIRTY} uncommitted file(s)"

if [ ! -f "$STATE" ]; then
  echo "No ${STATE}. Run the project-handoff skill before ending substantial work."
  exit 0
fi

# Staleness: does the commit STATE was written against still exist in history, and how far
# behind is it? A large gap means the handoff describes a repository that has moved on.
RECORDED=$(sed -n 's/^Last verified commit:[[:space:]]*`\{0,1\}\([0-9a-f]\{7,40\}\)`\{0,1\}.*/\1/p' "$STATE" | head -1)
if [ -n "$RECORDED" ]; then
  if git cat-file -e "${RECORDED}^{commit}" 2>/dev/null; then
    BEHIND=$(git rev-list --count "${RECORDED}..HEAD" 2>/dev/null || echo 0)
    if [ "${BEHIND:-0}" -gt 0 ]; then
      echo "WARNING: STATE.md was written at ${RECORDED}, HEAD is ${BEHIND} commit(s) ahead. Treat it as possibly stale."
    fi
  else
    echo "WARNING: STATE.md references commit ${RECORDED}, which is not in this history."
  fi
fi

# Collapse a section to one line, cut at a word boundary so it never ends mid-word.
section() {
  awk -v want="$1" '
    $0 ~ "^## " want "$" { flag = 1; next }
    /^## / { flag = 0 }
    flag && NF { printf "%s ", $0 }
  ' "$STATE" 2>/dev/null \
    | tr -s ' ' \
    | awk '{ if (length($0) > 170) { s = substr($0, 1, 170); sub(/[^ ]*$/, "", s); print s "..." } else print }'
}

OBJECTIVE=$(section "Objective")
NEXT=$(section "Exact Next Action")

[ -n "$OBJECTIVE" ] && echo "Objective: ${OBJECTIVE}"
[ -n "$NEXT" ] && echo "Next: ${NEXT}"

echo "Read ${STATE} before substantive work. Docs/ai/INDEX.md says which doc answers what."
exit 0
