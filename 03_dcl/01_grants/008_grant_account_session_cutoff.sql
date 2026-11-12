-- The cutoff of an account is written by the application when job 7 delivers a revocation (a cutoff moves forward by
-- update) and read on every request; it is never deleted. The reader only reads it.
GRANT SELECT, INSERT, UPDATE ON cash_reporting.account_session_cutoff TO cash_reporting_writer;
GRANT SELECT ON cash_reporting.account_session_cutoff TO cash_reporting_reader;
