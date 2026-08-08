---
paths:
  - "Sources/CoreStore/**/*.swift"
  - "Sources/CoreStore/Resources/*.sql"
---

# CoreStore rules

**Every SQL string in this project lives in this module.** A layer above that needs data gets a
typed method here. If you are about to write SQL in `CoreSearch`, `CoreGraph`, or the CLI, add
the method here instead — that boundary is what keeps the storage substrate replaceable.

## Migrations

- Migrations are append-only. **Never renumber or edit a shipped migration.** A store in the
  wild has already applied it, and rewriting a schema's history produces two databases that
  claim the same version and disagree.
- A new migration is a new `.sql` in `Resources/` plus an entry in `Database.migrations`.
- Migration 1 always runs; its statements are all `IF NOT EXISTS`.

## Schema invariants

- **Nothing below `object` may be the only copy of anything.** Dropping every derived table and
  running `opencore rebuild` must reconstruct them. If a change breaks that, the change is wrong.
- Deleting an object must cascade to its chunks, evidence, and vectors. Orphaned rows are
  retrievable with nothing to cite.
- `chunk_vector` is keyed by `(chunk_id, model)`. Two embedders' vectors must never be
  comparable in one query.
- Nullable means unmeasured. `receipt.confidence` is `NULL` on purpose and must stay that way
  until a calibration exists.

## Concurrency

`Database` is an actor holding a non-`Sendable` `Connection`. The connection's methods are
synchronous so `write { }` can issue several statements with no suspension point between them.
That is the only reason `BEGIN`/`COMMIT` is actually atomic here. **Do not make the transaction
closure `async`** — an await inside it lets other work interleave mid-transaction.

## Binding

Use `SQLValue`, never string interpolation into SQL. The labelled initialisers
(`SQLValue(text:)`, `SQLValue(date:)`) exist so an optional becomes `NULL` rather than the
four-character string `"nil"`.
