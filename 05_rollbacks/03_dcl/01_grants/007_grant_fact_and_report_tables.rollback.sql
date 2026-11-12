REVOKE ALL ON cash_reporting.reservation_state, cash_reporting.departure_state,
    cash_reporting.tenant_time_zone, cash_reporting.monthly_administrative_report FROM cash_reporting_writer, cash_reporting_reader;
