# Requested entity navigation

[source, 2026-11-01] EntityLinkChip reported completed claims/passages before openEntity queued
navigation, and displayed invented SQL. The actual typed dossier read contains collapsed statement
rows, bounded recent events, contradictions and aliases, not passages. Unmatched/failed name lookup
could keep an unrelated default dossier. Consuming pending fields restarted the task's default load.

[source] The chip now reports receipt only. CorePresentation.EntityNavigationRead resolves the exact
requested ID/canonical name/alias, reads its dossier and returns loaded/missing/failed/discarded.
It checks cancellation and current ownership before and after suspension points and rejects a
mismatched dossier. No SQL, credentials or production defaults are introduced into presentation.

[source] Explicit app navigation suppresses default selection and clears the previous dossier before
loading. Its revision is separate from pending-field consumption. The requested target lives in the
history owner after failure, so Back/refresh/retry retain the subject. Manual selection synchronously
invalidates the old target, and publication also checks the model request revision. List replies
guard dossier/error ownership. A generation refresh preserves the nested workspace tab; only a new
explicit/history/legacy request presents the dossier tab. Terminal feedback follows a current real
read and reports returned row/event/contradiction counts. Failed reads retain the failure banner.

[test] Restored `swift build` and full `swift test`, both using `/private/tmp/opencore-build`, exited0.
The suite passed692 tests (113+48+60+41+15+112+282+21), with the packaged review-bootstrap fixture probe
enabled. Nine new tests (including parameterized cases) cover exact/alias/missing targets, resolution
and read failures, nil/mismatched dossiers, obsolete requests, suspended reads and cancellation.
Fixtures are in-memory values with controlled asynchronous reads, not the live store or UI.

[test] Eleven independent mutations each produced named runtime expectation failures: wrong exact
target, reversed alias order, missing-name default fallback, nil-dossier outcome, mismatched-dossier
acceptance, omitted ownership/cancellation gates before reading/after resolution/after reading,
cancellation reported as failure, obsolete error publication and swallowed read failures. Harness
exit0 restored helper SHA-256 `12088a650ed55f6fcc6abe769207c6981080d7774d03ae06d236e2b82fc3f907`.
Logs: `/private/tmp/opencore-entity-navigation-mutations-summary.log` and per-case logs.

[source] Separate adversarial review found app wiring defects beyond the package helper tests:
deferred manual invalidation, missing failed targets in history, list errors overwriting newer
dossier state and refresh resetting nested tabs. Focused source fixes address those findings;
the final separate source pass found no further actionable defect. The helper tests do not exercise SwiftUI
bindings/history/menu interactions. Actual view acceptance remains unverified. Existing manual
selection cancellation/nil-dossier handling is tracked separately in the roadmap.

[test] Both normal and thin review Mac build-only schemes exited0 before the final refresh/tab
source fix. Final normal build and authorized deployment each exited0 with BUILD SUCCEEDED.
The app launched; previous bundle retained at
`/private/tmp/OpenCore-app-backups/20261101T090645Z-93902/OpenCore.app`.
Map check reported0 errors/warnings;
sensitive and diff checks exited0. No phone source or wire
contract changed, so no phone rebuild was needed. No live-store test or computer control performed.

[source, Apple references and macOS27 SDK checked 2026-11-01] Current
[task(id:…)](https://developer.apple.com/documentation/swiftui/view/task%28id%3Aname%3Apriority%3Afile%3Aline%3A_%3A%29)
compares an Equatable ID and cancels/restarts work when it changes. The SDK interface confirms its
default name/priority/file/line parameters; the older documentation URL no longer resolves.
[Task.cancel](https://developer.apple.com/documentation/swift/task/cancel%28%29) describes cooperative
cancellation, so cancellation alone does not prevent late publication. These contracts explain the
revision and explicit ownership gates; fixture tests and source review provide separate evidence.
