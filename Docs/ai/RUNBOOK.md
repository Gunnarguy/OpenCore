# Runbook

Every command below is marked **verified** (run successfully in this repository, with the date)
or **unverified** (derived from configuration, never executed here). Do not promote an
unverified command without running it.

## Environment

Xcode 27 beta. Prefix every build with:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

**Build outputs must live outside `~/Documents`.** This repository is inside iCloud-synced
`~/Documents`; iCloud stamps extended attributes on build inputs and `codesign` rejects them.
Use `/private/tmp/...` for every scratch and derived-data path.

## Build and test — verified 2026-08-08

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --scratch-path /private/tmp/opencore-build
```

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /private/tmp/opencore-build
```

Expected: 24 tests pass, as two runs of 7 and 17.

The CLI binary lands at `/private/tmp/opencore-build/out/Products/Debug/opencore`, **not**
`.build/debug/`, when `--scratch-path` is used. This surprises people every time.

## macOS app — verified 2026-08-08

```bash
cd Apps/OpenCoreMac && xcodegen generate
```

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Apps/OpenCoreMac/OpenCore.xcodeproj -scheme OpenCore -configuration Debug -derivedDataPath /private/tmp/opencore-app-dd -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- build
```

The app bundle lands at `/private/tmp/opencore-app-dd/Build/Products/Debug/OpenCore.app`.

`.xcodeproj` is gitignored and regenerated from `project.yml`. Never hand-edit it.

## First run — verified 2026-08-08

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore doctor
```

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore sync github --commits 40
```

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore embed
```

Measured: 691 objects and 966 chunks from 21 repositories in 16–20s; embedding all 966 passages
took 25s on device.

Use `--db /private/tmp/opencore-demo/oc.sqlite3` on any command to work against a scratch store
instead of the real one at `~/Library/Application Support/OpenCore/opencore.sqlite3`.

## Saved chats — verified 2026-08-10

Every chat turn is written to the store as it completes, so a thread can be reopened later.

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore chats
```

Lists saved threads, most recently used first, with turn counts and the id `--resume` takes.

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore chat "FOLLOW-UP QUESTION" --resume THREAD_ID
```

Resuming restores the visible history **and** replays the exchanges into the model's
`Transcript`, so the model has the conversation rather than only the reader having it.

Verified: a thread went 2 turns to 4 on resume rather than forking a new one, and
`opencore trace <code>` now resolves a receipt printed by `chat`, which it previously could not.

**Retrieval still runs on the raw follow-up text.** "What language did you just say it uses"
retrieves nothing useful and correctly answers "the sources retrieved do not answer that". The
model has the context and is refusing to answer from memory, which is the design working;
query rewriting for follow-ups is a tracked gap, not a bug in resume.

## Claude Desktop as an MCP client — verified 2026-08-10

**The binary is not relocatable on its own.** It loads migrations from
`OpenCore_CoreStore.bundle`, which must sit beside it, or it dies with
`unable to find bundle named OpenCore_CoreStore`. Install both:

```bash
mkdir -p ~/.local/libexec/opencore && cp /private/tmp/opencore-build/out/Products/Release/opencore ~/.local/libexec/opencore/ && cp -R /private/tmp/opencore-build/out/Products/Release/OpenCore_CoreStore.bundle ~/.local/libexec/opencore/
```

Do **not** point a client at `/private/tmp/opencore-build`. That path is periodically cleaned,
and the failure arrives weeks later as a client that silently lists no tools.

Config lives at `~/Library/Application Support/Claude/claude_desktop_config.json`. Merge, never
overwrite: it also holds window state, folder grants and per-account preferences.

```json
{ "mcpServers": { "opencore": { "command": "/Users/gunnarhostetler/.local/libexec/opencore/opencore", "args": ["mcp"] } } }
```

Claude Desktop reads this only at launch, so it must be fully quit and reopened.

Verify the server by hand before blaming the client:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"core_ask","arguments":{"query":"what is OpenCore built with"}}}' | ~/.local/libexec/opencore/opencore mcp 2>/dev/null
```

Measured: negotiates the client's version, then returns 92 claims with evidence and authority.
Tool arguments are `query` for `core_ask` and `core_search`, `entity` for `core_claims`,
`receipt` for `core_trace`.

## Exercising the MCP server — verified 2026-08-08

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /private/tmp/opencore-build/out/Products/Debug/opencore mcp 2>/dev/null
```

stderr carries the logs; stdout carries only JSON-RPC. Redirecting stderr away is what makes the
output parseable.

## Recovery

**Nonsensical build failure** — duplicate symbols, "invalid redeclaration", a codesign
"resource fork ... not allowed" error. iCloud wrote a conflict copy such as `Foo 2.swift` and
the build is compiling it for real. Find and delete it:

```bash
find . -name "* 2.*" -not -path "./.git.nosync/*"
```

**Derived layers look wrong** — claims missing, contradictions absent, search returning
nothing sensible. Re-derive from objects; this never touches the floor:

```bash
/private/tmp/opencore-build/out/Products/Debug/opencore rebuild
```

Verified 2026-08-08: reproduces 966 chunks, 38 entities and 82 claims exactly. **Note it also
clears vectors**, because a chunk whose boundaries moved has a vector describing text that no
longer exists. Re-run `embed` afterwards.

**Store is corrupt or you want a clean slate** — the store is one file plus its WAL:

```bash
rm -rf ~/Library/Application\ Support/OpenCore
```

Everything is re-derivable from the sources; nothing unique lives there except receipts.

**`gh repo create --source=.` fails with "not a git repository"** — `gh` does not follow the
`.git` gitdir pointer this repository uses. Create the repo by name and add the remote by hand.

## Git layout

`.git` is a **file** containing `gitdir: .git.nosync`, deliberately, to keep the object store
out of iCloud sync. Do not "fix" it. Ordinary git commands work normally.

## Not verified here

- **Calendar and Reminders sync.** Compiles, never run against real data. Must be run from the
  built app, not the CLI: EventKit reads usage strings from the calling binary's `Info.plist`
  and a SwiftPM executable has none, so the request is denied by TCC with no prompt.
- **Notes sync.** Compiles, never run. Needs an Automation grant on first use.
- **Release builds.** Only Debug has been built.
- **CI.** There is none yet.
