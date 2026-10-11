# Design: Lightweight Zig GitHub Actions Runner

Status: draft v0.1 · Audience: the whole team · Companion: [SPEC.md](SPEC.md)

## 1. Problem

Small engineering teams want CI/CD built into their normal workflow without paying a hosted provider, so they self-host GitHub Actions runners. That breaks down at their scale. The official runner is a .NET listener plus a worker process per job, and it is CPU- and memory-heavy. A small team has one machine, not a cluster of servers, so the CPU is the bottleneck. It caps how many runners can poll for jobs concurrently, and once it does, self-hosting no longer beats the hosted option. The official runner's logs are also only viewable in GitHub's UI.

## 2. Goals

- A single static **Zig** binary that registers as a real self-hosted runner and claims jobs natively (`runs-on: self-hosted`).
- Low idle cost, so one machine can host many runners, including the machines a team already develops on when it has no server.
- Drop-in for teams that know GitHub Actions: the runner accepts the same workflow syntax, so migrating needs no change to what they already know. Parity is a documented subset (see Non-goals and SPEC §6).
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
7. **Ephemeral (JIT) runners.** One job per registration; the process re-registers for the next job. This simplifies state and cleanup.

## 6. Job lifecycle

1. Operator config provides a GitHub token, repo/org, labels and runner group.
2. Runner calls `generate-jitconfig`, decodes `encoded_jit_config` (base64 JSON of filename → base64 content).
3. Runner exchanges an RSA-signed JWT for an OAuth token, creates a broker session, and long-polls for a message.
4. On a job message: insert `runs`/`jobs`/`steps` rows (status `queued` → `in_progress`).
5. Build the Dagger pipeline; execute step by step; batch log lines into `job_logs`.
6. On finish: update step/job conclusion, report completion to GitHub, delete the session, exit (ephemeral).

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
