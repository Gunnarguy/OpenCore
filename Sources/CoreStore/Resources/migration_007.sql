-- Deletion markers prevent an already prepared phone answer from recreating a thread
-- after its owner deletes it. The key is a one-way digest of the scoped thread identity;
-- it contains no conversation text and is deliberately not tied to the deleted row by FK.
-- This is primary state: exports include it and rebuilds must never clear it.
CREATE TABLE IF NOT EXISTS companion_thread_tombstone (
    id TEXT PRIMARY KEY NOT NULL,
    deleted_at REAL NOT NULL,
    -- Set only inside the deleting transaction; the trigger consumes it before commit.
    pending_delete_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_companion_pending_delete
    ON companion_thread_tombstone(pending_delete_id) WHERE pending_delete_id IS NOT NULL;

-- A version-six writer that was already open when this migration ran must not bypass
-- the new deletion marker. It receives a SQLite error instead of deleting silently.
CREATE TRIGGER IF NOT EXISTS companion_thread_guard_delete
BEFORE DELETE ON conversation
WHEN typeof(OLD.id) = 'text' AND substr(OLD.id, 1, 9) = 'phone-v1:'
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1 FROM companion_thread_tombstone WHERE pending_delete_id = OLD.id
    ) THEN RAISE(ABORT, 'phone thread deletion requires the current OpenCore store') END;
    UPDATE companion_thread_tombstone SET pending_delete_id = NULL WHERE pending_delete_id = OLD.id;
END;
