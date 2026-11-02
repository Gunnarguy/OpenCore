# Exact JSON-RPC numeric identity

[test, 2026-11-01] Exact-ID integration passed56 targeted tests,17 runtime mutations,760 restored
full tests, package and normal Mac builds, final separate adversarial source review, full codemap,
direct sensitive scan and diff check. No protocol revision/method advertisement changed. No install,
launch, commit or push. Installed Mac remains preference-persistence build; CLI/MCP remains old.

## Measured before and after

[measured] The inherited JSONValue Double path accepted raw fractional1.0000000000000001 as1
and echoed integer9007199254740993 as9007199254740992. The old probe remains at
`/private/tmp/opencore-rpc-id-probe`; it was compiled from the earlier source and is historical.
The new current-source probe was compiled with:

```sh
swiftc -swift-version 6 Sources/CoreJSONRPC/Messages.swift Sources/CoreJSONRPC/RPCWireObject.swift /private/tmp/opencore-wire-id-probe/main.swift -o /private/tmp/opencore-wire-id-probe/probe
```

[measured] Compile and execution exited0. Output:

| Raw ID | New result |
|---|---|
|1.0000000000000001 | Rejected, code-32600 |
|9007199254740993 | Response ID9007199254740993 |
|1e1000 | Response ID1e1000 |

[source] This is exact supplied-wire-byte identity and isolated transport-fixture evidence. It is
not a claim about installed clients, live-service interoperability or ordinary numeric payloads.

## Boundary and owning seams

[source] New `RPCWireObject`/`RPCID`/sealed `RPCIntegerToken` separate IDs from ordinary JSONValue
fields. Strict bounded grammar validates the whole original document before semantic ID rejection.
It rejects trailing commas, invalid escapes/UTF-8 and truncated containers rather than relying on
Foundation's permissive syntax. Duplicate decoded top-level keys are a deliberate invalid-envelope
restriction, checked after syntax and before masking. Only a validated ID token is masked with a
same-length safe placeholder for Foundation to decode other fields. Neither masking nor invalid
ID handling can sanitize malformed original syntax.

[source] Integer validation/canonical equality uses digits, sign and symbolic signed-decimal
exponents, without Double/Decimal, fixed numeric ceilings or exponent expansion. Original numeric
spelling is retained for responses. Zero ignores sign/exponent semantically, after full grammar
validation. String equality/hash uses decoded UTF8 code points; Swift String's canonical Unicode
normalization would otherwise merge distinct IDs. String serialization is JSONEncoder-escaped;
numeric token construction is sealed, so unvalidated input cannot inject fields or framing bytes.
Chosen application budgets are8MiB and128 container levels, not protocol numeric maxima or total
memory guarantees. Public numeric construction checks bytes before making an additional array.

[source] `RPCRequest.decode(Data)` replaces Decodable because decoder-time raw numeric fidelity
cannot be recovered after Double conversion. `RPCResponse.serialized()` requires an explicit typed
ID, keeps legacy unknown identity as explicit null and escapes ordinary values/ErrorBody through
JSONEncoder. Generic codec still distinguishes missing/null for transport-specific preflight errors.
MCPServer run/write, app playground and fixture helpers use these APIs. HTTP/SSE and stdio parse
IDs before exact correlation; generated outgoing integer IDs also bypass Double. Counter exhaustion
is refused rather than overflowing. Authorization, failed-HTTP unidentified-error rules and shared
session ownership from the previous HTTP job remain qualified by the targeted suite.

## Execution and review

[test]14 `RPCWireIDTests` cover raw large/fractional/decimal/exponent/zero IDs, mathematical equality
and hashing, Unicode identity, escaping, missing/null, nested/escaped key scanning, duplicate fields,
syntax-before-semantics, depth/UTF-8, sealed serialization, typed request/response echo and actual
stdio sh-pipe correlation. Added actual injected HTTP/SSE wrong-fraction versus equivalent1e0 test.
Existing request/error/HTTP/stdio regressions passed in the56-test targeted run.

[test] First new-test compile caught a missing inner try in a macro. The next run exposed Foundation
accepting a trailing comma; strict grammar and truncated-container regressions then passed. Separate
review found and closed duplicate-ID quadratic masking, wrong-kind ID error precedence, public
allocation-before-bound and optional ordinary response identity. Final separate source pass had no
remaining actionable scoped finding. The reviewer ran no tests/live access.

[test]17 isolated mutations each exited1 with runtime expectation failures, not compile failures:
fraction validation, floating conversion, negative zero, fractional/exponent offsets, negative
exponent, Unicode identity, string escaping, null presence, duplicates, field injection, array trailing
comma, depth budget, semantic error class, request ID retention, response ID retention, and both
HTTP/stdio exact-wire seams. Driver `/private/tmp/opencore-wire-id-mutations.py`; aggregate
`/private/tmp/opencore-wire-id-mutations.log`. All four mutated files restored exact hashes:

| File | SHA-256 |
|---|---|
| RPCWireObject.swift | `482d169836d9bf0c19615115912e8c7d0da1f755aae94821dc42b75c83d1dbd3` |
| Messages.swift | `bddb23b512210e523d308ec37a5b09e05028c0b5f2ecf4cc4fa20af74ba1e88c` |
| HTTPResponseDecoder.swift | `e51eee18096868ae202801ef16aa1673e14594ed55eacc0b68a7f068fdf10cb4` |
| StdioTransport.swift | `1313ab42fd9959c6f7aef5a4718e2e99af59d4b21cad4604adf4bf42098fd16f` |

[test] Ran/read package build, then full tests with
`OPENCORE_GEMINI_FALLBACK=0 OPENCORE_RUN_REVIEW_BOOTSTRAP=1`, then
`bash script/build_and_run.sh --build-only`, sequentially outside Documents. All exited0.
Full totals113+56+60+41+25+112+332+21=760, including packaged immutable-snapshot review fixture.
Logs `/private/tmp/opencore-wire-id-restored-build.log`, `…-suite.log`, `…-mac.log`; results JSON
`/private/tmp/opencore-wire-id-restored-results.json`. Targeted:
`/private/tmp/opencore-wire-id-reviewed-targeted.log`. No live service/listener, live store/config or physical control/device
tests were performed; stdio children used minimal fixture environments and HTTP used fail-closed
custom-scheme sessions. No real database copy was needed.

[test] Final full codemap check22 slices/0 errors/0 warnings. Direct sensitive scan and
`git diff --check` exit0. Normal Mac build succeeded with five pre-existing fixed-buffer C-string
deprecations; not warning-free. Roadmap40b49a74-d54f-818c-a886-c16af3f1c11f tracks those for later
hardening without physical hardware tests.

[source, checked2026-11-01] Current and advertised legacy MCP prose requires string/integer IDs:
[current requests](https://modelcontextprotocol.io/specification/2026-07-28/basic#requests),
[November2025 requests](https://modelcontextprotocol.io/specification/2025-11-25/basic#requests).
Current SDK/compiler execution establishes the Foundation syntax behavior, not a protocol allowance.
Full dual-era metadata/method/caching/HTTP-header migration, March batch qualification, cancellation-
aware raw stdio loop and real services remain separate work. Generic numeric payloads retain the
existing JSONValue representation; this job makes no arbitrary payload-number fidelity claim.
