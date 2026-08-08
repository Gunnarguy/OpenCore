# OpenCore as MCP infrastructure

This is where OpenCore stops being an app you look at and becomes something other tools
ask. An MCP client gets `core_ask` and `core_trace`, and can therefore cite *your* history
back to the commit it came from.

## Setup

```bash
swift build -c release
```

Then add to your MCP client's config (Claude Desktop, Claude Code, or any MCP client):

```json
{
  "mcpServers": {
    "opencore": {
      "command": "/absolute/path/to/OpenCore/.build/release/opencore",
      "args": ["mcp"]
    }
  }
}
```

Verify it by hand before wiring it up — the server speaks newline-delimited JSON-RPC on
stdin/stdout:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' | .build/release/opencore mcp
```

## Tools

| Tool | Returns |
|---|---|
| `core_ask` | an answer assembled from claims, each marked observed or inferred, with evidence, counter-evidence, and a receipt code |
| `core_search` | raw passages, dense + BM25 fused |
| `core_claims` | what OpenCore currently believes about one entity |
| `core_contradictions` | conflicts and how each was settled |
| `core_changed` | what it learned or changed its mind about recently |
| `core_trace` | the exact evidence behind a previous `core_ask`, by receipt code |

`core_ask` → `core_trace` is the pair that matters. An assistant can answer from your
history and then show the user the commits and documents that produced the answer.

## The boundary

**An MCP caller is not you.**

Locally, naming a sensitive domain in a query opens it, because a person typing *"what did
my doctor say"* is giving consent by asking. Over MCP the query text is written by a model,
and a model asking about your diagnosis is not consent.

So by default `sensitiveDomainsUnlockable` is false, and:

- No wording in a tool call reaches `medical`, `financial`, or `relationship` data.
- A query that *classifies* as sensitive is re-based to `project` rather than refused, so
  the caller gets a useful answer from the data it is allowed to see.
- The receipt records the block either way.

Verified `[measured]`: asking `core_ask("what did my doctor say about my diagnosis")`
returns project claims with a receipt reading
`domains blocked: financial, medical, personal, relationship, work`.

To lift it — for a local agent you fully control — pass `--unsafe-expose-sensitive`. The
flag is named to be uncomfortable to type, which is the intended amount of friction.

## Transport notes

Hand-rolled JSON-RPC rather than the official Swift SDK, to keep the package's
zero-dependency guarantee. The stdio transport is newline-delimited JSON-RPC and the
surface needed here is five methods, so the SDK would cost a dependency and a
version-pinning surface to save a few hundred lines.

Protocol version `2025-11-25`.

Two rules the implementation must never break `[source]`:

- **Nothing but MCP messages reaches stdout.** Every log line goes to stderr. A stray
  `print` anywhere in the call path corrupts the stream, and the symptom is a client that
  hangs rather than an error.
- **Notifications get no response, ever.** A request with no `id` is a notification;
  replying to one is a protocol violation some clients treat as fatal.
