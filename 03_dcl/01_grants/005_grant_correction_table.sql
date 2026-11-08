-- Plan D-11: a correction note is a fact like a closure or a reopening. The writer inserts and reads it; there is
-- no UPDATE and no DELETE, so the engine refuses them (AC-D1.23, AC-D1.19). The reader only reads it.
GRANT SELECT, INSERT ON cash_reporting.cash_closure_correction TO cash_reporting_writer;
GRANT SELECT ON cash_reporting.cash_closure_correction TO cash_reporting_reader;
