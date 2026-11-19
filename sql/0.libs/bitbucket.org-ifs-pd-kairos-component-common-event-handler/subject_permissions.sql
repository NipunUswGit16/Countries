-- Lookup store read by the authorization sidecar (PDP) on every API call.
-- Shape is fixed by access-management ADR-0004 D3; the sidecar's query and this
-- DDL must stay in lockstep.
--
-- Identifiers are deliberately unquoted: Postgres folds them to lower case and
-- the reader looks them up folded. Quoting any of them here would make the
-- reader miss the table, which it reports as "tenant not provisioned" — a
-- silent deny rather than an error.
CREATE TABLE IF NOT EXISTS subject_permissions (
    subject_id     TEXT        NOT NULL,
    permission_key TEXT        NOT NULL,
    assignment_id  TEXT        NOT NULL, -- same key via 2 grants survives 1 revoke
    valid_from     TIMESTAMPTZ NULL,
    valid_until    TIMESTAMPTZ NULL
);

-- READ path: checks are always subject-first, and INCLUDE keeps the validity
-- window in the index leaf so the probe is an index-only scan.
-- fillfactor 90: rows are insert/delete only, never updated in place.
CREATE UNIQUE INDEX IF NOT EXISTS subject_permissions_read
    ON subject_permissions (subject_id, permission_key, assignment_id)
    INCLUDE (valid_from, valid_until)
    WITH (fillfactor = 90);

-- WRITE path: the handler deletes a whole assignment before re-inserting it.
CREATE INDEX IF NOT EXISTS subject_permissions_write
    ON subject_permissions (assignment_id);
