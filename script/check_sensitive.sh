#!/usr/bin/env bash
# Fails when a private term or a credential-shaped string reaches a file git would publish.
#
#   script/check_sensitive.sh             the working tree (tracked and new, not ignored) and
#                                         any staged change: what `git add -A` would publish
#   script/check_sensitive.sh --staged    the whole index, which is the next commit's tree
#   script/check_sensitive.sh --history [RANGE]   list commits in RANGE (default origin/main..HEAD)
#                                         with a private term in a file, a file name, the commit
#                                         message or the author fields; reports, never rewrites
#
# Exit 0 is clean, 1 is a hit, 2 means the check could not run. A failed scan is never clean.
#
# Private terms are the union of two gitignored files: Local/sensitive-terms.txt, one fixed string
# per line with `#` starting a comment, and every name in Local/private-names.json. A name from
# that file that origin/main already holds, or that is under four characters, is skipped; put it
# in the terms file to scan it anyway. Matching ignores case. A term of six or more characters
# matches anywhere, and a shorter one only where a token starts and ends, so it finds
# `quokkaTool` and `quokka_x` and leaves `cleanObj` alone. Without either file only the generic
# scan runs, and the script says so rather than passing quietly.
#
# Binary files are skipped. A credential inside one is not found.
#
# Local/sensitive-allow.txt (also gitignored) lists `path:text` entries: a hit in that file whose
# line contains that text is not reported. Use it for a known false positive. Nothing installs
# this as a git hook: run it before committing.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
python3 script/check_sensitive.py "$@"
status=$?
# A missing or crashed interpreter is not a hit and it is not clean.
if [[ "$status" != 0 && "$status" != 1 ]]; then
  [[ "$status" == 2 ]] || echo "sensitive check could not run: python3 exited $status"
  exit 2
fi
exit "$status"
