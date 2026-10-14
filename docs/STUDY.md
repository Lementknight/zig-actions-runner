# Study: what a CI step costs, and what it should

Status: in progress · Reference machine: Raspberry Pi 5 (4 cores, 8 GB, SD card) · Companion: [DESIGN.md](DESIGN.md), [SPEC.md](SPEC.md)

This study decides how the runner should execute steps. Today every step runs through Dagger; the alternatives are BuildKit directly, or an executor of our own in Zig. Rather than pick by intuition, each part of the problem is measured on its own, and each design choice is written down with what it gains and what it gives up.

## 1. The problem

Self-hosted runners exist so that people can run CI/CD on their own machines, the way Gitea lets them host their own forge, without renting cloud compute. That sets the constraints:

- **The reference machine is a Raspberry Pi.** Code that only performs on good hardware is badly designed code. The runner should run well on a Pi and scale with more compute, without assuming it.
- **The workloads are many small, frequent jobs.** Lint, format and test checks for Go (native tooling) and Python (uv), failing fast; static-site builds; SSH deploys to dev and prod boxes; release versioning; branch rules and standardization. Checks are shared with git hooks through Dagger, so steps call `dagger` themselves.
- **They run often, so caching is required.** When source changes, only the work the change affects should run.
- **The people running it are a team, not strangers.** Standard container isolation is the bar; hostile multi-tenancy is not the target.
- **The examples are open-source projects**, so the study can be reproduced and the projects modified.

What the runner adds to a job beyond the job's own commands is the cost being designed. Its share depends on the job: about 3% of a 60-second build, but 30–50% of a 3-second lint check.

## 2. Workloads

| Size | Project | Packages with tests | Measures |
|---|---|---|---|
| small | [go-chi/chi](https://github.com/go-chi/chi) (MIT), [spf13/cobra](https://github.com/spf13/cobra) (Apache-2.0) | 2 each | the runner's own overhead: tests are short, so most of the time left is the runner's |
| medium | [go-task/task](https://github.com/go-task/task) (MIT) | 19 | which tests a change affects, across packages |
| large | [caddyserver/caddy](https://github.com/caddyserver/caddy) (Apache-2.0) | 30 | how costs grow with project size |
| Python | [pallets/click](https://github.com/pallets/click), [pallets/flask](https://github.com/pallets/flask) (BSD-3) | — | uv, ruff and pytest |

Each project is pinned to a commit, and all Go projects build with Go 1.26 (the newest any of them asks for is 1.26.4).

## 3. Measurement

- **Engine CPU:** the Dagger engine container's cgroup counter (`cpu.stat` `usage_usec`), sampled every 2 s on the Pi and attributed to a job by GitHub's start and end times. It includes everything the job's steps run, since they run inside the engine.
- **Runner CPU:** `/proc/<pid>/stat` of the runner process. It stays near 0.1 s per job, so it is left out of the tables below.
- **What ran:** from the tools' own output (for Go, `ok … (cached)` against `ok … <time>`).
- **One job at a time** on the reference machine, so a job's CPU is its own.
- **Caveats:** a 2 s sampling interval blurs short jobs; one run per configuration so far; numbers from the Mac are labelled as such, and the Mac runs everything inside a Linux VM.

## 4. Caching has three layers

Before comparing engines, it matters where caching happens, because only one layer belongs to the engine:

| Layer | Unit | Who provides it | Hits when |
|---|---|---|---|
| step cache | a whole step | the engine (Dagger snapshots each step and keys it on its inputs) | nothing the step depends on changed, including the whole workspace |
| tool cache | a package, a test binary, a dependency | the tool (`GOCACHE`, uv's cache), kept in a persistent volume per repository | the tool's own inputs are unchanged |
| function cache | a Dagger function call | Dagger, for checks written as Dagger modules | the function's arguments are unchanged |

The step cache keys a step on its entire parent container. A checkout of a new commit is a new workspace, so every step after it misses, even `uv sync`, whose real inputs are two files. "Only run the tests the change affects" therefore cannot come from the step cache. Experiment 1 tests whether it comes from the tool cache.

## 5. Experiment 1: does Go run only the tests a change affects?

**Question.** With the runner's persistent `GOCACHE` volume, does `go test ./...` in a later job re-run only the packages a change affects?

**Method.** Four jobs in sequence on the Pi, each a fresh job with a fresh checkout of `go-task/task` at `ad2782e`. The `go test` step is forced to run, so the step cache does not replay it. Before each change, `go list -test` predicts which test binaries depend on the changed package.

| Job | Change |
|---|---|
| cold | none, with an empty, throwaway `GOCACHE` |
| warm | none |
| leaf | in `cmd/release`, which nothing imports |
| core | in `errors`, which 16 test binaries depend on |

**Results** (Raspberry Pi 5):

| Job | Predicted | Re-run | Cached | `go test` | Job | Engine CPU |
|---|---|---|---|---|---|---|
| cold | 19 | 19 | 0 | 153 s | 163 s | 371 s |
| warm | 0 (+2) | 2 | 17 | 9.8 s | 17 s | 9.9 s |
| leaf | 1 (+2) | 3 | 16 | 5.2 s | 12 s | 10.5 s |
| core | 16 | 16 | 3 | 24.8 s | 33 s | 49 s |

**Findings.**

1. **Yes.** Across separate jobs, Go re-ran exactly the predicted test binaries. A warm run costs about 10 s of engine CPU against 371 s cold: 37 times less. The requirement is met at the tool layer, by the persistent cache volume, not by the engine.
2. **Go's cache is keyed on the linked test binary, which is finer than the source.** The first attempts used a comment, and then a function nothing calls, as the change. Neither re-ran anything, even in `errors`: a comment leaves the compiled output unchanged, and the linker drops an unused function, so every test binary stayed byte-for-byte the same. Only a change that reaches the binary (an `init` function) re-ran tests. So Go re-runs a test only when the code it executes could have changed.
3. **Two packages always re-run** (the root package's integration tests, 2.5–4.3 s, and `internal/fsext`): their tests use inputs Go does not track. Every project has some, and they set the floor for a warm run.
4. **The runner had a bug, found by the method.** `GITHUB_JOB` and `${{ github.job }}` were always empty, so the first run's jobs all took the same branch. GitHub's runner fills `github.job` in from the message's `system.github.job` variable; ours now does too (PR #125).

**What it means for the engine.** The fine-grained caching that matters most for these workloads lives in the tools, and needs only cheap, persistent, per-repository directories. Any engine must keep those. The engine's own step cache matters for steps without such a tool cache, such as scripts, downloads and generated files.

## 6. Next

- **The overhead floor:** the small Go projects (chi, cobra) and an empty job, to measure what the runner adds when the tests take almost nothing.
- **Python with uv:** the same questions for `uv sync`, ruff and pytest. Pytest has no built-in equivalent of Go's test cache, so test selection there is a real gap to look into.
- **Step-cache hit rates** under a scripted series of realistic commits (source edits, dependency bumps, documentation edits).
- **Breaking down the engine's cost:** Dagger (~720 ms per 10 trivial steps on the Mac), BuildKit alone (~300 ms) and raw overlayfs with namespaces (~35 ms). The BuildKit layer will be split into its parts: runc, snapshot metadata, cgroups, gRPC.
