# db

Schema, migrations and seed data for the Tiger Data (TimescaleDB) database. See
[docs/SPEC.md](../docs/SPEC.md) §4 for the schema and its rules.

## Install dbmate

[dbmate](https://github.com/amacneil/dbmate) is a single binary that applies plain `.sql`
files in `db/migrations/` and records applied versions in `schema_migrations`.

```sh
# Arch
yay -S dbmate
# any Linux / macOS
sudo curl -fsSL -o /usr/local/bin/dbmate \
  https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
sudo chmod +x /usr/local/bin/dbmate
```

## DATABASE_URL

dbmate reads `DATABASE_URL`. Tiger Cloud requires TLS, so use `sslmode=require`, and
percent-encode the password if it has special characters (`@`, `:`, `/`, `#`, `%`, ...).

```sh
export DATABASE_URL="postgres://tsdbadmin:<percent-encoded-password>@<host>:<port>/tsdb?sslmode=require"
```

In CI the parts come from the `TIGER_USERNAME`, `TIGER_PASSWORD`, `TIGER_HOST`, `TIGER_PORT`
and `TIGER_DB_NAME` secrets. For a local container use
`postgres://postgres:pw@localhost:5432/postgres?sslmode=disable`.

## Migrate

```sh
dbmate --migrations-dir db/migrations --no-dump-schema up
```

A second `up` is a no-op. Migrations are forward-only. Check the policies afterwards:

```sql
SELECT job_id, proc_name, schedule_interval, hypertable_name
FROM timescaledb_information.jobs
WHERE hypertable_name = 'job_logs';
```

## Seed

```sh
psql "$DATABASE_URL" -f db/seed.sql
```

The seed adds a completed run with a job, steps 0..3 and six gapless log lines, plus an
in-progress run with one running job, a failed run, and three runners (busy, idle and
offline). It is safe to run twice.
