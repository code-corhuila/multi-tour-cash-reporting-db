DROP INDEX cash_reporting.uq_cash_movement_reverses;
ALTER TABLE cash_reporting.cash_movement DROP CONSTRAINT fk_cash_movement_reverses;
ALTER TABLE cash_reporting.cash_movement
    DROP CONSTRAINT chk_cash_movement_reverses_income_or_refund,
    DROP CONSTRAINT uq_cash_movement_tenant_movement;
ALTER TABLE cash_reporting.cash_movement DROP COLUMN reverses_cash_movement_id;
ALTER TABLE cash_reporting.cash_movement DROP COLUMN reservation_id;
