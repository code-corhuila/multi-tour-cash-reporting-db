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

# HU-SEC-007 G-SEC9-1 -db (ADR-004 D5; Project Lead, 2026-11-11): the tenth event of the outbox, PlatformExceptionalAccessUsed, the audit of each use of the token of an exceptional or emergency access.
# Its aggregate is the authorization of the access (aggregate_id), its payload is closed to eight keys, the instant being usedAt and not occurredAt (spec 012 RN-SEC-012-07; changeset 004). Every probe below leaves no row behind (its own transaction is rolled back), so the counts above and below hold.
ea_auth="eeeeeeee-0000-4000-8000-000000000001"
ea_admin="eeeeeeee-0000-4000-8000-000000000002"
ea_keys="authorizationId platformAdministratorId tenantId method route area usedAt correlationId"
ea_payload() { # optional: a key to leave out, then a JSON fragment to add
  local out="" k
  for k in $ea_keys; do
    [ "$k" = "${1:-}" ] && continue
    case $k in
      authorizationId) v="$ea_auth" ;; platformAdministratorId) v="$ea_admin" ;; tenantId) v="$tenant_a" ;;
      method) v="GET" ;; route) v="/api/v1/cash-reporting/cash-days/{date}/movements" ;; area) v="CASH" ;;
      usedAt) v="2026-11-11T10:00:00Z" ;; correlationId) v="corr-1" ;;
    esac
    out="$out\"$k\":\"$v\","
  done
  printf '{%s%s}' "$out" "${2:-}" | sed 's/,}$/}/'
}
ea_insert() { # payload JSON, optional aggregate id
  echo "insert into $SCHEMA.outbox_event (tenant_id, event_type, aggregate_id, payload, occurred_at) values ('$tenant_a', 'PlatformExceptionalAccessUsed', '${2:-$ea_auth}', '$1'::jsonb, now())"
}
ea_revert_file="05_rollbacks/01_ddl/04_alter/003_widen_outbox_event_for_platform_exceptional_access_used.rollback.sql"
ea_before="$(sql "select count(*) from $SCHEMA.outbox_event")"

echo "HU-SEC-007 db - the outbox accepts the use of an exceptional access, with its authorization as aggregate"
check "the use with its eight keys and the authorization as aggregate is accepted" "$(sql "begin; $(ea_insert "$(ea_payload)"); rollback;" >/dev/null 2>&1; echo $?)"
check "the application user may write it: INSERT is accepted as the application" "$(app_ok "begin; $(ea_insert "$(ea_payload)"); rollback;"; echo $?)"
check "an event of the older types still takes the empty object" "$(sql "begin; $(event_insert RefundExecuted); rollback;" >/dev/null 2>&1; echo $?)"

echo "HU-SEC-007 db - the use is refused when it is not of the closed shape"
check "a use that leaves out the correlationId is refused by chk_outbox_event_platform_exceptional_access_used_keys" "$(refused "$(ea_insert "$(ea_payload correlationId)")" chk_outbox_event_platform_exceptional_access_used_keys; echo $?)"
check "a use that leaves out the platformAdministratorId is refused by chk_outbox_event_platform_exceptional_access_used_keys" "$(refused "$(ea_insert "$(ea_payload platformAdministratorId)")" chk_outbox_event_platform_exceptional_access_used_keys; echo $?)"
check "a use that carries a key of the response is refused by chk_outbox_event_platform_exceptional_access_used_keys" "$(refused "$(ea_insert "$(ea_payload '' '"responseBody":"x"')")" chk_outbox_event_platform_exceptional_access_used_keys; echo $?)"
check "a use that carries a query string key is refused by chk_outbox_event_platform_exceptional_access_used_keys" "$(refused "$(ea_insert "$(ea_payload '' '"query":"a=1"')")" chk_outbox_event_platform_exceptional_access_used_keys; echo $?)"
check "a use whose instant is named occurredAt instead of usedAt is refused by chk_outbox_event_platform_exceptional_access_used_keys" "$(refused "$(ea_insert "$(ea_payload usedAt '"occurredAt":"2026-11-11T10:00:00Z"')")" chk_outbox_event_platform_exceptional_access_used_keys; echo $?)"
check "a use whose aggregate is not its authorizationId is refused by chk_outbox_event_platform_exceptional_access_used_ids" "$(refused "$(ea_insert "$(ea_payload)" eeeeeeee-0000-4000-8000-0000000000ff)" chk_outbox_event_platform_exceptional_access_used_ids; echo $?)"
check "a use whose payload tenant is not its tenant is refused by chk_outbox_event_platform_exceptional_access_used_ids" "$(refused "$(ea_insert "$(ea_payload | sed "s/$tenant_a/$tenant_b/")")" chk_outbox_event_platform_exceptional_access_used_ids; echo $?)"
check "an eleventh event name is still refused by chk_outbox_event_event_type" "$(refused "$(event_insert CashSessionRenamed)" chk_outbox_event_event_type; echo $?)"

echo "HU-SEC-007 db - the revert never erases an audit and leaves the nine events"
sql "$(ea_insert "$(ea_payload)")" >/dev/null 2>&1 || true
check "the revert of the slice is refused while a use of an exceptional access is stored (chk_outbox_event_event_type)" "$(refused "$(cat "$ea_revert_file" 2>/dev/null || echo 'select 1/0')" chk_outbox_event_event_type; echo $?)"
sql "delete from $SCHEMA.outbox_event where event_type = 'PlatformExceptionalAccessUsed'" >/dev/null 2>&1 || true
check "the revert of the slice is accepted once no use is stored, and then the tenth event is refused again" "$(refused "begin; $(cat "$ea_revert_file" 2>/dev/null || echo "select 1/0"); $(ea_insert "$(ea_payload)"); rollback;" chk_outbox_event_event_type; echo $?)"
check "the probes left the outbox as they found it" "$([ "$(sql "select count(*) from $SCHEMA.outbox_event")" = "$ea_before" ]; echo $?)"


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

# BEGIN-HU-CSH-DASHBOARD-PROBES (HU-CSH-002, AC-D2.12 and AC-D2.14 to AC-D2.17): the read, no cash needed, the upsert, the repeated event
echo "AC-D2.12 - the dashboard read uses its unique key"
tenant_p="55555555-0000-4000-8000-0000000000d2"
dash_read="select * from $SCHEMA.daily_dashboard_projection where tenant_id = '$tenant_p' and report_date = '2026-11-02'"
# the table holds a handful of rows: the plan is judged with the sequential and bitmap scans off, as AC-D1.20 does
dash_plan="$(app_sql "set enable_seqscan = off; set enable_bitmapscan = off; explain (costs off) $dash_read" || true)"
echo "$dash_plan" | sed 's/^/        /'
check "the read of one day uses uq_daily_dashboard_projection_tenant_report_date" "$(case "$dash_plan" in *uq_daily_dashboard_projection_tenant_report_date*) echo 0 ;; *) echo 1 ;; esac)"
check "the read of one day needs no Sort node and no second index" "$(case "$dash_plan" in *Sort*|*idx_*) echo 1 ;; *) echo 0 ;; esac)"

echo "AC-D2.14 - the dashboard needs no cash"
dash_ins() { echo "insert into $SCHEMA.daily_dashboard_projection (tenant_id, report_date, updated_at) values ('$tenant_p', '$1', now())"; }
check "the projection holds no foreign key and no table points at it" "$([ "$(sql "select count(*) from pg_constraint where contype = 'f' and ('$SCHEMA.daily_dashboard_projection'::regclass in (conrelid, confrelid))")" = 0 ]; echo $?)"
check "the projection holds no trigger of its own" "$([ "$(sql "select count(*) from pg_trigger where tgrelid = '$SCHEMA.daily_dashboard_projection'::regclass and not tgisinternal")" = 0 ]; echo $?)"
check "the tenant has no cash at all" "$([ "$(sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_p'")" = 0 ]; echo $?)"
check "a date with no cash is accepted" "$(sql "$(dash_ins 2026-11-02)" >/dev/null 2>&1; echo $?)"
sql "insert into $SCHEMA.cash_session (tenant_id, business_date, time_zone, origin, created_at) values ('$tenant_p', '2026-11-03', 'America/Bogota', 'AUTOMATIC_CREATION', now())" >/dev/null
sql "insert into $SCHEMA.cash_session (tenant_id, business_date, time_zone, origin, created_at, opening_base_cents, opened_at, opened_by, pending_closure) values ('$tenant_p', '2026-11-04', 'America/Bogota', 'OPERATIONAL_OPENING', now(), 0, now(), gen_random_uuid(), true)" >/dev/null
check "a date whose cash was created automatically is accepted" "$(sql "$(dash_ins 2026-11-03)" >/dev/null 2>&1; echo $?)"
check "a date whose cash is Pendiente de cierre is accepted" "$(sql "$(dash_ins 2026-11-04)" >/dev/null 2>&1; echo $?)"
sql "insert into $SCHEMA.cash_session (tenant_id, business_date, time_zone, origin, created_at, opening_base_cents, opened_at, opened_by, status, closed_at, closing_mode, closing_balance_cents, closed_by) values ('$tenant_p', '2026-11-05', 'America/Bogota', 'OPERATIONAL_OPENING', now(), 0, now(), gen_random_uuid(), 'CLOSED', now(), 'FORMAL', 0, gen_random_uuid())" >/dev/null
sql "insert into $SCHEMA.cash_session_closure (tenant_id, cash_session_id, closed_at, closing_mode, closed_by, opening_base_cents, income_cents, operational_payments_cents, operational_expenses_cents, refunds_cents, cash_entries_cents, transfer_entries_cents, cash_exits_cents, transfer_exits_cents, expected_cash_cents, closing_balance_cents) select tenant_id, cash_session_id, now(), 'FORMAL', gen_random_uuid(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 from $SCHEMA.cash_session where tenant_id = '$tenant_p' and business_date = '2026-11-05'" >/dev/null
sql "insert into $SCHEMA.cash_session_reopening (tenant_id, cash_session_id, cash_session_closure_id, reopened_by, reopened_at, reason) select tenant_id, cash_session_id, cash_session_closure_id, gen_random_uuid(), now(), 'late transfer' from $SCHEMA.cash_session_closure where tenant_id = '$tenant_p'" >/dev/null
check "a date whose cash was closed and reopened is accepted" "$(sql "$(dash_ins 2026-11-05)" >/dev/null 2>&1; echo $?)"
check "the four days are four rows beside three cashes, and none touched a cash table" "$([ "$(sql "select count(*) from $SCHEMA.daily_dashboard_projection where tenant_id = '$tenant_p'")" = 4 ] && [ "$(sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$tenant_p'")" = 3 ]; echo $?)"

echo "AC-D2.15 - a rebuild upserts as the application, without delete"
dash_upsert() { # report date, confirmed set literal
  echo "insert into $SCHEMA.daily_dashboard_projection (tenant_id, report_date, confirmed_reservations, updated_at) values ('$tenant_p', '$1', $2, now()) on conflict (tenant_id, report_date) do update set confirmed_reservations = excluded.confirmed_reservations, updated_at = excluded.updated_at"
}
check "the first write of a day, as the application, is an insert" "$(app_ok "$(dash_upsert 2026-11-10 "'[\"r1\"]'::jsonb")"; echo $?)"
check "the same tenant and date written again, as the application, is an upsert" "$(app_ok "$(dash_upsert 2026-11-10 "'[\"r1\",\"r2\"]'::jsonb")"; echo $?)"
check "one row remains and it holds the second write" "$([ "$(sql "select count(*) from $SCHEMA.daily_dashboard_projection where tenant_id = '$tenant_p' and report_date = '2026-11-10' and confirmed_reservations = '[\"r1\",\"r2\"]'::jsonb")" = 1 ]; echo $?)"
check "the rebuild needed no DELETE: the application still cannot delete a projection" "$(app_refuses "delete from $SCHEMA.daily_dashboard_projection where tenant_id = '$tenant_p'"; echo $?)"

echo "AC-D2.16 - a repeated event leaves the projection unchanged"
ev_rep="aaaaaaaa-0000-4000-8000-0000000000d2"
dash_snapshot() { sql "select md5(string_agg(t::text, '|' order by report_date)) from $SCHEMA.daily_dashboard_projection t where tenant_id = '$tenant_p'"; }
check "the event is recorded with its first projection write, in one transaction" "$(app_ok "begin; $(dash_upsert 2026-11-11 "'[\"r1\"]'::jsonb"); insert into $SCHEMA.processed_event (tenant_id, event_id, event_type, processed_at) values ('$tenant_p', '$ev_rep', 'ReservationConfirmed', now()); commit;"; echo $?)"
before_rep="$(dash_snapshot)"
rep_out="$(app_sql "begin; $(dash_upsert 2026-11-11 "'[\"r1\",\"r9\"]'::jsonb"); insert into $SCHEMA.processed_event (tenant_id, event_id, event_type, processed_at) values ('$tenant_p', '$ev_rep', 'ReservationConfirmed', now()); commit;" || true)"
check "the same event again is refused by uq_processed_event_tenant_event" "$(case "$rep_out" in *uq_processed_event_tenant_event*) echo 0 ;; *) echo 1 ;; esac)"
check "the transaction rolled back whole: the projection is as it was" "$([ "$(dash_snapshot)" = "$before_rep" ]; echo $?)"
check "the repeated event is still one row" "$([ "$(sql "select count(*) from $SCHEMA.processed_event where tenant_id = '$tenant_p' and event_id = '$ev_rep'")" = 1 ]; echo $?)"
check "a new event in the same transaction commits both, so the probe can see a change" "$(app_ok "begin; $(dash_upsert 2026-11-11 "'[\"r1\",\"r9\"]'::jsonb"); insert into $SCHEMA.processed_event (tenant_id, event_id, event_type, processed_at) values ('$tenant_p', 'aaaaaaaa-0000-4000-8000-0000000000d3', 'ReservationConfirmed', now()); commit;"; echo $?)"
check "and the projection did change" "$([ "$(dash_snapshot)" != "$before_rep" ]; echo $?)"

echo "AC-D2.17 - a date already stored is written again into the same row"
check "report_date is a plain date, not an instant" "$([ "$(sql "select data_type from information_schema.columns where table_schema = '$SCHEMA' and table_name = 'daily_dashboard_projection' and column_name = 'report_date'")" = date ]; echo $?)"
sql "insert into $SCHEMA.tenant_time_zone (tenant_id, time_zone, updated_at) values ('$tenant_p', 'America/Bogota', now())" >/dev/null
before_zone="$(dash_snapshot)"
check "the tenant changes its time zone" "$(app_ok "update $SCHEMA.tenant_time_zone set time_zone = 'Asia/Tokyo', updated_at = now() where tenant_id = '$tenant_p'"; echo $?)"
check "no stored projection row was reinterpreted by the change" "$([ "$(dash_snapshot)" = "$before_zone" ]; echo $?)"
check "the date already stored, written again after the change, is the same row" "$(app_ok "$(dash_upsert 2026-11-10 "'[\"r1\",\"r2\",\"r3\"]'::jsonb")"; echo $?)"
check "that tenant still holds one row for that date" "$([ "$(sql "select count(*) from $SCHEMA.daily_dashboard_projection where tenant_id = '$tenant_p' and report_date = '2026-11-10'")" = 1 ]; echo $?)"
# END-HU-CSH-DASHBOARD-PROBES

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

# BEGIN-HU-CSH-FACTS (HU-CSH-002 plan D-12 and HU-CSH-003 plan D-02): probes run as the owner, then as the application
echo "AC-D2.18 to AC-D2.20 - the last known state of a reservation, a departure and the zone of a tenant"
fact_sql() { # table columns values
  echo "insert into $SCHEMA.$1 ($2) values ($3)"
}
rs_cols="tenant_id, reservation_id, status, updated_at"
check "a reservation state is recorded" "$(sql "$(fact_sql reservation_state "$rs_cols" "'$tenant_a', 'r-1', 'CONFIRMED', now()")" >/dev/null 2>&1; echo $?)"
check "a second state of the same tenant and reservation is refused by uq_reservation_state_tenant_reservation" "$(refused "$(fact_sql reservation_state "$rs_cols" "'$tenant_a', 'r-1', 'CANCELLED', now()")" uq_reservation_state_tenant_reservation; echo $?)"
check "another tenant may hold the same reservation id" "$(sql "$(fact_sql reservation_state "$rs_cols" "'$tenant_b', 'r-1', 'CONFIRMED', now()")" >/dev/null 2>&1; echo $?)"
check "a reservation state without tenant is refused by chk_reservation_state_tenant_required" "$(refused "$(fact_sql reservation_state "$rs_cols" "null, 'r-2', 'CONFIRMED', now()")" chk_reservation_state_tenant_required; echo $?)"
check "a reservation state without reservation id is refused by chk_reservation_state_reservation_required" "$(refused "$(fact_sql reservation_state "$rs_cols" "'$tenant_a', null, 'CONFIRMED', now()")" chk_reservation_state_reservation_required; echo $?)"
check "a reservation state with a blank status is refused by chk_reservation_state_status_required" "$(refused "$(fact_sql reservation_state "$rs_cols" "'$tenant_a', 'r-3', '  ', now()")" chk_reservation_state_status_required; echo $?)"
check "the reservation state keeps the financial situation and the newest event time" "$(sql "update $SCHEMA.reservation_state set financial_situation = 'BALANCE_PENDING', last_event_occurred_at = now() where tenant_id = '$tenant_a' and reservation_id = 'r-1'" >/dev/null 2>&1; echo $?)"
ds_cols="tenant_id, departure_id, status, updated_at"
check "a departure state is recorded with its scheduled start" "$(sql "$(fact_sql departure_state "$ds_cols, scheduled_start" "'$tenant_a', 'd-1', 'SCHEDULED', now(), now()")" >/dev/null 2>&1; echo $?)"
check "the reservation state keeps its creation instant and the id of the newest event" "$(sql "update $SCHEMA.reservation_state set created_at = now(), last_event_id = 'e-9' where tenant_id = '$tenant_a' and reservation_id = 'r-1'" >/dev/null 2>&1; echo $?)"
check "the departure state keeps the id of the newest event" "$(sql "update $SCHEMA.departure_state set last_event_id = 'e-9' where tenant_id = '$tenant_a' and departure_id = 'd-1'" >/dev/null 2>&1; echo $?)"
check "a second state of the same tenant and departure is refused by uq_departure_state_tenant_departure" "$(refused "$(fact_sql departure_state "$ds_cols" "'$tenant_a', 'd-1', 'CANCELLED', now()")" uq_departure_state_tenant_departure; echo $?)"
check "a departure state without tenant is refused by chk_departure_state_tenant_required" "$(refused "$(fact_sql departure_state "$ds_cols" "null, 'd-2', 'SCHEDULED', now()")" chk_departure_state_tenant_required; echo $?)"
check "a departure state without departure id is refused by chk_departure_state_departure_required" "$(refused "$(fact_sql departure_state "$ds_cols" "'$tenant_a', null, 'SCHEDULED', now()")" chk_departure_state_departure_required; echo $?)"
tz_cols="tenant_id, time_zone, updated_at"
check "the zone of a tenant is recorded" "$(sql "$(fact_sql tenant_time_zone "$tz_cols" "'$tenant_a', 'America/Bogota', now()")" >/dev/null 2>&1; echo $?)"
check "a second zone of the same tenant is refused by uq_tenant_time_zone_tenant" "$(refused "$(fact_sql tenant_time_zone "$tz_cols" "'$tenant_a', 'UTC', now()")" uq_tenant_time_zone_tenant; echo $?)"
check "a blank zone is refused by chk_tenant_time_zone_time_zone_required" "$(refused "$(fact_sql tenant_time_zone "$tz_cols" "'$tenant_b', '  ', now()")" chk_tenant_time_zone_time_zone_required; echo $?)"
check "a zone without tenant is refused by chk_tenant_time_zone_tenant_required" "$(refused "$(fact_sql tenant_time_zone "$tz_cols" "null, 'UTC', now()")" chk_tenant_time_zone_tenant_required; echo $?)"

echo "AC-D3.1 to AC-D3.15 - the monthly administrative report is a formula, one row per tenant and period"
mr_cols="tenant_id, starts_on, ends_on, updated_at"
mr_sql() { # tenant starts ends extra-columns extra-values
  echo "insert into $SCHEMA.monthly_administrative_report ($mr_cols${4:+, $4}) values ($1, $2, $3, now()${5:+, $5})"
}
check "an empty month is a valid row of zeros, with the confirmed sales unknown (null)" "$(sql "$(mr_sql "'$tenant_a'" "'2026-10-01'" "'2026-10-31'")" >/dev/null 2>&1; echo $?)"
check "the empty month holds zero components, empty sets and no confirmed sales" "$([ "$(sql "select count(*) from $SCHEMA.monthly_administrative_report where tenant_id = '$tenant_a' and period_income_cents = 0 and consolidated_cash_total_cents = 0 and counted_movements = 0 and registered_cancellations = '[]'::jsonb and registered_operational_costs = '[]'::jsonb and confirmed_sales_cents is null")" = 1 ]; echo $?)"
check "a second report of the same tenant and period is refused by uq_monthly_report_tenant_period" "$(refused "$(mr_sql "'$tenant_a'" "'2026-10-01'" "'2026-10-31'")" uq_monthly_report_tenant_period; echo $?)"
check "another tenant may hold a report for the same period" "$(sql "$(mr_sql "'$tenant_b'" "'2026-10-01'" "'2026-10-31'")" >/dev/null 2>&1; echo $?)"
check "a report without tenant is refused by chk_report_tenant_required" "$(refused "$(mr_sql null "'2026-09-01'" "'2026-09-30'")" chk_report_tenant_required; echo $?)"
check "a period whose start is after its end is refused by chk_report_period" "$(refused "$(mr_sql "'$tenant_a'" "'2026-09-30'" "'2026-09-01'")" chk_report_period; echo $?)"
for col in period_income_cents operational_payments_cents operational_expenses_cents executed_refunds_cents; do
  # the income also changes the split: another constraint would refuse it first (they fire in alphabetical order)
  cols="$col"; vals="-1"; [ "$col" = period_income_cents ] && { cols="$col, period_income_cash_cents"; vals="-1, -1"; }
  check "a negative $col is refused by chk_report_${col}_nonnegative" "$(refused "$(mr_sql "'$tenant_a'" "'2026-08-01'" "'2026-08-31'" "$cols" "$vals")" chk_report_${col}_nonnegative; echo $?)"
done
check "a total that is not income - payments - expenses - refunds is refused by chk_report_total_formula" "$(refused "$(mr_sql "'$tenant_a'" "'2026-08-01'" "'2026-08-31'" "period_income_cents, period_income_cash_cents, consolidated_cash_total_cents" "1000, 1000, 999")" chk_report_total_formula; echo $?)"
check "a negative total that follows the formula is accepted" "$(sql "$(mr_sql "'$tenant_a'" "'2026-07-01'" "'2026-07-31'" "operational_expenses_cents, consolidated_cash_total_cents" "500, -500")" >/dev/null 2>&1; echo $?)"
check "an income split that does not add to the income is refused by chk_report_income_by_medium" "$(refused "$(mr_sql "'$tenant_a'" "'2026-06-01'" "'2026-06-30'" "period_income_cents, period_income_cash_cents, period_income_transfer_cents, consolidated_cash_total_cents" "1000, 600, 300, 1000")" chk_report_income_by_medium; echo $?)"
check "a negative count of movements is refused by chk_report_counted_movements_nonnegative" "$(refused "$(mr_sql "'$tenant_a'" "'2026-05-01'" "'2026-05-31'" "counted_movements" "-1")" chk_report_counted_movements_nonnegative; echo $?)"
check "negative confirmed sales are refused by chk_report_confirmed_sales_nonnegative" "$(refused "$(mr_sql "'$tenant_a'" "'2026-05-01'" "'2026-05-31'" "confirmed_sales_cents" "-1")" chk_report_confirmed_sales_nonnegative; echo $?)"
check "known confirmed sales of zero or more are accepted" "$(sql "$(mr_sql "'$tenant_a'" "'2026-04-01'" "'2026-04-30'" "confirmed_sales_cents" "0")" >/dev/null 2>&1; echo $?)"
for col in registered_cancellations registered_operational_costs; do
  short="${col/registered_operational_costs/costs}"; short="${short/registered_cancellations/cancellations}"
  check "a set that is not an array is refused by chk_report_${short}_is_array ($col)" "$(refused "$(mr_sql "'$tenant_a'" "'2026-03-01'" "'2026-03-31'" "$col" "'{}'::jsonb")" chk_report_${short}_is_array; echo $?)"
  check "a set over 10000 elements is refused by chk_report_${short}_max_items ($col)" "$(refused "$(mr_sql "'$tenant_a'" "'2026-03-01'" "'2026-03-31'" "$col" "(select jsonb_agg(g) from generate_series(1, 10001) g)")" chk_report_${short}_max_items; echo $?)"
done

echo "AC-D2.21 and AC-D3.12 - the new tables are written by the application and never deleted"
for t in reservation_state departure_state tenant_time_zone monthly_administrative_report; do
  check "the application holds exactly SELECT, INSERT, UPDATE on $t" "$([ "$(privs cash_reporting_app $t)" = "SELECT,INSERT,UPDATE" ]; echo $?)"
  check "DELETE on $t by the application is refused" "$(app_refuses "delete from $SCHEMA.$t"; echo $?)"
  check "the reader holds only SELECT on $t" "$([ "$(privs cash_reporting_reader $t)" = SELECT ]; echo $?)"
done
# END-HU-CSH-FACTS
# BEGIN-HU-CSH-MONTH-PROBES (HU-CSH-003 plan D-03, AC-D3.16 to AC-D3.24): the sum of the month and its reconciliation, over small seeds
# The sum is the shape of plan D-03 and the reconciliation the shape of plan D-03 (AC-D3.23); each probe seeds its own tenant.
echo "AC-D3.16 to AC-D3.24 - the month is the sum of the movements by the business date of their cash"
P_OPEN="opening_base_cents, opened_at, opened_by"
P_CLOSED="opening_base_cents, opened_at, opened_by, status, closed_at, closing_mode, closing_balance_cents, closed_by"
p_cash() { # tenant date origin extra-columns extra-values (zone: P_ZONE, default America/Bogota)
  sql "insert into $SCHEMA.cash_session (tenant_id, business_date, time_zone, origin, created_at${4:+, $4}) values ('$1', '$2', '${P_ZONE:-America/Bogota}', '${3:-OPERATIONAL_OPENING}', now()${5:+, $5})" >/dev/null
}
p_closed_cash() { p_cash "$1" "$2" OPERATIONAL_OPENING "$P_CLOSED" "300000, now(), gen_random_uuid(), 'CLOSED', now(), 'FORMAL', 1120000, gen_random_uuid()"; }
p_mv_sql() { # tenant date type medium amount registered_at [extra-columns extra-values]
  echo "insert into $SCHEMA.cash_movement (tenant_id, cash_session_id, movement_type, payment_medium, amount_cents, registered_at, registered_by, concept${7:+, $7}) select '$1', cash_session_id, '$3', '$4', $5, '$6', gen_random_uuid(), 'probe'${8:+, $8} from $SCHEMA.cash_session where tenant_id = '$1' and business_date = '$2'"
}
p_mv() { sql "$(p_mv_sql "$@")" >/dev/null; }
p_closure() { # tenant date: a valid closure snapshot (the default closure of AC-D1.8)
  sql "insert into $SCHEMA.cash_session_closure (tenant_id, cash_session_id, closed_at, closing_mode, closed_by, opening_base_cents, income_cents, operational_payments_cents, operational_expenses_cents, refunds_cents, cash_entries_cents, transfer_entries_cents, cash_exits_cents, transfer_exits_cents, expected_cash_cents, closing_balance_cents) select tenant_id, cash_session_id, now(), 'FORMAL', gen_random_uuid(), 300000, 1000000, 100000, 50000, 30000, 700000, 300000, 150000, 30000, 850000, 1120000 from $SCHEMA.cash_session where tenant_id = '$1' and business_date = '$2'" >/dev/null
}
p_month() { # tenant first-day last-day: the plan D-03 sum, as "TYPE=cents,... n=count"
  sql "select coalesce(string_agg(t || '=' || total, ',' order by t), 'none') || ' n=' || coalesce(sum(c), 0) from (select m.movement_type t, sum(m.amount_cents) total, count(*) c from $SCHEMA.cash_movement m join $SCHEMA.cash_session cs on cs.tenant_id = m.tenant_id and cs.cash_session_id = m.cash_session_id where m.tenant_id = '$1' and cs.business_date between '$2' and '$3' group by m.movement_type) x"
}
p_report() { # tenant first last income cash transfer payments expenses refunds count: a report rebuilt from the movements
  sql "insert into $SCHEMA.monthly_administrative_report (tenant_id, starts_on, ends_on, period_income_cents, period_income_cash_cents, period_income_transfer_cents, operational_payments_cents, operational_expenses_cents, executed_refunds_cents, consolidated_cash_total_cents, counted_movements, updated_at) values ('$1', '$2', '$3', $4, $5, $6, $7, $8, $9, $4 - $7 - $8 - $9, ${10}, now())" >/dev/null
}
p_recon() { # tenant: the components of each stored report that differ from the movements (the reconciliation of plan D-03 and spec 4.2); empty when none
  sql "select coalesce(string_agg(r.starts_on || ' ' || d.component, ',' order by r.starts_on, d.component), '') from $SCHEMA.monthly_administrative_report r cross join lateral (select coalesce(sum(m.amount_cents) filter (where m.movement_type = 'INCOME'), 0) income, coalesce(sum(m.amount_cents) filter (where m.movement_type = 'OPERATIONAL_PAYMENT'), 0) payments, coalesce(sum(m.amount_cents) filter (where m.movement_type = 'OPERATIONAL_EXPENSE'), 0) expenses, coalesce(sum(m.amount_cents) filter (where m.movement_type = 'REFUND'), 0) refunds, coalesce(sum(m.amount_cents) filter (where m.movement_type = 'INCOME' and m.payment_medium = 'CASH'), 0) income_cash, coalesce(sum(m.amount_cents) filter (where m.movement_type = 'INCOME' and m.payment_medium = 'TRANSFER'), 0) income_transfer, count(m.cash_movement_id) movements from $SCHEMA.cash_session cs join $SCHEMA.cash_movement m on m.tenant_id = cs.tenant_id and m.cash_session_id = cs.cash_session_id where cs.tenant_id = r.tenant_id and cs.business_date between r.starts_on and r.ends_on) t cross join lateral (values ('period_income_cents', r.period_income_cents::numeric, t.income), ('operational_payments_cents', r.operational_payments_cents::numeric, t.payments), ('operational_expenses_cents', r.operational_expenses_cents::numeric, t.expenses), ('executed_refunds_cents', r.executed_refunds_cents::numeric, t.refunds), ('period_income_cash_cents', r.period_income_cash_cents::numeric, t.income_cash), ('period_income_transfer_cents', r.period_income_transfer_cents::numeric, t.income_transfer), ('counted_movements', r.counted_movements::numeric, t.movements::numeric)) d(component, stored, computed) where r.tenant_id = '$1' and d.stored is distinct from d.computed"
}
p_snap() { # tenant: a fingerprint of the cashes and the closures of the tenant, to prove they did not change
  sql "select md5(coalesce((select string_agg(s::text, '|' order by business_date) from $SCHEMA.cash_session s where tenant_id = '$1'), '') || coalesce((select string_agg(c::text, '|' order by cash_session_closure_id) from $SCHEMA.cash_session_closure c where tenant_id = '$1'), ''))"
}

echo "AC-D3.16 - the month is the business date of the cash, not the time of the movement"
t16="33333333-0000-4000-8000-000000000016"
p_cash $t16 2026-09-30; p_cash $t16 2026-10-01
p_mv $t16 2026-09-30 INCOME CASH 1000 "2026-10-01 02:30:00+00"   # 21:30 of 30 September at UTC-5
p_mv $t16 2026-10-01 INCOME CASH 500 "2026-10-01 15:00:00+00"
check "the movement of 02:30 UTC on 1 October counts in September, the month of the date of its cash" "$([ "$(p_month $t16 2026-09-01 2026-09-30)" = "INCOME=1000 n=1" ]; echo $?)"
check "and in no other: October holds only its own movement" "$([ "$(p_month $t16 2026-10-01 2026-10-31)" = "INCOME=500 n=1" ]; echo $?)"
check "a sum by the time of the movement would have given October both (the seed tells the two readings apart)" "$([ "$(sql "select sum(amount_cents) from $SCHEMA.cash_movement where tenant_id = '$t16' and registered_at >= '2026-10-01 00:00:00+00' and registered_at < '2026-11-01 00:00:00+00'")" = 1500 ]; echo $?)"

echo "AC-D3.17 - open, pending, automatic and automatically closed cashes count by their movements only"
t17="33333333-0000-4000-8000-000000000017"
p_cash $t17 2026-08-03 OPERATIONAL_OPENING "$P_OPEN" "300000, now(), gen_random_uuid()"
p_cash $t17 2026-08-04 OPERATIONAL_OPENING "$P_OPEN, pending_closure" "200000, now(), gen_random_uuid(), true"
p_cash $t17 2026-08-05 AUTOMATIC_CREATION
p_cash $t17 2026-08-06 AUTOMATIC_CREATION "status, closed_at, closing_mode, closing_balance_cents" "'CLOSED', now(), 'AUTOMATIC', 1000"
for d in 03 04 05 06; do p_mv $t17 2026-08-$d INCOME CASH 1000 "2026-08-$d 15:00:00+00"; done
check "the four cashes are an open one, a pending one, an automatic one and one closed automatically" "$([ "$(sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$t17' and ((status = 'OPEN' and not pending_closure and origin = 'OPERATIONAL_OPENING') or (pending_closure) or (origin = 'AUTOMATIC_CREATION' and status = 'OPEN') or (closing_mode = 'AUTOMATIC'))")" = 4 ]; echo $?)"
check "the movements of all four count, once each" "$([ "$(p_month $t17 2026-08-01 2026-08-31)" = "INCOME=4000 n=4" ]; echo $?)"
check "the bases (500000 together) add nothing" "$([ "$(sql "select sum(opening_base_cents) from $SCHEMA.cash_session where tenant_id = '$t17'")" = 500000 ]; echo $?)"

echo "AC-D3.18 - a day closed twice is counted once"
t18="33333333-0000-4000-8000-000000000018"
p_closed_cash $t18 2026-07-10
p_mv $t18 2026-07-10 INCOME CASH 700000 "2026-07-10 15:00:00+00"
p_mv $t18 2026-07-10 INCOME TRANSFER 300000 "2026-07-10 16:00:00+00"
p_closure $t18 2026-07-10
sql "insert into $SCHEMA.cash_session_reopening (tenant_id, cash_session_id, cash_session_closure_id, reopened_by, reopened_at, reason) select tenant_id, cash_session_id, cash_session_closure_id, gen_random_uuid(), now(), 'late transfer' from $SCHEMA.cash_session_closure where tenant_id = '$t18'" >/dev/null
p_closure $t18 2026-07-10
check "the day holds two closures and one reopening" "$([ "$(sql "select count(*) from $SCHEMA.cash_session_closure where tenant_id = '$t18'")" = 2 ] && [ "$(sql "select count(*) from $SCHEMA.cash_session_reopening where tenant_id = '$t18'")" = 1 ]; echo $?)"
check "the month equals the movements: each counts once" "$([ "$(p_month $t18 2026-07-01 2026-07-31)" = "INCOME=1000000 n=2" ]; echo $?)"
check "the sum of the closure snapshots would have counted the day twice (the seed tells them apart)" "$([ "$(sql "select sum(income_cents) from $SCHEMA.cash_session_closure where tenant_id = '$t18'")" = 2000000 ]; echo $?)"

echo "AC-D3.19 - a movement after the closing is counted once and the closure stays"
t19="33333333-0000-4000-8000-000000000019"
p_closed_cash $t19 2026-06-05
p_mv $t19 2026-06-05 INCOME CASH 700000 "2026-06-05 15:00:00+00"
p_mv $t19 2026-06-05 INCOME TRANSFER 300000 "2026-06-05 16:00:00+00"
p_closure $t19 2026-06-05
snap_19="$(p_snap $t19)"
check "a transfer after the closing is accepted as the application" "$(app_ok "$(p_mv_sql $t19 2026-06-05 INCOME TRANSFER 400 "2026-06-06 09:00:00+00" after_closing true)"; echo $?)"
check "a refund by transfer after the closing is accepted as the application" "$(app_ok "$(p_mv_sql $t19 2026-06-05 REFUND TRANSFER 100 "2026-06-06 10:00:00+00" after_closing true)"; echo $?)"
check "a cash movement after the closing is refused by chk_cash_movement_after_closing_transfer_only (the physical cash is not touched)" "$(refused "$(p_mv_sql $t19 2026-06-05 INCOME CASH 100 "2026-06-06 11:00:00+00" after_closing true)" chk_cash_movement_after_closing_transfer_only; echo $?)"
check "the month counts the two late movements once, in the month of their cash" "$([ "$(p_month $t19 2026-06-01 2026-06-30)" = "INCOME=1000400,REFUND=100 n=4" ]; echo $?)"
check "the cash and its closure snapshot are as they were" "$([ "$(p_snap $t19)" = "$snap_19" ]; echo $?)"

echo "AC-D3.20 - a correction of a closed day reaches the month through its movements"
t20="33333333-0000-4000-8000-000000000020"
p_closed_cash $t20 2026-05-12
p_mv $t20 2026-05-12 INCOME CASH 1000 "2026-05-12 15:00:00+00"
p_closure $t20 2026-05-12
p_report $t20 2026-05-01 2026-05-31 1000 1000 0 0 0 0 1
check "the stored report equals the movements before the correction" "$([ -z "$(p_recon $t20)" ]; echo $?)"
snap_20="$(p_snap $t20)"
sql "insert into $SCHEMA.cash_closure_correction (tenant_id, cash_session_id, cash_session_closure_id, justification, registered_by, registered_at) select tenant_id, cash_session_id, cash_session_closure_id, 'description fixed', gen_random_uuid(), now() from $SCHEMA.cash_session_closure where tenant_id = '$t20'" >/dev/null
sql "insert into $SCHEMA.cash_session_reopening (tenant_id, cash_session_id, cash_session_closure_id, reopened_by, reopened_at, reason) select tenant_id, cash_session_id, cash_session_closure_id, gen_random_uuid(), now(), 'wrong amount' from $SCHEMA.cash_session_closure where tenant_id = '$t20'" >/dev/null
check "the note and the reopening add nothing to the month" "$([ "$(p_month $t20 2026-05-01 2026-05-31)" = "INCOME=1000 n=1" ]; echo $?)"
income_20="$(sql "select cash_movement_id from $SCHEMA.cash_movement where tenant_id = '$t20' and movement_type = 'INCOME'")"
p_mv $t20 2026-05-12 REFUND CASH 1000 "2026-05-13 09:00:00+00" reverses_cash_movement_id "'$income_20'"
check "the reversal counts as the movement it is" "$([ "$(p_month $t20 2026-05-01 2026-05-31)" = "INCOME=1000,REFUND=1000 n=2" ]; echo $?)"
check "the closure of the day keeps its original values and no second cash was made" "$([ "$(sql "select count(*) from $SCHEMA.cash_session where tenant_id = '$t20'")" = 1 ] && [ "$(sql "select income_cents || '/' || closing_balance_cents from $SCHEMA.cash_session_closure where tenant_id = '$t20'")" = "1000000/1120000" ] && [ "$(p_snap $t20)" = "$snap_20" ]; echo $?)"
check "the stored report is stale until it is rebuilt: it differs in the refunds and the count" "$([ "$(p_recon $t20)" = "2026-05-01 counted_movements,2026-05-01 executed_refunds_cents" ]; echo $?)"
sql "update $SCHEMA.monthly_administrative_report set executed_refunds_cents = 1000, consolidated_cash_total_cents = 0, counted_movements = 2, updated_at = now() where tenant_id = '$t20'" >/dev/null
check "after the rebuild the stored report equals the movements again" "$([ -z "$(p_recon $t20)" ]; echo $?)"

echo "AC-D3.21 - a change of time zone neither loses nor repeats a movement between months"
t21="33333333-0000-4000-8000-000000000021"
sql "insert into $SCHEMA.tenant_time_zone (tenant_id, time_zone, updated_at) values ('$t21', 'America/Bogota', now())" >/dev/null
P_ZONE=America/Bogota p_cash $t21 2026-03-30; P_ZONE=America/Bogota p_cash $t21 2026-03-31
P_ZONE=Asia/Tokyo p_cash $t21 2026-04-01; P_ZONE=Asia/Tokyo p_cash $t21 2026-04-02
p_mv $t21 2026-03-30 INCOME CASH 100 "2026-03-30 15:00:00+00"
p_mv $t21 2026-03-31 INCOME CASH 200 "2026-04-01 03:00:00+00"   # 22:00 of 31 March at UTC-5
p_mv $t21 2026-04-01 INCOME CASH 400 "2026-03-31 16:00:00+00"   # 01:00 of 1 April at UTC+9
p_mv $t21 2026-04-02 INCOME CASH 800 "2026-04-02 10:00:00+00"
snap_21="$(p_snap $t21)"
check "the tenant changes its zone as the application and no stored cash is reinterpreted" "$(app_ok "update $SCHEMA.tenant_time_zone set time_zone = 'Asia/Tokyo', updated_at = now() where tenant_id = '$t21'"; echo $?)"
check "the cashes keep the date and the zone they were created with" "$([ "$(p_snap $t21)" = "$snap_21" ] && [ "$(sql "select count(distinct time_zone) from $SCHEMA.cash_session where tenant_id = '$t21'")" = 2 ]; echo $?)"
check "March holds the two movements of its cashes" "$([ "$(p_month $t21 2026-03-01 2026-03-31)" = "INCOME=300 n=2" ]; echo $?)"
check "April holds the other two" "$([ "$(p_month $t21 2026-04-01 2026-04-30)" = "INCOME=1200 n=2" ]; echo $?)"
check "every movement is in exactly one of the two months" "$([ "$(sql "select count(*) from $SCHEMA.cash_movement where tenant_id = '$t21'")" = 4 ] && [ "$(sql "select sum(amount_cents) from $SCHEMA.cash_movement where tenant_id = '$t21'")" = 1500 ]; echo $?)"

echo "AC-D3.22 - a month with only opening bases, or with no cash, reads zero"
t22="33333333-0000-4000-8000-000000000022"
p_cash $t22 2026-02-02 OPERATIONAL_OPENING "$P_OPEN" "300000, now(), gen_random_uuid()"
p_cash $t22 2026-02-03 OPERATIONAL_OPENING "$P_OPEN" "500000, now(), gen_random_uuid()"
check "a month with only opening bases reads zero movements and no component" "$([ "$(p_month $t22 2026-02-01 2026-02-28)" = "none n=0" ]; echo $?)"
check "a month with no cash at all reads the same" "$([ "$(p_month $t22 2026-01-01 2026-01-31)" = "none n=0" ]; echo $?)"
sql "insert into $SCHEMA.monthly_administrative_report (tenant_id, starts_on, ends_on, updated_at) values ('$t22', '2026-02-01', '2026-02-28', now()), ('$t22', '2026-01-01', '2026-01-31', now())" >/dev/null
check "the zero row of AC-D3.8 equals that sum: the reconciliation finds no difference" "$([ -z "$(p_recon $t22)" ]; echo $?)"
check "and the base did not enter the total" "$([ "$(sql "select count(*) from $SCHEMA.monthly_administrative_report where tenant_id = '$t22' and consolidated_cash_total_cents = 0 and period_income_cents = 0 and counted_movements = 0")" = 2 ]; echo $?)"

echo "AC-D3.23 - a stale report is detected by the reconciliation"
t23="33333333-0000-4000-8000-000000000023"
p_cash $t23 2026-04-10
p_mv $t23 2026-04-10 INCOME CASH 1000 "2026-04-10 15:00:00+00"
p_mv $t23 2026-04-10 INCOME TRANSFER 500 "2026-04-10 16:00:00+00"
p_mv $t23 2026-04-10 OPERATIONAL_EXPENSE CASH 200 "2026-04-10 17:00:00+00"
p_mv $t23 2026-04-10 REFUND CASH 100 "2026-04-10 18:00:00+00"
p_report $t23 2026-04-01 2026-04-30 1500 1000 500 0 200 100 4
check "a report rebuilt from the movements shows no difference" "$([ -z "$(p_recon $t23)" ]; echo $?)"
p_mv $t23 2026-04-10 INCOME TRANSFER 300 "2026-04-11 09:00:00+00"
check "a movement added without a rebuild shows the income, its transfer part and the count" "$([ "$(p_recon $t23)" = "2026-04-01 counted_movements,2026-04-01 period_income_cents,2026-04-01 period_income_transfer_cents" ]; echo $?)"
sql "update $SCHEMA.monthly_administrative_report set period_income_cents = 1800, period_income_transfer_cents = 800, consolidated_cash_total_cents = 1500, counted_movements = 5, updated_at = now() where tenant_id = '$t23'" >/dev/null
check "after the rebuild there is no difference again" "$([ -z "$(p_recon $t23)" ]; echo $?)"
sql "update $SCHEMA.monthly_administrative_report set operational_expenses_cents = 250, consolidated_cash_total_cents = 1450 where tenant_id = '$t23'" >/dev/null
check "a stored component altered without a rebuild shows exactly that component" "$([ "$(p_recon $t23)" = "2026-04-01 operational_expenses_cents" ]; echo $?)"

echo "AC-D3.24 - a reversal counts as a movement of its own type"
t24="33333333-0000-4000-8000-000000000024"
p_cash $t24 2026-01-15
p_mv $t24 2026-01-15 INCOME CASH 1000 "2026-01-15 15:00:00+00"
i1="$(sql "select cash_movement_id from $SCHEMA.cash_movement where tenant_id = '$t24' and movement_type = 'INCOME' and amount_cents = 1000")"
p_mv $t24 2026-01-15 REFUND CASH 1000 "2026-01-15 16:00:00+00" reverses_cash_movement_id "'$i1'"
p_mv $t24 2026-01-15 REFUND TRANSFER 400 "2026-01-15 17:00:00+00"
r2="$(sql "select cash_movement_id from $SCHEMA.cash_movement where tenant_id = '$t24' and movement_type = 'REFUND' and amount_cents = 400")"
p_mv $t24 2026-01-15 INCOME TRANSFER 400 "2026-01-15 18:00:00+00" reverses_cash_movement_id "'$r2'"
check "the income reversed by a refund and the refund reversed by an income each count in their own type" "$([ "$(p_month $t24 2026-01-01 2026-01-31)" = "INCOME=1400,REFUND=1400 n=4" ]; echo $?)"
check "no movement is counted twice: the two types add up to every row once" "$([ "$(sql "select sum(amount_cents) from $SCHEMA.cash_movement where tenant_id = '$t24'")" = 2800 ]; echo $?)"
check "the total of the month is net: income minus refunds is zero" "$([ "$(sql "select sum(case movement_type when 'INCOME' then amount_cents else -amount_cents end) from $SCHEMA.cash_movement where tenant_id = '$t24'")" = 0 ]; echo $?)"
# END-HU-CSH-MONTH-PROBES

# BEGIN-HU-SEC-CUTOFF (HU-SEC-005 AC4, HU-SEC-006 AC7; ADR-004 D5): the cutoff of the sessions of an account
echo "HU-SEC-005 AC4 and HU-SEC-006 AC7 - the cutoff of the sessions of an account, one row per account"
acct_a="aaaaaaaa-0000-4000-8000-00000000000a"
acct_b="aaaaaaaa-0000-4000-8000-00000000000b"
evt_1="eeeeeeee-0000-4000-8000-000000000a01"
cutoff_cols="account_id, tenant_id, session_cutoff_at, event_id, updated_at"
cutoff_sql() { # account tenant cutoff event
  echo "insert into $SCHEMA.account_session_cutoff ($cutoff_cols) values ($1, $2, $3, $4, now())"
}
check "the cutoff of an account of a tenant is recorded" "$(sql "$(cutoff_sql "'$acct_a'" "'$tenant_a'" "'2026-11-12T10:00:00Z'" "'$evt_1'")" >/dev/null 2>&1; echo $?)"
check "the cutoff of an account of the platform is recorded with no tenant" "$(sql "$(cutoff_sql "'$acct_b'" null "'2026-11-12T10:00:00Z'" "'$evt_1'")" >/dev/null 2>&1; echo $?)"
check "a second row of the same account is refused by uq_account_session_cutoff_account" "$(refused "$(cutoff_sql "'$acct_a'" "'$tenant_a'" "'2026-11-12T11:00:00Z'" "'$evt_1'")" uq_account_session_cutoff_account; echo $?)"
check "a cutoff without account is refused by chk_account_session_cutoff_account_required" "$(refused "$(cutoff_sql null "'$tenant_a'" "'2026-11-12T10:00:00Z'" "'$evt_1'")" chk_account_session_cutoff_account_required; echo $?)"
check "a cutoff without instant is refused by chk_account_session_cutoff_session_cutoff_at_required" "$(refused "$(cutoff_sql "'$acct_a'" "'$tenant_a'" null "'$evt_1'")" chk_account_session_cutoff_session_cutoff_at_required; echo $?)"
check "a cutoff without event id is refused by chk_account_session_cutoff_event_id_required" "$(refused "$(cutoff_sql "'$acct_a'" "'$tenant_a'" "'2026-11-12T10:00:00Z'" null)" chk_account_session_cutoff_event_id_required; echo $?)"
check "the application inserts, reads and updates a cutoff (it moves forward by update)" "$(app_ok "insert into $SCHEMA.account_session_cutoff ($cutoff_cols) values ('aaaaaaaa-0000-4000-8000-00000000000c', null, now(), '$evt_1', now()); update $SCHEMA.account_session_cutoff set session_cutoff_at = now(), updated_at = now() where account_id = '$acct_a'; select count(*) from $SCHEMA.account_session_cutoff"; echo $?)"
check "the application holds exactly SELECT, INSERT, UPDATE on account_session_cutoff" "$([ "$(privs cash_reporting_app account_session_cutoff)" = "SELECT,INSERT,UPDATE" ]; echo $?)"
check "DELETE on account_session_cutoff by the application is refused" "$(app_refuses "delete from $SCHEMA.account_session_cutoff"; echo $?)"
check "the reader holds only SELECT on account_session_cutoff" "$([ "$(privs cash_reporting_reader account_session_cutoff)" = SELECT ]; echo $?)"
# END-HU-SEC-CUTOFF

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
