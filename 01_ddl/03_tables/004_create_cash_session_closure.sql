-- Immutable snapshot of each closing (plan D-04, DP-D1-1 PROPUESTO default: accepted as written).
-- The session row keeps only the current closing; a reopening followed by a second closing must not
-- erase the first one (CR-06), so every closing is one row here. The application never updates or
-- deletes it: the grants arrive in T-07. The engine holds the formula and the sums by medium;
-- that the numbers equal the movements of the session is the application's (spec section 4).
CREATE TABLE cash_reporting.cash_session_closure (
    cash_session_closure_id    uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                  uuid,
    cash_session_id            uuid,
    closed_at                  timestamptz,
    closing_mode               text,
    closed_by                  uuid,
    -- null for a session that was never operationally opened
    opening_base_cents         bigint,
    income_cents               bigint,
    operational_payments_cents bigint,
    operational_expenses_cents bigint,
    refunds_cents              bigint,
    cash_entries_cents         bigint,
    transfer_entries_cents     bigint,
    cash_exits_cents           bigint,
    transfer_exits_cents       bigint,
    -- null exactly when there is no base
    expected_cash_cents        bigint,
    -- signed: a day may close below zero
    closing_balance_cents      bigint,
    CONSTRAINT pk_cash_session_closure PRIMARY KEY (cash_session_closure_id),
    -- composite key with the tenant first: a closure cannot point at another tenant's session
    CONSTRAINT fk_cash_session_closure_cash_session FOREIGN KEY (tenant_id, cash_session_id)
        REFERENCES cash_reporting.cash_session (tenant_id, cash_session_id),
    -- target of the composite key of the reopening (plan D-05)
    CONSTRAINT uq_cash_session_closure_tenant_session_closure UNIQUE (tenant_id, cash_session_id, cash_session_closure_id),
    CONSTRAINT chk_cash_session_closure_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_cash_session_closure_cash_session_required CHECK (cash_session_id IS NOT NULL),
    CONSTRAINT chk_cash_session_closure_closed_at_required CHECK (closed_at IS NOT NULL),
    CONSTRAINT chk_cash_session_closure_amounts_required CHECK (
        income_cents IS NOT NULL AND operational_payments_cents IS NOT NULL
        AND operational_expenses_cents IS NOT NULL AND refunds_cents IS NOT NULL
        AND cash_entries_cents IS NOT NULL AND transfer_entries_cents IS NOT NULL
        AND cash_exits_cents IS NOT NULL AND transfer_exits_cents IS NOT NULL
        AND closing_balance_cents IS NOT NULL),
    CONSTRAINT chk_cash_session_closure_closing_mode CHECK (closing_mode IS NOT NULL AND closing_mode IN ('FORMAL', 'AUTOMATIC')),
    -- same rule as the session: a formal closing has its user, an automatic one has none
    CONSTRAINT chk_cash_session_closure_closed_by CHECK (
        (closing_mode <> 'FORMAL' OR closed_by IS NOT NULL) AND (closing_mode <> 'AUTOMATIC' OR closed_by IS NULL)),
    CONSTRAINT chk_cash_session_closure_amounts_nonnegative CHECK (
        opening_base_cents >= 0 AND income_cents >= 0 AND operational_payments_cents >= 0
        AND operational_expenses_cents >= 0 AND refunds_cents >= 0 AND cash_entries_cents >= 0
        AND transfer_entries_cents >= 0 AND cash_exits_cents >= 0 AND transfer_exits_cents >= 0),
    -- the formula of the day: base + income - payments - expenses - refunds
    CONSTRAINT chk_cash_session_closure_balance CHECK (closing_balance_cents =
        coalesce(opening_base_cents, 0) + income_cents - operational_payments_cents
        - operational_expenses_cents - refunds_cents),
    CONSTRAINT chk_cash_session_closure_entries_by_medium CHECK (cash_entries_cents + transfer_entries_cents = income_cents),
    CONSTRAINT chk_cash_session_closure_exits_by_medium CHECK (
        cash_exits_cents + transfer_exits_cents = operational_payments_cents + operational_expenses_cents + refunds_cents),
    -- expected cash = base + cash entries - cash exits; a transfer never changes it
    CONSTRAINT chk_cash_session_closure_expected_cash CHECK (
        (expected_cash_cents IS NULL) = (opening_base_cents IS NULL)
        AND (opening_base_cents IS NULL OR expected_cash_cents = opening_base_cents + cash_entries_cents - cash_exits_cents))
);
