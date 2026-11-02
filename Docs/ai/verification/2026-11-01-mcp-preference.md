# MCP startup preference persistence

[source, 2026-11-01] The app previously saved its requested defaults Bool, ignored shared-file
errors and immediately claimed the configuration blocked/permitted access. Loading malformed
configuration silently defaulted before re-encoding one field, losing other JSON fields. The
generated unsafe flag could override a later restrictive shared setting, including after restart.

[source] SharedConfig.setMCPExposure patches only its known field, preserves other JSON fields,
refuses unreadable/malformed/nonregular existing documents and validates a present privacy field
as a Boolean. Missing documents may be created. Its typed result separates preparation refusal,
unconfirmed write/readback and matching observed readback. A writer error never promises unchanged
bytes and triggers no rollback. Confirmation is neither a durable-write guarantee nor a lock against
other writers. Existing CLI load behavior remains restrictive; no schema/migration changed.

[source] CorePresentation keeps requested UserDefaults separate from the shared-write result.
Initialization/isolated effects do not certify configuration. A failed/new unknown result clears
stale confirmation, and the app bridge retains failures through its banner. Both settings/status
surfaces show the result; newly created playground servers unlock only confirmed permissive state.
The safe block action is always available, including retrying the same requested value; unsafe
startup access still requires the named confirmation dialog.

[source] Separate review found that cached write confirmation could outlive an external writer's
restrictive change. Strict current-file observation now revalidates confirmation immediately before
new playground construction or clipboard copy. Changed/unreadable state clears confirmation;
unknown state cannot gain authorization from a later matching read alone. Status wording describes
the last confirmed save. This still does not lock the file or revoke existing server instances.

[source] An initial strict read can restore existing shared authorization without asking for another
write each launch. It performs no callback or I/O inside the preference object. Requested defaults
are not authorization; any attempted session change, failure or invalidation prevents initial-read
restoration. Unknown first reads also consume that one-shot opportunity via an independent
attempt flag. The UI distinguishes an observed existing setting from a confirmed write result.

[source] Generated client JSON escapes the command and contains only the mcp argument. It relies on
the shared startup setting and cannot bake in an unsafe override. Copying requires a verified setting
in both the control state and action guard. The UI explains restart/reconnect and removal of existing
explicit unsafe arguments. Saving a file does not revoke a running server or edit a client's config.

[test] Restored package build and full suite exited0:710 tests
(113+56+60+41+25+112+282+21), packaged review probe enabled. Targeted tests also exited0:
8 shared-config and25 presentation tests.
Controlled fixtures cover missing/valid/future-only documents, unknown-field preservation,
malformed/non-Boolean byte preservation, aliases, preparation failure, partial writes and missing/
failed/mismatched readback. Preference tests cover unknown/confirmed/failed/mismatched results,
same-value restrictive retry, stale confirmation and JSON command escaping without unsafe flags.
All filesystem data and defaults suites are fresh UUID fixtures; live configuration/store/credentials
were not read or written as tests.

[test] Nineteen independent mutations each failed named runtime expectations, including lost fields,
invalid-field acceptance, alias replacement, wrong failure phases, missing readback, requested/stale/
mismatched confirmation, unsafe client arguments, invalid revalidation, strict-read fallback and
initial/postattempt/unknown-initial observation. Harness exit0 restored SHA-256:
SharedConfig `9b304efed37cf92ea43b7bef18797f4c16055f53307b7706d74ee29725e5407b`;
AppSettings `cf19903a4fbbd714164cd6f25c957c315983ccb2259c2bc49f50e9b3f8becbc7`.
[source] The separate final source review found no remaining actionable defect after stale-consumer and
nil-initial-observation repairs. It performed no execution/live access.

[test] Both Mac build-only schemes and authorized deployment exited0 with BUILD SUCCEEDED.
The app launched; prior bundle is retained at
`/private/tmp/OpenCore-app-backups/20261101T093604Z-8579/OpenCore.app`.
Map check reported0 errors/warnings; sensitive/diff checks exited0. Raw logs remain in
`/private/tmp/opencore-mcp-preference-*`; no phone source or protocol changed.

[source, Apple references checked 2026-11-01] Current
[Data.WritingOptions](https://developer.apple.com/documentation/foundation/data/writingoptions)
aliases NSData options; [atomic](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic)
writes an auxiliary file then replaces the destination. This is not a running-permission guarantee.
[File attributes](https://developer.apple.com/documentation/foundation/filemanager/attributesofitem%28atpath%3A%29)
include a symbolic link's own type; the implementation admits an ordinary file. Current macOS27 SDK
package and app compilation exercised these APIs. Actual UI/CLI-process acceptance remains unverified.
