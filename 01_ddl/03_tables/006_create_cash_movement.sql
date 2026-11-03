-- One row per money fact of a cash (plan D-06, RN-CAJ-001): the amount is positive cents and the type
-- gives the direction (RNF-D1.3). The application never updates or deletes it: the grants arrive in T-07.
-- That the cash had its opening, and that the day is not closed, is the -api's guard (DD-4, plan D-09).
CREATE TABLE cash_reporting.cash_movement (
    cash_movement_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id        uuid,
    cash_session_id  uuid,
    movement_type    text,
    payment_medium   text,
    amount_cents     bigint,
    -- a transfer received after the closing (GAP-013); deciding "after closing" is the application's
    after_closing    boolean     NOT NULL DEFAULT false,
    registered_at    timestamptz,
    -- DD-5: a plain uuid, the actor of automatic movements is NO DEFINIDO
    registered_by    uuid,
    CONSTRAINT pk_cash_movement PRIMARY KEY (cash_movement_id),
    -- composite key with the tenant first: a movement cannot point at another tenant's session (CR-04)
    CONSTRAINT fk_cash_movement_cash_session FOREIGN KEY (tenant_id, cash_session_id)
        REFERENCES cash_reporting.cash_session (tenant_id, cash_session_id),
    CONSTRAINT chk_cash_movement_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_cash_movement_cash_session_required CHECK (cash_session_id IS NOT NULL),
    CONSTRAINT chk_cash_movement_type CHECK (movement_type IS NOT NULL
        AND movement_type IN ('INCOME', 'OPERATIONAL_PAYMENT', 'OPERATIONAL_EXPENSE', 'REFUND')),
    CONSTRAINT chk_cash_movement_payment_medium CHECK (payment_medium IS NOT NULL
        AND payment_medium IN ('CASH', 'TRANSFER')),
    CONSTRAINT chk_cash_movement_amount_required CHECK (amount_cents IS NOT NULL),
    CONSTRAINT chk_cash_movement_amount_positive CHECK (amount_cents > 0),
    CONSTRAINT chk_cash_movement_registered_at_required CHECK (registered_at IS NOT NULL),
    CONSTRAINT chk_cash_movement_registered_by_required CHECK (registered_by IS NOT NULL),
    -- only a transfer can be marked after closing; a cash movement never carries the mark
    CONSTRAINT chk_cash_movement_after_closing_transfer_only CHECK (NOT after_closing OR payment_medium = 'TRANSFER')
);
