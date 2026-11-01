# OpenCore Roadmap

> **Roadmap truth is the Notion database, not this file.** This is the readable summary;
> Notion is what gets updated first and carries per-row evidence levels and leverage
> classification.
>
> Database `7dc3bd42-1933-4d25-847a-5bc98acac3fc`,
> data source `546d4b56-a91a-4324-92e7-738c9637d8d0` (query tools take the data source id).

Ordered by what unblocks what, not by what sounds best.

Status: `todo` · `doing` · `done` · `dropped`

## Now  ·  2026-10-31

Five items were built and reviewed: private names, focused answers, time windows, fresh store and
honest beliefs. Four are open: **rebuild** and **Home** have unreviewed code in the tree, **hardening**
is partly in the tree and unreviewed, and the **WWDC26 currency** pass was not done. The owner's next
step is to start building. The versions below are the original plan, and Notion has moved past them.

## The two force multipliers

Out of everything unbuilt, exactly two items collapse large parts of the rest. Build these
before anything they unblock, however tempting the alternative looks:

1. **MCP client.** One `MCPConnector` conforming to the existing `Connector` protocol turns
   the whole MCP ecosystem into OpenCore sources. The official registry passed 9,652 servers
   in May 2026. Writing connectors one at a time is volume work this makes unnecessary.
2. **Eval harness.** Every retrieval constant in this repo is chosen rather than measured,
   and v0.2 added more of them than v0.1 had.

A third arrives for free from Apple rather than from us: the WWDC26 `LanguageModel` protocol
is the model-agnostic abstraction this project was going to have to invent, so on-device,
PCC, Core AI, MLX, Claude and Gemini become one conformance instead of six integrations.

---

## v0.1 — the trust stack stands up  ·  done

- [x] Four primitives, bitemporal claims, ordinal authority
- [x] SQLite schema with FTS5, migrations, zero external dependencies
- [x] GitHub connector: repositories, commits, READMEs, language breakdowns
- [x] Rule-based entity resolution and claim extraction
- [x] Contradiction detection and append-only versioned beliefs
- [x] Domain firewall applied before ranking
- [x] Hybrid retrieval with per-signal attribution
- [x] Receipts with measured counters and nullable confidence
- [x] CLI: `doctor` `sync` `search` `ask` `claims` `contradictions` `memory` `trace` `rebuild`
- [x] macOS app over the same store
- [x] 13 tests at the time

---

## v0.2 — passages, senses, and surfaces  ·  done

- [x] Schema migration 2: chunks, chunk FTS5, chunk vectors, embedding-run coverage
- [x] Structure-first chunker (paragraph → sentence → hard cut) with overlap
- [x] `NLContextualEmbedding` provider, 512-dim, mean-pooled, on device
- [x] Resumable embedding indexer with coverage reporting
- [x] `PassageSearch`: dense + BM25 legs, RRF fusion, MMR diversification, context expansion
- [x] Filesystem connector with per-root domain assignment
- [x] Apple Calendar and Reminders via EventKit
- [x] Apple Notes via AppleScript, isolated in one file
- [x] `IngestPipeline` so CLI, app, and rebuild cannot drift apart
- [x] MCP server over stdio, hand-rolled, protocol 2025-11-25
- [x] External-caller policy: sensitive domains unreachable through MCP regardless of wording
- [x] 24 tests at the time

Measured `[measured]`: 691 objects → 966 chunks; embedding 966 passages took 25s on device;
a passage query runs dense in ~190ms and lexical in ~8ms over 966 chunks.

---

## v0.3 — make the central claim falsifiable  ·  doing

Everything below it is unfalsifiable without it. `opencore eval` exists and measured MMR's λ and the
dense weight. Benchmark v1 turned out to be fitted, and v2 is not built.

1. **Eval harness.** Exists, over 20 hand-written cases. Not yet: a fixture corpus with external
   ground truth, cases for status, time, personal data and follow-ups, or CI, which does not exist.
2. **Calibrate `Receipt.confidence`.** It is `nil` today, on purpose. Fill it only once a
   measurement exists that means something. Until then it renders as "not measured".
3. **Publish the results, including the bad ones.** A report saying a signal did not help is
   the strongest thing this project can produce, because almost nobody publishes negative
   results about their own work.
4. **Fix the BM25 clustering** found in the first run, and prove the fix with (1) rather than
   by eye.

## v0.4 — the second sync  ·  doing

Contradiction detection fired on real data: 14 rows, and most of them were document churn rather than
disagreement, which is what the honest-beliefs work fixed.

4b. **Claim extraction beyond GitHub.** Structured documents and some prose now produce claims.
   Reminders still produce none. Calendar events are read with attendees, and the
   stored ones need Re-read Whole Calendar.
5. **README claim extraction.** Partly in: a README can argue with a repository's metadata.
6. **Belief-change notifications.** Built, firing once per new pair of values. Delivery has never
   been observed, because the app has not run with it.

## v0.5 — retrieval, measured  ·  todo

7. **ANN index** over chunk vectors, once `doctor` shows brute-force cosine taking real
   time. Not before: an approximate index adds a tuning surface and a recall cliff, and
   trading recall for speed you do not need is a bad trade made twice.
8. **Compare embedders.** `NLContextualEmbedding` versus a bundled alternative, on the
   harness, with the losing result published.

## v0.6 — more of your history  ·  todo

9. **Office extraction.** Skipped rather than half-read. PDF text and on-device OCR are in.
10. **Mail connector**, tagged by folder the way Notes is.
11. **Model-proposed claims.** Built, entering at `modelInference`.
12. **Cross-source contradiction.** The flagship case: a README claiming something a
    calendar or a commit contradicts.

---

## Known open

- **App sandbox is off.** Sandboxed, the app and CLI maintain two separate databases that look
  identical and never agree. Re-enabling it needs a security-scoped bookmark to a shared store
  location. Required before any distribution. Reasoning is in `Apps/OpenCoreMac/project.yml`,
  where it will be read.
- **`Receipt.init(row:)` re-derives its id** from query plus millisecond timestamp. Round-trips
  correctly today because the stored `Double` reproduces exactly, but it is fragile. Store the
  id explicitly.
- **`ClaimExtractor.dormantAfter` is 180 days**, chosen not measured. It is a judgement call and
  named as one.
- **Entity resolution is conservative by design.** A wrong merge contaminates every claim on
  the entity with no record of the seam; a missed merge can be joined later with history intact.
- **`opencore rebuild` loads all objects into memory** in 500-row pages. It ran in 21 s at 9,537
  objects `[measured]`, and that is not 100k.
- **Dense search is brute-force cosine** over every stored vector. Deliberate at this scale;
  see v0.5 item 7 for when that stops being true.
- **Most retrieval constants are chosen**: RRF k=60, the 0.02 scaling on authority and recency, the
  1200-character chunk target, the 5% language-share floor, `dormantAfter` at 180 days. MMR's λ and
  the dense weight were set by the 2026-08-09 eval, over a benchmark since found to be fitted. Each
  is labelled where it appears.

## Explicitly not doing

Recorded so they stop being reconsidered:

- Cloud sync. The store is one file; back it up.

Two items once listed here were reversed: chat was built, and autonomous agents were reopened.
`Docs/ai/PROJECT.md` has the reasoning.
