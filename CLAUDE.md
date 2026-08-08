# OpenCore — Repository Operating Protocol

An evidence-native store for personal history. Swift 6, SwiftPM engine plus an XcodeGen'd
macOS app. Zero external dependencies, deliberately.

Read `Docs/ARCHITECTURE.md` before changing anything in `CoreGraph` or `CoreStore`.

## Before your first action

1. **This repo lives in iCloud-synced `~/Documents`.** Two failure modes look like code bugs:
   - `.git` is a file pointing at `.git.nosync`. That is on purpose, to keep the object store
     out of iCloud after it corrupted a sibling repo's index. Do not "fix" it.
   - Always build with `--scratch-path` / `-derivedDataPath` **outside `~/Documents`**. iCloud
     stamps extended attributes on build inputs and `codesign` rejects them.
     Use `/private/tmp/opencore-build`.
   - Nonsensical duplicate-symbol errors usually mean iCloud wrote `Foo 2.swift`. Look for it
     before debugging the code.

2. **Xcode is at `/Applications/Xcode-beta.app`.** Prefix builds with
   `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Non-negotiables

These are the project's whole thesis. A change that breaks one is wrong even if it compiles.

- **Objects are the floor.** Nothing derived may be the only copy of anything. If a change
  makes `opencore rebuild` unable to reconstruct a layer, the change is wrong.
- **Never delete to record a change of mind.** Retraction and supersession are columns.
- **Authority never multiplies.** It is an ordinal tier. If you find yourself writing
  `confidence * authority`, stop — that is the exact mistake the type prevents.
- **Unmeasured stays `nil`.** Never write a plausible default into a receipt field. "not
  measured" is the correct rendering and it is load-bearing.
- **Only functional predicates contradict.** Widening that set manufactures conflicts out of
  ordinary multi-valued data.
- **Every SQL string lives in `CoreStore`.** If a layer above it needs data, add a typed method
  there rather than reaching into the database.
- **Connectors produce objects and nothing else.** No claims, no entities, no interpretation.
- **Counter-evidence is a row**, never an absence.

## Documentation discipline

- Every claim in `Docs/` carries `[measured]`, `[test]`, `[source]` or `[design]`. Do not
  upgrade a label without actually doing the thing.
- The README's "What is not true yet" section is not a disclaimer to trim. It is the point.
  Add to it when you find a new limitation.
- Never quote an accuracy number. None has been measured. When one exists it comes from the
  eval harness in `Docs/ROADMAP.md` v0.2 and it carries its corpus and date.
- A bug found and fixed gets a regression test that names the original failure in a comment.
  See the OpenClinic domain-classification test for the pattern.

## Commands

Verified in this repository:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --scratch-path /private/tmp/opencore-build
```

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /private/tmp/opencore-build
```

```bash
cd Apps/OpenCoreMac && xcodegen generate
```

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Apps/OpenCoreMac/OpenCore.xcodeproj -scheme OpenCore -derivedDataPath /private/tmp/opencore-app-dd -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- build
```

The built CLI lands at `/private/tmp/opencore-build/out/Products/Debug/opencore`, not
`.build/debug/`, when using `--scratch-path`.

## Working style

- Say plainly when something is unverified rather than hedging.
- Verify root causes before claiming them. Find the line that makes it true.
- Do not commit or push unless asked.
- No em-dashes in user-facing text.
