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

**Domains are a firewall, applied before ranking.** Local queries use explicit domain admission.
MCP excludes sensitive and restricted domains unless the server is deliberately launched with
`--unsafe-expose-sensitive`; model-written query wording cannot grant consent. Filtering after
ranking still leaks that something relevant exists, and starves the allowed domains of slots.

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
| **Apple Health** | workouts and daily step totals, synced from the app | medical, not configurable |

Calendar and Reminders are `personal` and not configurable. A calendar is the richest
source of who you meet, when you are ill, and who you are close to, and it arrives looking
like harmless scheduling metadata. Details in [Docs/CONNECTORS.md](Docs/CONNECTORS.md).

## Using the app

Open **How it connects** in any workspace to choose an outcome and follow one of your projects
through its records. Technical screens keep their names, paired with a consistent vocabulary:
Corpus holds originals, Passages searches excerpts, Claims shows extracted statements, Beliefs
records decisions and revisions, and Receipts audits recorded answer paths.

Use **Inspect evidence** to check a statement, then **Inspect original** to read its source.
Subject links keep that project or person in view with a visible filter; global totals open
the global view. Shared navigation also connects projects and agents, supported Mac tasks,
model readiness, hardware, history and store health. All advanced workspaces remain available.

Use **Hardware, USB & Disk → View → Displays** for connected monitors, their current desktop
modes, render size and exact modes macOS offers. Test a resolution/refresh/scaling mode with
a 15-second Keep/Revert preview. When BetterDisplay is running, the same screen also exposes
live hardware picture controls, compatible signal modes, its installed feature catalog and complete
capability/EDID/input reports. Monitor controls are grouped into Picture, Resolution & Signal,
Inputs & Power, and Advanced. Explanations expand beside each control, and the hardware browser
stays visible when the app sidebar is hidden. Values are read from the selected monitor; unsupported requests
remain visible. USB devices and display outputs have separate lists.

## Try it

```bash
swift build --scratch-path /private/tmp/opencore-build
swift test --scratch-path /private/tmp/opencore-build
```

```bash
alias opencore=/private/tmp/opencore-build/out/Products/Debug/opencore
opencore sync github && opencore embed
```

```bash
opencore ask "What is OpenClinic built with?"
```

Any scratch path works, as long as it is outside a synced folder: iCloud stamps attributes on build
inputs and code signing rejects them.

```
Q: What is OpenClinic built with?

3 claims bear on this: 2 read directly from source data, 1 inferred.

• OpenClinic is built with Swift.
  confidence 0.99 · authored artifact · observed
  ← Language composition of Gunnarguy/OpenClinic, by bytes: Swift: 788285 bytes (99%)…
~ OpenClinic is active.
  confidence 0.85 · derived pattern · inferred

── receipt oc_d74555 ──────────────────────
objects searched      9537
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
receipt's counters are measurements rather than estimates. An answer leads with the subject you
named and the predicate you asked about, in a stable order, with passages after the claims.

### Retrieval

Two legs, fused by **rank** rather than score:

```
query ──┬─► dense   (cosine over on-device NLContextualEmbedding vectors) ──┐
        └─► lexical (BM25 over passage FTS5) ───────────────────────────────┴─► RRF ─► MMR ─► admit ─► expand
```

BM25 returns unbounded negatives and cosine returns -1…1, so blending the raw values means
inventing a normalisation constant that ends up doing more work than either retriever.
Reciprocal Rank Fusion compares ranks, which are comparable by construction.

The 2026-08-09 eval scored the fused result lower with the dense leg than without it, so
the default runs the lexical leg alone. The example below predates that, and its counts come from
a small early store.

```bash
opencore passages "why did retrieval move on device"
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

### Any MCP server is a source

The official registry passed 9,650 servers. Rather than hand-writing an integration per
service, OpenCore speaks the protocol they already speak.

```bash
opencore mcp-source discover --command some-mcp-server     # lists tools, calls nothing
opencore mcp-source add work --command some-mcp-server --tool list_issues --domain work
opencore sync mcp work
```

**Nothing is called unless you name it.** An MCP server advertises write tools too —
`send_message`, `delete_file` — and a sync that guessed wrong would not return a bad answer,
it would send an email. So the policy is default-deny with an explicit allowlist, and there is
no automatic path around it: the server's own `readOnlyHint` is a claim from an untrusted peer,
and `get_message` reads while `get_approval` might send one. `discover` prints an advisory to
shorten your review; the call path never reads it.

`--env NAME` forwards a variable **by name**. Values are read from your environment at launch
and never touch the database.

### As MCP infrastructure

```bash
opencore mcp
```

Eight tools — `core_ask`, `core_search`, `core_claims`, `core_contradictions`,
`core_changed`, `core_trace`, `core_dossier`, `core_timeline` — so an assistant can answer from
your history and then show you the commits behind the answer.

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
| `opencore eval` | retrieval quality per leg over a benchmark |
| `opencore mcp` | serve MCP over stdio |
| `opencore chat "QUESTION"` | a model answer grounded in cited sources, saved as a thread |
| `opencore timeline`, `receipts`, `correct`, `export` | events, past answers, a correction, a full export |
| `opencore repair-agent-memory` | read-only report of imported memory policy; `--apply` needs a new backup path |
| `opencore rebuild` | re-derive a **copy** from objects and show what would change, by id |
| `opencore rebuild --apply-rehearsal DIR` | apply a rehearsal you have read, in one transaction |

`rebuild` is the load-bearing one. If it cannot reproduce the graph, the claim that objects are
the floor is false. It never touches the store it is pointed at: it rebuilds a copy, carries
across what derivation cannot produce (corrections, quarantine, receipt links, vectors, the dates
things were first known), and reports the difference claim by claim. A rehearsal that would make
anything readable by more callers cannot be applied. This path has not had its review yet, so read
"What is not true yet" before applying one.

### macOS app

```bash
./script/build_and_run.sh --build-only
```

`--verify` also replaces `/Applications/OpenCore.app` and launches it. Same engine, same store. The
app and the CLI read one database on purpose.

## Layout

| Module | Owns |
|---|---|
| `CoreModel` | the vocabulary. Value types, no I/O, no dependencies |
| `CoreJSONRPC` | JSON-RPC types and transports, shared by the MCP server and the MCP client |
| `CoreTelemetry` | measurement, bounded child processes, display parsing. Depends on nothing |
| `CoreStore` | SQLite. **Every SQL string in the project is here** |
| `CoreIngest` | connectors, and the schedule and one-sync-at-a-time lane. Connectors produce objects and nothing else |
| `CoreGraph` | ingest pipeline, entity resolution, claim extraction, contradictions, beliefs, sync rules, rebuild rehearsal |
| `CoreSearch` | admission policy, embeddings, RRF fusion, MMR, time windows |
| `CoreReason` | query planning, focus, assembly, chat, grounding, receipts |
| `CoreMCP` | the MCP server, over JSON-RPC on stdio |
| `opencore` | the CLI |
| `Apps/OpenCoreMac` | the SwiftUI app, including the operator console, which is outside the evidence store |

Zero external Swift dependencies, including the MCP server. A personal knowledge store that stops
building when a package moves is a personal knowledge store you lose. Developer tooling is another
matter: the app project needs `xcodegen`, and the operator screens talk to BetterDisplay and a local
automation service when they are present.

## What is not true yet

Stated plainly, because the whole project is an argument for doing that:

- **Three pieces of work are open.** Home has code in the tree that has not had its review.
  Hardening is partly in the tree and unreviewed. The WWDC26 currency pass has not been done.
  Rebuild has been reviewed and proved on a copy, and has never been applied to the live store.
  That stays the owner's decision.
- **The app has not been launched with the latest work.** It builds. Nobody has seen the new Home,
  Maintenance or Sources screens, and scheduled sync and notification delivery have never run.
- **Display connection attribution is incomplete.** The display inventory sees current screens
  and modes, but does not establish the physical HDMI/DisplayPort socket, dock, cable or panel
  maximum. Descriptor and BetterDisplay link reports can reflect overrides/adapters; configured
  input labels are not a physical socket inventory. Native mode previews and BetterDisplay DDC,
  signal and simple feature controls are implemented. Context-heavy controller/mirror/stream
  operations remain inspectable and open in BetterDisplay. Firmware analysis is not implemented.
  External monitor brightness changes and live readback are verified with restoration to the original value.
  Other physical adjustments and automatic mode rollback remain unverified.
- **Time phrases cover spans, not every date.** "Recently", "last week", "in March", "since
  August", "the last week of September" and "last night" filter an answer. "Recently" is a chosen
  14 days, and the parts of a day and the seven days at the edge of a month are chosen too. Single
  dated days ("on October 12", "last Monday"), future spans ("next week", "tonight", "this
  weekend"), two-ended ranges and a position inside something undated ("the last week of the
  sprint") are not read, so those questions search all of time. An object with no date cannot be
  placed in a window, so a filtered answer leaves it out, and the Passages screen says so.
  A count with a time phrase reports every event in the window: "how many commits this month"
  includes the other verbs, and "how many meetings this month" says it is not a count of meetings.
  "These days" asks how things stand, so it keeps the current count. Freshness is by kind of
  source, so one stale folder beside a fresh one does not show. A window's edges come from the
  machine's calendar, and that is also true of an MCP client asking from another zone.
- **A repository's status is a reading of commit titles.** Which commits count as upkeep is a chosen
  list of title prefixes plus bot authors, because the floor keeps a commit's title and author and
  not its files. A commit titled "docs" that holds real work doesn't wake a repository. Commits on
  other branches aren't read, so work that has only been pushed there can read as dormant.
- **A document's date is the file's date.** Revisions of one document are ordered by modification
  time, so a stale copy saved later than the real file wins until the real file changes. Two
  documents are the same document if they share a file name within one project and one predicate.
- **A correction outlasts every later document.** Correcting a project's objective holds against
  every newer handoff, and each of those conflicts says the newer claim lost. Nothing expires a
  correction yet, so a plan you corrected once needs correcting again when it moves on.
- **Repositories listed only in `private-names.json` are not synced without it.** That file is
  private, so this repository can't ship it. With it missing they are left out rather than guessed
  at, and one listed after being marked `restricted` stays restricted, because no retag action
  exists yet.
- **No calibrated confidence.** Claim confidences are hand-set except the language-share
  number, which is genuinely derived. Receipt confidence is `nil` and renders as
  "not measured".
- **A small eval harness, and benchmark v1 was fitted.** `opencore eval` scores retrieval per leg
  over the 20 hand-written cases in `Benchmarks/rag_eval_v1.jsonl`. Its 2026-08-09 run set MMR's λ to
  0.85 and the dense weight to 0. RRF's k=60 and the 0.02 signal scaling are still chosen. Some rules
  once mirrored benchmark rows and were removed on 2026-10-30, and the benchmark has no status,
  time, personal or follow-up cases, so it says little about the answers people actually read.
- **Contradiction detection is test-verified and now field-observed**, on the real store,
  where most of what it found was document churn rather than disagreement. A document rewriting
  itself now resolves by time and raises nothing. See `Docs/ai/DECISIONS.md`, 2026-10-30.
- **Some claims on an existing store have lost their own evidence, and no answer shows them.**
  Recording shared evidence as counter-evidence used to overwrite a claim's own support, and that
  no longer happens, but the damage stays until a rebuild. On 2026-10-31 it had left 9 current claims
  with nothing supporting them, including both sides of each open contradiction, and an answer drops
  a claim with no support. On a copy a rebuild takes that to 0.
- **Personal data can't be asked about yet.** Notes, calendar and reminders are stored, and `personal`
  stays closed to local ask as well as to MCP. "Who contributed to X" shows nobody, because every
  person entity is `personal`. Saying "my journal" does not open it.
- **A repository's archive flag has no history of its own.** Archiving changes metadata and not the
  record's text, so no earlier version is kept, and a rebuild reads only the current flag. GitHub
  gives no archive date either, so `archived` is dated by the last push, which is a floor on when it
  happened rather than when it happened.
- **A model is told to repeat a caveat, and nothing forces it to.** Chat gives it each claim's
  counter-evidence and contradictions, and the first real case left them out of its prose. They
  stay in that claim's source and in the receipt.
- **Scheduled sync runs only while the app is running.** Calendar and Reminders can only be read
  by the app bundle, so a closed app means they do not refresh. Three days of unattended
  freshness has not been observed yet.
- **Apple Notes has never returned a record.** The connector now reports that as a failure
  instead of "already up to date", but why the one real sync returned nothing is not established.
- **Password-protected notes are left out,** and the app shows no count of them. Domain for the rest
  comes from a guess at the folder name.
- **The operator console is not part of the evidence store.** Fleet, hardware, monitor and
  computer-use screens write no objects or receipts, are off Home by default, and have no tests
  of their own.
- **Dense search is brute force.** Linear cosine over every vector. Deliberate at personal
  corpus scale: an ANN index adds a tuning surface and a recall cliff before anything has
  been measured. `doctor` showing real time on this is the signal to build it.
- **Lexical scores cluster** in the object-level scorer. Found on the first run, recorded
  rather than tuned by eye.
- **Document extraction has limits.** PDF text layers and on-device Vision OCR for scanned
  pages and images are implemented. PDF text and image OCR fixtures pass; extraction is not
  a guarantee of complete or correct recognition. Office files remain unsupported.
- **Calendar and Reminders need the app.** EventKit reads usage strings from the calling
  binary's Info.plist, which a SwiftPM executable does not have. The CLI reports that
  specific cause rather than returning an empty calendar.
- **Extraction is selective.** GitHub metadata, accepted calendar attendees, supported
  structured documents and selected prose patterns produce claims. Arbitrary ingested text
  can remain retrievable without producing a claim.
- **Model proposals are inferences.** Optional model-proposed claims enter at
  `modelInference`, the bottom authority tier. Exact source spans are checked; a matching quote
  proves where the words occurred, not that the proposed interpretation is true.
- **Live computer control has known gaps, so leave it on dry run.** The app's Stop, step actions and
  dry-run default have tests for their decisions but have never been run live, and the Local Hub
  still has gaps of its own. All recorded runs were practice.
- **Computer-use support is partial.** Supported Local Hub tasks, routines and model lifecycle
  calls are wired. Desktop recording and live coordinate replay are unfinished and marked
  unavailable. All 13 local model choices have run in Model Lab. Seven vision adapters currently return
  screenshot target locations; they are excluded from unsupported task scopes. Local trial
  results include failures and do not establish desktop-control accuracy or unattended reliability.
  **Model Lab → Rank every model** compares all choices by job on the recorded chip/RAM/OS
  and runtime. **Storage & delete downloads** shows package costs and named confirmation
  controls. Unloading frees RAM; deleting a download removes model files and keeps results/history.
- **Private history needs conservative recovery.** The 2026-10-23 audit repaired imported
  agent-memory policies while preserving original objects, receipts and history. Unproven
  interpretations are quarantined pending reviewed replay. Do not use a blind rebuild as
  recovery: corrections and statements without replayable floor evidence now block it.
- **Shared context does not imply identical agents.** Shared skills, files and handoffs help
  continuity. Vendor-specific hooks, permissions, tools and session behavior still need their
  own verification; counting configuration files does not prove those workflows executed.

## License

MIT
