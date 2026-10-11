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

## CI

`.github/workflows/db.yml` has two jobs.

**Every pull request** (`Migrate and seed a container`) starts a `timescale/timescaledb`
service container, runs `dbmate --wait up`, runs `dbmate up` again (it must be a no-op), applies
`db/seed.sql` twice (it must be re-runnable), and checks that `job_logs` has its compression and
retention policies. Any error fails the job. It never touches Tiger.

**Manual dispatch only** (`Migrate Tiger Data`) runs `dbmate --wait up` against the shared Tiger
Data database. Nothing else runs migrations there. To trigger it:

- First, `db.yml` must be on the default branch (`main`). GitHub offers Run workflow, and accepts
  `gh workflow run`, only for a `workflow_dispatch` workflow whose file is on the default branch,
  so until `db.yml` reaches `main` the dispatch job cannot be triggered from any branch.
- Once it is there, a run can target any branch, and it applies that branch's `db/migrations`:
  - GitHub: Actions → `db` → Run workflow → pick the branch.
  - CLI: `gh workflow run db.yml --ref <branch>`, then `gh run watch`.

It needs five repository secrets: `TIGER_HOST`, `TIGER_PORT`, `TIGER_DB_NAME`,
`TIGER_USERNAME` and `TIGER_PASSWORD`. `.github/scripts/with_tiger_url.py` assembles
`DATABASE_URL` from them (user, password and database name percent-encoded, `sslmode=require`),
masks the URL and the encoded values with `::add-mask::` (GitHub masks each secret on its own,
not a string built from them), and runs `dbmate` with the URL in its environment only. The URL is
never printed or written to `$GITHUB_ENV`. Runs are serialized (`concurrency: tiger-migrate`), so
two dispatches never migrate at once. The seed is not applied to Tiger.

After the first dispatch, open the run's log and confirm that no host, password or URL appears
unmasked (they show as `***`).
