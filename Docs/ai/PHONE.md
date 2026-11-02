# iPhone companion: phase review

[source, 2026-10-31] The owner requested complete native mobile fidelity, including control, and
coordinated Mac/iPhone icons. This working tree implements the prerequisites and first read-only
phase. It is not phase acceptance. The owner has not yet confirmed a Mac screen review or performed
in-person pairing. The Notion companion brief remains the authoritative roadmap.

## Coverage of the Mac's twenty sections

[source] This table comes from the current `enum Section`, not a reconstruction of the missing
112-cell ubiquity audit. “Later” means absent, not an agreed permanent omission.

| Mac section | iPhone implementation | Remaining fidelity |
|---|---|---|
| Command Center | Scoped counts, seven-day activity, freshness | Mac dashboards, Jarvis and pressure cards later |
| Grounded Chat | Mac Conversation plus deterministic Reasoner mode, saved-chat source path, sources, receipts | Saved-chat drafts are withheld; durable retry, other actions and real-model parity remain |
| Repo Fleet & Handoffs | Later, phase 3 | Entire operator view |
| Coding Agents Hub | Later, phase 3 | Entire operator view |
| Computer Use Studio | Later, phases 3/4 | Reads first; control blocked on Local Hub fixes |
| AI Models & RAM | Later, phases 3/4 | Inventory, load/unload |
| Hardware, USB & Disk | Later, phases 3/4 | Inventory and guarded operations |
| Knowledge Graph | Entity search and admitted claim dossiers | Spatial graph, aliases and relationship visualization |
| Timeline & Time Travel | Scoped paged event timeline and belief checkout | Full Mac event detail interactions |
| Connections & MCP | Connection/pairing status on phone | Mac MCP server/client management remains Mac-only |
| Settings | Face ID unlock, pairing, lock, forget, recovery | Mac preferences and configuration remain Mac-only |
| Reality Checks & Diffs | Admitted contradiction records | Resolve/diff actions in phase 2 |
| Claims | Search, metadata, support/refutation and full sources | Corrections in phase 2 |
| Beliefs | Current belief versions and admitted reasons | Corrections/history interaction in phase 2 |
| Passages | Scoped browse and ranked retrieval, full source drill-down | Physical network performance unverified |
| Receipts | Complete receipt JSON and linked trace | Limited grants see only their current grant's own receipts |
| Time travel | As-of belief checkout | Owner interaction unverified |
| Sources | Domain, kind, authority and last successful sync | Sync/resync in phase 2; no connector credentials on phone |
| Corpus | Counts, search, complete object text/metadata/URI | Large-response edge cases need physical testing |
| Maintenance | Later, phase 2 | Rehearsal/report only; agent never applies a rebuild |

## Phase 0 evidence

[test] `MigrationSafetyTests` proves rollback, newer-schema refusal and fail-closed unknown domains.
`unsupportedClaimsStayOffEveryAnswerSurface` proves shared admission through MCP and Reasoner.
[source] The unsafe MCP setting now names mixed restricted data and requires destructive confirmation;
running MCP clients need reconnection. No migration or schema version was added.

## Phase 1 “done when” evidence

| Requirement | Evidence and outstanding proof |
|---|---|
| Same answer and receipt as the Mac | [test] Deterministic Reasoner fixture compares summary, receipt consultation counts and admitted domains, plus trace after ACK. [source] Generative chat calls the existing Conversation with the Mac's settings. Real-model/physical-phone parity is unverified. |
| Blocked domain stays blocked | [test] Every read section and direct object/entity/domain lookups exclude blocked fixtures. Timeline admission precedes LIMIT. Re-pairing narrows chat context and receipt access. |
| Revoked phone gets nothing | [test] Authentication rejects revoked keys; revocation cancels a suspended read and closes its transport. Physical socket test unverified. |
| Stranger on tailnet gets nothing | [test] Unknown identities, reused/expired invitations and replayed proofs are rejected. [source] Listener pins an assigned tunnel address. A real-tailnet stranger test has not run. |
| Usable while Mac asleep | [source] Offline UI names sleep, a closed Mac app and expired Tailscale sign-in, with last-reached time. Actual sleeping-Mac timeout and reconnection require the owner. No remote wake. |

[source] Limits: five-minute sessions, two-minute invitations, eight connections and eight cached
responses, eight MB per message. Resume is a completed-response retry, not a byte-offset checkpoint.
Backgrounding locks and clears evidence. Drafts may be interrupted before their delivery is audited.
Secure Enclave keys have no simulator fallback; physical Face ID cannot be certified by simulator UI.

[design] The owner has authorized the remaining phases. Local Hub still needs `admit_control` on
`desktop_type`/`desktop_press`, policy coverage for Trash/Erase, and its token removed from unauthenticated
bootstrap. No Local Hub, USB, monitor or live control work was performed here.

[measured, 2026-10-31] Simulator smoke captures and exact verification scope are in `verification/2026-10-31-phone/README.md`.

[measured, 2026-10-31] At the owner's instruction, the signed companion 0.1.0 (1) was installed on the physical iPhone. Device app inventory confirmed the version. It was not launched or paired; the matching Mac build still needs installation.

## Independent cloud request audits

[source] Answer delivery receipts still require the phone ACK. A submitted cloud request has a separate
request-audit receipt saved on the Mac before answer delivery, including after failure/cancellation.
It contains actual admitted claim/passage provenance and current authenticated request ownership,
never a fabricated source or phone-delivery stage. A limited phone can read only its current grant's
request audits; re-pairing does not restore its previous grant's history. Completed deterministic
fallback warnings can be delivered with their audit disclosure. Failed audit persistence is reported.
[source] Source-object counts exclude question/instruction bytes. HTTP contact, application response
and answer decoding are separate observations; no receipt proves packet/byte delivery or retention.

[measured, wrap-up2026-11-01] Read-only physical-device app query exit0 confirms OpenCorePhone0.1.0(1)
installed. Latest Mac baseline installed/launched with --verify0. Latest owner pairing answer remains
“Not tried yet”; no physical pairing/Face ID/reconnect or phone-control acceptance is claimed.

[measured, follow-up2026-11-01] Then-current source device build0 and strict signature verification0;
fresh physical-iPhone install0/outcome success and postinstall query0. App0.1.0(1), not launched.
Mac0.2.0(2) installed/running; staged source inputs matched at that time. The later receipt-scope
and SQLite text repair is built but not installed on the Mac. Pairing/Face ID/phone controls remain
unverified or incomplete as listed above.

[measured, latest checkpoint 2026-11-01] The current signed iPhone build was installed and the app
was found in device inventory. The matching Mac build is installed but has not been launched.
Opening that production build applies missing migrations to its configured store. The current phone
has not been launched or paired in this checkpoint; Face ID and real network behavior remain untested.

[test, measured, 2026-11-02] The first real Enable on the Mac failed with POSIX 22, so no pairing code
had ever been produced. `NWListener(using:on:)` rejects a port that `requiredLocalEndpoint` also names;
the listener now takes the port from the endpoint alone. Every earlier companion test used an in-memory
peer. `CompanionSocketTests` covers listener start, pairing, a 180 KB page and code-free reconnect
over real loopback TCP with production parameters. Socket failures now read as the named Mac-unreachable
message. The Mac has a Copy pairing code button. Both builds installed. A real tailnet bind, the
physical phone and Face ID remain unverified.
