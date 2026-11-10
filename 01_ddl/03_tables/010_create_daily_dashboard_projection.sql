-- The daily dashboard of a tenant: six sets of reference ids, one row per tenant and local date (plan D-03). The six
-- numbers of the screen are the array lengths, computed by the api; the row holds no personal datum. Rebuildable
-- by upsert, never deleted by the application (DP-D2-6).
CREATE TABLE cash_reporting.daily_dashboard_projection (
    daily_dashboard_id           uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                    uuid,
    -- the local calendar day of the tenant
    report_date                  date,
    created_reservations         jsonb       NOT NULL DEFAULT '[]'::jsonb,
    pending_payment_reservations jsonb       NOT NULL DEFAULT '[]'::jsonb,
    confirmed_reservations       jsonb       NOT NULL DEFAULT '[]'::jsonb,
    confirmed_with_balance       jsonb       NOT NULL DEFAULT '[]'::jsonb,
    cancelled_reservations       jsonb       NOT NULL DEFAULT '[]'::jsonb,
    upcoming_services            jsonb       NOT NULL DEFAULT '[]'::jsonb,
    -- the newest event applied: an older state event is ignored (DP-D2-5)
    last_event_occurred_at       timestamptz,
    updated_at                   timestamptz,
    CONSTRAINT pk_daily_dashboard_projection PRIMARY KEY (daily_dashboard_id),
    CONSTRAINT uq_daily_dashboard_projection_tenant_report_date UNIQUE (tenant_id, report_date),
    CONSTRAINT chk_daily_dashboard_projection_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_daily_dashboard_projection_report_date_required CHECK (report_date IS NOT NULL),
    CONSTRAINT chk_daily_dashboard_projection_updated_at_required CHECK (updated_at IS NOT NULL),
    CONSTRAINT chk_dashboard_created_reservations_is_array CHECK (jsonb_typeof(created_reservations) = 'array'),
    CONSTRAINT chk_dashboard_pending_payment_reservations_is_array CHECK (jsonb_typeof(pending_payment_reservations) = 'array'),
    CONSTRAINT chk_dashboard_confirmed_reservations_is_array CHECK (jsonb_typeof(confirmed_reservations) = 'array'),
    CONSTRAINT chk_dashboard_confirmed_with_balance_is_array CHECK (jsonb_typeof(confirmed_with_balance) = 'array'),
    CONSTRAINT chk_dashboard_cancelled_reservations_is_array CHECK (jsonb_typeof(cancelled_reservations) = 'array'),
    CONSTRAINT chk_dashboard_upcoming_services_is_array CHECK (jsonb_typeof(upcoming_services) = 'array'),
    -- a set holds at most 10000 elements, enough for the day of one tenant (DP-D2-3)
    CONSTRAINT chk_dashboard_created_reservations_max_items CHECK (jsonb_typeof(created_reservations) <> 'array' OR jsonb_array_length(created_reservations) <= 10000),
    CONSTRAINT chk_dashboard_pending_payment_reservations_max_items CHECK (jsonb_typeof(pending_payment_reservations) <> 'array' OR jsonb_array_length(pending_payment_reservations) <= 10000),
    CONSTRAINT chk_dashboard_confirmed_reservations_max_items CHECK (jsonb_typeof(confirmed_reservations) <> 'array' OR jsonb_array_length(confirmed_reservations) <= 10000),
    CONSTRAINT chk_dashboard_confirmed_with_balance_max_items CHECK (jsonb_typeof(confirmed_with_balance) <> 'array' OR jsonb_array_length(confirmed_with_balance) <= 10000),
    CONSTRAINT chk_dashboard_cancelled_reservations_max_items CHECK (jsonb_typeof(cancelled_reservations) <> 'array' OR jsonb_array_length(cancelled_reservations) <= 10000),
    CONSTRAINT chk_dashboard_upcoming_services_max_items CHECK (jsonb_typeof(upcoming_services) <> 'array' OR jsonb_array_length(upcoming_services) <= 10000),
    -- a reservation with balance is a confirmed one
    CONSTRAINT chk_dashboard_balance_within_confirmed CHECK (
        jsonb_typeof(confirmed_with_balance) <> 'array' OR jsonb_typeof(confirmed_reservations) <> 'array'
        OR confirmed_with_balance <@ confirmed_reservations)
);
