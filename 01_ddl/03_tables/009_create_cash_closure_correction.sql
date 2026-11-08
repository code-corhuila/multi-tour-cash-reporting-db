-- One row per correction note on a closed cash: who, when and why, and the closure it is about (plan D-11,
-- DP-D1-2). A correction does not reopen and changes no closure value, so it is its own table (D-05 is only for
-- reopenings). A closure may carry several notes. No UPDATE or DELETE for the application.
CREATE TABLE cash_reporting.cash_closure_correction (
    cash_closure_correction_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                  uuid,
    cash_session_id            uuid,
    -- the closure the note is about
    cash_session_closure_id    uuid,
    justification              text,
    registered_by              uuid,
    registered_at              timestamptz,
    CONSTRAINT pk_cash_closure_correction PRIMARY KEY (cash_closure_correction_id),
    -- composite key with the tenant and the session first: the closure must be of this session
    CONSTRAINT fk_cash_closure_correction_closure FOREIGN KEY (tenant_id, cash_session_id, cash_session_closure_id)
        REFERENCES cash_reporting.cash_session_closure (tenant_id, cash_session_id, cash_session_closure_id),
    CONSTRAINT chk_cash_closure_correction_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_cash_closure_correction_cash_session_required CHECK (cash_session_id IS NOT NULL),
    CONSTRAINT chk_cash_closure_correction_closure_required CHECK (cash_session_closure_id IS NOT NULL),
    -- mandatory justification, not blank, up to the 500 characters of the contract
    CONSTRAINT chk_cash_closure_correction_justification CHECK (
        justification IS NOT NULL AND btrim(justification) <> '' AND char_length(justification) <= 500),
    CONSTRAINT chk_cash_closure_correction_registered_by_required CHECK (registered_by IS NOT NULL),
    CONSTRAINT chk_cash_closure_correction_registered_at_required CHECK (registered_at IS NOT NULL)
);
