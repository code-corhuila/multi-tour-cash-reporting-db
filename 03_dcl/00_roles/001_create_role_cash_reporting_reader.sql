-- NOLOGIN and no password on purpose: a role that can log in needs a secret, and a secret versioned
-- here would be a grave fault. The infrastructure creates the login user and grants it one of these.
CREATE ROLE cash_reporting_reader NOLOGIN;
