-- Read: the correction notes of a closure in time order (plan D-11). It also indexes the closure side of the
-- composite key fk_cash_closure_correction_closure, whose first three columns lead it.
CREATE INDEX idx_cash_closure_correction_tenant_closure
    ON cash_reporting.cash_closure_correction (tenant_id, cash_session_closure_id, registered_at);
