-- The frame of the grants: both roles see the schema. Privileges on each table arrive with the
-- table's own story (HU-CSH-001 T-07 seals them); no DELETE is granted on a business table.
GRANT USAGE ON SCHEMA cash_reporting TO cash_reporting_reader, cash_reporting_writer;
