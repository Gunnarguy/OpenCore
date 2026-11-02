---
paths:
  - "Apps/OpenCoreMac/**"
---

# App rules

The app has **no test target**. A behaviour that matters goes in a package module, where it can be
tested, and the view calls it. `SourceSync`, `SyncSchedule`, `Answer.shortcutText` and
`Conversation.replayedExchanges` were all moved out of the app for this reason. A statement about a
view is `[source]` until someone has run it.

## Building

- Build only with `./script/build_and_run.sh --build-only`. It stages source outside iCloud. `--verify`
  also replaces `/Applications/OpenCore.app` and launches it, so that is the owner's step.
- `.xcodeproj` is generated from `project.yml`. A new file is not in the build until `xcodegen` runs,
  which `build_and_run.sh` does for you, and a hand edit is lost.
- Launching the app with `sync.scheduled` on starts a sync pass about 20 s later, against the live store.

## Sections

The app is three places: Ask, Mac and Evidence, plus Settings. A new `Section` needs an entry in
`WorkspaceFamily.sections`. Miss it and it vanishes with no compile error. Add to Ask last: it is the
first screen, and its job is one box and the owner's day.

## Data and failures

- SQL stays in `CoreStore`. A view that needs data calls a typed method through `AppModel`.
- Long work goes through `AppModel`'s state. A failure goes to `failure`, and `FailureBanner` keeps it
  until dismissed, so nothing that starts new work may clear it silently.
- Sync goes through `exclusively`, `SourceSync` and `SyncCoordinator`. A second path that marks a source
  synced is how dates get poisoned.
- An ObjC completion handler can inherit `@MainActor` from its context and trap at run time. Read the
  SDK header for `NS_SWIFT_SENDABLE` before hopping actors in one. Blocking work leaves the main actor
  with `Task.detached`.
- A setting's `didSet` does not fire in `init`, so a side effect tied to it has to run at launch too.

## Models and privacy

- Local-first is the default. `Receipt.objectsTransmitted` must stay true of whichever path answered.
- Spotlight and App Intents are readable by other processes, so they get what an MCP caller could read:
  `[.project, .publicRecord]`, and `externalCaller: true`.
