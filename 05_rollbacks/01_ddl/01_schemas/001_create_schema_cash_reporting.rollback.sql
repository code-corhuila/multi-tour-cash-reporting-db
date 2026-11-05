-- Reverses 001_create_schema_cash_reporting.sql. It does not use CASCADE on purpose:
-- by the time it runs, the rollbacks of every later changeset have already removed their objects.
DROP SCHEMA cash_reporting;
