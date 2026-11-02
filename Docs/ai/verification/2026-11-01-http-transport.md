# HTTP response and cancellation foundation

[test, 2026-11-01] The restored package build,738 full tests,23 targeted HTTP tests,21 runtime
mutations, normal Mac build, sensitive scan and diff check exited0 where success was expected.
Mutations each exited1 with runtime expectation failures; no compile failure counted as proof.
Separate adversarial source review found an overlapping-initialize race, now fixed and re-reviewed.
The full22-slice codemap check ends with0 errors/0 warnings after repairing stale index entries.

## Changed behavior

[source] `HTTPTransport` preserves recognized failed-HTTP RPC code/message/data and status together.
401 retains authorization discovery and403 stays an authorization refusal; neither exposes a protocol
error code to era negotiation. Unknown error bodies expose only a bounded diagnostic prefix through
explicit typed access. Automatic descriptions omit structured payloads and bodies.

[source] `HTTPResponseDecoder` validates JSON-RPC envelopes and response IDs. Unidentified error
responses are allowed only on failed HTTP exchanges, including notification preflight failure.
Successful responses require the requested ID. SSE parsing observes complete UTF-8 events, multiline
data, CR/LF/CRLF, one initial BOM, comments and preceding notifications. EOF does not dispatch an
incomplete event. Chosen consumed-byte limit is8MiB; diagnostics retain at most400 bytes by default.
These are application budgets, not measured process-memory limits or protocol maxima.

[source] `HTTPRequestExecution` uses a single completion winner across a monotonic deadline,
caller cancellation and worker completion. Synchronous task registration permits cancellation before
headers. Logical return does not wait for native acknowledgement; late workers cannot publish again.
Shutdown and cancellation affect owned requests, leaving caller-owned injected sessions usable.
Only complete successful initialize replies publish legacy session IDs. A concurrent initialize is
refused before issuing another POST, preventing an older response from replacing newer ownership.

[design] No protocol revision, method advertisement, grants or phone channel changed. Full dual-era
MCP migration remains a separate unfinished phase. Foundation deployment is deferred until that
phase is complete. Installed Mac remains the earlier preference-persistence build; CLI/MCP remains old.

## Regressions and proof

[test] New `HTTPTransportTests.swift` and `HTTPResponseDecoderTests.swift` have23 named tests with
parameter matrices. Sessions use an unsupported custom URL scheme with per-session URLProtocol;
losing the fixture seam fails rather than contacting a service. No listener, live store/config,
credential, real service or computer-control endpoint was exercised.

| Coverage | Evidence |
|---|---|
| Actual injected JSON/SSE loading,200/400/404 structured errors, null/scalar/object details | [test] `httpFixtureRoundTrip`, `httpRecognizedFailures` |
|401 challenge and403 cannot drive fallback; notification202/non202/preflight errors | [test] `httpAuthorizationIsNotNegotiation`, `httpNotificationAcceptance` |
| Byte caps stop an unfinished load; exact budget and bounded failure diagnostics | [test] `httpBodyBudgetStopsLoad`, `httpDecoderExactByteBudget`, `httpDecoderFailureDiagnosticBudget` |
| Stalled headers/bodies and trickling SSE share a whole-exchange deadline | [test] `httpWholeExchangeDeadline` |
| Ready-load caller cancellation and shared-session shutdown ownership | [test] `httpCallerCancellationIsLocal`, `httpSharedSessionOwnership` |
| Failed/malformed/cancelled initialize cannot publish headers; ordinary replies cannot replace session | [test] `httpSessionHeaderPublication`, `httpCancelledInitializeDoesNotPublishSession`, `httpFailedInitializeDoesNotPublishSession` |
| Gated first initialization refuses overlapping POST | [test] `httpOverlappingInitializeIsRefused` |
| Invalid timeouts and pre-cancelled calls issue no POST | [test] `httpInvalidAndPreCancelledCalls` |
| Deadline can return before an uncooperative worker; entry-controlled cancellation fences late success | [test] `httpExecutionFencesLateWorker`, `httpExecutionCancellationFencesEnteredWorker` |
| Envelope/ID/error shape, preflight identification, strict UTF-8/content type, SSE framing and incomplete EOF | [test] Eight `httpDecoder…` tests with matrices |

[test] Initial fixture compile failed on a Swift sending-closure capture; an explicit Sendable pump
helper fixed it. First expanded run caught missing caller-cancellation propagation in the fixture
escape helper, corrected without a production workaround. Separate review found the initialization
race and a short-deadline test that wrongly required worker scheduling before expiry. The latter now
permits pre-entry timeout and separately establishes entry before testing cancellation fencing.

[test] Runtime mutations removed or damaged: non2xx status, structured data,401/403 separation,
ID correlation, RPC version, error shape, byte cap, recognized failure body, diagnostic cap, SSE CR
framing, event framing, EOF handling, content type, notification status, session method ownership,
initialization exclusion, caller cancellation, application deadline, shared-session ownership and
late native-task cancellation. Every mutation produced a runtime failure, then restored exact bytes.
Driver `/private/tmp/opencore-http-mutations.py`; aggregate `/private/tmp/opencore-http-mutations.log`.

| Restored source | SHA-256 |
|---|---|
| HTTPTransport.swift | `73c2d6eb61c4557b72626277c7adcbc97e6aeaca955eaadca4cf3a11dc8bf939` |
| HTTPResponseDecoder.swift | `18213576eb960d50a42b88b79bfd9f3460101521a6bbf147ef1be662ab447d92` |
| HTTPRequestExecution.swift | `b153a085b1e17d54357037dd85442609ad6a0cbcf78339544520ad7d11164367` |
| MCPTransport.swift | `34f1a5d94b26d7f7854d69f82c49ef9b974394210a2c674864110d6e270d03f0` |

[test] Commands run/read: `swift build --scratch-path /private/tmp/opencore-build`, then
`OPENCORE_GEMINI_FALLBACK=0 OPENCORE_RUN_REVIEW_BOOTSTRAP=1 swift test --scratch-path /private/tmp/opencore-build`;
full target totals113+56+60+41+25+112+310+21=738. The packaged snapshot-only review fixture also ran.
Logs `/private/tmp/opencore-http-restored-build.log`, `…-suite.log`; results JSON records both exit0.
Targeted log `/private/tmp/opencore-http-final-targeted.log` records23 named tests passed.
`bash script/build_and_run.sh --build-only` exited0 and BUILD SUCCEEDED in
`/private/tmp/opencore-http-mac-build.log`. It did not install or launch the production app.

[test] The Mac build emitted CorePresentation import warnings in eight existing view files. This is
tracked separately in roadmap40b49a74-d54f-81b4-bc8d-f6c5c377bd29; this build is not warning-free.
The first full index check also found a stale AppSettings node/callback edge, an unstamped shared
AppModel and two pre-existing unmapped control-decision files. Updated map ownership/evidence only;
final `python3 script/codemap.py check` exited0,22 slices/0 errors/0 warnings. Sensitive scan was run
directly, exit0; `git diff --check` exit0. No commit or push.

## Current contracts checked

[source, 2026-11-01] Current MacOSX27 SDK/Foundation interfaces and Apple docs establish that
[`bytes(for:delegate:)` returns at headers](https://developer.apple.com/videos/play/wwdc2021/10095/?time=261),
[`AsyncBytes.task`](https://developer.apple.com/documentation/foundation/urlsession/asyncbytes/task)
therefore arrives too late for stalled-header ownership, and
[`didCreateTask`](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:didcreatetask:))
is the synchronous registration hook. Native [`cancel()`](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
acknowledgement is asynchronous. Request timeout is an
[idle-data interval](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest),
so trickling data needs an application deadline. Per-session
[`protocolClasses`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/protocolclasses)
supports isolated fixtures. This is SDK/source evidence, not a claim about zero post-cancel bytes.

[source, 2026-11-01] Current [MCP HTTP specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
requires preserving failed-HTTP RPC details and permits unidentified preflight errors. Current
[WHATWG SSE parsing](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream)
requires blank-line event dispatch and discards pending EOF data. Real-service interoperability,
proxy buffering, transport memory bounds, redirects/OAuth currency and full modern-era header/schema
behavior remain unverified or separate migration work.
