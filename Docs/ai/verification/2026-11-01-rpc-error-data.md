# Structured JSON-RPC error details

[source, 2026-11-01] RPCError, its response body and both recognized remote-error paths previously
discarded the optional data payload. The value/wire types and transport-independent accessor now
retain decoded JSONValue details, including explicit null separately from absence. Code/message
fallbacks and legacy constructors remain. Automatic ordinary/debug/localized descriptions omit
payloads; generic HTTP status descriptions no longer include raw bodies. Deliberate typed access
retains the original details. No protocol version, method, admission rule or listener changed.

[test] Restored package build/full suite exited0:715 tests
(113+56+60+41+25+112+287+21), packaged review probe enabled. Five new tests cover eight-case
absent/null/scalar/nested matrices, server response encoding, typed transport access, actual matched
stdio child replies, recognized HTTP JSON/SSE mapping, safe descriptions and legacy fallbacks.
The child uses only pipes and a minimal environment, with shutdown on both request outcomes.
The HTTP test exercises the shared mapper; it does not qualify a real HTTP session or service.

[test] Sixteen isolated mutations each produced named runtime failures: dropped constructor,
null-presence/wire/common-mapper data; stdio/HTTP producer and accessor loss; direct error access;
payload/body description leakage; missing error-code fallback; and invented default null details.
The harness exited0 and restored SHA-256:
Messages `ffb77bef378d7363cef25a41427093841d35c80ee832482b3afec3e6d0154f5d`;
StdioTransport `4d537bad8f6d132ca081a71db1d0b3ab621d536f7909cefb864ddbf914e4e099`;
HTTPTransport `400a9a92f6643b1b9bb229d0809d80263ec6744a81626ea2d9ee00a035fc4132`;
MCPTransport `d0dfbf49dfca18791d4c8be9eed3694948253e0830e20ef14615646f408c222b`.
Logs: `/private/tmp/opencore-rpc-error-data-*`.

[source] Separate adversarial review found no actionable defect within this foundation. It ran no
tests/builds/live access. Non-2xx HTTP parsing, correlation, size/deadline limits and the complete
dual-era MCP migration remain separate roadmap jobs. This is not modern-support qualification.
[test] Normal Mac build exited0 with BUILD SUCCEEDED; map check reported0 errors/warnings,
sensitive/diff checks exited0. Deployment is deferred until the
complete MCP phase; the currently installed Mac is the verified preference-persistence build.

[source, references and macOS27 SDK checked 2026-11-01] The
[JSON-RPC2 specification](https://www.jsonrpc.org/specification), section5.1, permits optional
primitive or structured error data. Apple documents
[localized error descriptions](https://developer.apple.com/documentation/foundation/localizederror/errordescription)
and [custom debugging descriptions](https://developer.apple.com/documentation/swift/customdebugstringconvertible/debugdescription)
as distinct representations; current SDK tests exercise all three formatting routes. Keeping
structured details available is separate from automatically placing them in diagnostic text.
