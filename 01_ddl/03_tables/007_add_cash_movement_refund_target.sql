-- The target of the refund detail's composite key (plan D-06, CR-05): it repeats the key of the movement
-- with its type, amount and medium, so the engine can compare them. It adds no rule of its own: the
-- movement_id alone is already unique, this only makes the wider tuple referenceable.
ALTER TABLE cash_reporting.cash_movement
    ADD CONSTRAINT uq_cash_movement_refund_target
    UNIQUE (tenant_id, cash_session_id, cash_movement_id, movement_type, amount_cents, payment_medium);
