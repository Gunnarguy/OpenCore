# OpenCore Roadmap

> **Roadmap truth is the Notion database, not this file.** This is the readable summary;
> Notion is what gets updated first and carries per-row evidence levels and leverage
> classification.
>
> Database `7dc3bd42-1933-4d25-847a-5bc98acac3fc`,
> data source `546d4b56-a91a-4324-92e7-738c9637d8d0` (query tools take the data source id).

Ordered by what unblocks what, not by what sounds best.

Status: `todo` · `doing` · `done` · `dropped`

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
- [x] 13 tests

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
- [x] 24 tests

Measured `[measured]`: 691 objects → 966 chunks; embedding 966 passages took 25s on device;
a passage query runs dense in ~190ms and lexical in ~8ms over 966 chunks.

---

## v0.3 — make the central claim falsifiable  ·  todo

**This is the priority, and it is deliberately before more features.** Everything below it is
unfalsifiable without it, and every number this project might quote is currently unmeasured.

1. **Eval harness.** A fixture corpus with external ground truth, plus recall@k, MRR and nDCG
   per retrieval stage. Run it in CI on every push.
2. **Calibrate `Receipt.confidence`.** It is `nil` today, on purpose. Fill it only once a
   measurement exists that means something. Until then it renders as "not measured".
3. **Publish the results, including the bad ones.** A report saying a signal did not help is
   the strongest thing this project can produce, because almost nobody publishes negative
   results about their own work.
4. **Fix the BM25 clustering** found in the first run, and prove the fix with (1) rather than
   by eye.

## v0.4 — the second sync  ·  todo

Contradiction detection is test-verified but has never fired on real data, because a first sync
has nothing to disagree with. Incremental sync landed in v0.2, so the machinery is in place and
what remains is the extraction that makes conflicts appear.

4b. **Claim extraction for non-GitHub sources.** Files, notes, calendar and reminders are
   ingested, chunked and retrievable but produce zero claims, because `ClaimExtractor` only
   understands GitHub object shapes. They are half-citizens until this lands: searchable,
   but invisible to `claims`, `contradictions`, and `memory log`.

5. **README claim extraction.** A README asserting something the code contradicts is the
   flagship demo, and it is a real problem: a documented capability that no longer exists gets
   retrieved and cited back as fact.
6. **Belief-change notifications** when a sync changes what the system thinks.

## v0.5 — retrieval, measured  ·  todo

7. **ANN index** over chunk vectors, once `doctor` shows brute-force cosine taking real
   time. Not before: an approximate index adds a tuning surface and a recall cliff, and
   trading recall for speed you do not need is a bad trade made twice.
8. **Compare embedders.** `NLContextualEmbedding` versus a bundled alternative, on the
   harness, with the losing result published.

## v0.6 — more of your history  ·  todo

9. **PDF and Office extraction.** Currently skipped rather than half-read.
10. **Mail connector**, tagged by folder the way Notes is.
11. **Model-proposed claims**, entering at `modelInference` and outranked by every rule.
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
- **`opencore rebuild` loads all objects into memory** in 500-row pages. Fine at 691 objects,
  not fine at 100k.
- **Dense search is brute-force cosine** over every stored vector. Deliberate at this scale;
  see v0.5 item 7 for when that stops being true.
- **Retrieval constants are all chosen, none measured**: RRF k=60, MMR λ=0.7, the 0.02
  scaling on authority and recency, the 1200-character chunk target, the 5% language-share
  floor, `dormantAfter` at 180 days. Each is labelled as chosen where it appears. The eval
  harness exists to replace them with numbers.

## Explicitly not doing

Recorded so they stop being reconsidered:

- A chatbot UI. The interesting surface is the receipt, not the conversation.
- Autonomous agents that act on your data.
- Cloud sync. The store is one file; back it up.
- Multiple model providers before there is a single measured number.
