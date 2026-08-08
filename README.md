<h1 align="center">OpenCore</h1>

<p align="center">
  <strong>An evidence-native runtime for personal intelligence.</strong>
</p>

<p align="center">
  <em>Not "AI that knows everything about you."<br>
  Software that can tell you what it knows, why it believes it, where it came from,<br>
  how confident it is, and what changed its mind.</em>
</p>

---

Most personal-AI systems store a fact and retrieve it. OpenCore stores the *evidence*, derives
claims from it, notices when two claims cannot both be true, decides which one currently
stands, and keeps the losing one so you can ask what it used to think.

```
your data → objects → evidence → claims → contradictions → beliefs → answer → receipt
            ▲ the floor          ▲ everything from here up is rebuildable
```

## What is actually different

**Observed and inferred are different rows.** "OpenIntelligence is written in Swift" comes from
GitHub's byte counts. "Gunnar prefers local-first architecture" is a pattern someone concluded.
Systems that store both in one `memories` table cannot tell you which is which, and neither
can you.

**Time has two axes.** Every claim carries *valid time* (when the fact held in the world) and
*transaction time* (when OpenCore held it). Collapsing those into one timestamp is the most
common modelling mistake in memory systems, and it makes "what did you believe in March?"
unanswerable. See [`Temporal.swift`](Sources/CoreModel/Temporal.swift).

**Authority is an ordinal tier, not a probability.** The temptation is `authority: 0.98` and
then, downstream, `score = confidence * authority`. That multiplication launders a guess into
a calibrated number. Here authority compares and breaks ties. It never multiplies.
See [`Authority.swift`](Sources/CoreModel/Authority.swift).

**Changing its mind is a write, not an edit.** Beliefs are append-only and versioned;
superseded claims are retracted, never deleted. `opencore memory checkout 2026-03-01`
reconstructs what the system believed on that date.

**Counter-evidence is a row.** `claim_evidence.stance` is `supports` or `refutes`. An answer
that cannot show what argues against it is not inspectable, it is just confident.

**Domains are a firewall, applied before ranking.** A project question never reads medical
records, and a sensitive domain opens only when the query *names* it. Filtering after ranking
still leaks that something relevant exists, and starves the allowed domains of slots.

**Unmeasured renders as "not measured."** Receipts have a nullable confidence, and it stays
null until an eval harness produces a real number. A receipt that fills in a plausible value is
worse than no receipt, because it looks like proof.

## What it reads

| Source | What comes in | Domain |
|---|---|---|
| **GitHub** | repositories, commits, READMEs, language breakdowns | project / public |
| **Local files** | markdown, text, code — per-folder | **you choose, per folder** |
| **Apple Calendar** | events, attendees, locations | personal |
| **Apple Reminders** | tasks, lists, completion | personal |
| **Apple Notes** | notes and folders, via AppleScript | per folder, default personal |

Calendar and Reminders are `personal` and not configurable. A calendar is the richest
source of who you meet, when you are ill, and who you are close to, and it arrives looking
like harmless scheduling metadata. Details in [Docs/CONNECTORS.md](Docs/CONNECTORS.md).

## Try it

```bash
swift build && swift test
```

```bash
.build/debug/opencore sync github && .build/debug/opencore embed
```

```bash
.build/debug/opencore ask "What is OpenClinic built with?"
```

```
Q: What is OpenClinic built with?

3 claims bear on this: 2 read directly from source data, 1 inferred.

• OpenClinic is built with Swift.
  confidence 0.99 · authored artifact · observed
  ← Language composition of Gunnarguy/OpenClinic, by bytes: Swift: 788285 bytes (99%)…
~ OpenClinic is active.
  confidence 0.85 · derived pattern · inferred

── receipt oc_d74555 ──────────────────────
objects searched      691
objects retrieved     12
evidence admitted     3
claims consulted      3
domains blocked       financial, medical, personal, relationship, work
model                 none — assembled from claims
objects transmitted   0
confidence            not measured
    retrieve            15ms  blocked_by_domain=0 candidates=200 retrieved=12
```

No model wrote that. Every line came from a claim row with evidence attached, which is why the
receipt's counters are measurements rather than estimates.

### Retrieval

Two legs, fused by **rank** rather than score:

```
query ──┬─► dense   (cosine over on-device NLContextualEmbedding vectors) ──┐
        └─► lexical (BM25 over passage FTS5) ───────────────────────────────┴─► RRF ─► MMR ─► admit ─► expand
```

BM25 returns unbounded negatives and cosine returns -1…1, so blending the raw values means
inventing a normalisation constant that ends up doing more work than either retriever.
Reciprocal Rank Fusion compares ranks, which are comparable by construction.

```bash
.build/debug/opencore passages "why did retrieval move on device"
```

```
legs        lexical 100 · dense 100 → fused 184
timings     dense 189ms · fuse 0ms · lexical 8ms · mmr 1ms
chunks      966 searched, 0 withheld by domain, 4 dropped by MMR

 1. ████████████████████ 0.0330  [dense#11 lexical#10]   OpenIntelligence — README
 2. █████████████████░░░ 0.0290  [dense#3  lexical#57]   fix(Infrastructure): make workspace metadata writes atomic
 3. ████████████████░░░░ 0.0274  [dense#70 lexical#6]    Update OpenIntelligence FAQ: drop parameter-count claim
```

Rows 2 and 3 are why both legs exist: each was near-invisible to one retriever and near the
top of the other. Embeddings are Apple's `NLContextualEmbedding`, 512-dimensional, computed
on device — 966 passages in 25 seconds, nothing uploaded.

### As MCP infrastructure

```bash
.build/debug/opencore mcp
```

Six tools — `core_ask`, `core_search`, `core_claims`, `core_contradictions`,
`core_changed`, `core_trace` — so an assistant can answer from your history and then show
you the commits behind the answer.

**An MCP caller is not you.** Locally, naming a sensitive domain in a query opens it,
because a person typing *"what did my doctor say"* is consenting by asking. Over MCP the
query text is written by a model, and a model asking about your diagnosis is not consent.
Sensitive domains are unreachable through the server regardless of wording, and the receipt
says so. Setup and the full reasoning: [Docs/MCP.md](Docs/MCP.md).

### Commands

| | |
|---|---|
| `opencore doctor` | database, credentials, what is stored |
| `opencore sync github` | repositories, commits, READMEs, language breakdowns |
| `opencore search "TEXT"` | hybrid retrieval, with each signal's contribution shown |
| `opencore ask "QUESTION"` | an answer assembled from claims, with a receipt |
| `opencore claims [ENTITY]` | current claims, observed and inferred marked separately |
| `opencore contradictions` | conflicts found, and how each was settled |
| `opencore memory log --since 30d` | what the system learned or changed its mind about |
| `opencore memory checkout 2026-03-01` | what it believed on a past date |
| `opencore trace oc_abc123` | the exact evidence behind one answer |
| `opencore embed` | build on-device vectors for every passage |
| `opencore passages "TEXT"` | passage retrieval: dense + BM25, RRF, MMR |
| `opencore mcp` | serve MCP over stdio |
| `opencore rebuild` | drop every derived layer and re-derive from objects |

`rebuild` is the load-bearing one. If it does not reproduce the graph, the claim that objects
are the floor is false. Verified `[measured]`: 691 objects → 966 chunks, 38 entities,
82 claims, identical to the pre-rebuild graph.

### macOS app

```bash
cd Apps/OpenCoreMac && xcodegen generate && open OpenCore.xcodeproj
```

Same engine, same store. The app and the CLI read one database on purpose.

## Layout

| Module | Owns |
|---|---|
| `CoreModel` | the vocabulary. Value types, no I/O, no dependencies |
| `CoreStore` | SQLite. **Every SQL string in the project is here** |
| `CoreIngest` | connectors. Produce objects and nothing else |
| `CoreGraph` | entity resolution, claim extraction, contradictions, beliefs |
| `CoreSearch` | admission policy, embeddings, RRF fusion, MMR |
| `CoreReason` | query planning, assembly, receipts |
| `CoreMCP` | JSON-RPC over stdio |

Zero external dependencies, including the MCP server. A personal knowledge store that stops
building when a package moves is a personal knowledge store you lose.

## What is not true yet

Stated plainly, because the whole project is an argument for doing that:

- **No calibrated confidence.** Claim confidences are hand-set except the language-share
  number, which is genuinely derived. Receipt confidence is `nil` and renders as
  "not measured".
- **No eval harness.** Nothing here has a measured accuracy number, so this README does not
  quote one. Retrieval constants — RRF's k=60, MMR's λ=0.7, the 0.02 signal scaling — are
  all *chosen*, and are labelled as chosen everywhere they appear.
- **Contradiction detection is test-verified, not yet field-observed.** A first sync has
  nothing to contradict; conflicts appear on the second sync after a source changes its mind.
- **Dense search is brute force.** Linear cosine over every vector. Deliberate at personal
  corpus scale: an ANN index adds a tuning surface and a recall cliff before anything has
  been measured. `doctor` showing real time on this is the signal to build it.
- **Lexical scores cluster** in the object-level scorer. Found on the first run, recorded
  rather than tuned by eye.
- **No PDF or Office extraction.** Those files are skipped, not half-read, because a PDF
  read as UTF-8 becomes plausible garbage that gets embedded and cited.
- **Calendar and Reminders need the app.** EventKit reads usage strings from the calling
  binary's Info.plist, which a SwiftPM executable does not have. The CLI reports that
  specific cause rather than returning an empty calendar.
- **Only GitHub produces claims.** Files, notes, calendar and reminders are ingested,
  chunked, embedded and retrievable, but the claim extractor only understands GitHub
  shapes, so they contribute passages and not beliefs. `sync files` reporting
  `claims 0` is correct behaviour today, not a failure.
- **Rule-based extraction only.** A model may later *propose* claims. It would enter at
  `modelInference`, the bottom authority tier, outranked by every rule.

## License

MIT
