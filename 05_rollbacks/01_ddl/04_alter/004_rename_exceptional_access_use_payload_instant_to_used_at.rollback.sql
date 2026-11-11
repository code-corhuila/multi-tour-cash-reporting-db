-- HU-SEC-007 G-SEC9-1 (-db): the closed list of 003, with occurredAt in place of usedAt. A database that already holds rows with usedAt refuses this revert on purpose: the audit is never rewritten.
ALTER TABLE cash_reporting.outbox_event
    DROP CONSTRAINT chk_outbox_event_platform_exceptional_access_used_keys,
    ADD CONSTRAINT chk_outbox_event_platform_exceptional_access_used_keys CHECK (
        event_type <> 'PlatformExceptionalAccessUsed'
        OR (jsonb_exists_all(payload, ARRAY['authorizationId', 'platformAdministratorId', 'tenantId', 'method', 'route', 'area', 'occurredAt', 'correlationId'])
            AND payload - ARRAY['authorizationId', 'platformAdministratorId', 'tenantId', 'method', 'route', 'area', 'occurredAt', 'correlationId'] = '{}'::jsonb));
