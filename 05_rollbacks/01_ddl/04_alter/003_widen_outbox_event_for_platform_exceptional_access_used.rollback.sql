-- HU-SEC-007 G-SEC9-1 (-db): the list of 002, without PlatformExceptionalAccessUsed. A database that already holds rows of that event refuses this revert on purpose
-- (the list is added last and the engine checks it against every stored row): the audit is never erased by a revert; the owner decides what to do with those rows first.
ALTER TABLE cash_reporting.outbox_event
    DROP CONSTRAINT chk_outbox_event_platform_exceptional_access_used_ids,
    DROP CONSTRAINT chk_outbox_event_platform_exceptional_access_used_keys,
    DROP CONSTRAINT chk_outbox_event_event_type,
    ADD CONSTRAINT chk_outbox_event_event_type CHECK (event_type IN (
        'CashSessionOpened', 'CashSessionClosed', 'CashSessionAutoCreated', 'CashSessionAutoClosed',
        'CashSessionReopened', 'CashIncomeRecorded', 'OperationalPaymentRecorded',
        'OperationalExpenseRecorded', 'RefundExecuted'));
