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
| 0 | `CoreCompanion` | iOS/macOS wire types, authenticated encrypted transport, pairing and session decisions. No engine or SQL dependency |
| 0 | `CoreJSONRPC` | Messages and the stdio and HTTP transports, shared by the MCP server and client |
| 1 | `CoreStore` | Every SQL string: `Store`, `Chunks`, `Activity`, `HomeSnapshot`, `Conversations`, `RebuildDiff`, `Export`, `LocalPrivateNames`, migrations |
| 2 | `CoreIngest` | Connectors, MCP client and OAuth, Keychain, `AgentMemoryPolicy`, `SyncSchedule`, `SyncLane` |
| 2 | `CoreGraph` | `IngestPipeline`, `EntityResolver`, `ClaimExtractor`, `BeliefEngine`, `BeliefAlerts`, `SourceSync`, `RebuildRehearsal` |
| 2 | `CoreSearch` | `AdmissionPolicy`, `HybridSearch`, `PassageSearch`, `TemporalIntent`, embeddings |
| 3 | `CoreReason` | `Reasoner` (claims, no model), `Conversation` (chat), `QueryFocus`, `WindowReport`, `AggregateAnswering`, `Grounding`, `ModelClaimProposer`. The only layer that reaches a model |
| 4 | `CoreCompanionHost` | Mac-only typed owner reads and existing answer engines, with per-device domain ceilings |
| 5 | `CoreMCP`, `opencore`, `Apps/OpenCoreMac`, `Apps/OpenCorePhone` | Surfaces; the phone imports only `CoreCompanion` |

Four answer shapes `[source]`: `Reasoner.answer` assembles claims with no model. `Conversation.answer`
is grounded chat, on-device first. `AggregateAnswering` answers counts from SQL. `AgendaAnswering`
lists the owner's calendar and reminders from their objects by date and status, for local callers only,
after any count. Each gets the same admission policy before anything is ranked.

[source] `CoreJSONRPC.HTTPTransport` owns individual request executions. A mutex-protected completion
winner covers headers, streaming reads, an application deadline and caller cancellation; synchronous
URLSession task registration permits cancellation before headers. Logical completion does not wait
for native cancellation acknowledgement, and late workers cannot replace it. Injected sessions stay
caller-owned. Shutdown closes this transport; overlapping legacy initializations are refused before
another POST can replace session ownership.
[source] `HTTPResponseDecoder` checks response IDs/envelopes, preserves recognized failed-HTTP RPC
details plus status, and prioritizes authorization failures. It frames whole UTF-8 SSE events, ignoring
notifications until a response, without dispatching incomplete EOF data. Chosen budgets are8MiB
consumed bytes and400 diagnostic bytes; these are application limits, not process-memory or protocol
maxima. Legacy session headers publish only after a completed successful initialize response. Protocol
revision/header selection is still a separate migration job. Isolated custom-scheme URLProtocol fixtures
cannot fall back to a real service. Current API contracts were checked against macOS27 SDK/docs on
2026-11-01; fixture tests establish behavior, not real-service interoperability.

[source] Exact wire IDs use `RPCWireObject` and sealed `RPCID` integer tokens. A strict whole-
document grammar pass precedes semantic checks and safe fixed-length ID masking; other fields stay
in JSONValue. Canonical numeric equality uses symbolic exponents without floating conversion or
expansion; string identity/hash compares decoded UTF8 code points. `RPCRequest.decode(Data)` and
`RPCResponse.serialized()` replace the lossy Foundation ID routes at server, playground and fixture
seams; both client transports correlate exact IDs before interpreting response fields. Application
budgets8MiB/128levels are chosen limits. Ordinary numeric payload representation is unchanged.
[test] Raw IDs, typed echo, both transport seams and prior contracts passed760 full tests/17 runtime
mutations with separate review; proof/limits: [exact IDs](ai/verification/2026-11-01-exact-rpc-ids.md).

[source] Stdio client replies use `StdioReplyInbox` exact-ID registrations and per-owner receipt
floors/deadlines. The reader stamps whole chunks before parsing, decodes outside its state mutex and
publishes only to current owners; other concurrent callers cannot discard their replies. Cached
on-time data survives EOF/expiry; stopped or withdrawn work cannot publish a late parse. Chosen
active/cache/FIFO budgets bound retained wire data and metadata. Post-encoding health/cancel
admission feeds a single FIFO client stdin writer with an owned nonblocking, per-FD SIGPIPE-suppressed
endpoint. Queued/zero-byte cancellation is local; interrupted partial frames close the shared stream.
Byte progress is applied before final-byte cancellation classification. Pointers/descriptors never
cross await, and all shutdown callers await the same owned close. Chosen128-frame/16MiB queue budgets,
16KiB syscall chunks and5ms polling are application choices. Encoding remains synchronous and reply
eligibility uses its existing clock; no whole-exchange/confirmed child-exit guarantee is claimed.
[test] Ownership passed777 full tests/25 mutations and separate review; proof:
[stdio ownership](ai/verification/2026-11-01-stdio-ownership.md).
[test] Client stdin writer passed791 full tests,16 writer/6 reader faults, separate review and builds;
proof/limits: [nonblocking stdin](ai/verification/2026-11-01-stdio-writer.md). TERM remains an unconfirmed
request; safe owned exit has a separate High roadmap row.

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

[source] JARVIS operator briefings are deterministic observations with per-snapshot capture/attempt
metadata, not synthesized evidence. Complete/partial/failed reads stay distinct; failed refreshes do
not redate cached values, and late row or inventory results cannot replace newer observations.
Unknown Git fields cannot certify a clean tree. Inventory counts are materialized at collection.
The numbered-file scan uses chosen cooperative entry/deadline limits between filesystem operations;
a single filesystem call can still block. Stored beliefs remain in the evidence workspace.

---

## What is reviewed

As of 2026-10-31 `[source]`: private names, focused answers, time windows, fresh store and honest
beliefs were built, adversarially reviewed and repaired. Rebuild was reviewed on copies. The companion prerequisites and owner channel received separate adversarial passes. Home still needs owner screen review, and the repository-wide WWDC26 currency pass is not complete. `Docs/ai/STATE.md` has the list.

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

[source] New claim and passage answers link the exact spans and original passage scores in one
receipt transaction. System answers use the already retrieved answer, preserve per-claim authority
and caveats, and save once after supplemental prose is chosen. A local writer's identity is recorded;
deterministic prose has no model. Legacy passage-only receipts may predate persisted span links.

---

## Outbound request accounting

[source, 2026-10-31] Cloud submission is recorded when a prepared request is handed to transport.
Source-object counts use distinct represented floor IDs in that prompt. Optional HTTP status,
recognizable provider application response, and structured-answer decoding stay separate. Missing
measurements are omitted. The legacy integer counts application-acknowledged source objects;
unconfirmed submissions stay in stages and shared presentation, even after deterministic fallback.
These observations do not prove bytes, retention, or the egress of questions/instructions.

[source] Each submitted cloud request also saves an independent request-audit receipt with real
claim/passage provenance. It survives disabled chat history, cancellation and absent phone ACK.
Authenticated device/grant metadata limits phone access without asserting delivery. A later answer
receipt links the audit; companion.delivery is added only after ACK. Request audits are labelled as
such, and failed persistence is reported rather than hidden. No schema migration was added.

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


## iPhone owner channel [source, 2026-10-31]

The phone is a native SwiftUI remote. The Mac keeps the only store and runs the existing
`Conversation`, `Reasoner` and `PassageSearch`. `CoreCompanionHost` has no SQL or operator path.
The engine remains Mac-only; only the dependency-free wire target is built into the phone.
MCP remains a separate, model-facing, read-only channel with its existing domain gate.

The Mac connection is off at launch. Enabling it requires a selected, currently assigned, up
Tailscale tunnel address. `NWParameters.requiredLocalEndpoint` pins the listener to that literal
IPv4 address; there is no wildcard or LAN fallback. In-person invitations pin the Mac public key,
expire after two minutes and authorize one phone. The phone uses a biometric-protected Secure
Enclave P-256 signing key, a fresh Mac challenge and ephemeral ECDH. Direction-specific HKDF keys,
AES-GCM and authenticated sequence numbers protect each fragment. Limits are chosen: five-minute
sessions, eight active connections, eight volatile resumable responses, eight MB per message,
600-byte fragments and TCP MSS 960. These sizes are design choices, not packet measurements.

[source, references checked 2026-10-31] Xcode 27.0 (27A266a), iOS/macOS 27 SDK interfaces and
Apple's current [Secure Enclave signing key](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey),
[local endpoint requirement](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint),
[biometric evaluation](https://developer.apple.com/documentation/localauthentication/lacontext/evaluatepolicy(_:localizedreason:reply:))
and [TCP segment limit](https://developer.apple.com/documentation/network/nwprotocoltcp/options/maximumsegmentsize)
references were read. Tailscale documents its [1280-byte MTU](https://tailscale.com/docs/reference/troubleshooting/network-configuration/tcp-connection-two-devices).
These references establish API contracts, not this app's behavior on a physical phone.

[source] A paired grant is the maximum domain set. Query admission may narrow it. Browse queries
filter before pagination. Claims require admitted subjects, targets and supporting floor objects.
New pairings receive a random grant ID; conversation context and resumable responses cannot cross
a changed grant. A change in a chat turn's admitted set clears model context and retrieval anchors.
Limited phones can read only their current grant's own receipts, because historical raw questions
and stage notes have no independent domain label. Full-domain owner phones can inspect all receipts.

[source] Supplying a new valid code for an existing signing identity persists a fresh grant with the
new code's domain ceiling. A code-free reconnect retains the existing grant. Grant replacement and
revocation return the precise displaced grant, so delayed cleanup cannot cancel a newer session or
erase its replay state. Failed code validation or persistence retains the prior grant.

[source] Phone delivery counts as transmission off the Mac. The delivery stage records the paired
device ID, name, grant ID and distinct floor objects directly quoted or cited in the delivered answer.
`objectsTransmitted` is at least that count; a pre-existing model transmission count is preserved.
Consulted evidence stays in the trace even when not directly quoted. Claim and passage provenance,
including actual retrieval scores and immutable passage snippets, is saved atomically with the receipt
after acknowledgement. Confidence remains nil. Draft tokens are explicitly unverified; they do not
produce a completed-delivery receipt. This counter describes completed acknowledged answers, not a
byte-level record of interrupted draft fragments. Browse reads do not create answer receipts.

[source] Closing a connection, revoking its grant, stopping the server or expiring a session cancels
in-flight preparation. After an authenticated acknowledgement, the receipt commit may finish even
if the final socket write fails. A five-minute, memory-only resume cache reuses the same generated
response and commit instead of inventing a newer generation time or a second receipt. The phone
stores only pairing/key material and its last-reachable timestamp. Evidence and answers are cleared
on background lock. No APNs, remote wake, second database or offline evidence cache is implemented.

[source, in progress] Saved-phone-chat primitives bind each thread to its pairing grant and domain
ceiling, recheck the admitted history before exposure, and compare the ordered exchange revision in
the acknowledged write transaction. Schema 7 adds an exportable digest-only deletion marker so
current readers and acknowledged saves reject a deleted thread even if its rows are recreated. A
trigger rejects unmarked deletes from an already-open older writer; it does not prevent every insert
by older code. The in-progress saved-chat generation route uses a fresh actor per request and carries
the revision from the restored snapshot to its ACK-gated save. It withholds drafts for now, checks
old history and new answer references in one read snapshot, and revalidates cached saved answers and
history pages before sending them. Cached pages without an explicit validator refuse retry/resume;
other read routes still need validators and an initial-send disclosure audit.
Deletion markers cannot backfill threads deleted before this migration. No live-store migration was
performed for this work.

[design] The full-fidelity goal includes later store actions and operator views/control. Their routes
are absent from this first read-only channel. Physical Face ID, real-tailnet pairing, sleeping-Mac
behavior and generation parity with real models still require the owner's phase review.


## Internal Mac review bootstrap [source, 2026-11-01]

OpenCoreReview is a separate background-only Foundation entry point, built with only
OpenCoreReviewSupport (CoreStore/CoreTelemetry). Production app UI/controller types are not linked into this
bootstrap. The regular app rejects review arguments before constructing AppModel. There is no
fallback to the default store. Policy admits an explicit regular nlink1 file under a private copy
root, rejects aliases and SQLite sidecars, then opens an immutable read-only snapshot.

[source] Ordinary Store/Database opens retain their defaults. The distinct snapshot factory uses
escaped URI options and skips sidecars/locks only for self-contained, unchanging copies. The typed
creator uses SQLite backup, changes only the new destination's journal mode/permissions and removes
only its owned detached SHM index after close. Both backup kinds reject preexisting auxiliaries.
No schema or migration changed. Actual screen/model/settings injection is a subsequent job.

[source, references checked 2026-11-01] API contracts: Apple's [App Sandbox](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox),
[read-only file exceptions](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html),
SQLite [immutable URIs](https://www.sqlite.org/uri.html) and [WAL read-only behavior](https://www.sqlite.org/wal.html#read_only_databases).
The macOS 27 SDK exposes the required open flags; installed SQLite reports 3.54.0. Compilation,
signed-metadata inspection and fixture execution are separate evidence in the verification artifact.

## Explicit Mac presentation ownership [source, 2026-11-01]

CorePresentation contains macOS settings and adaptive Pastel tokens. Settings requires one explicit
UserDefaults instance for reads/writes and explicit effects for scheduled sync, returning to dry run
and MCP configuration. Only the production app bridge chooses standard defaults and controller
callbacks. Initialization restores state without invoking effects; named next-launch automation
confirmation and dirty/reset semantics remain unchanged. App-local NSApp appearance behavior remains.

[source] Glass card/bar/badge ViewModifiers resolve environment settings in body. The package and
theme extraction does not yet isolate AppModel or view tasks, remove the production environment
fallback, or qualify actual screens. Tests and current Apple references:
[settings ownership](ai/verification/2026-11-01-settings-ownership.md).

[source] MCP startup preference writes use a typed field-preserving SharedConfig updater, with
preparation refusal, unknown write/readback and matching observed confirmation kept separate.
Requested defaults never prove persistence. A one-shot strict initial read can restore saved
authorization; attempted changes, unknown observation and invalidation cannot silently reinitialize
it. New playground servers and clipboard copies revalidate current shared state. Generated clients
contain no unsafe override. Existing servers and explicit external unsafe arguments keep their
startup behavior. Proof/limits: [MCP preference](ai/verification/2026-11-01-mcp-preference.md).
