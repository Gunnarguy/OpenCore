# MCP, both directions

OpenCore is an MCP **server** (other tools query your history) and an MCP **client** (any of
~9,650 registry servers becomes a source). The client is the more consequential half: rather
than hand-writing an integration per service, OpenCore speaks the protocol those services
already speak.

---

# Part 1 — OpenCore as an MCP client

## Three commands

```bash
opencore mcp-source discover --command some-mcp-server
```

Connects, lists every tool with a read-only advisory, and **calls nothing**. Run this first.

```bash
opencore mcp-source add work --command some-mcp-server --tool list_issues --tool get_issue --domain work
```

```bash
opencore sync mcp work
```

## The tool policy

An MCP server advertises whatever tools it likes, and plenty of them **write**:
`send_message`, `create_issue`, `delete_file`. A sync that guessed wrong would not return a bad
answer, it would send an email.

So: **default-deny with an explicit allowlist**, and no automatic path around it.

- The server's `readOnlyHint` is **not sufficient**. The specification says plainly that
  annotations come from an untrusted server and must not drive safety decisions.
- Name heuristics are **not sufficient**. `get_message` reads; `get_approval` might send one.
- The advisory in `discover` exists to shorten a human's review list. The call path never
  consults it. `[source]` — `MCPClientConnector`

`[test]` — a source with no allowlisted tools throws before launching anything.

That friction is the feature. Nothing gets called because it looked safe.

## Credentials

`--env NAME` forwards an environment variable **by name**. The value is read from your
environment when the server launches and is never written to the database, a log line, or the
repository. `[test]` — the serialised config never contains a value, and only declared
variables reach the child process; the rest of your environment is not inherited.

A declared-but-unset variable is reported rather than passed as empty, because an empty
credential produces a confusing auth error instead of an obvious missing-variable one.

## What content from a server is

Third-party text OpenCore did not author. It enters at `Authority.thirdPartyRecord` — below
anything the user wrote — in the `personal` domain by default, which a project query cannot
read. `[test]`

It is stored as evidence to be cited, never as anything to be acted on. Text inside a tool
result that looks like an instruction is simply text.

## Protocol versions

`initialize` is tried first (`2025-11-25`). If the server reports the method does not exist,
`server/discover` is tried instead, which is how a `2026-07-28` stateless server answers. The
newer specification explicitly endorses that probe on stdio. `[source]`

## Verified

`[measured]` 2026-08-08, against OpenCore's own MCP server, which had 6 tools then and has 8 now:
discovery listed 6 tools with advisories; a 3-tool allowlist produced 3 objects and 5 chunks; re-sync
reported `0 new, 0 changed, 3 unchanged`; `remove` cascaded all 3 objects away.

`[measured 2026-10-30]` Sources in the real store mostly hold no allowed tools and do not sync, so a
list of servers is not a list of working sources.

---

# Part 2 — OpenCore as an MCP server

This is where OpenCore stops being an app you look at and becomes something other tools
ask. An MCP client gets `core_ask` and `core_trace`, and can therefore cite *your* history
back to the commit it came from.

## Setup

```bash
swift build -c release
```

Then add to your MCP client's config (Claude Desktop, Claude Code, or any MCP client). The binary
loads its migrations from `OpenCore_CoreStore.bundle`, which has to sit beside it, and
`Docs/ai/RUNBOOK.md` has the install steps:

```json
{
  "mcpServers": {
    "opencore": {
      "command": "/absolute/path/to/opencore",
      "args": ["mcp"]
    }
  }
}
```

`[source]` A client keeps the binary it started with, so new work reaches a session only after the
binary is replaced and that client reconnects.

Verify it by hand before wiring it up — the server speaks newline-delimited JSON-RPC on
stdin/stdout:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' | .build/release/opencore mcp
```

## Tools

| Tool | Returns |
|---|---|
| `core_ask` | an answer assembled from claims, each marked observed or inferred, with evidence, counter-evidence, the passages that matched, and a receipt code. A named subject and the predicate asked about come first, and repeated rows collapse to one line that keeps all their evidence. A time phrase filters the answer to that window, see below |
| `core_search` | raw passages, dense + BM25 fused, filtered to a window when the query names one |
| `core_claims` | what OpenCore currently believes about one entity, one line per fact, with `×n` when several rows hold it |
| `core_contradictions` | conflicts and how each was settled |
| `core_changed` | what it learned or changed its mind about recently |
| `core_trace` | the exact evidence behind a previous `core_ask`, by receipt code |
| `core_dossier` | one entity's aliases, current beliefs, contradictions and timeline |
| `core_timeline` | events across admitted domains over a window; notes and calendar are personal, so they do not appear |

The 2026-08-09 eval scored the fused result lower with the dense leg than without it, so
the default runs the lexical leg alone.

**Time phrases.** [test] `core_ask` and `core_search` read "recently", "last week", "this month",
"in March", "in March last year", "in 2025", "since August", "since the start of the year", "since
2026-10-01", "since Monday", "the past 3 days", "the past year", "two weeks ago", "last night", "last
weekend" and "the last week of September" as a filter, in the machine's time zone. A question about
what happened is answered from the event log, grouped by subject. A question about a topic is
answered from passages dated inside the window. `core_search` reads no passages for a span with no
topic and says to use `core_ask`. Either way the reply states the days it read, says when a span was
chosen rather than defined, and gives the store's freshness by kind of source, with MCP sources as
`mcp`. A `Stale:` line means data is missing, so do not read it as a quiet period. Only sources the
caller may read are reported. A window's "chunks searched" counts the admitted chunks dated inside
it, and an answer that searched no text reports 0. Single dated days ("on October 12", "last
Monday"), future spans ("next week", "tonight", "this weekend"), ranges with two ends and a position
inside something undated ("the last week of the sprint") are not read, and those questions search
all of time. A count with a time phrase says so when it is not a count of the thing named.

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
- Which chunks were withheld is not reported: a blocked count is an existence oracle for a model.
- A belief's reason is withheld unless the claim it replaced is admitted too, because the sentence
  names the replaced value. `[test]`
- Freshness names kinds of source, never handles, and only ones holding something the caller may read.

Verified `[measured]`: asking `core_ask("what did my doctor say about my diagnosis")`
returns project claims with a receipt reading
`domains blocked: financial, medical, personal, relationship, work`.

To lift it — for a local agent you fully control — pass `--unsafe-expose-sensitive`. The
flag is named to be uncomfortable to type, which is the intended amount of friction. The app's
Settings has a matching toggle, whose reach over `restricted` is on the open hardening list.

Whether another tool is worth adding: not now. `DECISIONS.md`, 2026-10-31, records why.

## Transport notes

Hand-rolled JSON-RPC rather than the official Swift SDK, to keep the package's
zero-dependency guarantee. The stdio transport is newline-delimited JSON-RPC and the
surface needed here is five methods, so the SDK would cost a dependency and a
version-pinning surface to save a few hundred lines.

Protocol version `2025-11-25`, a spec behind `2026-07-28`. The upgrade is tracked as Critical in
Notion and has not started.

Two rules the implementation must never break `[source]`:

- **Nothing but MCP messages reaches stdout.** Every log line goes to stderr. A stray
  `print` anywhere in the call path corrupts the stream, and the symptom is a client that
  hangs rather than an error.
- **Notifications get no response, ever.** A request with no `id` is a notification;
  replying to one is a protocol violation some clients treat as fatal.
