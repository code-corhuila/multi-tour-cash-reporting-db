-- Every consumed event id, stored in the same transaction as its effect (ADR-004 D10; plan D-04). The key is per
-- tenant, like the idempotency table: a unique violation means the event is a repeat. HU-CSH-003 reuses it.
CREATE TABLE cash_reporting.processed_event (
    processed_event_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          uuid,
    event_id           uuid,
    event_type         text,
    processed_at       timestamptz,
    CONSTRAINT pk_processed_event PRIMARY KEY (processed_event_id),
    CONSTRAINT uq_processed_event_tenant_event UNIQUE (tenant_id, event_id),
    CONSTRAINT chk_processed_event_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_processed_event_event_id_required CHECK (event_id IS NOT NULL),
    CONSTRAINT chk_processed_event_event_type_required CHECK (event_type IS NOT NULL AND btrim(event_type) <> ''),
    CONSTRAINT chk_processed_event_processed_at_required CHECK (processed_at IS NOT NULL)
);
