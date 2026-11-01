# OpenCore Architecture

Every claim in this document is labelled with how it was verified.

- `[measured]` — observed by running it, with the output recorded here
- `[test]` — asserted by a test in this repository
- `[source]` — read from the code, not executed
- `[design]` — an intent, not yet implemented

---

## Module map

Layers depend downward only `[source]`, `Package.swift`.

| Layer | Module | Holds |
|---|---|---|
| 0 | `CoreModel` | Primitives, `Domain`, `Authority`, `Temporal`, `Belief`, `CommitNature`, `ConnectorBatch`, `Receipt`, the chunker. No I/O |
| 0 | `CoreTelemetry` | Measurement, `BoundedProcess`, BetterDisplay parsing, `DisplayMutationGate`. Depends on nothing |
| 0 | `CoreJSONRPC` | Messages and the stdio and HTTP transports, shared by the MCP server and client |
| 1 | `CoreStore` | Every SQL string: `Store`, `Chunks`, `Activity`, `HomeSnapshot`, `Conversations`, `RebuildDiff`, `Export`, `LocalPrivateNames`, migrations |
| 2 | `CoreIngest` | Connectors, MCP client and OAuth, Keychain, `AgentMemoryPolicy`, `SyncSchedule`, `SyncLane` |
| 2 | `CoreGraph` | `IngestPipeline`, `EntityResolver`, `ClaimExtractor`, `BeliefEngine`, `BeliefAlerts`, `SourceSync`, `RebuildRehearsal` |
| 2 | `CoreSearch` | `AdmissionPolicy`, `HybridSearch`, `PassageSearch`, `TemporalIntent`, embeddings |
| 3 | `CoreReason` | `Reasoner` (claims, no model), `Conversation` (chat), `QueryFocus`, `WindowReport`, `AggregateAnswering`, `Grounding`, `ModelClaimProposer`. The only layer that reaches a model |
| 4 | `CoreMCP`, `opencore`, `Apps/OpenCoreMac` | Surfaces |

Three answer shapes `[source]`: `Reasoner.answer` assembles claims with no model. `Conversation.answer`
is grounded chat, on-device first. `AggregateAnswering` answers counts from SQL. Each gets the same
admission policy before anything is ranked.

---

## The two halves of the app

**The evidence half** is everything above: sources, corpus, passages, claims, beliefs, receipts,
chat, time travel, maintenance. It reads and writes the store through the package modules.

**The operator half** is a Mac console: repository fleet, coding agents, computer use, AI models and
RAM, hardware, USB, disk and monitors. It is about 43% of the app's lines `[measured 2026-10-30]`. It
lives in `HardwareUSBView`, `ComputerControlView`, `ComputerUsePowerhouse`, `OperatorConsoleService`,
`BetterDisplay*`, `ConnectedDisplay*` and `Model*View`, and it talks to two outside processes:
BetterDisplay, and a Local Hub, a separate repository served on `127.0.0.1`.

The two halves share no data path except fleet-fed file sync `[source]`. The operator half writes no
objects and no receipts, so nothing it does is evidence, and `Receipt.objectsTransmitted` says nothing
about it. Its risks are in `Docs/ai/STATE.md`. The Hub's path and identity and the automation tool's
path come from `private-names.json`, and with that file missing the Hub reads as not running.

---

## What is reviewed

As of 2026-10-31 `[source]`: private names, focused answers, time windows, fresh store and honest
beliefs were built, adversarially reviewed and repaired. Rebuild, Home and hardening have code in the
tree that was not reviewed, and the WWDC26 currency pass was not done. `Docs/ai/STATE.md` has the list.

---

## The trust stack

```
       SOURCE            a connector instance: github:Gunnarguy
         │
         ▼
       OBJECT            raw ingested item, content-addressed        ← the floor
         │
         ├──────────────► object_fts     BM25 index (external content)
         └──────────────► object_vector  embeddings, keyed by model
         │
         ▼
      EVIDENCE           a cited span within an object
         │
         ▼
  ENTITY ── alias        resolved conceptual things
         │
         ▼
       CLAIM             subject·predicate·object + confidence + authority
         │               + valid time + transaction time
         ├──────────────► claim_evidence  with stance: supports | refutes
         │
         ▼
   CONTRADICTION         two claims that cannot both stand
         │
         ▼
       BELIEF            append-only, versioned resolution per slot
         │
         ▼
      RECEIPT            what actually happened while answering
```

**Rule 1: objects are the floor.** Everything below `object` in the schema is derived.
`opencore rebuild` re-derives claims, evidence, contradictions, beliefs, events and edges from stored
objects on a copy of the store, and reports the difference by id. `--apply-rehearsal` applies it in
one transaction, and only the owner runs that. `[test]` — *deleting derived rows leaves objects
intact*, `Tests/CoreStoreTests/StoreTests.swift`. A rebuild carries what derivation cannot produce:
corrections, quarantine, recorded contradictions, belief history and the text past answers cited.
`[test]` *quarantine follows a statement to a new id*, `Tests/CoreGraphTests/RebuildRehearsalTests.swift`.

**Rule 2: nothing is deleted to record a change of mind.** Retraction and supersession are
columns. `[test]` — *a retracted claim is preserved, not deleted*.

---

## Bitemporality

Two independent axes on every claim `[source]` — `Sources/CoreModel/Temporal.swift`:

| Axis | Columns | Question it answers |
|---|---|---|
| Valid time | `valid_from`, `valid_to` | when was this true in the world? |
| Transaction time | `observed_at`, `retracted_at` | when did OpenCore believe it? |

A claim learned today about something true last year has `valid_from` last year and
`observed_at` today. Collapsing these makes both questions unanswerable.

`[test]` — *belief history is append-only and checkout reconstructs a past view* asserts that
querying as-of April returns belief v1 while as-of now returns v2.

---

## Authority vs confidence

Two numbers that are constantly conflated, kept apart by their types `[source]`:

| | Type | Means | Arithmetic allowed |
|---|---|---|---|
| `Authority` | ordinal enum, 0–5 | who said it | compare only |
| `confidence` | `Double` 0–1 | how strong the evidence is | blend, calibrate |

`Authority` is `Comparable` and nothing else. It is deliberately not a `Double`, because a
`Double` invites `confidence * authority`, which multiplies a calibrated number by an
uncalibrated constant and produces something that looks calibrated.

Tiers, low to high: `modelInference`, `derivedPattern`, `generatedSummary`,
`thirdPartyRecord`, `authoredArtifact`, `directStatement`.

The one place `authority` becomes a `Double` is retrieval blending, where it is normalised
against the top tier for scoring only. The raw tier stays on the row. `[source]` —
`Sources/CoreSearch/HybridSearch.swift`.

---

## Contradiction and belief

**Only functional predicates can contradict** `[source]` — `Predicate.functional`.

A project genuinely is built with Swift *and* Python, so two `built_with` claims are two facts.
A project has one `primary_language` at a time, so two current ones mean something changed.
Treating every repeated predicate as a conflict manufactures drama out of multi-valued data.
`[test]` — *multi-valued predicates are not treated as conflicts*.

**A record rewriting itself is not a disagreement** `[source]`: `BeliefEngine.revisions(among:)`.
Before anything compares authority, a slot drops any claim whose own record has since said
something else: same file name, or same object for anything that is not a file. Order is world time
and then the time OpenCore read it, because GitHub can report two languages under one push date. A
claim retires only when everything behind it has moved on, so a value another document still states
stays. A model's reading of a document is a proposal, so it takes no part in this step in either
direction. A document's rewrite writes a belief version and no contradiction row. A repository
changing status or language keeps one `temporalSupersession` row per change, because that is rare
and worth reading.
`[test]`: *the real objective slot follows its file, and a sync with nothing new changes nothing*,
*a repository brought back from the archive stops reading archived*, *a value stays while another
document still states it*.

`objective`, `last_verified_commit` and `next_action` are functional because a project has one of
each at a time and only functional predicates get a belief. They are also
`Predicate.documentRestated`, which changes two things: a new value never raises a notification, and
tiers compare differently (below). `[test]`: *a next action is replaced by the next revision, so a
project has one*.

Adjudication order for what remains `[source]`: `BeliefEngine.rank`, `BeliefEngine.adjudicate`:

1. **Standing.** Normally the authority tier. Higher wins → `supersededByAuthority`, and the reason
   says so when the loser was newer, with both dates. For `documentRestated` predicates the tiers
   from `generatedSummary` to `authoredArtifact` compare equal, because the tier records where a
   file sat when it was read. A model proposal stays below them and a correction stays above them.
2. **World-time recency.** Later `valid_from` wins → `supersededByRecency`.
3. **Authority within a standing**, on a tied date → `supersededByAuthority`.
4. **Neither.** → `unresolved`, both retained, nothing retracted.

`[test]`: *later evidence supersedes earlier*, *a user correction outranks an inference*, *between
two documents the newer statement of a plan wins, whatever root each came from*, *a newer model
proposal cannot displace a statement a person wrote, and the reason admits it is newer*, *equal
authority with no ordering is left unresolved rather than guessed*.

The last step matters most. A system that always picks a winner is reporting a coin flip as a
conclusion.

**What reaches a notification** `[source]`: `BeliefAlerts`, `BeliefNotifier`. A contradiction
alerts only when its slot has never held that pair of values, whichever rows assert them, and under
an identifier derived from the contradictions it reports. The open count stays on the Contradictions
screen, since it repeats on every pass. `[test]`: *two syncs in a row raise a contradiction once*,
*the same two values re-dated are not a new contradiction*.

### Corrections

A correction does not edit the wrong claim. It asserts a new one at `directStatement`,
retracts the old, and stores `prior_failure` — *why the old belief was reachable*. Storing only
the new value teaches nothing; storing the diagnosis is what lets the extractor be fixed
instead of the symptom patched. `[test]` — *a user correction outranks an inference and records
why the old belief was reachable*.

---

## Retrieval

### Admission before ranking

`AdmissionPolicy` runs *ahead* of scoring, not after `[source]`. Filtering after ranking still
leaks that something relevant exists in a blocked domain, and "top 20 then filter" starves the
allowed domains of slots.

Two rules, both learned by breaking `[measured]`:

1. **Whole words, never substrings.** `"What is OpenClinic built with?"` was classified
   `.medical` because `clinic` matched inside the project name. Every domain was blocked and
   the answer was "not enough evidence" for a question the store could answer.
2. **A known entity outranks a keyword.** Surfaces in `entity_alias` are masked out before
   keyword scanning, so a repo called `Budget` is not a financial query.

`[test]` — *a project whose name contains a sensitive keyword is not a sensitive query*
asserts both guards independently, so removing one cannot pass.

### Scoring

Weights vary by query class `[source]` — `QueryClass.weights`. Fixed weights across all query
shapes is what makes hybrid search feel arbitrary; a lookup wants lexical and authority, a
history question wants temporal.

Current signals: lexical (BM25, title weighted 2×), temporal (one-year half-life), authority,
graph (2-hop entity proximity). `SearchOutcome.unavailableSignals` reports a semantic signal with no
provider or no vectors as absent rather than scoring it zero — a signal that scored 0 because it
never ran is not the same result as one that ran and found nothing. That is `HybridSearch`, over
objects. Passage search is `PassageSearch`: BM25 and a dense leg, fused by rank, and the dense leg is
skipped at its default weight of 0.

### Time windows

`TemporalIntent` reads a phrase such as "recently" or "since August" into a `QueryTimeWindow` with an
injected clock and calendar, per answer `[test]`. A question about what happened is answered from
the event log through `Store.activity`. A question about a topic filters passages by date in SQL, on
both legs, ahead of any cap `[test]`. `WindowReport` states the days read, whether the span was chosen,
and freshness by kind of source, and `Store.freshness` reports only sources the caller may read.

### Focused answers

`QueryFocus` finds the subject a question names and the predicates it asks about, in the question's
word order. Claims about the subject lead, then the predicates asked about, in a total order so the
output is identical across processes `[measured]`. Repeated claims collapse to one line that keeps all
their evidence. Chat gets the same focus, one cited source per claim line.

**Known weakness** `[measured]`: BM25 normalisation `1 - 1/(1 + max(0, -bm25))` compresses most
hits into 0.88–0.91, so lexical discriminates less than it should. Recorded rather than tuned,
because tuning it without an eval harness is guessing.

---

## Receipts

Every field is observed during execution `[source]` — `ReceiptRecorder` is an actor that stamps
each stage as it completes. If a value could not be measured it is `nil` and renders as
"not measured". `[test]` — *a receipt round-trips with its stages and null confidence*.

`receipt_evidence` and `receipt_claim` record what an answer actually used, which is what makes
`opencore trace` able to walk from a sentence back to the commit behind it. `[measured]` —
verified against receipt `oc_d74555`.

---

## Freshness

`SourceSync` decides where a read starts, what an empty or failed read does, and when the date moves,
for the app, the CLI and both MCP sync paths `[test]`. The app ticks with
`NSBackgroundActivityScheduler` and `SyncSchedule` decides what is due, so it stays fresh only while the
app runs. `SyncCoordinator` allows one sync per app process. `Docs/CONNECTORS.md` has the rules.

---

## Concurrency

`Database` is an actor holding a non-`Sendable` `Connection`. The connection's methods are
synchronous, and it is only ever handed to a closure running inside actor isolation. That is
what lets `write { }` issue several statements with no suspension point between them, which is
the only way `BEGIN`/`COMMIT` is actually atomic. An async closure there would allow other work
to interleave inside the transaction. `[source]` — `Sources/CoreStore/Database.swift`.

---

## Measured baseline

The store on 2026-10-31 `[measured]`: 9,537 objects, 14,663 chunks, 1,075 entities, 944 claims, 14
contradictions, 2 open, on schema version 6.

The first sync, for scale: one sync of `github:Gunnarguy`, `--commits 40`, 2026-08-08 `[measured]`:

| | |
|---|---|
| wall clock | 16–20s |
| objects | 691 |
| entities | 38, with 70 aliases |
| claims | 82, from 41 evidence spans |
| events | 656 |
| beliefs | 41 |
| contradictions | 0 |

Zero contradictions is expected on a first sync: there is nothing yet to disagree with. They
appear on a later sync once a source changes what it says.

Tests: see `Docs/ai/RUNBOOK.md` for the current count `[measured]`.
