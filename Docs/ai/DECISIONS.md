# Decisions

Append-only. Each entry records rationale that cannot be reconstructed from the code, because
the code shows *what* was chosen and never *what was rejected and why*.

Do not record trivial coding choices here.

---

## 2026-08-07 — Authority is an ordinal enum, not a Double

**Decision.** `Authority` is a `Comparable` enum with six tiers and no arithmetic.

**Context.** Sources differ in trustworthiness: a user statement outranks a commit message,
which outranks a model inference. Every design sketch for this reached for decimal weights.

**Alternatives.** Decimal weights 0.0–1.0, which is what the originating design document
proposed (`user states: 1.00, commit: 0.98, model inference: 0.40`).

**Rationale.** Store it as a `Double` and someone downstream writes
`score = confidence * authority`. That multiplies a calibrated number by an invented constant
and produces something that *looks* calibrated. The originating document even admitted the
values "shouldn't be arbitrarily treated as statistical probabilities" — correct instinct,
wrong data type. An ordinal tier makes the mistake a compile error.

**Consequences.** Blending authority into a retrieval score requires an explicit, visible
normalisation at the one call site that does it. Adjudication compares tiers and never
combines them.

---

## 2026-08-07 — Claims are bitemporal

**Decision.** Every claim carries valid time (`valid_from`/`valid_to`) and transaction time
(`observed_at`/`retracted_at`) as independent axes.

**Context.** "What was true in March?" and "What did you believe in March?" are different
questions with different answers, and both need to be answerable.

**Alternatives.** A single timestamp, which is what nearly every memory system uses.

**Rationale.** Collapsing the axes makes both questions unanswerable. A claim learned today
about something true last year has `valid_from` last year and `observed_at` today; with one
timestamp you cannot represent that at all.

**Consequences.** More columns, more index surface, and `memory checkout` becomes a real query
rather than a feature that has to be faked.

---

## 2026-08-07 — Only functional predicates can contradict

**Decision.** `Predicate.functional` names the predicates where one subject may hold one value.
Contradiction detection considers no others.

**Context.** The naive version treats every repeated `(subject, predicate)` as a conflict.

**Rationale.** A project genuinely is built with Swift *and* Python. Treating that as a
contradiction manufactures drama out of ordinary multi-valued data and destroys trust in the
conflicts that are real.

**Consequences.** Adding a predicate to the functional set is a meaningful change, not a
config tweak.

---

## 2026-08-07 — Equal authority with no ordering stays unresolved

**Decision.** When two competing claims have the same authority tier and no usable temporal
ordering, `Resolution.unresolved` is recorded, both claims are retained, and neither is
retracted.

**Rationale.** A system that always picks a winner is reporting a coin flip as a conclusion.
Being able to say "I do not know which of these is right" is the feature.

**Consequences.** `contradictions --open` can be non-empty indefinitely, and that is correct
behaviour rather than a backlog.

---

## 2026-08-07 — The macOS app sandbox is off

**Decision.** `com.apple.security.app-sandbox: false` for now.

**Context.** Sandboxed, `Store.defaultPath()` resolves inside the app container, so the app and
the `opencore` CLI would maintain two separate databases that look identical and never agree.
The sandbox also blocks shelling out to `gh auth token`.

**Alternatives.** Ship sandboxed and accept two stores; or ship sandboxed with a
security-scoped bookmark to a shared location.

**Rationale.** For a tool whose entire claim is that you can inspect what it knows, two
divergent stores is the worst available failure. The bookmark is the right answer but is not
free, and this is v0.2 of a personal tool with no distribution.

**Consequences.** Cannot be distributed as-is. Tracked in Notion as required before
distribution. The reasoning lives in `Apps/OpenCoreMac/project.yml` where someone flipping the
flag will actually read it.

---

## 2026-08-08 — Domain classification masks known entity names before keyword matching

**Decision.** `AdmissionPolicy.classifyDomain` masks every surface in `entity_alias` out of the
query, then matches domain keywords on **whole words only**.

**Context.** Found by running it: *"What is OpenClinic built with?"* was classified `.medical`
because `clinic` matched as a substring of the project name. Every domain was blocked and the
answer was "not enough evidence" for a question the store could answer completely.

**Rationale.** Two independent guards, because either alone leaves a hole. Whole-word matching
fixes `OpenClinic`; name masking fixes a repo literally called `Budget`.

**Consequences.** Classification now needs store access for the alias list, so
`classifyDomain` takes `knownEntitySurfaces`. Both guards are asserted separately in tests so
removing one cannot pass.

---

## 2026-08-08 — Retrieval legs are fused by rank, not by score

**Decision.** `PassageSearch` combines the dense and lexical legs with Reciprocal Rank Fusion.

**Context.** BM25 returns unbounded negative values; cosine similarity returns −1…1.

**Alternatives.** Normalise both into 0…1 and take a weighted sum.

**Rationale.** Any normalisation is invented, and the invented constant ends up doing more work
than either retriever. Ranks are comparable by construction. RRF `k=60` is the value from the
original formulation, used unchanged because nothing here has measured an alternative.

**Consequences.** Scores are small (~0.03) and not interpretable as probabilities. Non-relevance
signals fold in afterwards with an explicit `0.02` scaling that is flagged as arbitrary.

---

## 2026-08-08 — An MCP caller cannot unlock sensitive domains

**Decision.** `MCPServer.sensitiveDomainsUnlockable` defaults to `false`. No wording in a tool
call reaches medical, financial or relationship data. A query that classifies as sensitive is
re-based to `project` rather than refused.

**Context.** Locally, naming a sensitive domain in a query opens it, on the theory that a person
typing "what did my doctor say" is consenting by asking.

**Rationale.** Over MCP the query text is written by a model. A model asking about your
diagnosis is not consent. The same input carries different authority depending on who composed
it, and the transport is the only reliable signal of that.

**Consequences.** An escape hatch exists (`--unsafe-expose-sensitive`) and is named to be
uncomfortable to type. Receipts record the block either way.

---

## 2026-08-08 — MCP JSON-RPC is hand-rolled

**Decision.** No dependency on the official MCP Swift SDK.

**Context.** The SDK exists, is official, and implements the spec properly.

**Rationale.** The zero-dependency guarantee is a real constraint of this project, not an
aesthetic one. The stdio transport is newline-delimited JSON-RPC and the needed surface is five
methods; the SDK would cost a dependency and a version-pinning surface to save a few hundred
lines.

**Consequences.** Spec upgrades are manual work. Already relevant: the shipped server implements
`2025-11-25` and `2026-07-28` is a breaking revision.

---

## 2026-08-08 — Durable AI docs live in `Docs/ai/`, not `docs/ai/`

**Decision.** Capital `Docs/`.

**Context.** The Context OS specification suggests `docs/ai/`. This repository already has
`Docs/`, and macOS is case-insensitive by default: creating `docs/ai/` silently lands inside
`Docs/`.

**Rationale.** Git would then record a path whose casing does not match the directory, which
breaks on case-sensitive filesystems such as Linux CI. `Docs/ai/` also matches the sibling
OpenIntelligence repository.

**Consequences.** Any instruction referencing `docs/ai/` should be read as `Docs/ai/`.

---

## 2026-08-08 — No `Docs/ai/ARCHITECTURE.md`

**Decision.** The knowledge plane deliberately omits the architecture file the specification
lists, and `INDEX.md` points at the existing `Docs/ARCHITECTURE.md` instead.

**Rationale.** `Docs/ARCHITECTURE.md` already exists, is thorough, and labels every claim with
how it was verified. A second architecture document would drift from it, and two documents
disagreeing about the system is precisely the failure mode this project exists to surface.

**Consequences.** A reader following the specification literally will find a file missing. The
omission is stated in `INDEX.md` with the reason.

---

## 2026-08-08 — OpenCore runs no language model

**Decision.** `Reasoner` assembles answers deterministically from claim rows. `Receipt.model`
is `nil` because nothing generated anything.

**Context.** The obvious build is retrieve-then-prompt-a-model. That is what every comparable
product does, and it is one afternoon of work.

**Rationale.** Every sentence in an answer maps to a claim row with evidence attached, which
is what lets the receipt's counters be measurements rather than estimates. A model in that
position produces prose nobody can attribute, and the receipt would then be describing a
provenance the answer does not have.

**Consequences.** This is why most of OpenIntelligence's engine is absent rather than
pending: verification gates, PCC routing, and multi-pass reasoning all operate on generated
text, and there is none. Measured 2026-08-08, OpenCore has roughly a fifth of that engine —
the fusion layer only. Answers are also duller than a model would write, and that is the
trade.

When the WWDC26 `LanguageModel` protocol lands and a model does write the prose, verification
gates stop being optional: an ungrounded sentence inside a receipt claiming "assembled from
claims" would be the worst thing this project could ship.

---

## 2026-08-08 — CoreJSONRPC is its own module

**Decision.** JSON-RPC types and the stdio transport live in a dependency-free `CoreJSONRPC`,
imported by both `CoreMCP` (server) and `CoreIngest` (client).

**Alternatives.** Put them in `CoreModel`; or have `CoreIngest` depend on `CoreMCP`.

**Rationale.** The second would make ingestion depend on the entire reasoning stack, since
`CoreMCP` pulls in `CoreReason`. The first would put protocol plumbing in the domain
vocabulary. A third small module costs nothing and keeps the dependency graph a DAG that
still reads top to bottom.

---

## 2026-08-08 — MCP tools are default-deny, with no automatic path around it

**Decision.** An MCP source calls only tools named in an explicit allowlist. Nothing derives
one, including the server's own `readOnlyHint`.

**Context.** MCP servers advertise write tools: `send_message`, `create_issue`, `delete_file`.

**Alternatives.** Trust `readOnlyHint`; or allow tools whose names begin with a reading verb.

**Rationale.** The specification states annotations come from an untrusted server and must not
drive safety decisions. Name heuristics fail on the cases that matter: `get_message` reads,
`get_approval` might send one. A wrong guess here does not return a bad answer, it sends an
email. `MCPTool.readOnlyAdvisory` exists only to shorten a human's review list and the call
path never reads it.

**Consequences.** Adding a server is two steps rather than one, deliberately. Registry
metadata is rich enough to make auto-allowlisting tempting, and it must stay refused.

---

## 2026-08-08 — App preferences live in UserDefaults, not the store

**Decision.** `AppSettings` writes to `UserDefaults`. The SQLite store holds no preferences.

**Rationale.** The store is the user's data and the thing they export, back up, and move
between machines. A preference travelling with a dataset is wrong in both directions: an
export would carry settings nobody asked for, and a fresh install would inherit tuning from
whoever produced the file.

**Consequences.** The CLI and the app do not share tuning. The CLI takes flags. If they ever
need to agree, the settings belong in a config file both read, still not in the store.
