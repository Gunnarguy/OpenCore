# Current State

Updated: 2026-11-02 (America/Los_Angeles)
Branch/worktree: main, ~/Documents/GitHub/OpenCore
All work is committed locally on top of 08f4e80, one commit ahead of `origin/main`, and not pushed.

## Objective

[design] Owner, 2026-11-02: finish what Codex left, and he has forgotten the app's main purpose. That
purpose is a memory of his own life that shows its evidence, so answering his real questions comes
first. The phone has never connected, so nothing is built on it until it has. The eight completion
areas in COMPLETION.md stand, with the MCP migration and saved-chat hardening frozen until then.
Phone coverage/acceptance: PHONE.md.

## Exact Next Action

[measured, 2026-11-02] Three steps are the owner's, in this order. Sync Apple Calendar once from
Sources and allow it: the schedule record says Calendar was never allowed, so it last synced
2026-08-14. Do the same for Notes, which holds no objects. Then turn Tailscale on and pair the phone.
[measured] A bundle of 70c3c48 and `Local/` are in `~/Backups/OpenCore-2026-11-02` on the always-on
machine, checksum matched. That network dropped Tailscale packets over about 1,150 bytes, so large copies
hung until the owner lowered the tunnel MTU to 1150, which resets when Tailscale reconnects.

[test, measured, 2026-11-02] Answers now work for his plain questions, measured on a store copy before
and after. Calendar and reminders are read directly (`AgendaIntent`, `Store.agendaEvents`,
`agendaReminders`, `AgendaAnswering`), in `Reasoner` and `Conversation`, so Home, chat, the CLI and both
phone modes get them, for the owner only. "Which projects are dormant" lists by current belief.
"Last Tuesday" reads as a day. With no subject named, subjects come from the top two passages and the
passages lead. Also fixed: a failed scan no longer reaches the planner, the Timeline's slower read can
no longer overwrite a newer one, and the phone link stays on across launches once turned on. Full suite
exit 0, 929 tests. Removing the external-caller guard, the `.personal` check and the stale line each
failed tests. Mac, iPhone and CLI are installed from this tree at about 08:36 PST, the Mac app is
running, and a fresh installed `opencore mcp` listed 8 tools. Views are `[source]`: no screen was seen.
A fresh rehearsal on a copy reports BLOCKED: 6 past answers would no longer trace, 66 of 2,260 receipt
links would be cut, 156 claims retired. That gate works, the cause is not traced, and no apply is needed
for anything above.

[measured, 2026-11-02] The owner pairs the phone and reports what happens. Enable on the Mac failed
with POSIX 22 on every real attempt, so no pairing code had ever existed: `NWListener(using:on:)`
throws EINVAL when `requiredLocalEndpoint` also names the port. Fixed in `CompanionServer.bind`.
`CompanionSocketTests` runs a full pairing, a 180 KB page and a code-free reconnect over a real
loopback socket, and the first of these failed with POSIX 22 before the fix. Full suite exit 0, 903
tests. Mac and iPhone builds installed at 08:07 PST, and the Mac app is running on schema 7. Tailscale
was Stopped on the Mac at that check, so a tailnet bind is still unproven, and so is Face ID, a real
phone, revoke and sleep. No copy of this uncommitted tree exists on the always-on machine: the rsync failed with
Tailscale off. Run it once Tailscale is on, or commit at the owner's word.

[measured, 2026-11-02] This corrects the entries below: the live store has been at schema 7 since
2026-11-01 20:41 PST, about seven minutes after the last Codex message, so a build carrying migration 007
was opened then, and who opened it is not known. Entries saying that build stayed closed or that no live
store was migrated are out of date. Apple Calendar last synced 2026-08-14 and Apple Notes has no objects.

[design, 2026-11-01] Full phone actions/operator parity, safe streaming, durable retry, other read-route
replay validation and physical acceptance remain.
Three owner-requested Gemini/AGY Argon jobs produced the phone saved-chat UI and read-only maps for
owner actions and operator views; parent verification and later repairs are recorded below. Logs:
/private/tmp/opencore-agy-phone-ui.log, ...-phase2-map.log and ...-operator-map.log.

[test, foundation complete 2026-11-01] Phone-specific Conversation restore obtains a fresh scoped snapshot,
decodes full source/verdict models, preserves IDs and receipts, and serializes against generation.
An independent review found stale context after failed refresh and generic-restore reentrancy;
both were reproduced and repaired. Ten focused restore tests, twelve runtime mutations and the
separate re-review passed. Full Swift suite exit 0 with 844 tests; normal Mac build exit 0 and the
staged Conversation.swift matched the current source; codemap 22 slices, 0 errors/warnings. Roadmap
row 40c49a74-d54f-81de-902a-f1560b278806 completed for this foundation only. The full broker save
path, UI integration, device acceptance and deployment remain.

[test, list/open complete; integration in progress] Broker saved-history list/open checks the current authenticated
grant and scope and fully decodes source/verdict models before returning records. Focused broker and
wire tests passed (9, including current-source reclassification). A separate review found that
malformed full models consumed page slots; a 41-malformed/41-valid regression failed before the fix.
Store now accepts a synchronous full-model admission predicate inside its read snapshot before
pagination; 20 focused Store/broker/wire tests passed, with a clear separate source re-review.
Full Swift suite passed 844 tests; final Mac and phone device builds passed before a subsequent
whitespace-only removal of an extra final newline in Conversation.swift. Codemap 22 slices had
0 errors/warnings and the direct sensitive scan exited 0.
An additional Argon read-only review timed out after eight minutes with no usable findings despite
its wrapper reporting success; log /private/tmp/opencore-agy-history-read-review.log. It does not yet
save new conversations: ACK-gated persistence and
durable retry recovery are the next broker job. Separate phone-UI review found missing response/thread
correlation and legacy-Mac conversation isolation issues; fixes received a clear source re-review. No new phone UI
or backend code has been installed. The phone UI and shared wire contract matched their staged device
build inputs. No installation or physical-device interaction occurred. Roadmap row
40c49a74-d54f-81bf-95c9-dcef25cb8adf is In Progress.

[test, foundation complete] CompanionHistoryLookup distinguishes a truly new scope-derived
thread from an existing unavailable one in one read snapshot. Synthetic orphan and byte-identical
BLOB identifier cases failed before fixes. Lookup and the ACK transaction reject malformed BLOB
aliases; the transaction also rechecks question, answer and receipt IDs. Thirty focused history,
exchange and wire tests, an 849-test full suite, the Mac build and separate source reviews passed.
The answer-insert rollback fixture was repaired after the new preflight made its former fault too
early; its final focused test passed. The lookup is not a reservation, and callers must still decode
the complete CoreReason models before use. Logs /private/tmp/opencore-history-lookup-final-suite.log,
...-lookup-final-focused.log and ...-lookup-mac-build.log. Next wire ACK-gated saved-chat writes.
Restore must use its fresh
current-grant Store.companionHistory snapshot, decode complete source/verdict models, refuse a
mismatched conversation ID/domain ceiling and serialize against active generation. The broker must
assign Store.companionReceiptID(for: request.id) before the prepared page is sent, verify actual
source/trace admission, persist only after ACK, and support durable retry recovery. Do not set
Conversation.persistHistory to true: it inserts the receipt before ACK and would then try to insert
it again. Re-pairing, scope changes and Mac-added unlabelled turns must fail closed.

[design, in progress] A versioned, byte-framed SHA-256 request fingerprint and a saved-delivery
adapter are now in source but are NOT called by normal chat generation. The adapter assigns the
deterministic receipt ID before preparation and saves the question, answer, receipt and trace only
after ACK. Synthetic tests cover successful ACK, a forced late rollback, current-scope claim denial,
an untrusted thread appearing before ACK, warning preservation and forged request/scope rejection.
Thirty-eight focused Store/companion tests passed; fingerprint and delivery reviews, full suite,
actual generation wiring, durable retry and deployment remain. Logs
/private/tmp/opencore-saved-delivery-final-focused.log and ...-history-fingerprint-focused.log.
Digest notes now have an explicit v1 marker so a future algorithm can retain a v1 verifier.

[test, in progress] A synthetic evidence-ID collision showed that a passage could be linked to a
different stored object and overwrite its snippet. Before/after-prepare regressions failed before
repair. Saved chat, legacy chat and Evidence answers now check byte-exact evidence provenance before
preparation and again in the ACK write transaction; 44 focused tests pass, including object, range,
authority, snippet, BLOB, duplicate and acknowledgement-race cases. The subsequent full suite
passed 861 tests; independent review and a current Mac build remain. Logs
/private/tmp/opencore-passage-conflict-final-focused.log and ...-passage-conflict-full.log.
[test, in progress] Source reclassification between preparation and ACK was also reproduced for
current and prior saved-chat sources, legacy displayed sources/claims, and Evidence answers. The
public saved-chat write rechecks the prior thread and new source/trace admission inside its write
transaction; non-history phone receipts recheck displayed references and actual trace rows there too.
The expanded request-shape and explicit-domain matrix and 58 focused tests passed; separate source
review is clear, including isolated displayed-object, displayed-claim, evidence-trace and claim-trace
tests. A fresh broad run and Mac build remain. Log /private/tmp/opencore-legacy-ack-admission-fixed.log.
[test, source complete] A separate review found ACK persistence failures reached the phone but not
the Mac's sticky failure banner. CompanionBroker now reports a generic privacy-safe diagnostic
through onDeliveryFailure, and CompanionHostController wires it to AppModel.recordAuditFailure.
Four focused tests passed across saved, legacy, Evidence and successful delivery; the independent
source review found no remaining actionable issue. A current Mac build remains. Log
/private/tmp/opencore-phone-failure-sink-focused.log.

[design, in progress] To prevent two different requests generating from the same saved context
and both committing, CompanionHistoryRevision captures the ordered question/answer/receipt IDs.
The public save requires the expected revision and compares it inside the same write transaction;
the broker carries it into ACK. A separate design review found an ABA gap after deletion; synthetic
regressions failed before migration 007 added a digest-only, exportable deletion tombstone. A second
regression showed already-open older writers could bypass it; a migration trigger now rejects their
unmarked deletions, with a transient authorization cleared in the current delete transaction. The
trigger does not fence older inserts; new reads and ACK writes independently reject the marker. A
synthetic test of recreated rows passed, and failed when the shared reader's guard was removed.
Sixty-one earlier focused history/migration/export tests passed; a separate source pass found no
remaining actionable defect within the current-reader/ACK and older-delete-guard scope. Broad verification,
Mac/phone builds and deployment remain. Historical deletions made before migration are not backfilled.
Actual generation must capture its revision from the exact snapshot it restores BEFORE producing an
answer, rather than refreshing it after generation. No live store was migrated or rebuilt.

[test, source] Conversation.restoreCompanionHistoryWithRevision now returns the decoded turns
and the revision from the same admitted Store snapshot used to rebuild context. Eleven focused
restore tests passed, including a later write making the returned revision stale; a separate source
review found no actionable wrapper defect. The fixture does not force a concurrent write during
restore or run a real model. Generation wiring must use a fresh actor per operation (or serialize
restore through generation), so an intervening send cannot change context. No current app build
includes this change.

[test, in progress] A byte-identical BLOB conversation or turn alias was already rejected by lookup
and ACK, but direct/list reads could still expose the TEXT thread. A synthetic regression failed in
both reads before the shared history reader gained the same alias check. Seventeen focused Store,
eleven restore and four wire tests passed afterward; the separate source review found no actionable
defect. Additional cases preserve a NUL-suffixed BLOB as a distinct identity.

[test, in progress] The normal saved-phone-chat route now creates a fresh scoped Conversation per
request, restores its admitted snapshot and revision, and gives that revision to the ACK-gated save.
The adapter requires an explicit pre-generation revision. A separate review found that reclassifying
an old source during generation could leak a draft or prepared answer; synthetic tests reproduced
both. Saved-chat drafts are withheld for now. A further synthetic race showed that checking current
answer sources separately from old history also leaked a newly restricted source; the pre-disclosure
check now validates both in one Store read snapshot. Eight positive/negative object, evidence,
passage and claim cases passed. The server now reruns a saved answer's disclosure validator before
initial send, retry/resume and committed send; saved-history list/open pages also revalidate their
displayed revisions in one snapshot. Focused replay tests passed and failed when server checks were
removed. Review found and a focused test reproduced an eviction race while validation was suspended;
reservation now happens first, and the regression passes. A final source pass found no actionable
defect in saved-chat/history replay. As an interim fail-closed measure, cached pages without an
explicit disclosure validator now refuse retry/resume; saved chat and history supply validators.
Focused tests cover both refusal and validated replay; a separate source pass found no actionable
defect in the interim. The current full Swift run passed 892 tests with the packaged-review fixture
enabled after rebuilding OpenCoreReview; logs /private/tmp/opencore-record-identity-full.log and
/private/tmp/opencore-review-current-build.log. Other read routes still need validators to
restore resume and to audit their initial-send race. Safe streaming, durable retry, a current build
and device acceptance remain. No real model or physical pairing was exercised by these tests.

[test, source, in progress] Review found Swift's canonical String equality collapsing two byte-distinct
typed IDs before the phone's admission check. Synthetic prepared-answer and saved-history tests
both reproduced disclosure before the fix. ID<Scope> now compares and hashes UTF-8 bytes, matching
SQLite's default BINARY identity. A standalone check, three integration regressions and the broader
Swift test suite passed. Separate source review found no actionable equality/hash/Codable defect.
Review separately found Evidence-mode link deduplication collapsed equivalent raw String IDs.
Two focused regressions failed before the link identity/dedup fix and passed afterward; a separate
source pass found no actionable defect. Phone record-list identity and pagination now use exact
UTF-8 bytes; the focused pagination regression failed before and passed after, and a separate source
pass found no actionable defect. The iPhone and Mac production builds passed at that checkpoint.
Other raw String-keyed collections remain outside this scoped fix. Apple String and
SQLite comparison references were checked 2026-11-01: https://developer.apple.com/documentation/swift/string
and https://www.sqlite.org/datatype3.html.
[source, 2026-11-01] Foundation's Base64 API and SwiftUI's unique list-identity guidance were
checked: https://developer.apple.com/documentation/foundation/data/base64encodedstring(options:)
and https://developer.apple.com/documentation/swiftui/displaying-data-in-lists.

[test, in progress] Review found a recovered page from one connection could survive pairing to
another. The phone now clears recovered content before every connection attempt, and clears pending
resume tokens when a new pairing code is used. A recovery epoch plus operation/session fences prevent
a late completion from repopulating a reset session. Focused tests failed before and passed after;
the independent re-review found no remaining actionable defect. A current iPhone rebuild remains.

[test, in progress] A new pairing code now replaces an existing phone's grant after validating the
code and persisting the new scope; code-free reconnect retains its existing grant. Failed validation
or persistence preserves the existing grant. The server cancels old-grant work and invalidates its
cached exchanges. An independent review found that delayed cleanup could remove a newer grant's
work; authority transitions now return the precise displaced grant, and cleanup targets only it.
Seven focused tests, including a delayed-cleanup fixture, passed; log
/private/tmp/opencore-grant-transition-final-tests.log. Separate source review found an idle stale
connection window; registration now precedes the current-grant fence and the follow-up review found
no remaining actionable issue in this scope. The full Swift suite passed 899 tests with the packaged
review fixture enabled; log /private/tmp/opencore-latest-full-suite.log. Fresh iPhone and Mac builds
succeeded with strict signatures. The iPhone build was installed and the installed app queried;
log /private/tmp/opencore-phone-latest-install.log. The Mac build is at
/private/tmp/opencore-review-dd/Build/Products/Debug/OpenCore.app. The matching Mac bundle is now
installed and remains closed; opening the new production build would run migrations
against its configured store. Real phone pairing and Face ID remain untested. No live store was
migrated or rebuilt during this checkpoint.

[source, test, in progress] The Mac pairing screen now displays each paired device's actual domain
ceiling and refreshes its device list after a successful Keychain update. Concurrent refreshes are
fenced against a newer refresh or stopped host. Source review found that changing the limit during
code issuance could mislabel the code; issuance now snapshots the scope/address, serializes requests,
and discards results from a stopped/restarted host. Review also found that Revoke silently did
nothing while the host was stopped; it is now disabled with an enable-first explanation. The Mac
build succeeded and separate source re-review found no remaining narrow issue; actual UI acceptance
is pending. Log /private/tmp/opencore-mac-pairing-revoke-build.log.

[measured, 2026-11-01] Owner questioned the storage drop. The pressure log measured 62.7 GiB free
on Oct 30 18:00 and 15.3 GiB at Nov 1 midnight; swap used rose from 4.8 to 10.2 GiB, which does
not explain the full drop. Current candidates include two shut-down simulator devices totaling
about 9.93 GiB and large SS temporary test/build copies; their data/rollback status is not cleared
for deletion and APFS shared blocks prevent adding reported folder sizes as exact recovery. About
3.84 GiB of the simulators' total was in undocumented poster stores. Removed
481 MiB of inactive, completed Xcode test products under the owner's existing cache approval.
At the owner's instruction, one shut-down iPhone simulator was erased; once APFS
accounting caught up, free space rose by about 7.3 GiB to 22.4 GiB. The iPad simulator was not erased.
SwiftPM's clean command also removed an inactive 572 MiB reported index cache; disk free rose about
451 MiB immediately afterward. The current OpenCore index is open and was left in place.
No APFS Data snapshots were listed.
[measured, test] When free space fell below 15 GiB, the obsolete /private/tmp/opencore-review-dd
build was removed. An intervening full test run failed its packaged-review fixture for that reason
(log /private/tmp/opencore-saved-ack-admission-full.log). After the simulator cleanup, the review
scheme was rebuilt and the full suite including that fixture passed (logs above).

[source, 2026-11-01] SQLite documents distinct TEXT/BLOB comparison semantics and indexed OR
lookups: https://www.sqlite.org/datatype3.html and https://www.sqlite.org/queryplanner.html.
Apple's current CryptoKit hash and Foundation sorted-key documentation was checked for the next
request-identity job: https://developer.apple.com/documentation/cryptokit/hashfunction/hash(data:)
and https://developer.apple.com/documentation/foundation/jsonencoder/outputformatting-swift.struct/sortedkeys.

[test, 2026-11-01] The phone chat atomic storage foundation is implemented but NOT app-wired.
The transaction saves a question, answer, receipt and trace together; deterministic ID from a random
request UUID retains the duplicate marker after conversation deletion. Exact grant/thread/scope and
turn payload are bound to the receipt; Mac edits or unlabelled turns refuse continuation, while a
judgement stays mutable. Four review findings reproduced before fixes. Eleven targeted tests and
eleven runtime mutation checks passed; a separate re-review found no further actionable defect.
Swift package and normal Mac builds passed, full suite passed 814 tests at that checkpoint, codemap 22 slices had
0 errors/warnings. Logs /private/tmp/opencore-history-store-focused.log,
/private/tmp/opencore-history-store-full-test.log and /private/tmp/opencore-history-store-mac-build.log.
Roadmap row 40c49a74-d54f-8160-8b02-c6f644ec4d3d completed as FOUNDATION ONLY. No schema migration,
phone access, device test or deployment was performed. Actual ACK, caller provenance and trace/source
admission are the future broker's responsibility, not established by this storage method.

[test, 2026-11-01] Scoped phone history read foundation is implemented but NOT app-wired. It uses
one SQLite read snapshot and validates current grant, scope, owned payload, object/claim/trace
admission and malformed NUL/BLOB links before pagination; titles derive from validated questions.
Review findings for cancellation and claim links reproduced before repair; separate re-review
found no remaining actionable production defect. Twenty-two focused history tests, seventeen
runtime mutations, Swift package/normal Mac builds, full suite 825 tests and codemap 0 errors/warnings
passed. Logs /private/tmp/opencore-history-read-focused.log, /private/tmp/opencore-history-read-full-test.log
and /private/tmp/opencore-history-read-mac-build.log. SQLite transaction/snapshot and Apple Dispatch
and Swift API docs plus current SDK were checked on 2026-11-01. Roadmap row
40c49a74-d54f-8102-9297-f2b4eb76e2f5 completed as FOUNDATION ONLY. Full source/verdict decoding,
model restore, broker/UI, durable retry recovery and physical-device tests remain.

[test, 2026-11-01] Companion server request fencing is complete in source: a request reserves its
identity before preparation, active replay acknowledgements retain tokens through cache eviction,
and old cleanup cannot erase a newer reservation. The original authenticated grant and session
are rechecked after receive and before handler entry. Synthetic peers reproduced duplicate work,
stale stop/re-pair requests and active-replay eviction; regressions now pass. Six runtime mutations
were caught, five concurrency repeats passed, separate review found no remaining actionable defect,
package and normal Mac builds passed, full suite passed 803 tests and codemap had 0 errors/warnings.
Logs: /private/tmp/opencore-concurrent-request-focused.log, /private/tmp/opencore-exchange-full-test.log,
/private/tmp/opencore-exchange-mac-build.log. Roadmap row 40c49a74-d54f-81be-ac3f-efa71f5619cc
completed. [design] The reservation is volatile: it does not provide durable exactly-once behavior
after restart, stop, expiry or eviction once no exchange remains active. Future phone writes need
durable operation identities. Latest Mac build is not installed.

[test, 2026-11-01] Receipt scope and SQLite text repair complete in source: unknown, malformed,
missing and nontext scope values fail closed; a genuinely empty list remains empty. UTF-8 text
bindings and reads retain embedded NUL; bind errors are reported. Regressions failed before repair;
eight independent runtime mutations were caught and restored byte-for-byte. Focused suite passed,
full Swift suite passed 797 tests at that checkpoint, package build and normal Mac build exit0, independent source
review found no actionable defect, codemap 22 slices 0 errors/warnings, sensitive scan exit0.
Tests use synthetic temporary stores. Logs: /private/tmp/opencore-phone-receipt-sqlite-focused.log,
/private/tmp/opencore-receipt-sqlite-full-test.log and /private/tmp/opencore-receipt-sqlite-mac-build.log.
Roadmap row 40c49a74-d54f-819a-9f3a-e11eb1125fa5 is completed. Current installed Mac predates this
repair; it was built but not deployed. Current phone pairing/Face ID remain unverified.

[source, 2026-11-01] SQLite documents undefined expression behavior for strings containing NUL:
the byte-preserving storage fix does not establish safe NUL search or indexing. Checked SQLite
column/binding documentation, Apple Swift String.withCString and the current macOS SDK.

[measured, earlier deployment2026-11-01] iPhone device build was rebuilt from the then-current
source: script/build_phone.sh --device exit0/BUILD SUCCEEDED, deep/strict codesign0, physical-device
install exit0/outcome success, postinstall app query0 confirms one matching app. Phone0.1.0(1).
Logs /private/tmp/opencore-phone-current-device-build.log and ...-current-install.json; private device
identity remains outside tracked files. Phone not launched; pairing/Face ID still unverified.
Mac0.2.0(2) was running, and source hashes then matched its staged build inputs (0 observed
differences), /private/tmp/opencore-current-both-provenance.json. The subsequent receipt repair above
has not been installed.
No product source changes/new tests/commit/push; full791-test baseline and open completion gaps below
remain. Device build has the expected no-AppIntents metadata-extraction warning.

[measured] OWNER REQUESTED WRAP-UP: “Dude finish up”. Latest tested Mac baseline installed and
launched with bash script/build_and_run.sh --verify, direct exit0; log
/private/tmp/opencore-wrapup-deploy.log, rollback
/private/tmp/OpenCore-app-backups/20261101T144740Z-87319/OpenCore.app. Read-only physical-phone app
query exit0 confirms com.gunndamental.OpenCorePhone0.1.0(1) installed; private device identity stays
outside tracked files, /private/tmp/opencore-wrapup-phone-apps.json. Phone was not reinstalled/launched.
[test] Latest full suite791, package/normal Mac builds0, separate review and sensitive/maps/diff0.
No build/mutation active; no commit/push. No live-store/control/hardware test or rebuild apply.
[design] Full app is NOT complete. Latest physical pairing answer remains “Not tried yet”. Phone
owner actions/operator controls, safe actual Mac screen review, copy-based recovery, full dual-era
MCP migration and held-out eval remain open in COMPLETION.md/PHONE.md. Installed CLI remains old;
Mac now includes the qualified legacy-preserving foundations, without modern advertisement changes.
[design] Lifecycle row40b49a74-d54f-8164-8235-db82acb61b4b returns to To Do; DESIGN ONLY, no product
source changed. Independent review suggests a smaller standalone C supervisor: child inherits0/1/2,
then supervisor closes its copies (no proxy/buffering). Exclusive exact-PID reaping/signals, checked
SIGCHLD disposition/mask and unblocked TERM before spawn, handler only sig_atomic_t flag, monotonic
fixed stop/reap budgets, never signal after reaped/ECHILD or on negative/group PIDs. Only trusted
helper normal exit0 means DIRECT child exit observed, not child health/exitcode0 or whole tree.
Await typed cleanup at discover/fetch/disconnect; preserve original errors plus unconfirmed cleanup.
NormalMac/CLI must deterministically package helper; no PATH/env/CWD fallback; thin review excluded.
Host drain/handle retirement semantics and lost ownership/error cleanup need settle before coding.
[measured] Current actual-source shutdown probe compile/exec0: owned TERM-ignoring1s timer peer;
shutdown returned0.000096708s with child running, still running100ms later, then natural exit0.
/private/tmp/opencore-stdio-shutdown-probe/original.json. No raw signals or force cleanup.
[test] Throwaway packaging probes ONLY: fresh SwiftPM C executable test dependency built/runs,1test0;
XcodeGen2.45.4 native tool embed/codeSign/copy executables generated and built0, embedded helper
exists and deep/strict codesign0; no launch. /private/tmp/opencore-supervisor-packaging-probe/.
Test code bundle observed at build Products/Debug/FixtureTests.xctest (main executable is SwiftPM's
system testing helper), so future tests can explicitly supply sibling just-built artifact via marker
Bundle. No production helper added; no architecture implementation accepted. Next session should
choose the next narrow authorized completion job from current gaps, without continuing the old proxy.

## Accepted job history

[test] Client stdin writer completed:791 full tests (113+56+60+41+25+112+363+21),88 focused,
16 writer/6 reader runtime faults and three repeated gate cases, exact restoration, final separate
source/fixture review, package/normal Mac builds0, full22-slice codemap0errors/warnings, direct
sensitive/diff0. Proof verification/2026-11-01-stdio-writer.md. Two full-run fixture failures are
preserved; GCD-backed waits/paused callbacks/fault-release coordinators retain original reverse-call
1s/readiness3s bounds. Controlled partial deadline uses actual progress/queue readiness plus independent
real5s watchdog. Current restored writer SHA7d10f1b48e94047a96b1c9c9434c79a0201eba821f0f97a2e9d1e640b64d20f2,
endpoint2f3c97045024b02487be350c1176875183410aa8093db607f9c21ef43fd05480,
transport7ed65cc19a95e06054f91e2801f37a937f67c1e69f038f161179efde0dd0e654.
[measured] Final actual-source1MiB peer-backpressure probe: timeout0.1 returns0.107323083s (old2.298375042s),
cancellation0.000943125s after cancel (old2.182399083s), both exit0. All3 native probes recompiled0;
configured default-SIGPIPE process survived EPIPE32/exit0, unprotected negative control exit-13;
exact old FD slot reused for sentinel, resumed pump/stale endpoint wrote zero bytes, exit0.
[source] Owned endpoint verifies O_NONBLOCK/per-FD NOSIGPIPE/CLOEXEC before launch; fresh pointer/FD
per syscall, errno inside borrowed-buffer closure, one close without retry. FIFO actor owns full
retained frame accounting/continuations; queued and zero-byte cancellation/expiry local, interrupted
partial frames close shared transport, final accepted byte classified first. Every shutdown awaits
same writer close; .closed wording no longer claims server exit. Chosen128frames/16MiB,16KiB chunks,
5ms polling; no total-memory/encoding/scheduler/whole-exchange/peer-ack guarantee.
[design] Continue full dual-era MCP phase one narrow job at a time; lifecycle High
40b49a74-d54f-8164-8235-db82acb61b4b remains open: TERM unconfirmed, Process.isRunning/raw SIGKILL
not PID ownership proof; no force-kill code added. Modern metadata/discovery/cancellation/batches/client
HTTP headers remain pending. Current MCP parent stays In Progress, no modern advertisement.
At writer qualification no install/launch/commit/push occurred; later owner wrap-up deployed the
qualified Mac baseline as recorded above. Installed CLI remains old. Pairing latest “Not tried yet.” No live store/config/service/
control/monitor/USB/device tests. Mac build retains5 tracked pre-existing HardwareUSBView deprecations.
[test] Stdio reply ownership completed:777 restored full tests (113+56+60+41+25+112+349+21),23 focused,
25 runtime mutations, exact restored StdioReplyInbox SHA
820d026a4dd001c880bcce0b0ed427b1ab0358c321554648a92561918370728f and StdioTransport SHA
72d38da93a26074647c06b639f6257241ab1dbdd6ed51aee895a699f7efdeec4. Final separate source/fixture
review, package/normal Mac builds0, full22-slice codemap0error/warnings, direct sensitive/diff0.
Original actual reverse2→1 pipe repro failed second call1sec; current fixtures green. Proof
verification/2026-11-01-stdio-ownership.md, completed40b49a74-d54f-815f-bc57-fc1a9b72934d.
[source] StdioReplyInbox registrations own exact IDs/token/whole-chunk receipt floor/deadline;
parse outside state lock, owner-fenced publication, EOF/expired eligible backlog, stop/cancel fences,
selected count/wire-byte caps, truthful response-shape validation. Post-encoding mutex-protected
health/cancel admission prevents unadmitted native bytes; encode refusal isolated from other owners.
Native writes still synchronous. Current SDK27/Apple docs checked Nov1: Process/FileHandle Sendable,
throwing write/close; TERM attached only after launch/outside mutex, fatal stdout drains/discards to
EOF. TERM is not observed exit, throwing write is not SIGPIPE proof. Mac build has5 existing C-string
warnings tracked40b49a74-d54f-818c-a886-c16af3f1c11f. No installs/launches/commit/push; Mac preference
build/CLI still old. Pairing Not tried yet. No live services/store/config/control/device tests.
[test] Exact wire IDs completed:760 full tests (113+56+60+41+25+112+332+21),56 targeted,17 runtime
mutations with exact four-file restored SHA values, final separate source review, package and normal
Mac builds0, full22-slice codemap0errors/0warnings, direct sensitive/diff0. Mac build emitted5 existing
fixed-buffer String(cString:) deprecations, tracked for later hardening in
40b49a74-d54f-818c-a886-c16af3f1c11f; no live hardware tests. No installs/launches/commit/push.
[measured] Current-source raw probe /private/tmp/opencore-wire-id-probe now refuses fractional
1.0000000000000001 (-32600) and echoes9007199254740993 and1e1000 exactly. The older probe at
/private/tmp/opencore-rpc-id-probe is historical and must not be recompiled/rerun as current proof.
[source] New sealed RPCID/RPCIntegerToken and RPCWireObject strict grammar avoid ID Double/Decimal
conversion, numeric ceilings or exponent expansion; string equality/hash uses decoded UTF8, missing/
null remain distinct. Strict whole-original syntax precedes ID semantics; early duplicate rejection,
fixed-length masking and preallocation bound avoid resource faults. RPCRequest.decode(Data) and
RPCResponse.serialized() replace lossy Foundation ID routes at server/playground/fixtures; both
transport matchers/outgoing generated integers use exact IDs. Ordinary payload numeric representation
is unchanged. No modern protocol advertisement changed. Proof:
verification/2026-11-01-exact-rpc-ids.md; completed40b49a74-d54f-8198-991a-da157dfde02a.
[test] Decoded-envelope structure foundation completed:7 named matrix tests,11 runtime mutations
with restored Messages SHA e98f6db4932c3ccb49a4234d781dd3307a49ca57cf70183b92b64cf673a28276,745 full
tests (113+56+60+41+25+112+317+21), final separate source review, package/normal Mac builds, full22-
slice codemap0errors/0warnings and direct sensitive/diff checks0. Mac has no warning:/error: matches.
Proof verification/2026-11-01-rpc-request-envelope.md; completed40b49a74-d54f-81b7-b9e7-ed26ab43ca6f.
[measured] This foundation validates decoded structure only: current-source fixture probe compiled
at /private/tmp/opencore-rpc-id-probe confirms1.0000000000000001→1 and9007199254740993→9007199254740992.
It does NOT close exact numeric wire-ID fidelity; that is the next active job above. No new ceiling
introduced. Current run loop still drops decode failures; complete wire error replies/cancellation-
aware stdio run loop remain atomic dual-era integration work.
[source] Research checked2026-11-01: all3 advertised legacy revisions share string/integer IDs,
object params, null invalid/request notification distinction. March26 additionally MUST receive
batches, but current server does not despite advertising it: row40b49a74-d54f-81f2-9705-f7b8c79f1e9a
requires implement/qualify or remove advertisement later. Full modern request metadata missing
requires-32602, unsupported version-32022 data supported/requested; serverInfo is SHOULD in each
RESULT's _meta, not an error metadata/resultType requirement. Notifications' metadata is optional.
Parent3b649a74-d54f-8103-aeb3-dd362d2ec9c3 stays In Progress; see COMPLETION.md.
[test] Explicit presentation imports completed in eight Mac files: separate source review, normal
Mac build-only exit0 with no warning:/error: matches, full22-slice codemap0errors/0warnings, sensitive/
diff checks0. No runtime behavior change/new tests/installation. Proof:
verification/2026-11-01-presentation-imports.md; completed row40b49a74-d54f-81b4-bc8d-f6c5c377bd29.
[test] HTTP response/cancellation foundation completed:738 full tests (113+56+60+41+25+112+310+21),
23 targeted HTTP tests,21 runtime mutations with four restored SHA values, final separate source
review, package/normal Mac builds and maps/sensitive/diff checks exit0. Review found/fixed overlapping
initialize overwrite and a fixture timing assumption. No listener/services/store/config tests. HTTP
non2xx details/status, correlation, UTF-8/SSE, byte bounds, total deadline and owned cancellation now
qualified by isolated fixtures. No protocol advertisement changed. No build/mutation active.
Proof: verification/2026-11-01-http-transport.md. Completed row40b49a74-d54f-8133-b27c-dd1a5b7a0e24.
[source] Full modern metadata/header mirroring/schema/era migration remains unfinished; official
HTTP spec requires MCP-Protocol-Version/body match, Mcp-Method/Mcp-Name, x-mcp-header validation and
Mcp-Param mirroring/encoding, -32020 mismatch and -32022 supported/requested details. See COMPLETION.md.
Defer deployment until complete MCP phase; installed Mac remains preference build and CLI/MCP old.
[test] RPC error foundation completed:715 full tests, five new matrix/pipe tests,16 runtime mutations
with four restored SHA-256 values, final separate source review, normal Mac build and map/sensitive/
diff checks passed. No build or mutation is active. CoreJSONRPC Messages/StdioTransport/HTTPTransport/
MCPTransport and new CoreGraph RPCErrorDataTests retain decoded optional details, including null,
and omit them from automatic descriptions. HTTP mapper is tested, not actual session behavior.
Deployment deferred until complete MCP phase; installed Mac remains preference-persistence build.
Details: verification/2026-11-01-rpc-error-data.md. Foundation row40b49a74-d54f-81ed-a6df-c1df407ba8d0.
[test] MCP startup preference job completed:710 full tests,33 targeted tests,19 runtime mutations,
final separate source review, both Mac build-only schemes, maps/sensitive/diff checks and authorized
Mac deployment passed. App launched; previous bundle retained at
/private/tmp/OpenCore-app-backups/20261101T093604Z-8579/OpenCore.app. CLI/MCP executable remains old.
No build or mutation is active. Details: verification/2026-11-01-mcp-preference.md.
[source] Requested defaults, observed configuration and write confirmation are separate. A one-shot
strict initial observation restores saved authorization without a repeat write; unknown first read,
attempted changes/failures/invalidation cannot reinitialize it. Current-file revalidation guards new
playground servers and copying; generated clients contain no unsafe override. Existing server
permissions/explicit arguments remain until owner reconnects/removes overrides. Actual UI/CLI-process
acceptance is unverified. These new view configuration-read tasks must be injected/gated before
real isolated screen review, alongside existing credential/model/operator tasks.
[test] Entity navigation job completed:692 restored full tests,11 runtime mutations, separate
review and both Mac build-only schemes passed. Four app wiring findings were fixed and re-reviewed;
final normal rebuild and authorized deployment exit0, app launched. Backup:
/private/tmp/OpenCore-app-backups/20261101T090645Z-93902/OpenCore.app. Helper behavior is tested;
app glue is source/build evidence. Actual screen acceptance is unverified. Details:
verification/2026-11-01-entity-navigation.md.
[source] Existing manual selection cancellation/nil-dossier behavior is separately tracked in
40b49a74-d54f-8180-9c25-d69583a28d70. No live UI/store tests. Model/view-task isolation is later.
[test] Settings/theme extraction is complete: explicit CorePresentation defaults/effects,
environment card/bar/badge modifiers, all42 preserved keys/defaults,683 full tests, nine mutations,
separate review and both Mac builds passed. First Mac build caught a type-inference cycle, fixed
with an explicit shared type. Authorized Mac deployment exit0 and launched; backup
/private/tmp/OpenCore-app-backups/20261101T084650Z-85152/OpenCore.app. Details:
verification/2026-11-01-settings-ownership.md.
[source] SharedConfig save errors are now surfaced as described above; real-view model/task isolation remains.
No actual view rendered; production environment fallback and model/view-task isolation remain.

[test] Bootstrap row 40b49a74-d54f-81a5-bc7f-cf12172d1697 is complete. Both app schemes built;
actual signed/background identity/copy-root entitlements and absent app/controller symbols checked.
Packaged fixture probe passed standalone/full/repeat: explicit immutable copy, one object, unchanged
bytes/no sidecars, missing args refused. Full677 tests with probe enabled,15 mutations and independent
reviews passed. Normal Mac deployment /private/tmp/opencore-review-bootstrap-deploy.log exit0 and
launched. CLI/MCP remains old. No real copy or screen tested. Details:
verification/2026-11-01-review-bootstrap.md.

[source] Later real-view reuse also needs AppModel injection BEFORE construction, no global didSet
callbacks, and suppression of view-task operators/credentials/models/sync/Spotlight/notifications.
Root/MenuBar currently touch hardware/control globals. Thin Foundation bootstrap intentionally
compiles only its main and links CoreStore/CoreTelemetry, not production app UI/controller types.

## Current delivered state

[source] Native read-only iPhone app, authenticated Mac owner broker, both coordinated icons and
opt-in Mac pairing UI exist. Phone imports only CoreCompanion; all engine/store work stays on Mac.
MCP is separate, model-facing and read-only. No phone store actions/operator routes implemented yet.
[measured] Phone 0.1.0 (1) installed and verified in device inventory. Matching Mac updates installed
and launched via authorized --verify. Older bundles remain under /private/tmp/OpenCore-app-backups.
Normal scheduled sync may run after app launch; this was not used as a live-store test.
[source] Latest owner reply is Not tried yet, superseding Connected successfully. Physical pairing,
Face ID, tailnet/revoke/sleep behavior and real-model parity remain unverified. Agent enabled no real
listener and did not launch/pair the phone. Initial owned simulator review was unpaired only.

## Completed in the working tree

- [test] Transactional migration DDL/ledger and newer-schema rejection, including lock recheck.
  Unknown stored domains decode restricted. No shipped migration changed or schema bump added.
- [test] Shared claim admission requires admitted subject/target/support. Unsafe MCP UI requires
  named confirmation/reconnect. Admission changes clear chat model/anchor context.
- [test] Owner domain selection/personal wording work across Mac/phone/engine; model/system callers
  remain project/public. Raw private questions and explicit selections cannot enable cloud fallback.
  Timed follow-ups keep their subject. No held-out accuracy measurement claimed.
- [test] Phone crypto, grant/replay/lifecycle cancellation, before-page filtering, exact passages and
  trace/ACK/resume contracts. Pairings have fresh grant IDs; limited phones see only current-grant
  owned receipts. No software Secure Enclave fallback in simulator.
- [test] System answers use real per-claim sources, original reading authority, caveats and one
  retrieval/receipt. Exact local/chat passage traces retain real scores. Shortcut claims are qualified.
- [test] JARVIS uses deterministic timestamped complete/partial/failed operator snapshots, no invented
  floor IDs/authority/receipts. Unknown Git status is not clean; row/full stale reads are rejected.
  Inventory counts are materialized. Scan budgets are cooperative between filesystem operations.
- [source] Native Settings reuses model/preferences, failure/progress display and a matching data-valued
  workspace window. Actual menu, keyboard, focus and close/reopen behavior is not measured.
- [test] Optional Gemini key is only in auth header, invalid tokens rejected. Existing opt-in,
  admission, model/body/timeout remain. Current Google docs: 2.5 Flash has no announced shutdown,
  but access is limited to past users. No account/service acceptance measured.
- [test] Review bootstrap: separate identity/entry, production review-argument refusal before
  AppModel, private ordinary nlink1/self-contained copy admission and immutable read-only URI.
  Typed creator owns a new snapshot, closes SQLite before owned-SHM cleanup, chmod0400/fsync;
  source main/WAL preserved. Both backup kinds reject preexisting auxiliaries. No migration.
- [test] Settings/theme state moved to CorePresentation with explicit suite/effects and no
  restoration callbacks. Production app bridge preserves behavior. Glass card/bar/badge modifiers
  resolve environment state; all42 keys/defaults preserved. Complete review-runtime isolation and
  configuration-save error handling are separate jobs.
- [test] Typed explicit entity navigation rejects missing/mismatched targets and cancelled/stale
  outcomes. [source] Chip separates initiation from real-read completion; request/history ownership,
  list-error ownership and refresh tab behavior were repaired and separately reviewed. No passages
  are loaded or claimed by the dossier read. Manual selection qualification remains separate.
- [test] Stdio retains only lines read by the deadline, including buffered replies after waiter
  scheduling delay. Cancellation precedes consumption. Per-stream read locks serialize bytes/EOF
  independently of the state lock. Controlled fixtures prove overlap and closure behavior; original
  full-run timing cause is unestablished. This is not the pending full protocol revision migration.
- [test] Notes uses escaped versioned framing, validated accounting/dates, exact field shape,
  duplicate rejection and conservative unread handling. Whole-second overlap preserves fractional
  start-boundary edits. Per-event and overall deadlines/errors remain distinct. Protected notes stay
  unread. Actual synthetic AppleScript handlers/ISO coercion passed; real Notes/TCC is unverified.
  BoundedProcess now waits for both output drains within its original deadline, polls cancellation
  after parent exit and marks incomplete pipes timed out. Only its owned direct child is terminated.
- [test] Cloud accounting separates submission, HTTP, application response and decode; counts distinct
  represented floor IDs. Independent request audits persist with exact provenance before phone ACK,
  including history-disabled/cancelled calls. They are not completed answers or deliveries. Exact
  device/grant ownership protects limited access. Mac failure sink survives a lost phone consumer.
  Completed deterministic warnings can be delivered; empty fallback clears prior partial drafts.
  Final prose author stays separate from attempts. Shared disclosures avoid zero-egress claims;
  MCP traces withhold raw owner questions/unlabelled notes. No schema migration added.

## Verification

[test, 2026-11-01] Latest full suite: exit0,715 tests
(113+56+60+41+25+112+287+21), packaged bootstrap probe enabled and passed. Sixteen RPC error mutations failed named runtime expectations and restored four source SHA-256
values; source review and normal Mac build passed. The previous MCP preference job passed710 tests,
19 mutations, both Mac builds and authorized deployment. It repaired stale-file/consumer and unknown
initial-observation issues. Sensitive0; targeted maps0 errors/warnings; diff check0. Earlier
entity proof:692 tests,11 mutations,four app wiring repairs re-reviewed. Settings proof:683 tests,
nine mutations,all42 keys/defaults preserved. Bootstrap proof:677 tests,15 mutations,signed identity/
entitlements and fixture execution. Actual UI acceptance remains unverified; details in verification
artifacts. November1 calendar failure was fixed with explicit UTC fixtures; product logic unchanged.
[measured] Earlier phone simulator navigation, locked claims, dark/largest text review and signed
phone installation are recorded in PHONE.md. Actual scrolling gesture and paired screens not tested.
[source] Apple APIs checked against current reference and Xcode 27 SDK on 2026-10-31, linked in
ARCHITECTURE/COMPLETION. SDK compilation is not live API/hardware qualification.

## Remaining / boundaries

- [design] Real Notes acceptance; actual Mac model/settings/view-task isolation and screen review; actual Timeline async
  publication race; native Settings runtime acceptance. Legacy Corpus/Entities startup issue is
  already generation-aware. Do not redo it from old handoff titles.
- [design] Gemini/operator late-Stop/dry-run/scan safety, fresh read-only copy/rehearsal, full dual-era
  MCP 2026-07-28 client/server, menu/system parity, phone actions/operator views and held-out eval.
- [source] Local Hub needs admit_control for desktop_type/desktop_press, Trash/Erase policy coverage,
  and token removal from unauthenticated bootstrap. Report only; never edit that repo here.
- [source] Actual installed Mac entitlements were verified: Automation/Calendar true, sandbox false.
  Stale ignored Generated entitlements are not evidence of a packaging failure. Notes/TCC unknown.
- [source] Formal read/change/receipt choices and Mac owner screen review were not separately confirmed
  beyond the full-fidelity/build instruction; pairing UI explicitly grants read scope. No phone writes.
  No remote wake, push, persistent offline evidence cache or live hardware/control qualification.
- [source] Public history contains old private terms; history rewrite is the owner's decision.

## Working set and roadmap

[source] CoreCompanion/Host and OpenCorePhone are new; OwnerReads, ClaimAdmission, migration safety,
ConversationAdmissionScope, AnswerGrounding, GeminiRequest/GenerationAttempt, ReceiptOutbound,
OperatorSnapshotRead and their regression files are new. ReviewSnapshotPolicy, OpenCoreReviewMain, ReviewBootstrapTests, NotesReplyTests and StdioReadDeadlineTests are new; AppleNotesConnector, BoundedProcess/tests, StdioTransport, Store/Database snapshot helpers, Mac project/build selector and TimeAwareAnswerTests calendar fixture are modified. Mac AppModel/Settings/Chat/Intent/JARVIS/
operator/Home/receipts/windowing surfaces, CoreReason, CoreSearch, CoreStore and MCP/CLI presentation,
build scripts, docs and affected maps are modified. Preserve all dirty work.
[source] Notion main brief: 40b49a74-d54f-81ae-8128-d4525f62872b. Roadmap source:
collection://546d4b56-a91a-4324-92e7-738c9637d8d0. Completed narrow rows: owner scope
40b49a74-d54f-81c6-a539-c07084d5e61e; grounding 40b49a74-d54f-81b5-b06c-d7e14f3ec13e;
snapshots 40b49a74-d54f-8118-ac5e-e68ece4180e8; auth 40b49a74-d54f-81fc-b759-f08e5516133f;
cloud audits 40b49a74-d54f-8135-936c-c74b639223c8. Native Settings row
40b49a74-d54f-8134-9e1a-dcd1a9e372ae remains In Progress for runtime acceptance.
Notes row 40a49a74-d54f-81af-a8f5-cc4de3befa3b has test evidence, remains In Progress for real-library
acceptance. Disposable phone build/staging and generated indexes were removed to recover disk space;
phone remains installed. Source/artwork, verification logs and Mac rollback bundles remain. Stdio
row 40b49a74-d54f-81c3-a750-dd1e98e978bd is Completed for the controlled deadline/ordering repair.
[measured] Latest disk check16GiB free with8GiB swap. Guards refused earlier builds without reserve. Owned SDK/index/package
intermediates were removed, Products/logs retained.304 source-identified UUID fixture dirs born
within the exact final full-run window were removed,246.2MiB recovered. No owner data/backups/history
removed. Recheck disk before large writes; package caches/intermediates were regenerated for the latest builds.
Completed earlier single-run logs can bound cleanup of this session's known test-only UUID dirs;
never sweep older/unidentified outputs or real copies. Latest two completed single-run logs
(settings683 and entity692) bounded608 more source-defined UUID fixture directories;492.8MiB
recovered. Logs/products/rollback bundles and owner data remain. No tests were active during cleanup.

## Hard constraints

[source] Work on main; never commit/push/stash/reset/checkout without the owner's word. No trailers.
Public repo: no employer/colleague/private repo/machine/serial/tailnet/device identifiers in tracked
files. Run sensitive scan directly before any commit; read exit code without a pipe. Use codemap
find before grep, MACHINE-MAP before guesses, CLAUDE over stale AGENTS and brief.
[source] Never live-store tests, rebuild apply, live computer control, monitor/USB writes or Hub edits.
Real data only through store-copy skill and read-only snapshots; unique fixture stores for mutations.
Build outside Documents, one build at a time, Mac through build_and_run.sh --build-only. Existing
full-send authorization includes deployment; normal startup sync is not a test. No invented pass,
confidence or accuracy. Keep Notion/STATE current; label evidence. Separate reviews remain required.

[source] Latest narrow completion: MCP preference row40b49a74-d54f-815c-8823-c69adaebbc1e.
CoreStore/SharedConfig and CorePresentation/AppSettings, Mac bridge/SettingsView/MCPSourcesView are
modified; SharedConfigWriteTests and MCPPreferencePersistenceTests are new. EntityView and typed
EntityNavigationRead/tests were added in the prior job. Keep all unrelated dirty work. Source-identified
UUID cleanup for the exact completed710-test log removed304 fixture directories/245.5MiB; logs,
products, rollback bundles and owner data remain. No tests were active during cleanup.
