-- Read: the open and pending sessions of a tenant, in date order (HU-CSH-001 plan D-10, AC-D1.20). Partial on
-- OPEN: closed days are the bulk of the table and this read never wants them. It also answers the time-zone
-- precondition (DP-D1-8). The cash of one day is read through uq_cash_session_tenant_business_date.
CREATE INDEX idx_cash_session_tenant_open
    ON cash_reporting.cash_session (tenant_id, business_date)
    WHERE status = 'OPEN';
