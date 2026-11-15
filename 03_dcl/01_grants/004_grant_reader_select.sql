-- Plan D-10: the reader only reads the five business tables. It sees neither technical table.
GRANT SELECT ON cash_reporting.cash_session, cash_reporting.cash_session_closure, cash_reporting.cash_session_reopening,
    cash_reporting.cash_movement, cash_reporting.refund_movement TO cash_reporting_reader;
