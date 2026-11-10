-- Files in this directory are copied into consuming components and executed in
-- filename order. Two rules follow from that:
--
--   1. Plain SQL only. No psql meta-commands (\i, \ir, \set, ...) — the runner
--      sends file contents straight to the server, which cannot parse them.
--   2. The numeric prefix is the install order, and it is load-bearing:
--      1.02 (function) must precede 1.03 (trigger), and 1.04 (sent_at column)
--      must precede 1.05 (the partial index whose predicate references it).
--
-- Every file is idempotent, so the whole set is safe to re-run.
--
-- Table names are unqualified: the caller must set search_path to the target
-- tenant schema. 1.02 is the exception — it creates into public explicitly and
-- needs CREATE on public.
CREATE TABLE IF NOT EXISTS event_outbox (
    id UUID NOT NULL PRIMARY KEY,
    data JSONB NOT NULL,
    sent_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_event_outbox_data_gin ON event_outbox USING GIN (data);