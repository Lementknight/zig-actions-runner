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
- Still unverified: `renewjob` (extends `lockedUntil` during long jobs), annotations, and the live console feed (`FeedStreamUrl`).
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

Executor design (verified live against Dagger v0.21.10, offline with `runner --exec-job testdata/job-mixed.json` and end to end through GitHub):
- The runner spawns `dagger --progress=logs query` and writes one GraphQL document to stdin: `container.from(image).withWorkdir("/github/workspace")` followed by one `withExec(args: ["sh","-c",<wrapper>])` per step, then a read of the report file (below). Scripts are JSON-escaped into the document, so commas and quotes are safe (`dagger core ... --args` splits on commas and is not used). Env `NO_COLOR=1` and `DAGGER_NO_NAG=1` are set. The query result goes to a private temp file (0600, deleted afterwards) so a large report cannot deadlock the stderr reader.
- Each wrapper always exits 0 and prints marker lines `::zig-step::begin N`, `::zig-step::end N <rc>` and `::zig-step::skip N` around the step's output. The marker is a fixed string, not a per-run nonce: the wrapper text is part of the exec cache key, so a random value would defeat caching. A workflow author can forge markers in their own job's output, but already controls everything that job reports.
- Dagger's log frontend prints each span's output in chunks and repeats the span header (a line starting with a block glyph, then the wrapper source, ending with a line holding just `'`) whenever it switches between spans. A step's trailing lines can therefore arrive after the next step has begun. Lines are attributed to the step named in the most recent span header (it contains that step's `begin N` text); `end` and `skip` markers clear it. Lines outside any step span are Dagger progress noise, kept only as a tail for engine errors.
- `if:` supports `success()`, `always()`, `failure()` and `cancelled()` via a flag file in the container; `continue-on-error` decides whether a failed step sets that flag. Any other condition fails the step with an "unsupported" message.
- `run:` uses `bash --noprofile --norc -e -o pipefail -c` by default and `sh -e -c` for `shell: sh`. Step `env` is applied with `env K=V`, and `working-directory` with `cd`. Filesystem state carries across steps because the steps form one container chain.
- Each wrapper also appends its marker lines and output to `/tmp/zig-out/report` inside the container. Because that file is part of the cached filesystem, a fully cached chain (which replays no logs at all) can still be read back: steps the live stream never reported are replayed from the report, through the same attribution code. Verified: an identical re-run returns identical output and results, 0.70 s instead of 2.16 s offline and 0.84 s instead of 3.9 s through GitHub.
- Output streams live (spacing of a script's own `sleep`s is preserved).
- Limitations: stdout and stderr are merged (stream is always `stdout`); `seq` across steps that finish within milliseconds reflects arrival order, while order within a step is exact; `container:` jobs, `uses:` actions and expressions are unsupported.

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
