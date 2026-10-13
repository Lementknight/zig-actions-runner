# Spec Sheet

Status: draft v0.1 · Companion: [DESIGN.md](DESIGN.md)

This is the contract between components. If you change anything here, tell the team and update this file in the same PR.

## 1. Repo layout (proposed)

```
hackathon/
  docs/                 DESIGN.md, SPEC.md
  runner/               Zig runner
    src/
      main.zig          CLI entry
      config.zig        env/flags
      github/           jitconfig.zig, auth.zig, broker.zig
      dagger.zig        pipeline driver
      sink.zig          LogSink interface + postgres impl
  api/                  TypeScript read API
  web/                  frontend
  db/migrations/        numbered .sql files
  deploy/               Dockerfile, compose.yaml
```

## 2. Runner configuration

Environment variables (flags override):

| Var | Required | Description |
|---|---|---|
| `GH_TOKEN` | yes | Token with admin on the repo/org (to call `generate-jitconfig`) |
| `GH_SCOPE` | yes | `owner/repo` or `org:<name>` |
| `RUNNER_LABELS` | no | Comma-separated, default `self-hosted,linux,zig` |
| `RUNNER_GROUP_ID` | no | Default `1` |
| `RUNNER_NAME_PREFIX` | no | Name becomes `<prefix>-<hostname>-<n>` |
| `DATABASE_URL` | no | `postgres://user:password@host:port/database?sslmode=require` (Tiger Data; user and password percent-encoded). `sslmode` is `require` (TLS verified against the system CAs and the host name, the default), `no-verify` (TLS without verification) or `disable` (plain TCP, local containers). Instead of a URL the standard `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` and `PGSSLMODE` variables work. If neither is set, logs go to stdout only (`StdoutSink`, §5.1) |
| `DAGGER_CMD` | no | Path to the `dagger` CLI, default `dagger`. With `RUNNER_ENGINE=direct` it is only run to create a missing engine container (`dagger core version`) |
| `RUNNER_ENGINE` | no | `direct` (default) or `cli` (flag `--engine`): how jobs reach the Dagger engine. `direct`: the runner holds each job's Dagger session itself (`src/engine.zig`, see §6 "Engine client"); `cli`: each job runs a `dagger run` child, as before |
| `RUNNER_ENGINE_HOST` | no | The engine's own listener, `tcp://host:port` or `unix:///path` (flag `--engine-host`), for `direct` sessions: the runner connects to it directly, with no Docker API and no `buildctl dial-stdio` process per connection (see §6 "Engine client"). Empty (default): through `RUNNER_ENGINE_CONTAINER` |
| `RUNNER_ENGINE_CONTAINER` | no | Default `dagger-engine-v0.21.10`: the engine container `direct` sessions connect through (the container the `dagger` CLI of that version starts) |
| `DOCKER_HOST` | no | A `unix://` socket for the Docker API (default `/var/run/docker.sock`), which `direct` sessions use to reach the engine |
| `RUNNER_IMAGE` | no | Base image for jobs, default `ubuntu:24.04` (flag `--image`). The default gets `git`, `curl`, `xz-utils`, `jq` and CA certificates installed; a custom image is used as is |
| `RUNNER_DAGGER_NESTING` | no | `true` (default) or `false` (flag `--dagger-nesting`). Gives each step's commands access to the job's Dagger engine, so `dagger call` works inside a job (see §6 "Dagger inside a job"). A job with this access can run privileged containers, so it controls the runner's host: turn it off where untrusted workflows (for example pull requests from forks) can reach the runner |
| `RUNNER_JS_RUNTIME` | no | `bun` (default) or `node` (flag `--js-runtime`): what runs JavaScript actions (see §6) |
| `RUNNER_PACKAGE_CACHES` | no | `true` (default) or `false` (flag `--package-caches`): mount persistent Dagger cache volumes at package managers' cache directories in every job (see §6 "Package caches") |
| `RUNNER_STEP_CACHE` | no | `true` (default) or `false` (flag `--step-cache`): reuse a step's result from an earlier run when its inputs are unchanged; steps that use secrets or read run-specific values always run (see §6 "Step caching"). A workflow or job opts out with `ZIG_RUNNER_STEP_CACHE: false` in its `env` |
| `LOG_FLUSH_LINES` | no | Default `200` |
| `LOG_FLUSH_MS` | no | Default `500` |
| `RUNNER_COUNT` | no | Default `1` (flag `--runners`, 1 to 1024): how many runners this process runs, as concurrent tasks (`std.Io.Group`). Each registers under its own name and serves jobs one after another as described for `RUNNER_ONCE`; they share the configuration, the console and database log sinks (each line written whole) and one database connection (one query at a time), and each job still gets its own Dagger session. The process exits when every runner has stopped, with the most severe exit code. Verified live: `--runners 3` ran a three-job matrix at the same time (all three started within 3 s and finished in 18 s, against 45 s one after another); the process used about 31 MB idle and 47 MB at peak (Debug build), with 10 threads throughout, while the three `dagger run` children used about 65 MB each |
| `RUNNER_ONCE` | no | `false` (default) or `true` (flag `--once`): exit after one job, as an ephemeral runner process. By default the runner keeps going: after each job it registers a new JIT runner (GitHub gives a JIT runner one job) under a new name and waits for the next, freeing everything the job allocated in between (verified live: one process ran a three-job matrix one job after another, each under a fresh registration, its RSS returning to about 20 MB after each job). A cycle that fails before running a job is retried after 5 s, 10 s, 20 s, ... up to 5 minutes; a registration GitHub rejects (HTTP 401, 403, 404 or 422: bad token or scope) stops the runner with exit code 2 |

Flags: `--token`, `--scope`, `--engine`, `--engine-host`, `--labels`, `--group-id`, `--name-prefix`, `--database-url`, `--dagger-cmd`, `--image`, `--dagger-nesting`, `--js-runtime`, `--package-caches`, `--step-cache`, `--log-flush-lines`, `--log-flush-ms` (as `--flag value` or `--flag=value`), plus `--runners` (see `RUNNER_COUNT`), `--once` (exit after one job), `--dry-run` (validate config, register nothing) and `--db-check` (connect to the configured database, print the server and TimescaleDB versions, whether the tables and the `job_logs` hypertable exist, and how many `zig_it_*` test schemas are left; no GitHub credentials needed, prints no credentials or host name; exit 0, or 3 if the database is unavailable).

Stopping (verified live): SIGTERM or SIGINT asks the runners to stop. A runner waiting for a job stops at once: its long poll (which can otherwise take about 50 s) runs next to a watcher in a `std.Io.Select`, and on a stop the poll is cancelled (the blocked read is interrupted), then the runner deletes its broker session and registration as after any cycle; two idle runners stopped in about 1 s with no registration left. A runner with a job finishes it, reports it and uploads its logs, then stops (a 20 s job stopped mid-way finished and succeeded, and the process exited 0 with no registration left). Removing a registration is retried (after 1 s, then 2 s) when GitHub answers 422 or 5xx or the request fails, and a registration still left is reported on stderr rather than dropped silently. The process exits 0 once every runner has stopped. A second signal exits at once with code 130, leaving registrations (and a running job) behind. Two signals sent back to back may arrive as one.

Exit codes: `0` job done (with `--once`; without it the runner exits on errors or when stopped), `130` a second stop signal, `1` config error (including an unparsable database URL), `2` GitHub auth/protocol error, `3` DB unavailable when the runner starts (a database that fails later never fails a job; see §5.1).

## 3. GitHub interaction

Documented:
- `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` and the org equivalent. Body: `name`, `runner_group_id`, `labels[]`, optional `work_folder`. Returns `runner{}` and `encoded_jit_config`.
- Token needs `repo` (repo scope) or `admin:org` (org scope).

Undocumented (reverse-engineered from `actions/runner`, treat as unverified until tested):
- `encoded_jit_config` is base64 JSON: `{ "<filename>": "<base64 file content>" }`. Files include runner settings, RSA credentials and OAuth credential data.
- Broker: `POST session`, `GET message?sessionId&status&runnerVersion&os&architecture`, `DELETE session?sessionId`.
- Broker error kinds to handle: `RunnerNotFound`, `RunnerVersionTooOld`, `RunnerSessionInvalid`, `HostedRunnerDeprovisioned`.
- Job message type `AgentJobRequestMessage`.

Verified live (M1, 2026-10-11, repo scope):
- `encoded_jit_config` decodes to three files: `.runner`, `.credentials`, `.credentials_rsaparams`.
- `.runner` is JSON with PascalCase string values: `AgentId`, `AgentName`, `PoolId`, `ServerUrl`, `ServerUrlV2` (`https://broker.actions.githubusercontent.com/`), `UseV2Flow` (`"true"`), `Ephemeral`, `GitHubUrl`, `WorkFolder`, `DisableUpdate`.
- `.credentials` is PascalCase: `Scheme` (`OAuth`), `Data.ClientId`, `Data.AuthorizationUrl`.
- `.credentials_rsaparams` is lowercase base64: `modulus`, `exponent`, `d`, `p`, `q`, `dp`, `dq`, `inverseQ`.
- OAuth: POST form `grant_type=client_credentials`, `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`, `client_assertion=<RS256 JWT>` (claims `sub`=`iss`=ClientId, `aud`=AuthorizationUrl, `nbf`, `iat`, `exp`=+5min, `jti`) to `AuthorizationUrl` returns HTTP 200 with `access_token`.
- `runner --inspect` reproduces these checks and deletes the runner it registers.

Verified live (M2, 2026-10-11), broker base = `ServerUrlV2`, `Authorization: Bearer <access_token>`:
- `POST {broker}session` with `{"ownerName","agent":{"id","name","version","osDescription","ephemeral","disableUpdate"},"useFipsEncryption":false}` returns 201 `{sessionId, ownerName, assignmentQueued, orchestrationId}`. The response carries no encryption key.
- `GET {broker}message?sessionId=&status=Online&runnerVersion=&os=Linux&architecture=X64&disableUpdate=true` long-polls about 50 s, then returns 202 with an empty body when no job is queued.
- `DELETE {broker}session?sessionId=` returns 204 with no body and no `Content-Length`.
- The broker enforces a minimum `runnerVersion`: 2.328.0 gets 403 `{"source","errorMessage","errorKind":"RunnerVersionTooOld","statusCode":403}`; 2.338.0 (latest release on 2026-10-06) is accepted. Keep the claimed version current.
- Verified with a real queued job (push to a throwaway branch with `runs-on: [self-hosted, <unique label>]`): `GET message` returns 200 `{messageId, messageType:"RunnerJobRequest", body:"<JSON string>"}`. The parsed `body` is `{runner_request_id, run_service_url, billing_owner_id, should_acknowledge}`; `run_service_url` is a `run-actions-*.actions.githubusercontent.com` host. The message itself is not encrypted.
- The job is assigned to the runner when the message is delivered; deleting a runner then returns 422 until the run is cancelled or finishes.
Verified live (run service, 2026-10-11), `run_service_url` from the `RunnerJobRequest` body, `?api-version=2024-11-01`:
- `POST {run_service_url}/acquirejob` with `{"jobMessageId": <runner_request_id>, "runnerOS": "Linux", "billingOwnerId": <billing_owner_id>}` and the runner's access token returns 200 with the full job definition (about 35 KB). It holds secrets (`github_token`, a job-scoped `AccessToken`, `mask` values): never log it.
- Job definition keys: `steps[]`, `variables{}`, `mask[]`, `plan{planId}`, `jobId`, `timeline{id}`, `requestId`, `lockedUntil`, `resources.endpoints[].authorization.parameters.AccessToken`, `contextData{github,inputs,job,matrix,needs,strategy,vars}`, `fileTable[]`, `billingOwnerId`.
- A `run:` step is `{type:"action", reference:{type:"script"}, id, contextName, name, condition, inputs:{type, map:[{Key:{lit:"script"}, Value:{lit:"<script text>"}}]}}`. Inputs and `contextData` use the compact template-token encoding (`t`/`type` ints, `lit`, `k`/`v`, `d`).
- `POST {run_service_url}/completejob` with `{"planId","jobId","conclusion":"succeeded","outputs":{},"stepResults":[],"annotations":[],"telemetry":[]}` returns 204 and GitHub marks the job and run `success`. It must be authorized with the job-scoped `AccessToken` from `resources.endpoints`; the runner's own token gets 401 "Not authorized for this job".
- `POST .../acknowledge` returns 400 "request hmac is missing". It is not required: `acquirejob` works without it.
- After `acquirejob`, the job is held by the runner. Cancelling the run (even force-cancel) did not release it for several minutes; always finish it with `completejob`.
- `completejob` conclusions are the .NET `TaskResult` names: `succeeded`, `failed`, `canceled` (`"cancelled"` gets 400 "Bad Request"); step results use the same words.
- `stepResults` (verified live; GitHub then lists exactly these steps): `[{"external_id": <step id>, "number": N, "name": "...", "status": "completed", "conclusion": "succeeded"|"failed"|"skipped", "started_at": "<ISO-8601 UTC, ms>", "completed_at": "..."}]`, numbered from 1. `"success"`/`"failure"` as conclusions get HTTP 400 "Bad Request" (the vocabulary is the same as the job conclusion). A rejected `completejob` leaves the job held, so the runner retries with `"stepResults": []`. GitHub does not add synthetic "Set up job" / "Complete job" steps.
- A step's display name is the literal `displayNameToken` when the workflow sets `name:`; otherwise `name` is the internal `__run` and the runner shows `Run <first line of script>` (what GitHub shows for unnamed steps).
- `contextData.job` is `{t, d:[{k, v}]}` and holds `check_run_id`, which is GitHub's numeric job id (the REST `jobs/{id}`); it is the key used for logs.
- Variables flagged `isSecret` (`github_token`, `system.github.token`) and the job token must be masked in all output; the `mask` array uses a regex encoding and is not used.
- End to end (runner started, commit pushed, job runs through Dagger, GitHub shows the run and both steps `success`, the ephemeral runner is gone): about 4 s from `acquirejob` to completion for a 3 s script; about 0.8 s when the identical steps are served from Dagger's cache.
- Log upload to GitHub (verified live; without it the Actions UI shows empty steps and `GET .../jobs/{id}/logs` is 404):
  - Base URL is the job variable `system.github.results_endpoint`; auth is the job-scoped token (`Authorization: Bearer`).
  - Per step and for the whole job, all JSON over Twirp at `{base}/twirp/results.services.receiver.Receiver/<Method>`: `GetStepLogsSignedBlobURL` / `GetJobLogsSignedBlobURL` with `{workflow_run_backend_id: plan.planId, workflow_job_run_backend_id: jobId, step_backend_id: <step id>}` (no step id for the job) returns `{logs_url, ...}`.
  - `PUT logs_url` with `x-ms-blob-type: BlockBlob` and no `Authorization` header; body lines are `<ISO-8601 UTC with 7 fractional digits> <text>\n`.
  - Then `CreateStepLogsMetadata` / `CreateJobLogsMetadata` with the same ids plus `{uploaded_at, line_count}`.
  - After this, `jobs/{id}/logs` returns the job log and the run's log archive has a file per step (named after the step) plus GitHub's own `system.txt`.
  - Uploads happen after the steps finish and before `completejob`; a failed upload is reported and never blocks completion. Logs are kept in memory (redacted, capped at 64 MiB) until then, so a live console feed while the job runs is not provided.
- `POST {run_service_url}/renewjob` with `{"planId","jobId"}` and the job's `AccessToken` (the runner's token gets 401 "Not authorized for this job", as for completejob) returns 200 with `{"lockedUntil": "<ISO-8601>", ...}`, 10 minutes after the call. `acquirejob`'s own `lockedUntil` is the zero date (`0001-01-01T00:00:00`). Without renewal GitHub fails the job exactly 10 minutes after `acquirejob` with the annotation "The self-hosted runner lost communication with the server", while its steps still run (verified live: a 16-minute step). The runner renews every 60 s for the whole job, as `actions/runner` does, from a task next to the job.
- A kept-alive connection that the server closed while it sat idle returns no bytes (`HttpConnectionClosing`, seen on completejob after a 16-minute step); the request was not processed, so the runner sends it once more on a new connection.
- `annotations` in completejob (verified live next to `ubuntu-latest`: GitHub lists the same annotations for both): `[{"level": "FAILURE"|"WARNING"|"NOTICE", "message", "title", "path", "startLine", "endLine", "startColumn", "endColumn", "stepNumber", "isInfrastructureIssue": false}]` (actions/runner's `Annotation`). They come from `::error`/`::warning`/`::notice` (properties `file`, `line`, `endLine`, `col`, `endColumn`, `title`; a path in the workspace is made relative to it; `endLine`/`endColumn` default to `line`/`col`) and from the runner's own errors ("Process completed with exit code N.", timeouts, "The operation was canceled."). One without a file points to its line in the step's log (GitHub shows it as `.github` with that line). At most 10 per level and step, as GitHub's runner.
- Step summaries: what a step writes to `$GITHUB_STEP_SUMMARY` (a fresh file per step; several execs of one step, as in a composite action, are joined) is read back with the step's other file commands, masked like the logs, and uploaded after them, as actions/runner does: `GetStepSummarySignedBlobURL` (`{workflow_run_backend_id, workflow_job_run_backend_id, step_backend_id}` → `summary_url`), a `PUT` of the markdown (`x-ms-blob-type: BlockBlob`), then `CreateStepSummaryMetadata` with the ids, `upload_size` and `uploaded_at` (verified live: both calls succeed). Over 1 MiB, the step logs GitHub's "$GITHUB_STEP_SUMMARY upload aborted" error and nothing is uploaded.
- Still unverified: the live console feed (`FeedStreamUrl`).
- Zig 0.17 `std.http.Client` pitfalls: for 204 responses without `Content-Length`, `Request.deinit` blocks draining the body (set `connection.closing = true` first); the default 1 KiB write buffer is smaller than the ~1.6 KiB bearer token, so raise `write_buffer_size`.

Findings from M2–M4 must be written back into this section.

## 4. Database schema (Tiger Data / TimescaleDB)

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE runs (
  id            BIGINT PRIMARY KEY,          -- GitHub run id
  repo          TEXT NOT NULL,
  workflow      TEXT NOT NULL,
  event         TEXT,
  branch        TEXT,
  sha           TEXT,
  status        TEXT NOT NULL,               -- queued|in_progress|completed
  conclusion    TEXT,                        -- success|failure|cancelled|NULL
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(), -- first seen; never overwritten by upserts
  completed_at  TIMESTAMPTZ
);

CREATE TABLE jobs (
  id            BIGINT PRIMARY KEY,          -- GitHub job id
  run_id        BIGINT NOT NULL REFERENCES runs(id),
  name          TEXT NOT NULL,
  runner_name   TEXT,
  status        TEXT NOT NULL,
  conclusion    TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ
);

CREATE TABLE steps (
  job_id        BIGINT NOT NULL REFERENCES jobs(id),
  number        INT NOT NULL,                -- step 0 is a real row, "Set up job", written by the runner
  name          TEXT NOT NULL,
  status        TEXT NOT NULL,
  conclusion    TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  PRIMARY KEY (job_id, number)
);

CREATE TABLE job_logs (
  ts            TIMESTAMPTZ NOT NULL,
  job_id        BIGINT NOT NULL,
  step_number   INT NOT NULL,
  seq           BIGINT NOT NULL,             -- monotonic per job, assigned by runner
  stream        TEXT NOT NULL CHECK (stream IN ('stdout', 'stderr')),
  line          TEXT NOT NULL,
  PRIMARY KEY (job_id, seq, ts)
);

SELECT create_hypertable('job_logs', by_range('ts', INTERVAL '1 day'));
ALTER TABLE job_logs SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'job_id',
  timescaledb.compress_orderby   = 'seq'
);
SELECT add_compression_policy('job_logs', INTERVAL '1 day');
SELECT add_retention_policy('job_logs', INTERVAL '30 days');

CREATE INDEX runs_created_at_idx      ON runs (created_at DESC, id DESC);        -- unfiltered list and its `before` cursor
CREATE INDEX runs_repo_created_at_idx ON runs (repo, created_at DESC, id DESC);
CREATE INDEX jobs_run_id_id_idx       ON jobs (run_id, id);
```

Added by `002_runners.sql`:

```sql
CREATE TABLE runners (
  name           TEXT PRIMARY KEY,           -- the runner name (`jobs.runner_name` refers to it, without a foreign key)
  status         TEXT NOT NULL CHECK (status IN ('idle', 'busy', 'offline')),
  labels         TEXT[] NOT NULL DEFAULT '{}',
  registered_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now() -- heartbeat
);
CREATE INDEX jobs_runner_name_idx ON jobs (runner_name, status);
```

`job_logs` uses 1 day chunks (the default is 7). The primary key keeps `ts` because TimescaleDB requires the partition column in unique constraints.

Rules:
- Only the runner writes. The API is read-only.
- `seq` starts at 1 per job and has no gaps; the frontend relies on it for ordering and resume.
- The runner upserts its `runners` row on registration, sets `busy` when it acquires a job and `idle` when the job ends, refreshes `last_seen_at` on every broker poll (about every 50 s) and sets `offline` on a clean exit. The read API also reports a runner as `offline` when `last_seen_at` is older than 2 minutes (two polls), so a crashed runner does not stay `idle`.
- Log lines are stored with ANSI codes intact; the frontend renders them.
- Migrations live in `db/migrations/NNN_name.sql`, forward-only.
- Migrations are applied with dbmate (`db/README.md`); `db/seed.sql` holds demo data for the API and contract test.
- Exact TimescaleDB function syntax should be verified against the Tiger Data version in use before the first migration is merged. The Tiger service runs TimescaleDB 2.30.2 on PostgreSQL 18.6 (checked 2026-10-11). `001_init.sql` applied cleanly there (via SQL), and via `dbmate up` (second run a no-op) on a fresh `timescale/timescaledb:latest-pg17` container.

## 5. Component interfaces

### 5.1 LogSink (Zig, `sink.zig`)

```
LogSink
  append(job_id, step_number, stream, line)   // buffered, non-blocking
  flush()                                      // forced, called at step/job end
  close()
```
Implementations: `PostgresSink` (batched insert/COPY) and `StdoutSink` (for local dev without a DB). The runner must work with `StdoutSink` alone.

`PostgresSink` (verified against the schema in `db/migrations/001_init.sql` on TimescaleDB 2.30 / Postgres 17, and in a live job):
- Every line is first passed to the console sink, then redacted, stamped with a timestamp and a per-job `seq` (1, 2, 3, ... assigned when appended, so gapless unless lines are dropped, see below), and buffered. A batch is written with one `COPY job_logs (ts, job_id, step_number, seq, stream, line) FROM STDIN` when it reaches `LOG_FLUSH_LINES` (default 200), when `LOG_FLUSH_MS` (default 500) has passed since the last write (checked on every append and by a background flusher, so a quiet job's last line is not stuck), and at every step end and job end. `job_id` is GitHub's numeric job id (`check_run_id`).
- Messages that belong to no job (registering the runner, waiting for work) have job id 0 and go to the console only.
- Step numbering follows the schema: step 0 is "Set up job" (the runner's own messages about the job, such as acquiring it); the workflow's steps are 1..n.
- The database must never fail a job. A failed write keeps the lines buffered; the next flush reconnects and retries, at most every 2 s. If the buffer grows past 100 000 lines the oldest are dropped and counted, which is the only way a `seq` gap appears. A database that is unavailable when the runner starts is an error (exit code 3); one that fails later is not.
- The live stdout and stderr of a step are merged, so every streamed line is stored with `stream = 'stdout'` (the column allows `stderr`).
- Values are written with quoted literals and COPY text escaping; NUL bytes and invalid UTF-8, which Postgres rejects, are replaced with U+FFFD. ANSI escape codes are stored intact.

### 5.2 Job state updates

The runner updates `runs`, `jobs` and `steps` at these transitions only: job start, step start, step end, job end. Each is a single upsert, idempotent on the primary key (`INSERT ... ON CONFLICT DO UPDATE`), and writes happen in foreign-key order (run, then job, then steps).
- Job start: `runs` (status `in_progress`, repo, workflow, event, branch, sha from the `github` context), `jobs` (name from `jobDisplayName`, runner name, `started_at`), and step 0 "Set up job" as completed.
- Step start: `steps` row `in_progress` with `started_at`. Step end: `completed` with its conclusion (`success`, `failure`, `cancelled`, or `skipped`; a failed step with `continue-on-error` is `success`) and `completed_at`. A skipped step, or one that fails before running, is written once, already completed.
- Job end: `jobs` completed with `success` or `failure`, and `runs` completed with the same conclusion. One runner handles one job, so the run's state follows its job; a workflow with several jobs is therefore reported by whichever job finishes last.
- `runs.created_at` is when the run was first seen and is never overwritten; `jobs.started_at` and `steps.started_at` are kept when a later upsert omits them.
- A write that fails is counted and reported once at the end (`run state: N database write(s) failed`); it never fails the job.

### 5.3 Read API (`api/`)

Hono on Node with `pg` (`api/README.md`). It only reads: every connection starts with `default_transaction_read_only=on`. `DATABASE_URL` is required; `PORT` defaults to `8080`.

| Endpoint | Returns |
|---|---|
| `GET /api/runs?repo=&limit=&before=` | Run list, newest first |
| `GET /api/runs/:id` | Run + its jobs + steps |
| `GET /api/jobs/:id/logs?after=<seq>&limit=` | Log lines with `seq > after`, ordered by `seq` |
| `GET /api/runners` | Every runner with its state and job counts |
| `GET /api/health` | `{ "ok": true }` |

Response shapes mirror the table columns (snake_case JSON). BIGINT ids and `seq` are JSON numbers; timestamps are ISO 8601; nullable columns are `null`. An empty query parameter (`?repo=`) counts as absent.

- **Run list.** A bare array, ordered `created_at DESC, id DESC`. `repo` filters by repository. `before` is a run id and returns only runs older than it in that order (an unknown id gives `[]`). `limit` defaults to `50`; larger values are capped at `200`.
- **Run.** The run's columns plus `jobs`, ordered by `id`, each with its `steps` ordered by `number`.
- **Health.** Runs `SELECT 1`; answers `503 { "ok": false, ... }` when the database does not answer.

Log response:
```json
{ "lines": [{"seq": 1, "step": 2, "stream": "stdout", "ts": "...", "line": "..."}], "next_after": 1, "job_done": false }
```
- `after` defaults to `0`. `limit` defaults to `1000`; larger values are capped at `5000`.
- `next_after` is the `seq` of the last line returned. On an empty page it echoes `after`.
- `job_done` is true only when the job's status is `completed` and no lines with `seq > next_after` exist. The API reads the job's status before its lines, so the runner must flush a job's log before it writes the job end transition (§5.1, §5.2).
- The query bounds `ts >= jobs.started_at - interval '1 hour'`, so only the job's own chunks are scanned (the hour covers clock skew between runner and database).

The client polls with `next_after` until `job_done` is true and a page comes back empty.

Errors: an unknown run, job or path answers `404 { "error": "not found" }`. A non-numeric or non-positive id, or a malformed `limit`, `before` or `after`, answers `400 { "error": "invalid ..." }`. A database failure answers `500 { "error": "internal error" }`.

Runners response (a bare array, ordered by `name`):
```json
[{ "name": "zig-runner-1", "status": "busy", "labels": ["self-hosted", "linux", "zig"],
   "registered_at": "...", "last_seen_at": "...",
   "current_job": { "id": 9100000002, "run_id": 9000000002, "name": "build" },
   "running_jobs": 1, "completed_jobs": 2 }]
```
`status` is `idle`, `busy` or `offline` (see §4 for how `offline` is derived). `current_job` is the runner's in-progress job, or null. The counts come from `jobs.runner_name`. Jobs queued on GitHub that no runner has acquired yet are not visible to the runner and are not listed.

### 5.4 Frontend pages

- `/` run list: status icon, workflow, repo, branch, sha, age, duration.
- `/runners` runner list: status badge, name, labels, last seen, current job (links to its run), running and completed job counts. A "Show all jobs" switch (off by default) lists every running and finished job under its runner; there is no jobs endpoint, so it walks `GET /api/runs` and `GET /api/runs/:id`.
- `/runs/:id` job list/graph with per-job status; selecting a job shows its steps.
- `/runs/:runId/jobs/:jobId` job view, linkable on its own: collapsible steps, ANSI-colored log viewer, live tail while `in_progress`, timestamps toggle.
- Must work with fake data from the M0 seed script.

## 6. Dagger execution

- One Dagger pipeline per job; base image defaults to `ubuntu:24.04` unless the job specifies `container:` (not supported yet) or `RUNNER_IMAGE` is set. The default image has `git`, `curl`, `xz-utils`, `jq` (composite actions often assume it, as GitHub's hosted images have it) and `ca-certificates` installed by one `apt-get` exec at the start of the job's container (cached by Dagger: about 13 s the first time, nothing after); a custom `RUNNER_IMAGE` is used as is, so it must bring its own tools.
- Workspace: the checked-out repo mounted at `/github/workspace`.
- `run:` steps become `withExec(["sh","-e","-c", script])`, honoring `working-directory`, `env` and `shell: bash|sh`.
- Step stdout/stderr lines go to `LogSink` as they arrive, in order.
- Step failure stops the job unless `continue-on-error` is set.
- Timeouts and cancellation (verified live next to `ubuntu-latest`: the same step conclusions and messages). A step's `timeout-minutes` arrives as `timeoutInMinutes` (`{"type":6,"num":1}`, or an expression) and the runner enforces it: past it, the step fails with "##[error]The action '<name>' has timed out after <n> minutes." (`continue-on-error` applies). The job's `timeout-minutes` is not in the job definition: GitHub enforces it by cancelling the job. A cancel (in the UI, or at the job's timeout) is a `JobCancellation` message on the runner's broker session (`{"jobId", "timeout": "0.00:05:00.0000"}`), so while a job runs the runner keeps polling it, as `Busy`. Then the running step ends with "##[error]The operation was canceled." (conclusion `cancelled`), `cancelled()` is true and `success()` false, so only `if: always()` / `cancelled()` steps and post scripts run, and the job completes as `canceled`. The message's timeout is the grace period: GitHub ends the job itself when it runs out (renewjob then returns 404, which the runner also treats as a cancel), so past it the runner stops whatever still runs. A step is stopped by shutting its query's connection to the engine; the engine then cancels the exec (verified: its processes are gone). With `RUNNER_ENGINE=cli` steps cannot be stopped, and run to their end.
- A single shared Dagger engine per machine serves all runners.

Expressions (verified live; `src/expr.zig`, `src/context.zig`):
- The server pre-parses templated strings: `run: echo ${{ github.sha }}` arrives as the token `{"type":3,"expr":"format('echo {0}', github.sha)"}`, so the runner evaluates only the expression text. The same holds for step `env`, `name:` (`displayNameToken`), `continue-on-error`, `shell`, `working-directory`, checkout inputs, and job/workflow `env` (the job's `environmentVariables` is a list of mapping tokens, workflow first). Conditions arrive already wrapped, for example `success() && (github.ref == 'refs/heads/x')`; a condition without a status function is wrapped the same way here.
- Contexts: `github`, `inputs`, `matrix`, `needs`, `strategy`, `vars` and `job` come from the job's `contextData` (`{t:2, d:[{k,v}]}` dictionaries, `{t:1, a:[...]}` arrays; a null context such as `matrix` outside a matrix job is null). `env` is workflow env, then job env, then the step's own env (a step's env is visible to its own script); `steps.<id>.outcome`, `.conclusion` and `.outputs` come from earlier steps (`success`/`failure`/`skipped`; the conclusion is `success` for a failed step with `continue-on-error`), keyed by `contextName` (the workflow's `id:`, else `__run`, `__run_2`, ...); `job.status` is `success` or `failure`; `runner` has `os` (`Linux`), `arch` (`X64`), `name`, `temp` and `tool_cache`.
- `hashFiles(patterns...)` (verified against a GitHub-hosted runner on the same commit: one file, `**/package.json` matching two files, an exclusion, and no match all gave GitHub's values, and `actions/cache@v4` saved with a key built from it): the SHA-256 of the files' SHA-256 digests, as GitHub computes it, or "" when nothing matches. Patterns are globs relative to the workspace (absolute ones count only inside it), one per argument or line; `!` excludes, the last matching pattern decides, and a pattern that matches a directory matches everything in it. The runner lists the files with Dagger's `Directory.glob` on the job's current container (each pattern as given and with `/**`) and hashes them with one `sha256sum` exec in that container, which does not change it; the image needs `sha256sum`, `xargs` and `tr` (coreutils or busybox). Files are taken in path order; GitHub walks directories, so with several matches the order, and the hash, could differ. `hashFiles` in workflow- or job-level `env` is not supported (the container does not exist yet).
- Not supported yet, failing the step with a message instead of evaluating wrongly: the `*` object filter.
- Semantics follow GitHub: case-insensitive property names and string comparison, loose coercion (strings, booleans and null compare as numbers; NaN equals nothing), `&&`/`||` return an operand, functions `contains`, `startsWith`, `endsWith`, `format`, `join`, `toJSON`, `fromJSON`, `success`, `always`, `failure`, `cancelled`. An expression that cannot be parsed or evaluated fails that step, with the reason and the expression in its log; a failed condition fails the step and the job.

File commands and default environment (verified live; `src/commands.zig`):
- Each step gets `$GITHUB_OUTPUT`, `$GITHUB_ENV`, `$GITHUB_PATH` and `$GITHUB_STEP_SUMMARY` (files under `/github/file_commands/<kind>_<step number>`) and `$GITHUB_ACTION` (the step's `contextName`). The step's script creates them first and touches them again afterwards, and the step's query reads them back with `file(path:) { contents }` in the same request, so they also work for steps served from Dagger's cache.
- `GITHUB_OUTPUT` and `GITHUB_ENV` hold `name=value` lines or `name<<DELIMITER` multi-line values; `GITHUB_PATH` holds one directory per line. A malformed file fails the step that wrote it, with the offending line in its log (`Unable to process the GITHUB_OUTPUT file command: ...`). `GITHUB_STEP_SUMMARY` is created but its content is not used.
- Outputs become `steps.<id>.outputs.<name>`. `GITHUB_ENV` entries are added to the `env` context and applied to the container before the next step with `withEnvVariable`; `GITHUB_PATH` entries are prepended to `PATH` the same way (`expand: true`). Names starting with `GITHUB_` or `RUNNER_`, and `NODE_OPTIONS` and `CI`, are refused with a warning.
- Every step sees `CI=true`, `GITHUB_ACTIONS=true`, `GITHUB_WORKSPACE`, `RUNNER_OS`, `RUNNER_ARCH`, `RUNNER_NAME`, `RUNNER_TEMP`, `RUNNER_TOOL_CACHE` and these from the `github` context when present: `GITHUB_REPOSITORY`, `_REPOSITORY_OWNER`, `_SHA`, `_REF`, `_REF_NAME`, `_REF_TYPE`, `_EVENT_NAME`, `_ACTOR`, `_TRIGGERING_ACTOR`, `_RUN_ID`, `_RUN_NUMBER`, `_RUN_ATTEMPT`, `_JOB`, `_WORKFLOW`, `_BASE_REF`, `_HEAD_REF`, `_SERVER_URL`, `_API_URL`, `_GRAPHQL_URL`. They are set once on the base container. `GITHUB_TOKEN` is not set; `github.token` works in expressions.
- Workflow commands in a step's output (verified with `runner --exec-job testdata/job-workflow-commands.json`): `::add-mask::<value>` masks the value, and each of its lines, in everything logged afterwards by every sink (stdout, the GitHub log upload, Postgres), for the rest of the job; the command line itself is not logged. `::group::`/`::endgroup::` and `::error::`, `::warning::`, `::notice::` become GitHub's log markup (`##[group]`, `##[error]`, ...; annotations are not created). `::debug::` lines are shown only when `ACTIONS_STEP_DEBUG` is `true` (a secret or a repository variable). `::stop-commands::<token>` turns commands into plain text until `::<token>::`. The deprecated `::set-output` and `::save-state` still work (`GITHUB_OUTPUT` wins over `set-output`); `::set-env` and `::add-path` log GitHub's "command is disabled" error. Values use GitHub's escapes (`%25`, `%0D`, `%0A`, and `%3A`, `%2C` in properties). Only step output is read this way; the runner's own lines never are.
- The step summary is uploaded with the logs (see §3, "Step summaries").

Secrets (verified live on a repository with Actions secrets):
- Repository secrets are delivered in the job message as entries of `variables`, keyed by the secret's own name and flagged `"isSecret": true` (for example `TIGER_HOST`), next to GitHub's own `github_token` and `system.github.token`. There is no `contextData.secrets`. Secrets referenced by the workflow, and the job token, are always masked: every secret value is on the sink's redaction list as soon as the job is acquired, so a step that prints one shows `***`, in the console and in the logs uploaded to GitHub.
- The `secrets` context is built from those variables (without `system.*`), with `github_token` exposed as `GITHUB_TOKEN`; `secrets.NOPE` for an unknown name is an empty string, as in GitHub.
- Workflow- and job-level `env` is part of every step's environment (it is set on the base container, so `$TIGER_HOST` works in a script, not only `${{ env.TIGER_HOST }}`). Any env value that contains a secret, at job or step level, is registered as a Dagger secret in the session (`setSecret`, then `withSecretVariable`) instead of being written into a command line. That keeps it out of the exec arguments, which Dagger keeps in its cache metadata and prints in its progress log, and Dagger scrubs it from its own logs.
- Job-level secret env stays on the container for every step. A step's secret env is attached as `ZIG_SECRET_<i>` (`withSecretVariable`), the step's script gives it its real name (`env -u ZIG_SECRET_0 'NAME='"$ZIG_SECRET_0" ...`, so only the variable's name is in the command), and the same query removes it after the exec (`withoutSecretVariable`), so the next step does not see it, as on GitHub. The aliases exist because Dagger silently drops variables whose names are not identifiers (`withEnvVariable` and `withSecretVariable` with `INPUT_GITHUB-TOKEN` set nothing, checked on v0.21.10), and action inputs are passed as such names. Before this, a step's secret env was left on the container and visible to every later step, and a hyphenated name never arrived (`testdata/job-secrets.json` shows both).
- A secret written directly into a script (`run: echo ${{ secrets.X }}`) is still part of that script's text, and therefore of its exec arguments; pass secrets through `env:` as GitHub recommends. Secrets shorter than 3 characters are not routed through Dagger secrets (they would match unrelated text).

Postgres TLS (verified against Tiger Data):
- Tiger negotiates TLS 1.3 (`TLS_AES_256_GCM_SHA384`, X25519, an ECDSA P-256 certificate chaining to a public CA) and verifies against the system CAs and the host name with `sslmode=require`.
- Tiger sends a TLS `CertificateRequest` during the handshake, as any Postgres server with a CA file configured does. Zig 0.17's `std.crypto.tls.Client` rejects it (`TlsUnexpectedMessage`), so the runner uses `src/vendor/tls_client.zig`: std's client with one marked change that answers it with an empty `Certificate` message (RFC 8446 §4.4.2), TLS 1.3 only. Reproduced locally with `ssl_ca_file` set on a Postgres container. Drop the copy once std handles it.

Executor design (verified live against Dagger v0.21.10, offline with `runner --exec-job testdata/job-mixed.json` and end to end through GitHub):
- One long-lived Dagger session hosts the whole job. The runner spawns `dagger run --progress=logs sh -c '<print $DAGGER_SESSION_PORT and $DAGGER_SESSION_TOKEN, then wait for stdin to close>'`, reads that first line from the child's stdout, and sends GraphQL over HTTP (`POST http://127.0.0.1:<port>/query`, `Authorization: Basic base64("<token>:")`), as the Dagger SDKs do. Closing the child's stdin ends the session. `dagger session` is documented as internal-only and is not used.
- Why not one `dagger query` per step: container ids only live as long as their session (`loadContainerFromID` in a new session fails with "missing shared result"; Directory ids from `git()` do survive, Secret ids do not). A single query for the whole job would be stateless between steps and could not react to earlier results.
- Setup query: `container { from(address: <image>) { withWorkdir(path: "/github/workspace") { id } } }`. Each step is then one query: `loadContainerFromID(id: <previous>) { [withDirectory(path, source)] withExec(args: ["sh","-c",<script>], expect: ANY) { id exitCode stdout stderr } }`; the returned `id` is used by the next step. Scripts are JSON-escaped into the document, so commas and quotes are safe. `expect: ANY` makes a failing step return normally, so `exitCode` is the step's real exit code, and `stdout`/`stderr` are separate fields even for steps served from Dagger's cache.
- The runner, not the container, decides what runs: `if:` is evaluated per step with the expression engine below, a skipped step sends no query, and `continue-on-error` decides whether a failed step marks the job failed. This is the foundation for expressions and step outputs.
- Live output: `dagger run`'s progress log on stderr is read by a concurrent reader task. Each script prints `::zig-step::begin N` and `::zig-step::end N` around the step so lines can be attributed to the step. The marker is a fixed string, not a per-run nonce (a random value would change the exec cache key); a workflow author can forge markers in their own output but already controls everything the job reports. A span header is one line, starts with a block glyph and contains the step's `begin N` text; lines are attributed to the step named in the latest header (Dagger may repeat a header when it switches spans). Lines outside a step are Dagger progress noise, kept only as a tail for engine errors. A mutex serialises sink access between the reader and the main task.
- Cached steps print no log lines. After each query the runner waits up to 60 ms for the step's `end` marker; if none arrived and no live line was seen, the step's `stdout` then `stderr` are replayed. Replayed lines are remembered so a late live copy is dropped instead of logged twice.
- `run:` uses `bash --noprofile --norc -e -o pipefail -c` by default and `sh -e -c` for `shell: sh`. Step `env` is applied with `env K=V`, and `working-directory` with `cd`. Filesystem state carries across steps because each step starts from the previous step's container.
- Measured: a 8-step job takes about 2.8 s the first time and 1.5 s when every step is cached (the single-query design was 2.2 s and 0.7 s; the difference is the per-step round trip and the 60 ms cache wait).
- Limitations: live stdout and stderr are merged (a replayed step has them separate); `seq` across steps reflects arrival order; `container:` jobs are unsupported and fail the job before any step runs, with "container: jobs are not supported yet" in its log.
- `services:` (verified live next to `ubuntu-latest`: the same step list, "Initialize containers" and "Stop containers" included; Postgres 17 and Redis 7, TimescaleDB with node-postgres; also on a Raspberry Pi, arm64). They arrive as the message's `jobServiceContainers`: a mapping of name to `image`, `env`, `ports` (a sequence), `options` (one string), `credentials` and `volumes`, any of them possibly an expression. In "Initialize containers" each image's configuration is read first (logged as "Pulling <image>" and "Digest: sha256:..."), then each service runs as `container.from(image)` with its env (plus `GITHUB_ACTIONS` and `CI`), its container ports exposed, and the image's entrypoint and command started by busybox's `sh`, which first prints `::zig-step::service <n>` so the log stream's records for that span are the service's own output (kept, up to 10 000 lines, and printed in "Stop containers" as GitHub prints `docker logs`), then `asService(args)` and `start`, which waits until the ports accept connections: that is when Postgres is ready (its first-run setup listens on no TCP port), so `--health-*` options are accepted and not run; other options and volumes are ignored with a warning. A started service runs until the job's session ends, so its data carries from step to step. The services are bound to the job's container under their names (`postgres:5432` resolves, which GitHub's runner does not offer to a job on the host), and, as on GitHub, each published port is reachable as `localhost:<host port>` in every step: a busybox `tcpsvd` forwards it (IPv4 and IPv6) to the service for the step's duration. A bare container port keeps its number on localhost (GitHub picks a random one); `job.services.<name>.ports['<container port>']` gives the host port, `job.services.<name>.id` an id. Docker actions reach services by name, and each service reaches the services listed before it by name (verified live: pgbouncer reaching `postgres:5432`; one listed after it cannot be bound, since a binding needs the service started). A job with services opts out of the step cache: a step replayed from cache would leave the service without the changes it made. "Stop containers" prints each service's logs and stops it, after the post scripts. Not yet: a layer-by-layer pull progress (a large image shows "Pulling" until it is up).

`uses: actions/checkout` is replaced by a built-in checkout (verified live):
- The step arrives as `reference: {type:"repository", name:"actions/checkout", ref:"v4", repositoryType:"GitHub"}`; `inputs` is absent when the workflow has no `with:`. The pinned version is ignored.
- The runner resolves each checkout in the same session just before its step: `git(url:"<server_url>/<repo>.git", keepGitDir:true) { commit(id:<sha>) | ref(name:<ref>) | head { tree(depth:<n>[, includeTags:true]) { id } } }`, which returns a Directory id. The step's query then mounts it with `withDirectory(path, source: id)` before the step's exec. The tree is content-addressed, so the same commit gives the same workspace and later steps keep hitting Dagger's cache. The workspace contains a real `.git`.
- Defaults: `repository` = the workflow's repo, `ref` = the triggering sha (`github.sha`; another repository defaults to its HEAD), `fetch-depth` = 1 (0 = full history). `depth` is always sent: Dagger's default is 1, so leaving it out gives a one-commit shallow clone; `depth: 0` gives the full, unshallow history (checked: 188 commits on the blog, `--is-shallow-repository` false). `fetch-tags: true` sets `includeTags`. `ref` may be a sha, a branch, a tag or `refs/...` (for example `refs/pull/N/merge`); `path` must be relative and stay inside the workspace.
- Refs, as actions/checkout leaves them (Dagger's tree has a detached HEAD and no refs at all): `refs/heads/B` gets `refs/remotes/origin/B` and a local branch `B` tracking it, checked out; `refs/pull/N/merge` (or `/head`) gets `refs/remotes/pull/N/merge`, detached; `refs/tags/T` gets the tag; a bare `ref:` name gets `refs/remotes/origin/<name>`. The ref is `with: ref:` or, for the workflow's own repository, `github.ref`; a sha gets none. Without a ref at HEAD a later `git fetch` cannot tell the server what the clone has and downloads the whole tree again, which is what made the dagger CLI warn "failed to fetch branch ... object not found" on pull requests: it fetches the PR head with git and reads it with go-git, which does not see the new pack file such a large fetch produces (verified: the fetch went from 168 objects to 1, and the warning disappeared from the blog's test-build on a pull request). The git commands run in the checkout step, ignore failures, and need `git` (the default image has it).
- Submodules: Dagger's git always initializes and checks out submodules, recursively, whatever the depth (checked on the blog: `themes/PaperMod` and `public`). So `submodules: true`, `recursive` and `false` are all accepted, and the workspace always has them; `true` behaves like `recursive`. A private submodule would make the whole checkout fail, even with `submodules: false`.
- Accepted and ignored: `persist-credentials`, `token`, `clean`, `show-progress`, `set-safe-directory`, `filter`, `sparse-checkout-cone-mode`, `ssh-strict`, `ssh-user`. Accepted only when off: `lfs`, `sparse-checkout`, `ssh-key`, `ssh-known-hosts`. Any other input, or `lfs: true` and the like, fails the step with "unsupported ...".
- Credentials: checkouts authenticate with the job's `GITHUB_TOKEN` (as actions/checkout does with `github.token`), passed to `git(...)` as a Dagger secret (`httpAuthUsername: "x-access-token"`, `httpAuthToken`), never in the URL; so the job's own repository can be private (verified live on a private repository with `RUNNER_ENGINE=direct`). Actions are fetched with it only from the job's own repository (the only one the token reads); other actions are fetched anonymously. A fetch that still needs credentials fails that step with git's message, and the rest of the job continues. With `RUNNER_ENGINE=cli`, the dagger CLI also answers the engine's git credential requests from the host's own git setup, which is how private checkouts happened to work before; the direct client gives the engine no host credentials. `GIT_TERMINAL_PROMPT=0` is set so a fetch can never block on a prompt.
- Differences from the real action: no credentials are left in `.git/config`; a failed fetch fails only that step, with the reason in its log; the default base image gets `git` (see §6 Dagger execution), so `git log` and friends work in the checked-out workspace.
- A skipped checkout (`if:` false) still mounts the tree; only `success()`/`always()`/`failure()`/`cancelled()` are evaluated, as for other steps.

Other `uses:` actions are read from their `action.yml` (verified live with `dagger/dagger-for-github@v8.4.1` on Lementknight/blog):
- The step arrives as `reference: {type:"repository", name:"owner/repo", ref, repositoryType:"GitHub"}`, plus `path` for an action in a subdirectory (`owner/repo/dir@ref`); `inputs` holds the `with:` values as template tokens.
- When the step runs, the runner fetches the action's repository with Dagger's git support (`git(url) { ref(name) | commit(id) { tree(depth:1) { id entries(path) } } }`, cached by the engine), reads `action.yml` (or `action.yaml`) with a second query, and parses it with `src/yaml.zig`, a YAML subset parser (see its header; it was checked against 31 real `action.yml` files and Ruby's Psych). Invalid metadata, or a missing file, fails the step with the reason.
- Composite actions (`runs.using: composite`) run as part of their `uses:` step: one GitHub step, one log, each of the action's steps a separate exec in the job's container. The repository is mounted at `/github/_actions/<owner>/<repo>/<ref>` before the first of them; `github.action_path` and `GITHUB_ACTION_PATH` point at the action's directory, with `GITHUB_ACTION_REPOSITORY` and `GITHUB_ACTION_REF`.
- `${{ }}` in `action.yml` values is evaluated by the runner (the job message only pre-processes the workflow's own expressions). Inputs are the step's `with:` values, else the declared defaults (which may be expressions such as `${{ github.token }}`), both evaluated in the `uses:` step's scope. Undeclared inputs are passed on with GitHub's warning, "Unexpected input(s) ..., valid inputs are [...]".
- The action's steps see its own `inputs` and `steps` contexts and a fresh `success()`/`failure()` state; the `uses:` step's `env` is inherited and each step's `env` added to it. `GITHUB_ENV` and `GITHUB_PATH` changes outlive the action, as on GitHub. A run step must name its `shell` (bash or sh). After the steps, the action's `outputs` are evaluated against its `steps` and become `steps.<id>.outputs` of the `uses:` step.
- The log shows each step as GitHub does: `##[group]Run <first line of the evaluated script>`, the script, `##[endgroup]`, then its output.
- Local actions (`uses: ./dir`, arriving as `repositoryType: "self"` with `path`; verified live with a composite, a JavaScript and a Dockerfile action in the test repository, each feeding the next): read from the workspace when the step runs, from the job's container as earlier steps left it, so the repository must be checked out first; when the directory or its `action.yml` is missing the step fails with GitHub's message, "Can't find 'action.yml' or 'action.yaml' under '<dir>'. Did you forget to run actions/checkout before running your local action?". Nothing is mounted (the files are already there), `GITHUB_ACTION_PATH` is the directory in the workspace, and `github.action_repository` / `action_ref` are empty, as on GitHub. GitHub runs no `pre` for local actions, and neither does the runner; `post` runs as for other actions. A path with `..` is refused.
- `uses:` steps inside a composite action (verified live: a local composite action nesting `actions/cache@v4` keyed with `hashFiles`, a local composite action, `docker://alpine:3.22` and `actions/checkout` with `path:`; the nested output reached the outer action's outputs and the job, and the cache's `post` saved it at the end of the job) run as part of the `uses:` step like the job's own steps: `actions/checkout` is the built-in checkout, `docker://` runs the image, `./dir` is a local action, anything else a remote one, which may be composite again. Their `with:` is evaluated in the composite action's scope (its `inputs`, `steps`, env), they inherit the step's env, and their outputs and outcome go to the composite action's `steps` context. Nested actions are loaded when their step runs; their `pre` scripts do not run, their `post` scripts run at the end of the job with the others. As on GitHub, composite actions nest at most 9 levels deep ("<action>: composite actions can be nested at most 9 levels deep").

Engine client (`RUNNER_ENGINE=direct`, the default; `src/engine.zig`, `src/hpack.zig`). The runner holds each job's Dagger session itself instead of running a `dagger run` child (about 65 MB of Go per job). The protocol is Dagger v0.21.10's own client's (engine/client/client.go), all over HTTP/1.1, which the engine serves:
- Connections: each is `buildctl dial-stdio` in the engine container, started through the Docker API (create an exec, start it with the connection upgraded to a raw stream, then read Docker's stdout/stderr framing), as the CLI does with `docker exec -i`. A stopped engine container is started (`POST /containers/<name>/start`); a missing one is created by running `dagger core version` once.
- Every request carries `X-Dagger-Client-Metadata` (base64 JSON: fresh client, session and token ids, `client_version` v0.21.10) and a W3C `traceparent` with a trace per session: without a trace the engine stores the session's log records with an empty trace id and drops them when exporting (found live: "hex encoded trace-id must have length equals to 32").
- `GET /sessionAttachables` turns one connection into the session's callback channel (`101`, then a one-byte ack): the engine speaks gRPC over HTTP/2 to the client there. A minimal HTTP/2 server (settings and ping acks, window updates, an HPACK decoder checked against RFC 7541's examples) answers: `grpc.health.v1.Health/Check` SERVING (the engine checks every 5 s and drops a client after two failures); `moby.filesync.v1.FileSync/DiffCopy` asking for an absolute path with `/zig-runner/...` and every stat or file read with NOT_FOUND (the engine detects a workspace on the client's host before the first query; this way it finds none and reads nothing from the runner's machine); `moby.filesync.v1.Auth/Credentials` with no credentials (anonymous pulls); anything else UNIMPLEMENTED (no host directories, sockets, secrets or terminals).
- Then `POST /init`, `GET /v1/logs` (server-sent events of OTLP log records in JSON: exec output in pieces, with the exec's span id and `stdio.stream`), `POST /query` per GraphQL query on a kept-alive connection, and `POST /shutdown` at the end of the job, after which the log stream ends, so every live line has arrived before reused steps are told apart.
- Live output is routed by span (`SpanDemux` in `src/dagger.zig`): pieces are joined into lines per span, and a span belongs to the step whose `begin` marker it prints. Records marked `dagger.io/logs.verbose` (the engine repeating output it already logged, such as a `stdout` field's value) are skipped, as Dagger's own progress output does.
- Each job still has its own session: concurrent queries in one shared session that differ only in volatile variables are merged by the engine, one value winning (checked: four concurrent queries all saw the first's value), which would leak run ids and event payloads between jobs.
- With `RUNNER_ENGINE_HOST`, connections go straight to the engine's listener instead (a name is resolved for `tcp://`). The engine image takes listeners as arguments; for example, an engine for runners on the same machine, on the loopback only (a TCP listener is unauthenticated, so it must not be reachable by anything that should not run containers as root):

      docker run -d --name dagger-engine-runners --privileged \
        -p 127.0.0.1:1234:1234 -v dagger-engine-runners:/var/lib/dagger \
        registry.dagger.io/engine:v0.21.10 \
        --addr unix:///run/dagger/engine.sock --addr tcp://0.0.0.0:1234
      RUNNER_ENGINE_HOST=tcp://127.0.0.1:1234 runner --runners 3

  On Linux, sharing `/run/dagger` with the runner (a volume or bind mount) and `RUNNER_ENGINE_HOST=unix:///run/dagger/engine.sock` avoids a network listener altogether. Verified live with such an engine (a separate container, removed afterwards): the live engine test over `tcp://`, and `--runners 3` on a three-job matrix (private checkout, live output, `actions/github-script`), all succeeded with no `dagger` and no `dial-stdio` process anywhere; the runner process was about 31 MB idle and about 40 MB with the three jobs running (Debug build), so a running job costs a few MB outside the engine.
- Verified live: the same job file gave the same step results and output through both engines; three concurrent jobs of a matrix (private checkout, a 15 s step streamed live, `actions/github-script` on Bun) succeeded with `--runners 3` and no `dagger` process. Cost: the three `dagger run` children (~195 MB) are gone; each session's three connections are three `buildctl dial-stdio` processes inside the engine container (~11 MB each, ~34 MB per job). A direct engine socket (`unix://` or `tcp://`) would remove those too.

Dagger inside a job (verified live: Lementknight/blog's `test-hugo-build.yml` workflow, `dagger/dagger-for-github` with `args: ci --skip-links`, passed all six checks on the runner):
- With `RUNNER_DAGGER_NESTING` on (the default), every step exec is sent with `experimentalPrivilegedNesting: true` (in the v0.21.10 schema: "Provides Dagger access to the executed command"). A `dagger` CLI inside the step then gets a session on the job's own engine, with no Docker socket and no second engine; the setup and provisioning execs never get it.
- The nested pipeline shares the engine's cache: re-running the blog job on the same commit took 15 s instead of 40 s, with `Blog.ci CACHED`. The option does not change caching of the step's own exec (checked with a `date` probe, cached in both modes); a re-run still re-executes steps because `GITHUB_RUN_ATTEMPT` is part of every step's environment, as on GitHub.
- Dagger's Dang language was considered for this and does not apply: it is an SDK for writing modules (engine v1.0 betas), not a way to reach an engine from a container, and the runner already speaks the GraphQL API that Dang compiles to.

Package caches (verified with two `--exec-job` runs in separate Dagger sessions: the second read what the first wrote under `/root/.npm` and `/root/.cache/zig`, and found nothing with `RUNNER_PACKAGE_CACHES=false`):
- Every job's base container mounts one Dagger cache volume (`withMountedCache`) at each of these cache directories, so package managers reuse downloads and build caches across jobs with no workflow changes: npm `/root/.npm`, pnpm `/root/.local/share/pnpm/store`, Yarn `/usr/local/share/.cache/yarn`, pip `/root/.cache/pip`, uv `/root/.cache/uv`, Go `/root/go/pkg/mod` and `/root/.cache/go-build`, Cargo `/root/.cargo/registry` and `/root/.cargo/git`, Bun `/root/.bun/install/cache`, Zig `/root/.cache/zig`, Gradle `/root/.gradle/caches`, Maven `/root/.m2/repository`. The paths are root's, the default image's user; a custom image with another user or home does not benefit.
- Volumes are keyed `zig-runner/<owner>/<repo>/<scope>/<tool>`. The scope is `repo`, or `fork-pr` for a pull request from a fork (`github.event.pull_request.head.repo.full_name` differs from the repository), so untrusted code cannot plant content in the caches the repository's own branches use; GitHub scopes its cache by branch for the same reason.
- The volumes live in the Dagger engine, so they are shared by all runners using the same engine and survive runner restarts; `dagger core engine local-cache prune` (or pruning the engine) clears them. Concurrent jobs share them (`SHARED`), which these tools handle with their own locking.

Step caching (verified with `runner --exec-job testdata/job-step-cache.json` run several times with different `run_id`s, in separate Dagger sessions):
- Dagger reuses an exec whose inputs (parent container, command, environment) are unchanged. Without help that never happens across runs, because every step gets values that differ per run. So the run-specific variables (`GITHUB_RUN_ID`, `GITHUB_RUN_NUMBER`, `GITHUB_RUN_ATTEMPT`, `GITHUB_ACTOR`, `GITHUB_TRIGGERING_ACTOR`) are set with `withVolatileVariable`: steps see them, but they are not part of the cache key. The event payload, which also differs per run, travels in the volatile `ZIG_RUNNER_EVENT` (hidden from the step with `env -u`) and each step writes it to `GITHUB_EVENT_PATH` before it runs; a payload over 100 KiB (too large for one environment string) is written into the container instead, which turns reuse off for that job. Values that describe the inputs (`GITHUB_SHA`, `GITHUB_REF`, `GITHUB_EVENT_NAME`, ...) stay in the key.
- A reused step is not run: its recorded output is replayed and its file commands (outputs, env, PATH) apply as recorded. Its log ends with "Reused from Dagger's cache: this step's inputs were unchanged since an earlier run, so the output above was recorded then." That is decided once the session has ended and the log stream is fully read: the live stream can lag behind a step that did run, and its lines then arrive after the replay (they are dropped as duplicates).
- Steps that must not be skipped always run: those that use secrets (secret env at step or job level, a secret in the script text, and JavaScript actions, which always get the job token), every step of a job that can request OIDC tokens (see OIDC below), and those whose script names a run-specific variable or `GITHUB_EVENT_PATH` (so they never replay another run's values). They get a line `: 'zig-runner runs this step every time: <reason> (run <run_id>.<attempt>)'`, which makes their cache key differ per run; every step after them then runs too, because each step starts from the previous step's container.
- Not detected: a script file in the repository that reads run-specific values. Workflows that depend on that, or that have side effects without secrets, opt out with `ZIG_RUNNER_STEP_CACHE: false` in their `env`; operators with `RUNNER_STEP_CACHE=false`. With step caching off, run-specific values are ordinary variables and the event file is written into the container, as before.

JavaScript actions (`runs.using: node12` … `node24`) run on Bun by default (verified live: `actions/github-script@v9` on Lementknight/blog made an authenticated API call, read the push event payload and returned a result the next step used; offline with `runner --exec-job testdata/job-js.json` on both runtimes):
- The runtime binary is taken from its image once per job (`oven/bun:1.4.3`, `/usr/local/bin/bun`, the version the repository's Docker images pin; or `node:24-bookworm-slim` with `RUNNER_JS_RUNTIME=node`) and added with `withFile` at `/github/_runtime/node/node`. Bun named `node` behaves as Node (`process.version` reports v26.3.0 for Bun 1.4.3, and a `node` child process works), except that it does not answer `node --version`; so `/github/_runtime/bin/node` is a small shim that answers `-v`/`--version` with `-p process.version` and runs the binary otherwise. That directory is put first on `PATH` for the action only. It also has `npx`, for actions that run a package's binary (`FirebaseExtended/action-hosting-deploy` runs `npx firebase-tools@<version> ...`): with Bun it is `bun x` (the same binary, also named `bun`; its progress goes to stderr, so a tool's stdout, often JSON the action parses, stays clean), and with Node it is npm's own `npx-cli.js`, with `npm` too, from the same image. Bun has no `npm` here.
- The action's repository is mounted as for composite actions, and `main` runs as `exec /github/_runtime/node/node <action path>/<main>`, started by bash: dash drops variables whose names are not identifiers when it starts a program, which would lose `INPUT_GITHUB-TOKEN` (found live).
- Inputs (the step's `with:`, else the declared defaults, evaluated as for composite actions) are passed as `INPUT_<NAME>` (upper case, spaces as `_`, hyphens kept, as `@actions/core` reads them). Values that contain a secret, such as the `${{ github.token }}` default, go through Dagger secrets under aliases (see Secrets).
- `github.token` is added to the `github` context from the job's `github_token` variable (contextData has none), as GitHub's runner does; actions default `github-token` to it.
- The event payload (`github.event`, pretty-printed JSON as on GitHub) is written to `/github/workflow/event.json` for every job, and `GITHUB_EVENT_PATH` points at it.
- Runtime services: `ACTIONS_RUNTIME_URL` (`PipelinesServiceUrl` of the `SystemVssConnection` endpoint), `ACTIONS_RUNTIME_TOKEN` (the job token, as a secret), `ACTIONS_CACHE_URL`, `ACTIONS_RESULTS_URL` and `ACTIONS_CACHE_SERVICE_V2=True` when the job's `actions_uses_cache_service_v2` variable is true. `GITHUB_STATE` is a file command like the others (see `pre` and `post` below).
- Outputs written to `GITHUB_OUTPUT` become `steps.<id>.outputs`. The log shows `##[group]Run <action>`, the `with:` inputs, `##[endgroup]`, then the action's output.
- `pre` and `post` (verified live with `gacts/run-and-post-run@v1` on both runtimes: its post ran after the job's other steps and saw what its main wrote): every `uses:` action is fetched at the start of the job, as GitHub does in "Set up job", and a JavaScript action's `pre` runs then, before any step, when `pre-if` (default `always()`) holds. Its `post` runs after all steps, in reverse order of the steps, for each action whose main ran, when `post-if` (default `always()`) holds. Each phase is logged in the action's own step log under `##[group]Pre <action>` / `##[group]Post <action>` (the runner cannot add steps to GitHub's list), gets the step's inputs, and gets the state saved so far (`GITHUB_STATE`, `::save-state`) as `STATE_<name>`. A failing `pre` or `post` fails the job; a failing `pre` also makes later `success()` steps skip.
- Workflow commands printed by the action are handled as for any step (see above).

OIDC tokens (verified live on Lementknight/blog: a `curl` in a `run:` step and `core.getIDToken()` in `actions/github-script@v8` both got tokens from GitHub with the requested `aud` and `sub: repo:Lementknight/blog:ref:refs/heads/...`; a job without the permission saw no URL):
- GitHub puts `GenerateIdTokenUrl` in the `SystemVssConnection` endpoint data only for jobs with `permissions: id-token: write`. Then every step, `run:` steps and actions alike, gets `ACTIONS_ID_TOKEN_REQUEST_URL` (that URL) and `ACTIONS_ID_TOKEN_REQUEST_TOKEN` (the job token, registered once per job as a Dagger secret and passed under an alias), as GitHub's runner does, so cloud login actions (`aws-actions/configure-aws-credentials`, `google-github-actions/auth`, `azure/login`) and npm's trusted publishing work.
- Such steps always run with step caching on ("it can request OIDC tokens (id-token: write)"): a step may deploy or publish with a token and no secret, and must not be skipped as reused.

Docker actions (verified live on Lementknight/blog: `uses: docker://alpine:3.22` changed the workspace and `GITHUB_ENV` for the next step; `actions/hello-world-docker-action@main`, built from its Dockerfile and running as a non-root user, set an output the next step read; `docker://hadolint/hadolint` with `entrypoint: /bin/hadolint`, an image without a shell, ran):
- Two kinds: `runs.using: docker` in an `action.yml`, whose `image` is a Dockerfile in the action's directory (built with Dagger's `dockerBuild`, the Dockerfile's directory as the context, as GitHub builds it) or `docker://<image>`; and a `uses: docker://<image>` step, which arrives with reference type `containerRegistry`. Images are pulled or built once per job; a pull or build failure fails the step with Dagger's message.
- The command is what `docker run` would run: the image's entrypoint and `runs.args` (each item evaluated with the action's `inputs` in scope, one argument each), or the image's command when there are no args; an `entrypoint` replaces the image's entrypoint and command. A `docker://` step takes `with: args` (split at whitespace, double quotes grouping, as GitHub hands the string to `docker run`) and `with: entrypoint`.
- The action runs in its own container, not the job's. Before it, the job's `/github/workspace` is copied in (the working directory), with `/github/home` (`HOME`, shared by the job's Docker actions), the file commands directory and the event file. After it, the workspace it leaves replaces the job's (`withoutDirectory` + `withDirectory`, so deletions carry over), and its file commands apply as for any step. These directories are owned by the image's `USER` when it has one.
- A static busybox (`busybox:1.37.0-musl`, mounted at `/github/_runtime/busybox`) starts the command: it prints the step's markers for live logs, creates the file commands and passes the environment, so images without a shell work.
- Environment, as GitHub gives container actions: the default variables, the job's env (workflow, job, `GITHUB_ENV`), the step's env, `INPUT_<NAME>`, the action's `runs.env` (evaluated with its inputs), `HOME=/github/home`, `GITHUB_ACTION_REPOSITORY`/`GITHUB_ACTION_REF`, the runtime services as for JavaScript actions, and OIDC variables with `id-token: write`. Secret values go through Dagger secrets under aliases. The job's `PATH` additions do not apply (the image has its own `PATH`). With step caching on they always run, since they always get the job token.
- `pre-entrypoint` and `post-entrypoint` run as JavaScript actions' `pre` and `post` do (same image and args, `pre-if`/`post-if`, state as `STATE_<name>`).

Job outputs (verified live: a job's `outputs:` read by a later job through `needs`, with a `${{ steps... }}` value, a literal and a `format(...)` combining them, and the "Complete job" lines next to the same job on `ubuntu-latest`): the message's `jobOutputs` is a template mapping like step inputs (`{type:2, map:[{Key:{lit}, Value:{lit|expr}}]}`; `v=${{ x }}` arrives as `format('v={0}', x)`). After every step and post step, each is evaluated against the final contexts and sent with completejob as `outputs: {name: {value, isSecret: false}}` (actions/runner's VariableValue); an output that would carry a secret is dropped with GitHub's `##[warning]Skip output 'x' since it may contain secret.`, and one that cannot be evaluated with the reason. "Complete job" logs `Evaluate and set job outputs` and a `Set output 'x'` per output, as GitHub's runner does. Until this, every output reached later jobs as an empty string.

Checkout log (verified live next to `ubuntu-latest`, a default checkout and one with `path:` and `fetch-depth: 0`): the built-in checkout's step log has actions/checkout's shape with what happened instead of git commands it did not run: `Syncing repository: owner/repo`; a `Fetching the repository` fold (the URL fetched with Dagger's git support, the commit or ref, the depth, whether tags were fetched); a `Checking out the ref` fold (where, and the branch or detached HEAD as `checkoutRefCommands` leaves it: "Switched to a new branch 'b'" / "branch 'b' set up to track 'origin/b'.", or "HEAD is detached at ..."); then the full commit from `git log -1 --format=%H`, the same command actions/checkout ends with (skipped when the image has no git). The branch lines and the commit matched the hosted log.

Log format (verified live: one workflow as a matrix on `ubuntu-latest` and on the runner, both job logs fetched from GitHub and compared line by line). The job's log reads as GitHub's runner writes it for a self-hosted runner:
- "Set up job" (step 0, in the job's log): `Current runner version: '<version the runner registers with>' (zig-runner)`, `Runner name: '...'`, `Runner group name: '...'` (`system.runnerGroupName`), `Machine name: '...'`; a `Runner Image` fold with the job's image and how the engine is reached (this runner's equivalent of GitHub's image information); a `GITHUB_TOKEN Permissions` fold, one `Name: level` line per entry of the job variable `system.github.token.permissions`, in its order; `Secret source: Actions` (`Dependabot` when `github.actor` is `dependabot[bot]`); `Prepare workflow directory`, `Prepare all required actions`, `Getting action download info`; one `Download action repository 'owner/repo@ref' (SHA:<commit>)` per remote action, fetched before any step (the commit comes from the same Dagger git query); and `Complete job name: <job>`. Only the actions the runner fetches are listed: not actions/checkout (built in), local actions, or `docker://` images.
- `run:` steps open with `##[group]Run <first line>`, the script, `shell: /usr/bin/bash -e {0}` (or the explicit shell's line), and `env:` with the workflow, job, `GITHUB_ENV` and step variables (secret values masked as `***`), then `##[endgroup]`; steps of composite actions the same way.
- Actions open with `##[group]Run <action>@<ref>`, `with:` listing every input that has a value (given or defaulted, in the action's order, then undeclared ones), `env:` as above, `##[endgroup]`. actions/checkout lists the given inputs, then its defaults (as in v4 to v6), as GitHub does.
- Shells run as GitHub runs them (verified live next to `ubuntu-latest`: same `shell:` lines, outcomes and error messages): the script is written to a file (`/tmp/zig-runner-step-<n>.sh`, RUNNER_TEMP being `/tmp`) that the shell runs, so `$0`, `BASH_SOURCE` and errors (`<file>: line 2: nosuchcmd: command not found`) name it. No `shell:` is `bash -e {0}` (no pipefail), or `sh -e {0}` when the image has no bash; `shell: bash` is `bash --noprofile --norc -e -o pipefail {0}`; `shell: sh` is `sh -e {0}`; a custom bash or sh command with `{0}` for the file (`bash -l {0}`, `/bin/bash --login -eo pipefail {0}`) runs as written. The log's `shell:` line shows the command with a bare `bash`/`sh` as `/usr/bin/...`. A failing script logs `##[error]Process completed with exit code N.`, as GitHub does. Only bash and sh run, the shells of GitHub's Ubuntu runners; other shells fail the step with why and a pointer to `shell: bash` (PowerShell is left out on purpose: it needs .NET; `cmd` is Windows-only).
- "job acquired: N steps" and "job succeeded" are the runner's own console lines, not part of the job's log on GitHub.
- Steps (verified live next to `ubuntu-latest`: the same list, names and order, each with its log): GitHub lists only the workflow's steps; like its runner, this one adds "Set up job" (the lines above), a "Pre <step name>" step for each action's `pre` script, a "Post <step name>" step for each `post` script (last step first; "Post Run <action>" for one nested in a composite action), and "Complete job" ("Cleaning up orphan processes"; the job's processes end with its Dagger session). They get ids of their own (UUIDs made by the runner), are numbered in that order, reported in completejob's `stepResults`, and each has its log uploaded under its id (the results service accepts step ids GitHub did not list). Pre and post steps start with their output (a post with "Post job cleanup."), without the main step's input fold. A step for an action in a subdirectory is named with it (`Run owner/repo/dir@ref`).
- Not yet like GitHub: GitHub leaves gaps in the numbers before post steps (only the order shows); the built-in checkout's output differs from the action's git commands and it has no post step.

Supported v0 subset: `run`, `env`, `working-directory`, `shell` (bash, sh, or a custom bash or sh command with `{0}`), `name`, `continue-on-error`, `timeout-minutes` (step and job), `if:`, `${{ }}` expressions (see above), `uses: actions/checkout`, composite, JavaScript and Docker `uses:` actions (remote or local), `uses: docker://`. Anything else fails the step with a clear "unsupported" message in the log. Expressions are described below.

## 7. Resource targets (to measure, not assumed)

- Idle runner: target under 20 MB RSS, near-zero CPU while long-polling.
- Binary: single static executable, no runtime dependencies.
- Target 20+ idle runners on a 4 GB machine; to be validated in M7.

Measured 2026-10-12 (Linux arm64 in Docker on macOS, `aarch64-linux-musl` static build, `--runners 20`, direct engine sessions over the engine's own TCP listener, a fresh engine):
- Binary: 12.8 MB ReleaseSafe (most of it debug info), 1.0 MB ReleaseSmall; static, no runtime dependencies.
- 20 idle runners in one process: 29 MB RSS in total (about 1.4 MB per runner), flat over minutes of long polls, 62 threads (each waiting runner: its task, its poll and a stop watcher).
- 10 concurrent jobs on those 20 runners (checkout, 15 s of streamed output, `actions/github-script` on Bun; all succeeded): the runner peaked at 44 MB (about 1.5 MB per running job) and returned to 31 MB; no other process ran outside the engine. The engine container, with the jobs' own containers, peaked at 376 MB on a cold cache.
- So 20+ runners on a 4 GB machine is met by a wide margin for the runner itself; what a machine can run at once is bounded by the jobs' containers in the engine.
- Found by measuring: every HTTP request used to build its own `std.http.Client`, which loads the CA bundle (and a 64 KB decompression window) into the memory a waiting runner only frees after its next job, so each idle runner grew by about 700 KB per poll (20 runners: 74 MB growing by about 14 MB a minute). One client for the process (`src/github/http.zig`) and per-request scratch memory fixed it.

## 8. Definition of done (demo slice)

1. `runner` starts with the env vars above and registers a JIT runner.
2. A push triggers a workflow with one `run: echo hello && sleep 2 && echo done` step.
3. Output appears in the frontend within ~2 s of being produced.
4. The job shows as succeeded in the GitHub UI.
5. Re-running the identical job is measurably faster through Dagger caching.

## 9. Conventions

- Zig: `zig fmt`, no allocations in the log hot path beyond the buffer, errors returned not panicked.
- Commits: small, one component each; update SPEC.md with any contract change.
- Secrets never logged; `GH_TOKEN` and `DATABASE_URL` redacted from all output.
