-- The schema of this domain. Nothing of the domain lives in public (Annex A rule 9, Annex J.4).
-- The instance, its volume, its extensions and its users belong to multi-tour-infra-postgres.
CREATE SCHEMA cash_reporting;

COMMENT ON SCHEMA cash_reporting IS 'Cash and Reporting macrodomain (ADR-004 D1): cash sessions, movements, closures and their events.';
