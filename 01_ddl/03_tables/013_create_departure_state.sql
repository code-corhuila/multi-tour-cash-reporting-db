-- The last known state of a departure (HU-CSH-002 plan D-12, DP-D2-12): the indicator "upcoming services" counts the
-- departures that start today in the zone of the tenant (DP-DB4 by default). Plain ids, no foreign key to another domain.
CREATE TABLE cash_reporting.departure_state (
    departure_state_id     uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id              uuid,
    departure_id           text,
    status                 text,
    scheduled_start        timestamptz,
    last_event_occurred_at timestamptz,
    updated_at             timestamptz,
    CONSTRAINT pk_departure_state PRIMARY KEY (departure_state_id),
    CONSTRAINT uq_departure_state_tenant_departure UNIQUE (tenant_id, departure_id),
    CONSTRAINT chk_departure_state_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_departure_state_departure_required CHECK (departure_id IS NOT NULL AND btrim(departure_id) <> ''),
    CONSTRAINT chk_departure_state_status_required CHECK (status IS NOT NULL AND btrim(status) <> ''),
    CONSTRAINT chk_departure_state_updated_at_required CHECK (updated_at IS NOT NULL)
);
