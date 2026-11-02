# Companion verification, 2026-10-31

[test] Final package build and full suite exited 0: 612 tests across seven binaries. A repeated
focused scope/companion run with --skip-build passed (1+17 tests). Mac build-only, iOS Simulator
and development-signed iPhone builds succeeded. Device bundle signature verification exited 0.

[test] Named mutation failures covered stale authentication publication, repeated acknowledgement,
passage trace persistence in both answer modes, scope/context reset, pre-limit subject admission,
receipt input privacy and re-pairing. Restored source hashes matched. The pairing-grant check was
also removed in isolation and its named regression failed independently.

[measured] These screenshots contain no real store data. Home, Library navigation, locked Claims,
Connection and the Pair your Mac navigation were exercised in a dedicated iOS 27 simulator. Light,
dark and largest Dynamic Type were inspected. [source] Large-text content uses vertical scroll views;
a scroll gesture was not exercised in that check. [measured] The initial remote
accessibility timeout recovered; some tap calls warned about snapshot settling and the following
snapshot succeeded. This is a manual simulator smoke check, not a UI test suite.

[source] Full-model output, physical Face ID, real tailnet traffic/bind/revoke, asleep-Mac behavior,
and app-switcher cover are unverified. [measured] The physical iPhone was subsequently installed
at the owner's word; app inventory confirmed 0.1.0 (1). The Mac was not replaced. The Secure Enclave path has no
simulator software fallback. Later store/operator/control phases are not implemented.

[source] The Mac built at /private/tmp/opencore-review-dd and phone at /private/tmp/opencore-phone-dd.
Build/test/mutation logs are temporary files under /private/tmp/opencore-*.log; they are not published.
No real listener or live-store test ran. No commit or push occurred.
