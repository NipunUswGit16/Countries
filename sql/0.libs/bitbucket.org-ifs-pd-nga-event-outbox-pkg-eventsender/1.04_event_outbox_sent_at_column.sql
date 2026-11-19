-- Adds the sent_at column to event_outbox. The publisher sets sent_at = now()
-- after Kafka acks the publish for a row; rows with sent_at IS NULL are
-- considered unpublished.
--
-- Nullable, no default: this is a metadata-only operation on PostgreSQL 11+,
-- so it does not rewrite the table. INSERTs queue briefly behind the
-- ACCESS EXCLUSIVE lock and proceed against the new schema with sent_at = NULL,
-- which is the correct unpublished state.
--
-- Idempotent via IF NOT EXISTS.
ALTER TABLE event_outbox
  ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ;
