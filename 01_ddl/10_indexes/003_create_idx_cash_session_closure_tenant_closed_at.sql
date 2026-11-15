-- Read: the closing history of a tenant, newest first (plan D-10, AC-D1.20).
CREATE INDEX idx_cash_session_closure_tenant_closed_at
    ON cash_reporting.cash_session_closure (tenant_id, closed_at DESC);
