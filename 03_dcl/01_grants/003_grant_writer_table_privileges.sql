-- Plan D-10. The writer inserts and reads every table; it updates only the session (a closing and a reopening
-- change it). Closures, reopenings, movements and refund details are facts: no UPDATE and no DELETE, so the
-- engine refuses them (AC-D1.8, AC-D1.13, AC-D1.19). The two technical tables keep all four (ADR-004 D10 point 6).
GRANT SELECT, INSERT, UPDATE ON cash_reporting.cash_session TO cash_reporting_writer;
GRANT SELECT, INSERT ON cash_reporting.cash_session_closure, cash_reporting.cash_session_reopening,
    cash_reporting.cash_movement, cash_reporting.refund_movement TO cash_reporting_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON cash_reporting.outbox_event, cash_reporting.idempotency_key TO cash_reporting_writer;
