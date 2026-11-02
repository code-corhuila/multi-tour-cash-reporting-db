-- One row per tenant and local date, closed or not (RN-CAJ-001, plan D-03). It holds the current
-- closing; the immutable snapshot of each closing is cash_session_closure (arrives in T-04).
-- Required columns carry a named check so the engine's refusal names the rule, not the column.
CREATE TABLE cash_reporting.cash_session (
    cash_session_id       uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id             uuid,
    -- the tenant's calendar date; the instant of creation is created_at
    business_date         date,
    -- the zone at creation; the date is never recomputed after a zone change
    time_zone             text,
    -- never rewritten by an opening: an automatic cash opened later stays AUTOMATIC_CREATION
    origin                text,
    created_at            timestamptz DEFAULT now(),
    opening_base_cents    bigint,
    opened_at             timestamptz,
    opened_by             uuid,
    closed_at             timestamptz,
    closing_mode          text,
    status                text        DEFAULT 'OPEN',
    -- signed: a day may close below zero
    closing_balance_cents bigint,
    closed_by             uuid,
    -- a mark, not a status: the open day that crossed its end without closing (GAP-012)
    pending_closure       boolean     NOT NULL DEFAULT false,
    CONSTRAINT pk_cash_session PRIMARY KEY (cash_session_id),
    -- the first constraint written: exactly one cash per tenant and date, whatever created it
    CONSTRAINT uq_cash_session_tenant_business_date UNIQUE (tenant_id, business_date),
    -- target of the composite keys of the tables that point at a session (plan D-07)
    CONSTRAINT uq_cash_session_tenant_cash_session UNIQUE (tenant_id, cash_session_id),
    CONSTRAINT chk_cash_session_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_cash_session_business_date_required CHECK (business_date IS NOT NULL),
    CONSTRAINT chk_cash_session_time_zone_required CHECK (time_zone IS NOT NULL AND btrim(time_zone) <> ''),
    CONSTRAINT chk_cash_session_origin_required CHECK (origin IS NOT NULL),
    CONSTRAINT chk_cash_session_created_at_required CHECK (created_at IS NOT NULL),
    CONSTRAINT chk_cash_session_status_required CHECK (status IS NOT NULL),
    -- DP-D1-5: codes stored in English, as domain 2 (PROPUESTO)
    CONSTRAINT chk_cash_session_origin CHECK (origin IN ('OPERATIONAL_OPENING', 'AUTOMATIC_CREATION')),
    CONSTRAINT chk_cash_session_status CHECK (status IN ('OPEN', 'CLOSED')),
    CONSTRAINT chk_cash_session_closing_mode CHECK (closing_mode IN ('FORMAL', 'AUTOMATIC')),
    CONSTRAINT chk_cash_session_opening_all_or_none CHECK (
        (opening_base_cents IS NULL) = (opened_at IS NULL) AND (opened_at IS NULL) = (opened_by IS NULL)),
    CONSTRAINT chk_cash_session_opening_base_nonnegative CHECK (opening_base_cents >= 0),
    CONSTRAINT chk_cash_session_closed_columns CHECK (CASE status
        WHEN 'CLOSED' THEN closed_at IS NOT NULL AND closing_mode IS NOT NULL
            AND closing_balance_cents IS NOT NULL
            AND (closing_mode <> 'FORMAL' OR closed_by IS NOT NULL)
            AND (closing_mode <> 'AUTOMATIC' OR closed_by IS NULL)
        WHEN 'OPEN' THEN closed_at IS NULL AND closing_mode IS NULL
            AND closing_balance_cents IS NULL AND closed_by IS NULL
        ELSE true END),
    CONSTRAINT chk_cash_session_pending_closure CHECK (NOT pending_closure OR (status = 'OPEN' AND opened_at IS NOT NULL))
);
