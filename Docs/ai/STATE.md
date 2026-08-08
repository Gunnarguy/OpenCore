# Current State

Updated: 2026-08-08 11:00 PT
Branch/worktree: `main`, primary checkout (not a linked worktree)
Last verified commit: `95bcd96`

## Objective

Build the **MCP client** so OpenCore can consume any MCP server as a source. It is one of only
two items classified `force multiplier` on the roadmap, and it makes most of the remaining
connector work unnecessary.

## Status

v0.2 is pushed and working end to end. The engine ingests GitHub, local files, Calendar,
Reminders and Notes; chunks and embeds on device; retrieves with dense + BM25 fused by RRF then
MMR; and serves MCP over stdio. Nothing is in flight — the tree is clean and the next objective
has not been started.

## Completed

- v0.1 (`43c1581`): four primitives, bitemporal claims, ordinal authority, SQLite + FTS5,
  contradiction detection, versioned beliefs, domain firewall, receipts, CLI, macOS app.
- v0.2 (`80fa667`): chunks + vectors (migration 2), NLContextualEmbedding on device,
  `PassageSearch` with RRF and MMR, filesystem/Calendar/Reminders/Notes connectors,
  `IngestPipeline`, MCP server over stdio, external-caller domain policy.
- `95bcd96`: roadmap moved to Notion; force multipliers identified.

## Active Constraints

- **Objects are the floor.** Nothing derived may be the only copy of anything. If a change
  makes `opencore rebuild` unable to reconstruct a layer, the change is wrong.
- **Zero external dependencies.** Including the MCP server. This is why JSON-RPC is hand-rolled.
- **Unmeasured stays `nil`.** Never write a plausible default into a receipt field.
- **Authority never multiplies.** It is an ordinal tier, not a probability.
- No accuracy number may be quoted anywhere; none has been measured.

## Working Set

- `Sources/CoreIngest/Connector.swift`: the protocol an MCP client connector must conform to.
- `Sources/CoreMCP/JSONRPC.swift`: `JSONValue` and the RPC types are reusable for a client;
  the server currently owns them.
- `Sources/CoreMCP/MCPServer.swift`: the server side, and the reference for framing and
  the external-caller policy a client must respect in reverse.
- `Sources/CoreGraph/IngestPipeline.swift`: whatever the client produces flows through here.
- `Docs/MCP.md`: the protocol notes, including the two rules that must not break.

## Verification

Last run 2026-08-08, all green:

- `swift build --scratch-path /private/tmp/opencore-build` -> builds clean
- `swift test --scratch-path /private/tmp/opencore-build` -> 24 tests passed (7 + 17)
- `xcodebuild ... -scheme OpenCore` -> BUILD SUCCEEDED
- `opencore rebuild` -> 691 objects, 966 chunks, 38 entities, 82 claims (identical to pre-rebuild)
- `opencore embed` -> 966/966 passages, 25s on device
- MCP handshake by hand -> initialize, tools/list, tools/call all correct; medical query
  correctly blocked for an external caller

## Blockers / Unknowns

- **Unknown:** whether the Calendar, Reminders and Notes connectors work against real data.
  They compile and are `[source]`-level only. *Verify:* run `sync calendar` from the built
  macOS app (not the CLI — EventKit needs Info.plist usage strings the SwiftPM binary lacks)
  and check `opencore doctor` object counts.
- **Known gap, not a blocker:** the shipped MCP server implements protocol `2025-11-25`.
  `2026-07-28` removed the `initialize` handshake, made `server/discover` mandatory, and
  requires `resultType` on every result. Tracked as Critical in Notion.
- **Known gap:** only GitHub produces claims. Files, notes, calendar and reminders are
  retrievable but invisible to `claims`, `contradictions`, and `memory log`.

## Exact Next Action

Create `Sources/CoreIngest/MCPClientConnector.swift`: a `Connector` that launches a configured
MCP server as a subprocess over stdio, calls `tools/list`, invokes the read-only tools it
advertises, and maps each result into a `CoreObject` with `authority: .thirdPartyRecord` and a
domain chosen per-server at configuration time. Reuse `JSONValue` from `CoreMCP` by moving the
RPC types into a shared location both the client and server can import.
