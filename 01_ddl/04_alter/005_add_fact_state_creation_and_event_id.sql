-- The domain of the dashboard needs two things the first version of the fact tables did not keep (HU-CSH-002 plan D-12):
-- the instant a reservation was created (the flow "created today" of the local day) and the id of the newest event applied
-- (it decides between two events with the same instant, so the result does not depend on the order of arrival).
-- Both are nullable: a row may exist before the creation event arrives.
ALTER TABLE cash_reporting.reservation_state
    ADD COLUMN created_at    timestamptz,
    ADD COLUMN last_event_id text;
ALTER TABLE cash_reporting.departure_state
    ADD COLUMN last_event_id text;
