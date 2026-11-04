# multi-tour-cash-reporting-db

> Database of the **Cash and reporting** macrodomain (macrodomain 4): the schema `cash_reporting`,
> inside the single PostgreSQL instance, migrated with Liquibase.

Part of **Multi Tour**. Governance and documentation live in
[`multi-tour-docs`](https://github.com/code-corhuila/multi-tour-docs) (specs in
`07-api/specs/cash-reporting/multi-tour-cash-reporting-db/`).

## What is this?
The migrations (DDL, DML, DCL, TCL and their rollbacks) of the schema `cash_reporting`. The instance,
its volume, its extensions and the login user `cash_reporting_app` belong to `multi-tour-infra-postgres`.

## What does it need?
Docker only. A PostgreSQL 18 with the schema `cash_reporting` and the user `cash_reporting_app`
(the infrastructure creates both). The runner reads `PG_DATABASE`, `PG_ADMIN_USER` and `PG_ADMIN_PASSWORD`
(see `.env.example`; the real `.env` is never versioned).

## How is it run?
- Apply: from the infrastructure compose, `docker compose --profile tooling run --rm cash-reporting-db-migrate`.
- Verify the four steps of Annex A (update, update again, rollback to empty, update) on an empty,
  throwaway PostgreSQL: `bash tests/db-ci.sh`. The same file runs in `.github/workflows/db-ci.yml`.

## How is it tested?
`tests/db-ci.sh` (one probe per acceptance criterion of the story, each written to fail first).
The control tables are `databasechangelog_cash_reporting` and `databasechangeloglock_cash_reporting`.

## What does it not do?
It creates no instance, no extension and no login user, writes nothing outside `cash_reporting`, and
holds no secret. Another domain reads its data through events or its API, never through this schema.

## Branching
Three permanent branches, none accepts a direct commit: `develop` <- `feat/`, `fix/`, `chore/`;
`qa` <- `qa/`; `main` <- `release/`, `hotfix/`. Promotion is `git cherry-pick -x`, never a merge
between permanent branches. `main` requires the teacher's approval. Full norm: `multi-tour-docs`.
