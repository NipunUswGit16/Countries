-- Shared notification function used by per-schema triggers on the
-- event_outbox table. Lives in the public schema so it can be referenced from
-- every tenant schema's trigger without duplicating the function definition.
--
-- Channel name is per-schema: "outbox_events_<schema>". This lets the
-- publisher subscribe selectively (one LISTEN per active tenant on a single
-- shared connection) and avoids fan-out across unrelated tenants. The
-- prefix must match the publisher's OutboxNotifyChannelPrefix config.
--
-- Payload is only schema/table (no row id) so it is identical for every row
-- in a bulk INSERT. PostgreSQL then coalesces multiple pg_notify calls on the
-- same channel within one transaction into a single listener delivery when
-- the payloads match (NOTIFY semantics). The publisher's routing key is the
-- channel name (notification.Channel); the publisher drains unpublished rows
-- (sent_at IS NULL) for that schema.
CREATE OR REPLACE FUNCTION public.notify_event_outbox_insert()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        'outbox_events_' || TG_TABLE_SCHEMA,
        json_build_object(
            'schema', TG_TABLE_SCHEMA,
            'table',  TG_TABLE_NAME
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
