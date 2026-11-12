-- The zone of a tenant (HU-CSH-002 plan D-12, DP-D2-12). A tenant without a row uses the zone the service is configured
-- with (America/Bogota), the same TenantCalendar as the cash. The name is an IANA name checked by the api.
CREATE TABLE cash_reporting.tenant_time_zone (
    tenant_time_zone_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           uuid,
    time_zone           text,
    updated_at          timestamptz,
    CONSTRAINT pk_tenant_time_zone PRIMARY KEY (tenant_time_zone_id),
    CONSTRAINT uq_tenant_time_zone_tenant UNIQUE (tenant_id),
    CONSTRAINT chk_tenant_time_zone_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_tenant_time_zone_time_zone_required CHECK (time_zone IS NOT NULL AND btrim(time_zone) <> ''),
    CONSTRAINT chk_tenant_time_zone_updated_at_required CHECK (updated_at IS NOT NULL)
);
