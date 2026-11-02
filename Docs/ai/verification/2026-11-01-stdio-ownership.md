# Stdio reply ownership

[test, 2026-11-01] Repaired concurrent stdio reply routing with777 restored full tests,23 focused
tests,25 runtime mutations, separate adversarial source/fixture review, package and normal Mac builds,
full codemap, direct sensitive and diff checks. No protocol advertisement, install, launch, commit
or push. This qualifies reply ownership, not bounded stdin writes or confirmed child exit.

## Failure and behavior

[test] The original actual sh-pipe regression reads requests1/2, then returns replies2/1. First call
returned correctly; second timed out1sec, exit1 in `/private/tmp/opencore-stdio-ownership-repro.log`.
[source] Reentrant actor calls each consumed a shared FIFO and discarded another owner's ID. The
new `StdioReplyInbox` registers exact ID, token, receipt floor and deadline before writing, and keeps
at most one reply for each owner. Other callers cannot consume/drop it. Unregister/take check the
registration identity; stale, duplicate, unknown and late frames are not retained. Actual reversed
pipe regression now passes, as do cancellation/local encode-refusal/late stale-frame pipe cases.

[source] Receipt generation/time is stamped for an entire appended chunk before any frame parsing.
Parsing one frame occurs outside the state mutex, under stdout read-order protection. Publication
rechecks current ownership/floor/deadline; stop cannot publish an unfinished parse. An eligible finite
already-received chunk remains eligible while parsing after clock expiry, and cached on-time replies
survive natural EOF. The floor excludes already-appended chunks; it is not general replay protection
for bytes still in the kernel or an incomplete frame. Buffer compaction occurs once per chunk.

[source] Chosen limits:128 active requests,16MiB retained reply wire bytes, and generic FIFO1024
frames/16MiB. Single-line limit remains8MiB. These are application budgets, not protocol maxima or
total memory guarantees. Byte charges remain until take/unregister; terminal faults clear cached
state, fail every waiter and prevent future admission. Native cleanup is requested outside the
state mutex; fatal stdout continues draining/discarding to EOF. TERM does not establish exit.

[source] Matched IDs must carry actual JSON-RPC response envelopes, with exactly result/error and
proper error shape. Requests reject invalid timeouts, pre-cancelled work and closed transports.
After encoding, mutex-protected health/cancellation admission precedes native I/O; later races are
already-committed synchronous writes. Pre-I/O encoding refusals affect that owner only. A native
stream write failure closes the shared stream because a partial frame cannot be assumed recoverable.
Throwing FileHandle write/close replaces legacy forms; write remains synchronous.

## Tests and separate review

[test]17 new named `StdioOwnershipTests` cover real reversed/cancelled/stale/encode-refusal pipes,
owner deadlines and token/floor/first-result accounting, small injected byte/count limits, clear with
a charged cache, same-chunk timestamp/registration races, parsing cancellation/replacement and stop,
cached EOF/expiry, pre-cancelled routed backlog, terminal fault notification/draining, malformed
response matrices, invalid/closed calls and zero native bytes after cancellation/EOF during paused
encoding. Existing generic reader callback ordering/deadline/cancel/EOF tests still pass.23 focused
tests are in `/private/tmp/opencore-stdio-ownership-acceptance.log`.

[test] Separate review drove outside-mutex parsing, whole-chunk stamping, per-owner eligibility,
post-encoding admission and an actual waiter-inspection barrier rather than a sleep-only assumption.
The first expanded fixture compile hit Swift's noasync semaphore rule; a synchronous fixture helper
resolved it. Subsequent focused runs passed. Final source review had no remaining actionable scoped
finding and ran no execution. Original red failure and every repair remain recorded in the logs.

[test]25 mutations each exited1 with runtime expectation failures, not compile failures: owner
deadline/floor, first-result/consumed state, take/unregister tokens and byte charges, active/count/byte
caps, clear, routing enabled, chunk generation/time, eligible parsing, parsing under mutex, pre-I/O
health/cancellation, routed buffered cancellation, response version/shape/code, encode isolation,
generic tiny-line count, and stop publication. Driver `/private/tmp/opencore-stdio-ownership-mutations.py`;
aggregate `/private/tmp/opencore-stdio-ownership-mutations.log`. Both files restored exact SHA-256:

| File | SHA-256 |
|---|---|
| StdioReplyInbox.swift | `820d026a4dd001c880bcce0b0ed427b1ab0358c321554648a92561918370728f` |
| StdioTransport.swift | `72d38da93a26074647c06b639f6257241ab1dbdd6ed51aee895a699f7efdeec4` |

[test] Ran/read sequential package build, full suite with
`OPENCORE_GEMINI_FALLBACK=0 OPENCORE_RUN_REVIEW_BOOTSTRAP=1`, then normal Mac build-only, all outside
Documents. All exited0. Full totals113+56+60+41+25+112+349+21=777, including packaged immutable-copy
review fixture. Logs `/private/tmp/opencore-stdio-ownership-restored-build.log`, `…-suite.log`, `…-mac.log`;
results JSON `/private/tmp/opencore-stdio-ownership-restored-results.json`. Mac BUILD SUCCEEDED with
five pre-existing C-string deprecations (separate row40b49a74-d54f-818c-a886-c16af3f1c11f). Full22-slice
codemap check0 errors/0 warnings, direct sensitive scan0, diff check0. Fixtures use owned pipes/minimal
child environments; no live store/config/service/listener, physical control or device tests.

## API evidence and remaining boundary

[source, checked2026-11-01] Current MacOSX27 SDK NSTask/NSFileHandle declarations mark
[Process](https://developer.apple.com/documentation/foundation/process) and FileHandle Sendable.
The child callback is attached after successful launch. Apple documents
[terminate](https://developer.apple.com/documentation/foundation/process/terminate()) as SIGTERM;
it can be ignored, and prelaunch termination is invalid. Capturing an owned Process does not prove
exit or callback cleanup. SDK/current docs confirm throwing
[write(contentsOf:)](https://developer.apple.com/documentation/foundation/filehandle/write(contentsof:))
and [close()](https://developer.apple.com/documentation/foundation/filehandle/close()); writes are
synchronous, and close is not a concurrent/idempotent protocol supplied by Sendability.

[source] Synchronous stdin backpressure, partial-frame cancellation, SIGPIPE behavior and bounded
exit escalation remain unqualified. The throwing API alone is not proof of SIGPIPE suppression.
Row40b49a74-d54f-8108-995b-e6d7a00d74ee is the next narrow job before full protocol acceptance. Do not
claim a whole-exchange stdio deadline or confirmed hostile-child cleanup from this reply-routing job.

[source, subsequent2026-11-01] The later [client stdin writer](2026-11-01-stdio-writer.md) qualifies
bounded nonblocking owned writes, SIGPIPE suppression and partial-frame cancellation separately.
The original777-test evidence/hashes above describe this earlier ownership job. Confirmed child
exit remains a separate High lifecycle row; neither job claims a whole-exchange deadline.
