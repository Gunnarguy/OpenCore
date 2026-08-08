---
paths:
  - "Sources/CoreIngest/**/*.swift"
---

# Connector rules

**A connector produces `CoreObject`s and nothing else.** No claims, no entities, no
interpretation. That separation is what makes derived layers rebuildable: if extraction is
wrong, it reruns over objects already on disk instead of re-fetching from a rate-limited API or
a permission-gated framework.

## Required of every connector

1. **`externalID` must be stable across syncs.** It is half the object's identity, so an id
   that changes creates a duplicate instead of an update.
2. **Set `authority` honestly.** A commit is `.authoredArtifact`. A generated summary is
   `.generatedSummary`. Nothing a connector produces is ever `.directStatement` — that tier is
   reserved for the user telling OpenCore something.
3. **Set `domain` conservatively.** When unsure, pick the more restrictive one. Over-tagging
   hides data from a query, which is an annoyance. Under-tagging leaks it, which is the failure
   the firewall exists to prevent.
4. **Honour `since`.** A connector that re-fetches everything works but makes routine syncs
   expensive enough that the user stops running them.
5. **Report what you skipped** through `log`. Silent truncation reads as "there was nothing
   there".

## Do not half-handle a format

A PDF decoded as UTF-8 becomes plausible-looking garbage that then gets embedded, retrieved, and
cited as though it were the document. Skip what you cannot read properly and say so.

## Credentials

Never write a credential to the store, the repo, or a log line. Resolve from the environment or
the system keychain at call time. `GitHubConnector.resolveToken` is the pattern: explicit
argument, then `GITHUB_TOKEN`, then the already-authenticated `gh` CLI.

## Platform permissions

EventKit reads usage strings from the **calling binary's** `Info.plist`. A SwiftPM executable
has none, so requests are denied by TCC with no prompt. Detect that specific case and report it
as itself, never as an empty result — an empty calendar and a denied permission look identical
otherwise.
