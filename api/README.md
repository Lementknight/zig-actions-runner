# api

The read API over the runner's data (docs/SPEC.md §5.3): Hono on Node, `pg` for Postgres. It
only reads. Every connection starts with `default_transaction_read_only=on`, so a write fails
even if a route tried one (SPEC §4: only the runner writes).

## Run

```sh
npm --prefix api ci
DATABASE_URL=... npm --prefix api start      # PORT defaults to 8080
```

`DATABASE_URL` is required and is never printed. `web/`'s dev server proxies `/api` to
`http://localhost:8080` (`API_PROXY_TARGET` overrides it).

## Docker

`api/Dockerfile` runs the API on Bun, inside the image only; local dev and CI stay on npm. Bun
installs the production dependencies from `package-lock.json` and runs `src/server.ts` directly,
with no build step. From the repo root:

```sh
docker build -t zig-actions-api api
docker run --rm -e DATABASE_URL=... -p 8080:8080 zig-actions-api
```

| Variable | Required | Default | |
|---|---|---|---|
| `DATABASE_URL` | yes | none | Given at `docker run`, never stored in the image. Without it the container prints `DATABASE_URL is not set` and exits 1. |
| `PORT` | no | `8080` | The port inside the container. |

The Bun version is the `BUN_VERSION` build argument (`1.4.3`), pinned to the same value as `web/Dockerfile`; change both together.

The `HEALTHCHECK` calls `GET /api/health` every 10 seconds with Bun's own `fetch` (the slim image
has no curl). That route runs `SELECT 1`, so `docker ps` shows the container `unhealthy` while the
database is down and `healthy` again once it answers. The container runs as the image's `bun`
user, not root. `.dockerignore` keeps `node_modules`, `.env*` and the tests out of the build.

To reach a database in another container, put both on one Docker network and use the database
container's name as the host in `DATABASE_URL`. A database on the host is `host.docker.internal`
on Docker Desktop.

## Endpoints

| Endpoint | Returns |
|---|---|
| `GET /api/health` | `{ "ok": true }` after a `SELECT 1`; 503 `{ "ok": false, ... }` when the database does not answer |
| `GET /api/runs?repo=&limit=&before=` | A bare array of runs, newest first (`created_at DESC, id DESC`) |
| `GET /api/runs/:id` | The run with `jobs[]` (by id), each with `steps[]` (by `number`) |
| `GET /api/runners` | A bare array of runners by name: status, labels, timestamps, `current_job` and job counts |
| `GET /api/jobs/:id/logs?after=&limit=` | `{ lines: [{ seq, step, stream, ts, line }], next_after, job_done }`, lines with `seq > after` by `seq` |

- Fields are the table columns, snake_case. BIGINT ids are JSON numbers. Timestamps are ISO 8601
  (`2026-10-11T12:00:00.000Z`); nullable columns are `null`.
- `limit` defaults to 50; larger values are capped at 200. `before` is a run id and returns the
  runs that sort after it, that is older. An empty parameter (`?repo=`) means absent.
- Logs: `after` defaults to 0, `limit` to 1000, capped at 5000. `next_after` is the last `seq`
  returned, or echoes `after` on an empty page. `job_done` is true only when the job is
  `completed` and no line past `next_after` exists. The query bounds `ts` from the job's
  `started_at` less an hour, so TimescaleDB scans only the job's chunks.
- Runners: `status` is `offline` when the row says so or `last_seen_at` is more than 2 minutes
  old by the database's clock, `busy` only when the row says busy and the runner has an
  in-progress job, and `idle` otherwise. `current_job` (`{ id, run_id, name }`) is set exactly
  when `status` is `busy`. `running_jobs` and `completed_jobs` count `jobs` by `runner_name`.
  Names sort in byte order (`COLLATE "C"`), as JavaScript's `sort()` does.
- docs/SPEC.md §5.3 is the contract; this list is a summary of it.
- A malformed id, `limit`, `before` or `after` answers 400 `{ "error": "..." }`. An
  unknown run, job or path answers 404 `{ "error": "not found" }`. A database failure answers 500
  `{ "error": "internal error" }` and logs only the error message.

## Test

```sh
npm --prefix api test
```

This typechecks, then runs the unit tests, which stub the database. The tests in
`test/*.db.test.ts` run only when `DATABASE_URL` points at a database migrated and seeded as in
`db/README.md`, and skip otherwise. Against a local container:

```sh
docker run -d --name tsdb -e POSTGRES_PASSWORD=postgres -p 5432:5432 timescale/timescaledb:latest-pg17
export DATABASE_URL='postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable'
dbmate --migrations-dir db/migrations --no-dump-schema --wait up
psql "$DATABASE_URL" -f db/seed.sql
npm --prefix api test
```

## Contract check

`web/src/api/contract.test.ts` asserts the read API contract the frontend relies on. With
`CONTRACT_API_URL` set it also runs against a real API. `scripts/contract-check.sh` starts this
API on `CONTRACT_PORT` (default 8080), waits for `/api/health`, runs
`CONTRACT_API_URL=http://localhost:<port>/api npm --prefix web test`, and stops the API. If
anything fails, it prints the API's log. From the repo root, with the container above migrated
and seeded and `DATABASE_URL` still exported:

```sh
npm --prefix api ci && npm --prefix web ci
sh api/scripts/contract-check.sh
```

The contract needs the seed: it looks for a completed job with at least three log lines.

## CI

`.github/workflows/api.yml` runs the same check on every pull request. It starts a
`timescale/timescaledb` service container, migrates and seeds it, runs `npm --prefix api test`
with `DATABASE_URL` set (so the database tests run), then runs `api/scripts/contract-check.sh`.
A failed api test or contract test fails the job. It never touches Tiger.
