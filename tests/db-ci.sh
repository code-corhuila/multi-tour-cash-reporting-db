#!/usr/bin/env bash
# The four steps of Annex A against an empty PostgreSQL, in a throwaway container (norm 5.2.8):
#   1. update               builds everything
#   2. update, again        applies nothing
#   3. rollback-count 999   leaves the database empty
#   4. update               rebuilds
# CI and a developer run this same file. Docker is the only requirement.
set -euo pipefail
cd "$(dirname "$0")/.."

# Git Bash may resolve Docker Desktop's shell wrapper before docker.exe; invoke the CLI directly.
if command -v docker.exe >/dev/null 2>&1; then
  docker() { command docker.exe "$@"; }
fi

POSTGRES_IMAGE="postgres:18"
SCHEMA="cash_reporting"
CONTROL="databasechangelog_cash_reporting"
LOCK="databasechangeloglock_cash_reporting"

suffix="$$"
runner_image="csh-db-runner:ci-$suffix"
network="csh-db-ci-$suffix"
container="csh-db-ci-pg-$suffix"
# A throwaway credential for a throwaway container: generated here and never written anywhere.
throwaway="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export POSTGRES_PASSWORD="$throwaway" PGPASSWORD="$throwaway" LIQUIBASE_COMMAND_PASSWORD="$throwaway"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; docker network rm "$network" >/dev/null 2>&1 || true; docker rmi "$runner_image" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail=0
check() { # description, condition result (0 = holds)
  if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=1; fi
}
sql() { docker exec -e PGPASSWORD "$container" psql -U postgres -d postgres -tAc "$1"; }
liquibase() {
  # no volume: the migrations are inside the image, exactly as the compose file runs it
  docker run --rm --network "$network" -e LIQUIBASE_COMMAND_PASSWORD "$runner_image" \
    --url="jdbc:postgresql://$container:5432/postgres" --username=postgres \
    --changelog-file=changelog/changelog-master.yaml \
    --database-changelog-table-name="$CONTROL" \
    --database-changelog-lock-table-name="$LOCK" "$@"
}

echo "building the runner image (deploy/Dockerfile)"
docker build -q -t "$runner_image" -f deploy/Dockerfile . >/dev/null
docker network create "$network" >/dev/null
docker run -d --name "$container" --network "$network" -e POSTGRES_PASSWORD "$POSTGRES_IMAGE" >/dev/null

echo "waiting for PostgreSQL"
for _ in $(seq 1 60); do
  docker exec "$container" pg_isready -U postgres -q 2>/dev/null && sql "select 1" >/dev/null 2>&1 && break
  sleep 1
done
sql "select 1" >/dev/null || { echo "PostgreSQL did not start"; exit 1; }

# Annex J.7: the application user belongs to multi-tour-infra-postgres. CI creates it in its place;
# NOLOGIN is enough because tests become the role with SET ROLE. The schema is NOT created here:
# the tree creates it (01_ddl/01_schemas), as multi-tour-infra-postgres leaves schemas to each -db.
sql "create role cash_reporting_app nologin" >/dev/null

# objects left in the domain schema and roles of the domain (the user is the infrastructure's)
leftovers() { sql "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '$SCHEMA'"; }
domain_roles() { sql "select count(*) from pg_roles where rolname in ('cash_reporting_reader','cash_reporting_writer')"; }
applied() { sql "select count(*) from $CONTROL"; }

echo "step 1 - update builds everything"
liquibase update >/dev/null
first="$(applied)"
check "the tree applied at least one changeset" "$([ "$first" -gt 0 ]; echo $?)"
liquibase validate >/dev/null
check "liquibase validate passes" "$?"

echo "AC-D1.1 - cash tables live only in the domain schema"
check "the tree itself creates the schema $SCHEMA" "$([ "$(sql "select count(*) from pg_namespace where nspname = '$SCHEMA'")" = 1 ]; echo $?)"
in_public="$(sql "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p','v','m','S','f') and c.relname not like 'databasechangelog%'")"
check "nothing of the domain lives in public" "$([ "$in_public" = 0 ]; echo $?)"
check "the control table $CONTROL exists" "$([ "$(sql "select count(*) from information_schema.tables where table_name = '$CONTROL'")" = 1 ]; echo $?)"
check "the default control table databasechangelog does not exist" "$([ "$(sql "select count(*) from information_schema.tables where table_name = 'databasechangelog'")" = 0 ]; echo $?)"
check "reader and writer exist, NOLOGIN and without password (Annex A rule 10)" "$([ "$(domain_roles)" = 2 ] && [ "$(sql "select count(*) from pg_authid where rolname in ('cash_reporting_reader','cash_reporting_writer') and (rolcanlogin or rolpassword is not null)")" = 0 ]; echo $?)"
check "the application user inherits the writer" "$([ "$(sql "select pg_has_role('cash_reporting_app','cash_reporting_writer','member')")" = t ]; echo $?)"

# T-02. The grants per table arrive in T-07, so these probes run as the owner: they judge constraints.
refused() { # statement, constraint name that must refuse it (0 = refused by exactly that constraint)
  out="$(sql "$1" 2>&1 || true)"; case "$out" in *"$2"*) return 0 ;; *) return 1 ;; esac
}
# T-07. Probes that judge grants run as the application itself: SET ROLE cash_reporting_app.
app_sql() { docker exec -e PGPASSWORD "$container" psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -tAc "set role cash_reporting_app; $1" 2>&1; }
app_ok() { app_sql "$1" >/dev/null; }  # 0 when the engine accepted every statement as the application
app_refuses() { case "$(app_sql "$1" || true)" in *"permission denied"*) return 0 ;; *) return 1 ;; esac; }
tenant_a="11111111-1111-4111-8111-111111111111"
tenant_b="22222222-2222-4222-8222-222222222222"
key_insert() { echo "insert into $SCHEMA.idempotency_key (tenant_id, key) values ('$1', $2)"; }
event_insert() { echo "insert into $SCHEMA.outbox_event (tenant_id, event_type, aggregate_id, payload, occurred_at) values ('$tenant_a', '$1', gen_random_uuid(), '{}', now())"; }

echo "AC-D1.16 - an idempotency key is unique per tenant"
key="repeat('k', 8)"
check "a key is accepted" "$(sql "$(key_insert $tenant_a "$key")" >/dev/null 2>&1; echo $?)"
check "the same key twice by one tenant is refused by uq_idempotency_key_tenant_key" "$(refused "$(key_insert $tenant_a "$key")" uq_idempotency_key_tenant_key; echo $?)"
check "another tenant may use the same key" "$(sql "$(key_insert $tenant_b "$key")" >/dev/null 2>&1; echo $?)"
check "a key of 7 characters is refused by chk_idempotency_key_key_length" "$(refused "$(key_insert $tenant_a "repeat('k', 7)")" chk_idempotency_key_key_length; echo $?)"
check "a key of 129 characters is refused by chk_idempotency_key_key_length" "$(refused "$(key_insert $tenant_a "repeat('k', 129)")" chk_idempotency_key_key_length; echo $?)"
check "a key of 128 characters is accepted" "$(sql "$(key_insert $tenant_a "repeat('z', 128)")" >/dev/null 2>&1; echo $?)"

echo "AC-D1.17 - the outbox accepts the nine events in the same transaction"
nine="CashSessionOpened CashSessionClosed CashSessionAutoCreated CashSessionAutoClosed CashSessionReopened CashIncomeRecorded OperationalPaymentRecorded OperationalExpenseRecorded RefundExecuted"
batch="begin;"; for e in $nine; do batch="$batch $(event_insert $e);"; done
sql "$batch rollback;" >/dev/null 2>&1 || true
check "nine events rolled back leave no row (same transaction as the change)" "$([ "$(sql "select count(*) from $SCHEMA.outbox_event")" = 0 ]; echo $?)"
sql "$batch $(key_insert $tenant_a "repeat('t', 8)"); commit;" >/dev/null 2>&1 || true
check "the nine events commit together with their key" "$([ "$(sql "select count(distinct event_type) from $SCHEMA.outbox_event")" = 9 ]; echo $?)"
check "a tenth event name is refused by chk_outbox_event_event_type" "$(refused "$(event_insert CashSessionRenamed)" chk_outbox_event_event_type; echo $?)"
check "a new event starts PENDING with zero attempts" "$([ "$(sql "select count(*) from $SCHEMA.outbox_event where status = 'PENDING' and attempts = 0 and published_at is null")" = 9 ]; echo $?)"
check "an unknown status is refused by chk_outbox_event_status" "$(refused "update $SCHEMA.outbox_event set status = 'LOST'" chk_outbox_event_status; echo $?)"
check "PUBLISHED without published_at is refused by chk_outbox_event_published_at" "$(refused "update $SCHEMA.outbox_event set status = 'PUBLISHED'" chk_outbox_event_published_at; echo $?)"
check "a payload that is not an object is refused by chk_outbox_event_payload_object" "$(refused "insert into $SCHEMA.outbox_event (tenant_id, event_type, aggregate_id, payload, occurred_at) values ('$tenant_a', 'RefundExecuted', gen_random_uuid(), '[]', now())" chk_outbox_event_payload_object; echo $?)"


# T-03. The cash session. Probes run as the owner: they judge constraints, not grants (T-07).
sess() { echo "insert into $SCHEMA.cash_session ($1) values ($2)"; }
S_COLS="tenant_id, business_date, time_zone, origin, created_at"
s_vals() { echo "'$1', '$2', 'America/Bogota', '${3:-AUTOMATIC_CREATION}', now()"; }
OPEN_COLS="opening_base_cents, opened_at, opened_by"
OPEN_VALS="300000, now(), gen_random_uuid()"
CLOSED_COLS="$S_COLS, status, closed_at, closing_mode, closing_balance_cents, closed_by"

echo "AC-D1.2 - cash session holds the columns of the model"
cols="cash_session_id tenant_id business_date time_zone origin created_at opening_base_cents opened_at opened_by closed_at closing_mode status closing_balance_cents closed_by pending_closure"
have=0; for c in $cols; do have=$((have + $(sql "select count(*) from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_session' and column_name = '$c'"))); done
check "the table holds the 15 columns of plan D-03" "$([ "$have" = 15 ]; echo $?)"
check "business_date is a date and the money is bigint cents" "$([ "$(sql "select count(*) from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_session' and ((column_name = 'business_date' and data_type = 'date') or (column_name in ('opening_base_cents','closing_balance_cents') and data_type = 'bigint'))")" = 3 ]; echo $?)"
check "uq_cash_session_tenant_cash_session exists as the target of the composite keys" "$([ "$(sql "select count(*) from pg_constraint where conname = 'uq_cash_session_tenant_cash_session'")" = 1 ]; echo $?)"

echo "AC-D1.3 - a tenant has one cash per date whatever created it"
check "an automatic creation is accepted" "$(sql "$(sess "$S_COLS" "$(s_vals $tenant_a 2026-09-01)")" >/dev/null 2>&1; echo $?)"
check "a second cash for the same tenant and date, same origin, is refused by uq_cash_session_tenant_business_date" "$(refused "$(sess "$S_COLS" "$(s_vals $tenant_a 2026-09-01)")" uq_cash_session_tenant_business_date; echo $?)"
check "a second cash with the other origin is refused by uq_cash_session_tenant_business_date" "$(refused "$(sess "$S_COLS" "$(s_vals $tenant_a 2026-09-01 OPERATIONAL_OPENING)")" uq_cash_session_tenant_business_date; echo $?)"
check "another tenant may hold a cash for that date" "$(sql "$(sess "$S_COLS" "$(s_vals $tenant_b 2026-09-01)")" >/dev/null 2>&1; echo $?)"

echo "AC-D1.4 - a cash session without its required columns is refused"
req_insert() { # the column that is sent null
  local v_tenant="'$tenant_a'" v_date="'2026-09-02'" v_zone="'America/Bogota'" v_origin="'AUTOMATIC_CREATION'" v_created="now()" v_status="'OPEN'"
  case "$1" in tenant_id) v_tenant=null ;; business_date) v_date=null ;; time_zone) v_zone=null ;; origin) v_origin=null ;; created_at) v_created=null ;; status) v_status=null ;; esac
  sess "tenant_id, business_date, time_zone, origin, created_at, status" "$v_tenant, $v_date, $v_zone, $v_origin, $v_created, $v_status"
}
for c in tenant_id business_date time_zone origin created_at status; do
  n="${c%_id}"; check "a null $c is refused by chk_cash_session_${n}_required" "$(refused "$(req_insert $c)" chk_cash_session_${n}_required; echo $?)"
done
check "a blank time zone is refused by chk_cash_session_time_zone_required" "$(refused "$(sess "$S_COLS" "'$tenant_a', '2026-09-02', '  ', 'AUTOMATIC_CREATION', now()")" chk_cash_session_time_zone_required; echo $?)"
check "an origin outside the list is refused by chk_cash_session_origin" "$(refused "$(sess "$S_COLS" "$(s_vals $tenant_a 2026-09-02 MANUAL)")" chk_cash_session_origin; echo $?)"
check "a status outside the list is refused by chk_cash_session_status" "$(refused "$(sess "$S_COLS, status" "$(s_vals $tenant_a 2026-09-02), 'PENDING'")" chk_cash_session_status; echo $?)"
check "a new cash starts OPEN and not pending" "$([ "$(sql "select count(*) from $SCHEMA.cash_session where status = 'OPEN' and not pending_closure")" = 2 ]; echo $?)"

echo "AC-D1.5 - opening data is all or none and the base is not negative"
check "an operational opening with base time and user is accepted" "$(sql "$(sess "$S_COLS, $OPEN_COLS" "$(s_vals $tenant_a 2026-09-03 OPERATIONAL_OPENING), $OPEN_VALS")" >/dev/null 2>&1; echo $?)"
check "an opening with a base of zero is accepted" "$(sql "$(sess "$S_COLS, $OPEN_COLS" "$(s_vals $tenant_a 2026-09-04 OPERATIONAL_OPENING), 0, now(), gen_random_uuid()")" >/dev/null 2>&1; echo $?)"
check "only a base is refused by chk_cash_session_opening_all_or_none" "$(refused "$(sess "$S_COLS, opening_base_cents" "$(s_vals $tenant_a 2026-09-05 OPERATIONAL_OPENING), 300000")" chk_cash_session_opening_all_or_none; echo $?)"
check "only the opening user is refused by chk_cash_session_opening_all_or_none" "$(refused "$(sess "$S_COLS, opened_by" "$(s_vals $tenant_a 2026-09-05 OPERATIONAL_OPENING), gen_random_uuid()")" chk_cash_session_opening_all_or_none; echo $?)"
check "a negative base is refused by chk_cash_session_opening_base_nonnegative" "$(refused "$(sess "$S_COLS, $OPEN_COLS" "$(s_vals $tenant_a 2026-09-05 OPERATIONAL_OPENING), -1, now(), gen_random_uuid()")" chk_cash_session_opening_base_nonnegative; echo $?)"
check "an automatic cash opened later keeps its origin" "$(sql "update $SCHEMA.cash_session set opening_base_cents = 100000, opened_at = now(), opened_by = gen_random_uuid() where tenant_id = '$tenant_a' and business_date = '2026-09-01'" >/dev/null 2>&1; echo $?)"
check "the opened automatic cash is still AUTOMATIC_CREATION" "$([ "$(sql "select origin from $SCHEMA.cash_session where tenant_id = '$tenant_a' and business_date = '2026-09-01'")" = AUTOMATIC_CREATION ]; echo $?)"

echo "AC-D1.6 - a closed session holds its closing and an open one does not"
check "a formal closing with its user is accepted" "$(sql "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-06), 'CLOSED', now(), 'FORMAL', 1100000, gen_random_uuid()")" >/dev/null 2>&1; echo $?)"
check "a negative closing balance is accepted" "$(sql "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-07), 'CLOSED', now(), 'FORMAL', -50000, gen_random_uuid()")" >/dev/null 2>&1; echo $?)"
check "an automatic closing without user is accepted" "$(sql "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-08), 'CLOSED', now(), 'AUTOMATIC', 0, null")" >/dev/null 2>&1; echo $?)"
check "a formal closing without user is refused by chk_cash_session_closed_columns" "$(refused "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-09), 'CLOSED', now(), 'FORMAL', 0, null")" chk_cash_session_closed_columns; echo $?)"
check "an automatic closing with a user is refused by chk_cash_session_closed_columns" "$(refused "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-09), 'CLOSED', now(), 'AUTOMATIC', 0, gen_random_uuid()")" chk_cash_session_closed_columns; echo $?)"
check "a closed session without balance is refused by chk_cash_session_closed_columns" "$(refused "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-09), 'CLOSED', now(), 'FORMAL', null, gen_random_uuid()")" chk_cash_session_closed_columns; echo $?)"
check "a closed session without closing time is refused by chk_cash_session_closed_columns" "$(refused "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-09), 'CLOSED', null, 'FORMAL', 0, gen_random_uuid()")" chk_cash_session_closed_columns; echo $?)"
check "an open session with a closing column is refused by chk_cash_session_closed_columns" "$(refused "$(sess "$S_COLS, closed_at" "$(s_vals $tenant_a 2026-09-09), now()")" chk_cash_session_closed_columns; echo $?)"
check "a closing mode outside the list is refused by chk_cash_session_closing_mode" "$(refused "$(sess "$CLOSED_COLS" "$(s_vals $tenant_a 2026-09-09), 'CLOSED', now(), 'MANUAL', 0, gen_random_uuid()")" chk_cash_session_closing_mode; echo $?)"

echo "AC-D1.7 - the pending mark needs an open session with opening"
check "the mark on an open session with opening is accepted" "$(sql "$(sess "$S_COLS, $OPEN_COLS, pending_closure" "$(s_vals $tenant_a 2026-09-10 OPERATIONAL_OPENING), $OPEN_VALS, true")" >/dev/null 2>&1; echo $?)"
check "the mark without opening is refused by chk_cash_session_pending_closure" "$(refused "$(sess "$S_COLS, pending_closure" "$(s_vals $tenant_a 2026-09-11), true")" chk_cash_session_pending_closure; echo $?)"
check "the mark on a closed session is refused by chk_cash_session_pending_closure" "$(refused "$(sess "$CLOSED_COLS, $OPEN_COLS, pending_closure" "$(s_vals $tenant_a 2026-09-11 OPERATIONAL_OPENING), 'CLOSED', now(), 'FORMAL', 0, gen_random_uuid(), $OPEN_VALS, true")" chk_cash_session_pending_closure; echo $?)"
check "the mark is not a status: PENDING_CLOSURE is refused as status" "$(refused "$(sess "$S_COLS, status" "$(s_vals $tenant_a 2026-09-11), 'PENDING_CLOSURE'")" chk_cash_session_status; echo $?)"

# T-04. The closure snapshot and the reopening. Probes run as the owner: they judge constraints.
# DP-D1-1 (PROPUESTO default): cash_session_closure is an immutable snapshot of each closing.
sid() { sql "select cash_session_id from $SCHEMA.cash_session where tenant_id = '$1' and business_date = '$2'"; }
for d in 2026-10-01 2026-10-02; do
  sql "$(sess "$CLOSED_COLS, $OPEN_COLS" "$(s_vals $tenant_a $d OPERATIONAL_OPENING), 'CLOSED', now(), 'FORMAL', 1120000, gen_random_uuid(), $OPEN_VALS")" >/dev/null
done
sql "$(sess "$CLOSED_COLS, $OPEN_COLS" "$(s_vals $tenant_b 2026-10-01 OPERATIONAL_OPENING), 'CLOSED', now(), 'FORMAL', 1120000, gen_random_uuid(), $OPEN_VALS")" >/dev/null
sess_1="$(sid $tenant_a 2026-10-01)"; sess_2="$(sid $tenant_a 2026-10-02)"; sess_b="$(sid $tenant_b 2026-10-01)"
CL_COLS="tenant_id, cash_session_id, closed_at, closing_mode, closed_by, opening_base_cents, income_cents, operational_payments_cents, operational_expenses_cents, refunds_cents, cash_entries_cents, transfer_entries_cents, cash_exits_cents, transfer_exits_cents, expected_cash_cents, closing_balance_cents"
dv() { if [ "$1" = D ]; then echo "$2"; else echo "$1"; fi; }  # D means the default of the valid closure
# closure_sql tenant session mode closed_by base income cash_in transfer_in cash_out transfer_out expected balance
# valid default: base 300000, income 1000000 (700000 cash + 300000 transfer), payments 100000,
# expenses 50000, refunds 30000 (exits 150000 cash + 30000 transfer), expected 850000, balance 1120000
closure_sql() {
  echo "insert into $SCHEMA.cash_session_closure ($CL_COLS) values ('$1', '$2', now(), '$(dv "${3:-D}" FORMAL)', $(dv "${4:-D}" "gen_random_uuid()"), $(dv "${5:-D}" 300000), $(dv "${6:-D}" 1000000), 100000, 50000, 30000, $(dv "${7:-D}" 700000), $(dv "${8:-D}" 300000), $(dv "${9:-D}" 150000), $(dv "${10:-D}" 30000), $(dv "${11:-D}" 850000), $(dv "${12:-D}" 1120000))"
}

echo "AC-D1.8 - a closure keeps its values and agrees with the formula"
check "a closure that agrees with the formula is accepted" "$(sql "$(closure_sql $tenant_a $sess_1)" >/dev/null 2>&1; echo $?)"
check "a second closure of the same session is accepted (the history is kept)" "$(sql "$(closure_sql $tenant_a $sess_1)" >/dev/null 2>&1; echo $?)"
check "a closure of a never opened session (no base, no expected cash) is accepted" "$(sql "$(closure_sql $tenant_a $sess_2 AUTOMATIC null null 0 0 0 0 0 null 0 | sed 's/, 100000, 50000, 30000,/, 0, 0, 0,/')" >/dev/null 2>&1; echo $?)"
check "the closure holds the 17 columns of plan D-04" "$([ "$(sql "select count(*) from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_session_closure'")" = 17 ]; echo $?)"
check "a wrong closing balance is refused by chk_cash_session_closure_balance" "$(refused "$(closure_sql $tenant_a $sess_1 D D D D D D D D D 1120001)" chk_cash_session_closure_balance; echo $?)"
check "entries by medium that do not add up to income are refused by chk_cash_session_closure_entries_by_medium" "$(refused "$(closure_sql $tenant_a $sess_1 D D D D 700001 D D D 850001)" chk_cash_session_closure_entries_by_medium; echo $?)"
check "exits by medium that do not add up are refused by chk_cash_session_closure_exits_by_medium" "$(refused "$(closure_sql $tenant_a $sess_1 D D D D D D 150001 D 849999)" chk_cash_session_closure_exits_by_medium; echo $?)"
check "a wrong expected cash is refused by chk_cash_session_closure_expected_cash" "$(refused "$(closure_sql $tenant_a $sess_1 D D D D D D D D 850001)" chk_cash_session_closure_expected_cash; echo $?)"
check "expected cash without a base is refused by chk_cash_session_closure_expected_cash" "$(refused "$(closure_sql $tenant_a $sess_1 D D null D D D D D D 820000)" chk_cash_session_closure_expected_cash; echo $?)"
check "a base without expected cash is refused by chk_cash_session_closure_expected_cash" "$(refused "$(closure_sql $tenant_a $sess_1 D D D D D D D D null)" chk_cash_session_closure_expected_cash; echo $?)"
check "a negative amount is refused by chk_cash_session_closure_amounts_nonnegative" "$(refused "$(closure_sql $tenant_a $sess_1 D D D D D -1 D D D D)" chk_cash_session_closure_amounts_nonnegative; echo $?)"
check "a negative closing balance that agrees with the formula is accepted" "$(sql "$(closure_sql $tenant_a $sess_1 D D 0 0 0 0 150000 30000 -150000 -180000)" >/dev/null 2>&1; echo $?)"
check "a formal closure without user is refused by chk_cash_session_closure_closed_by" "$(refused "$(closure_sql $tenant_a $sess_1 FORMAL null)" chk_cash_session_closure_closed_by; echo $?)"
check "an automatic closure with a user is refused by chk_cash_session_closure_closed_by" "$(refused "$(closure_sql $tenant_a $sess_1 AUTOMATIC D)" chk_cash_session_closure_closed_by; echo $?)"
check "a closing mode outside the list is refused by chk_cash_session_closure_closing_mode" "$(refused "$(closure_sql $tenant_a $sess_1 MANUAL)" chk_cash_session_closure_closing_mode; echo $?)"
check "a closure without tenant is refused by chk_cash_session_closure_tenant_required" "$(refused "$(closure_sql $tenant_a $sess_1 | sed "s/values ('$tenant_a'/values (null/")" chk_cash_session_closure_tenant_required; echo $?)"
check "a closure of another tenant's session is refused by fk_cash_session_closure_cash_session" "$(refused "$(closure_sql $tenant_b $sess_1)" fk_cash_session_closure_cash_session; echo $?)"
check "a closure of a session that does not exist is refused by fk_cash_session_closure_cash_session" "$(refused "$(closure_sql $tenant_a 00000000-0000-4000-8000-000000000000)" fk_cash_session_closure_cash_session; echo $?)"

# WAITING for T-07: the grants changeset (plan D-10) gives the application SELECT and INSERT only.
# T07_GRANTS=1 since the T-07 PR: the probes below are counted.
T07_GRANTS=1
echo "AC-D1.8 - a closure is never updated or deleted by the application"
if [ "$T07_GRANTS" = 1 ]; then
  check "UPDATE of a closure by the application is refused" "$(app_refuses "update $SCHEMA.cash_session_closure set income_cents = 0"; echo $?)"
  check "DELETE of a closure by the application is refused" "$(app_refuses "delete from $SCHEMA.cash_session_closure"; echo $?)"
  check "UPDATE of a reopening by the application is refused" "$(app_refuses "update $SCHEMA.cash_session_reopening set reason = 'x'"; echo $?)"
  check "DELETE of a reopening by the application is refused" "$(app_refuses "delete from $SCHEMA.cash_session_reopening"; echo $?)"
else
  echo "  WAIT  closure and reopening have no UPDATE or DELETE for the application: waits for the grants changeset of T-07 (not counted)"
fi

echo "AC-D1.9 - a reopening keeps reason user time and the closure"
cl_1="$(sql "select cash_session_closure_id from $SCHEMA.cash_session_closure where cash_session_id = '$sess_1' order by cash_session_closure_id limit 1" 2>/dev/null || true)"
cl_2="$(sql "select cash_session_closure_id from $SCHEMA.cash_session_closure where cash_session_id = '$sess_1' and cash_session_closure_id <> '$cl_1' order by cash_session_closure_id limit 1" 2>/dev/null || true)"
cl_s2="$(sql "select cash_session_closure_id from $SCHEMA.cash_session_closure where cash_session_id = '$sess_2' limit 1" 2>/dev/null || true)"
check "the closures to reopen exist" "$([ -n "$cl_1" ] && [ -n "$cl_2" ] && [ -n "$cl_s2" ]; echo $?)"
reop_sql() { # tenant session closure reason-literal
  echo "insert into $SCHEMA.cash_session_reopening (tenant_id, cash_session_id, cash_session_closure_id, reopened_by, reopened_at, reason) values ('$1', '$2', '$3', gen_random_uuid(), now(), $4)"
}
check "a reopening with reason user time and its closure is accepted" "$(sql "$(reop_sql $tenant_a $sess_1 "${cl_1:-none}" "'wrong count'")" >/dev/null 2>&1; echo $?)"
check "a second reopening of the same session over another closure is accepted" "$(sql "$(reop_sql $tenant_a $sess_1 "${cl_2:-none}" "'late transfer'")" >/dev/null 2>&1; echo $?)"
check "the two reopenings belong to one session" "$([ "$(sql "select count(*) from $SCHEMA.cash_session_reopening where cash_session_id = '$sess_1'")" = 2 ]; echo $?)"
check "no second cash was created by the reopenings" "$([ "$(sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_a' and business_date = '2026-10-01'")" = 1 ]; echo $?)"
check "a second reopening of the same closure is refused by uq_cash_session_reopening_closure" "$(refused "$(reop_sql $tenant_a $sess_1 "${cl_1:-none}" "'again'")" uq_cash_session_reopening_closure; echo $?)"
check "a blank reason is refused by chk_cash_session_reopening_reason_not_blank" "$(refused "$(reop_sql $tenant_a $sess_2 "${cl_s2:-none}" "'   '")" chk_cash_session_reopening_reason_not_blank; echo $?)"
check "a null reason is refused by chk_cash_session_reopening_reason_not_blank" "$(refused "$(reop_sql $tenant_a $sess_2 "${cl_s2:-none}" null)" chk_cash_session_reopening_reason_not_blank; echo $?)"
check "a reopening that names a closure of another session is refused by fk_cash_session_reopening_closure" "$(refused "$(reop_sql $tenant_a $sess_1 "${cl_s2:-none}" "'wrong closure'")" fk_cash_session_reopening_closure; echo $?)"
check "a reopening of another tenant over this closure is refused by fk_cash_session_reopening_closure" "$(refused "$(reop_sql $tenant_b $sess_b "${cl_s2:-none}" "'other tenant'")" fk_cash_session_reopening_closure; echo $?)"
check "a reopening without user is refused by chk_cash_session_reopening_reopened_by_required" "$(refused "insert into $SCHEMA.cash_session_reopening (tenant_id, cash_session_id, cash_session_closure_id, reopened_at, reason) values ('$tenant_a', '$sess_2', '$cl_s2', now(), 'x')" chk_cash_session_reopening_reopened_by_required; echo $?)"
check "a reopening without time is refused by chk_cash_session_reopening_reopened_at_required" "$(refused "insert into $SCHEMA.cash_session_reopening (tenant_id, cash_session_id, cash_session_closure_id, reopened_by, reason) values ('$tenant_a', '$sess_2', '$cl_s2', gen_random_uuid(), 'x')" chk_cash_session_reopening_reopened_at_required; echo $?)"
check "only the two accepted reopenings exist" "$([ "$(sql "select count(*) from $SCHEMA.cash_session_reopening")" = 2 ]; echo $?)"
echo "AC-D1.23 - a correction note is kept beside the closure and never changes it"
corr_sql() { # tenant session closure justification-literal
  echo "insert into $SCHEMA.cash_closure_correction (tenant_id, cash_session_id, cash_session_closure_id, justification, registered_by, registered_at) values ('$1', '$2', '$3', $4, gen_random_uuid(), now())"
}
closures_before="$(sql "select count(*) from $SCHEMA.cash_session_closure")"
check "a correction with justification, user, time and its closure is accepted" "$(sql "$(corr_sql $tenant_a $sess_1 "${cl_1:-none}" "'description fixed'")" >/dev/null 2>&1; echo $?)"
check "a second correction of the same closure is accepted (several notes per closure)" "$(sql "$(corr_sql $tenant_a $sess_1 "${cl_1:-none}" "'second note'")" >/dev/null 2>&1; echo $?)"
check "a justification of 500 characters is accepted" "$(sql "$(corr_sql $tenant_a $sess_2 "${cl_s2:-none}" "repeat('x', 500)")" >/dev/null 2>&1; echo $?)"
check "a blank justification is refused by chk_cash_closure_correction_justification" "$(refused "$(corr_sql $tenant_a $sess_1 "${cl_1:-none}" "'   '")" chk_cash_closure_correction_justification; echo $?)"
check "a justification of 501 characters is refused by chk_cash_closure_correction_justification" "$(refused "$(corr_sql $tenant_a $sess_1 "${cl_1:-none}" "repeat('x', 501)")" chk_cash_closure_correction_justification; echo $?)"
check "a null justification is refused by chk_cash_closure_correction_justification" "$(refused "$(corr_sql $tenant_a $sess_1 "${cl_1:-none}" null)" chk_cash_closure_correction_justification; echo $?)"
check "a correction that names a closure of another session is refused by fk_cash_closure_correction_closure" "$(refused "$(corr_sql $tenant_a $sess_1 "${cl_s2:-none}" "'wrong closure'")" fk_cash_closure_correction_closure; echo $?)"
check "a correction of another tenant over this closure is refused by fk_cash_closure_correction_closure" "$(refused "$(corr_sql $tenant_b $sess_b "${cl_s2:-none}" "'other tenant'")" fk_cash_closure_correction_closure; echo $?)"
check "a correction without user is refused by chk_cash_closure_correction_registered_by_required" "$(refused "insert into $SCHEMA.cash_closure_correction (tenant_id, cash_session_id, cash_session_closure_id, justification, registered_by, registered_at) values ('$tenant_a', '$sess_1', '${cl_1:-none}', 'no user', null, now())" chk_cash_closure_correction_registered_by_required; echo $?)"
check "a correction without time is refused by chk_cash_closure_correction_registered_at_required" "$(refused "insert into $SCHEMA.cash_closure_correction (tenant_id, cash_session_id, cash_session_closure_id, justification, registered_by, registered_at) values ('$tenant_a', '$sess_1', '${cl_1:-none}', 'no time', gen_random_uuid(), null)" chk_cash_closure_correction_registered_at_required; echo $?)"
check "only the three accepted corrections exist" "$([ "$(sql "select count(*) from $SCHEMA.cash_closure_correction")" = 3 ]; echo $?)"
check "the corrections changed no closure and created no second cash" "$([ "$(sql "select count(*) from $SCHEMA.cash_session_closure")" = "$closures_before" ]; echo $?)"
# HU-CSH-002 (plan D-03 to D-05): the dashboard projection and the processed events. Probes run as the owner.
echo "AC-D2.1 to AC-D2.7 - the dashboard projection holds six sets and refuses what is not an array or too long"
dash_cols="tenant_id, report_date, updated_at"
dash_sql() { # tenant-literal date-literal extra-columns extra-values
  echo "insert into $SCHEMA.daily_dashboard_projection (tenant_id, report_date, updated_at${3:+, $3}) values ($1, $2, now()${4:+, $4})"
}
check "the projection table lives in the domain schema" "$([ "$(sql "select count(*) from information_schema.tables where table_schema = '$SCHEMA' and table_name = 'daily_dashboard_projection'")" = 1 ]; echo $?)"
check "an empty day is a valid row of six empty arrays" "$(sql "$(dash_sql "'$tenant_a'" "'2026-10-01'")" >/dev/null 2>&1; echo $?)"
check "the six sets default to an empty array" "$([ "$(sql "select count(*) from $SCHEMA.daily_dashboard_projection where tenant_id = '$tenant_a' and created_reservations = '[]'::jsonb and pending_payment_reservations = '[]'::jsonb and confirmed_reservations = '[]'::jsonb and confirmed_with_balance = '[]'::jsonb and cancelled_reservations = '[]'::jsonb and upcoming_services = '[]'::jsonb")" = 1 ]; echo $?)"
check "a second projection of the same tenant and date is refused by uq_daily_dashboard_projection_tenant_report_date" "$(refused "$(dash_sql "'$tenant_a'" "'2026-10-01'")" uq_daily_dashboard_projection_tenant_report_date; echo $?)"
check "another tenant may hold a projection for the same date" "$(sql "$(dash_sql "'$tenant_b'" "'2026-10-01'")" >/dev/null 2>&1; echo $?)"
check "a projection without tenant is refused by chk_daily_dashboard_projection_tenant_required" "$(refused "$(dash_sql null "'2026-10-02'")" chk_daily_dashboard_projection_tenant_required; echo $?)"
check "a projection without date is refused by chk_daily_dashboard_projection_report_date_required" "$(refused "$(dash_sql "'$tenant_a'" null)" chk_daily_dashboard_projection_report_date_required; echo $?)"
for col in created_reservations pending_payment_reservations confirmed_reservations confirmed_with_balance cancelled_reservations upcoming_services; do
  check "a set that is not an array is refused by chk_dashboard_${col}_is_array ($col)" "$(refused "$(dash_sql "'$tenant_a'" "'2026-10-03'" $col "'{}'::jsonb")" chk_dashboard_${col}_is_array; echo $?)"
  # a balance set sits within the confirmed one, whose own maximum fires first: the engine still refuses it
  max_name="chk_dashboard_${col}_max_items"; [ "$col" = confirmed_with_balance ] && max_name="violates check constraint"
  check "a set over 10000 elements is refused by its maximum ($col)" "$(refused "$(dash_sql "'$tenant_a'" "'2026-10-03'" $col "(select jsonb_agg(g) from generate_series(1, 10001) g)")" "$max_name"; echo $?)"
done
check "a balance reservation that is not confirmed is refused by chk_dashboard_balance_within_confirmed" "$(refused "$(dash_sql "'$tenant_a'" "'2026-10-04'" confirmed_with_balance "'[\"r1\"]'::jsonb")" chk_dashboard_balance_within_confirmed; echo $?)"
check "a balance reservation that is confirmed is accepted" "$(sql "$(dash_sql "'$tenant_a'" "'2026-10-05'" "confirmed_reservations, confirmed_with_balance" "'[\"r1\",\"r2\"]'::jsonb, '[\"r1\"]'::jsonb")" >/dev/null 2>&1; echo $?)"
check "the projection keeps the time of the newest event applied (nullable until one is applied)" "$(sql "update $SCHEMA.daily_dashboard_projection set last_event_occurred_at = now() where tenant_id = '$tenant_a' and report_date = '2026-10-05'" >/dev/null 2>&1; echo $?)"

echo "AC-D2.8 - a processed event is recorded once per tenant"
event_row() { echo "insert into $SCHEMA.processed_event (tenant_id, event_id, event_type, processed_at) values ('$1', '$2', 'ReservationConfirmed', now())"; }
ev1="aaaaaaaa-0000-4000-8000-000000000001"
check "a processed event is recorded" "$(sql "$(event_row $tenant_a $ev1)" >/dev/null 2>&1; echo $?)"
check "the same event twice for one tenant is refused by uq_processed_event_tenant_event" "$(refused "$(event_row $tenant_a $ev1)" uq_processed_event_tenant_event; echo $?)"
check "another tenant may record the same event id" "$(sql "$(event_row $tenant_b $ev1)" >/dev/null 2>&1; echo $?)"
check "a processed event without tenant, event id or type is refused" "$(refused "insert into $SCHEMA.processed_event (tenant_id, event_id, event_type, processed_at) values (null, '$ev1', 'X', now())" chk_processed_event_tenant_required; echo $?)"

# T-05. The movements. Probes run as the owner: they judge constraints, not grants (T-07).
# Whether the cash had its opening is not checked here: it is DD-4, the -api's guard.
MV_COLS="tenant_id, cash_session_id, movement_type, payment_medium, amount_cents, registered_at, registered_by, concept"
# mv_sql tenant session type medium amount [extra-column extra-value]
mv_sql() {
  echo "insert into $SCHEMA.cash_movement ($MV_COLS${6:+, $6}) values ('$1', '$2', '$3', '$4', $5, now(), gen_random_uuid(), 'daily sale'${7:+, $7})"
}

echo "AC-D1.10 - a cash movement without its required columns or with a bad amount is refused"
check "an income in cash is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 INCOME CASH 250000)" >/dev/null 2>&1; echo $?)"
check "an operational payment by transfer is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 OPERATIONAL_PAYMENT TRANSFER 100000)" >/dev/null 2>&1; echo $?)"
check "an operational expense in cash is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 OPERATIONAL_EXPENSE CASH 50000)" >/dev/null 2>&1; echo $?)"
check "a refund by transfer is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 REFUND TRANSFER 30000)" >/dev/null 2>&1; echo $?)"
check "the movement holds the 12 columns of the model" "$([ "$(sql "select count(*) from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_movement'")" = 12 ]; echo $?)"
check "the amount is bigint cents" "$([ "$(sql "select data_type from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_movement' and column_name = 'amount_cents'")" = bigint ]; echo $?)"
check "an amount of zero is refused by chk_cash_movement_amount_positive" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH 0)" chk_cash_movement_amount_positive; echo $?)"
check "a negative amount is refused by chk_cash_movement_amount_positive" "$(refused "$(mv_sql $tenant_a $sess_1 OPERATIONAL_EXPENSE CASH -1)" chk_cash_movement_amount_positive; echo $?)"
check "a null amount is refused by chk_cash_movement_amount_required" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH null)" chk_cash_movement_amount_required; echo $?)"
check "a type outside the list is refused by chk_cash_movement_type" "$(refused "$(mv_sql $tenant_a $sess_1 DONATION CASH 1000)" chk_cash_movement_type; echo $?)"
check "a null type is refused by chk_cash_movement_type" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH 1000 | sed "s/'INCOME'/null/")" chk_cash_movement_type; echo $?)"
check "a medium outside the list is refused by chk_cash_movement_payment_medium" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CARD 1000)" chk_cash_movement_payment_medium; echo $?)"
check "a null medium is refused by chk_cash_movement_payment_medium" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH 1000 | sed "s/'CASH'/null/")" chk_cash_movement_payment_medium; echo $?)"
check "a movement without tenant is refused by chk_cash_movement_tenant_required" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH 1000 | sed "s/values ('$tenant_a'/values (null/")" chk_cash_movement_tenant_required; echo $?)"
check "a movement without session is refused by chk_cash_movement_cash_session_required" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH 1000 | sed "s/'$sess_1'/null/")" chk_cash_movement_cash_session_required; echo $?)"
check "a movement without time is refused by chk_cash_movement_registered_at_required" "$(refused "insert into $SCHEMA.cash_movement (tenant_id, cash_session_id, movement_type, payment_medium, amount_cents, registered_by, concept) values ('$tenant_a', '$sess_1', 'INCOME', 'CASH', 1000, gen_random_uuid(), 'daily sale')" chk_cash_movement_registered_at_required; echo $?)"
check "a movement without user is refused by chk_cash_movement_registered_by_required" "$(refused "insert into $SCHEMA.cash_movement (tenant_id, cash_session_id, movement_type, payment_medium, amount_cents, registered_at, concept) values ('$tenant_a', '$sess_1', 'INCOME', 'CASH', 1000, now(), 'daily sale')" chk_cash_movement_registered_by_required; echo $?)"
check "the after-closing mark starts false" "$([ "$(sql "select count(*) from $SCHEMA.cash_movement where after_closing")" = 0 ]; echo $?)"

# T-05b. The concept of the movement (amendment 2026-11-03): required, not blank, at most 200, for every type.
# A null is refused by the NOT NULL itself, which names the column; the two checks name the blank and the length.
echo "AC-D1.10 - a movement without a concept or with a blank one is refused"
concept_of() { mv_sql $tenant_a $sess_1 INCOME CASH 1000 | sed "s/'daily sale'/$1/"; }
long_200="$(head -c 200 /dev/zero | tr '\0' x)"; long_201="$(head -c 201 /dev/zero | tr '\0' x)"
check "a movement without a concept is refused" "$(refused "$(concept_of null)" 'null value in column "concept"'; echo $?)"
check "a blank concept is refused by chk_cash_movement_concept_required" "$(refused "$(concept_of "''")" chk_cash_movement_concept_required; echo $?)"
check "a concept of only spaces is refused by chk_cash_movement_concept_required" "$(refused "$(concept_of "'   '")" chk_cash_movement_concept_required; echo $?)"
check "a concept with text is accepted for every type, refund included" "$(sql "$(mv_sql $tenant_a $sess_1 REFUND CASH 1000)" >/dev/null 2>&1; echo $?)"
echo "AC-D1.10 - a concept longer than 200 characters is refused"
check "a concept of 201 characters is refused by chk_cash_movement_concept_length" "$(refused "$(concept_of "'$long_201'")" chk_cash_movement_concept_length; echo $?)"
check "a concept of 200 characters is accepted" "$(sql "$(concept_of "'$long_200'")" >/dev/null 2>&1; echo $?)"

# T-05c. The reservation of an income paid for a reservation (decision 2026-11-10, HU-CSH-001): an optional plain id of
# domain 2 (Annex J.3.4), null for a movement typed by hand. Movements stay immutable: a reversal is a new movement.
echo "AC-D1.10 - the movement may carry the reservation it was paid for"
check "reservation_id is a nullable uuid" "$([ "$(sql "select data_type || '/' || is_nullable from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_movement' and column_name = 'reservation_id'")" = 'uuid/YES' ]; echo $?)"
check "an income with its reservation is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 INCOME TRANSFER 1000 reservation_id "'dddddddd-0000-4000-8000-0000000000aa'")" >/dev/null 2>&1; echo $?)"
check "the reservation is stored as given" "$([ "$(sql "select count(*) from $SCHEMA.cash_movement where reservation_id = 'dddddddd-0000-4000-8000-0000000000aa'")" = 1 ]; echo $?)"
check "a movement without a reservation is still accepted" "$(sql "$(mv_sql $tenant_a $sess_1 OPERATIONAL_EXPENSE CASH 1000)" >/dev/null 2>&1; echo $?)"
echo "a movement may compensate another one (decision 2026-11-10): a REFUND reverses an income and an INCOME reverses a refund, once"
rev_src="$(sql "select cash_movement_id from $SCHEMA.cash_movement where reservation_id = 'dddddddd-0000-4000-8000-0000000000aa'")"
check "reverses_cash_movement_id is a nullable uuid" "$([ "$(sql "select data_type || '/' || is_nullable from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'cash_movement' and column_name = 'reverses_cash_movement_id'")" = 'uuid/YES' ]; echo $?)"
check "a compensating refund of that movement is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 REFUND TRANSFER 1000 reverses_cash_movement_id "'$rev_src'")" >/dev/null 2>&1; echo $?)"
rev_refund="$(sql "select cash_movement_id from $SCHEMA.cash_movement where reverses_cash_movement_id = '$rev_src'")"
check "a compensating income of that refund is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 INCOME TRANSFER 1000 reverses_cash_movement_id "'$rev_refund'")" >/dev/null 2>&1; echo $?)"
check "a second compensation of the refund is refused by uq_cash_movement_reverses" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME TRANSFER 1000 reverses_cash_movement_id "'$rev_refund'")" uq_cash_movement_reverses; echo $?)"
check "a second compensation of the same movement is refused by uq_cash_movement_reverses" "$(refused "$(mv_sql $tenant_a $sess_1 REFUND TRANSFER 1000 reverses_cash_movement_id "'$rev_src'")" uq_cash_movement_reverses; echo $?)"
check "a compensation that is neither a REFUND nor an INCOME is refused by chk_cash_movement_reverses_income_or_refund" "$(refused "$(mv_sql $tenant_a $sess_1 OPERATIONAL_EXPENSE TRANSFER 1000 reverses_cash_movement_id "'$rev_src'")" chk_cash_movement_reverses_income_or_refund; echo $?)"
check "a compensation of a movement that does not exist is refused by fk_cash_movement_reverses" "$(refused "$(mv_sql $tenant_a $sess_1 REFUND TRANSFER 1000 reverses_cash_movement_id "'eeeeeeee-0000-4000-8000-000000000001'")" fk_cash_movement_reverses; echo $?)"
check "a compensation of another tenant's movement is refused by fk_cash_movement_reverses" "$(refused "$(mv_sql $tenant_b "$(sid $tenant_b 2026-09-01)" REFUND TRANSFER 1000 reverses_cash_movement_id "'$rev_src'")" fk_cash_movement_reverses; echo $?)"

echo "AC-D1.11 - only a transfer can be marked after closing"
check "a transfer marked after closing is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 INCOME TRANSFER 80000 after_closing true)" >/dev/null 2>&1; echo $?)"
check "a cash movement marked after closing is refused by chk_cash_movement_after_closing_transfer_only" "$(refused "$(mv_sql $tenant_a $sess_1 INCOME CASH 80000 after_closing true)" chk_cash_movement_after_closing_transfer_only; echo $?)"
check "a cash payment marked after closing is refused by chk_cash_movement_after_closing_transfer_only" "$(refused "$(mv_sql $tenant_a $sess_1 OPERATIONAL_PAYMENT CASH 80000 after_closing true)" chk_cash_movement_after_closing_transfer_only; echo $?)"
check "a cash movement not marked is accepted" "$(sql "$(mv_sql $tenant_a $sess_1 INCOME CASH 80000 after_closing false)" >/dev/null 2>&1; echo $?)"

echo "AC-D1.12 - a movement cannot point at another tenant's session"
check "a movement of tenant B over tenant A's session is refused by fk_cash_movement_cash_session" "$(refused "$(mv_sql $tenant_b $sess_1 INCOME CASH 1000)" fk_cash_movement_cash_session; echo $?)"
check "a movement of tenant B over its own session is accepted" "$(sql "$(mv_sql $tenant_b $sess_b INCOME CASH 1000)" >/dev/null 2>&1; echo $?)"
check "a movement of a session that does not exist is refused by fk_cash_movement_cash_session" "$(refused "$(mv_sql $tenant_a 00000000-0000-4000-8000-000000000000 INCOME CASH 1000)" fk_cash_movement_cash_session; echo $?)"
check "a movement over a session never opened is accepted here (DD-4: the -api guards the opening)" "$(sql "$(mv_sql $tenant_a $sess_2 INCOME CASH 1000)" >/dev/null 2>&1; echo $?)"

# WAITING for T-07, same flag as the closure probe above: the grants changeset gives the application
# SELECT and INSERT only on cash_movement. Written now, not counted until T07_GRANTS is flipped to 1.
echo "AC-D1.13 - a movement cannot be updated or deleted by the application"
if [ "$T07_GRANTS" = 1 ]; then
  check "UPDATE of a movement by the application is refused" "$(app_refuses "update $SCHEMA.cash_movement set amount_cents = 1"; echo $?)"
  check "DELETE of a movement by the application is refused" "$(app_refuses "delete from $SCHEMA.cash_movement"; echo $?)"
else
  echo "  WAIT  a movement has no UPDATE or DELETE for the application: waits for the grants changeset of T-07 (not counted)"
fi

# T-06. The refund detail. Probes run as the owner: they judge constraints, not grants (T-07).
# Movements with known ids so that the details can point at them; each detail is tried against its own.
mv_m1="aaaaaaaa-0000-4000-8000-000000000001"  # refund, cash, 40000
mv_m2="aaaaaaaa-0000-4000-8000-000000000002"  # refund, transfer, 50000
mv_m3="aaaaaaaa-0000-4000-8000-000000000003"  # income, cash, 40000 (not a refund)
mv_m4="aaaaaaaa-0000-4000-8000-000000000004"  # refund, cash, 20000
mv_m5="aaaaaaaa-0000-4000-8000-000000000005"  # refund, cash, 10000
for spec in "$mv_m1 REFUND CASH 40000" "$mv_m2 REFUND TRANSFER 50000" "$mv_m3 INCOME CASH 40000" "$mv_m4 REFUND CASH 20000" "$mv_m5 REFUND CASH 10000"; do
  set -- $spec
  sql "$(mv_sql $tenant_a $sess_1 $2 $3 $4 cash_movement_id "'$1'")" >/dev/null
done
# rf_sql tenant session movement amount method [authorization]
rf_sql() {
  echo "insert into $SCHEMA.refund_movement (tenant_id, cash_session_id, cash_movement_id, refund_authorization_id, reservation_id, amount_cents, reason, executed_by, outflow_method, executed_at) values ('$1', '$2', '$3', ${6:-gen_random_uuid()}, gen_random_uuid(), $4, 'customer cancelled', gen_random_uuid(), '$5', now())"
}
rf_cols() { sql "select count(*) from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'refund_movement'"; }

echo "AC-D1.14 - a refund agrees with its cash movement"
check "the refund detail holds the 12 columns of the model" "$([ "$(rf_cols)" = 12 ]; echo $?)"
check "the detail type is generated and stored as REFUND" "$([ "$(sql "select is_generated || '/' || generation_expression from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'refund_movement' and column_name = 'movement_type'")" = "ALWAYS/'REFUND'::text" ]; echo $?)"
check "a refund that agrees with its movement is accepted" "$(sql "$(rf_sql $tenant_a $sess_1 $mv_m1 40000 CASH)" >/dev/null 2>&1; echo $?)"
check "a refund by transfer that agrees with its movement is accepted" "$(sql "$(rf_sql $tenant_a $sess_1 $mv_m2 50000 TRANSFER)" >/dev/null 2>&1; echo $?)"
check "a different amount is refused by fk_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20001 CASH)" fk_refund_movement_cash_movement; echo $?)"
check "a different medium is refused by fk_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 TRANSFER)" fk_refund_movement_cash_movement; echo $?)"
check "a movement not of type refund is refused by fk_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m3 40000 CASH)" fk_refund_movement_cash_movement; echo $?)"
check "a movement that does not exist is refused by fk_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_a $sess_1 00000000-0000-4000-8000-000000000000 20000 CASH)" fk_refund_movement_cash_movement; echo $?)"
check "another tenant's detail over the movement is refused by fk_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_b $sess_1 $mv_m4 20000 CASH)" fk_refund_movement_cash_movement; echo $?)"
check "another session's detail over the movement is refused by fk_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_a $sess_2 $mv_m4 20000 CASH)" fk_refund_movement_cash_movement; echo $?)"
check "a second detail for one movement is refused by uq_refund_movement_cash_movement" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m1 40000 CASH)" uq_refund_movement_cash_movement; echo $?)"
check "the movement keeps its target unique for the composite key" "$([ "$(sql "select count(*) from pg_constraint where conname = 'uq_cash_movement_refund_target' and contype = 'u' and conrelid = '$SCHEMA.cash_movement'::regclass")" = 1 ]; echo $?)"
check "an outflow method outside the list is refused by chk_refund_movement_outflow_method" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CARD)" chk_refund_movement_outflow_method; echo $?)"
check "a blank reason is refused by chk_refund_movement_reason_not_blank" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH | sed "s/'customer cancelled'/'   '/")" chk_refund_movement_reason_not_blank; echo $?)"
check "a null reason is refused by chk_refund_movement_reason_not_blank" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH | sed "s/'customer cancelled'/null/")" chk_refund_movement_reason_not_blank; echo $?)"
check "a detail without reservation is refused by chk_refund_movement_reservation_required" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH | sed "s/, gen_random_uuid(), 20000/, null, 20000/")" chk_refund_movement_reservation_required; echo $?)"
check "a detail without authorization is refused by chk_refund_movement_refund_authorization_required" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH null)" chk_refund_movement_refund_authorization_required; echo $?)"
check "a detail without executing user is refused by chk_refund_movement_executed_by_required" "$(refused "insert into $SCHEMA.refund_movement (tenant_id, cash_session_id, cash_movement_id, refund_authorization_id, reservation_id, amount_cents, reason, outflow_method, executed_at) values ('$tenant_a', '$sess_1', '$mv_m4', gen_random_uuid(), gen_random_uuid(), 20000, 'customer cancelled', 'CASH', now())" chk_refund_movement_executed_by_required; echo $?)"
check "a detail without time is refused by chk_refund_movement_executed_at_required" "$(refused "insert into $SCHEMA.refund_movement (tenant_id, cash_session_id, cash_movement_id, refund_authorization_id, reservation_id, amount_cents, reason, executed_by, outflow_method) values ('$tenant_a', '$sess_1', '$mv_m4', gen_random_uuid(), gen_random_uuid(), 20000, 'customer cancelled', gen_random_uuid(), 'CASH')" chk_refund_movement_executed_at_required; echo $?)"
check "a detail without amount is refused by chk_refund_movement_amount_required" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 null CASH)" chk_refund_movement_amount_required; echo $?)"
check "a detail without tenant is refused by chk_refund_movement_tenant_required" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH | sed "s/values ('$tenant_a'/values (null/")" chk_refund_movement_tenant_required; echo $?)"
check "a detail without session is refused by chk_refund_movement_cash_session_required" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH | sed "s/'$sess_1'/null/")" chk_refund_movement_cash_session_required; echo $?)"
check "a detail without movement is refused by chk_refund_movement_cash_movement_required" "$(refused "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH | sed "s/'$mv_m4'/null/")" chk_refund_movement_cash_movement_required; echo $?)"
check "the stored detail type is REFUND" "$([ "$(sql "select count(*) from $SCHEMA.refund_movement where movement_type = 'REFUND'")" = 2 ]; echo $?)"

echo "AC-D1.15 - cross-domain ids are plain columns"
check "reservation and authorization carry no foreign key: the only key of the detail is the movement's" "$([ "$(sql "select string_agg(conname, ',' order by conname) from pg_constraint where conrelid = '$SCHEMA.refund_movement'::regclass and contype = 'f'")" = fk_refund_movement_cash_movement ]; echo $?)"
check "no foreign key of the detail leaves the domain schema" "$([ "$(sql "select count(*) from pg_constraint c join pg_class t on t.oid = c.confrelid join pg_namespace n on n.oid = t.relnamespace where c.conrelid = '$SCHEMA.refund_movement'::regclass and c.contype = 'f' and n.nspname <> '$SCHEMA'")" = 0 ]; echo $?)"
auth_x="bbbbbbbb-0000-4000-8000-000000000001"
check "a first detail of an authorization that exists nowhere in this database is accepted" "$(sql "$(rf_sql $tenant_a $sess_1 $mv_m4 20000 CASH "'$auth_x'")" >/dev/null 2>&1; echo $?)"
check "a second detail of the same authorization is accepted (partial executions)" "$(sql "$(rf_sql $tenant_a $sess_1 $mv_m5 10000 CASH "'$auth_x'")" >/dev/null 2>&1; echo $?)"
check "the two details share the authorization" "$([ "$(sql "select count(*) from $SCHEMA.refund_movement where refund_authorization_id = '$auth_x'")" = 2 ]; echo $?)"

# T-07. Grants, isolation and plans. These probes run as the application: SET ROLE cash_reporting_app.
tenant_c="33333333-3333-4333-8333-333333333333"
tenant_d="44444444-4444-4444-8444-444444444444"
privs() { # role table: the privileges it holds, in a fixed order
  sql "select coalesce(string_agg(p, ',' order by array_position(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'], p)), 'none') from unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p where has_table_privilege('$1', '$SCHEMA.$2', p)"
}
business_rows() { sql "select (select count(*) from $SCHEMA.cash_session) + (select count(*) from $SCHEMA.cash_session_closure) + (select count(*) from $SCHEMA.cash_session_reopening) + (select count(*) from $SCHEMA.cash_movement) + (select count(*) from $SCHEMA.refund_movement)"; }

echo "AC-D1.18 - two tenants hold the same data and none sees the other"
for t in $tenant_c $tenant_d; do
  check "tenant ${t:0:1} opens a cash for 2026-11-01 as the application" "$(app_ok "$(sess "$S_COLS, $OPEN_COLS" "$(s_vals $t 2026-11-01 OPERATIONAL_OPENING), $OPEN_VALS")"; echo $?)"
  sess_t="$(sid $t 2026-11-01)"
  check "tenant ${t:0:1} records two movements and a key as the application" "$(app_ok "$(mv_sql $t "${sess_t:-none}" INCOME CASH 1000); $(mv_sql $t "${sess_t:-none}" OPERATIONAL_EXPENSE CASH 2000); $(key_insert $t "repeat('s', 8)")"; echo $?)"
done
sess_c="$(sid $tenant_c 2026-11-01)"; sess_d="$(sid $tenant_d 2026-11-01)"
check "each tenant sees exactly its own cash and the two ids differ" "$([ "$(app_sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_c'")" = 1 ] && [ "$(app_sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_d'")" = 1 ] && [ -n "$sess_c" ] && [ "$sess_c" != "$sess_d" ]; echo $?)"
check "a query scoped to C never returns D's cash" "$([ "$(app_sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_c' and cash_session_id = '$sess_d'")" = 0 ]; echo $?)"
check "a query scoped to D never returns C's cash" "$([ "$(app_sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_d' and cash_session_id = '$sess_c'")" = 0 ]; echo $?)"
check "C holds 2 movements and none of them sits in D's session" "$([ "$(app_sql "select count(*) from $SCHEMA.cash_movement where tenant_id = '$tenant_c'")" = 2 ] && [ "$(app_sql "select count(*) from $SCHEMA.cash_movement where tenant_id = '$tenant_c' and cash_session_id = '$sess_d'")" = 0 ]; echo $?)"
check "D holds 2 movements and none of them sits in C's session" "$([ "$(app_sql "select count(*) from $SCHEMA.cash_movement where tenant_id = '$tenant_d'")" = 2 ] && [ "$(app_sql "select count(*) from $SCHEMA.cash_movement where tenant_id = '$tenant_d' and cash_session_id = '$sess_c'")" = 0 ]; echo $?)"
check "the same data on both sides: equal date, count and total" "$([ "$(app_sql "select count(distinct (s.business_date, m.n, m.total)) from $SCHEMA.cash_session s join (select tenant_id, count(*) n, sum(amount_cents) total from $SCHEMA.cash_movement group by tenant_id) m using (tenant_id) where s.tenant_id in ('$tenant_c', '$tenant_d')")" = 1 ]; echo $?)"
check "the same idempotency key is held once by each tenant, each seeing only its own" "$([ "$(app_sql "select count(*) from $SCHEMA.idempotency_key where tenant_id = '$tenant_c' and key = repeat('s', 8)")" = 1 ] && [ "$(sql "select count(*) from $SCHEMA.idempotency_key where key = repeat('s', 8) and tenant_id in ('$tenant_c', '$tenant_d')")" = 2 ]; echo $?)"

echo "AC-D1.19 - no business row can be deleted by the application user"
check "the application holds exactly SELECT, INSERT, UPDATE on cash_session" "$([ "$(privs cash_reporting_app cash_session)" = "SELECT,INSERT,UPDATE" ]; echo $?)"
for t in cash_session_closure cash_session_reopening cash_closure_correction cash_movement refund_movement; do
  check "the application holds exactly SELECT, INSERT on $t" "$([ "$(privs cash_reporting_app $t)" = "SELECT,INSERT" ]; echo $?)"
done
for t in outbox_event idempotency_key; do
  check "the application holds SELECT, INSERT, UPDATE, DELETE on $t and no more" "$([ "$(privs cash_reporting_app $t)" = "SELECT,INSERT,UPDATE,DELETE" ]; echo $?)"
done
before="$(business_rows)"
for t in cash_session cash_session_closure cash_session_reopening cash_closure_correction cash_movement refund_movement; do
  check "DELETE on $t by the application is refused" "$(app_refuses "delete from $SCHEMA.$t"; echo $?)"
done
check "no business row disappeared" "$([ "$(business_rows)" = "$before" ] && [ "$before" -gt 0 ]; echo $?)"
check "the application holds exactly SELECT, INSERT, UPDATE on daily_dashboard_projection" "$([ "$(privs cash_reporting_app daily_dashboard_projection)" = "SELECT,INSERT,UPDATE" ]; echo $?)"
check "the application holds exactly SELECT, INSERT on processed_event" "$([ "$(privs cash_reporting_app processed_event)" = "SELECT,INSERT" ]; echo $?)"
check "DELETE on daily_dashboard_projection by the application is refused" "$(app_refuses "delete from $SCHEMA.daily_dashboard_projection"; echo $?)"
check "DELETE and UPDATE on processed_event by the application are refused" "$(app_refuses "delete from $SCHEMA.processed_event"; echo $?)"
check "the reader holds only SELECT on daily_dashboard_projection and nothing on processed_event" "$([ "$(privs cash_reporting_reader daily_dashboard_projection)" = SELECT ] && [ "$(privs cash_reporting_reader processed_event)" = none ]; echo $?)"
check "UPDATE of a correction by the application is refused" "$(app_refuses "update $SCHEMA.cash_closure_correction set justification = 'x'"; echo $?)"
check "UPDATE of a refund detail by the application is refused" "$(app_refuses "update $SCHEMA.refund_movement set reason = 'x'"; echo $?)"
check "the application still closes and reopens a cash: UPDATE of cash_session is accepted" "$(app_ok "update $SCHEMA.cash_session set pending_closure = true where cash_session_id = '$sess_c'"; echo $?)"
check "the technical tables accept deletion: a key is inserted and deleted by the application" "$(app_ok "$(key_insert $tenant_a "'delete-me-1'"); delete from $SCHEMA.idempotency_key where tenant_id = '$tenant_a' and key = 'delete-me-1'"; echo $?)"
check "the key is gone" "$([ "$(sql "select count(*) from $SCHEMA.idempotency_key where key = 'delete-me-1'")" = 0 ]; echo $?)"
check "the technical tables accept deletion: an event is inserted and deleted by the application" "$(app_ok "insert into $SCHEMA.outbox_event (tenant_id, event_type, aggregate_id, payload, occurred_at) values ('$tenant_a', 'RefundExecuted', 'cccccccc-0000-4000-8000-000000000001', '{}', now()); delete from $SCHEMA.outbox_event where aggregate_id = 'cccccccc-0000-4000-8000-000000000001'"; echo $?)"
check "the event is gone" "$([ "$(sql "select count(*) from $SCHEMA.outbox_event where aggregate_id = 'cccccccc-0000-4000-8000-000000000001'")" = 0 ]; echo $?)"
for t in cash_session cash_session_closure cash_session_reopening cash_closure_correction cash_movement refund_movement; do
  check "the reader holds only SELECT on $t" "$([ "$(privs cash_reporting_reader $t)" = SELECT ]; echo $?)"
done
check "the reader holds nothing on the two technical tables" "$([ "$(privs cash_reporting_reader outbox_event)" = none ] && [ "$(privs cash_reporting_reader idempotency_key)" = none ]; echo $?)"

echo "AC-D1.20 - the five reads use their indexes"
# The tables hold a handful of rows, so the planner would prefer a sequential scan whatever the indexes.
# enable_seqscan and enable_bitmapscan are set off inside each probe: the plan then shows the index that serves the
# read in its own order, and a Sort node would show an index that does not give the order the screen needs.
plan() { app_sql "set enable_seqscan = off; set enable_bitmapscan = off; explain (costs off) $1"; }
read_1="select * from $SCHEMA.cash_session where tenant_id = '$tenant_a' and business_date = '2026-09-01'"
read_2="select * from $SCHEMA.cash_movement where tenant_id = '$tenant_a' and cash_session_id = '$sess_1' order by registered_at desc"
read_3="select * from $SCHEMA.cash_session_closure where tenant_id = '$tenant_a' order by closed_at desc"
read_4="select * from $SCHEMA.cash_session where tenant_id = '$tenant_a' and status = 'OPEN' order by business_date"
read_5="select * from $SCHEMA.refund_movement where tenant_id = '$tenant_a' and reservation_id = 'dddddddd-0000-4000-8000-000000000001'"
read_6="select * from $SCHEMA.outbox_event where status = 'PENDING' order by occurred_at limit 100"
n=0
for spec in "uq_cash_session_tenant_business_date|$read_1|the cash of a day" "idx_cash_movement_tenant_session_registered_at|$read_2|the movements of a session by time" "idx_cash_session_closure_tenant_closed_at|$read_3|the closures newest first" "idx_cash_session_tenant_open|$read_4|the open or pending sessions of a tenant" "idx_refund_movement_tenant_reservation|$read_5|the refunds of a reservation" "idx_outbox_event_pending|$read_6|the relay's pending events (declared exception to tenant first)"; do
  n=$((n + 1)); idx="${spec%%|*}"; rest="${spec#*|}"; q="${rest%%|*}"; what="${rest#*|}"
  p="$(plan "$q" || true)"; echo "$p" | sed 's/^/        /'
  check "read $n, $what, uses $idx" "$(case "$p" in *"$idx"*) echo 0 ;; *) echo 1 ;; esac)"
  check "read $n needs no Sort node: the index gives the order" "$(case "$p" in *Sort*) echo 1 ;; *) echo 0 ;; esac)"
done
check "the seven indexes of the plan exist and no other idx_ index does" "$([ "$(sql "select count(*) from pg_indexes where schemaname = '$SCHEMA' and indexname like 'idx\_%'")" = 7 ]; echo $?)"
check "the reopening key index is idx_cash_session_reopening_tenant_session_reopened_at" "$([ "$(sql "select indexdef from pg_indexes where schemaname = '$SCHEMA' and indexname = 'idx_cash_session_reopening_tenant_session_reopened_at'" | grep -c '(tenant_id, cash_session_id, reopened_at)')" = 1 ]; echo $?)"
check "the open index is partial on OPEN and the outbox index is partial on PENDING" "$([ "$(sql "select count(*) from pg_indexes where schemaname = '$SCHEMA' and ((indexname = 'idx_cash_session_tenant_open' and indexdef like '%(tenant_id, business_date)%' and indexdef like '%status%OPEN%') or (indexname = 'idx_outbox_event_pending' and indexdef like '%(status, occurred_at)%' and indexdef like '%status%PENDING%'))")" = 2 ]; echo $?)"

echo "step 2 - the runner applies zero changesets the second time (AC-D1.21)"
liquibase update >/dev/null
check "the control table did not grow" "$([ "$(applied)" = "$first" ]; echo $?)"
pending="$(liquibase status 2>&1 | grep -c 'have not been applied' || true)"
check "status reports no pending changeset" "$([ "$(liquibase status 2>&1 | grep -ci 'up to date')" -ge 1 ]; echo $?)"

echo "AC-D1.22 - rollback leaves nothing and the tree rebuilds (step 3, rollback-count 999)"
liquibase rollback-count 999 >/dev/null
check "the schema is dropped by the rollback" "$([ "$(sql "select count(*) from pg_namespace where nspname = '$SCHEMA'")" = 0 ]; echo $?)"
check "the schema holds no object" "$([ "$(leftovers)" = 0 ]; echo $?)"
check "the domain roles are gone" "$([ "$(domain_roles)" = 0 ]; echo $?)"
check "the control table holds no changeset" "$([ "$(applied)" = 0 ]; echo $?)"

echo "AC-D1.22 - the tree rebuilds (step 4)"
liquibase update >/dev/null
check "the rebuild applies the same changesets" "$([ "$(applied)" = "$first" ]; echo $?)"
check "the rebuilt tree has its seven indexes again" "$([ "$(sql "select count(*) from pg_indexes where schemaname = '$SCHEMA' and indexname like 'idx\_%'")" = 7 ]; echo $?)"
check "the rebuilt tree has its grants again: DELETE on a movement is still refused" "$([ "$(privs cash_reporting_app cash_movement)" = "SELECT,INSERT" ] && app_refuses "delete from $SCHEMA.cash_movement"; echo $?)"

[ "$fail" -eq 0 ] && echo "db-ci: all checks passed" || { echo "db-ci: FAILED"; exit 1; }
