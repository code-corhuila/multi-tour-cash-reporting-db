-- The monthly administrative report: a derived, rebuildable record, one row per tenant and period (HU-CSH-003 plan D-02).
-- The total is a formula over the components, never a typed number (RF-012, GAP-11 of the PDR), and may be negative.
-- The constraints use the prefix chk_report_ because PostgreSQL cuts a name over 63 characters. The confirmed sales stay
-- null until the commercial domain gives the value of the reservations: an unknown figure is never served as zero.
CREATE TABLE cash_reporting.monthly_administrative_report (
    monthly_report_id            uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                    uuid,
    starts_on                    date,
    ends_on                      date,
    period_income_cents          bigint      NOT NULL DEFAULT 0,
    operational_payments_cents   bigint      NOT NULL DEFAULT 0,
    operational_expenses_cents   bigint      NOT NULL DEFAULT 0,
    executed_refunds_cents       bigint      NOT NULL DEFAULT 0,
    consolidated_cash_total_cents bigint     NOT NULL DEFAULT 0,
    period_income_cash_cents     bigint      NOT NULL DEFAULT 0,
    period_income_transfer_cents bigint      NOT NULL DEFAULT 0,
    counted_movements            integer     NOT NULL DEFAULT 0,
    -- null = no source yet; the value is known (zero or more) once the commercial events carry it
    confirmed_sales_cents        bigint,
    -- elements: {reservationId, cause} and {costId, amountCents}; at most 10000 each
    registered_cancellations     jsonb       NOT NULL DEFAULT '[]'::jsonb,
    registered_operational_costs jsonb       NOT NULL DEFAULT '[]'::jsonb,
    updated_at                   timestamptz,
    CONSTRAINT pk_monthly_administrative_report PRIMARY KEY (monthly_report_id),
    CONSTRAINT uq_monthly_report_tenant_period UNIQUE (tenant_id, starts_on, ends_on),
    CONSTRAINT chk_report_tenant_required CHECK (tenant_id IS NOT NULL),
    CONSTRAINT chk_report_period_required CHECK (starts_on IS NOT NULL AND ends_on IS NOT NULL),
    CONSTRAINT chk_report_period CHECK (starts_on <= ends_on),
    CONSTRAINT chk_report_updated_at_required CHECK (updated_at IS NOT NULL),
    CONSTRAINT chk_report_period_income_cents_nonnegative CHECK (period_income_cents >= 0),
    CONSTRAINT chk_report_operational_payments_cents_nonnegative CHECK (operational_payments_cents >= 0),
    CONSTRAINT chk_report_operational_expenses_cents_nonnegative CHECK (operational_expenses_cents >= 0),
    CONSTRAINT chk_report_executed_refunds_cents_nonnegative CHECK (executed_refunds_cents >= 0),
    -- the total is income - payments - expenses - refunds, whatever its sign
    CONSTRAINT chk_report_total_formula CHECK (
        consolidated_cash_total_cents = period_income_cents - operational_payments_cents - operational_expenses_cents - executed_refunds_cents),
    CONSTRAINT chk_report_income_by_medium CHECK (period_income_cash_cents + period_income_transfer_cents = period_income_cents),
    CONSTRAINT chk_report_counted_movements_nonnegative CHECK (counted_movements >= 0),
    CONSTRAINT chk_report_confirmed_sales_nonnegative CHECK (confirmed_sales_cents IS NULL OR confirmed_sales_cents >= 0),
    CONSTRAINT chk_report_cancellations_is_array CHECK (jsonb_typeof(registered_cancellations) = 'array'),
    CONSTRAINT chk_report_costs_is_array CHECK (jsonb_typeof(registered_operational_costs) = 'array'),
    CONSTRAINT chk_report_cancellations_max_items CHECK (jsonb_typeof(registered_cancellations) <> 'array' OR jsonb_array_length(registered_cancellations) <= 10000),
    CONSTRAINT chk_report_costs_max_items CHECK (jsonb_typeof(registered_operational_costs) <> 'array' OR jsonb_array_length(registered_operational_costs) <= 10000)
);
