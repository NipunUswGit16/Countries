-- Partial index used by the publisher's "unpublished set" read query.
--
-- Predicate matches the FetchEvents read: WHERE sent_at IS NULL. Postgres
-- maintains the index as rows transition from NULL -> set on MarkPublished;
-- rows with sent_at set don't appear in the index and don't cost INSERT/UPDATE
-- write-amp once they're marked.
--
-- Runs after 1.04_event_outbox_sent_at_column.sql, which adds the column this
-- predicate references.
--
-- This file is intended to be run by an operator against an existing tenant
-- schema (e.g. via psql with search_path set). The publisher's installer
-- (internal/postgres/trigger/installer.go EnsureUnpublishedIndex) creates an
-- equivalent index per-schema CONCURRENTLY at startup; this file is provided
-- as the canonical reference and for one-off operator installs.
--
-- Cannot use CONCURRENTLY here because callers may run this file inside a
-- transaction (component sqlrunners typically wrap the whole set in one, and
-- local/event_outbox_notify_install_all.sql wraps its DDL in a DO block). The
-- publisher's per-schema install path does use CONCURRENTLY, since it issues
-- each statement in auto-commit.
--
-- Idempotent via IF NOT EXISTS.
CREATE INDEX IF NOT EXISTS idx_event_outbox_unpublished
  ON event_outbox (id)
  WHERE sent_at IS NULL;
