# Settings and theme ownership

[source, 2026-11-01] The original preference implementation separately chose standard defaults for
reads and writes, and three didSets reached production controllers/configuration. CorePresentation
now requires one defaults instance and explicit callbacks. The app bridge supplies the original
production effects. Separate review compared all42 stored keys/defaults with the original.

[source] Pastel tokens moved unchanged into the same macOS-only package target. Actual glass
card/bar/badge helpers now resolve environment settings from ViewModifier.body. This prepares real
view reuse; no view was rendered. AppModel still supplies a production environment fallback and
owns services/defaults that must be isolated before real screen review. Appearance remains a
process-local NSApp operation. The ignored SharedConfig save failure remains a separate roadmap job.

[test] `swift build --scratch-path /private/tmp/opencore-build` exited0. The restored full package
suite exited0 with683 tests (113+48+60+41+6+112+282+21), none skipped. The packaged review-bootstrap
fixture probe was enabled and passed. Six new preference tests cover independent suites, restoration
without effects, explicit callbacks, live-default confirmation clearing, isolated persistence and
chunking/retrieval reset semantics. Only fresh UUID defaults suites and fixture stores were used.

[test] Nine isolated mutations each produced named runtime expectation failures: read suite, write
suite, initialization callback, missing scheduled-sync callback, missing dry-run callback, inverted
MCP callback, missing confirmation clearing, missing confirmation granting and missing chunk-dirty
transition. Harness exit0 restored AppSettings.swift SHA-256
`9751ae9cb315969afcd7be1cae1bef1c0b8388fb2dbecf77f72c2d1223b2630e`.
Logs: `/private/tmp/opencore-settings-mutations-summary.log` and per-case mutation logs.

[test] The first normal Mac build exited65: inferred AppSettings.shared and AppModel.shared types
formed a compiler circular reference. The app bridge now explicitly declares its shared value's
AppSettings type. Final normal and review Mac build-only commands each exited0 with BUILD SUCCEEDED.
The separate final bridge review confirmed lazy initialization and deferred callback invocation.
Authorized normal deployment exited0 and launched; previous bundle retained at
`/private/tmp/OpenCore-app-backups/20261101T084650Z-85152/OpenCore.app`. No live-store test performed.
Maps reported0 errors/warnings; sensitive scan and diff whitespace checks exited0.

[source] Separate adversarial review found no actionable extraction defect and checked explicit
ownership, restoration, confirmations, dirty/reset semantics, environment lookup and target wiring.
That review performed no builds, tests or live access. Raw logs stay outside this public repository.

[source, Apple references and macOS27 SDK checked 2026-11-01] Current
[Environment](https://developer.apple.com/documentation/swiftui/environment) documentation describes
view-local environment lookup and dependency updates. Current
[ViewModifier](https://developer.apple.com/documentation/swiftui/viewmodifier) is MainActor-isolated;
the modifiers read settings in body. NSColor's
[dynamic provider](https://developer.apple.com/documentation/appkit/nscolor/init(name:dynamicprovider:))
receives the drawing appearance. Its current SDK declaration is not NS_SWIFT_SENDABLE; immutable RGB
captures and the original factory behavior are preserved. These references do not prove rendering,
contrast, keyboard/menu behavior or complete review-runtime isolation.
