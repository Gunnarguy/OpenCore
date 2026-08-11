# Current State

Updated: 2026-08-11, end of session
Branch/worktree: `measure-and-fix-plus-saved-chats`, primary checkout (not a linked worktree).
Branched from `main` at `86c06ab`; fast-forward `main` onto it when ready.
Last commit: `d4dc228`, **"Make MCP one tab, which is what unstrands the tool picker"**.
Nine commits on this branch, four of them today.

**The working tree is clean.** Everything below is committed.

## Objective

**Understand how the system actually behaves, then fix what that reveals.** Telemetry found
the dense-leg waste and it is now fixed. A question asked in ordinary use found a second,
worse defect: chat answered a counting question with a confidently wrong number behind a valid
receipt. That is also fixed. The next job is the Notion JSON-blob granularity bug, which
blocks any further Notion syncing.

**The per-project-Notion-database button was dropped**, deliberately, on evidence. See
Decisions below. OpenCore now writes nothing to Notion at all, which is also the strongest
possible guarantee that it cannot damage an existing roadmap.

## Status

The system can now be measured, and the first two things measurement found are fixed.

**Warm query is 350ms -> 70ms.** `[measured]` The dense leg was computed in full and then
discarded on `absorb`'s first line, because `denseWeight` is 0. `search` now skips it;
`rankings` still runs it so `opencore eval` keeps measuring it. Eval is byte-identical across
the change, which is the proof the skipped work was contributing nothing.

**Counting questions are no longer answered from a passage window.** `[measured]` Asked "how
many of my apps are built with Swift", chat answered **2** against a true **12**: it counted
the Swift ones among the six retrieved passages. New `.aggregate` query class, computed in SQL
over every admitted row, model not involved. Now answers `12 of 22 repositories`.

**Chats are saved and resumable.** Migration 4, `conversation` + `conversation_turn`, both
deliberately outside `derivedTables` because a conversation is primary data that `rebuild`
cannot reconstruct. `opencore chats` lists threads; `opencore chat "..." --resume ID` reopens
one, restoring the model's `Transcript` and not merely the text on screen. In the app it is a
History menu in the Chat tab, not a fifteenth tab. Saving a turn also saves its receipt, which
fixed the chat-receipts bug found earlier the same day.

Verified working end to end today: `opencore eval`, the on-device chat path, MCP sign-in via
`ASWebAuthenticationSession` against `mcp.notion.com`, one real Notion sync, and
`--telemetry` across `passages` and `ask`.

## Landed today: the UX pass, then the MCP merge

Four commits, in this order. Each was built on the one before it.

1. `61671d2` — `EntityDossier`, `CorpusSnapshot`, migration 5 (`judgement`, `judged_at`), and
   `Turn.init(id:)` so a verdict reaches the row it is about.
2. `36407e1` — `EntityView`, `CorpusView`, banded sidebar, `AskView` deleted.
3. `a42394a` — **the OAuth refresh was never called.** See Blockers; this is the most
   consequential thing found today and it was found by accident.
4. `d4dc228` — MCP and MCP Store merged into one screen, which unstranded the tool picker.

## Why the UX pass happened

Prompted by a review of the app's information architecture. The finding that drove it: **the
sidebar is the database schema with a sidebar around it.** Claims, Beliefs, Contradictions,
Timeline, Passages, Receipts are the *layers of the system*, not anything a person wants. The
tell was that `core_ask`'s sibling `core_claims(entity:)` gave an external model a first-class
entity lens that the app itself did not have.

What it added:

- `Sources/CoreStore/EntityDossier.swift` — assembles everything about one entity.
- `Sources/CoreStore/CorpusSnapshot.swift` — counts by kind, source, domain, time.
- `Apps/OpenCoreMac/Sources/EntityView.swift` — the subject-first page. This is the centrepiece.
- `Apps/OpenCoreMac/Sources/CorpusView.swift` — makes the corpus legible.
- `Sources/CoreStore/Resources/migration_005.sql` — `judgement` and `judged_at` on
  `conversation_turn`, registered as migration 5 in `Database.migrations`.
- `Tests/CoreStoreTests/JudgementAndDossierTests.swift` — 6 tests.

Modified: `ChatView.swift`, `OpenCoreApp.swift` (banded sidebar), `Conversation.swift`,
`Conversations.swift`, `Database.swift`. Deleted: `AskView.swift`, retired into Chat.

Then `d4dc228` merged MCP and MCP Store into one screen with a segmented control, and pulled
the tool picker out of the add-a-server path so both paths share it. That is what made
**Choose tools** on a configured source possible. Three details in it are load-bearing and
easy to undo by accident:

- Discovery runs against the source's **stored** config. The OAuth token is keyed by server
  *name*, so a rebuilt config authenticates as the wrong server or as nobody.
- Saving upserts the row that was read, not a `Source` rebuilt from the connector, so
  `lastSyncedAt` and the sync cursor survive.
- A tool argument stored as an object or a number is shown **read-only**. The form writes text,
  and parsing it back into JSON is the guess `--tool-arg-json` exists as a separate flag to
  avoid. Making that field editable would silently flatten a working Notion configuration.

**Why migration 5 exists.** Every retrieval constant in this project rests on 20 hand-written
benchmark cases. Migration 4 already persists every question, answer, source list and receipt;
one judgement column turns that history into a corpus that grows by using the product. `NULL`
is unjudged and must never be read as neutral.

### What is verified, and what is not

- `xcodebuild -scheme OpenCore` -> **BUILD SUCCEEDED.** This was the one real gap and it is
  closed. Note the app project is XcodeGen-generated and gitignored, so `xcodegen generate` in
  `Apps/OpenCoreMac/` is required after adding or deleting a source file: `sources: - path:
  Sources` enumerates files at generation time rather than referencing the folder.
- `swift test` -> **89 tests pass** (8 + 21 + 3 + 18 + 3 + 36). Was 81: +6
  `JudgementAndDossierTests`, +2 OAuth token expiry.
- `opencore mcp-source discover --url https://mcp.notion.com/mcp --as notion` -> **Notion MCP,
  protocol 2025-11-25, 28 tools.** This is the exact path the new Choose tools button calls,
  so the button's engine is verified even though the button is not.
- **NOT verified: clicking through the merged MCP screen.** The discovery call it makes works
  against the live server; nobody has pressed the button. Same for Entity and Corpus.
- **Migration 5 is applied to the live store.** `PRAGMA table_info(conversation_turn)` shows
  `judgement TEXT` and `judged_at REAL`. Checked against the real database, not a fixture.
- The Entity page **was** run against the real store earlier and worked. Looking at it
  immediately found three defects that were then fixed: entity references rendering as raw
  hashes (`contributed to 6230ffec...`), 477 near-identical claim rows, and a slow load from an
  N+1 introduced in the dossier assembly.
- **Thumbs up/down is wired**, contrary to what this file said on 2026-08-10. `ChatView`'s
  `TurnView.judgement` renders the two icons and `ChatModel.judge` calls `Store.judge`. The
  id round-trip that makes it durable is real: `Conversation` persists a turn as
  `StoredTurn(id: turn.id.uuidString)` and `restore()` reads `UUID(uuidString: row.id)` back,
  so a verdict written today is still shown when the thread is reopened. Judgements are held
  in a dictionary beside `turns` rather than on `Turn`, because `Turn` is streamed from the
  conversation actor and replaced wholesale on every frame.

## Decisions taken this session

**Dropped: the button that creates a Notion database per project.** Not deferred, dropped.
The evidence, all read-only from the live workspace:

- The two roadmaps that exist (OpenCore, OpenIntelligence) share six property *names* and
  **zero identical option sets**. OpenCore has `Critical` priority and `Dropped` status;
  OpenIntelligence has neither, and their `Target Release` lists are disjoint (v0.1-v1.0 vs
  v4.0-v5.0). A button must pick a schema; per-project schemas mean it cannot.
- `📦 Projects DB` holds **33 projects, 2 with roadmaps**, so the gap is real. But it already
  contains three duplicate pairs (`ManualMind`, `HealthKit Supplements Tracker`, both created
  2025-12-13 then again 2026-01-21; `PlaudBlender` twice against the same repo). Some earlier
  automation already ran a create-if-missing pass here and got it wrong. Adding a second
  writer raises that rate.
- The cheap honest version, if it is ever wanted: a **read-only report** naming which of the
  33 projects have no roadmap, and the user clicks Duplicate in Notion. Right schema, because
  it was copied from a real one, and nothing writes.

**The valuable direction is the inverse**: pull all 33 project rows and both roadmaps *into*
OpenCore. That needs the same two Critical prerequisites, is on-thesis (connectors produce
objects), and makes `opencore ask "which projects used Pinecone"` answerable.

## Landed on this branch, previously in flight

All committed now. Three things that had been uncommitted for a session: MCP over HTTP + OAuth,
`toolArguments` as `JSONValue`, and the telemetry layer.

**Telemetry** (`Sources/CoreTelemetry/`, new Layer-0 target, no dependencies):

- Nesting comes from a `@TaskLocal`, not a parameter. That is the only reason it reaches into
  `CoreStore`'s query methods and `PassageSearch`'s legs without a signature change between
  them and the CLI.
- `span` takes `isolation: isolated (any Actor)? = #isolation`. Without it, a span opened
  inside an actor (`Database`, `HTTPTransport`, every connector) fails Swift 6's region check
  because the body would be a non-`Sendable` closure crossing an isolation boundary.
- **There is no stdout sink and no option to add one.** The `opencore mcp` constraint is
  enforced by the type not existing rather than by a rule someone has to remember.
- Off unless `--telemetry` or `OPENCORE_TELEMETRY`. Disabled cost is one atomic load.
- `Database.execute`/`query` are instrumented, so **every SQL statement in the project** is
  measured from one place, named by shape (`SELECT object`) so repeats group in a summary.
  The convenience forwarders on `Database` are deliberately *not* instrumented, or every row
  would be double-counted.
- Surfaces: `--telemetry` (tree), `--telemetry-summary` (time by layer, self time not total),
  `--telemetry-json PATH` (JSONL).

**`toolArguments` is now `[String: [String: JSONValue]]`.** Top level stays a named map
because MCP's `tools/call` `arguments` is always an object; only the values widened. Configs
written by the string-only version decode unchanged, so there is no migration. CLI gains
`--tool-arg-json TOOL:key=<json>` beside `--tool-arg`; two flags rather than one that guesses,
because `{"limit":"10"}` and `{"limit":10}` are both real and no rule can tell which a server
wants without reading its schema.

MCP over HTTP + OAuth. Builds clean, signed in, and has synced once.

- `Sources/CoreJSONRPC/MCPTransport.swift` (new) — `MCPTransport` protocol so `MCPClient` no
  longer holds a concrete `StdioTransport`, plus `rpcErrorCode(_:)` so the `-32601` protocol
  probe works identically over both transports.
- `Sources/CoreJSONRPC/HTTPTransport.swift` (new) — streamable HTTP. Handles both
  `application/json` and `text/event-stream` replies, echoes `Mcp-Session-Id`, and reads the
  `resource_metadata` URL out of a 401's `WWW-Authenticate`.
- `Sources/CoreIngest/MCPOAuth.swift` (new) — discovery, **dynamic client registration**, PKCE
  S256, token exchange and refresh, keychain storage under `mcp-oauth:<server>`.
- `Apps/OpenCoreMac/Sources/MCPSignIn.swift` (new) — `ASWebAuthenticationSession` flow.
- `Apps/OpenCoreMac/project.yml` — registers the `opencore://` URL scheme.
- `Sources/opencore/MCPSourceCommands.swift` — `mcp-source oauth --url`, and `discover`/`add`
  accept `--url` for hosted servers.

**The one crash worth remembering** is written up in auto-memory: an ObjC completion handler
written inside a `@MainActor` type inherits main-actor isolation, and Swift 6's executor check
traps when the framework calls it on its own queue. `@Sendable` on the closure is the fix.

## Completed

- v0.1 `43c1581`, v0.2 `80fa667` — see `Docs/ROADMAP.md`.
- `3e02ba6`, `6925546` — Claude Context OS, and a fix to its own staleness check.
- `5aa3448` — MCP client. `CoreJSONRPC` extracted; default-deny tool policy; migration 3.
- `4a7e97e` — app parity. The app had never used `PassageSearch` at all.
- `3ee49cb`, `7b3ae89` — Settings, then real settings. `RetrievalTuning`, domain matrix,
  `Exporter`.
- `daa9c63` — Settings on `Form`/`.formStyle(.grouped)`; MCP store; keychain credentials.
- `4eb94a2` — wired up five things that reached nothing. `Reasoner` was still running the v0.1
  object scorer everywhere, so the app built 2,237 embeddings it never searched. Calendar,
  notes and files now produce claims and timeline events. `Store.dropDerivedLayers()` closed
  the duplicated-rebuild-SQL violation of `.claude/rules/store.md`.
- `7dbf3b9` — reached four capabilities with no caller. `BeliefEngine.correct()`
  was implemented, tested and unreachable, so the correction table could never have had a row;
  `opencore correct` and a sheet on the Claims table now reach it. Timeline tab and CLI.
- `4e24d3b` — chat on the on-device model, HealthKit, and commits finally producing claims.

Store right now: 6,654 objects, 7,661 chunks, 135 entities, 939 claims, 6,412 events.
By kind: 5,366 notes, 668 commits, 558 calendar events, 22 repositories, 21 files,
19 documents. **Notes and commits are 90% of the corpus**, which is the shape behind the
commit-flooding defect below.

## Active Constraints

- **Objects are the floor.** `opencore rebuild` must reconstruct every derived layer.
- **Zero external dependencies.** Apple system frameworks are not dependencies, so deep
  platform integration is on-thesis rather than a compromise.
- **Unmeasured stays `nil`.** No accuracy number may be quoted; none has been measured.
- **Authority never multiplies.** Ordinal tier, not a probability.
- **MCP tools are default-deny.** Never derive an allowlist, however good the metadata looks.
- **The model never reads the store.** Retrieval runs in code; the model sees only the passages
  it is handed and never introduces a claim. This is what keeps `Authority` meaningful.

## Working Set

For commit flooding:

- `Sources/CoreSearch/PassageSearch.swift` — `absorb(_:leg:weight:)` is the RRF contribution;
  domain admission and MMR follow it. `rankings(...)` is what the harness measures through.
- `Sources/CoreIngest/GitHubConnector.swift` — writes `Gunnarguy/<repo>` as line 1 of
  `object.text` for **both** commits and repositories. Not the Chunker, which chunks
  `object.text` verbatim.
- `Benchmarks/rag_eval_v1.jsonl` — `q18` is the regression test. Add cases when a fix targets a
  shape not covered; never edit an existing case to make a change look better.

For Notion over MCP:

- `Sources/CoreIngest/MCPClientConnector.swift` — `MCPServerConfig` already has `command`,
  `arguments`, `environmentNames`, `allowedTools`, `domain`, `authority`, and resolves secrets
  from the keychain. This is the whole integration surface.

## Verification

Last run 2026-08-11, against the uncommitted tree:

- `xcodebuild -scheme OpenCore` -> **BUILD SUCCEEDED**, twice: after the UX pass and again
  after the MCP merge. This closes the gap left open on 2026-08-10.
- `swift test` -> **89 tests pass** (8 + 21 + 3 + 18 + 3 + 36). +6 `JudgementAndDossierTests`,
  +2 OAuth token expiry.
- `opencore mcp-source discover --url https://mcp.notion.com/mcp --as notion` -> **28 tools**,
  protocol 2025-11-25, against the live server. The same command failed with `server requires
  authorization` before `a42394a`, which is the before/after for the OAuth refresh fix.
- `PRAGMA table_info(conversation_turn)` on the live store -> `judgement` and `judged_at`
  present, so migration 5 applied cleanly to a real database at version 4.
- `opencore chats` -> both saved threads still listed and readable after the migration.

Run 2026-08-10, against the same tree:

- `swift build` -> clean
- `swift test` -> **81 tests pass** (8 + 15 + 3 + 18 + 3 + 34). Superseded by the 89 above.
  Was 51: +9 for counting
  (chat and `Reasoner`), +3 for the dense-leg guard, +5 for saved conversations, +3 for MCP
  protocol negotiation, +3 for receipt identity, +5 for registry ranking. New targets
  `CoreSearchTests` and `CoreMCPTests`.
- `opencore chats` / `chat --resume ID` -> a thread went 2 turns to **4** on resume rather
  than forking, and `opencore trace` resolved a receipt printed by `chat`, which it could not
  do before today.
- `core_ask` over MCP -> `12 of 22 repositories`, with the receipt reporting 22 searched, 0
  retrieved, 0 evidence. Asking it to count `personal` notes returns **no count**: the
  firewall declined and it fell through to retrieval, so an MCP caller cannot count what it
  cannot retrieve.
- `opencore passages --telemetry-summary` -> **70ms total**, and no `embed.query`,
  `leg.dense` or `SELECT chunk_vector` span present. Was 350ms.
- `opencore eval` -> lexical 0.362, dense 0.025, fused 0.365 nDCG@6, missed 7/18/7.
  **Byte-identical before and after the dense-leg guard**, which is the check that the
  skipped work was contributing nothing.
- `opencore chat "how many of my apps are built with swift"` -> `12 of 22 repositories —
  Swift`, with the 1 repository that records no language reported as unaccounted for rather
  than counted as not matching. Was **2**.
- Store: 6,654 objects, 7,661 chunks.

Carried over from 2026-08-09, not re-run today:

- `opencore mcp-source list` -> `notion`, endpoint `https://mcp.notion.com/mcp`,
  **OAuth signed in**, tools `notion-fetch, notion-list-recent-pages`, synced 2026-08-09
- `--tool-arg-json` smoke test -> a nested `notion-query-data-sources` argument persisted with
  `page_size` as a **number** and `data_source_urls` as an **array**.
- `opencore passages/ask --telemetry` -> **telemetry on produces 0 lines on stdout**, checked
  explicitly.

## Blockers / Unknowns

- ~~**The dense leg is fully computed, then discarded.**~~ **Done, 2026-08-10.** Warm query
  350ms -> **70ms** `[measured]`, verified by `--telemetry-summary`: no `embed.query`, no
  `leg.dense`, no `SELECT chunk_vector` span remains. `rankings` untouched, and `opencore eval`
  is byte-identical across the change (fused nDCG@6 0.365, dense still measured at 0.025).
  Regression tests in `Tests/CoreSearchTests/DenseLegSkipTests.swift` assert both guards
  separately: `search` must skip, `rankings` must not.
- ~~**Counting questions are answered from a six-passage window.**~~ **Done, 2026-08-10.** See
  Decisions. New `.aggregate` class, `Store.objectCountsByMetadata`, `AggregateAnswering`.
  Firewalled: `domains` is a required parameter, because a count is a disclosure.
- ~~**Chat receipts are never persisted.**~~ **Done, 2026-08-10**, as part of saved chats.
  Saving a turn saves its receipt, so `opencore trace <code>` now resolves a chat answer.
  Verified against the real store.
- **Retrieval runs on the raw follow-up text, so conversational follow-ups retrieve badly.**
  `[measured]` With a thread resumed and the model's transcript restored, "what language did
  you just say it uses" retrieves nothing relevant and answers "the sources retrieved do not
  answer that". The model *has* the context and is refusing to answer from memory, which is
  the thesis working correctly. The missing piece is query rewriting: expanding a follow-up
  into a standalone retrieval query using the thread's context. Pre-existing, and it affects
  follow-ups within one sitting exactly as much as resumed ones.
- **The Notion sync stores raw JSON blobs, one per tool call.** `[measured]` The two objects it
  produced are titled `notion · notion-fetch` and `notion · notion-list-recent-pages`, and their
  text is the raw MCP response. Wrong granularity: a list response must fan out into one object
  per record, each with its own stable `externalID`, or re-syncing updates two blobs forever and
  retrieval indexes JSON syntax. Fix before syncing Notion again. Tracked Critical.
  *Telemetry makes this visible*: `objects=1` on a `tool` span whatever the record count.
- ~~`toolArguments` is string-only~~ **Done.** See In flight.
- **The answer path is N+1.** `[measured]` One `ask` issues **77 separate `SELECT entity`**
  statements plus one `SELECT chunk` per context neighbour. Filed **Low** on purpose: the whole
  store layer is 32ms of a 350ms run, so this is optimising the 9% while the 91% above goes
  untouched. Revisit when the dense-leg fix lands.

- **Commit flooding is now the top retrieval defect.** `[measured]` 651 short commit objects
  against 16 READMEs, and BM25 length normalisation favours the short ones, so a question naming
  a repository retrieves its commit stream. After the fusion fix the OpenCore README reaches
  rank 4 (it previously never appeared) and three unrelated commits still outrank it, and chat
  still answers from one of them. Benchmark case `q18` is the regression test and still fails
  by design. *Note:* the earlier proposed fix was wrong, `Gunnarguy/<repo>` is in `object.text`
  for repositories too, so stripping it helps neither side.
- **`signalScale` is inert.** `[measured]` Swept 0.02 / 0.005 / 0.0 for identical nDCG. The
  authority and recency terms change no ranking, which makes `QueryClass.weights` decorative.
  Do not fix by raising the constant: the benchmark is almost entirely `factual` cases and
  cannot fairly judge a temporal signal until it has temporal ones.
- **The dense leg is near-random.** `[measured]` nDCG@6 0.059 at full vector coverage, so not an
  index problem. `NLContextualEmbedding` is a token model, mean-pooled, never trained for
  asymmetric query-to-document retrieval. *Verify:* symmetric self-retrieval first, which
  separates "vectors are broken" from "asymmetry is hard". It won one case nothing else found,
  so the signal is real and weak.
- **The valid-time axis is unreachable.** `Validity.heldInWorld` and `.asOf` have no caller, so
  "what did you believe in March" works and "what was true in March" does not. Half the
  bitemporal model, which is the headline design idea.
- **`Store.beliefHistory(key:)` is unreachable.** 43 belief versions exist; no surface shows the
  version history of a single belief.
- **`met_with` claims are still zero.** The stored calendar objects predate the connector
  learning to record attendees. *Verify:* re-sync calendar from the app, then re-derive.
- **Notion is connected and syncing, but returns the database rather than its rows.**
  `[measured]` OAuth sign-in worked from the app; 2 objects, 14 chunks, `thirdPartyRecord`,
  domain `project`, retrievable. `notion-fetch` on a database returns its schema, not its rows;
  rows need `notion-query-data-sources`, whose parameters are object-shaped. **The
  `toolArguments` half of this is now fixed**; the remaining half is configuring the tool and
  fanning out its response.
- **Finishing a hosted source needs the CLI.** After signing in, the app cannot list or tick
  tools for an existing source, so Sync fails `noAllowedTools` with no in-app remedy. The
  discovery panel and tool picker already exist; they are only reachable on the new-source
  path.
- **Known gap:** the MCP *server* still implements `2025-11-25`; the *client* handles both
  generations. Tracked Critical in Notion. It now **negotiates** properly, though: it answers
  `initialize` with the client's requested version when that version is one it can serve
  (`2025-11-25`, `2025-06-18`, `2025-03-26`), instead of hardcoding its own. Being a version
  behind is survivable; refusing to speak a client's version silently was not.
- ~~**`core_ask` over MCP and `opencore ask` do not have the counting fix.**~~ **Done,
  2026-08-10.** `Reasoner` now has the `.aggregate` path, so chat, `opencore ask` and
  `core_ask` all answer `12 of 22 repositories`. `Answer.counted` is an explicit field rather
  than something inferred from empty `points`, because a counted answer and a found-nothing
  answer are otherwise indistinguishable to a caller.
- ~~**Two answers to the same query in the same millisecond collide.**~~ **Fixed
  2026-08-10.** `Receipt.id` is now minted unique per answer rather than derived from query
  plus timestamp, and `Receipt.init(row:)` **reads** the stored id instead of recomputing it.
  Content-addressing is right for an object, where re-ingesting the same bytes should update
  one row; a receipt records that an answer *happened*, so the same question twice is two
  events. 3 tests in `Tests/CoreStoreTests/ReceiptIdentityTests.swift`.
- ~~**Remote-only MCP servers cannot be added from the MCP Store screen.**~~ **Fixed
  2026-08-10.** `RegistryServer.launchability` became `reachability`, which answers "how would
  OpenCore reach this" rather than "can this be launched as a subprocess", and the registry
  model now keeps endpoint URLs instead of decoding them down to a transport name and throwing
  the address away. Measured on one live page: **23 usable to 63** (+40 hosted), 1 still
  unreachable. A package still wins when a server publishes both, because launching needs no
  account and no sign-in.
- ~~**The last step of a hosted source is still CLI-only.**~~ **Done, 2026-08-11**, `d4dc228`.
  A configured source has a **Choose tools** button that discovers against its stored config
  and opens the shared picker. What is *still* CLI-only, deliberately, is editing a tool
  argument that is an object or a number. That is the last remaining reason to reach for the
  CLI on a Notion source.
- ~~**The OAuth refresh is never called.**~~ **Found and fixed 2026-08-11**, `a42394a`.
  `[measured]` `makeClient()` read `MCPOAuth.stored(server:)?.accessToken` raw, with no expiry
  check, while `MCPOAuth.validAccessToken(server:endpoint:)` sat there doing exactly the right
  thing with **zero callers**. So every hosted source worked until its first access token
  expired and then failed every call with `server requires authorization`. Live Notion server,
  same command: `error: server requires authorization` before, `28 tools` after.

  **How it was found matters more than the fix.** Not by reading the OAuth code, which
  compiles and looks correct. It surfaced while verifying the unrelated navigation fix above:
  exercising the newly-reachable discovery path returned a 401 that had nothing to do with the
  change being tested. A navigation defect was sitting on top of a protocol defect.

  **This is the fifth capability found built, correct and unreachable**, after
  `BeliefEngine.correct()`, `Store.beliefHistory(key:)`, `Validity.heldInWorld`/`.asOf`, and
  the v0.1 object scorer. Building things is not this project's failure mode. Wiring them up
  is. A grep for public functions with no caller outside tests would have caught four of five,
  and is worth doing as a standing check.
- **Not clicked through:** the app compiles and chat has been exercised headlessly, but the
  riskiest path is still unverified end to end: MCP store -> credentials -> Add -> Discover ->
  tick tools -> Sync.

## Exact Next Action

The tree is clean and everything below is committed. Two things are worth doing before more
features, in this order.

1. **Click through the app against real data.** This is now the largest gap in the project and
   it grew today: Entity, Corpus, the banded sidebar, the merged MCP screen and the thumbs are
   all built, all compiling, and none has been used. Today's session is itself the argument for
   doing this: exercising one path end to end against a live server found a Critical defect
   that reading the code did not. Highest risk first, which is the full MCP flow:
   catalogue -> Add -> Sign in -> **Choose tools** -> Sync. The engine under it is verified,
   the screen is not.

2. **Fan out MCP list responses into one object per record** (Critical, see Blockers). Still
   the top blocking defect for anything Notion. `MCPClientConnector` writes one object per
   *tool call*, so a list of N records becomes a single JSON blob titled
   `notion · notion-list-recent-pages`, and re-syncing updates two blobs forever while
   retrieval indexes JSON syntax. Each record needs its own stable `externalID`.
   *Telemetry makes it visible*: `objects=1` on a `tool` span whatever the record count.

Also worth doing, cheap, and prompted by today's finding: **grep for public functions with no
caller outside tests.** Five capabilities have now been found built and unreachable, which is a
pattern rather than a coincidence.

Three traps worth keeping, each of which has cost time at least once:

- The app declares its own top-level `enum Section`, which shadows `SwiftUI.Section`
  module-wide. The error names `CodingKeyRepresentable` and says nothing about lists. Spell it
  `SwiftUI.Section`.
- **One SwiftPM build at a time.** `swift build` takes an exclusive lock on the scratch path, so
  a second invocation queues silently and looks like a hang. It is not a slow type checker.
  Check `pgrep -f swift-frontend` before concluding anything about performance.
- **Run `xcodegen generate` after adding or deleting an app source file.** The project is
  generated and gitignored, and `sources: - path: Sources` enumerates files at generation time.
  A new view that is never added to the project simply does not exist to the compiler.

Not on this list on purpose: the create-a-database button, and third-party model providers. See
Decisions and the Notion board.

## Housekeeping

`Apps/OpenCoreMac/OpenCore 2.xcodeproj` was an iCloud duplicate and is **deleted**, 2026-08-10.
Verified stale before removing: 15 hours older than the real one, gitignored (so untracked and
regenerable by XcodeGen from `project.yml`), referenced by nothing, and containing **zero**
references to `MCPSignIn` against the real project's four, so it predated the OAuth work
entirely. `xcodebuild -scheme OpenCore` still succeeds. It was the only such duplicate in the
repository.
