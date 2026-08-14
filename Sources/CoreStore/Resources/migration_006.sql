-- Migration 6 — an object's own history, so the floor is actually a floor.
--
-- THE BUG THIS FIXES, measured 2026-08-12 on the real store. Before a routine `rebuild`: one
-- contradiction, MMT-2025 status, `dormant` superseded by `active`, plus a belief at v2 reading
-- "changed from 'dormant' to 'active'". After: contradiction table empty, 43 beliefs all at
-- version 1, all reading "first evidence for this slot". The only change of mind in the entire
-- store, and the only demonstration of the bitemporal design, destroyed by a maintenance
-- command that reported success.
--
-- WHY IT HAPPENED. Objects were upserted in place: one row per (source, kind, externalID), and
-- `ON CONFLICT DO UPDATE` overwrote title, text, authored_at, metadata and content_hash. The
-- `dormant` reading came from an older `pushed_at` that a later sync overwrote. So re-deriving
-- from objects could only ever produce `active`. The claim layer held history the object layer
-- did not.
--
-- That contradicts the project's first non-negotiable directly: "Objects are the floor. Nothing
-- derived may be the only copy of anything." The contradiction row *was* the only copy of the
-- fact that MMT-2025 used to be dormant. The invariant was not drifted from; it was never
-- achievable, because a mutable source has history and the floor did not record it.
--
-- WHY A SIDE TABLE rather than versioning `object` itself. `ObjectID` is derived from
-- (source, kind, externalID) and is referenced by chunk, evidence and event. Making it unique
-- per version would change the identity of every row above it, and re-point every foreign key,
-- to solve a problem that only needs the superseded *content* kept. Current objects stay
-- exactly one row each, so every existing query is untouched.
--
-- THIS TABLE IS PRIMARY DATA, NOT DERIVED. Nothing can reconstruct it: it is what an object
-- used to say. It must never appear in `Store.derivedTables`, `rebuild` must never clear it,
-- and the exporter must include it. The export completeness test enforces the last one.
--
-- WHAT THIS CANNOT DO: recover history already lost. Every object updated before today
-- overwrote its previous content and there is nothing to restore. MMT-2025's `dormant` reading
-- is gone permanently. This stops the next one from being lost, and that is all.

CREATE TABLE IF NOT EXISTS object_version (
    object_id TEXT NOT NULL,
    -- Part of the key: an object that flips back to a previous content hash is the same version
    -- returning, not a third one. `INSERT OR IGNORE` then makes re-recording it a no-op.
    content_hash TEXT NOT NULL,
    title TEXT NOT NULL,
    text TEXT NOT NULL,
    uri TEXT,
    authored_at REAL,
    ingested_at REAL NOT NULL,
    domain TEXT NOT NULL,
    authority INTEGER NOT NULL,
    metadata TEXT NOT NULL,
    -- When this content stopped being current. The ordering key for replaying history, and the
    -- only field here that is not a copy of what the object row held.
    superseded_at REAL NOT NULL,
    PRIMARY KEY (object_id, content_hash),
    FOREIGN KEY (object_id) REFERENCES object(id) ON DELETE CASCADE
);

-- Replay is chronological, per object and overall, so both orderings are served.
CREATE INDEX IF NOT EXISTS idx_object_version_replay ON object_version(superseded_at ASC);
CREATE INDEX IF NOT EXISTS idx_object_version_object ON object_version(object_id, superseded_at ASC);
