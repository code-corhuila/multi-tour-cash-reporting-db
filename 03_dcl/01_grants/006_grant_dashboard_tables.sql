-- Plan D-05. The writer reads and inserts both tables and updates only the projection (a rebuild upserts); nobody deletes
-- (DP-D2-6, AC-D2.11). A processed event is a fact: no UPDATE. The reader only reads the projection.
GRANT SELECT, INSERT, UPDATE ON cash_reporting.daily_dashboard_projection TO cash_reporting_writer;
GRANT SELECT, INSERT ON cash_reporting.processed_event TO cash_reporting_writer;
GRANT SELECT ON cash_reporting.daily_dashboard_projection TO cash_reporting_reader;
