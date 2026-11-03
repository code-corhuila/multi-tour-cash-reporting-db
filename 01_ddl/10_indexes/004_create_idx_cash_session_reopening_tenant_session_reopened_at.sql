-- Read: the reopenings of a session in time order (plan D-10). It also indexes the session side of the
-- composite key fk_cash_session_reopening_closure, whose first two columns lead it.
CREATE INDEX idx_cash_session_reopening_tenant_session_reopened_at
    ON cash_reporting.cash_session_reopening (tenant_id, cash_session_id, reopened_at);
