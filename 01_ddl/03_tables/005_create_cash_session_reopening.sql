-- One row per reopening: who, when and why, and which closure it reopened (plan D-05, RN-CAJ-001).
-- The session is the same one, so a reopening creates no second cash; a session may be reopened
-- more than once, each time over a different closure. No UPDATE or DELETE for the application (T-07).
CREATE TABLE cash_reporting.cash_session_reopening (
    cash_session_reopening_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                 uuid,
    cash_session_id           uuid,
    -- the closure reopened (PROPUESTO, DP-D1-1)
    cash_session_closure_id   uuid,
    reopened_by               uuid,
    reopened_at               timestamptz,
    reason                    text,
    CONSTRAINT pk_cash_session_reopening PRIMARY KEY (cash_session_reopening_id),
    -- composite key with the tenant and the session first: the closure must be of this session
    CONSTRAINT fk_cash_session_reopening_closure FOREIGN KEY (tenant_id, cash_session_id, cash_session_closure_id)
        REFERENCES cash_reporting.cash_session_closure (tenant_id, cash_session_id, cash_session_closure_id),
    -- one reopening per closure; a second closing creates a new closure that may be reopened again
    CONSTRAINT uq_cash_session_reopening_closure UNIQUE (cash_session_closure_id),
    CONSTRAINT chk_cash_session_reopening_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_cash_session_reopening_cash_session_required CHECK (cash_session_id IS NOT NULL),
    CONSTRAINT chk_cash_session_reopening_closure_required CHECK (cash_session_closure_id IS NOT NULL),
    CONSTRAINT chk_cash_session_reopening_reopened_by_required CHECK (reopened_by IS NOT NULL),
    CONSTRAINT chk_cash_session_reopening_reopened_at_required CHECK (reopened_at IS NOT NULL),
    CONSTRAINT chk_cash_session_reopening_reason_not_blank CHECK (reason IS NOT NULL AND btrim(reason) <> '')
);
