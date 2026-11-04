-- The detail of a refund movement (plan D-06, RN-CAJ-001, CR-05, CR-08): a refund is a movement of type
-- refund tied to its reservation, never an expense. One detail per movement; the composite key makes the
-- engine refuse a detail whose session, tenant, amount or medium differs from the movement, or whose
-- movement is not a refund. That every refund movement has a detail is written by the application in the
-- same transaction. No UPDATE or DELETE for the application: the grants arrive in T-07.
CREATE TABLE cash_reporting.refund_movement (
    refund_movement_id      uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id               uuid,
    cash_session_id         uuid,
    cash_movement_id        uuid,
    -- always REFUND: it is what lets the composite key demand a movement of that type
    movement_type           text        GENERATED ALWAYS AS ('REFUND') STORED,
    -- plain uuids of domain 2 (Annex J.3.4): no foreign key; several details may share one authorization
    refund_authorization_id uuid,
    reservation_id          uuid,
    amount_cents            bigint,
    reason                  text,
    executed_by             uuid,
    outflow_method          text,
    executed_at             timestamptz,
    CONSTRAINT pk_refund_movement PRIMARY KEY (refund_movement_id),
    -- one detail per movement
    CONSTRAINT uq_refund_movement_cash_movement UNIQUE (cash_movement_id),
    -- the tenant, session, amount and medium must be those of a movement of type refund
    CONSTRAINT fk_refund_movement_cash_movement
        FOREIGN KEY (tenant_id, cash_session_id, cash_movement_id, movement_type, amount_cents, outflow_method)
        REFERENCES cash_reporting.cash_movement (tenant_id, cash_session_id, cash_movement_id, movement_type, amount_cents, payment_medium),
    CONSTRAINT chk_refund_movement_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_refund_movement_cash_session_required CHECK (cash_session_id IS NOT NULL),
    CONSTRAINT chk_refund_movement_cash_movement_required CHECK (cash_movement_id IS NOT NULL),
    CONSTRAINT chk_refund_movement_refund_authorization_required CHECK (refund_authorization_id IS NOT NULL),
    CONSTRAINT chk_refund_movement_reservation_required CHECK (reservation_id IS NOT NULL),
    CONSTRAINT chk_refund_movement_amount_required CHECK (amount_cents IS NOT NULL),
    CONSTRAINT chk_refund_movement_reason_not_blank CHECK (reason IS NOT NULL AND btrim(reason) <> ''),
    CONSTRAINT chk_refund_movement_executed_by_required CHECK (executed_by IS NOT NULL),
    CONSTRAINT chk_refund_movement_outflow_method CHECK (outflow_method IS NOT NULL
        AND outflow_method IN ('CASH', 'TRANSFER')),
    CONSTRAINT chk_refund_movement_executed_at_required CHECK (executed_at IS NOT NULL)
);
