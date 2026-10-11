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
| `DATABASE_URL` | no | Tiger Data connection string (TLS required). If unset, logs go to `StdoutSink` (§5.1) |
| `DAGGER_CMD` | no | Path to the `dagger` CLI, default `dagger` |
| `LOG_FLUSH_LINES` | no | Default `200` |
| `LOG_FLUSH_MS` | no | Default `500` |

Flags: `--token`, `--scope`, `--labels`, `--group-id`, `--name-prefix`, `--database-url`, `--dagger-cmd`, `--log-flush-lines`, `--log-flush-ms` (as `--flag value` or `--flag=value`), plus `--dry-run` (validate config, register nothing).

Exit codes: `0` job done (ephemeral exit), `1` config error, `2` GitHub auth/protocol error, `3` DB unavailable.

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
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
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
  number        INT NOT NULL,
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
  stream        TEXT NOT NULL,               -- stdout|stderr
  line          TEXT NOT NULL,
  PRIMARY KEY (job_id, seq, ts)
);

SELECT create_hypertable('job_logs', by_range('ts'));
ALTER TABLE job_logs SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'job_id',
  timescaledb.compress_orderby   = 'seq'
);
SELECT add_compression_policy('job_logs', INTERVAL '1 day');
SELECT add_retention_policy('job_logs', INTERVAL '30 days');

CREATE INDEX ON jobs (run_id);
CREATE INDEX ON runs (repo, created_at DESC);
```

Rules:
- Only the runner writes. The API is read-only.
- `seq` starts at 1 per job and has no gaps; the frontend relies on it for ordering and resume.
- Log lines are stored with ANSI codes intact; the frontend renders them.
- Migrations live in `db/migrations/NNN_name.sql`, forward-only.
- Exact TimescaleDB function syntax should be verified against the Tiger Data version in use before the first migration is merged.

## 5. Component interfaces

### 5.1 LogSink (Zig, `sink.zig`)

```
LogSink
  append(job_id, step_number, stream, line)   // buffered, non-blocking
  flush()                                      // forced, called at step/job end
  close()
```
Implementations: `PostgresSink` (batched insert/COPY) and `StdoutSink` (for local dev without a DB). The runner must work with `StdoutSink` alone.

### 5.2 Job state updates

The runner updates `runs`, `jobs` and `steps` at these transitions only: job start, step start, step end, job end. Each is a single upsert, idempotent on primary key.

### 5.3 Read API (`api/`)

| Endpoint | Returns |
|---|---|
| `GET /api/runs?repo=&limit=&before=` | Run list, newest first |
| `GET /api/runs/:id` | Run + its jobs + steps |
| `GET /api/jobs/:id/logs?after=<seq>&limit=` | Log lines with `seq > after`, ordered by `seq` |
| `GET /api/health` | `{ "ok": true }` |

Response shapes mirror the table columns (snake_case JSON). Log response:
```json
{ "lines": [{"seq": 1, "step": 2, "stream": "stdout", "ts": "...", "line": "..."}], "next_after": 1, "job_done": false }
```
The client polls with `next_after` until `job_done` is true.

### 5.4 Frontend pages

- `/` run list: status icon, workflow, repo, branch, sha, age, duration.
- `/runs/:id` job list/graph with per-job status; selecting a job shows its steps.
- Job view: collapsible steps, ANSI-colored log viewer, live tail while `in_progress`, timestamps toggle.
- Must work with fake data from the M0 seed script.

## 6. Dagger execution

- One Dagger pipeline per job; base image defaults to `ubuntu:24.04` unless the job specifies `container:`.
- Workspace: the checked-out repo mounted at `/github/workspace`.
- `run:` steps become `withExec(["sh","-e","-c", script])`, honoring `working-directory`, `env` and `shell: bash|sh`.
- Step stdout/stderr lines go to `LogSink` as they arrive, in order.
- Step failure stops the job unless `continue-on-error` is set.
- A single shared Dagger engine per machine serves all runners.

Supported v0 subset: `run`, `env`, `working-directory`, `name`, `continue-on-error`, `actions/checkout`. Anything else fails the step with a clear "unsupported" message in the log. `${{ }}` expressions are limited to `github.*`, `env.*` and `secrets.*` lookups.

## 7. Resource targets (to measure, not assumed)

- Idle runner: target under 20 MB RSS, near-zero CPU while long-polling.
- Binary: single static executable, no runtime dependencies.
- Target 20+ idle runners on a 4 GB machine; to be validated in M7.

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
