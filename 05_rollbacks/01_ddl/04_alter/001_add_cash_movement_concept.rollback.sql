ALTER TABLE cash_reporting.cash_movement
    DROP CONSTRAINT chk_cash_movement_concept_length,
    DROP CONSTRAINT chk_cash_movement_concept_required;
ALTER TABLE cash_reporting.cash_movement DROP COLUMN concept;
