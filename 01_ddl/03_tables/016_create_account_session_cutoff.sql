-- The cutoff of the sessions of an account (HU-SEC-005 AC4, HU-SEC-006 AC7; ADR-004 D5, decision DEC-003 of security):
-- the instant from which the tokens of the account no longer count. The api answers 401 to a token issued before it.
-- One row per account, never deleted: the cutoff only moves forward, the api keeps the newest. The tenant is empty for an
-- account of the platform (an account belongs to one tenant or to none, checked by the api). event_id is the id of the
-- event that set the cutoff: the same event again changes nothing, so the first delivery is told apart from a repeat.
CREATE TABLE cash_reporting.account_session_cutoff (
    account_session_cutoff_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    account_id                uuid,
    tenant_id                 uuid,
    session_cutoff_at         timestamptz,
    event_id                  uuid,
    updated_at                timestamptz,
    CONSTRAINT pk_account_session_cutoff PRIMARY KEY (account_session_cutoff_id),
    CONSTRAINT uq_account_session_cutoff_account UNIQUE (account_id),
    CONSTRAINT chk_account_session_cutoff_account_required CHECK (account_id IS NOT NULL),
    CONSTRAINT chk_account_session_cutoff_session_cutoff_at_required CHECK (session_cutoff_at IS NOT NULL),
    CONSTRAINT chk_account_session_cutoff_event_id_required CHECK (event_id IS NOT NULL),
    CONSTRAINT chk_account_session_cutoff_updated_at_required CHECK (updated_at IS NOT NULL)
);
