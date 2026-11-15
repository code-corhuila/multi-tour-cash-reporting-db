# Changelog

All notable changes of `multi-tour-cash-reporting-db` (Cash and Reporting schema (Liquibase)) are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [3.0.0] - 2026-11-14

Cut 3 release. Every entry below is a pull request merged into `qa` and re-applied to `release/3.0.0` with `git cherry-pick -x`; the heading of each group is the user story named in the pull request, and the entry is the title of the pull request without its type. The frozen head of `qa` is `fcdaf36f87319b5229f27532a5f9a170e0241d38`.

### Changed

#### HU-CSH-001 - Operate the daily cash

- The first batch of the daily cash ([PR 9](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/9))
- The second batch of the daily cash ([PR 10](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/10))
- The grants, indexes and movement concept ([PR 11](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/11))
- The cash_reporting schema ([PR 13](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/13))
- The correction note table ([PR 15](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/15))
- The reservation and the reversal link of the cash movement ([PR 19](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/19))

#### HU-CSH-002 - Consult the daily dashboard

- The dashboard projection and processed events ([PR 18](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/18))
- The fact tables and the monthly report ([PR 25](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/25))
- The creation instant and the event id of the fact states ([PR 27](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/27))
- The dashboard probes of HU-CSH-002 ([PR 30](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/30))

#### HU-CSH-003 - Consult the monthly report and the cash consolidation

- The month probes of HU-CSH-003 ([PR 31](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/31))

#### HU-SEC-005 - Manage the tenant's internal users

- The account session cutoff table ([PR 33](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/33))

#### HU-SEC-007 - Exceptional and emergency access of the Platform Administrator

- The exceptional access use event of the cash outbox ([PR 21](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/21))
- The usedAt of the exceptional access event ([PR 23](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/23))

#### Cross-cutting: CI, test fixes and alignment promotions (no single story is named in the PR title, branch or body)

- The db-ci timeout margin ([PR 35](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/35))
- The checks on pull requests to main ([PR 37](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/37))
- Run the test workflow only on pull requests to develop and qa ([PR 41](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/41))

### Fixed

#### Cross-cutting: CI, test fixes and alignment promotions (no single story is named in the PR title, branch or body)

- The single income per payment ([PR 39](https://github.com/code-corhuila/multi-tour-cash-reporting-db/pull/39))

[Unreleased]: https://github.com/code-corhuila/multi-tour-cash-reporting-db/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/code-corhuila/multi-tour-cash-reporting-db/releases/tag/v3.0.0
