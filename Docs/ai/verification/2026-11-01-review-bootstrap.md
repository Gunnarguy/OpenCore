# Isolated Mac review bootstrap, 2026-11-01

[test] Package build exited 0. Final full suite exited 0: 677 tests
(113+48+60+41+112+282+21), with the packaged test enabled and no skipped test.
Six relevant tests repeated across two binaries, exits 0. Fifteen isolated guard mutations
failed runtime expectations and restored source SHA-256. Independent source reviews covered
copy admission, sidecars, backup cleanup, production entry guard and packaged-test safety.

[test] Both commands exited 0 with BUILD SUCCEEDED:

```bash
bash script/build_and_run.sh --build-only OpenCoreReview
bash script/build_and_run.sh --build-only OpenCore
```

[test] The actual Review bundle passed strict/deep signature verification. Its plist has the
separate com.gunndamental.OpenCore.Review identity and LSBackgroundOnly=true. Signed entitlements
contain App Sandbox, debug get-task-allow and the read-only /private/tmp/opencore-review-snapshots/
exception. Network client/server, Automation and microphone entitlements are absent. Its symbol
table contains no AppModel, AppSettings, RootView or CompanionHostController. These checks establish
packaging/dependency facts, not a measured denial of every prohibited system operation.

[test] The opt-in packaged probe passed standalone, in the full suite and in its repeat. It created a synthetic source, made a consistent
private snapshot, launched only the Review executable with that explicit copy and observed one
object. Snapshot bytes were unchanged and no WAL/SHM/journal appeared. Missing arguments returned
exit 2. The probe requires the exact Review identity and success marker before its refusal test.
No production UI, real store, credentials, model, endpoint, hardware or computer control was tested.

```bash
OPENCORE_RUN_REVIEW_BOOTSTRAP=1 OPENCORE_GEMINI_FALLBACK=0 swift test --skip-build --scratch-path /private/tmp/opencore-build --filter packagedReviewBootstrapUsesOnlyFixture
```

[test] Source main/WAL bytes survive snapshot creation. Immutable reads reject writes and preserve
copy bytes even for a WAL-header image and filenames containing URI metacharacters. Preexisting
sidecars remain untouched and prevent either backup kind from creating a destination main file.
A platform-retained SHM index exposed during development is removed only after target close,
only when it is the same ordinary nlink1 inode created inside the private backup namespace.

[test] An earlier pre-package full run failed an existing wall-clock month fixture on November 1.
The reasoning result was correct; the expectation assumed five-day-old events were in this month.
The fixture now supplies explicit UTC middle/first-month references and expected nonempty/empty
results. Two targeted runs and the final full suite passed. Another pre-package run intentionally
skipped the not-yet-built packaged probe; it is not the final verification result above.

[measured] Authorized production deployment exited 0, built successfully and launched the Mac app.
Previous bundle remains under /private/tmp/OpenCore-app-backups. Normal scheduled sync may follow
launch; this deployment was not used as a live-store test. CLI/MCP installed binary is unchanged.

[measured] Storage guards prevented builds without reserve. Only owned rebuildable caches/indexes/
package intermediates were removed; Products and logs were retained. After the final suite, 304
source-identified UUID fixture directories born within that exact completed run were removed,
recovering 246.2 MiB. Rollback bundles, owner data, other output and agent histories were preserved.

[source] Detailed local logs: /private/tmp/opencore-review-bootstrap-*.log. Raw build/signing/runtime
logs are not tracked. API contracts/check dates are linked in COMPLETION and ARCHITECTURE.

[design] This is a Foundation-only bootstrap, not a screen review. Actual views require isolated
settings/model injection and suppression of view-task side effects before they may be constructed.
No Mac screen, menu/focus behavior, physical pairing or real-model fidelity is certified here.
