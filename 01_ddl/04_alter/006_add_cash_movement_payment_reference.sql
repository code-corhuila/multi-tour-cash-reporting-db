-- One income per payment (audit 2026-11-13, HU-WFL-002). The saga register-payment records the income of a payment in the
-- cash; a second saga with another Idempotency-Key must not record it again. payment_reference is the payment of domain 2
-- (a plain id, Annex J.3.4, no foreign key). It is nullable: a movement typed by hand, a refund and a reversal have none.
-- No row is ever updated: the writer grant (SELECT, INSERT) already covers the column.
ALTER TABLE cash_reporting.cash_movement ADD COLUMN payment_reference uuid;
ALTER TABLE cash_reporting.cash_movement
    ADD CONSTRAINT chk_cash_movement_payment_reference_income
        CHECK (payment_reference IS NULL OR movement_type = 'INCOME');
-- A payment has one income, reversed or not (the reversal is a REFUND that points at it), whatever the key that asked.
CREATE UNIQUE INDEX uq_cash_movement_tenant_payment_reference
    ON cash_reporting.cash_movement (tenant_id, payment_reference)
    WHERE payment_reference IS NOT NULL;
