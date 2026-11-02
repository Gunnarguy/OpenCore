# Explicit presentation imports

[test, 2026-11-01] The normal Mac build-only command exited0 after adding direct CorePresentation
imports at the eight AppSettings declaration sites that emitted Swift6.4 warnings in the previous
HTTP foundation build. New log `/private/tmp/opencore-presentation-import-build.log` contains
BUILD SUCCEEDED and no `warning:` or `error:` matches. No install or launch was performed.

[source] Scope is one import each in BrowseViews, ChatView, CompanionSettingsView, HomeView,
MCPSourcesView, MachineChecksView, OpenCoreApp and SettingsView. The package product dependency and
the app-local AppSettings typealias already existed. No initialization or app behavior was changed.
Separate source review found no actionable defect in these exact additions; prior dirty edits in
those files were excluded. No new test was added for imports; build resolution verifies the change.

[test] Refreshed the seven affected codemap slices; full check exited0 with22 slices,0 errors and0
warnings. Direct sensitive scan and `git diff --check` exited0. The package's last full run remains738
tests from the immediately preceding HTTP job; it was not rerun for app-only imports. No commit/push.

[source] Roadmap40b49a74-d54f-81b4-bc8d-f6c5c377bd29 records this completed follow-on. HTTP proof's
warning report remains accurate for its earlier build; this later build establishes their removal.
