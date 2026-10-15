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

**Concurrent jobs.** In a run of the same matrix three legs at a time, an always-run step wrote the run's commit SHA, so every leg produced the same new digest. All six jobs succeeded. The store ended up with one directory for the digest, containing only what the step wrote, and no leftover temporary directories. The legs started in the same second, but this does not prove their store calls overlapped: a leg that arrives late finds the directory and skips. It does show the concurrent path is safe.

The test also caught a bug in review: the temporary name came from the run's nonce, which a run's matrix legs share. Each store now uses its own random name.

**Deletions, empty directories and metadata.** A secret step deleted two files (one with a quote in its name) and a directory tree, created nested empty directories, and changed a mode, a symlink and an owner. The step after it, starting from the rebuilt container, checked all of them, and every check passed. On a re-run the step produced the same digest (3 removed paths), and the check was replayed.

**Noise survey: Python and Node.** The same re-run test with the always-run setup steps of uv and Node projects (click, flask, express):

| Setup step | Same digest on a re-run? | What differed |
|---|---|---|
| `astral-sh/setup-uv` v9 | yes, and the same for click and flask | — |
| `actions/setup-node` v4 | no | `/tmp/node-compile-cache`: V8 bytecode that Node and npm write on every run, not byte-identical between runs |
| `actions/setup-go` v5 | yes, once its noise was excluded | Go's telemetry counters (§7.3) |

So far the noise is all tool caches or telemetry that the tool rebuilds itself. Rather than keep a growing per-tool ignore list, these now live in cache volumes like the package caches (PR #131). That puts them outside the container's filesystem by construction, and Node starts faster on the Pi with its compile cache kept. Output keys now ignore only the runner's own file commands. Leaving out a whole directory such as `/tmp` would not be: steps legitimately leave files there for later steps.

The survey also found three runner bugs unrelated to output keys:
- `github.workspace` was empty, so `setup-uv` failed (fixed).
- A step's output was lost when it arrived after the step's end marker, as Bun's error does when it refuses an action (fixed).
- The same timing could label a step that ran as "Reused from Dagger's cache". The runner no longer guesses (PR #132). Each job has a random value in a volatile variable, which is not part of any cache key. Each step writes it with its file commands, so a replayed result carries an earlier job's value.

**The exact label found a bug on its first run.** Secret-using steps were forced to run by a nonce made from the run's ID and attempt. A run's matrix jobs share those, so in a matrix, the second job replayed the first job's secret steps. For a deploy in a matrix, that would mean deploying once instead of in each job, as GitHub does. The nonce is now per job (PR #132). This shows why an exact signal beats a heuristic: the timing guess had hidden the bug.

With all of this, one fresh run and one re-run of click, flask and Express on the Pi labelled every step correctly. In the first run, nothing was labelled reused. In the re-run, exactly the steps after the setup steps were, in all three jobs. `setup-uv`, `setup-python` (through the Node fallback) and `setup-node` each produced the same digest in both runs.

It also found that Bun cannot load `actions/setup-python` v7, whose bundle mixes ES `import` with CommonJS `exports`; Node runs it. The runner now retries an action with Node when Bun refuses to load it (PR #130). The retry starts from the container before Bun's attempt: starting from the refused exec, which always runs, kept every later step from being replayed.

The store had 27 digests after one day of experiments, so it needs pruning. It is now pruned by age since last use (PR #133). The store step runs whenever an always-run step finishes, and is never replayed. It marks the output it finds or stores as used, and removes outputs not produced for 7 days. Pruning can only cause misses, never wrong results: a replayed step does not read the store, and a copy that finds nothing falls back to the step's own container. On the Pi, four backdated outputs were removed by the next job, and everything else stayed.

### 7.5 Findings

1. **Output-addressed keys work on Dagger** without a new engine, through a content store and a digest in an exec's arguments. They lift experiment 2's main limit: one secret-using step no longer forces every later step to run.
2. **Measure overhead with a back-to-back control.** The first comparison against experiment 2's numbers from earlier in the day overstated the cost by about 2 times. Most of the slowdown was the Pi's state at the time, not the change.
3. **The engine is short of memory on the Pi, with or without this change.** It sits at its 4 GB cap and has hit it tens of thousands of times. 1.4 GB of that is reclaimable kernel slab (inode and directory caches), so first runs re-read Go's toolchain and caches from the SD card, at 25–30% iowait. That is the next cost to understand. Pass B is fast because it barely touches the disk.
4. **One hypothesis was wrong.** I thought stripping the ignored paths before the diff forced a full filesystem walk; the Mac showed no difference.

**Images with a non-root user.** The copy into the next step ran as the image's user, so in an image with a non-root `USER` it failed and output keys fell back. It now runs as root, then restores the image's user (PR #134). With `cgr.dev/chainguard/git:latest-dev` (uid 65532) on the Pi, the next step still ran as 65532. A file the always-run step wrote kept its owner, and a re-run replayed the check.

**Docker actions.** A Docker action runs in its own image, and only the workspace comes back. That copy was keyed on the action's run, so every later step still ran. The returned workspace is now stored by its digest and copied into the container from before the action (PR #135). On the Pi, a `docker://alpine` step's changes to the workspace (a deletion, a new file, an empty directory) reached the next step. A re-run produced the same digest and replayed the check.

**Seeing how often they apply.** A fallback used to show only with step debug. The runner's own log now has a line per job, for example `job 115925527829: output keys: 1 of 1 always-run steps applied`, with the last reason when any fell back (PR #136).

**Still open before this can be on by default:** none of the prototype's known gaps remain. What's left is to run it on the target workloads for a while, with the per-job line showing how often it applies, and to measure the cost of the store on the Pi over days rather than single runs.

## 8. Experiment 4: the overhead floor and the engine's memory on the Pi

**Questions.** What does the runner itself cost on a job that does almost nothing? And why do first runs on the Pi spend 25–30% of their time waiting on the SD card?

### 8.1 The overhead floor

An empty job (one `true` step), and the small Go projects chi and cobra (`setup-go`, checkout, `go test`), three times each, one at a time, with output keys on.

- **The runner is cheap:** an empty job takes 2–4 s and 0.1 s of engine CPU.
- **In a small Go job, almost all the time went to output keys' diff after `setup-go`: 13.5–21 s.** The action itself took 2 s. Timing each phase of the output-key work (PR #136) found this; the per-job total alone would not have.
- **cobra fails on this runner but not on GitHub.** `TestFailGenFishCompletionFile` expects writing to a `0400` file to fail. Steps run as root here, and root ignores file permissions; GitHub runs them as the non-root user `runner`. Any test suite that checks permissions will differ the same way. Steps in the default image now run as `runner` (uid 1001, passwordless `sudo`), as on GitHub (PR #139), and cobra's suite passes. That needed provisioning the user and making `/github` its own, plus moving the package caches under its home, owned by it, in new volumes (root's hold files it cannot write). It also needed creating the caches' directories in advance: Dagger creates a cache mount's missing parent directories as root, which broke `setup-go`'s `mkdir ~/go/bin`.

The same test found that **checked-out files had the time 1970-01-01 00:00:01**, which is what Dagger's `git` gives them. Building pallets/flask failed, because wheels are zips and cannot hold times before 1980. Checkouts now get a fixed time, 2000-01-01, which stays the same from run to run so cached steps still match (PR #139).

### 8.2 The engine's memory

Read from the engine's cgroup (`memory.stat`, `memory.events`) and the kernel's slab caches, without restarting anything:

| | Measured |
|---|---|
| Engine memory | at its 4 GB cap; the cap hit 121,907 times |
| Kernel slab charged to the engine | 1.68–2.0 GB, mostly ext4 inode cache (1.45–1.73 GB) |
| Page cache | 0.8 GB |
| Engine cache on disk | 67 GB in 17,000 snapshots; 25 GB of the 117 GB card free |

The engine had no configuration. Dagger's default garbage collection lets the cache reach about three quarters of the disk before collecting anything. The kernel's record of the cache's files filled the engine's memory and crowded out its page cache. So every walk of a container's files went to the SD card: the diff, and Go's toolchain on a first run.

**One measurement perturbed the system.** My first snapshot script ran `du` over the 67 GB cache, which itself pulled about 300 MB of inodes into memory. Later snapshots took disk use from the engine's own log.

**A control restart reset everything.** I restarted the engine without changing anything, as the control for a cache cap. Within minutes, the cache went from 67 GB to 2.4 GB (329 snapshots), and the next restart's log mentioned 128 network namespaces "left over from previous run". In Dagger v0.21, the engine keeps its index of cached results in memory. After a restart, the snapshots on disk are unreferenced, and garbage collection removes them. **So every engine restart empties the step cache,** which DEPLOY.md now says.

On the fresh engine, the same workflow:

| | 67 GB cache | Fresh engine |
|---|---|---|
| Diff after `setup-go` | 13.5–20.9 s | 0.73–1.0 s |
| All output-key work | 14.4–25.7 s | 1.0–1.3 s |
| chi job (steps replayed) | 23–55 s | 5 s |
| Page cache / slab | 798 / 1,999 MB | 3,417 / 206 MB |

**The fix:** cap the cache at 20 GB (`deploy/engine.json`, PR #138); the engine reports the policy as active. A logger on the Pi records the engine's memory every 15 minutes, to check whether slab stays small as the cache fills up to the cap.

**The cap bounds the disk, not the memory.** The logger caught the cache filling up: experiment 5's two flask runs, which stored and copied a `.venv` per job, took it from 10 GB to the cap in about half an hour.

| Time | Cache on disk | Snapshots | Slab (inode cache) | Memory cap hit |
|---|---|---|---|---|
| after the Go runs | ~10 GB | 4,676 | 288 MB | 87 times |
| declared flask run | 21.4 GB (at the cap) | 9,130 | 989 MB | 19,053 |
| control flask run | 21.4 GB | 3,436 | 1,208 MB | 33,494 |
| idle afterwards | ~21 GB | 1,551 | 1,182 MB | 44,371 |

Garbage collection held the disk at the cap and cut the snapshots by five times, but the kernel's records of the files it had touched stayed at 1.2 GB, charged to the engine. Within each flask run, output keys' work after `setup-uv` grew from about 1 s to 10–17 s; on the Go runs before, it held at about 1 s. So the 67 GB day was the same effect at a larger scale, and the cap makes it smaller, not absent. Whether ordinary jobs (not experiments that write hundreds of MB each) also push the engine to its memory cap is what the next days of logging will show; if they do, a lower cap (about 12 GB) is the next step, not a larger memory cap on a machine that hosts other services.

**What a restart costs.** Recreating the engine's container between two runs of an always-run probe job (PR #148): the step cache was gone, and every cache volume survived. A marker written into the npm cache before was still there after, as were the Go and uv toolchains, Go's 1,055 module directories and uv's cache. So after a restart a workflow's first run replays no steps but still finds its downloads and toolchains. Restarts on the Pi are rare and deliberate: Watchtower checked the engine nightly but never replaced it (its pinned tag never changed), unattended upgrades neither reboot nor touch Docker, and the deploy files now keep image updaters away from the engine (WUD would otherwise move it to the next Dagger release). A cold step cache after a restart is accepted rather than kept outside the engine.

### 8.3 Found along the way

- **Log uploads failed for two minutes,** all of a job's blobs within the same second. A request that failed was giving its dead connection back to the shared pool. Now a failed connection is dropped, and failed writes are retried (PR #137). Why the failures stopped by themselves is not known.
- **The leftover network namespaces are not a leak.** Dagger keeps a warm pool of 128 network namespaces (`CNIPoolSize`, default 128 in `cmd/engine/config.go`), prefilled at engine start: 128 in 9.4 s on the Pi, 7.8 s of engine CPU. A restart cannot release the old pool's namespaces, because their mounts went away with the old container, hence the warnings; they do not pile up on disk. The pool could be shrunk (`cniPoolSize` in `engine.toml`, 16 is plenty for three runners), but that only saves those ~8 s per engine start, so it is left as it is.

## 9. Experiment 5: hits across commits

**Question.** Experiment 2 found that a new commit misses every step after the checkout, and estimated that keying steps on their real inputs would save about a third of check-step time. Can the runner do that on Dagger, and what does it save in practice?

**Design.** Two parts. The first is PR #145; the second is a prototype on the branch `feat/declared-inputs`:

- **The commit and refs are volatile,** as run ids already were. Removing `GITHUB_SHA` from the key costs nothing in correctness: the checkout already keys every later step on the files it produced. A script that names one of these variables always runs, as for run ids. Experiment 2's worry, a step that reads the commit indirectly (`git describe`), is handled the same way: `.git` is in the workspace, so the checkout still keys it.
- **Declared inputs.** A `run:` step may list what it reads in `ZIG_RUNNER_INPUTS` (workspace globs, plus `$GITHUB_SHA` and the like if it needs them). It then runs in a container built from content: the job's base, what earlier steps changed outside the workspace and the variables they set, and only the declared files as the workspace, each part stored by digest. What it changes is copied back into the job's container. This reuses experiment 3's content store.

The trade-off is in who is trusted to be right. Inferring inputs (tracing what a step reads) needs no declaration but can miss reads and replay a wrong result. A declaration can also be wrong, but here it is enforced: an undeclared file is not in the container, so the step fails instead of replaying a wrong result. The cost of that safety is that the declaration must be complete, which a project's maintainers can do once per step.

**Workload.** Experiment 2's first six go-task commits, one job each, with `setup-go`, the checkout, and three declared steps: `go mod download` (`go.mod go.sum`), gofmt (`**/*.go`), and `go vet` (both); `go test` is undeclared.

| Commit | Job | go mod download | gofmt | go vet | go test |
|---|---|---|---|---|---|
| 2ecc2d2 (cold) | 211 s | ran 60 s | ran 2 s | ran 11 s | 116 s |
| 4ac7726 | 49 s | **replayed** 1 s | ran 2 s | ran 3 s | 24 s |
| 2ec5ffa | 23 s | **replayed** 2 s | **replayed** 1 s | **replayed** 1 s | 10 s |
| f34e517 (new module versions) | 117 s | ran 41 s | **replayed** 1 s | ran 3 s | 62 s |
| 24c4ee6 | 40 s | **replayed** 2 s | ran 2 s | ran 2 s | 26 s |
| 490d779 | 29 s | **replayed** 1 s | ran 2 s | ran 3 s | 15 s |

**Go results.**

- **The keys are right.** Each declared step replayed exactly when its declared files were unchanged and ran when they changed; none fell back. The earlier steps' changes (`setup-go`'s toolchain) had the same digest on every commit, which is what makes any of this possible.
- **The savings are small.** A replayed declared step takes 1–2 s on the Pi, mostly building its container, which is what gofmt and a warm `go vet` take to run. `go mod download`'s 41–60 s runs were a cold module cache (the first job) and new module versions (f34e517), exactly the cases where it cannot replay; with a warm cache it takes about a second either way. Go's own caches, kept between jobs in cache volumes, already capture most of what finer keys would save.

### 9.1 Python: flask

Twelve consecutive commits of pallets/flask, oldest first: `setup-uv`, the checkout, then `uv sync`, ruff, mypy and pytest, each declared. Two commits change only the changelog, two others repeat an earlier commit's files, and the rest change code. A control ran the same jobs without declarations.

Getting the declarations right took two tries, and both mistakes failed loudly rather than replaying: flit, flask's build backend, needs `LICENSE.txt`, and ruff is installed in `.venv`. The first try also found a bug: the checkpoint left the workspace owned by root, so `uv sync` could not create `.venv` as `runner` (fixed on the branch).

| Step | Control | Declared, ran | Declared, replayed |
|---|---|---|---|
| uv sync | 21–35 s | 54–74 s | 13–19 s |
| ruff | 0–1 s | 31–75 s | 4–6 s |
| mypy | 6–12 s | 19–28 s | 3–5 s |
| pytest | 4–5 s | 32–50 s | 3–5 s |
| Job | 43–69 s | 161–237 s | 39–49 s |
| Twelve jobs | **702 s** | | **1,514 s** declared |

Every replay was correct, but declaring made the series about twice as slow. Each declared step's container is built by copying what earlier steps produced (`.venv`, hundreds of MB) out of the store, and its result back in. On the Pi's SD card that costs 30–75 s. A job where everything replayed was barely faster than the control. `uv sync` also ran on every code commit, because an editable install of the project reads `src`.

### 9.2 What Dagger keys on content

Why copy at all? A probe on the Mac mounted a directory into a step that printed a random value, in two sessions, with two queries per session as the runner does, and checked whether the second session replayed the first's value:

| Directory mounted | Content | Next step |
|---|---|---|
| A step's output, the content changed (control) | differs | ran |
| A step's output, the step itself differs each time (a nonce) | same | **ran** |
| A git checkout filtered to `go.mod go.sum`, two commits | same | **replayed** |
| The whole git checkout, two commits (control) | differs | ran |

**Dagger keys files from a git checkout on their content, and a step's output on how it was made.** So the workspace half of the checkpoint did not need the store: filtering the checkout itself would be keyed on content for free, as long as no earlier step changed the declared files. The other half, what earlier steps produced, does need it, because the steps that produce toolchains and environments (`setup-go`, `setup-uv`) take the token and always run. That half is the cost in 9.1.

**A method note.** The first three rounds of this probe were invalid. In bash, `$RANDOM` inside a pipeline or `$(...)` is evaluated in a subshell, and a subshell of a shell that never used `$RANDOM` gets the same value every time. So the "different" trials sent identical commands, and every replay looked like content keying. The control caught it: a trial whose content had to differ replayed too. Values are now generated in the parent shell and printed.

**Findings.**

1. **The commit and refs are volatile** (PR #145). That is pure gain.
2. **Declared inputs replay correctly but do not pay on Dagger as built.** For Go, its own caches do most of the work; for Python, copying the environment costs more than replaying saves. The prototype stays on its branch.
3. **The next design would use the content keys Dagger already has:** declared files filtered from the checkout, with no store, and the store only for files an earlier step changed. For environments like `.venv`, a cache volume named by the lockfile's digest (as `actions/cache` is used) costs nothing to mount, but trades enforced correctness for a convention.
4. **Enforcement makes declarations safe to get wrong, but not free:** a project's maintainers have to find every file a step reads, and the first attempt here missed two.
5. **Dagger is the limit only for step outputs.** Driving BuildKit directly is not justified by this: the cheaper design above stays within Dagger.

## 10. Next

- **Python with uv:** the same questions for `uv sync`, ruff and pytest. Pytest has no built-in equivalent of Go's test cache, so test selection there is a real gap to look into.
- **Declared inputs without the copy:** the checkout-filtered design in 9.2, measured on the same Go and Python series.
- **Inferring inputs** instead of declaring them, from a language's manifest or by tracing reads, and what it would cost to be wrong.
- **Engine memory over days:** the 15-minute log under ordinary jobs, to decide whether the cache cap should be lower (8.2).
- **Output keys to default:** the open items of experiment 3, then the same measurement across the Go and Python workloads.
- **Breaking down the engine's cost:** Dagger (~720 ms per 10 trivial steps on the Mac), BuildKit alone (~300 ms) and raw overlayfs with namespaces (~35 ms). The BuildKit layer will be split into its parts: runc, snapshot metadata, cgroups, gRPC.
