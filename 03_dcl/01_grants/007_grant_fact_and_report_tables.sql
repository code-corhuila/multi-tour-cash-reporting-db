-- The fact tables and the monthly report are written by the application (a state changes with each event and a report is
-- rebuilt by upsert) and never deleted (DP-D2-6, DP-D3-8); the reader only reads them.
GRANT SELECT, INSERT, UPDATE ON cash_reporting.reservation_state, cash_reporting.departure_state,
    cash_reporting.tenant_time_zone, cash_reporting.monthly_administrative_report TO cash_reporting_writer;
GRANT SELECT ON cash_reporting.reservation_state, cash_reporting.departure_state,
    cash_reporting.tenant_time_zone, cash_reporting.monthly_administrative_report TO cash_reporting_reader;
