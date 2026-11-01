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

---

## 2026-08-12 — A `Dropped` row is a claim about the product, and it can be wrong

**Decision.** "A chatbot UI" moves from `Dropped` to `Completed`. "Autonomous agents that act on
the user's data" moves from `Dropped` to `To Do`, v0.6. `Docs/ai/PROJECT.md`'s out-of-scope list
is cut from four entries to two.

**What actually happened.** The board said a chatbot UI was dropped "so it stops being
reconsidered". It was not reconsidered. It was silently contradicted: Chat is the app's first
sidebar item, in a band called Ask, with saved resumable threads and per-answer judgements, and
on 2026-08-11 the separate Ask tab was retired *into* it. Several sessions of work touched that
exact screen without anyone opening the dropped rows.

**Alternatives.** Roll the code back to match the decision. Or leave both and record the
conflict without resolving it.

**Rationale.** The row's stated objection was *being undifferentiated*: "every competitor in this
space is a chat window; being one is how the project stops being differentiated." What shipped
is not that. Citations are typed rather than parsed out of prose, so an uncited sentence is
unrepresentable. Each sentence is checked against the source it actually cited rather than a
pool of all six. Every answer carries a receipt with measured counters. And it refuses to answer
from the model's own memory: with a thread resumed and the transcript restored, "what language
did you just say it uses" returns "the sources retrieved do not answer that" while the model
plainly has the context.

So the decision was made against a thing that did not get built. The receipt is still the
interesting surface; it now lives inside the conversation instead of instead of it.

**Consequences.** Agency is reopened as a real direction rather than arriving by accident, with
its prerequisites on the row: the eval harness reporting a number, and a decision about
`Receipt.objectsTransmitted`, which is `0` today and cannot stay `0` once anything is sent. The
shape that keeps it on-thesis is the one already accepted for model-proposed claims: a model may
**propose** an action, code **executes** it, and the proposal enters at the bottom authority
tier. The MCP client's default-deny allowlist is the consent model to reuse rather than reinvent.
An action requested through the MCP *server* must never execute, because an MCP caller is not
the user.

**The process failure is worth more than either decision.** Both `Dropped` rows and this
document were describing a product that no longer existed, and nothing surfaced it. It was found
because the author asked whether OpenCore was becoming a personal assistant, and answering
honestly required reading the dropped rows rather than the open ones. The repository's own rule
already covers this and was not being applied to the roadmap: when a document and the code
disagree, the code is right and the document is a bug to fix.


---

## 2026-10-23: Preserve unproven history while tightening imported-memory policy

**Context [source].** Imported generated memories could inherit project access and authored
artifact authority. Historical aliases and rows whose original presentation metadata had been
lost could expose private context even after only the current object was reclassified.

**Decision [design].** Normalize policy at the shared ingest boundary, exclude a conservative
restricted compartment from ordinary MCP admission, and quarantine affected interpretations.
Retain unprovable legacy rows as restricted immutable audit-floor objects. Require a new,
consistent private backup before applying the repair. Refuse destructive rebuilds when unique
corrections or direct assertions lack replayable floor evidence.

**Alternatives [design].** Reclassify only the current rows, guess their former privacy from
present-day metadata, delete affected history, or immediately rebuild the whole live corpus.

**Rationale [design].** Current visibility is not evidence of historical provenance. Restricting
unproven interpretations is reversible; exposing them or deleting their only surviving copy is
not. A byte-matching quote establishes provenance, not the truth of a model's interpretation.

**Consequences [measured, test].** The copied-store experiment and live repair preserved original
content and receipt links. The live store retained 7,469 original objects and gained 603 restricted
audit-floor objects. 556 objects need reviewed derivation replay. This is a tracked recovery task,
not permission to relax domain admission or blindly rebuild. Test fixtures cover corrections;
the live store had zero correction rows.


---

## 2026-10-23: Connect workspaces through purposes, subjects and evidence

**Context [source].** Screens exposed data structures with separate vocabulary and controls.
A global Claims page is capped at 400 current rows, so filtering that page cannot safely stand
in for an exact-subject query. A visible technical capability is not by itself an actionable flow.

**Decision [design].** Keep every workspace and its technical name. Add shared purpose metadata,
related-workspace navigation and an outcome map. Distinguish original records, excerpts,
extracted statements, recorded decisions and answer receipts. Show subject scope above the
scrolling content. Subject links use an exact EntityID for statements/decisions and explicitly
use text search for excerpts. Generic navigation clears target scope; related-subject links
preserve it. Navigation history records the scope. Keep global and subject claim caches separate.

**Alternatives [design].** Hide advanced views, replace them with a simplified mode, or add
standalone explanatory paragraphs without connecting the actual data and destinations.

**Rationale [design].** Repeated vocabulary and real context-preserving links let a person learn
one relationship and reuse it. Counts describe their loaded/current scope. An original can
produce searchable text without a claim, and a selected belief is a recorded decision rather
than a truth guarantee. The workflow map shows those distinct routes.

**Runtime finding [measured].** Opening the automatic SwiftUI inspector twice left the app
unresponsive. The sampled process used about one CPU core and its main thread was in an AppKit
layout cycle. A documented inspector width modifier alone did not settle it. An explicit bounded
HSplitView then opened claim evidence and original records responsively in native interaction.
Use the same inspector controls and data; do not reinstate automatic presentation on a build-only
claim. Apple HSplitView reference consulted 2026-10-23:
https://developer.apple.com/documentation/swiftui/hsplitview

**Runtime finding [measured, source].** Quick Jump's field updated while its results retained
old row closures. Snapshot results outside ScrollViewReader and reset the scroll host when
result IDs change. Keep keyboard selection by item ID through asynchronous insertions and
restore scroll on appearance. Chain Quick Jump to the map through sheet onDismiss.

**Consequences [test, measured].** Engine tests remain 173 passing. Native checks exercised a
real project's 27 statements, six decision records, supporting evidence and an original record;
subject preservation, global totals, Back/Forward, pane close and Quick Jump-to-map were checked.
These checks establish the tested paths, not a usability study or every external capability.


## 2026-10-23: Model roles come from local checks, with explicit adapter scope

**Context [measured].** The model catalog contained reference-only cards. The user asked to
load and run the full catalog and identify practical strengths. This explicitly authorized
model downloads and superseded the earlier Hub no-download preference.

**Decision [source, design].** Local Hub owns exact-revision downloads and isolated workers;
OpenCore consumes its live state and qualification receipts. Seven screenshot adapters expose
location predictions only. Apple/Qwen/Raptor retain their scoped tool tasks; Fara uses the
browser screenshot loop. Do not silently admit a locator to a planner task or grant Mac access.

**Alternatives [design].** Rank models from publisher scores or parameter counts, keep disabled
reference cards, or imply a complete desktop agent from a successful coordinate prediction.

**Rationale [measured].** All twelve packages plus Apple ran. The smaller Holo 3B outpaced larger
all-passing target finders on these six fixtures. Some small models missed targets; Raptor and
Apple altered exact multiline text; Qwen 4B emitted incomplete control-call frames. These
failures remain evidence. A real Qwen file task and Fara saved-form diagnostic independently
verified effects. No broad accuracy or real-account reliability was measured.

**Consequences [source, test].** Recommendations require completed all-passing suites with
matching model revision, fixture and serving preset. Missing memory remains nil. Local MLX
peak is separated from total Mac RAM. Stop cancels preflight and inference without a late
worker or verification effect; stale worker errors cannot replace intentional cancellation.
Original receipts, task history, private data, policies and permission grants are preserved.

## 2026-10-23: Mac warnings lead to specific review panels

**Context [source, measured].** Storage and numbered-file warning rows were styled as links
but had empty actions. The external hardware workspace did not explain internal disk usage.

**Decision [source, design].** Open a native Mac checks sheet on the matching topic. Show
live Data-volume measurements, bounded sizes of seven known model/build folders, Finder
destinations, and links to the existing model and hardware workspaces. Dismiss the sheet before
changing workspaces. Do not add cleanup or file replacement to a warning click.

**Alternatives [design].** Route every warning to generic Settings or Finder, delete likely
duplicates automatically, or estimate missing measurements. These do not provide enough
context for an informed action and can misrepresent the state of the Mac.

**Rationale [source, test].** A numbered filename alone does not establish an iCloud conflict.
List candidates with their matching base filenames and reject paths outside the scan root,
including parent symlinks with missing leaves. Failed simulator decoding and incomplete file
scans must differ from successful empty results. Disk warnings use the configured threshold.

**Consequences [test, measured].** Native warning-to-sheet, four file reveals, model-folder
reveal, refresh and cross-workspace links passed. Five regression tests cover measurement,
threshold, path and simulator parsing guarantees. Model weights and user files are unchanged.

## 2026-10-23: Rank every model for comparable jobs on the measured Mac

**Context [source, measured].** Four winner cards hid the other catalog placements. Existing
receipts stored arm64 and the OS version, insufficient to independently identify chip/RAM.
Twelve model packages occupied about 44.25 GB allocated, and free space was low.

**Decision [source, design].** Show all catalog models per job, with their strongest eligible
local placement, passed cases, median time, allocator peak and download size. Rank complete
comparable suites by passed fraction then time. Bind eligibility to hardware configuration,
OS/build, revision, serving preset, fixture and worker/library signature. Retain older results
as previous-setup evidence. Use the same eligibility gate for standings and recommendations.

**Alternatives [design].** Combine dissimilar tasks into one score, infer machine provenance
from arm64, rank by parameter count, or keep showing only winners. These conceal relevant
failures or imply measurements the receipts do not establish.

**Rationale [source, test].** Every choice needs a practical comparison while unlike roles
remain explicit. MLX allocator peaks are shown separately because they are not total RAM.
Failures before the first trial retain their status/error. Incomplete grounding subsets cannot
produce a winner that is absent from the rankings.

**Consequences [source, test].** A largest-first native storage view exposes delete-download
controls with the model name and size. Removal uses the existing owned-file API, rejects Apple
assets and keeps qualification/task history. Native dialogs are cancelable. No live model
removal or additional download is implied by inspecting or ranking the catalog.

## 2026-10-23: Keep hardware values beside their labels

**Context [source, measured].** A flexible Spacer in each shared hardware detail row pushed
measurements to the far edge of a wide inspector, making label/value matching difficult.

**Decision [design, source].** Use one shared leading value column beside a text-scaled label
column, with wrapping selectable values and a stacked narrow fallback. Keep existing help
controls and all measurements. The column dimensions are chosen reading dimensions.

**Alternatives [design].** Keep full-width justification or independently size every section.
Both preserve inconsistent scanning distances across the hardware workspace.

**Rationale and consequences [source, measured].** Nearby aligned values make each row read
as one pair while retaining all detail. Device/power rows and help expansion were verified
in the installed app. Narrow fallback is source-reviewed, not runtime-qualified.

## 2026-10-23: Represent monitors through the display system

**Context [source, measured].** USB and Thunderbolt enumeration omitted actual monitor outputs;
AVFoundation only listed cameras. macOS saw the primary external monitor, Apple built-in and a second external monitor.
The primary monitor's desktop/render modes differed from its path's registry native-format/range claims.

**Decision [source, design].** Add Displays using Quartz/AppKit online inventory, current modes
and offered modes. Match optional registry descriptors only when both online identity and
descriptor identity are unique. Retain fractional current refresh rates; reject invalid/nonintegral
integer descriptor fields. Refresh on screen-parameter changes and manual Refresh.

**Alternatives [design].** Pretend monitors are USB devices/MCP connections, infer a dock from
manufacturer, or use generic panel specifications as measured limits. Each misstates the source.

**Consequences [source, measured].** Current desktop points, render pixels and descriptor claims
are labeled separately. No physical HDMI/DP/dock route or panel maximum is asserted. Public
inventory solved the missing devices; no firmware artifact was selected or reverse engineered.
Three live production records and native count/menu were verified; CUA blocked remaining clicks.

## 2026-10-23: Use genuine display services and version-qualified BetterDisplay controls

**Context [source, measured].** Read-only inventory omitted monitor modifications. Installed
BetterDisplay 5.1.1 exposes documented local notifications, installed help, identity and DDC/mode
reports. The primary monitor answers 23 VCP queries; the second monitor's DDC capability query fails on its present path.
Configured input labels and provider link data cannot establish every physical socket.

**Decision [design, source].** Retain exact Quartz mode identities, including duplicate low-
resolution variants, and provide an app-only timed preview with session-only Keep. Bridge
existing BetterDisplay through its native documented notification protocol, qualifying commands
against installed help and uniquely matching native display ID/vendor/product/serial to UUID.
Use actual DDC ranges/enum codes and currently compatible signal modes. Expose the full installed
feature catalog, but reserve context-heavy commands for BetterDisplay's configured interface.
Keep raw reports, failed queries and conflicting source claims inspectable and attributed.

**Alternatives [design].** Guess capabilities from model names, treat configured input labels
as sockets, inject private undocumented display calls, install an extra helper, or present all
help entries as supported controls. Those lose identity, version, availability or evidence scope.

**Rationale [source, test].** Reversible exact mode previews need original all-screen modes/layout,
a full confirmation interval after successful apply and protection against later external edits.
Provider commands require an operation lease across asynchronous preflight/send/readback. A
local timeout cannot cancel an already-posted hardware change, so unknown outcomes remain
locked until their matching reply. Observable gate state and stale-report presentation keep UI
availability honest. Explicit get-only help stays read-only even if it mentions a numeric range.

**Consequences [source, measured].** OpenCore gains real mode, DDC, signal and simple provider
controls without changing BetterDisplay's settings/licensing. Advanced controller/mirror/stream
configuration remains inspect-only with a real app route. No firmware/Pro bypass is attempted.
34 focused tests, final app build, signature and read-only three-display probe passed. Physical
adjustments/rollback and remaining native click-through are explicitly unverified.

## 2026-10-23: Make picture adjustment live and keep hardware browsing visible

**Context [measured, source].** The primary monitor's settings appeared inert despite a working DDC path:
production brightness100→95→100 read back correctly. Sliders staged local values, Apply/confirmation
was separate, every write locked controls until manual reload and results appeared below the fold.
The nested hardware navigation sidebar could disappear with the main sidebar. User requested live
controls, explanations and a coherent visual layout.

**Decision [design, source].** Use bounded latest-value picture updates with per-control readback,
visible auto-refresh and in-place reports. Preserve explicit input/power confirmations. Explain
standard meanings, vendor ambiguity and actual availability. Group common controls before reports
in Picture/Resolution & Signal/Inputs & Power/Advanced. Use a separate resizable hardware browser;
keep optional app navigation independent and offer real count-button routes.

**Alternatives [design].** Keep staged Apply everywhere, post every drag event, treat acceptance as
physical success, or hide device selection with navigation chrome. Each loses responsiveness,
monitor stability, evidence fidelity or discoverability.

**Consequences [test, measured].**44 focused tests passed. The current production live queue reached
97 from100 with readback in0.613s in one probe, required no manual refresh and restored100. Pending
edits invalidate before posting when their session stops; posted writes finish bounded readback.
Source reviews corrected reentrancy, stale queued feedback, numeric validation and poll-erased
mutation outcomes. Current final visual QA remains limited by unavailable native computer control.

## 2026-10-23: Qualify live control delivery and reject invalid power states

**Evidence [test, measured].** The final 45 focused tests, installed build/launch and strict
signature passed. Native Dark-mode picture cards, Inputs & Power rendering and sidebar hide/show
were checked after CUA recovered. The installed brightness slider changed 100→99→100 with exact
independent readback and visible green feedback. This supersedes the earlier native-QA blocker
for those checks only. Physical mode/input/power/rollback, narrow resize, Light and VoiceOver remain
unqualified; AX text sometimes lagged the screenshot.

**Decision [source, measured].** Treat D6 readings outside 1...4 as unavailable. Observed primary-monitor
reads returned 24/5 while visibly on; 5 is an off command, not a readable state. D6 readable state
4 remains valid even if an enum is absent and the reported maximum is 1. Regression assertions
cover both paths. Do not attribute the inconsistent reply to firmware or provider without evidence.
Follow-up 40349a74-d54f-81fe-8929-f48959e6a921 retains that work.

## 2026-10-24: Separate hardware-read success from empty discovery

**Context [measured, source].** User USB-C/DisplayPort screenshots showed working120Hz video,
failed capabilities and green polling status. An empty feature loop performed no VCP reads but
advanced lastLiveUpdate and cleared its error. Current native/provider inventory sees only the
built-in screen, so the primary monitor connection failure cannot yet be diagnosed.

**Decision [source, test].** Require actual usable control values before advancing successful-read
time. Distinguish missing discovery from an empty category and normal built-in Apple controls.
Offer real retry/provider/help routes and a chosen30-second empty-discovery backoff. Preserve
existing write gates and capability/range validation. Do not invent support or blame the cable.

**Consequences [test, measured].**46 focused tests and installed build passed. Built-in native
screen renders appropriately. Direct VCP/capability qualification awaits reconnection;
follow-up40349a74-d54f-81fe-8929-f48959e6a921 remains open. No physical settings changed.

## 2026-10-24: Display readable video evidence beside failed DDC

**Context [measured].** The reconnected primary monitor reports a new DP UUID/product,1440p120Hz and full
DisplayPort link information. Direct capability/luminance/input/power requests fail outside OpenCore.
Generic brightness/contrast provider values still return and may be stored, so they cannot qualify
physical monitor state. The user interpreted empty control sections as inability to read any data.

**Decision [source].** Show reported video connection, bit depth/color/SDR and expandable paired
link details even when DDC discovery is empty. Identify link capacity as capacity, retain report
capture time and avoid inferred socket inventories. No guessed controls or physical success.

**Consequences [measured].** Native primary-monitor summary renders the real DP report. Provider detection
remains needed; its menu-bar settings window is not exposed by the desktop tool. Keep the async
request pending, preserve failed direct queries and make no hardware write during diagnosis.

## 2026-10-24: Preserve configured provider brightness without capabilities

**Context [measured, source].** User supplies the primary monitor's exact model and revision and confirms keyboard brightness
routing via BetterDisplay. Its DDC communication works although reports/GETs fail. Native settings
show configured0x10/range0–100,Prefer hardware on andCombined active. Report absence cannot
justify blocking all writes.

**Decision [source].** Offer automatic provider brightness independently of DDC discovery, with
explicit percentage request/confirmation and existing identity/mutation/mode guards. Provider
state is not physical readback. Mutation feedback is keyed separately from read selection. No new
keyboard hook, guessed current value, port auto-switch command or hardware-write verification.

**Verification [test, measured].**46 tests, installed build/launch/signature/source comparisons
passed. Native primary-monitor card/provider read verified; no physical write. That revision's internal parts and
cold fault remain unqualified. Current chat outputs/OpenCore-provider-brightness-verification.json.

## 2026-10-24: Make monitor choices visible without inventing support

**Context [design].** The user finds menu pickers opaque and wants controls laid out with
explanations and full fidelity only where supported. A global provider catalog and unavailable
DDC discovery must not become claims about the selected monitor.

**Decision [source].** Use visible adaptive option cards for DDC enumerations and provider values,
a searchable provider library, and grouped exact macOS mode rows with explicit scaling/Hz filters.
Keep purpose/effect/use/limits visible. Retain expandable raw reports for detailed evidence.
Preserve original mode IDs, unusable choices for inspection, confirmed input/power/provider actions,
post-apply Keep/Revert, identity and mutation guards. Do not synthesize unsupported controls from
model names or global feature definitions. Provider brightness stages a request from provider state
only; no implicit physical write or hardware success claim.

**Alternatives / consequences [design].** Keeping menu pickers hides comparisons; showing every
raw report in full would crowd out actionable controls. Bounded lazy catalogs and resettable
filters retain all reported choices with manageable scrolling. More visible guidance increases card
height. Layout QA must inspect real catalogs without applying monitor settings merely to test UI.

**Verification [test, measured].** Installed build/signature,46 focused tests and6 source-stage
comparisons pass. The monitor's Picture AX confirms provider1.0/request100%. CUA native pipe fails
on mode/Advanced inspection; full catalog/search/filter/narrow-window visual QA remains unverified.
No hardware settings changed. Evidence: outputs/OpenCore-monitor-visible-controls-verification.json.

## 2026-10-24: Filter Advanced by explicit capability evidence

**Context [source, design].** Display-specific entries in the provider help describe the global
API catalog, not this screen. Showing all141 entries equally made unsupported Apple/HDR controls
and setup operations look actionable on the primary monitor.

**Decision [source].** Default to controls matched by this connection’s capability Yes fields or
advertised DDC codes. Separate unknown evidence, explicit No/failed reads, and configuration/tools.
Unknown stays unknown; potential DDC compatibility and successful generic hardware GETs do not
replace advertised VCP evidence. Automatic brightness accepts software or hardware routes, mute
accepts volume or dedicated mute evidence, and built-in-XDR-only upscaling stays unverified when
the stricter prerequisite is unknown. No-value actions cannot be disqualified by GET failure.
Read evidence is invalidated by new loads/connections; only actual GET failures affect the list.

**Alternatives / consequences [design].** Filtering by model-name guesses or a generic successful
GET would invent support. Probing every catalog feature is noisy and some actions have no readable
value. Retain deliberate access to unknown/tools and explanations, without offering unavailable
changes. The configured Picture brightness fallback remains usable independently of DDC discovery.

**Verification [test, measured].**55 tests/6suites, installed build/launch/signature and4 staged
source comparisons pass. Final native Hardware/monitor navigation verified. Advanced selection
still closes native CUA pipe, so filter counts/search/layout remain unverified. No physical writes.
Evidence: current chat outputs/OpenCore-monitor-feature-filter-verification.json.

## 2026-10-30: Remove the rules that mirrored the benchmark

**Context [measured].** `HybridSearch.ftsQuery` carried hand-written bridges from a question's
words to the words of the README that answered it. Each lined up with one row of
`Benchmarks/rag_eval_v1.jsonl`, and q02's note said that case "cannot be won on keywords" while a
keyword rule won it. One rule put an employer's name in a public repository.

**Decision [source].** Remove them all, and do not give them a local home. A rule belongs in that
function only if it is about English, never about a document.

**Consequences [measured, 2026-10-30, the real store's copy, 9,537 objects, 20 cases].** Five cases
went from found to missed: q02, q05, q06, q07 and q17. Those five were being won by the rules.
The score before this change was not a measure of retrieval, and the honest number is the one
now printed by `opencore eval`. Every case is still a project README lookup, so this is a smaller
number from a benchmark that still does not test status, time, personal data or follow-ups.

## 2026-10-30: A document rewriting itself is not a contradiction

**Context [measured].** Of 14 contradictions on the real store, 6 were handoff documents being
rewritten, 6 were status and 2 were language. `adjudicate` asked about authority before time, so
70 objects from an old `/private/tmp` copy, at a higher tier than the real files, froze OpenCore's
own objective on a replaced sentence and retracted two newer values.

**Decision [source, test].** Within one slot, claims read from files of the same name are revisions
of one document. The newest wins by time, regardless of authority, with no contradiction row. A
tie retires nothing. `objective` and `last_verified_commit` stay functional, because removing them
loses the single current value; the defect was calling succession a contradiction.

**Alternatives.** Keying on the object id misses the same file reached through two sources or a
copied path. Excluding `/private/tmp` objects fixes one instance and leaves the rule wrong.

## 2026-10-30: Status comes from work, and dormancy is dated when it began

**Context [measured].** With no new push, `active` and `dormant` shared a `validFrom`, tied, and
stayed `active` forever: zero active-to-dormant beliefs existed. `pushed_at` also cannot tell a
README edit from work, and the store's four "revivals" were at least three README edits.

**Decision [source, test].** Status reads the newest commit that is not upkeep (`CommitNature`), and
`dormant` is dated `lastWork + 180 days`. `primary_language` is dated by the push it was read after,
because a language can only change through a push, and the old date was repository creation, so a
language change always tied.

**Known limit [source].** The floor keeps a commit's first line and author, not its changed files,
so upkeep is judged by title. The status claim stays `.inferred`.

## 2026-10-30: A rebuild is rehearsed on a copy and applied by a person

**Context [measured].** "Run Deterministic Rebuild Check" deleted every derived table in the live
store. Traced on the real store it would have cut 964 and 523 receipt links, lifted quarantine,
reset knowledge time and left a half-empty graph for any running `opencore mcp`. Its verdict
compared row counts, so a claim changing domain read as a perfect result. One correction
disabled it permanently.

**Decision [source, test].** `RebuildRehearsal` copies the store, re-derives the copy, carries across
what derivation cannot produce, and reports the difference by id. Applying is a separate call that
replaces rows inside one transaction and refuses if the store moved. Domain raises, lost
corrections and dropped claim rows are blockers with no override.

- **Rows are replaced, the file is not.** Open MCP processes would keep reading an unlinked inode
  with its own write-ahead log. A transaction means they see the old graph or the new one.
- **A claim no longer derived is retained as retracted**, because "never delete to record a change
  of mind" holds for rebuilds, and a receipt that cited it keeps something to point at.
- **Quarantine stays held by default.** Lifting it is a separate reviewed decision, not built here.
- **No migration.** Everything fits the existing schema, so older `opencore mcp` binaries are safe.

**Verification [measured, 2026-10-30, a copy of the real store].** Rehearsal 21 s. 0 domains raised,
0 claim rows dropped, all 1,487 receipt links kept, all 30 receipts trace identically before and
after applying, open contradictions 2 to 0, integrity and foreign key checks clean. A second
rehearsal on the applied copy changed nothing, so the result is a fixed point.

## 2026-10-30: Private names leave the repository, and missing them fails closed

**Context [measured].** The repository is public. Compiled lists and fixtures carried private
repository names, a monitor serial, hostnames, home paths and, through the benchmark rules, an
employer.

**Decision [source, test].** Values the program needs live in `private-names.json` beside the store,
read through `LocalPrivateNames`. Compiled tables hold only names `origin/main` already carried. An
unknown repository is `.restricted`, an unlisted one is hidden, and no machine is probed.
`script/check_sensitive.sh` reads its terms from the gitignored `Local/sensitive-terms.txt`.

**Open [measured].** All 14 unpushed commits still contain at least one term, and public commit
5d530c7 holds the old benchmark sentence. Forward fixes do not remove them. Rewriting is the
owner's decision.

## 2026-10-30: Fresh store means in-app, on the system's schedule

**Context [measured].** Nothing was syncing, the newest non-MCP sync was six days old, and Calendar
and Reminders had not run since 2026-08-14. A launchd job cannot help: the CLI has no Info.plist, so
EventKit refuses it.

**Decision [source, test].** The app ticks through `NSBackgroundActivityScheduler` (Foundation docs
read 2026-10-30) and `SyncSchedule` decides what is due. A failed job waits its interval. `since`
now filters calendar events by modification rather than selecting them by when they happen, because
the old reading meant an event before the last sync was never looked at again. An empty first
sync no longer sets `since`, and a source with a date and no objects reads from the beginning.

**Limit.** It runs only while the app runs. Reading Notes starts Notes, so that has its own toggle.

## 2026-10-30: A missing private list withholds, and derivation reads only the path

Corrects "Private names leave the repository, and missing them fails closed" above, which claimed
more than the tree did.

**Context [source].** Three things in that entry were false. Compiled code and the app still held
private repository names and a private path. The scan passed because its terms
file omitted most of the private list and every hardware and machine name. And "losing this file
costs convenience" was wrong: `Store.retainedImportDomain` never lowers `.restricted`, so one sync
with the file missing, malformed or partial would have pinned every repository the binary can't
name, with its claims and events, and `dropDerivedLayers` would then refuse to run. A partial file
made it worse, because `Repositories` had synthesized decoding, so one absent key emptied the file
with no message. Scheduled sync would have done this by itself. A review of `AgentMemoryPolicy`
also found `hasSuffix("-" + name)` had no boundary, so a slug could read an unknown repository, or a
subfolder of a medical one, as `.project`.

**Decision [source, test].** `.restricted` is an answer, and "the list is unavailable" is not one.
With the lists unavailable, `AgentMemoryPolicy.classification` returns `nil` for a repository the
binary can't name, so it is not read and nothing stored changes. A complete list that omits a name
still gives `.restricted`. `LocalPrivateNames.Repositories.isComplete` is the difference, and it is
true only when the file stated all three lists. One bad entry or section now loses only itself.

A slug is trusted only when the name is everything after a repository container, and a nested
repository is listed in the file. `claudeMemoryProjectName` and the anchor walk read the path and
nothing else, so `rebuild` reaches the same subjects under any account. They read neither
`NSUserName()` nor the private file, even though the file could give nicer names, because the type
promises reproducibility and the file is not part of the floor.

The private automation tool is now just "Automation" in the app, and its path, the hub's path and
the hub's identity moved to `localAutomation` in the file. Its two `UserDefaults` keys were renamed,
so both settings return to their defaults once, and those defaults are dry run on. An unset hub
identity means the hub is not trusted, since a port answering is no proof of who is listening.

The scan now takes every name in the private file as a term, skips what `origin/main` holds, checks
file names, reads messages and authors in `--history`, and exits 2 rather than clean when git fails.

**Consequences [source].** Re-deriving changes the subjects of memory objects whose names came from
those literals, such as the nested repository's 10 objects, which take their folder's flattened
name. `opencore rebuild` shows this as a difference. A repository listed after it was restricted
stays restricted until an explicit retag exists. Forward fixes leave the old text in unpushed
commits, which is still the owner's decision.

## 2026-10-31: Chat reads a claim as one source, with what stands against it

**Context [source, measured].** Chat quoted up to three claims into one source, labelled and cited
from the first. It passed the statement and nothing else, so a status with refuting evidence reached
the model as a flat fact, and its receipt counted every matching line while linking no rows, so
`trace` said "admitted no evidence". `Reasoner` counted rows, so `claimsConsulted` meant two things.

**Decision [source, test].** One source per claim. Title, object, authority and the `Grounding`
check then all belong to one line, which a shared source could not do at any cost. The price is up
to three of the six source slots, which leaves three for passages.

The caveats are lines in that source: inferred, counter-evidence, and any contradiction that stands
against the claim. That last one is deliberately narrower than `core_ask`, which prints every
contradiction touching an answer. A line that won carries nothing: 12 of the store's 14 are settled,
most read "observed X, superseding Y", and repeating that under a current value teaches the model
nothing. So `contradictionsSurfaced` counts what was put in front of the reader on both paths, and
chat's is smaller by that rule. The stored reason names neither value, so the rival's statement is
written out.

A receipt counts rows in both paths, only those behind lines the model was shown, and links them.
`evidenceAdmitted` keeps its two meanings, split by `answeredFromClaims` as it was. Counter-evidence
is linked as well, so a trace is not one-sided, and this changes `Reasoner`'s traces too.

A technology names a question only when the question asks something a technology can be the value
of. Swift is the topic of "which projects use Swift" and a word in "why did the swift build fail".

**Consequences [measured].** The rule that tells the model to repeat a caveat is not enforced. In the
first real case it kept the line and answered from a passage. No migration: `claimID` is an optional
key in `sourcesJSON`, so saved threads decode as before and keep their old titles.

## 2026-10-31: A time question states its window and how far the store has got

**Decision.** A time phrase is a filter, parsed by rule against an injected clock and calendar. An
activity question is answered from the event log, and a topical one from passages dated in the
window. Every such answer carries a `WindowReport`: the days read, whether the span was chosen, and
freshness by kind of source. It sits inside `summary` and `insufficientEvidence` rather than beside
them, so a surface that prints either cannot leave it out. In chat it is appended after the model
finishes and never handed to the model.

**Why.** [measured] The real store's newest non-MCP sync was seven days old on 2026-10-31, so a week
with no data and a quiet week read the same. Naming the newest event only on an empty answer left
the worse case open: a few commits from a week the store only half saw looks complete.

**Rules worth keeping.**

- The clock is read per answer. `MCPServer` holds one `Reasoner` for the life of a process and
  clients keep that process for days, so a captured date measured "recently" from server launch.
- A count with a time phrase goes to the event log. `AggregateAnswering` counts all of time. It
  already declined a bare "how many commits last week", because the leftover words are a qualifier
  it cannot place, but a question matching a facet got through: "how many repositories are archived
  this month" returned the all-time figure in the voice of a computed fact.
- Freshness is by kind, and only for sources holding an object the caller may read. A handle is a
  folder or repository name, and a sync date for a hidden source says that source exists.
- Staleness is measured against the end of the window, so a stale store can still answer fully
  about last year without an alarm.
- In a window with no named subject, a claim counts only if a retrieved passage supports it. Pooling
  subjects from passages listed 41 claims for "what did I decide about retrieval this month",
  led by a project's language [measured]. That went to 15.
- In chat the question's own words decide the route, and anchors only help find a name. Anchors
  are stemmed search terms, so "working" arrives as "work worke", which is no one's topic. A window
  carries to a follow-up as a value, because "recently" is a stopword and never came through as text.

**Chosen, not measured.** 14 days for "recently", 3 for "a few", 24 hours of lag before a source is
called stale, and "n units ago" meaning the calendar unit it lands in. Each says so where it is set,
and the first, second and fourth are marked on the window and printed.

**Consequences.** No migration: `freshness` is a read of existing columns. Any caller doing its own
retrieval for an answer must use `Answer.searchedText` and `Answer.window`. Four did not, and each
wrote a model summary from all of time under an answer about one week.

## 2026-10-31: The decisions around a sync moved out of the app

**Decision.** `SourceSync` (CoreGraph) owns where a read starts, what an empty or failed one does,
and when the sync date moves. `SyncLane` and `SyncCoordinator` (CoreIngest) own overlap. The app and
the CLI both call them. No migration.

**Why.** The first version of scheduled sync was tested only at `SyncSchedule`, and what could
actually lose data sat in `AppModel`, which has no test target. Reading that code against the
requirement found defects no test could have caught. The ones worth remembering:

- The sync date was taken after the read, and connectors skip `modified < since`. Anything changed
  while a read ran was missed for good, and Notes can take minutes to answer. It is now the moment
  the read began. Reading something twice costs a comparison; missing it costs the change.
- The overlap guard ran once, at the start of a scheduled pass, and nothing else asked.
- `reminders ?? []` turned a failed read into an empty one, which reported success.
- Reminders ignored `since`, so an hourly sync derived from all 5,371.
- A scheduled tick could raise a permission prompt with nobody there, and the request does not
  return until someone answers, which would have held every other source behind it.
- Only the schedule wrote a source's record, so a sync by hand left an old error on screen.

**A task local, not a flag.** A pass has to run the individual syncs inside it, and a click arriving
during that pass has to be refused. A flag saying "a pass is running" cannot tell those apart. The
overlap tests run real concurrent tasks for that reason.

**Found by a test written for something else.** Dropping the same two files twice reported one as
changed. `Store.ingest` compared a date rebuilt from the 1970-based column with one built from
seconds since 2001, and sub-second values do not survive that: 33 of 102 real mtimes [measured]. It
now compares the stored value. The first measurement of this said 0 of 200,000, because it built its
dates from the 1970 side, the one path that cannot lose bits. Measure the real path.

**Refused rather than queued.** Queueing is the stacking this exists to prevent. A person gets a
banner naming what is running. The cost is that a file dropped during a sync has to be dropped again.

**Filtering by modification has a hole, and it is closed.** An event made months ago that has just
entered the look-ahead has an old modification date, so a filter on that date alone would skip it
on every sync. Anything that was past the end of the last sync's window is read regardless.

## 2026-10-31: A read that fell short holds the sync date, and Notes waits for a person

**Decision.** `ConnectorBatch` moved to `CoreModel`, gained `unread`, and is what `SourceSync` takes
whole, so no call site can drop a field. A non-empty `unread` keeps what was read and leaves the date
alone, and `SyncSchedule.Outcome.held` says so on the record. Password-protected notes are counted
apart and never read. Notes joins the schedule only after a read someone started has brought
something back. In `domain(forFolder:)`, words that close a note still match anywhere, and words that
open one have to be whole words. No migration.

**Why.** The review of the Fresh store item found the silent loss `SourceSync` says it prevents still
open: 1 note read of 3,000 returned normally and moved the date, and the other 2,999 fell behind
`modified < since`. Refusing to advance is the whole fix, and locked notes are why it needed a design:
if they may fail on every read [inferred], counting them as failures stops Notes advancing for good.
Holding the date costs a comparison against the floor, because the connector reads the whole library
each time; moving it costs the notes.

**Why the schedule change and the classifier change together.** The schedule decided, with no click,
that a whole personal library flows through a folder-name guess whose substring matching sent
"Passcodes" to `.project`, which an MCP caller reads. Either change alone leaves a gap: the gate alone
leaves one click from the same result, and whole words alone leaves an unattended Automation prompt.
The live store holds 0 Notes objects, so neither needed a repair. Had they been stored first, a
changed note re-read under the stricter rule would have gone from `.project` to `.personal`, and from
`.work` to `.restricted` for good, per `retainedImportDomain`, and an unchanged one would have stayed.

**Rejected.** A date per record, which needs a migration. `.restricted` for a folder named like a
credential: from a sync that is permanent, and `.personal` is already out of an MCP caller's reach.

## 2026-10-31: A record rewriting itself is settled by time, and a plan is compared by date

**Decision.** `objective`, `last_verified_commit` and `next_action` are functional and are
`Predicate.documentRestated`; `next_action` joined both sets and is now dated. Before adjudication, a
slot retires any claim whose own record has since said something else, ordered by world time and then
by when it was read. A file is the same record by name within a slot, because the same `STATE.md`
reached the store as three objects through three sources, and anything else by object id. A document's
rewrite writes no contradiction row. A repository's change keeps one row per change. `standing` makes
the tiers from `generatedSummary` to `authoredArtifact` equal for those three predicates only. A
contradiction alerts only when its slot has never held that pair of values. No migration.

**Why.** The defect was calling succession a contradiction, not the predicates being functional.
Removing them loses the single current value, because beliefs exist only for functional predicates, and
`next_action` was the proof: outside the set, 2 slots held 5 live values, none ever replaced. The rule "only functional predicates contradict" is unchanged, and `built_with`, `met_with`
and `verify_command` stay out.

**Why not only same-document succession.** Three things the first version left open, all found by
measuring. Authority froze a repository brought back from the archive exactly as it froze the
objective, so the rule covers any record, not only files. Language readings could share a push date,
and only read order separates them, so order has a second key. Same-name retirement erased a value
another document still stated, so a claim retires only when everything behind it has moved on.

**The overwrite underneath.** `claim_evidence` holds one stance per pair and a repository's evidence
has no byte range, so writing `.refutes` overwrote a claim's own `.supports`. 14 claims had no support
left, 9 of them current, and an answer drops a claim with no support. Evidence both claims rest on is
now skipped, which leaves no refuting row when only the passage of time changed the conclusion.

**Measured on a copy of the store, 2026-10-31, not applied.** A rehearsed rebuild took 14 contradiction
rows to 4, 0 of them open: the 6 document rows went, the 2 open language rows resolved and stayed as
rows, the 4 dormant-to-active rows went because each of those pushes was a README or policy edit, the
2 rows for one archived repository became 1, and one repository went dormant, which adds 1. Slots with
more than one live `next_action` went from 2 to 0, and current functional claims with no support from
9 to 0. No row id survived, because dates are part of a claim id. On a second copy, one reconcile and
then three re-reads of every object reported 0 new contradictions throughout, and the second and third
re-reads wrote 0 beliefs and found 0 contradictions. Those re-reads stand in for a sync: no connector
ran, so nothing here measured a real sync.

**Without a rebuild the fix is partial.** Re-reading closed the 2 open rows, and left the 14 old rows
on the screen with their old reasons. Older `active` claims are dated by the push, so 3 of the 5
repositories whose last push was documentation stayed `active`, where a rebuild reads all 5 as dormant.
A retracted claim stays retracted on re-extraction, so OpenCore's frozen objective stayed frozen, and it
waits for the file's next change or a rebuild.

**Rejected.** Removing the three predicates from the functional set. Letting recency beat authority
everywhere: a model proposal must not displace what a person wrote, and a newer file must not overrule
a correction, so the cost is that a correction outlasts every later document. Dating `primary_language`
by sync time: every sync would mint a claim id for an unchanged fact.

## 2026-10-31: A repository record is read in order, and a value it returns to is a new reading

**Decision.** Within a repository record, a later read outranks an earlier one whatever the claims'
dates say. Within a document, world time still comes first. A value a record said, stopped saying
and said again gets a new claim dated by that read. A retired claim records its counter-evidence
one way, and a retired reading that shares its evidence gets a row of its own.

**Why.** [source] World time can't order a record's readings. `dormant` is dated by a threshold and
`archived` by the last push, so a repository archived after going quiet read `dormant` as newest and
an inferred status retired an observed one. An archived repository can't be pushed to, so its claim
id never changes and that stood for good. The connector records no archive date, and this holds
whether or not archiving moves `pushed_at`. Whether it does was not measured: the owner has no
archived repository to check.

**A retraction isn't undone.** Clearing `retracted_at` would have been shorter, and it would have
rewritten a past checkout and let a re-read undo a correction. The value's old row stays retired.
What `reading` compares is the record's own last reading, so a status a document outranked is not
"new" on every sync [test].

**Evidence ids stay as they are.** An id is its object and byte range, and receipts link to it, so
adding the snippet to every id would have cut those links on a rebuild. Only a collision takes a new
id. After a rebuild, a receipt that cited a line later rewritten at the same length shows the first
wording, where the live store shows the last.

**Not on real data yet.** [measured, a copy of the store, 2026-10-31] 0 repository objects have
`archived` true, and no store repository holds both `archived` and `dormant`. 0 of the 8 belief
versions with a predecessor replaced a claim in a domain MCP does not admit, so the gate on a reason
guards a path no row takes today.


## 2026-10-31: Cut the scope and start building, with four items left open

**Decision.** Private names, focused answers, time windows, fresh store and honest beliefs were built
and reviewed. Rebuild, Home, hardening and currency get no review pass now. Rebuild, Home and hardening
keep what is in the tree, marked unreviewed. Currency was not done. The owner's next step is the
commit decision and then his first feature.

**Context.** The owner stopped the run because hardening work had overtaken building on it. The
reviewed items are the ones that change what an answer says. The four cut items do not block a new
feature, with one exception below.

**Alternatives.** Finishing the run, which would have reviewed all nine. Reverting the unreviewed code,
which would lose tested work and require a second pass to recover it.

**Consequences.** `--apply-rehearsal` writes the live store through unreviewed code, so nobody applies
one until rebuild has been reviewed, even though applying is what fixes the live store's frozen
objective and its claims with no support. Live computer control stays on dry run. Notion's rebuild row
went back from Completed to In Progress with evidence `test`, because its copy measurement predates
the beliefs rework.

## 2026-10-31: No new MCP tool

**Decision.** Add none. The eight tools stay.

**Context.** The candidates were a way to read what `WindowReport` and `Store.activity` produce, a sync
trigger, and a status tool. `core_ask` already answers activity and status questions with a window, and
freshness comes with every windowed answer, so a read tool would duplicate it. A sync trigger is a write
from a caller that is not the user. Personal data over MCP is closed on purpose.

**Rationale.** The value of the pass came from making existing tools answer better. The cheap gain left
is making `core_claims` answer about a technology and adding focus to `core_ask synthesize`, and neither
needs a tool. A new tool also has to pass the healthcheck that hardcodes the count in `MCPSourcesView`,
and the two `isClaimAdmitted` functions should be unified before anything else reads claims.

**Consequences.** Reconsider only when a client needs something `core_ask` can't express, and then
check what it can reach before what it can do.

## 2026-10-31: A fixture date comes from the 1970 value

**Decision.** A test that compares a `Date` with one read back from the store builds it with
`Date(timeIntervalSince1970:)`.

**Context.** `Date` holds seconds since 2001 and the columns hold seconds since 1970, so a current
`Date` loses its last bit on the way back about half the time (99,873 of 200,000) [measured]. One
test built its date from `Date()` and failed 5 of 6 runs when repeated, after 539 had been reported
passing. The product was right, because `Store.ingest` had already been fixed for this same loss.

**Consequences.** A single passing run proves less than it looks like when a test touches the clock.
`Docs/ai/RUNBOOK.md` carries the symptom.
