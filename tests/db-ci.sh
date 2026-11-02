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

# Annex J.4, J.7: the schema and the application user belong to multi-tour-infra-postgres. CI does
# those two things in its place; NOLOGIN is enough because tests become the role with SET ROLE.
sql "create schema $SCHEMA" >/dev/null
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

echo "step 2 - the runner applies zero changesets the second time (AC-D1.21)"
liquibase update >/dev/null
check "the control table did not grow" "$([ "$(applied)" = "$first" ]; echo $?)"
pending="$(liquibase status 2>&1 | grep -c 'have not been applied' || true)"
check "status reports no pending changeset" "$([ "$(liquibase status 2>&1 | grep -ci 'up to date')" -ge 1 ]; echo $?)"

echo "step 3 - rollback leaves nothing (AC-D1.22)"
liquibase rollback-count 999 >/dev/null
check "the schema holds no object" "$([ "$(leftovers)" = 0 ]; echo $?)"
check "the domain roles are gone" "$([ "$(domain_roles)" = 0 ]; echo $?)"
check "the control table holds no changeset" "$([ "$(applied)" = 0 ]; echo $?)"

echo "step 4 - the tree rebuilds"
liquibase update >/dev/null
check "the rebuild applies the same changesets" "$([ "$(applied)" = "$first" ]; echo $?)"

[ "$fail" -eq 0 ] && echo "db-ci: all checks passed" || { echo "db-ci: FAILED"; exit 1; }
