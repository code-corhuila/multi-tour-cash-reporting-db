-- Written by the -api in the same transaction as the change it announces (norm 5.3.11, plan D-08).
-- The relay reads it through an internal route of the -api and never connects here.
-- The payload carries ids and amounts only, never free text (a refund reason stays out of it).
CREATE TABLE cash_reporting.outbox_event (
    outbox_event_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       uuid        NOT NULL,
    event_type      text        NOT NULL,
    aggregate_id    uuid        NOT NULL,
    payload         jsonb       NOT NULL,
    occurred_at     timestamptz NOT NULL,
    status          text        NOT NULL DEFAULT 'PENDING',
    attempts        integer     NOT NULL DEFAULT 0,
    -- null until the relay has delivered the event
    published_at    timestamptz,
    CONSTRAINT pk_outbox_event PRIMARY KEY (outbox_event_id),
    -- the nine names of the service (events.md)
    CONSTRAINT chk_outbox_event_event_type CHECK (event_type IN (
        'CashSessionOpened', 'CashSessionClosed', 'CashSessionAutoCreated', 'CashSessionAutoClosed',
        'CashSessionReopened', 'CashIncomeRecorded', 'OperationalPaymentRecorded',
        'OperationalExpenseRecorded', 'RefundExecuted')),
    CONSTRAINT chk_outbox_event_status CHECK (status IN ('PENDING', 'PUBLISHED', 'FAILED')),
    CONSTRAINT chk_outbox_event_attempts CHECK (attempts >= 0),
    CONSTRAINT chk_outbox_event_payload_object CHECK (jsonb_typeof(payload) = 'object'),
    CONSTRAINT chk_outbox_event_published_at CHECK ((status = 'PUBLISHED') = (published_at IS NOT NULL))
);
