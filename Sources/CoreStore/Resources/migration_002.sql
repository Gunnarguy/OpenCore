-- Migration 2 — passages.
--
-- v1 treated an object as the retrieval unit, which is right for a commit message and
-- wrong for a 40-page document. A chunk is a passage of an object: small enough to embed
-- meaningfully, large enough to stand as a citation on its own.
--
-- Chunks are derived, so they obey the same rule as everything else above `object`:
-- delete them all and `opencore rebuild` puts them back.

CREATE TABLE IF NOT EXISTS chunk (
    id          TEXT PRIMARY KEY,
    object_id   TEXT NOT NULL REFERENCES object(id) ON DELETE CASCADE,
    ordinal     INTEGER NOT NULL,
    text        TEXT NOT NULL,
    -- Offsets into `object.text`, so a chunk can always be located in its parent and
    -- expanded back to surrounding context at answer time.
    range_start INTEGER NOT NULL,
    range_end   INTEGER NOT NULL,
    token_estimate INTEGER NOT NULL,
    UNIQUE (object_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_chunk_object ON chunk(object_id, ordinal);

CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
    text,
    content = 'chunk',
    content_rowid = 'rowid',
    tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS chunk_fts_insert AFTER INSERT ON chunk BEGIN
    INSERT INTO chunk_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TRIGGER IF NOT EXISTS chunk_fts_delete AFTER DELETE ON chunk BEGIN
    INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;

CREATE TRIGGER IF NOT EXISTS chunk_fts_update AFTER UPDATE ON chunk BEGIN
    INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    INSERT INTO chunk_fts(rowid, text) VALUES (new.rowid, new.text);
END;

-- Vectors are keyed by model so two embedders' output can never end up in one
-- similarity search. Swapping models is DELETE WHERE model = ? followed by a re-embed,
-- and it never touches the floor.
CREATE TABLE IF NOT EXISTS chunk_vector (
    chunk_id   TEXT NOT NULL REFERENCES chunk(id) ON DELETE CASCADE,
    model      TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    -- Float32 little-endian, L2-normalised at write time so similarity is a dot product.
    vector     BLOB NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (chunk_id, model)
);

CREATE INDEX IF NOT EXISTS idx_chunk_vector_model ON chunk_vector(model);

-- Which embedding model the store is currently using, and whether every chunk has one.
-- Exists so `opencore doctor` can say "3,412 of 3,500 chunks embedded" rather than
-- leaving a half-built index to be discovered by a silently bad search result.
CREATE TABLE IF NOT EXISTS embedding_run (
    model       TEXT PRIMARY KEY,
    dimensions  INTEGER NOT NULL,
    chunks_done INTEGER NOT NULL,
    started_at  REAL NOT NULL,
    finished_at REAL
);
