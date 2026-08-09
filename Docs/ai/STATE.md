# Current State

Updated: 2026-08-09 14:40 PT
Branch/worktree: `main`, primary checkout (not a linked worktree)
Last verified commit: `4e24d3b`, plus uncommitted work described under "In flight"

## Objective

**Fix commit flooding, and bring Notion in over MCP.** The eval harness is built, has run, and
has already paid for itself: it found that fusion was destroying 83% of achievable retrieval
quality, and the fix took fused nDCG@6 from 0.073 to 0.422. The next defect it exposes is
commit flooding, which is a different problem and is now the top one. Separately, the Notion
integration is a source row rather than a subsystem, and closes the standing blocker that the
MCP client has never met a third-party server.

## Status

v0.3's headline work has landed and then some. OpenCore serves MCP and consumes it, the
registry is browsable in-app, the app has caught up with the engine across ten sidebar
sections, corrections and the timeline are reachable, chat runs on Apple's on-device model
through a schema that makes citations structural, and retrieval quality now has a number.

**The first measurement found a real defect and the fix is in.** Fused nDCG@6 was 0.073 against
0.420 for lexical alone, meaning the shipped hybrid retrieval was six times worse than half of
itself. A sweep isolated it to the dense leg carrying equal RRF weight while scoring 0.059.
Fused is now **0.422**, beating both its legs for the first time.

`denseWeight: 0` and `mmrLambda: 0.85` are the first defaults in this project chosen by
measurement rather than by taste. The dense leg is disabled, loudly and reversibly, pending the
`NLContextualEmbedding` question below.

## In flight (uncommitted)

Two pieces of work, both green: chat rebuilt against the real FoundationModels API, and the
eval harness. See the three 2026-08-09 entries in `DECISIONS.md` for why each piece is the way
it is.

**Eval harness:**

- `Benchmarks/rag_eval_v1.jsonl` (new) — 20 cases. Expectations written from corpus content
  before any query ran; half deliberately avoid the target's own vocabulary; `q18` is the
  known-failing question, included as a case that is supposed to fail.
- `Sources/opencore/EvalCommands.swift` (new) — `opencore eval [--file] [--k] [--verbose]`.
  Recall@1/@3/@k, MRR, nDCG@k, per leg. Scored by object, not chunk, because chunk boundaries
  are themselves a tuned parameter.
- `Sources/CoreSearch/PassageSearch.swift` — `rankings(...)` returning each leg's independent
  ranking. `search` cannot answer this: by the time it returns, a leg's own ordering is gone.
- `Sources/CoreStore/Store.swift` — `objectIDs(title:)`, so the harness writes no SQL.
- `Sources/opencore/main.swift`, `Apps/.../AppModel+Maintenance.swift` — `rebuild` re-embeds.
- `RetrievalTuning.lexicalWeight` / `.denseWeight` (new), and `opencore eval` takes
  `--rrf-k --mmr-lambda --candidates --signal-scale --lexical-weight --dense-weight` so a
  change is measured against the shipped default in one command.

**Chat rebuild:**

- `Sources/CoreReason/GroundedAnswer.swift` (new) — `@Generable` answer schema. Citations are a
  guided `Int`, so constrained decoding makes an uncited sentence unrepresentable.
- `Sources/CoreReason/Grounding.swift` — scores each sentence against **the source it cited**
  rather than all six pooled. Two signals reported separately: citation resolution (hard) and
  lexical overlap (heuristic).
- `Sources/CoreReason/Conversation.swift` — retained session and `Transcript` instead of
  hand-rolled history, `GenerationOptions(samplingMode: .greedy)`, `prewarm()`, the
  `LanguageModelError` taxonomy, token counts and real retrieval stages in the receipt.
- `Tests/CoreReasonTests/` (new target) — 9 tests. This subsystem previously had none.
- `Apps/OpenCoreMac/Sources/ChatView.swift` — holds one `Conversation` across turns so the
  transcript works; badge wording narrowed so a green check cannot be read as "correct".
- `Sources/opencore/main.swift` — `opencore chat` reports the two signals separately.

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

Store right now: 1,268 objects, 2,237 chunks, 111 entities, 922 claims, 1,247 events.

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

Last run 2026-08-09, against the uncommitted tree:

- `swift build` -> clean, no warnings in touched files
- `swift test` -> **41 tests pass** (7 + 9 + 25), up from 32
- `xcodebuild -scheme OpenCore` -> BUILD SUCCEEDED
- `opencore chat` -> ran against the real on-device model twice. Answer path and the
  `insufficient` path both verified.
- `opencore eval --verbose` -> 20/20 cases scoreable, every expected title resolved.
- Sweep over `denseWeight` x `mmrLambda` -> monotonic; fused nDCG@6 **0.073 -> 0.422**, now
  above lexical alone (0.420). `signalScale` swept 0.02/0.005/0.0 -> identical, so inert.
- `opencore chat` on `q18` after the fix -> the OpenCore README now reaches rank 4 where it
  previously never appeared, three unrelated commits still outrank it, and the answer is still
  wrong. Aggregate improved; that query did not.

## Blockers / Unknowns

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
- **The MCP client has never run against a third-party server**, only OpenCore's own.
- **Known gap:** the MCP *server* still implements `2025-11-25`; the *client* handles both
  generations. Tracked Critical in Notion.
- **Not clicked through:** the app compiles and chat has been exercised headlessly, but the
  riskiest path is still unverified end to end: MCP store -> credentials -> Add -> Discover ->
  tick tools -> Sync.

## Exact Next Action

Commit the in-flight work. Then two independent tracks, both measured with `opencore eval`
before and after:

**1. Commit flooding.** Stop 651 short commit objects crowding out 16 READMEs on questions about
a repository. Candidates, cheapest first: cap how many objects of one kind may enter the
candidate set; give `repository` and `document` objects a prior for `factual` questions naming a
known entity; or reconsider whether every commit needs to be independently retrievable at all.
`q18` is the regression test and must go from failing to passing.

**2. Notion as an MCP source.** Add one source row for the OpenCore roadmap database using the
existing stdio MCP client, sync it, read the objects back. This also closes the standing blocker
that the MCP client has never run against a third-party server. Design constraints are on the
Notion row: objects only, read-only tool allowlist, and **do not map the `Evidence` field onto
`Authority`**, which would be the `confidence * authority` mistake the type exists to prevent.

Do not edit an existing benchmark case to make a change look better. Add cases; never soften the
ones that fail. The benchmark needs `temporal` and `differential` cases before `signalScale` or
`QueryClass.weights` can be judged at all.
