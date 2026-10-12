# Design: Lightweight Zig GitHub Actions Runner

Status: draft v0.1 · Audience: the whole team · Companion: [SPEC.md](SPEC.md)

## 1. Problem

The official GitHub Actions runner is a .NET listener plus a worker process per job. It is CPU- and memory-heavy, which makes running many runners on one self-hosted machine impractical. Its logs are also only viewable in GitHub's UI.

## 2. Goals

- A single static **Zig** binary that registers as a real self-hosted runner and claims jobs natively (`runs-on: self-hosted`).
- Low idle cost, so one machine can host many runners.
- Each job executes as a **Dagger** pipeline, so repeated work is cached.
- Logs and run state are stored in **Tiger Data** (Postgres + TimescaleDB).
- A **new frontend** that reproduces the GitHub Actions experience (run list, job graph, live logs) from that data.

## 3. Non-goals (for the hackathon)

- Full workflow-syntax parity. Support a documented subset (see SPEC §6).
- Windows/macOS job execution. Linux containers only.
- Multi-tenant auth for the frontend.
- Auto-update of the runner binary.

## 4. Architecture

```
GitHub ⇄ runner (Zig) ──► Dagger engine (executes steps in containers)
            │
            └─► Tiger Data: runs, jobs, steps, job_logs
                        │
                  API server (read layer)
                        │
                    Frontend
```

| Component | Responsibility | Language |
|---|---|---|
| `runner` | Register via JIT config, authenticate, long-poll broker, translate job to Dagger, report status, write state and logs to the DB | Zig |
| `dagger` driver | Run a job's steps as a Dagger pipeline, stream stdout/stderr back to the runner | Zig shelling out to the `dagger` CLI (v0 decision) |
| Tiger Data | System of record for logs and run state | SQL |
| `api` | Read-only HTTP/SSE API over the DB | TypeScript (proposed) |
| `web` | UI that mimics GitHub Actions | React (proposed) |

## 5. Key decisions

1. **Real runner protocol, not webhooks.** Jobs must be claimed natively so they appear in the Actions UI and resolve required checks. Cost: we depend on an undocumented protocol, reverse-engineered from `actions/runner` source.
2. **GitHub is still told about status.** The runner must at minimum complete the job on GitHub; otherwise it stays "in progress" forever. Full log upload to GitHub is optional and deferred, because our frontend is the log viewer.
3. **One job = one Dagger pipeline.** `run:` steps become `withExec`. `uses:` actions are limited to a supported subset.
4. **Tiger Data is the primary log store.** Logs are append-only and time-ordered, which suits hypertables, compression and retention policies.
5. **Runners write directly to the DB in batches.** No intermediate queue. Each runner buffers lines and flushes by size or interval.
6. **Live logs via polling first.** `GET /jobs/:id/logs?after=<seq>` every ~1s. Upgrade to SSE or LISTEN/NOTIFY only if needed.
7. **Ephemeral (JIT) runners, long-lived process.** One job per registration; the process re-registers for the next job. This simplifies state and cleanup. The goal is many runners per machine as cheap concurrent tasks in one process, like goroutines, each one a job (see §10).

## 6. Job lifecycle

1. Operator config provides a GitHub token, repo/org, labels and runner group.
2. Runner calls `generate-jitconfig`, decodes `encoded_jit_config` (base64 JSON of filename → base64 content).
3. Runner exchanges an RSA-signed JWT for an OAuth token, creates a broker session, and long-polls for a message.
4. On a job message: insert `runs`/`jobs`/`steps` rows (status `queued` → `in_progress`).
5. Build the Dagger pipeline; execute step by step; batch log lines into `job_logs`.
6. On finish: update step/job conclusion, report completion to GitHub, delete the session, and start again at step 2 with a new JIT registration and fresh per-job memory (or exit, with `--once`).

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Undocumented broker/run-service protocol | Could block milestone 2–3 | Time-box; reference `actions/runner` source; build the DB/UI against fake data meanwhile |
| Job messages may be encrypted with the session key | Extra crypto work | Check `TaskAgentMessage` handling early (M2) |
| Zig 0.17.0 std API churn, and library compatibility (HTTP/TLS, Postgres client) | Build breakage | Prefer std where possible; pin versions; verify each dependency builds before committing to it |
| Dagger needs a Docker-compatible engine on the host | Heavier than the runner itself | One shared engine per machine, shared by all runners |
| Expression/contexts (`${{ }}`) are a large surface | Scope creep | Subset only; fail loudly on unsupported syntax |

## 8. Milestones and ownership

| # | Milestone | Depends on | Owner |
|---|---|---|---|
| M0 | Schema + fake-log writer + API stub | none | _TBD_ |
| M1 | JIT config decode, OAuth token | GitHub test repo + token | _TBD_ |
| M2 | Broker session + long-poll, receive a job | M1 | _TBD_ |
| M3 | Job → Dagger pipeline, `run:` steps | M2 | _TBD_ |
| M4 | Job completion reporting to GitHub | M2 | _TBD_ |
| M5 | Log sink to Tiger Data (batched) | M0 | _TBD_ |
| M6 | Frontend: run list, run page, log viewer | M0 (fake data is enough) | _TBD_ |
| M7 | Dockerfile, multi-runner compose setup | M3 | _TBD_ |

**Demo target (vertical slice):** push a commit → one `run:` step executes through Dagger → live output appears in our UI → the job shows green on GitHub.

M0, M5 and M6 do not need GitHub access and can start immediately, in parallel with M1–M4.

## 9. Open questions

- Frontend and API stack confirmation (React / TypeScript proposed).
- ~~Postgres client for Zig: pure-Zig library vs. linking `libpq`. Needs a Zig 0.17.0 build check.~~
  Closed 2026-10-11: a pure-Zig client on `std`, `runner/src/pg.zig` (SPEC §2, §5.1), so the binary
  stays static (§7). Tiger Data sends a TLS `CertificateRequest` that Zig 0.17's TLS client rejects, so
  `runner/src/vendor/tls_client.zig` is std's client with one change that answers it (SPEC §6).
- Dagger integration: `dagger` CLI vs. GraphQL API from Zig.
- Where do operator secrets (GitHub token, DB URL) live?

## 10. Many runners per process

The point of a lightweight runner is running many of them on one machine. The target model is Go's goroutines, with a workflow job as the unit: one process runs N runner slots as concurrent tasks (`std.Io`), each looping register → wait → run → report, with per-job memory freed after each job and one shared Dagger session instead of a `dagger run` child per job (measured at about 60 MB each, ten times the runner itself). Steps:

1. One runner keeps going: re-registers after each job, per-job arena (`--once` keeps the old behaviour).
2. `--runners N`: N concurrent slots in one process, sharing config, log sinks and the database. Done: three concurrent jobs cost the runner process ~47 MB at peak (Debug), the three `dagger run` children ~195 MB, which is what step 3 removes.
3. ~~One shared Dagger session for the process.~~ Found unsafe: within one session, concurrent queries whose containers differ only in volatile variables are merged and one value wins, which would leak run-specific values (run id, event payload) between jobs. Instead, the runner speaks Dagger's client protocol itself (`src/engine.zig`, SPEC §6 "Engine client"): one session per job as before, but no `dagger run` child (about 65 MB of Go per job). Through the engine container its connections run `buildctl dial-stdio` (about 11 MB each, three per job); with the engine's own socket (`RUNNER_ENGINE_HOST`, an engine started with an extra listener) there is no process per job outside the runner at all: three concurrent jobs, runner at about 40 MB (Debug).
4. Graceful shutdown (SIGTERM: stop polling, finish running jobs, delete idle registrations) and measured cost per idle slot and per running job, in release builds.
