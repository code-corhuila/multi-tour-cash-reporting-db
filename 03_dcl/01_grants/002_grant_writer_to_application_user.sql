-- The user is created by the infrastructure from secrets (Annex J.7); this only gives it the writer.
-- No grant goes to another domain's user (ADR-005 E7).
GRANT cash_reporting_writer TO cash_reporting_app;
