REVOKE ALL ON cash_reporting.cash_session, cash_reporting.cash_session_closure, cash_reporting.cash_session_reopening,
    cash_reporting.cash_movement, cash_reporting.refund_movement, cash_reporting.outbox_event, cash_reporting.idempotency_key FROM cash_reporting_writer;
