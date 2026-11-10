-- Per-schema AFTER INSERT trigger on event_outbox that fires the shared
-- public.notify_event_outbox_insert() function. Run this once per tenant
-- schema (after the schema and event_outbox table exist and the shared
-- function from 1.02_event_outbox_notify_function.sql has been installed).
--
-- DROP first to keep this script idempotent across re-runs.
DROP TRIGGER IF EXISTS event_outbox_notify_trigger ON event_outbox;

CREATE TRIGGER event_outbox_notify_trigger
AFTER INSERT ON event_outbox
FOR EACH ROW EXECUTE FUNCTION public.notify_event_outbox_insert();
