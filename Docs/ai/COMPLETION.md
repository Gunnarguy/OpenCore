# Mac and companion completion

[design, 2026-10-31] Owner: “yep do all of them. 10x full send.” This authorizes the eight completion
areas discussed, including the matching Mac deployment. It does not revoke the hard prohibitions:
no live-store tests, live rebuild apply, live computer control, hardware writes, Hub edits or commits/pushes.
Each job gets named regressions, mutation proof where behavior changes, separate review and actual builds.

| Area | Work and proof | Current state |
|---|---|---|
| Mac/phone connection | Matching deployment; in-person Face ID/pair; revoke/sleep/reconnect review | [measured] Latest phone and Mac builds installed; the Mac build remains closed. [design] Owner physical check pending. |
| Imported history | Explicit owner domains and ordinary personal wording; MCP/system gates; Notes diagnosis; sustained freshness | [test] Owner scopes, private cloud gate and follow-ups passed 618 tests and all three builds; deployed. Notes framing/accounting/precision and bounded output are fixture-tested; real Notes acceptance remains. |
| Mac screen flows | Safe isolated read-only review runtime; current twenty-section checklist; close actual loading/count/filter/feedback defects | [source] Startup-empty legacy defect already addressed. Timeline has a latest-request publication race. [test] Separate read-only bootstrap passed 677 tests and packaged fixture probe; actual views still need safe injection. |
| Evidence and consistent answers | Remove synthetic Jarvis/Intent citations; use real floor provenance, counters and configured retrieval | [test] System grounding repair: 623 tests, eight mutation proofs, independent review and Mac deployment passed. [test] JARVIS snapshot repair: 634 tests, ten mutation proofs, independent review and Mac deployment passed. UI acceptance remains unverified. |
| Safety | Independent outbound privacy gate, key out of URL, late Stop/dry-run/scan decision tests; report external Hub dependencies | [source] Cloud scope guard repaired, review source passed. Header auth and independent cloud request audits are tested and deployed; operator jobs remain. |
| Existing-store recovery | Fresh copy, readonly inspection and rehearsal/report, preserve primary data and history | [design] New copy/rehearsal pending; agent never applies to live store. |
| Native/current integrations | Native Settings scene, current SDK/API evidence, complete dual-era MCP server/client migration | [source] Official 2026-07-28 MCP revision confirmed; source/plan below. |
| Ubiquity and quality | Menu/window and system-surface parity, owner actions and operator views on phone, stored context boundaries, held-out eval | [design] Remaining implementation and acceptance work. |

[source] Read-only Mac review requires a branch before production AppModel/RootView/MenuBar construction:
production startup touches the live store, prefs, notification/Spotlight services and operator singletons.
Use a distinct review bundle, isolated defaults, Store.openReadOnly, no credentials/models/sync/telemetry
polling, and disabled mutation paths. A disabled button alone cannot stop a view's task side effects.

[source, official refs checked 2026-11-01] MCP 2026-07-28 is current and permits dual-era support:
[release](https://blog.modelcontextprotocol.io/posts/2026-07-28/),
[versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning),
[discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
[caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching),
[stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio).
Required: per-request _meta version/capabilities; discover supportedVersions/serverInfo; complete result
envelopes; ttlMs/cacheScope on discovery and lists; unsupported-version error data; legacy methods only
on legacy requests; cancellation/EOF preventing late replies. Existing client also needs discover-first
era detection, modern per-request metadata and HTTP headers, proper array parsing and error.data.
The old note claiming all error codes were renumbered is too broad: standard JSON-RPC errors remain.
[source, checked2026-11-01] All advertised legacy revisions require string/integer IDs and object
params too. The [March2025 batching requirement](https://modelcontextprotocol.io/specification/2025-03-26/basic#batching)
is a separate inherited gap: the current server advertises that revision but cannot receive batches.
Implement/qualify that transport behavior or remove the advertisement in full integration; row
40b49a74-d54f-81f2-9705-f7b8c79f1e9a tracks it. A per-request decoder correctly rejects an array as
one request; that is not proof that the transport supports batches.
[source] The current [HTTP contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
also requires matching body/header versions, Mcp-Method, relevant Mcp-Name and schema-directed
Mcp-Param headers. Validate x-mcp-header names/paths and primitive values before advertising tools;
exclude invalid annotated tools while retaining valid ones. Apply the specified base64 sentinel
encoding to unsafe header values, preserve header-mismatch -32020 and unsupported-version -32022
details (supported/requested). Authorization401/403 never justify era fallback. Modern HTTP has no
legacy session/replay path and cancels a request by closing its stream. These are remaining migration
requirements; the bounded transport job below does not advertise modern support.

[test, 2026-11-01] Structured error foundation passed715 tests,16 runtime mutations, separate
source review and normal Mac build. Decoded optional details retain explicit null/absence and remain
available through a shared accessor; automatic descriptions omit them. No protocol advertisement
changed. The follow-on HTTP job passed738 full tests,23 isolated parser/session tests,21 runtime
mutations, separate source review and normal Mac build. Full dual-era behavior remains pending.
Neither foundation is installed separately. Proof: [RPC error details](verification/2026-11-01-rpc-error-data.md),
[bounded HTTP](verification/2026-11-01-http-transport.md).
[test, 2026-11-01] Eight explicit CorePresentation imports removed the Mac dependency warnings;
separate source review, normal build-only and map/sensitive/diff checks passed. No runtime behavior
change or new package test claimed. Proof: [presentation imports](verification/2026-11-01-presentation-imports.md).
[test, 2026-11-01] Decoded MCP envelope structure passed745 full tests,7 matrix tests,11 runtime
mutations, separate source review and normal Mac build. This does not establish exact numeric wire
IDs: isolated current-source probes measured1.0000000000000001→1 and9007199254740993→9007199254740992.
[measured] The inherited loss is recorded in [decoded envelopes](verification/2026-11-01-rpc-request-envelope.md).
[test] Exact raw-ID job40b49a74-d54f-8198-991a-da157dfde02a completed with760 full tests,56 targeted,
17 runtime mutations, separate source review and package/normal Mac builds. Raw current-source probe
now refuses the tiny fraction and echoes the large integer and1e1000 exactly. Protocol advertisement
and ordinary numeric payload representation are unchanged; full integration stays pending. Proof:
[exact wire IDs](verification/2026-11-01-exact-rpc-ids.md).
[test, 2026-11-01] Stdio concurrent ownership is fixed: original reversed-reply pipe fixture lost
the second call;777 full tests,23 focused,25 runtime mutations, separate review and package/normal
Mac builds now pass. Per-owner chunk receipts preserve eligible backlog without dropping other
callers' data. Proof: [stdio ownership](verification/2026-11-01-stdio-ownership.md).
[test] Client stdin writer40b49a74-d54f-8108-995b-e6d7a00d74ee completed with791 full tests,88 focused,
16 writer/6 reader runtime faults and three repeated gate cases, separate review and package/normal
Mac builds. Final1MiB probe timeout0.1 returned0.107323083s (old2.298375042s); cancel0.000943125s after
cancel (old2.182399083s), both exit0. Per-FD SIGPIPE and exact descriptor-reuse probes passed with an
unprotected negative control. Proof: [nonblocking stdin](verification/2026-11-01-stdio-writer.md).
[source] Confirmed subprocess exit is separate High40b49a74-d54f-8164-8235-db82acb61b4b: TERM is only
a request, raw PID kill needs ownership proof. No synchronous encoding/whole-exchange or hostile-child
exit guarantee claimed. Full dual-era MCP remains incomplete. Owner-requested wrap-up installed and
launched the qualified legacy-preserving Mac baseline (--verify0); installed CLI remains old.

[source] Current read-only explorer found startup generation triggers in Corpus/Entities/Timeline/Sources.
The old 21-screen list and old roadmap titles are historical findings, not proof of current failures.
Update their status only after checking source, appropriate fixtures and actual review behavior.

[source, reference checked 2026-10-31] Operator snapshot ordering uses a monotonic process clock,
separate from displayed wall-clock capture dates. The current SDK typechecked DispatchTime.now().uptimeNanoseconds;
Apple documents [uptimeNanoseconds](https://developer.apple.com/documentation/dispatch/dispatchtime/uptimenanoseconds)
as time since boot excluding sleep. This establishes the API contract; fixture tests establish cache behavior.

[source, reference checked 2026-10-31] The native Settings scene reuses the same SettingsView and shared
preferences as the sidebar. Current [Apple Settings documentation](https://developer.apple.com/documentation/swiftui/settings)
assigns the application menu and keyboard-shortcut presentation to SwiftUI. Xcode 27 SDK compilation
is the implementation check; actual menu/window interaction is not yet measured.

[source, Apple reference checked 2026-10-31] Settings and menu-bar launchers present the main String-valued
window group using its matching default workspace value. Apple's current [openWindow reference](https://developer.apple.com/documentation/swiftui/environmentvalues/openwindow)
distinguishes opening another group window by id from reusing an existing window presenting the same
value. Both Settings and main workspace show shared operation/failure state. Current SDK build passed;
window focus/reuse and menu/keyboard acceptance are not yet measured.

[source, references checked 2026-10-31] Optional cloud fallback authentication uses the header in
Google's current [API-key guide](https://ai.google.dev/gemini-api/docs/api-key). The pure request helper
keeps credentials out of its URL and rejects invalid header tokens. The [deprecation table](https://ai.google.dev/gemini-api/docs/deprecations)
lists no shutdown for the existing 2.5 Flash model and limits access to past users. This job preserves
the model and existing opt-in/admission gates; it does not qualify a real account or call the service.

[source, Apple reference checked 2026-10-31] The [AppleScript timeout reference](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html)
specifies per-command timeouts and says timing out does not cancel the target application's operation.
Notes sets that event budget separately from its bounded reader process. Synthetic AppleScript tests
exercise the actual escaped framing handlers and ISO date coercion; they do not qualify Notes' live
dictionary bindings, Automation permission or library completion. Incremental reads retain the boundary
second because Notes timestamps omit fractions. Incomplete replies cannot advance date/cursor.

[test, 2026-10-31] Notes verification exposed a deterministic BoundedProcess output defect: a parent
could exit successfully while an inherited writer was still open; the fixed one-second drain returned
incomplete output as success. The drain now uses the original remaining deadline, observes cancellation
and marks an unfinished drain timed out. Delayed synthetic pipe fixtures and three mutations prove it.
The separate stdio investigation then proved deadline-before-buffer and callback-ordering defects
with controlled fixtures. Read timestamps preserve only the finite on-time backlog; read locks preserve
byte/EOF order; cancellation precedes consumption. The original full-run symptom had no timing trace,
so assigning its exact cause remains an inference. The full dual-era MCP migration remains pending.

[source, Apple references and Xcode 27 SDK checked 2026-10-31] Foundation's current
[readabilityHandler](https://developer.apple.com/documentation/foundation/filehandle/readabilityhandler)
uses a Sendable callback, confirmed by NSFileHandle.h's NS_SWIFT_SENDABLE annotation. The implementation
serializes each stream's read and publication without assuming callback ordering. Current Swift
[checkCancellation](https://developer.apple.com/documentation/swift/task/checkcancellation%28%29)
throws CancellationError; it runs before consuming a queued reply. Fixtures prove behavior separately
from these API contracts. This job changes no MCP methods, capabilities, domains or protocol revision.

[source, references checked 2026-11-01] The internal Foundation-only OpenCoreReview executable links
only OpenCoreReviewSupport (CoreStore/CoreTelemetry), with a separate identity and background-only
plist. The normal app refuses review arguments before its model is constructed. Apple's current
[App Sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox)
and published [temporary file exception reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
establish the declared read-only path exception; actual signed metadata and fixture execution were
checked separately. Network client/server, Automation and microphone entitlements are absent.

[source, SQLite reference and macOS 27 SDK checked 2026-11-01] Normal read-only SQLite connections
may consult [WAL sidecars](https://www.sqlite.org/wal.html#read_only_databases). Review admission
rejects them and file aliases; its distinct factory uses an escaped file URI with
[immutable read-only mode](https://www.sqlite.org/uri.html), never for a changing/live database.
The typed snapshot helper consistently backs up to a new private destination, makes it self-contained
and read-only, and verifies cleanup before success. Both backup kinds refuse preexisting sidecars.
Source main/WAL bytes and mutation refusal were tested on fixtures. Schema/migrations are unchanged.
Verification and limits: [review bootstrap](verification/2026-11-01-review-bootstrap.md).

[test, 2026-11-01] Settings/theme ownership extraction passed683 package tests, nine runtime
mutations, separate source review and both Mac build-only schemes. CorePresentation requires
explicit persistence/effects; all42 original stored keys/defaults are preserved. Actual glass
card/bar/badge modifiers now use environment settings. AppModel/services/view tasks still require
isolation before real screens can be reviewed. Proof and current Apple reference dates:
[settings ownership](verification/2026-11-01-settings-ownership.md).

[test, 2026-11-01] MCP startup preference persistence passed710 full tests,33 targeted tests,
19 runtime mutations, final separate source review, both Mac builds and authorized deployment.
[source] Requests, unknown outcomes and matching observations are separate; malformed inputs are
refused and unknown fields retained. Current-file revalidation protects new playground/copy actions;
valid saved authorization restores once without a repeat write, including an explicit unknown-read
attempt marker. Generated clients contain no unsafe override. Existing servers need restart and
explicit overrides need removal. Actual UI/CLI acceptance remains separate:
[MCP preference](verification/2026-11-01-mcp-preference.md).

[test, 2026-11-01] Typed requested-entity resolution/read behavior passed692 tests and11 mutations.
[source] App navigation now reports initiation separately from real completion, rejects missing or
failed targets without an unrelated default dossier and preserves request/history ownership.
Separate review found four app wiring issues; focused fixes passed the final source review.
Final Mac build and authorized deployment passed. Actual screen acceptance remains unverified.
Proof and current SDK/reference date: [entity navigation](verification/2026-11-01-entity-navigation.md).

[measured, wrap-up2026-11-01] Latest tested Mac build installed/launched, --verify exit0; phone app
read-only device query confirms0.1.0(1) installed. Pairing remains “Not tried yet”; no phone UI/control
acceptance claimed. Lifecycle supervisor remains a reviewed design, no product implementation. Full
completion areas above remain open. No commits/pushes or live-store/hardware/control tests.
