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

## 6. Experiment 2: what does the step cache replay?

**Question.** Under a realistic stream of commits, and under re-runs, which steps does the runner's step cache replay, and what does it save?

**Workload.** A typical Go CI job on `go-task/task`: setup, checkout, `go mod download`, gofmt, `go vet`, `go build`, `go test`. The series is the project's own last 21 commits, oldest first, one job at a time. They are an unbiased mix: of the 20 changes after the first commit, 11 touch no Go code (website, changelog, CI configuration), 3 change only `go.mod` or `go.sum`, and the rest change Go source.

### 6.1 A bug: no deployed runner ever replayed a step

The first re-runs replayed nothing, even of identical jobs with no secrets. The cause was that `RUNNER_NAME` was part of every step's cache key, and a runner pool registers every job under a new name. Step caching had been verified with `--exec-job`, under a fixed name, before the pool existed. With `RUNNER_NAME` made volatile (PR #126), GitHub's re-run of the same jobs:

| Commit | First run | Re-run | Steps replayed |
|---|---|---|---|
| 2ecc2d2 | 61 s | 3 s | 6 of 6 |
| 4ac7726 | 73 s | 4 s | 6 of 6 |
| 2ec5ffa | 66 s | 3 s | 6 of 6 |
| f34e517 | 73 s | 3 s | 6 of 6 |
| 24c4ee6 | 80 s | 4 s | 6 of 6 |
| 490d779 | 84 s | 4 s | 6 of 6 |

A re-run is about 20 times faster. Re-running jobs is common: a flaky test, a required check, a cancelled run.

### 6.2 One step that uses a secret stops the cache for every step after it

The same six jobs with `actions/setup-go` instead of a Go image: `setup-go` has a `token` input that defaults to the job's `GITHUB_TOKEN`. The runner always runs a step that uses a secret, and marks its result with a per-run value. Every later step then has a parent no earlier run had, so nothing after it can be replayed:

| | Re-run time per job | Steps replayed after the first |
|---|---|---|
| Go from the image (no secret) | 3–4 s | all 6 |
| `setup-go` (token by default) | 22–27 s | none |

Most `setup-*` actions, and `actions/checkout`, take the token by default. So in practice this rule, not the cache itself, decides whether a real workflow benefits.

### 6.3 New commits always miss

Every new commit missed every step after checkout, documentation-only commits included. That's by construction: each step's key is its whole parent container, which includes the workspace and per-commit variables such as `GITHUB_SHA` and `GITHUB_REF`.

What a finer key would have saved can be computed from the series. Suppose each step were keyed only on its real inputs:

- `go.mod`/`go.sum` for `go mod download`;
- `*.go` for gofmt;
- `*.go`, `go.mod`, `go.sum` for `go vet` and `go build`;
- everything except documentation, website and CI configuration for `go test`.

Under that rule, of the 20 changes, `go test` could have been replayed for 9 and `go vet`/`go build` for 10. That is **33% of the five check steps' measured time** (241 of 735 s). It's less than the commit mix suggests, because the tool caches already make those steps cheap on commits that don't touch Go: `go vet` took 1–7 s on them, against 71 s for the first commit.

### 6.4 Container jobs miss the package caches

The persistent cache volumes are mounted at the default image's paths (`/root/go/pkg/mod`, `/root/.cache/go-build`). The `golang` image keeps Go's module cache in `/go/pkg/mod`, so in a `container: golang:1.26` job `go mod download` took 35–54 s every time, against 0–1 s with the default image.

**Fix and follow-up (PR #127).** In a container job, the variables that name each tool's cache directory (`GOMODCACHE`, `GOCACHE`, `UV_CACHE_DIR` and others) now point at the volumes, and the container's or workflow's own values still win. The same six jobs, run without step-cache hits:

| | job time | `go mod download` | engine CPU per job |
|---|---|---|---|
| before | 60–74 s | 35–45 s | 33–44 s |
| after, warm | 16–24 s | 0–1 s | 18–26 s |

The choice of path turned out to matter. The first version mounted the volumes at a new directory (`/var/cache/zig-runner/...`). Go keys compiled packages partly on their source directory, so moving the module cache invalidated every compiled dependency. The first job's `go vet` took 96 s (313 s of engine CPU), and the first job on a commit with new module versions took 122 s. Keeping the default image's paths, so that every image puts modules in the same place, halved that warm-up (150 s and 60 s) by sharing what earlier default-image jobs had compiled. The other half probably comes from a different Go patch version between the image and setup-go; I haven't verified it.

### Findings

1. **The step cache works now, and pays off for re-runs:** about 20 times faster when nothing changed. It had never worked in a deployed runner, and only measuring re-runs on the reference machine showed that.
2. **The secret rule is the real limit.** It is correct that a step using a secret must run: it may deploy or publish. But it shouldn't take every later step with it when its result is the same. Two designs to compare:
   - **Key steps on their parent's *content* rather than its *inputs*** (output-addressed rather than input-addressed, as in Nix's content-addressed derivations): a step that must run but produces the same files as before leaves the next steps' keys unchanged. Dagger keys on inputs, so this needs either a different engine or an extra hashing pass.
   - **Treat a defaulted `GITHUB_TOKEN` input differently from a secret the workflow passes:** smaller, but a judgement call about what a token can affect.
3. **Across commits, finer keys would save about a third of check-step time** on this project, on top of the tool caches. Getting there means keying steps on declared or inferred inputs. It also means taking per-commit variables such as `GITHUB_SHA` out of the key for steps that don't read them, which risks replaying a step that does read them indirectly (a version stamp from `git describe`, say).
4. **Cache paths must not assume the default image.** Fixed for container jobs by pointing each tool's variable at its volume, which made jobs about 3 times faster and halved engine CPU. **A cache's path can be part of another cache's key:** Go's build cache is keyed partly on where module sources live, so every image should use the same module cache path.
5. **Method notes.** Two early analyses were wrong and are corrected here. A "second pass" pushed a new commit, which changes `GITHUB_SHA`, so it could not hit by construction; GitHub's re-run is the right way to repeat a run. And a parsing slip counted a trailing newline as a replayed step.

## 7. Experiment 3: output-addressed keys on Dagger

**Question.** Can the steps after an always-run step keep their cache keys when that step produces the same files as before, without leaving Dagger?

**Why it is hard.** In an input-addressed cache, "always run S" also means "always run everything after S": each step's key includes its parent's key, and S's key changes every run. The ways out are to make fewer steps always run, or to key later steps on S's *output*.

### 7.1 Probes (Mac, Dagger v0.21.10)

A nonce in S's script forces it to run, as the runner does.

| Parent of the next step T | T in runs 2 and 3 |
|---|---|
| S itself (today) | re-runs |
| the base plus S's `diff`, copied | re-runs: Dagger keys the copy on the diff's recipe, which includes S |
| the base plus S's `changes`, applied as a literal patch (`withPatch`) | cached |
| the base plus an exec that copies S's changes from a cache volume, the content digest in its arguments | **cached** |

Dagger keys every value on how it was made. To get content into a key, the content, or its digest, has to be passed as an argument.

A patch carries the content through the runner. The runner runs many jobs in one process (the goroutine model), so that costs memory per job in proportion to the output: about 2.7 MB of patch for a checkout of go-task/task, held several times over. A patch also loses empty directories, owners and permission bits.

The **content store** passes only the digest. `Directory.digest` hashes content, not the recipe:

| What S changed | Digest changes? |
|---|---|
| Same content, different run | no |
| Same content, new modification time | no |
| One byte, `chmod`, `chown`, an extra empty directory | yes |

### 7.2 Design

For a step that always runs and succeeds (`RUNNER_OUTPUT_KEYS`, off by default):

1. Diff the container after the step against the one before it. The "before" container includes what the runner mounted for the step: the variables earlier steps set, the action's code and the JavaScript runtime. Their recipes do not change from run to run.
2. Store the changes in a per-repository cache volume at their digest. When two jobs store the same digest at once, `mv -T` lets the first writer win.
3. The next step starts from the "before" container plus one exec, `cp -a /store/<digest>/. /`, which also removes deleted paths. Its arguments, the digest and the removed paths, are what its key depends on.

The runner holds only the digest, so memory per job does not grow with a step's output. That fits the goroutine model.

### 7.3 What the Pi found

1. **Two bugs the unit test could not see.** The argument is named `from`, not `older`. Busybox only accepts an applet as its first argument when its own name starts with `busybox`. The unit test checks query text against a fake session, so a real engine's schema has to be checked separately.
2. **Outputs that change every run without mattering.** `@actions/core` writes a random delimiter into the file-command files, and every `go` command rewrites Go's telemetry counters (`~/.config/go/telemetry`). Both made `setup-go`'s digest new every run. They are now neither keyed nor carried to the next step. This is the classic reproducible-builds problem: real output mixed with noise, which a content-addressed cache has to separate.
3. **The runner's own mounts counted as output.** The 169 MB JavaScript runtime and the action's 9 MB of code were stored as if `setup-go` had written them. Hashing and copying them on the SD card is what made the first run slow.
4. **A post step gains nothing from output keys.** Only other posts follow it, and they always run. Output-keying it cost 8–14 s per job, so posts are now skipped.

### 7.4 Results

Experiment 2's `setup-go` workflow (go-task/task at 6 commits), on the Pi. The first runs are back to back, flag off then on.

| | Job time | Engine CPU per job |
|---|---|---|
| First run, flag off | 31–66 s | 19–30 s |
| First run, flag on | 33–76 s | 20–29 s |
| Re-run, input keys (experiment 2) | 22–27 s | 17–26 s |
| **Re-run, flag on** | **4–6 s** (first job 18 s) | **0.7–1.6 s** (first job 4.4 s) |

In the re-run, `setup-go` runs, as a step with the token must, produces the same digest, and the six steps after it are replayed. A first run costs about the same as without output keys. The exception is the first job to store a new digest, which takes about 10 s more.

### 7.5 Findings

1. **Output-addressed keys work on Dagger** without a new engine, through a content store and a digest in an exec's arguments. They lift experiment 2's main limit: one secret-using step no longer forces every later step to run.
2. **Measure overhead with a back-to-back control.** The first comparison against experiment 2's numbers from earlier in the day overstated the cost by about 2 times. Most of the slowdown was the Pi's state at the time, not the change.
3. **The engine is short of memory on the Pi, with or without this change.** It sits at its 4 GB cap and has hit it tens of thousands of times. 1.4 GB of that is reclaimable kernel slab (inode and directory caches), so first runs re-read Go's toolchain and caches from the SD card, at 25–30% iowait. That is the next cost to understand. Pass B is fast because it barely touches the disk.
4. **One hypothesis was wrong.** I thought stripping the ignored paths before the diff forced a full filesystem walk; the Mac showed no difference.

**Still open before this can be on by default:**
- deletions and empty directories, covered by the design but not yet by a Pi run;
- images with a non-root `USER`, where `cp -a` cannot set owners, so the runner falls back;
- pruning the store;
- Docker actions, which copy their workspace back by a separate path and are not covered;
- which other tools write noise like Go's telemetry, which needs a survey of the target workloads (uv, npm).

## 8. Next

- **The overhead floor:** the small Go projects (chi, cobra) and an empty job, to measure what the runner adds when the tests take almost nothing.
- **Python with uv:** the same questions for `uv sync`, ruff and pytest. Pytest has no built-in equivalent of Go's test cache, so test selection there is a real gap to look into.
- **Engine memory on the Pi:** why kernel slab fills the engine's cgroup, and whether first runs can stop re-reading the toolchain from the SD card.
- **Output keys to default:** the open items of experiment 3, then the same measurement across the Go and Python workloads.
- **Breaking down the engine's cost:** Dagger (~720 ms per 10 trivial steps on the Mac), BuildKit alone (~300 ms) and raw overlayfs with namespaces (~35 ms). The BuildKit layer will be split into its parts: runc, snapshot metadata, cgroups, gRPC.
