# Decoded MCP request structure

[test, 2026-11-01] Generic decoded-envelope validation passed7 named matrix tests,11 runtime
mutations,745 restored full tests, package and normal Mac builds, full codemap/sensitive/diff checks.
Separate source review closed the bounded structure checks, while identifying a separate measured
raw numeric-ID defect. This job does not establish exact numeric wire fidelity or protocol migration.

[source] `RPCRequest` now explicitly decodes an object with literal JSON-RPC2.0 and string method.
Present IDs must be strings or finite integral numbers within JSONValue's Double representation;
null/bool/array/object IDs are refused. Absent ID alone denotes a valid notification. Present params
must be objects; absent params remain absent. Params/metadata retain their values without selecting
permissions. Constant malformed-envelope errors contain no input payloads. No method/version
advertisement changed; the current server loop still drops decode failures rather than emitting
complete wire parse/invalid-request responses. That loop is pending atomic dual-era integration.

[test] `RPCRequestTests.swift` covers invalid ID/version/method/params matrices, retained valid
string/integral IDs, absent notifications, object params/metadata, constant diagnostics, non-object
envelopes and nonfinite configured-decoder values. The first number-alias variant passed before
current normative prose was reconciled; the final test rejects positive/negative fractional decoded
IDs. No listener, live store/config, credential, phone or control endpoint was exercised.

[test]11 mutations each exited1 with runtime expectation failures: wrong-version acceptance,
null-ID collapse, arbitrary ID shape, fractional IDs, nonfinite IDs, arbitrary params shape, erased ID,
wrong method, erased params, inverted notification classification and input payload in diagnostics.
No compile failure counted as proof. Driver `/private/tmp/opencore-rpc-request-mutations.py`, aggregate
`/private/tmp/opencore-rpc-request-mutations.log`; Messages.swift restored exact SHA-256
`e98f6db4932c3ccb49a4234d781dd3307a49ca57cf70183b92b64cf673a28276`.

[test] Ran/read `swift build --scratch-path /private/tmp/opencore-build`, then full tests with
`OPENCORE_GEMINI_FALLBACK=0 OPENCORE_RUN_REVIEW_BOOTSTRAP=1`, then
`bash script/build_and_run.sh --build-only`. All exited0. Full totals
113+56+60+41+25+112+317+21=745; packaged immutable-snapshot review fixture also ran.
Logs `/private/tmp/opencore-rpc-request-restored-build.log`, `…-suite.log`, `…-mac.log`;
results `/private/tmp/opencore-rpc-request-restored-results.json`. Mac log has BUILD SUCCEEDED with
no warning:/error: matches. Full22-slice codemap check0 errors/0 warnings; direct sensitive scan and
`git diff --check` exit0. No install, launch, commit or push; prior installed Mac/CLI remain unchanged.

## Open fidelity defect, not closed by this foundation

[measured] Separate review found that JSONValue converts numeric tokens to Double before these
checks. Compiled current Messages.swift with `/private/tmp/opencore-rpc-id-probe/main.swift` using
`swiftc`, then ran its isolated fixture binary. Both commands exited0, and raw inputs produced:

| Raw ID | Encoded response ID |
|---|---|
|1.0000000000000001 |1 |
|9007199254740993 |9007199254740992 |

[source] Tests constructed through JSONValue cannot expose this earlier token loss. Exact raw-ID
validation, preservation and response correlation must be fixed next, before modern integration;
roadmap40b49a74-d54f-8198-991a-da157dfde02a retains this measured High finding. No invented Int64 or
safe-integer protocol ceiling was introduced here. The source limitation comment and final separate
review explicitly preserve this boundary. Completion of this narrow row is not completion of that bug.

[source, checked2026-11-01] MCP prose requires string/integer IDs despite the broader TypeScript
number alias, and object params across current and all advertised legacy revisions:
[current basic protocol](https://modelcontextprotocol.io/specification/2026-07-28/basic#requests),
[November2025](https://modelcontextprotocol.io/specification/2025-11-25/basic#requests),
[June2025](https://modelcontextprotocol.io/specification/2025-06-18/basic#requests),
[March2025](https://modelcontextprotocol.io/specification/2025-03-26/basic#requests).
March additionally requires receiving batches; the inherited run loop does not support them despite
advertising that revision. Separate row40b49a74-d54f-81f2-9705-f7b8c79f1e9a requires batch qualification
or corrected advertisement during integration. An individual request decoder is not a batch dispatcher.
