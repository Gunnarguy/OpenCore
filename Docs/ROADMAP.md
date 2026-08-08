# OpenCore Roadmap

Ordered by what unblocks what, not by what sounds best.

Status: `todo` · `doing` · `done` · `dropped`

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

## v0.2 — make the central claim falsifiable  ·  todo

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

## v0.3 — the second sync  ·  todo

Contradiction detection is test-verified but has never fired on real data, because a first sync
has nothing to disagree with.

5. **Incremental sync** using the stored cursor, so re-syncs are cheap and the second one is
   the interesting one.
6. **README claim extraction.** A README asserting something the code contradicts is the
   flagship demo, and it is a real problem: a documented capability that no longer exists gets
   retrieved and cited back as fact.
7. **Belief-change notifications** when a sync changes what the system thinks.

## v0.4 — semantic retrieval, measured  ·  todo

8. **`NLContextualEmbedding` provider.** Apple-authored, on-device, no model download. It has
   never been measured on a personal corpus, which makes measuring it interesting rather than
   routine.
9. **Vector storage and ANN search** over `object_vector`. The schema keys vectors by model so
   two embedders' vectors can never end up in one similarity search.
10. **Only then** turn the semantic weight on, with a before/after number from the harness.

## v0.5 — more of your history  ·  todo

11. **Filesystem connector** over notes and documents.
12. **Model-proposed claims**, entering at `modelInference` and outranked by every rule.
13. **MCP server** — `search_core`, `inspect_claim`, `get_evidence`, `trace_receipt`. This is
    where OpenCore stops being an app and becomes something other tools query.

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

## Explicitly not doing

Recorded so they stop being reconsidered:

- A chatbot UI. The interesting surface is the receipt, not the conversation.
- Autonomous agents that act on your data.
- Cloud sync. The store is one file; back it up.
- Multiple model providers before there is a single measured number.
