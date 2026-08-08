# Connectors

A connector produces `CoreObject`s and nothing else. It never writes claims, resolves
entities, or decides what anything means. That separation is what makes the derived layers
rebuildable: if claim extraction is wrong, it reruns over objects already on disk instead
of re-fetching from a rate-limited API or a permission-gated framework.

Every claim below is labelled `[measured]`, `[test]`, `[source]` or `[design]`.

---

## Domain assignment

This is the decision that matters most, because it determines what a question can ever
reach. Each connector assigns a `Domain` per object, and the admission policy applies it
before any ranking happens.

| Source | Domain | Why |
|---|---|---|
| GitHub, public repo | `public` | already published |
| GitHub, private repo | `project` | working context |
| Filesystem | **per root folder** | you choose it when adding the folder |
| Calendar | `personal` | see below |
| Reminders | `personal` | see below |
| Notes | **per folder name**, defaulting to `personal` | `[source]` `AppleNotesConnector.domain(forFolder:)` |

Calendar and Reminders are `personal` and not configurable. A calendar is the single
richest source of who you meet, when you are ill, and who you are close to, and it arrives
looking like harmless scheduling metadata. Treating it as project data because it mentions
a repo name would be the exact mistake this system exists to avoid.

Notes folder mapping errs toward the **more** restrictive domain `[test]`. Over-tagging a
note as medical hides it from a project query, which is a mild annoyance. Under-tagging
leaks it into one, which is the failure the firewall exists to prevent.

---

## GitHub

```bash
opencore sync github [--login NAME] [--commits N] [--include-forks]
```

Credential order: `--token`, then `GITHUB_TOKEN`, then `gh auth token` from an already
authenticated CLI `[source]`. Nothing is ever written to the repo.

Produces four object kinds: `repository`, `commit`, a `file` holding the language
breakdown, and a `document` holding the README. The README is deliberately a **separate
object from the repository**, because a README claiming something the code contradicts is
the flagship case for contradiction detection `[design]`.

Measured: 691 objects from 21 repositories at `--commits 40`, 16-20s `[measured]`.

## Filesystem

```bash
opencore sync files --root ~/Documents/Notes --domain personal \
                    --root ~/Work/specs      --domain work
```

`--root` and `--domain` pair up positionally, so each folder gets its own domain.

Reads only known text extensions `[test]`. PDF and Office formats are **skipped rather
than half-handled**: a PDF read as UTF-8 produces plausible-looking garbage that then gets
embedded, retrieved, and cited as though it were the document. Extraction is a roadmap
item, not a silent best-effort.

Skips `node_modules`, `.git`, `.build`, `DerivedData` and friends `[test]`. Files over 2MB
are skipped and counted in the log rather than dropped silently.

Incremental on modification date, with the stored content hash as the backstop for a file
whose mtime lies `[source]`.

## Calendar and Reminders

```bash
opencore sync calendar     # from the app; see below
opencore sync reminders
```

EventKit reads usage strings from the **calling binary's** `Info.plist`. The app bundle
has them; a SwiftPM executable does not, so from the CLI these requests are denied by TCC
with no prompt ever appearing.

That failure is detected and reported as itself `[source]` — `AccessError.noInfoPlist` —
rather than returning zero events, which is indistinguishable from an empty calendar.
**Run Calendar and Reminders sync from the OpenCore app.**

Calendar is fetched in yearly windows because EventKit caps a single predicate at roughly
four years and silently truncates beyond it `[source]`.

## Apple Notes

```bash
opencore sync notes
```

Notes has no public API. AppleScript is the only supported way in, and it is genuinely
unpleasant: it needs an Automation grant, it is slow on large libraries, and Apple has
changed the dictionary between releases before.

All of that is confined to `AppleNotesConnector.swift` on purpose. It sits behind the same
`Connector` protocol as everything else, so when Notes gets a real API, or when this breaks
on some future macOS, exactly one file changes.

Two details that are load-bearing `[source]`:

- Records are separated by ASCII 30 and fields by ASCII 31, from the C0 control block.
  Splitting on a comma or newline would corrupt every note containing one, which is all
  of them.
- stdout and stderr are drained **concurrently** with waiting for the process. A note
  library larger than the 64KB pipe buffer deadlocks if you wait first and read after.

TCC denial returns error `-1743`, which is mapped to a clear message rather than a raw
AppleScript error `[source]`.

---

## Writing a new connector

```swift
public struct MyConnector: Connector {
    public let source: Source
    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void)
        async throws -> ConnectorBatch
}
```

Rules, in order of how much trouble breaking them causes:

1. **Produce objects only.** No claims, no entities, no interpretation.
2. **Set `authority` honestly.** A commit is an `authoredArtifact`. A generated summary is
   a `generatedSummary`. Nothing a connector produces is a `directStatement`; that tier is
   reserved for the user telling OpenCore something.
3. **Set `domain` conservatively.** When unsure, pick the more restrictive one.
4. **Make `externalID` stable across syncs.** It is half the object's identity, so an id
   that changes creates a duplicate rather than an update.
5. **Honour `since`.** A connector that re-fetches everything works, but makes routine
   syncs expensive enough that the user stops running them.
6. **Report what you skipped.** Counts of skipped files or unparseable records go through
   `log`. Silent truncation reads as "there was nothing there".
