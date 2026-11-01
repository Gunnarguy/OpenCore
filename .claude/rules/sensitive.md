---
paths:
  - "**/*"
---

# Private data

**This repository is public.** Nothing that identifies an employer, a colleague, a private
repository, a machine or a piece of hardware goes in a tracked file: not in code, not in a test
fixture, not in a comment, not in `Docs/ai/STATE.md`.

- A private value the program needs lives in `private-names.json` beside the store and is read
  through `LocalPrivateNames`. A compiled table holds only repository names `origin/main` already
  carried, and derivation reads neither that file nor the account name.
- **A missing private file must withhold, never pin.** With the repository lists unavailable, a
  repository the binary can't name is left out of a sync. It is not classified `.restricted`,
  because `.restricted` from a sync is permanent. With a complete list, an unknown repository is
  `.restricted`. An unlisted one is hidden, and no machine is probed.
- A vendor table may name a company. Nothing may say which monitor, drive or machine is the
  owner's.
- Test fixtures use made-up values: repository names, hardware IDs and UUIDs too.
- Run `script/check_sensitive.sh` before committing. The `publish-check` skill has the details.
