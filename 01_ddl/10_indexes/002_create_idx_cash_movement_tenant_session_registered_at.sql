-- Read: the movements of a session, newest first (plan D-10, AC-D1.20). It also indexes the composite key
-- fk_cash_movement_cash_session, whose columns lead it.
CREATE INDEX idx_cash_movement_tenant_session_registered_at
    ON cash_reporting.cash_movement (tenant_id, cash_session_id, registered_at DESC);
