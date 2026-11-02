# The migration runner: Liquibase and the PostgreSQL driver, both at a fixed version.
# Liquibase 5 does not ship the driver, so it is installed here with a verified checksum.
FROM liquibase/liquibase:5.0.4
RUN lpm add postgresql@42.7.13 --global
# The migrations travel with the runner (the build context is the repository root, see .dockerignore),
# so applying them needs no volume and the runner and the SQL it applies are versioned together.
WORKDIR /liquibase/work
COPY --chown=liquibase:liquibase . .
