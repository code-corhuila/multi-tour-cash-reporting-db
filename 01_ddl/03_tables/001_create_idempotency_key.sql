-- One key table for the whole domain (plan D-08), written in the same transaction as the resource it
-- guards (norm 5.3.8). The resource is referenced by type and id with no foreign key (Annex J.3.4):
-- the tables that hold each resource arrive in later stories.
CREATE TABLE cash_reporting.idempotency_key (
    idempotency_key_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          uuid        NOT NULL,
    key                text        NOT NULL,
    resource_type      text,
    resource_id        uuid,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_idempotency_key PRIMARY KEY (idempotency_key_id),
    -- per tenant, never alone: a second tenant never receives the first one's resource
    CONSTRAINT uq_idempotency_key_tenant_key UNIQUE (tenant_id, key),
    -- the length the Idempotency-Key header must have (Annex C)
    CONSTRAINT chk_idempotency_key_key_length CHECK (char_length(key) BETWEEN 8 AND 128),
    CONSTRAINT chk_idempotency_key_resource_type_length CHECK (char_length(resource_type) BETWEEN 1 AND 64)
);
