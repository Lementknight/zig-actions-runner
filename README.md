# Zig Actions Runner

A lightweight, Zig-based alternative to the official GitHub Actions runner, built so small
engineering teams can run CI/CD on the machines they already have.

## Why

Self-hosting the official runner is how a team gets CI/CD without paying a hosted provider. In
practice it stops scaling quickly. The official runner is a .NET listener plus a worker process per
job, and it is heavy on CPU and memory. A small team usually has one machine, not a cluster, so the
CPU becomes the bottleneck. That limits how many runners can poll for jobs at once, and at that point
self-hosting stops making sense and a hosted service looks like the easier answer.

## What this project does instead

- **A single static Zig binary.** It registers as a real self-hosted runner and claims jobs natively
  (`runs-on: self-hosted`). There is no .NET runtime to install and no runtime dependencies.
- **Low idle cost.** The runner is meant to use little CPU and memory while it waits for jobs, so one
  machine can host many concurrent runners. A team with no server can run them on the machines it
  already develops on.
- **GitHub Actions workflows, unchanged.** The runner reads the same workflow syntax, so a team that
  already knows GitHub Actions keeps what it knows and does not rewrite its workflows. Support is a
  documented subset today, listed in [SPEC.md](docs/SPEC.md) §6. Anything outside it fails the step
  with a clear "unsupported" message instead of running wrong.
- **Cached job execution.** Each job runs as a Dagger pipeline, so repeated work is cached.
- **Your own log viewer.** Logs and run state go to Tiger Data (Postgres with TimescaleDB), and a
  custom frontend shows them the way the Actions UI does.

The idle-cost numbers are targets, not measurements yet. See SPEC §7.

## Components

| Directory | What it is |
|---|---|
| `runner/` | The Zig runner. Registers, claims jobs, runs them through Dagger, writes state and logs. |
| `db/` | Schema, migrations and seed data for Tiger Data. |
| `api/` | Read-only HTTP API over the stored runs and logs (TypeScript). |
| `web/` | The frontend: run list, run page and job view with live logs (React). |

```
GitHub ⇄ runner (Zig) ──► Dagger engine (runs steps in containers)
            │
            └─► Tiger Data: runs, jobs, steps, job_logs
                        │
                  API server (read layer)
                        │
                    Frontend
```

## Try it

You need Zig 0.17.0 and a GitHub token with admin on the repository or organization.

```sh
cd runner
zig build test
GH_TOKEN=... GH_SCOPE=owner/repo zig build run -- --dry-run   # validate config, register nothing
```

Drop `--dry-run` to register and wait for a job. Setting `DATABASE_URL` sends logs to Tiger Data;
without it they go to stdout. Every setting is listed in [SPEC.md](docs/SPEC.md) §2. The other
components have their own setup notes: [db](db/README.md), [api](api/README.md), [web](web/README.md).

## Docs

- [Design document](docs/DESIGN.md): the problem, goals, architecture, decisions and milestones.
- [Spec sheet](docs/SPEC.md): the contracts between components. Change it in the same PR as the code.

Status: in development. The runner protocol, Dagger execution, database layer, API and frontend are
being built in parallel. See DESIGN §8 for the milestone list.
