---
paths:
  - "Tests/**/*.swift"
---

# Test rules

Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.

## Test names are sentences about behaviour

`@Test("later evidence supersedes earlier for a functional predicate")`, not
`testSupersession`. The name is the specification; someone reading a failure should learn what
broke without opening the body.

## Assert the invariant, not a magic number

A test asserting `count == 1` breaks the moment a second migration exists and teaches nothing
when it does. Assert the property: versions are contiguous from 1, re-running changes nothing,
rebuild reproduces the same graph.

## A fixed bug gets a regression test that names the bug

Put the original failure in a comment above the test, in enough detail that someone can tell
whether a future change reintroduces it. The pattern to copy is
`entityNamesDoNotTriggerTheFirewall` in `Tests/CoreGraphTests/BeliefEngineTests.swift`.

When a fix has **two independent guards**, assert each separately. A single test passing because
of guard A cannot tell you that guard B was quietly deleted.

## Stores are temporary and unique

`Store.open` against a fresh `NSTemporaryDirectory()` path with a UUID. Never touch
`~/Library/Application Support/OpenCore` from a test.

## Do not test the mechanism, test the guarantee

The interesting assertions here are about the trust stack: objects survive derived-layer
deletion, retracted claims are preserved rather than removed, unmeasured confidence round-trips
as `nil`, sensitive domains stay blocked. Those are what must never regress.
