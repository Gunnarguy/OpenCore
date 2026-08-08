---
paths:
  - "Sources/CoreMCP/**/*.swift"
---

# CoreMCP rules

## stdout is sacred

**Nothing but MCP messages may reach stdout anywhere in this call path.** Every log line goes
to stderr. A stray `print` corrupts the JSON-RPC stream and the symptom is a client that hangs,
not an error anyone can find. Messages must not contain embedded newlines.

## Notifications get no response

A request with no `id` is a notification. Replying to one is a protocol violation that some
clients treat as fatal. `RPCRequest.isNotification` exists for this check; use it.

## An MCP caller is not the user

`sensitiveDomainsUnlockable` defaults to `false` and must stay that way. Locally, naming a
sensitive domain in a query opens it, because a person typing "what did my doctor say" is
consenting by asking. Over MCP the query text is written by a model, and a model asking about a
diagnosis is not consent.

A query classifying as sensitive is **re-based to `.project`**, not refused, so the caller still
gets a useful answer from what it is allowed to see. The receipt records the block either way.

## Protocol version

The shipped server implements `2025-11-25`. `2026-07-28` is a breaking revision that removes the
`initialize` handshake entirely, makes `server/discover` mandatory, requires `resultType` on
every result, drops `ping` and `logging/setLevel`, and requires `ttlMs` / `cacheScope` on list
results. Upgrading is tracked as Critical in the Notion roadmap. Do not partially adopt it:
a half-migrated server is worse than one that is honestly a version behind.

## Zero dependencies

Do not add the official MCP Swift SDK. The hand-rolled JSON-RPC is a deliberate decision
recorded in `Docs/ai/DECISIONS.md`, not an oversight waiting to be corrected.
