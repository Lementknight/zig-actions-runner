# Design: a lightweight, self-hosted GitHub Actions runner in Zig

Audience: the team, and anyone self-hosting it · Details: [SPEC.md](SPEC.md) · Running it: [DEPLOY.md](DEPLOY.md) · Measurements and trade-offs: [STUDY.md](STUDY.md)

## 1. Problem

The official GitHub Actions runner is a .NET listener plus a worker process per job. Each runner costs hundreds of megabytes, so a machine hosts only a few. Teams that want their CI on their own hardware, and people who want to learn CI/CD without paying for cloud compute, get a runner that does not fit small machines.

This project is to CI runners what Gitea is to GitHub: something you can run yourself, on modest hardware, that the rest of the ecosystem still works with.

## 2. Goals

- **A drop-in self-hosted runner.** It registers with GitHub and claims jobs natively (`runs-on: [self-hosted, zig]`). Workflows written for GitHub's hosted runners run unchanged, and their logs read like GitHub's, in GitHub's UI.
- **Many runners per machine.** One process runs many runners as concurrent tasks, each a job at a time, the way Go runs goroutines. What a machine can run at once is bounded by the jobs themselves, not by the runner.
- **A Raspberry Pi is the reference machine.** Code that only performs on good hardware is not done. Performance should scale with compute, and never assume it.
- **Repeated work is fast.** Unchanged steps are replayed, tools keep their caches between jobs, and only the work a change affects runs again.

## 3. Non-goals

- Windows or macOS jobs, PowerShell, or .NET: Linux containers and bash only.
- Hostile, multi-tenant workloads. The Dagger engine runs privileged and is root-equivalent on its machine, so the runner is for workflows its operator trusts.
- Auto-updating the runner binary.

## 4. Architecture

```
GitHub ⇄ runner process (N runners, Zig) ──► Dagger engine (one per machine; runs each step in a container)
                │
                └─► optional: Postgres / Tiger Data (runs, jobs, steps, logs) ──► api ──► web
```

| Component | Responsibility |
|---|---|
| `runner` | Registers runners just in time, polls GitHub's broker, runs each job's steps in the engine, streams logs to GitHub live and uploads them, reports results. One static Zig binary. |
| Dagger engine | Executes the steps, caches their results, and keeps the cache volumes. The runner speaks its protocol directly, one session per job. |
| `db`, `api`, `web` | Optional. When `DATABASE_URL` is set, the runner also writes run state and logs to Postgres, and a read-only API and frontend show them. GitHub's own UI is the primary log viewer. |

## 5. Key decisions

Each decision with what it costs. The measurements behind them are in [STUDY.md](STUDY.md) and [SPEC.md](SPEC.md).

1. **The real runner protocol, not webhooks.** Jobs are claimed natively, so they appear in the Actions UI and satisfy required checks. *Cost:* the protocol is undocumented; it follows `actions/runner`'s source and is checked by running workflows next to `ubuntu-latest`.
2. **Many runners in one process.** Runners are `std.Io` tasks, each job gets its own arena, and one HTTP client is shared. *Measured:* 20 idle runners in 29 MB, about 1.5 MB per running job.
3. **Dagger, spoken directly.** Jobs run in a Dagger engine, which caches step results. The runner holds each job's session itself (`engine.zig`) instead of starting a `dagger` CLI per job (about 65 MB each). Each job has its own session: a shared session merges concurrent queries that differ only in run-specific values, which would leak them between jobs. *Cost:* the runner is tied to Dagger's protocol, pinned to one engine version.
4. **GitHub-familiar by default.** The default image is `ubuntu:24.04` with what `ubuntu-latest` workflows assume, provisioned once per engine. Steps run as `runner` (uid 1001, passwordless `sudo`), as on GitHub. Step numbering, "Set up job" and post steps match GitHub's, and logs stream to GitHub live. `container:` jobs run as their image's user. *Cost:* every difference from GitHub found later is a bug to fix; `RUNNER_STEP_USER=root` exists for the cases where root is wanted.
5. **JavaScript actions on Bun, with Node as the fallback.** Bun is the default runtime: lighter, and good enough for most actions. When Bun refuses to load an action's code, which happens before any of it runs, the runner runs it again with Node and says so in the log (`actions/setup-python` v7 needs this). `RUNNER_JS_RUNTIME=node` uses Node throughout. *Cost:* Bun's incompatibilities surface one action at a time.
6. **Caching in three layers.**
   - **The step cache** (Dagger) replays a step whose inputs are unchanged. Run-specific values (run id, actor, runner name, the event) and the commit and refs are volatile, so they don't change the keys.
   - **Package and tool caches** are Dagger cache volumes per repository: npm, uv, Go, Cargo and others, plus `/opt/hostedtoolcache`. Pull requests from forks get their own.
   - **Dagger functions** cache their own calls.

   A step that uses a secret always runs, once in every job: it may deploy or publish. With **output keys** (experimental, `RUNNER_OUTPUT_KEYS`), the steps after it are keyed on what it produced rather than on its having run, so they can still be replayed. *Cost:* the step cache lives as long as the engine process, so an engine restart starts it cold. Restarts are rare and deliberate (the deploy files keep image updaters away), and the package and tool caches survive them, so a cold step cache is accepted rather than kept outside the engine. A new commit misses every step after the checkout, because each step starts from the previous one's container, which holds the checked-out files.
7. **The engine sized for small machines.** The engine runs with a memory cap and `GOGC=400`, and its cache on disk is capped at 20 GB (`deploy/engine.json`). Without the cache cap, Dagger let it grow to most of a Raspberry Pi's SD card. The kernel's records of those files then filled the engine's memory, and every job re-read its tools from the card.

## 6. Job lifecycle

1. The operator configures a GitHub token, the repository or organization, the labels and the number of runners.
2. Each runner registers just in time (`generate-jitconfig`), exchanges a signed JWT for a token, opens a broker session and long-polls for a job.
3. On a job: acquire it, renew it while it runs, and tell GitHub the steps (`WorkflowStepsUpdate`).
4. Run the steps in a Dagger session: `run:` steps, JavaScript, Docker and composite actions, services and job containers. Output streams to GitHub's live log feed.
5. Upload each step's log and summary, complete the job with its result, delete the session, and register again with fresh memory. `--once` exits instead.

On SIGTERM, waiting runners stop and remove their registrations, and running jobs finish first.

## 7. Risks

| Risk | Mitigation |
|---|---|
| GitHub changes the undocumented protocol | Follow `actions/runner`; check new behaviour against `ubuntu-latest` side by side |
| The privileged engine is root-equivalent on its machine | Trusted workflows only (§3); keep the pool small on shared machines |
| A Dagger upgrade changes its protocol or caching | One pinned engine version; upgrade deliberately, with the runner's tests |
| Actions that only work on Node | The Node fallback, or `RUNNER_JS_RUNTIME=node` |
| Small machines run out of memory or disk I/O | Engine memory and cache caps (`DEPLOY.md` "Sizing"); measure on the Pi |

## 8. Open questions

- **Hits across commits.** Tried and set aside (STUDY.md, experiment 5). A `run:` step could declare the files it reads, and the runner would key it on those instead of the whole checkout. Every replay decision was right, but both workloads ran faster without it: the tools' own caches already make the declarable steps cheap, the expensive steps (`go test`, pytest) are the ones a project cannot easily declare, and handing each step its inputs costs more than replaying them saves on a Raspberry Pi. The prototype is on `feat/declared-inputs-v2`. What is still open is the cost of handing a step its inputs at all, which decides whether any finer keying can pay.
- **Test selection for Python: nothing for the runner to do** (STUDY.md, experiment 8). Measured on sqlalchemy's 9,300 tests: selection saves eight times over when nothing relevant changed, but running tests under the tracing it needs costs four times as much, so a change to one core module selected 79% of the suite and took 4.5 times the full run. The unchanged case is already free through the step cache, which is the only case selection wins.
- **What a step costs in memory and inodes.** Experiment 7 found Dagger's per-step latency to be about 1% of a real job, so a different executor cannot win there; the engine's memory pressure (experiment 4) is the open dimension.
- **Output keys by default: no, on this evidence.** The trial ran 189 jobs on the Pi (STUDY.md §7.6): they applied in 187 and cost a median 4.6 s, but their cost follows the size of the job's filesystem rather than of what the step changed (78 s and 84 s on hugo, about 1 s on a small checkout), while the saving needs a re-run or unchanged inputs. They stay opt-in, and now stop themselves on a repository they are too slow for.

## 9. History

The project began at a hackathon. Its milestones were: a database schema and fake log writer, JIT registration and auth, the broker session, steps through Dagger, reporting completion, the log sink, the frontend, and a Compose setup. The database, API and frontend built then remain as optional parts. Since then the work has gone into running many runners per process, running GitHub's workflows unchanged, caching, and running well on a Raspberry Pi.
