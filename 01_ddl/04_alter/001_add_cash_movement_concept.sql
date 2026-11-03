-- The concept of a movement (plan D-06, AC-D1.10): free text of the operator, required for every type,
-- refund included, at most 200 characters (the -api trims it before it writes).
-- MIGRATION SAFETY: ADD COLUMN ... NOT NULL has no default, so it is valid only while cash_movement is
-- empty. This migration assumes an empty table: the database is deployed in no environment yet and every
-- test starts from an empty database. If rows ever existed, they must be migrated before this runs.
ALTER TABLE cash_reporting.cash_movement ADD COLUMN concept text NOT NULL;
ALTER TABLE cash_reporting.cash_movement
    ADD CONSTRAINT chk_cash_movement_concept_required CHECK (btrim(concept) <> ''),
    ADD CONSTRAINT chk_cash_movement_concept_length CHECK (char_length(concept) <= 200);
