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

---

## 2026-08-08 — "Objects are the floor" has a limit: rebuild cannot recover what was never captured

**Found by running it.** Teaching `ClaimExtractor` to read calendar attendees produced zero
`met_with` claims across 558 calendar events. The extractor was correct; the objects on disk
had no attendee metadata, because they were ingested before the connector was taught to record
it.

**The distinction that matters.** `rebuild` re-derives everything above `object` and is the
right tool when *extraction* changes. It is the wrong tool when the *connector* changes, and
nothing in the system currently says which one a given change was.

- Connector change → **re-sync**. New fields, new metadata, a different API call.
- Extractor, resolver or chunker change → **rebuild**. Same objects, different conclusions.

**Consequences.** The floor guarantee is real but narrower than it sounds: objects are the
floor *for what was captured*, not for what the source contained. A connector that discards a
field discards it permanently, which makes "keep the raw payload" a genuinely different design
from "keep the fields we currently parse".

Recorded rather than fixed. The cheap mitigation is for a connector to record a schema version
in `source.config` so a sync can tell it is behind; that is on the roadmap, not done.

---

## 2026-08-08 — Grounding has a third failure mode: faithful to the wrong sources

**Found by running the first real chat query.** Asked "what have I been building in OpenCore
recently?", the model answered about rebranding an app and migrating it to a Swift Package,
with correct citations. That work is WoWCA, a different repository.

The grounding check reported **3 of 3 sentences supported, and it was right**. Every sentence
was faithful to the passage it cited. The passages were simply about the wrong project.

**So there are three ways a grounded answer can be wrong**, and the check catches one:

1. *Unsupported* — a sentence about something absent from the context. **Caught.**
2. *Inverted* — a sentence that reverses the meaning of something present. Not caught; lexical
   overlap cannot see negation. Already documented.
3. *Faithful to irrelevant sources* — every sentence checks out, and the retrieval answered a
   different question. **Not caught, and not catchable at this layer at all.**

The third is the dangerous one, because it produces a confident, well-cited, verifiable answer
that is about the wrong thing. Verification operating downstream of retrieval can never detect
it: by the time the check runs, the wrong context is the only context.

**Consequences.**

- Retrieval quality, not generation quality, is now the ceiling on chat.
- The obvious fix is entity-scoped retrieval: when a query names a known entity, prefer objects
  belonging to it. **Deliberately not implemented yet.** That is an unmeasured tuning change of
  exactly the kind this project refuses to make on intuition, and there is still no harness to
  say whether it helps or quietly hurts other queries.
- The UI must not imply that a green grounding badge means the answer is right. It currently
  reads "N of N sentences supported", which is accurate and narrow. It must stay that narrow.

**Also found:** `rebuild` drops `chunk_vector`, so the dense leg silently stops contributing
until `embed` is run again. Retrieval reports this in `unavailableSignals` and `doctor` shows
"embeddings none", but neither is loud enough. Before re-embedding, the same question returned
six lexical-only hits and ranked OpenCore's own README third behind two commits from an
unrelated repository.

---

## 2026-08-09 — The grounding check was grading its own coursework

The previous entry recorded that a well-cited answer about the wrong repository scored 3 of 3.
Reviewing why that score was reachable at all found a second, worse problem, in the check
rather than in retrieval.

**The instructions told the model to pass the test.** Rule 3 read: *"Prefer the words in the
sources over paraphrase. This answer is checked afterwards against the source text, and
invented phrasing fails that check."* `Grounding` scores lexical overlap. So the prompt was
coaching the model toward high overlap, and the resulting score measured compliance with an
instruction rather than fidelity to evidence. A metric a system optimises against stops being
a measurement. The instruction is gone.

**And the check pooled the sources.** Every passage was concatenated into one haystack, so a
sentence citing `[1]` was scored against the union of all six. A sentence faithful to source 2
and attributed to source 1 scored perfectly. Regression test:
`vocabularyFromAnotherSourceDoesNotCount`.

**Citations are now typed rather than parsed.** `GroundedAnswer` is `@Generable`, and
`CitedSentence.source` is an `Int` guided to `1...6`, so constrained decoding makes an
uncited sentence unrepresentable instead of merely unlikely. `[n]` markers are rendered from
that field afterwards; the model never formats them. This replaces asking for markers in prose
and hoping to parse them back out.

**Two signals now, reported separately**, because one is a guarantee and the other is a guess:
citation resolution (structural, hard) and source overlap (lexical, heuristic). Collapsing
them into a single "grounding" percentage is what let the original failure read as success.

**What has not changed:** failure mode 3 is still uncatchable here, and retrieval is still the
ceiling. Verified after the rewrite by asking the same question. Both sentences cite correctly
and both genuinely match the passage cited, and one of them is still the WoWCA rebrand commit.
The machinery is now honest about that instead of reporting it as full support.

## 2026-08-09 — Written against the SDK, not against recollection

`Sources/CoreReason/Conversation.swift` previously used three FoundationModels calls
(`SystemLanguageModel.default.availability`, `LanguageModelSession(instructions:)`,
`streamResponse(to:)`) out of a framework exposing over a hundred public types, and guarded on
`macOS 26` while the installed SDK was 27.

The source of truth used for this pass was the interface file on disk, not documentation and
not memory:

```
$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework/
  Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface
```

It is 2,903 lines and it is authoritative for the toolchain that will actually compile. Reading
it caught something no amount of care would have: **every case of
`LanguageModelSession.GenerationError` is deprecated as of macOS 27**, superseded by
`LanguageModelError`, `SystemLanguageModel.Error`, and `GeneratedContent.ParsingError`. Error
handling is written against the replacements.

Also adopted, each for a stated reason rather than for coverage:

- `GenerationOptions(samplingMode: .greedy)` — the same question over the same passages should
  give the same answer, and creative sampling is how a model smooths a source into something
  more readable than what it says.
- A retained `LanguageModelSession` and its `Transcript`, replacing a hand-rolled prompt
  containing `history.suffix(4)` truncated to 300 characters per turn. On
  `contextSizeExceeded` the session is rebuilt from the trailing transcript entries and the
  question is retried exactly once.
- `prewarm()` on chat appearing, so assets load while the reader is typing.
- Token counts from `Snapshot.usage` into the receipt's `generate` stage.

**Not adopted, deliberately.** `Tool` would let the model request more retrieval mid-answer,
which is a real answer to failure mode 3, and `PrivateCloudComputeLanguageModel` would raise
the ceiling on hard questions. Both are refused for now on the same grounds: they are
unmeasured changes to answer quality, and PCC additionally breaks `objectsTransmitted: 0`,
which is a claim the receipt currently makes truthfully.

**Receipts stopped lying by omission.** The chat path wrote `stages: []` while `PassageOutcome`
was carrying `stageTimings`, `blockedByDomain`, `lexicalCandidates`, `denseCandidates`,
`afterFusion` and `droppedByDiversity` the whole time, and wrote `model: "Apple on-device"` as
a hardcoded literal into the field whose entire purpose is recording what actually ran. Both
fixed. `Receipt.model` now carries `SystemLanguageModel.default` by name and stops there: the
framework exposes no version or build identifier, and inventing one would be the exact
"plausible default in a receipt field" the type exists to refuse.

---

## 2026-08-09 — The first measurement says the hybrid retrieval is worse than half of it

`opencore eval` ran for the first time. 20 hand-written cases over the GitHub corpus,
1,268 objects, 2,237 chunks, 100% vector coverage verified before the run. `[measured]`

| leg | recall@1 | recall@3 | recall@6 | MRR | nDCG@6 | fully missed |
|---|---|---|---|---|---|---|
| lexical | 22.5% | 36.7% | 48.3% | 0.523 | 0.420 | 6 / 20 |
| dense | 0.0% | 7.5% | 10.0% | 0.054 | 0.059 | 17 / 20 |
| fused | 2.5% | 7.5% | 10.0% | 0.083 | 0.073 | 17 / 20 |

**Fusion scores six times worse than one of its own legs**, and recall@1 falls from 22.5% to
2.5%. RRF cannot do that by being badly tuned. It was doing exactly what it is designed to do,
against an assumption this corpus violates.

**The mechanism, traced rather than inferred.** `opencore passages "What is OpenCone?"` shows
the correct README at fused rank 7, below six commits. A document in one leg at rank 1 scores
`1/(60+1)` = 0.0164. A document in both legs at ranks 6 and 3 scores `1/66 + 1/63` = 0.0311.
So anything both legs return outranks anything one leg ranked first. RRF rewards agreement
between retrievers because agreement is normally evidence of relevance.

Here the legs are not independent. 651 of 1,268 objects are commits, every commit chunk begins
`Gunnarguy/<repo>`, and both legs therefore return the same repository's commit stream for any
question naming a repository. Agreement measures redundancy, not relevance, and fusion
amplifies it.

**This is very likely the same root cause as the WoWCA failure** recorded on 2026-08-08. That
was diagnosed as "retrieval quality" and left there; it is more specific than that.

**The dense leg is separately weak**, at nDCG 0.059 with full vector coverage, so this is not a
missing index. `NLContextualEmbedding` is a contextual token embedding model, mean-pooled, and
was never trained for asymmetric query-to-document retrieval. It did win one case no other leg
found (a portfolio README with zero lexical overlap), so the signal is real and very weak.
Recorded as a question with a test plan rather than a conclusion, because the symmetric
self-retrieval check that would settle it has not been run.

**What this changes.** Cross-encoder reranking was next on the board and has been
deprioritised: reranking improves the ordering of a candidate set, and the measured problem is
that fusion ranks the right answer *out* of the set that lexical alone had at position 1.
Sweeping RRF k, MMR λ and `signalScale` is also premature. The shape is wrong before the
constants are.

**What it does not license.** No accuracy number goes anywhere. One personal corpus, 20 cases,
binary judgements, written by the same person who wrote the retriever. It is directional.

**Guarding against the harness grading its own coursework.** The same failure as the coached
grounding check, one layer up: if the expected passages had been chosen by looking at what
retrieval returns, every constant in the repository would have been blessed. So expectations
were written from corpus content before any query ran, half the cases deliberately avoid the
target's own vocabulary, and `q18` is the known-failing question included as a case that is
*supposed* to fail. A harness reporting 100% on day one has measured nothing.

**Fixed first, so the numbers meant something.** `rebuild` dropped `chunk_vector` and stopped,
leaving retrieval silently lexical-only with no error. That violated the schema invariant in
`.claude/rules/store.md`: dropping every derived table and rebuilding must reconstruct them.
Both rebuild paths now re-embed, and `opencore eval` prints vector coverage before any metric,
because a dense leg scoring zero for want of vectors reads identically to one scoring zero for
want of quality.

---

## 2026-08-09 — The dense leg was destroying 83% of retrieval, and the sweep proved it

Same day as the harness. The fusion defect was isolated by sweeping rather than reasoned about,
which is the whole point of having built the thing. `[measured]`

Fused nDCG@6, 20 cases:

| denseWeight | mmrLambda 0.7 | mmrLambda 0.85 |
|---|---|---|
| 1.0 (shipped) | 0.073 | 0.073 |
| 0.5 | 0.136 | 0.140 |
| 0.25 | 0.235 | 0.242 |
| **0.0** | 0.417 | **0.422** |

Monotonic. At equal weight the dense leg was costing 83% of the achievable score, and removing
it from fusion took the pipeline from **0.073 to 0.422**, finally beating its own lexical leg
(0.420) instead of scoring a sixth of it.

**`RetrievalTuning` gained `lexicalWeight` and `denseWeight`.** Textbook RRF has no per-leg
weights, and that is not an oversight in the method: RRF's appeal is needing no per-retriever
calibration, which holds when the legs are independently informative. Measured here, that
assumption is false and very expensive.

**Two corrections to what the previous entry claimed.**

1. The proposed first fix was wrong. `Gunnarguy/<repo>` is in `object.text` for **repositories
   as well as commits**, so stripping it would not have differentially helped the README. The
   real asymmetry is 651 short commit objects against 16 READMEs, plus BM25 length
   normalisation favouring short documents. The fix was written before checking the object
   text, and checking it took one query.
2. The residual gap after disabling dense was partly **the harness's own fault**. `rankings`
   asked `search` for `limit` chunks, which dedupe to fewer than `limit` objects, while each
   leg deduped 100 candidates into `limit` object slots. Fusion was being charged for a deficit
   the measurement created. Now requests `limit * 3`.

**`signalScale` is inert.** Swept 0.02 / 0.005 / 0.0 for identical nDCG at every value.
Switching the authority and recency terms fully off changes no ranking on any case, which means
`QueryClass.weights` — six rows encoding the idea that different question shapes need different
signal mixes — is currently decorative. The existing comment called it the most unprincipled
number here; it is worse than that, it is disconnected. Recorded as its own row, and explicitly
**not** fixed by raising the constant, because the benchmark is almost entirely `factual` cases
and could not fairly judge a temporal signal yet.

**The disable is loud.** `denseWeight: 0` adds a `semantic-disabled` entry to
`unavailableSignals`, carrying the numbers that justify it. A leg switched off by tuning has to
be as visible as one that failed. `rebuild` silently dropping every vector was the same class
of fault, and a deliberate decision does not get to be quieter than an accident.

**What did not improve.** Re-running *"what have I been building in OpenCore recently?"*: the
OpenCore README now reaches the context at rank 4, which it never did before, and three WoWCA
and spell-parser commits still outrank it, and the model still answered from one of them. The
aggregate moved 5.8x; that query is still wrong. Benchmark case `q18` is the regression test
and is still failing exactly as intended. Commit flooding is now the top open retrieval defect,
and it is a different problem from the one just fixed.

---

## 2026-08-09 — The MCP client met a third-party server, and the allowlist rule earned its keep

`opencore mcp-source discover` against Notion's official server, run from the copy already in
the npx cache so nothing was downloaded: connected over stdio, negotiated protocol
`2025-11-25`, enumerated **24 tools**. `[test]`

Two things this settles.

**The force-multiplier claim was true.** A whole new source type, Notion, cost **zero lines of
code**. `MCPServerConfig` already had `command`, `arguments`, `environmentNames`,
`allowedTools`, `toolArguments`, `domain` and `authority`, and resolves secrets from the
keychain. The integration is a row in the `source` table. That was the entire argument for
building the MCP client before writing connectors by hand, and it holds.

**Never derive an allowlist, concretely.** The rule has been stated since `5aa3448` and this is
the first time it has been tested against a real server. Notion annotates
`API-query-data-source` and `API-post-search` as **DESTRUCTIVE**. Both are reads. The
annotation tracks the HTTP method, since the Notion API queries over `POST`, and says nothing
about semantics.

So a client that trusted the server's own read-only hints would have excluded the two tools
this integration most needs, while `API-retrieve-a-page` and friends were flagged "read-only
(name unclear)" and would have been admitted on a name pattern. Both directions wrong. The
allowlist is four tools, hand-picked: `API-query-data-source`, `API-retrieve-a-data-source`,
`API-retrieve-a-page`, `API-retrieve-page-markdown`.

**Blocked on a credential, deliberately not worked around.** `NOTION_TOKEN` is an internal
integration token that only its owner can create, and the database has to be shared with the
integration before anything is readable. `--env` passes variable *names*, never values, so the
token reaches the child process from the environment or the keychain and never touches the
database, a log line, or this repository.

**One design decision recorded before it is implemented,** because it is the tempting mistake:
Notion's `Evidence` column (`measured` / `test` / `source` / `design` / `unverified`) must
**not** map onto `Authority`. `Authority` is an ordinal tier describing who said a thing, and
every roadmap row is a `directStatement` regardless of how well evidenced its content is.
Folding a confidence-like field into the authority tier is exactly the `confidence * authority`
error the type exists to prevent. `Evidence` belongs in object metadata.

---

## 2026-08-09 — "Can't I just click sign in?" Yes, and that is dynamic client registration

Asked why OpenCore needed a hand-made token when every other MCP client just has a sign-in
button. The answer is that they do something OpenCore could not, and the missing piece has a
name. `[test]`

**`registration_endpoint` is the whole trick.** With OAuth 2.1 **dynamic client registration**,
a client registers itself with the authorization server at runtime. There is no client id to
obtain in advance, no developer-portal step, no token to copy, and no "share the database with
your integration" afterwards. Verified live against Notion: OpenCore called
`https://mcp.notion.com/register` and received a working client id, having arranged nothing
beforehand.

The manual-token route did work first, and is worth recording as the contrast. `discover`
against `@notionhq/notion-mcp-server` connected, negotiated `2025-11-25` and listed 24 tools,
but it needed an internal integration created by hand and a database shared with it. Every
hosted server would have needed the same ceremony.

**What was built.** `MCPTransport`, so the protocol logic stops knowing what pipe it is on;
`HTTPTransport` for streamable HTTP, handling both the `application/json` and
`text/event-stream` reply shapes because the spec lets a server pick per request; and
`MCPOAuth` for discovery, registration, PKCE, exchange, refresh and keychain storage.

**Decisions inside it worth keeping:**

- `token_endpoint_auth_method: none`. This is a native public client and cannot keep a secret on
  someone's Mac. Claiming otherwise would be theatre; PKCE is what actually protects the
  exchange.
- `prefersEphemeralWebBrowserSession = true`. Reusing the browser's cookie jar is how a person
  silently connects the wrong account, which for a store of personal history is the worst
  available quiet failure.
- `state` is checked before the code is read. Without it an attacker can hand the app a code
  from a session the user never began.
- The `resource` parameter (RFC 8707) binds the token to one MCP server, so it cannot be
  replayed against another resource trusting the same issuer.
- Refusing `plain` PKCE outright rather than complying. A server offering only `plain` is
  downgrading the exchange.
- The registered client is stored in the keychain alongside the token, because a refresh
  request carries `client_id` and losing it turns an expiring token into a forced re-auth.

**Where the split falls.** `ASWebAuthenticationSession` needs a presentation anchor, so the
sheet can only come from the app. Everything else lives in `CoreIngest` where both surfaces
reach it: the app signs in, the token goes to the keychain, `opencore sync` reads it. That is
the same split the environment-variable credentials already use, so it is a pattern extension
rather than a new one.

**One invariant deliberately bent, and why it is not broken.** `mcp-source add` used to require
at least one `--tool`. A hosted server's tool list cannot be read until someone has signed in,
so a row now exists before its allowlist does. The safety property is untouched: `fetch` still
throws `noAllowedTools`, so an empty allowlist cannot sync. What moved is *when* the allowlist
is chosen, not whether it is required.

**Still unverified:** the consent screen. Everything up to it is proven against the live server,
and the click itself is a human action that cannot and should not be automated.

---

## 2026-08-10 — Counting questions bypass retrieval entirely

**Decision.** A question classified `.aggregate` is answered by a `GROUP BY` over every
admitted row in `CoreStore`, and the model is never called. The sentence is assembled in code.

**Context.** Asked "how many of my apps are built with Swift", chat answered **2** against a
true **12**. `[measured]` Nothing malfunctioned. The answer path retrieves
`AnswerLimits.maximumSourceNumber` (6) passages and hands them to the model; the model counted
the Swift ones among those six and reported the total. Receipt valid, citations real, grounding
check clean. A confidently wrong number behind a valid receipt is the worst failure this
project can produce, because nothing in the output looks wrong.

**Alternatives.**

- *Widen the passage window.* Not available: that constant also bounds the `source` field of
  the guided-generation schema (`.range(1...6)` in `GroundedAnswer.swift`), so raising it is a
  schema change, and the next question counts something bigger than whatever number is picked.
- *Let the model call a counting tool.* Puts the model between the question and the number,
  which is the thing that was wrong. It also breaks "the model never reads the store".
- *Tell the model it cannot count.* Honest but useless, and the store holds the answer.

**Rationale.** A ranked window is the wrong instrument for a question whose answer is a
property of the whole population. No amount of better ranking fixes it, because the defect is
not that the wrong six passages were retrieved.

**Consequences.**

- `MetadataBreakdown` reports `unclassified` separately and never folds "no value recorded"
  into "does not match". Unmeasured stays unmeasured, in the one place a plausible number would
  be indistinguishable from a measured one.
- **Counts are firewalled exactly as passages are.** `domains` is a required parameter on every
  counting method rather than defaulting to all of them. A count is a disclosure: answering
  "14" to a question about medical appointments discloses what the firewall exists to withhold,
  while retrieving zero passages and so tripping none of the checks that guard the passage
  path.
- A qualifier the resolver cannot place **declines** and falls through to retrieval rather than
  reporting the bare population total. Answering "how many apps did I write on a train" with
  "22" would substitute a different question for the one asked, which is the original defect in
  a new costume.
- The counted receipt is a different shape: `objectsRetrieved` 0, `evidenceAdmitted` 0, `model`
  `nil`. Borrowing the retrieval shape would be a lie in precisely the place this change exists
  to fix.

**Known limits.** Facets resolve against metadata the connectors happen to record, so
"how many apps use SwiftUI" is unanswerable until something records a dependency list.
Pluralisation is a trailing `s`. Both decline rather than guess.

---

## 2026-08-10 — The dense leg is skipped, not computed and discarded

**Decision.** `PassageSearch.search` guards the query embedding *and* the vector scan on
`tuning.denseWeight > 0`. `PassageSearch.rankings` deliberately does not.

**Context.** `denseWeight` has been 0 since 2026-08-09, and `absorb` discards the leg on its
first line at that weight. `search` computed it anyway: 320ms of a 350ms warm query, so
**91% of retrieval time produced nothing**. `[measured]` Cold, the query embedding alone was
594ms.

**Rationale.** The split between the two entry points is the whole decision. `rankings` is what
`opencore eval` measures the dense leg through, and that measurement is the reason the weight
is 0. Guarding both would have deleted the evidence for the decision that motivated the fix,
and the next reader of the eval table would have concluded the embeddings had broken.

**Consequences.** `PassageOutcome.denseCandidates` is 0 and `unavailableSignals` carries
`semantic-disabled` saying the leg was not run. Verified: warm query 350ms to **70ms**, and
`opencore eval` is byte-identical across the change (fused nDCG@6 0.365, dense still measured
at 0.025), which is the check that the skipped leg was contributing nothing.

---

## 2026-08-10 — Conversations are primary data, not a derived layer

**Decision.** Migration 4 adds `conversation` and `conversation_turn`, and both are deliberately
**absent** from `Store.derivedTables`. `opencore rebuild` must not touch them.

**Context.** Chat was entirely ephemeral. Turns lived in a SwiftUI `@State` array, the model's
own `Transcript` carried the continuity, and closing the tab destroyed both.

**Rationale.** Every other table below `object` is reconstructible, which is why `rebuild` may
delete it. A conversation is the inverse: the user's questions are authored input and no object
graph can reproduce them, and the answers came from a model whose output is not reproducible, so
re-running the question later gives a different answer to the same words. Listing these tables
as derived would make `rebuild` silently delete a user's entire chat history, which is the
project's first non-negotiable violated in the most damaging possible direction.

**Consequences.**

- Sources and verdicts are stored as JSON on the turn rather than as foreign keys to `object`.
  Denormalisation on purpose: they are what the answer was *shown against*, and re-ingesting an
  object later must not retroactively rewrite the history of an answer given before the edit. A
  receipt that changes after the fact is not a receipt.
- `receipt_id` is a real foreign key with `ON DELETE SET NULL`, so deleting a conversation
  forgets the conversation without destroying an audit trail that `receipt_evidence` and
  `opencore trace` still reach.
- **Deleting a conversation is a genuine delete**, and that does not contradict "never delete to
  record a change of mind". That rule is about retracting a *claim*, which stays as a row
  because something downstream may have relied on it. Nothing derives from a chat turn.
- This also fixed a defect found the same day: chat receipts were built, printed by short code,
  and dropped, so `opencore trace` could not resolve a single chat answer. Saving the turn saves
  the receipt with it.

---

## 2026-08-10 — Resuming a thread restores the model's context, not just the text

**Decision.** `Conversation.restore()` replays stored exchanges into a real
`FoundationModels.Transcript` and installs it in a fresh session, instructions entry first.

**Alternatives.** Show the history and start the model fresh, which is what most chat UIs that
"save conversations" actually do.

**Rationale.** A thread that displays its history while the model has none looks resumed and
answers with amnesia: "what about the second one" gets a request for clarification directly
underneath a visible list of three. That is a worse experience than no history at all, because
the failure is invisible until it happens.

**Consequences.** The instructions entry is rebuilt identically to a live session's, or the
restored model keeps the conversation and loses the rules that make its answers citable, which
is the worse of the two things to drop. Old turns' *passages* are deliberately not replayed:
they were retrieved against a store that may have changed, so retrieval runs fresh for every new
question exactly as it does within one sitting.

**Known limit, measured.** Retrieval still runs on the raw follow-up text, so "what language did
you just say it uses" retrieves nothing useful and the answer is "the sources retrieved do not
answer that". The model has the context and is refusing to answer from memory, which is the
thesis working. Query rewriting for follow-ups is the missing piece and is tracked separately.
