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
| Apple Health | `medical`, not configurable | workouts and daily step totals, synced from the app |

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

Measured on the first sync: 691 objects from 21 repositories at `--commits 40`, 16-20s `[measured]`.

Repositories only `private-names.json` can name are left out of a sync when that file is missing, and
are not marked `restricted`, because that mark can't be undone by a sync `[test]`.

## Filesystem

```bash
opencore sync files --root ~/Documents/Notes --domain personal \
                    --root ~/Work/specs      --domain work
```

`--root` and `--domain` pair up positionally, so each folder gets its own domain.

Reads known text extensions, PDF text layers and images through on-device OCR `[test]`. Office
formats are **skipped rather than half-handled**: a binary read as UTF-8 produces
plausible-looking garbage that then gets embedded, retrieved, and cited as though it were the
document.

Skips `node_modules`, `.git`, `.build`, `DerivedData` and friends `[test]`. Files over 2MB
are skipped and counted in the log rather than dropped silently.

Incremental on modification date, with the stored content hash as the backstop for a file
whose mtime lies `[source]`.

A file or folder a person drops or chooses is the exception, through `handedOver`: it ignores
`since`, because a date says nothing about whether something handed over is wanted, and the
content hash still means dropping the same file twice changes nothing `[test]`.

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

Every calendar sync walks the whole window, because the predicate selects by when an event
happens and `since` is when OpenCore last looked. `since` filters by `lastModifiedDate`, plus any
event that has entered the look-ahead since the last sync, which no modification date would reveal
`[test]`. Reminders filter the same way. An event gains a field its connector learned later only
by being read again: use **Re-read Whole Calendar** on the Sources screen, which also picks up
events a wider look-back or look-ahead setting newly reaches.

A sync nobody started never raises a permission prompt. The request does not return until someone
answers it, so it fails with `needsFirstGrant` instead, and a person syncs the source once by hand
`[test]`. EventKit's reminder fetch can answer with no list at all, and that is a failed read, not
an empty one `[test]`.

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

**Notes has not produced a record yet.** Its one real sync, on 2026-08-14, stored 0 objects, and why
is not established. Everything below has been tested against the parser with the fetch as a closure,
and none of it has read a real library `[measured]`.

A reply with no readable note is a failure, unless an incremental read saw notes and none were
newer. A header record carries how many Notes reported, how many failed and how many are locked,
because a per-note `try` that fails every time otherwise looks like an empty library `[test]`.

A read that gets some notes and misses others keeps what it read and leaves the sync date alone,
so the next read covers the same span `[test]`. A note that fails on every read holds the date on
every read and says so. That costs comparing notes already stored, since the connector reads the
whole library each time anyway. Password-protected notes are counted and never read, so they hold
nothing `[test]`. They arrive by Re-read All Notes after the lock comes off. Whether removing a lock
changes a note's modification date, which would bring it in on an ordinary sync, is not established.
The script's use of `password protected` compiles against the macOS 27 dictionary and has never run
against a real library `[source]`.

Domain comes from the folder name. A word that closes a note (medical, financial, or one that says
a folder is private) matches anywhere in the name, and a word that opens it to a project query has to
be a whole word, so "Passcodes" and "Workouts" are `personal` `[test]`.

## When a sync runs

Calendar and Reminders can only be read by the app, so they stay fresh only while it runs. The app
schedules a tick with `NSBackgroundActivityScheduler`, and `SyncSchedule` decides what is due:
hourly for Calendar and Reminders, six-hourly for Notes, repository documents, agent memories and
GitHub. Both intervals are chosen. A tick with nothing due costs nothing `[test]`.

Notes stays off that schedule until a read someone started has brought something back, whatever the
setting says. Its first read raises an Automation prompt, and a never-run job would otherwise start
20 s after launch with nobody there `[test]`.

Two rules hold for every connector, in the app and the CLI, because both go through `SourceSync`:

- `last_synced` is the moment the read **began**, so a change made during a read is picked up by
  the next one `[test]`.
- It moves only when the read reached everything. A fetch that throws, an empty first or full read,
  and a read that fell short all leave it where it was. A connector says it fell short through
  `ConnectorBatch.unread`, and what it did read is kept `[test]`. Something left out on purpose
  belongs in `log` instead, or it holds the date forever. That covers a root that is not there, a
  file or folder that can't be opened, and repositories withheld because the private list is
  unavailable. A `[test]` label here stops at `SourceSync`: `GitHubConnector` and
  `MCPClientConnector` report no shortfall, which loses nothing today, because GitHub's `try?` reads
  are not gated by the date and MCP's fetch ignores it `[source]`.

Inside one app process, one sync runs at a time. `SyncCoordinator` refuses a sync that would overlap,
and says why if a person started it. A scheduled pass and the syncs inside it count as one `[test]`.
It is per-process and app-only, so a CLI sync or `opencore daemon` can overlap an app pass `[source]`.

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
   syncs expensive enough that the user stops running them: `IngestPipeline.run` derives from
   every object it is handed, whether or not it changed.
6. **Report what you skipped.** Counts of skipped files or unparseable records go through
   `log`. Silent truncation reads as "there was nothing there".
