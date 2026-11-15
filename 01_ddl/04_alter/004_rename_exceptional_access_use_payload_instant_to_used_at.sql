-- HU-SEC-007 G-SEC9-1 (spec 012 RN-SEC-012-07, owner of security, 2026-11-11): the instant of PlatformExceptionalAccessUsed travels in the payload as usedAt (RFC 3339 UTC), not as occurredAt; occurredAt
-- stays only in the envelope (occurred_at) with the same instant, as operations-cost writes it. The closed list of eight keys of 003 is rewritten with usedAt in place of occurredAt; nothing else changes.
-- A database that already holds rows of the event with occurredAt refuses this change on purpose: the audit rows are never rewritten by a migration; the owner decides.
ALTER TABLE cash_reporting.outbox_event
    DROP CONSTRAINT chk_outbox_event_platform_exceptional_access_used_keys,
    ADD CONSTRAINT chk_outbox_event_platform_exceptional_access_used_keys CHECK (
        event_type <> 'PlatformExceptionalAccessUsed'
        OR (jsonb_exists_all(payload, ARRAY['authorizationId', 'platformAdministratorId', 'tenantId', 'method', 'route', 'area', 'usedAt', 'correlationId'])
            AND payload - ARRAY['authorizationId', 'platformAdministratorId', 'tenantId', 'method', 'route', 'area', 'usedAt', 'correlationId'] = '{}'::jsonb));
