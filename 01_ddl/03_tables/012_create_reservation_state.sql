-- The last known state of a reservation as the events of the commercial domain told it (HU-CSH-002 plan D-12, DP-D2-12).
-- It lets the consumer order the events of one reservation and recognise an older one; it is not a history. The ids belong
-- to another domain: plain columns with no foreign key (Annex J.3.4).
CREATE TABLE cash_reporting.reservation_state (
    reservation_state_id   uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id              uuid,
    reservation_id         text,
    status                 text,
    -- null until the reservation is confirmed
    financial_situation    text,
    -- the newest event applied: an older one is ignored
    last_event_occurred_at timestamptz,
    updated_at             timestamptz,
    CONSTRAINT pk_reservation_state PRIMARY KEY (reservation_state_id),
    CONSTRAINT uq_reservation_state_tenant_reservation UNIQUE (tenant_id, reservation_id),
    CONSTRAINT chk_reservation_state_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_reservation_state_reservation_required CHECK (reservation_id IS NOT NULL AND btrim(reservation_id) <> ''),
    CONSTRAINT chk_reservation_state_status_required CHECK (status IS NOT NULL AND btrim(status) <> ''),
    CONSTRAINT chk_reservation_state_updated_at_required CHECK (updated_at IS NOT NULL)
);
