# Project

## Purpose

An evidence-native store of one person's own digital history. Not "AI that remembers you" —
software that can state what it knows, why it believes it, where it came from, how confident it
is, and what changed its mind.

The distinguishing claim is **inspectability**, not memory. Competitors store a fact and
retrieve it. OpenCore stores the evidence, derives claims from it, notices when two claims
cannot both be true, records which one currently stands, and keeps the loser so you can ask
what it used to think.

## Primary user

One person: the author, over their own data. This is not multi-tenant and is not intended to
be. Design decisions that would be wrong for a product with users are frequently right here,
and the reverse.

## In scope

- Ingesting personal sources into content-addressed objects.
- Deriving entities, claims, events, contradictions and beliefs from those objects.
- Passage-level retrieval with domain admission enforced before ranking.
- Answering from stored claims with evidence and a receipt.
- Serving the store to other tools over MCP.

## Out of scope — decided, not pending

- A chatbot UI. The interesting surface is the receipt, not the conversation.
- Autonomous agents that act on the user's data.
- Cloud sync. The store is one SQLite file.
- Multi-user, teams, sharing.

These are recorded as `Dropped` in the Notion roadmap so they stop being reconsidered.

## Major constraints

- **Zero external Swift dependencies.** A personal knowledge store that stops building when a
  package moves is a personal knowledge store you lose. This is why JSON-RPC is hand-rolled
  rather than taken from the official MCP Swift SDK.
- **Local-first, genuinely.** Ingestion, chunking, embedding, retrieval and answering all run
  on device. `Receipt.objectsTransmitted` is `0` and must stay honest if that changes.
- **No unmeasured number may be presented as measured.** Receipt confidence is `nil`. Every
  retrieval constant carries a comment saying it was chosen rather than measured.

## Platforms

macOS 15+ for the package; the app targets macOS 15+ and is developed against macOS 27 /
Xcode 27 beta. Swift 6.2 tools, Swift 6 strict concurrency.

## Critical dependencies

None in the package graph. System frameworks only: `SQLite3`, `NaturalLanguage`
(`NLContextualEmbedding`), `EventKit`, `CryptoKit`, `SwiftUI`.

Developer tooling: Xcode 27 beta, `xcodegen` for the app project, `gh` for the GitHub token.

## Source-of-truth locations

| Truth | Lives in |
|---|---|
| Roadmap | **Notion**, db `7dc3bd42-1933-4d25-847a-5bc98acac3fc`, data source `546d4b56-a91a-4324-92e7-738c9637d8d0` |
| Architecture | `Docs/ARCHITECTURE.md` |
| Execution state | `Docs/ai/STATE.md` |
| Schema | `Sources/CoreStore/Resources/*.sql` — the migrations, not any prose about them |
| The user's data | `~/Library/Application Support/OpenCore/opencore.sqlite3` |

Credentials are never stored in the repo or the database. GitHub uses `GITHUB_TOKEN` or the
`gh` CLI's own keychain entry.
