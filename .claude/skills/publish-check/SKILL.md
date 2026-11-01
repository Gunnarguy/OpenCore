---
name: publish-check
description: Check OpenCore for private names and credentials before committing or pushing, and report which unpushed commits still contain them. Use before any commit, push, or when someone asks whether the repository is safe to publish. OpenCore is a public repository.
---

# Publish check

OpenCore is public. Employer names, private repository names, hardware serials and home paths have
reached tracked files before, and `Docs/ai/DECISIONS.md` records how.

```bash
script/check_sensitive.sh             # the working tree and any staged change
script/check_sensitive.sh --staged    # the whole index, which is the next commit's tree
script/check_sensitive.sh --history   # commits in origin/main..HEAD that contain a private term
```

Exit 0 means clean, 1 means a hit, and 2 means the check could not run, which is never clean. It
prints each hit as `path:line:text`, and `path: file name` for a term in a name.

- **Private terms** are the union of two gitignored files: `Local/sensitive-terms.txt`, one fixed
  string per line, and every name in `Local/private-names.json`. Hardware and machine names go in
  the terms file. A name from the private file is skipped when `origin/main` already holds it or it
  is under four characters, and the script prints the skipped names. A name in the terms file is
  never skipped. Without either file only the generic scan runs, and the script says so. A clean
  result then means less.
- **Matching** ignores case. Six or more characters match anywhere. Shorter terms match where a
  token starts and ends, including inside `camelCase` and `snake_case`.
- **The generic scan** looks for credential shapes and real home paths. Binary files are skipped.
- **`--staged` fails until the fixes are staged**, because the index still holds what `HEAD` holds.
- **A false positive** goes in the gitignored `Local/sensitive-allow.txt` as `path:text`, and is
  skipped when that file's line contains that text.

## A hit

1. A value the program needs goes in `private-names.json` beside the store, never in a tracked
   file. `Docs/private-names.example.json` shows the shape. Without that file a repository is left
   out of a sync, never marked `.restricted`, because that mark can't be undone by a sync.
2. A test fixture uses a made-up value, including hardware IDs and UUIDs.
3. A doc says what is true without the private value.

## History

`--history` reads file contents, file names, commit messages and author fields. It reports and
changes nothing. Forward fixes leave the old text in history, so a term in
an unpushed commit should be fixed inside that commit before the push. Rewriting history is the
owner's decision, always.
