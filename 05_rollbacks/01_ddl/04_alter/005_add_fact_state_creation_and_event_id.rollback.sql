ALTER TABLE cash_reporting.departure_state DROP COLUMN last_event_id;
ALTER TABLE cash_reporting.reservation_state
    DROP COLUMN last_event_id,
    DROP COLUMN created_at;
