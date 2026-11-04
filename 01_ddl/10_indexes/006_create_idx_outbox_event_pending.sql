-- Read: the relay takes the pending events in order of occurrence, not per tenant. This is the declared
-- exception to the tenant-first rule of RNF-D1.1 (plan D-10). Partial on PENDING: published events leave it.
CREATE INDEX idx_outbox_event_pending
    ON cash_reporting.outbox_event (status, occurred_at)
    WHERE status = 'PENDING';
