# OpenCore Architecture

Every claim in this document is labelled with how it was verified.

- `[measured]` — observed by running it, with the output recorded here
- `[test]` — asserted by a test in this repository
- `[source]` — read from the code, not executed
- `[design]` — an intent, not yet implemented

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

**Rule 1: objects are the floor.** Everything below `object` in the schema is derived and
disposable. `opencore rebuild` deletes claims, evidence, contradictions, beliefs, events and
edges, then re-derives them from stored objects. `[test]` — *deleting derived rows leaves
objects intact*, `Tests/CoreStoreTests/StoreTests.swift`.

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

Adjudication order `[source]` — `BeliefEngine.rank`:

1. **Authority.** Higher tier wins → `supersededByAuthority`.
2. **World-time recency.** Later `valid_from` wins → `supersededByRecency`.
3. **Neither.** → `unresolved`, both retained, nothing retracted.

`[test]` — all three paths: *later evidence supersedes earlier*, *a user correction outranks an
inference*, *equal authority with no ordering is left unresolved rather than guessed*.

Step 3 matters most. A system that always picks a winner is reporting a coin flip as a
conclusion.

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
graph (2-hop entity proximity). Semantic is a protocol with no implementation, and
`SearchOutcome.unavailableSignals` reports it as absent rather than scoring it zero — a signal
that scored 0 because it never ran is not the same result as one that ran and found nothing.

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

## Concurrency

`Database` is an actor holding a non-`Sendable` `Connection`. The connection's methods are
synchronous, and it is only ever handed to a closure running inside actor isolation. That is
what lets `write { }` issue several statements with no suspension point between them, which is
the only way `BEGIN`/`COMMIT` is actually atomic. An async closure there would allow other work
to interleave inside the transaction. `[source]` — `Sources/CoreStore/Database.swift`.

---

## Measured baseline

One sync of `github:Gunnarguy`, `--commits 40`, 2026-08-08 `[measured]`:

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

Tests: 13 passing across `CoreStoreTests` and `CoreGraphTests` `[measured]`.
