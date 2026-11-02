# Nonblocking stdio stdin writer

[test, 2026-11-01] Accepted with791 full tests,88 focused transport tests,16 writer and6 reader
runtime fault checks, separate adversarial source/fixture review, package/normal Mac builds and
map/sensitive/diff checks. Three affected writer cases were repeated after the final gate repair.
This qualifies client stdin writes; synchronous JSON encoding, wall-clock reply eligibility and
confirmed child exit remain separate. No deployment at qualification; later wrap-up below.
No protocol advertisement, live service/store/config, hardware/device control, commit or push.

## Failure and measured behavior

[measured] An isolated probe compiled actual CoreJSONRPC sources, launched only its own `/bin/sh`
with a minimal environment, and submitted a1MiB fixture while the peer held stdin open and slept2s.
The old synchronous write returned a0.1s timeout after2.298375042s and cancellation after2.182399083s.
With the integrated writer, the same probe returned timeout after0.100483208s and cancellation after
0.0005375s. Both new executions exited0. These are fixture measurements, not universal latency bounds.
Artifacts `/private/tmp/opencore-stdio-backpressure-probe/*-nonblocking.json`; latest recompile returned0.107323083s and0.000943125s; all compile/execution exits0.

[source] `StdioPipeEndpoint` exclusively owns a newly created pipe's write FileHandle. Before child
launch/publication it preserves existing flags, enables and verifies O_NONBLOCK, per-descriptor
F_SETNOSIGPIPE and FD_CLOEXEC. Each bounded native write and close use the same ownership mutex.
The borrowed pointer and fresh descriptor never cross await; errno is captured inside the buffer
closure immediately after write. Close withdraws the handle before closing it once, without retry.
FIFO type checks validate kind; they do not prove ownership of arbitrary borrowed descriptors.

[source] `StdioPipeWriter` owns a single FIFO pump, continuations and byte/count accounting. Queued
and active zero-byte cancellation/expiry affect only that owner. Once an incomplete frame has accepted
bytes, interruption closes the shared stream and refuses followers. Positive progress is applied
before classifying cancellation: a completely accepted final frame keeps framing usable. Native
failure notifies the reader; reader admission refusal preserves eligible cached replies at EOF.
Cancellation handlers mark a synchronized flag and request an actor turn. No raw native close or
cached descriptor is used after suspension. All shutdown callers join one awaited close operation.

[design] Chosen budgets:128 retained frames/16MiB full retained frame bytes,16KiB per syscall and5ms
retry polling. Notifications get a15s write budget; request write deadline starts before encoding.
These are application choices, not protocol maxima, total-memory bounds, peer acknowledgements or
scheduler latency guarantees. Encoding is synchronous and is not preempted by this change.

## Fixture evidence

[test] Direct fixtures cover nonblocking/no-signal/close-on-exec flags, native two-byte chunk offsets,
EINTR/EAGAIN and short progress, actual concurrent96KiB FIFO frames without interleaving, independent
frame/byte limits, retained-byte release, pre-enqueue cancellation/expiry, active zero-byte timeout,
queued cancellation/timeout behind observed pipe pressure, partial-frame cancellation/timeout,
final-byte cancellation, EOF cache preservation and concurrent transport shutdown. Separate review
found and corrected errno-capture placement and an untrue child-exit error description. First full791 run failed the new1s chunk fixture and200ms partial setup fixture under parallel load.
The partial-deadline fixture now advances an injected monotonic clock only after actual progress and
queue readiness, and readiness waits use Dispatch rather than blocking Swift cooperative threads.
Updated16 writer mutations all produce runtime failures with exact restoration. A second full run
failed only the prior reversed-reply fixture: first-read marker absent and1s calls expired. Existing
paused parse callbacks/readiness waits and the overlapping-read fixture driver also ran blocking
work in detached Swift tasks. They now use GCD-backed continuations, retaining original timeouts,
barriers and assertions.88 focused transport tests pass. This establishes the harness change; no
execution trace identifies the precise scheduler delay responsible for either full-run symptom.
Six representative reader mutations all failed at runtime and restored exactly. Separate review also
identified fault/release coordinators that depended on a Swift parent resuming while an actor was
paused. The final gate helpers now apply cancellation/EOF and release on GCD before resuming the
fixture; actual readiness Bool/assertions remain.88 focused tests pass with those changes. Three
affected writer mutation cases were repeated and failed at runtime with exact restoration.

[measured] Disposable default-SIGPIPE process with configured endpoint survived broken pipe with
EPIPE32/exit0; an unconfigured raw-write negative control exited-13. No global signal disposition
changes occur in production or the test runner. A separate owned descriptor-reuse probe reacquired
the exact closed descriptor slot for a sentinel file; a resumed pending pump and a stale endpoint
attempt wrote zero bytes. It exited0. Latest-source reruns confirm both results; all three probe compiles exited0.

## Restored acceptance

[test] Read all outputs and direct exit codes: package build0, full suite0, normal Mac build-only0.
The full suite totals113+56+60+41+25+112+363+21=791, including the packaged immutable-copy review
fixture.88 focused transport tests passed after the final harness change. Mac BUILD SUCCEEDED with
five existing HardwareUSBView String(cString:) deprecations, separately tracked in
40b49a74-d54f-818c-a886-c16af3f1c11f. No new app launch/installation or phone build was needed for
this Mac MCP client change. Pairing remains owner-unverified: latest answer “Not tried yet.”

[test]16 writer faults each exited1 with runtime expectation failures; six representative reader
faults prove the corrected GCD harness still detects receipt/time/eligibility/locking/publication
regressions. Three affected cancellation-gate cases were repeated after moving fault/release onto
GCD. A compile-only first prune mutation was corrected and excluded from the runtime count. Each
mutation restored exact SHA-256; parent reread every final log and verified current source hashes.

| Source | Restored SHA-256 |
|---|---|
| StdioPipeWriter.swift | `7d10f1b48e94047a96b1c9c9434c79a0201eba821f0f97a2e9d1e640b64d20f2` |
| StdioPipeEndpoint.swift | `2f3c97045024b02487be350c1176875183410aa8093db607f9c21ef43fd05480` |
| StdioTransport.swift | `7ed65cc19a95e06054f91e2801f37a937f67c1e69f038f161179efde0dd0e654` |

[test] Artifacts: `/private/tmp/opencore-stdio-writer-final-{build,suite,mac}.log` and
`…-final-results.json`; `…-final-mutations.py/.log`, `…-harness-mutations.py/.log`,
`…-gates-mutations.py/.log` and corresponding `…-mutations-results.json` files; final native probes
`…-final-probes.json`. Original failed full runs are preserved in `…-restored-suite.log` and
`…-second-full-suite.log`; no retry is represented as proof of their original success. Separate
source review ran no tests or probes. Full22-slice codemap check0 errors/0 warnings (3 notes),
direct sensitive scan0 and git diff check0. All work remains uncommitted on main.

## Current API contracts and remaining boundary

[source, checked2026-11-01] Current macOS27 SDK and Apple's pinned
[fcntl manual](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/fcntl.2#L246)
provide per-descriptor F_SETNOSIGPIPE/F_GETNOSIGPIPE and nonblocking flag operations. The current
[write contract](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/write.2#L145)
requires accounting for accepted bytes and EAGAIN/EINTR; signal suppression is not inferred from a
throwing Foundation method. Runtime broken-pipe probes establish the separately measured behavior.

[source] Foundation [terminate](https://developer.apple.com/documentation/foundation/process/terminate())
requests TERM, which a child can ignore. Process.isRunning does not prove the PID cannot be reaped
and reused before a raw kill. No raw kill was added. Confirmed safe bounded exit is separate High
row40b49a74-d54f-8164-8235-db82acb61b4b; descendants retaining inherited pipes remain a lifecycle
concern. The writer's closed-stream error describes transport closure rather than claiming exit.
MCP stays a read-only model channel. The full dual-era protocol migration remains incomplete.

[measured, owner-requested wrap-up2026-11-01] Qualified Mac baseline subsequently installed and
launched with --verify, direct exit0; /private/tmp/opencore-wrapup-deploy.log, rollback
/private/tmp/OpenCore-app-backups/20261101T144740Z-87319/OpenCore.app. Legacy protocol advertisement
unchanged. Read-only phone query0 confirms existing0.1.0(1); no phone install/launch or pairing test.
Full dual-era MCP/lifecycle implementation remains unfinished. No commit/push.
