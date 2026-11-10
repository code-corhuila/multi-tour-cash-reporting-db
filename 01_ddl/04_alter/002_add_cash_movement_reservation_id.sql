-- Two optional links of a movement (decision 2026-11-10, HU-CSH-001). Both are nullable and no row of the movement
-- is ever updated: the writer grant (SELECT, INSERT) already covers the columns.
-- reservation_id: the reservation an income was paid for, a plain id of domain 2 (Annex J.3.4), no foreign key; a
-- movement typed by hand has none.
ALTER TABLE cash_reporting.cash_movement ADD COLUMN reservation_id uuid;
-- reverses_cash_movement_id: a movement is immutable, so a reversal is a new movement that points at the one it
-- compensates, in the same tenant, once only: a REFUND reverses an income and an INCOME reverses a refund.
ALTER TABLE cash_reporting.cash_movement ADD COLUMN reverses_cash_movement_id uuid;
ALTER TABLE cash_reporting.cash_movement
    ADD CONSTRAINT uq_cash_movement_tenant_movement UNIQUE (tenant_id, cash_movement_id),
    ADD CONSTRAINT chk_cash_movement_reverses_income_or_refund
        CHECK (reverses_cash_movement_id IS NULL OR movement_type IN ('INCOME', 'REFUND'));
ALTER TABLE cash_reporting.cash_movement
    ADD CONSTRAINT fk_cash_movement_reverses FOREIGN KEY (tenant_id, reverses_cash_movement_id)
        REFERENCES cash_reporting.cash_movement (tenant_id, cash_movement_id);
CREATE UNIQUE INDEX uq_cash_movement_reverses
    ON cash_reporting.cash_movement (tenant_id, reverses_cash_movement_id)
    WHERE reverses_cash_movement_id IS NOT NULL;
