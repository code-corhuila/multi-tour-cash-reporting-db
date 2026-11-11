-- HU-SEC-007 G-SEC9-1 (ADR-004 D5; Project Lead, 2026-11-11): the tenth event of outbox_event, PlatformExceptionalAccessUsed, the audit of each use of the token of an exceptional or
-- emergency access, written by the service in the same step as the read it audits. Its aggregate is the authorization of the access, which the outbox already holds as aggregate_id (no new column:
-- the access lives in the security service, so there is no foreign key either). The payload is closed to eight keys of identifiers, a method, a route template, an area and an instant, so no
-- data of the request or of the response can travel; the administrator (the sub of the token) travels as platformAdministratorId, for this table has no actor column. The payload must agree with
-- the row: authorizationId is the aggregate and tenantId is the tenant. The list of 002 is rewritten with the one new event; nothing is removed.
ALTER TABLE cash_reporting.outbox_event
    DROP CONSTRAINT chk_outbox_event_event_type,
    ADD CONSTRAINT chk_outbox_event_event_type CHECK (event_type IN (
        'CashSessionOpened', 'CashSessionClosed', 'CashSessionAutoCreated', 'CashSessionAutoClosed',
        'CashSessionReopened', 'CashIncomeRecorded', 'OperationalPaymentRecorded',
        'OperationalExpenseRecorded', 'RefundExecuted', 'PlatformExceptionalAccessUsed')),
    ADD CONSTRAINT chk_outbox_event_platform_exceptional_access_used_keys CHECK (
        event_type <> 'PlatformExceptionalAccessUsed'
        OR (jsonb_exists_all(payload, ARRAY['authorizationId', 'platformAdministratorId', 'tenantId', 'method', 'route', 'area', 'occurredAt', 'correlationId'])
            AND payload - ARRAY['authorizationId', 'platformAdministratorId', 'tenantId', 'method', 'route', 'area', 'occurredAt', 'correlationId'] = '{}'::jsonb)),
    ADD CONSTRAINT chk_outbox_event_platform_exceptional_access_used_ids CHECK (
        event_type <> 'PlatformExceptionalAccessUsed'
        OR (payload ->> 'authorizationId' = aggregate_id::text AND payload ->> 'tenantId' = tenant_id::text));
