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
| Rust, small | [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) (MIT/Unlicense) | — | a compiled language: what the step cache saves when nothing changed |
| Rust, large | [clap-rs/clap](https://github.com/clap-rs/clap) (MIT/Apache-2.0) | — | how a job's cost grows with the artefacts it leaves: ~1 GB of `target/`, ~925 MB of registry cache |

Each project is pinned to a commit or tag, and all Go projects build with Go 1.26 (the newest any of them asks for is 1.26.4). The Rust projects use `dtolnay/rust-toolchain@stable`, which works unchanged on this runner.

Rust was added last and is where the step cache shows best, because compiling is the cost:

| | Pi, first run | Pi, re-run | GitHub-hosted |
|---|---|---|---|
| ripgrep: fetch, debug build, test | 90 s (1.6 + 30.1 + 22.9 s) | **5 s**, 3 of 3 steps replayed | 36 s, then 34 s again |
| clap: fetch, debug build, test | 229 s (37.8 s fetch, 134.4 s test) | — | 85 s |

The Pi is about 2.5 times slower than a hosted runner at compiling, and about seven times faster than one on a re-run, since a hosted runner has nothing to replay. clap also shows what a Rust job leaves behind: a 996 MB `target/` in the workspace and 925 MB in the registry cache volume for one project, which is the scale the engine's 20 GB cache cap has to hold (§8.2).

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

**Design.** Two parts. The first is PR #145; the second is a prototype on the branch `feat/declared-inputs-v2`, three versions of it:

- **The commit and refs are volatile,** as run ids already were. Removing `GITHUB_SHA` from the key costs nothing in correctness: the checkout already keys every later step on the files it produced. A script that names one of these variables always runs, as for run ids. Experiment 2's worry, a step that reads the commit indirectly (`git describe`), is handled the same way: `.git` is in the workspace, so the checkout still keys it.
- **Declared inputs.** A `run:` step may list what it reads in `ZIG_RUNNER_INPUTS` (workspace globs, plus `$GITHUB_SHA` and the like if it needs them). It then runs in a container built from content: the job's base, what earlier steps changed outside the workspace and the variables they set, and only the declared files as the workspace. What it changes is put back into the job's container, which the next step starts from.

The trade-off is in who is trusted to be right. Inferring inputs (tracing what a step reads) needs no declaration but can miss reads and replay a wrong result. A declaration can also be wrong, but here it is enforced: an undeclared file is not in the container, so the step fails instead of replaying a wrong result. The cost of that safety is that the declaration must be complete.

**Workloads.** Experiment 2's first six go-task commits (`setup-go`, checkout, `go mod download` declared on `go.mod go.sum`, gofmt on `**/*.go`, `go vet` on both; `go test` undeclared), and twelve consecutive commits of pallets/flask (`setup-uv`, checkout, `uv sync`, ruff, mypy, pytest, all declared). Each series ran one job at a time, and each was measured against a control: the same workflow with the declarations removed.

### 9.1 The replay decisions are right

Across all four runs of the two series, every declared step replayed exactly when its declared files were unchanged and ran when they changed, and none fell back. On flask's four commits that left the declared inputs alone (two changelog-only, two repeating an earlier commit's files), all four steps replayed every time.

Enforcement was tested by getting declarations wrong twice, and both failed loudly rather than replaying something wrong: flit, flask's build backend, reads `LICENSE.txt` and the version out of `src`, and ruff is installed in `.venv`. A project's maintainers have to find every file a step reads, and the first attempt here missed two.

The first flask run also found a bug of the runner's own: the checkpoint left the workspace owned by root, so `uv sync` could not create `.venv` as the step user. The Go series had not caught it, because none of its steps write to the workspace.

### 9.2 What Dagger keys on content

Why the cost moved around so much is explained by what Dagger puts in a cache key. A probe mounted a directory into a step that printed a random value, in two sessions, with two queries per session as the runner does, and checked whether the second session replayed the first's value:

| Directory mounted | Content | Next step |
|---|---|---|
| A step's output, the content changed (control) | differs | ran |
| A step's output, the step itself differs each time (a nonce) | same | **ran** |
| A git checkout filtered to `go.mod go.sum`, two commits | same | **replayed** |
| The whole git checkout, two commits (control) | differs | ran |

**Dagger keys files from a git checkout on their content, and a step's output on how it was made.** So the workspace half of a declared step's container can be free, while the half that earlier steps produced cannot.

Two more measurements decided the design, both on the Pi, where the SD card makes costs visible (the same probes on the Mac showed no differences at all):

| Giving a step a 200–240 MB directory of ~20,000 files | Time |
|---|---|
| `cp -a` from a mount (what v1 did) | 20 s |
| `withDirectory`, no owner | 1–2 s |
| `withDirectory` with `owner:` (so the step user can write it) | **21 s**, then 1–2 s while the source is unchanged |
| `withMountedDirectory` | 1–2 s |

**Three method notes.** The first three rounds of the content probe were invalid: in bash, `$RANDOM` inside a pipeline or `$(...)` is evaluated in a subshell, and a subshell of a shell that never used `$RANDOM` gets the same value every time, so the "different" trials sent identical commands and every replay looked like content keying. The control caught it. Second, the `owner` probe had to run on the Pi: on the Mac every variant took 1–2 s, which would have been read as "owner is free". Third, that probe reused one source directory across its rounds, so it measured a cached ownership pass and understated what a *new* directory costs; the real runs showed that.

### 9.3 Three versions, and what each cost

| | flask, 12 commits | go-task, warm commits |
|---|---|---|
| **Control** (no declarations) | **575 s** | **258 s** |
| v1: the store, `cp` in and out | 1,514 s | — |
| v2: layers instead of copies | 1,376 s | — |
| v3: the ownership pass only where needed | **734 s** | **476 s** |

- **v1** stored every part by digest and copied it in with `cp -a`, and copied the step's output back the same way. Building a declared step's container took 25–65 s and applying its output 2–28 s, almost all of it moving `.venv`.
- **v2** passed those parts as Dagger directories instead. Building a container fell to 1–3 s and applying an output to under 2 s. Its first run replayed nothing at all, though: the checkout gets a fixed modification time so that Python wheels can be built (§8.1), and `withTimestamps` makes the result keyed on how it was built rather than on its content. Filtering the declared files first and setting the time afterwards keeps the content key.
- **v3** split the workspace by where its files come from. The checkout's files are root's and need `owner:`, but a filter of a git tree is content-keyed, so that pass is cached while those files are unchanged. An earlier declared step's output needs no pass at all: that step ran as the step user, so its files already belong to them. In v2 all the declared patterns went into one directory, so a change to `src` re-owned the whole 200 MB `.venv` on every commit.

### 9.4 Why it still does not pay

v3 is the best version and still loses on both workloads. The per-commit figures say why.

**flask.** A commit that leaves the declared inputs alone saves about 22 s; one that changes them costs about 31 s. So the feature needs about **three commits in five** to leave the expensive step's inputs alone. This sample had one in three. And `uv sync` must declare `src`, because flit reads the version from `src/flask/__init__.py`, so almost every commit re-runs it, and the three steps after it each take in its new `.venv`.

**go-task.** With the tool caches warm, the control's `go mod download` is 1 s on every commit: the step the feature was meant to rescue is already free. `go vet` is the one real win, 2 s replayed against 8–24 s. But `go test`, which declares nothing, cost 27–65 s against the control's 18–27 s. Its container is now a stack of the declared steps' layers, and materialising that stack costs more than the control's simple chain. **The overhead is not confined to declared steps: it falls on the steps after them too.**

**Findings.**

1. **The commit and refs are volatile** (PR #145). That is pure gain, and it is the half of this experiment worth keeping.
2. **Declared inputs work and do not pay, on this machine with this engine.** Every replay decision was right, and v3 is half v1's cost, but both workloads ran faster without declarations. Experiment 2's estimate of a third saved was computed from step times alone; it did not account for what it costs to hand a container its inputs.
3. **The two reasons are structural.** The tools' own caches (Go's module and build caches, uv's cache) already make the declarable steps cheap, and the step that dominates each workload is the one a project cannot easily declare or cache (`go test` for Go; for flask, `uv sync`, which must declare `src`). Declaring more steps makes the stack deeper, which the steps after them pay for.
4. **Where it would pay:** a step that is slow, has no cache of its own, and reads a small, rarely-changing set of files. That is a narrower case than this experiment assumed.
5. **It is not Dagger's fault alone.** Dagger does key checkout-derived files on content, which is what made v3 possible. What it does not offer is content keys for a step's output, and no copy-free way to re-own files. Driving BuildKit directly is not justified by this: the cheap paths were all reachable from Dagger's API.

The prototype stays on `feat/declared-inputs-v2` with its tests, in case the cost profile changes (an SSD machine, or an engine that keys step outputs on content).

## 10. Experiment 6: the cache volumes and installers that hardlink

**Question.** Experiment 5 found `uv sync` to be 19–33 s of a 40–57 s flask job, on every commit, with a warm uv cache. uv says why: "Failed to hardlink files; falling back to full copy." Is that the runner's doing, and what does it cost?

**The cause.** Each package cache is its own Dagger cache volume, and each volume is its own filesystem. Probed inside a job on the Pi, by `stat` and by trying the link:

| Path | Device |
|---|---|
| the uv cache volume | 99 |
| the pip cache volume | 77 |
| the npm cache volume | 162 |
| `/tmp` **and the workspace** | 173 |

A hardlink from any volume to the workspace is refused ("Invalid cross-device link"), and so is one from one volume to another. `/tmp` and the workspace are the same filesystem, so links between *those* work. On a GitHub-hosted runner everything is one disk, so the question never arises.

Two mounts of the *same* volume are also separate devices: a link between them is refused although each sees what the other writes. So the only hardlink-reachable place from a cache is inside that same cache, which is what the fix below rests on.

**What it costs.** Six variants of the same `uv sync` in one job (flask, 84 packages, a 214 MB `.venv`), and the same for pnpm and npm (68 MB of dependencies):

| Warm install | Pi, from the volume | Pi, from a copy on the workspace's filesystem | GitHub |
|---|---|---|---|
| uv | **27.0 s** | **0.2 s** | 0.1 s |
| pnpm | **16.6 s** | 1.4 s | 1.3 s |
| npm | 1.5 s | — | 1.4 s |

Copying uv's cache onto the workspace's filesystem first takes 4.4 s, so "copy, then install with hardlinks" is 4.6 s against 27 s. Naming the fallback explicitly (`UV_LINK_MODE=copy`) costs the same 25.4 s, which confirms the warning describes what already happens. Even on GitHub's SSD, forcing copy mode costs 5.6 s against 0.1 s.

### 10.1 The fix, and what it did not cost

Two designs were tried and discarded before the one that worked, both for reasons worth recording:

- **Persist caches as content the runner tracks** (read `container.directory(path).id` at the end of a job, add it with `withDirectory` at the start of the next). Hardlinks would work, since the cache would be on the container's own filesystem. But a cache's content would then be part of every step's cache key, and caches churn on almost every run, so step replay — worth about 20 times on a re-run (experiment 2) — would be lost. The two properties are mutually exclusive on Dagger: on the container's filesystem means in the key; persistent means a mount, and a mount means another device.
- **Mount one volume twice,** once for the cache and once for the install target. The probe above refused that link.

**What works is to put the install target inside the cache.** uv allows it (`UV_PROJECT_ENVIRONMENT`), so the runner now keeps uv's project environment in uv's own cache volume, one per ref, with the workspace's `.venv` a symlink to it, made before the checkout (which merges the repository over it and leaves it). Measured on the Pi against `ubuntu-latest`:

| | This runner | GitHub |
|---|---|---|
| `uv sync`, new ref | 9.2 s (was 28.6 s) | 1.3 s |
| `uv sync`, re-run | **0.5 s** | 0.8 s |
| fallback warnings | none (was 2) | none |
| `uv run`, `.venv/bin/python`, `activate`, `.venv/bin/pytest` | all work, 134 tests pass | same |

**The fidelity cost did not materialise.** Relocating the environment was expected to break `.venv/bin/...` and `source .venv/bin/activate`; through the symlink both work, as does pytest run from it. A warm sync is now faster than a GitHub-hosted runner's. The real costs are that environments accumulate in the volume, one per ref, until it is pruned, and that `RUNNER_UV_ENV_IN_CACHE=false` exists for anyone it surprises.

**pnpm cannot be fixed this way.** `node_modules` has to be in the workspace for imports to resolve, so there is nowhere hardlink-reachable to put it. It still pays 16.6 s against 1.4 s, and only its workflow can avoid that, by copying the store under `RUNNER_TEMP`.

**Findings.**

1. **The cache volumes make hardlink-based installers slow,** by a factor of 135 for uv and 12 for pnpm on the Pi. It is the runner's design doing it, not the tools.
2. **npm, Go and Cargo are unaffected:** they copy from their caches anyway, and a bulk copy of the same 68 MB takes 1.5 s. The penalty is not "copying is slow" but that uv and pnpm copy file by file, with verification, down a path they do not expect to take.
3. **The runner cannot stage a cache into the job.** That needs an exec that reads the volume, and Dagger keys an exec on its recipe, not on a mounted volume's content, so the exec would either be cached and serve a stale copy for ever, or carry a per-job value and change every step's cache key after it.
4. **It can move the install target into the cache, where one exists** (10.1): uv's environment now lives there by default, which made a warm `uv sync` faster than a GitHub-hosted runner's, and the symlink kept every way a workflow reaches `.venv` working. Where the target must stay in the workspace, as pnpm's `node_modules` must, only the workflow can avoid the cost.
5. **Two designs failed first, for one reason:** on Dagger, being on the container's filesystem means being in the cache key, and persisting means being a mount, which means another device. Any fix has to live on one side of that line.

## 11. Experiment 7: is the engine the per-step cost?

**Question.** With architecture open to change, would an executor of our own (overlayfs and namespaces directly, as the study's earlier Mac probes suggested) make jobs faster than Dagger does? The answer has to be a number, not a preference.

**Method.** On the Pi, three levels, each with a fresh nonce per measurement so nothing is replayed, and the per-step cost taken as the slope between a 1-step and a 21-step run rather than a total (which would fold in startup):

| Level | Per step | Fixed cost |
|---|---|---|
| Raw overlayfs: mount, namespace, exec, unmount, on the SD card | **17.1 ms** | — |
| **Dagger** (`withExec` chain in one session) | **60–62 ms** | 0.53–0.63 s per session |
| BuildKit through the Dockerfile frontend (`buildctl --no-cache`) | 207–534 ms | — |

**Dagger is not the slow layer.** Its per-step cost is about 3.5 times a hand-rolled floor, and the gap is 43 ms a step: on a ten-step job, 0.6 s against 0.17 s. Against jobs that take 40–60 s on this machine, that is about 1%. An executor of our own cannot win back more than that on per-step overhead, which is the ground the rewrite case was standing on.

The BuildKit row is **not comparable** and is kept only to be honest about what was run: a Dockerfile `RUN` commits a layer per instruction, while Dagger's `withExec` chain does not, so that row measures more work per step rather than a lower layer doing the same work. Reproducing the study's earlier Mac figures (Dagger ~72 ms a step, BuildKit ~30 ms) would need BuildKit driven through LLB with the same semantics as Dagger's chain.

**Where the fixed cost actually is.** An empty job through the runner takes 2–4 s (experiment 4) while an engine session costs 0.6 s and an empty job spends 0.1 s of engine CPU. So most of a job's floor is the GitHub protocol — registering, claiming, reporting, uploading logs — and not the engine at all. A different executor would not move it.

### 11.1 What a step costs in memory and inodes

The dimension latency could not settle. 100 trivial steps through Dagger, then 100 raw overlay steps, with the engine's cgroup, the host's inodes and the engine's snapshot count read either side:

| Per 100 steps | Dagger | Raw overlay |
|---|---|---|
| engine memory | **+279 MB** (anon 696 → 959 MB) | none |
| engine snapshots kept | **+202** (about 2 a step) | none |
| filesystem inodes | +1,206 (about 12 a step) | none |
| disk | +13 MB (about 131 KB a step) | +80 KB total |
| kernel `ext4_inode_cache` | unchanged at 957 MB | unchanged |

**The retained state is the price of the step cache, not of Dagger.** The raw loop keeps nothing because it deletes each mount; it also cannot replay anything. Any executor that replays steps has to keep each step's result, and two snapshots, twelve inodes and 131 KB a step is a modest way to keep it.

**The memory looked like the exception, and then did not.** The first reading was +279 MB for 100 steps, with nothing returned after 25 minutes idle, which suggested an index growing about 2.6 MB a step. Watching it across six more batches showed otherwise:

| | Heap | Snapshots |
|---|---|---|
| start (a collection had run since the first reading: 959 → 706 MB) | 706 MB | 2,960 |
| +100 steps | 876 MB | 3,164 |
| +200 steps | **882 MB** | 3,368 |
| +300 steps | 1,045 MB | 3,572 |

Between 100 and 200 steps the heap moved 6 MB while 200 snapshots were added, and the earlier 959 MB had already fallen to 706 MB on its own. So most of the growth is **Go garbage, not a live index**: the heap oscillates up to about five times the live set, which is what `GOGC=400` asks for, and the live set looks like a couple of hundred megabytes.

**That removes the architecture argument and leaves a setting.** `GOGC=400` was this project's own choice, for 6% less engine CPU on a Mac and 13% on a Pi (DEPLOY.md "Sizing"). The price is that the engine's heap runs to about 1 GB of a 4 GB cap before collecting, and page cache is what gets squeezed — the same page cache whose absence turned 1 s of output-key work into 17 s (§8.2). On a machine with 8 GB shared with other services, that trade looks wrong, and testing it costs one engine restart rather than a new executor.

### 11.2 `GOGC`, tested

Three arms on the Pi, each a fresh engine (so an empty step cache) and the same flask job: a cold run, then warm re-runs of the same commit. The first pass suggested warm jobs got faster as `GOGC` fell (31 s, 21 s, 17 s). Repeating the two ends three times each showed that was noise:

| | `GOGC=400` (the default here) | `GOGC=100` (Go's default) |
|---|---|---|
| cold run | 125 s | 133 s |
| warm runs | 19 / 9 / 7 s | 19 / 7 / 7 s |
| engine CPU, cold then warm | 45 / 13 / 4 / 3 s | 46 / 14 / 4 / 3 s |
| heap held | ~350 MB | **~125 MB** |
| page cache | 1,915 MB | 1,970 MB |

**`GOGC=400` buys nothing measurable here and costs about 225 MB of a 4 GB cap.** Job time and engine CPU are the same within noise across both arms. The 6% and 13% CPU savings that chose `GOGC=400` (DEPLOY.md "Sizing") were measured on a different workload, real Node builds with more steps; they may still hold there, so the documented default should not change on this evidence alone.

**What these arms cannot test.** Each starts from a fresh engine, so the step cache is empty and the engine never approaches its memory cap: `memory.events max` stayed at 0 in every arm. The pathology this was meant to address (§8.2: the cap hit 154,000 times, the same work taking 1 s or 17 s) needs thousands of cached results and days of churn to reappear. So this says `GOGC=100` is free in the short run, not that it prevents the pathology. The Pi is left at `GOGC=100` to find out, with the per-job cost and saving lines still being logged.

**Findings.**

1. **Per-step overhead does not justify leaving Dagger:** 43 ms a step against the floor, about 1% of a real job on the reference machine.
2. **Nor does the job floor:** it is the GitHub protocol, not the engine.
3. **What did cost real time this week was elsewhere:** the cache volumes' filesystem split (28.6 s a Python job, now 0.5 s, experiment 6) and the engine's memory pressure (the same work taking 1 s or 17 s, experiment 4). Both were found by measuring workloads, not layers.
4. **Nor does memory, once garbage is separated from live data** (11.1). Keeping a step's result costs about two snapshots, twelve inodes and 131 KB on disk; the heap growth that looked like an index is mostly Go garbage under `GOGC=400`, a setting of ours. The engine's memory pressure is therefore a tuning question, not an architecture one.
5. **So the architecture stays.** Nothing measured — per-step latency, the job floor, retained state or memory — supports replacing Dagger.
6. **`GOGC=400` looks like the wrong trade on this machine** (11.2), though not for the reason expected: not because a lower value is faster, but because it is free. The same job time and CPU, 225 MB less heap. Whether that headroom prevents §8.2's pathology needs a loaded engine and days, which the Pi is now accumulating at `GOGC=100`.

## 12. Next

- **Test selection for Python,** on a workload that needs it. flask does not: its 493 tests run in under 3 s, and experiment 6 found its job's time to be `uv sync`. A project with slow tests is needed before this question means anything.
- **Whether the staging recipe (experiment 6) can be made the default** without an exec that reads a volume, which Dagger will not key on content.
- **The cost of handing a step its inputs:** experiment 5's overhead, measured on its own rather than as a feature's by-product, and on a machine with an SSD as well as the Pi. It decides whether any form of finer keying can pay here.
- **Engine memory over days:** the 15-minute log under ordinary jobs, to decide whether the cache cap should be lower (8.2).
- **Output keys to default:** the open items of experiment 3, then the same measurement across the Go and Python workloads.
- **Whether `GOGC=100`'s headroom prevents the memory pathology** (11.2), which needs a loaded engine and days rather than fresh arms; and whether `GOGC=400`'s documented CPU saving still holds on a step-heavy workload, which is where it was first measured.
