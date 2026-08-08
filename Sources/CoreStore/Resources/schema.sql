-- OpenCore schema, migration 1.
--
-- Layout follows the trust stack: sources produce objects, objects yield evidence,
-- evidence supports claims, claims resolve into beliefs, and every query that reads
-- any of it leaves a receipt.
--
-- Two rules the schema itself enforces:
--   1. Nothing derived is ever the only copy of anything. Drop every table below
--      `object` and `opencore rebuild` reconstructs them. Objects are the floor.
--   2. Nothing is deleted to record a change of mind. Retraction and supersession
--      are columns, not DELETEs, because "what did you believe in March" has to
--      stay answerable.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS source (
    id                TEXT PRIMARY KEY,
    kind              TEXT NOT NULL,
    handle            TEXT NOT NULL,
    display_name      TEXT NOT NULL,
    default_authority INTEGER NOT NULL,
    default_domain    TEXT NOT NULL,
    last_synced_at    REAL,
    sync_cursor       TEXT,
    UNIQUE (kind, handle)
);

-- ---------------------------------------------------------------------------
-- Objects — the immutable floor
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS object (
    id           TEXT PRIMARY KEY,
    source_id    TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL,
    external_id  TEXT NOT NULL,
    title        TEXT NOT NULL,
    text         TEXT NOT NULL,
    uri          TEXT,
    authored_at  REAL,
    ingested_at  REAL NOT NULL,
    content_hash TEXT NOT NULL,
    domain       TEXT NOT NULL,
    authority    INTEGER NOT NULL,
    metadata     TEXT NOT NULL DEFAULT '{}',
    UNIQUE (source_id, kind, external_id)
);

CREATE INDEX IF NOT EXISTS idx_object_authored ON object(authored_at DESC);
CREATE INDEX IF NOT EXISTS idx_object_domain   ON object(domain);
CREATE INDEX IF NOT EXISTS idx_object_kind     ON object(kind);

-- BM25 over object text. `content=` makes this an external-content index: the text
-- is not duplicated, FTS5 reads it from `object` via rowid.
CREATE VIRTUAL TABLE IF NOT EXISTS object_fts USING fts5(
    title,
    text,
    content = 'object',
    content_rowid = 'rowid',
    tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS object_fts_insert AFTER INSERT ON object BEGIN
    INSERT INTO object_fts(rowid, title, text) VALUES (new.rowid, new.title, new.text);
END;

CREATE TRIGGER IF NOT EXISTS object_fts_delete AFTER DELETE ON object BEGIN
    INSERT INTO object_fts(object_fts, rowid, title, text) VALUES ('delete', old.rowid, old.title, old.text);
END;

CREATE TRIGGER IF NOT EXISTS object_fts_update AFTER UPDATE ON object BEGIN
    INSERT INTO object_fts(object_fts, rowid, title, text) VALUES ('delete', old.rowid, old.title, old.text);
    INSERT INTO object_fts(rowid, title, text) VALUES (new.rowid, new.title, new.text);
END;

-- Embeddings live beside objects rather than inside them, so a model swap is a
-- DELETE plus re-embed and never touches the floor. `model` is part of the key
-- because two embedders' vectors must never end up in one similarity search.
CREATE TABLE IF NOT EXISTS object_vector (
    object_id  TEXT NOT NULL REFERENCES object(id) ON DELETE CASCADE,
    model      TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    vector     BLOB NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (object_id, model)
);

-- ---------------------------------------------------------------------------
-- Evidence
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS evidence (
    id           TEXT PRIMARY KEY,
    object_id    TEXT NOT NULL REFERENCES object(id) ON DELETE CASCADE,
    range_start  INTEGER,
    range_end    INTEGER,
    snippet      TEXT NOT NULL,
    authority    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_evidence_object ON evidence(object_id);

-- ---------------------------------------------------------------------------
-- Entities
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS entity (
    id             TEXT PRIMARY KEY,
    kind           TEXT NOT NULL,
    canonical_name TEXT NOT NULL,
    domain         TEXT NOT NULL,
    first_seen_at  REAL NOT NULL,
    last_seen_at   REAL NOT NULL,
    UNIQUE (kind, canonical_name)
);

CREATE TABLE IF NOT EXISTS entity_alias (
    entity_id  TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
    surface    TEXT NOT NULL,
    confidence REAL NOT NULL,
    PRIMARY KEY (surface, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_alias_surface ON entity_alias(surface);

-- Typed relationships between entities. Distinct from `claim` because an edge is
-- structural and cheap to traverse, while a claim carries evidence and time.
CREATE TABLE IF NOT EXISTS edge (
    source_entity TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
    relation      TEXT NOT NULL,
    target_entity TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
    weight        REAL NOT NULL DEFAULT 1.0,
    claim_id      TEXT,
    PRIMARY KEY (source_entity, relation, target_entity)
);

CREATE INDEX IF NOT EXISTS idx_edge_target ON edge(target_entity, relation);

-- ---------------------------------------------------------------------------
-- Claims — bitemporal
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS claim (
    id            TEXT PRIMARY KEY,
    subject       TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
    predicate     TEXT NOT NULL,
    object_entity TEXT REFERENCES entity(id) ON DELETE SET NULL,
    literal       TEXT,
    confidence    REAL NOT NULL,
    authority     INTEGER NOT NULL,
    derivation    TEXT NOT NULL,
    domain        TEXT NOT NULL,

    -- valid time: when the fact held in the world
    valid_from    REAL,
    valid_to      REAL,
    -- transaction time: when OpenCore held it
    observed_at   REAL NOT NULL,
    retracted_at  REAL,

    claim_key     TEXT NOT NULL,
    CHECK (object_entity IS NOT NULL OR literal IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_claim_key       ON claim(claim_key);
CREATE INDEX IF NOT EXISTS idx_claim_subject   ON claim(subject, predicate);
CREATE INDEX IF NOT EXISTS idx_claim_current   ON claim(retracted_at) WHERE retracted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_claim_validtime ON claim(valid_from, valid_to);

-- A claim's evidence, with stance. Counter-evidence is a row here, not an absence.
CREATE TABLE IF NOT EXISTS claim_evidence (
    claim_id    TEXT NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
    evidence_id TEXT NOT NULL REFERENCES evidence(id) ON DELETE CASCADE,
    stance      TEXT NOT NULL,
    weight      REAL NOT NULL DEFAULT 1.0,
    PRIMARY KEY (claim_id, evidence_id)
);

CREATE INDEX IF NOT EXISTS idx_claimev_evidence ON claim_evidence(evidence_id);
CREATE INDEX IF NOT EXISTS idx_claimev_stance   ON claim_evidence(claim_id, stance);

-- ---------------------------------------------------------------------------
-- Contradictions and beliefs
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS contradiction (
    id          TEXT PRIMARY KEY,
    claim_a     TEXT NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
    claim_b     TEXT NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,
    resolution  TEXT NOT NULL,
    winner      TEXT REFERENCES claim(id) ON DELETE SET NULL,
    detected_at REAL NOT NULL,
    reason      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_contradiction_open ON contradiction(resolution) WHERE resolution = 'unresolved';

-- Append-only. One row per version; the current belief for a key is MAX(version).
CREATE TABLE IF NOT EXISTS belief (
    id           TEXT PRIMARY KEY,
    claim_key    TEXT NOT NULL,
    version      INTEGER NOT NULL,
    claim_id     TEXT NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
    confidence   REAL NOT NULL,
    authority    INTEGER NOT NULL,
    valid_from   REAL,
    valid_to     REAL,
    observed_at  REAL NOT NULL,
    retracted_at REAL,
    supersedes   TEXT REFERENCES belief(id) ON DELETE SET NULL,
    reason       TEXT NOT NULL,
    decided_at   REAL NOT NULL,
    UNIQUE (claim_key, version)
);

CREATE INDEX IF NOT EXISTS idx_belief_key     ON belief(claim_key, version DESC);
CREATE INDEX IF NOT EXISTS idx_belief_decided ON belief(decided_at DESC);

CREATE TABLE IF NOT EXISTS correction (
    id                TEXT PRIMARY KEY,
    superseded_claim  TEXT REFERENCES claim(id) ON DELETE SET NULL,
    asserted_claim    TEXT NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
    authority         INTEGER NOT NULL,
    reason            TEXT NOT NULL,
    prior_failure     TEXT,
    created_at        REAL NOT NULL
);

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS event (
    id          TEXT PRIMARY KEY,
    subject     TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
    verb        TEXT NOT NULL,
    detail      TEXT NOT NULL,
    occurred_at REAL NOT NULL,
    domain      TEXT NOT NULL,
    authority   INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_event_time    ON event(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_event_subject ON event(subject, occurred_at DESC);

-- ---------------------------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS receipt (
    id                      TEXT PRIMARY KEY,
    query                   TEXT NOT NULL,
    query_class             TEXT NOT NULL,
    domains_admitted        TEXT NOT NULL,
    domains_blocked         TEXT NOT NULL,
    stages                  TEXT NOT NULL,
    objects_searched        INTEGER NOT NULL,
    objects_retrieved       INTEGER NOT NULL,
    evidence_admitted       INTEGER NOT NULL,
    claims_consulted        INTEGER NOT NULL,
    contradictions_surfaced INTEGER NOT NULL,
    model                   TEXT,
    objects_transmitted     INTEGER NOT NULL,
    -- NULL means not measured. It must never be written as a plausible default.
    confidence              REAL,
    created_at              REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_receipt_created ON receipt(created_at DESC);

-- Which evidence an answer actually used, so `opencore trace <receipt>` can walk
-- backwards from a sentence to the commit it came from.
CREATE TABLE IF NOT EXISTS receipt_evidence (
    receipt_id  TEXT NOT NULL REFERENCES receipt(id) ON DELETE CASCADE,
    evidence_id TEXT NOT NULL REFERENCES evidence(id) ON DELETE CASCADE,
    rank        INTEGER NOT NULL,
    score       REAL NOT NULL,
    PRIMARY KEY (receipt_id, evidence_id)
);

CREATE TABLE IF NOT EXISTS receipt_claim (
    receipt_id TEXT NOT NULL REFERENCES receipt(id) ON DELETE CASCADE,
    claim_id   TEXT NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
    PRIMARY KEY (receipt_id, claim_id)
);

-- ---------------------------------------------------------------------------
-- Migrations
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS schema_migration (
    version    INTEGER PRIMARY KEY,
    applied_at REAL NOT NULL
);
