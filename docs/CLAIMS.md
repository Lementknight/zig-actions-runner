# Claim registry: what each number in the study rests on

Audience: whoever is about to cite a number, or re-check one · Companion: [MEASURE.md](MEASURE.md)
(the rules), [STUDY.md](STUDY.md) (the claims), [proofs/](../proofs/README.md) (the properties) ·
[DESIGN.md](DESIGN.md) for what was decided on them

[MEASURE.md](MEASURE.md) §3.1 asks that every performance claim have an entry naming what was
measured, on what, against what, how many times, and how to run it again — and that a claim without
one be marked unverified and not used to justify a change. This is that register, built by reading
STUDY.md against §3.2 after the fact.

**70 claims: 23 verified, 33 under-powered, 1 unverified, 4 superseded, 2 proved, 3 withdrawn, 2
refuted, 1 no effect found, 1 not measurable as framed.** Sixty-three came from reading STUDY.md
against §3.2; the seven in §S came
from measuring this machine instead, and are the first here that the study never made. The first
refutation is E6.4, and it was refuted in *direction*, not merely in size: a
warm `uv sync` is slower here than on a hosted runner, where the study said faster. **W.5 went the
same way for the same reason**, and between them they were both of the study's "faster than a hosted
runner" claims — each measured the Pi with its caches warm against a hosted runner with its caches
cold, so each reported a margin made mostly of downloads the Pi had already done. Neither was a
sample-size problem, which is why neither was fixed by repetition. The
one-line summary still holds otherwise: *little here is wrong, and little is measured to the
standard MEASURE.md sets.* The
large effects — 135× on uv's install, 20× on a re-run, 37× on a warm Go job — are far beyond any
plausible noise and can be relied on in direction and order of magnitude. The small ones cannot, and
that is where two deployed settings were decided.

## How to read a verdict

- **Verified** — meets §3.2 in substance: repeated measurements or a negative control or an
  independent oracle, and an effect comfortably larger than the measurement's own error.
- **Under-powered** — one sample per arm, or no interval, but the effect is far larger than any
  plausible run-to-run variance and nothing uncontrolled plausibly explains it. Usable; treat the
  *size* as approximate and the direction as sound.
- **Unverified** — the evidence does not support the claim as stated: the effect is within plausible
  variance, or an uncontrolled difference could account for it. **Per §3.1 these may not be used to
  justify a change** until re-checked. Each says what is wrong with it. Eight started here; **E5.4 is the only one left**, the rest having been verified, refuted or withdrawn.
- **Withdrawn** — taken out of the study's prose rather than queued for a series, for one of two
  reasons. Either it was run and recorded but is not comparable to what it was compared against
  (E7.2), or it was never a measurement in the first place: a mechanism offered in prose with no
  arms (E2.7), or arithmetic on single samples about a feature that has since been shelved (E5.6).
  A claim that cannot be measured as written should say so, not sit in a queue. Three.
- **Superseded** — a later experiment overturned it. Kept because it is still cited.
- **Proved** — not a measurement at all: a property established in `proofs/`.

Each entry names the workload at its pin, the machine, the arms, and the repetitions. Unless an entry
says otherwise the statistic is a **single reading** (or a range across the jobs of one series), one
job at a time, arms run in blocks rather than interleaved, and the first round not separated from the
steady state — the three things §3.2 asks for and the study did not do.

## Reproducing any of this

Four claims have a command in this repository. Everything else was produced by shell written for the
occasion, living in `~/.cache/zig-runner-study/` on one laptop (`declared.sh`, `go-v3.sh`, `v2.sh`,
`arm.sh`, `vol.sh`, `memsnap.sh`, …), untracked and not reviewed. **That is the single biggest gap
this register exposes**, and it is what MEASURE.md stage 2 replaces: a harness in the repository, with
the environment captured per trial and one JSON line per sample.

In the repository today:

| | Command |
|---|---|
| **the protocol, around any command** | `cd runner && zig build measure -- run …` ([measurements/](../measurements/README.md)) |
| re-analysing samples without re-running them | `zig build measure -- analyse <file>.jsonl --min-effect X` |
| the repetitions a wanted precision needs | `zig build measure -- dimension <file>.jsonl --target X` |
| the replay decisions and the key's contents | `cd runner && zig build test` (unit tests over the query text) |
| the caching properties | `./proofs/check.sh` |
| how often output keys applied, per job | `sudo journalctl -u zig-runner \| grep "output keys:"` on the Pi |
| how many steps a job replayed | `sudo journalctl -u zig-runner \| grep "replayed from the cache"` |

The harness was validated against the two claims whose answers were already known, by transcribing
their recorded numbers and analysing them: E7.6 comes back `no_effect_found`, as the study says, and
**E7.7 comes back `not_enough_samples`** — the verdict this register reached by reading, reached
independently by arithmetic. The samples are in [measurements/](../measurements/README.md).

## §2 Workloads

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| W.1 | ripgrep re-run 5 s against 90 s first run, 3 of 3 steps replayed | ripgrep, pinned · Pi | 1 × 1 | under-powered |
| W.2 | ripgrep on a hosted runner: 36 s, then 34 s again (nothing to replay) | ripgrep · `ubuntu-latest` | 1 × 2 | under-powered |
| W.3 | clap: 229 s here against 85 s hosted; leaves 996 MB of `target/` and 925 MB of registry cache | clap · Pi, hosted | 1 × 1 | under-powered |
| W.4 | hugo `go mod download` 35.8 s → 0.2 s, `go build ./...` 195.3 s → 8.7 s with warm volumes | hugo, 192 packages · Pi | cold vs warm × 1 | under-powered |
| W.5 | sqlalchemy install 21.0 s here against 28.2 s hosted ("faster than a hosted runner") | sqlalchemy · Pi, hosted | 3 × 10 | **refuted** (2026-10-17, [measurements/w5/](../measurements/w5/README.md)) — the hosted runner is **faster**: medians 2.154 s against 3.073 s, difference 0.919 s, 95% CI [0.881, 1.538], 30% of the baseline, negative control at 0.009 s, and the arms do not overlap (every hosted reading below every Pi reading). Same defect as E6.4: the study's own sentence says the Pi's registry was warm "while the hosted runner downloads from PyPI each time". With both package caches warm the install is 2-3 s, so the 7.2 s margin was download time |
| W.6 | sqlalchemy's 9,300 tests 81.2 s here against 42.7 s hosted | sqlalchemy · Pi, hosted | 1 × 1 | under-powered |
| W.7 | the Pi is ~2.5× slower at compiling and ~7× faster on a re-run | derived from W.1–W.3 | — | under-powered |

## §5 Experiment 1 — does Go run only the tests a change affects?

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E1.1 | Go re-ran exactly the test binaries `go list -test` predicted, across separate jobs | go-task/task @ `ad2782e` · Pi | 4 arms (cold, warm, leaf, core) × 1 | **verified** — an independent oracle per arm, matched exactly; not a timing |
| E1.2 | a warm job costs ~10 s of engine CPU against 371 s cold (37×) | as above | 2 × 1 | under-powered |
| E1.3 | Go's cache is keyed on the linked test binary, finer than the source | as above | 4 changes (comment, unused function, `init`) × 1 | **verified** — three negatives and one positive, a differential test |
| E1.4 | two packages always re-run (2.5–4.3 s), setting a warm run's floor | as above | 1 × 4 jobs | under-powered |

## §6 Experiment 2 — what does the step cache replay?

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E2.1 | a re-run with nothing changed is ~20× faster (61–84 s → 3–4 s), 6 of 6 steps replayed | go-task/task, 6 commits · Pi | first vs GitHub re-run × 6 commits | **verified** — six independent pairs, same direction, effect ~20× |
| E2.2 | one step using a secret stops replay for every step after it (3–4 s and 6 of 6, against 22–27 s and none) | same 6 commits, Go image vs `setup-go` · Pi | 2 × 6 | **proved** — `no-cutoff-without-keys`; the measurement agrees |
| E2.3 | every new commit misses every step after the checkout | 21-commit series · Pi | 1 × 20 changes | **proved** — `parent-matters`; construction, not chance |
| E2.4 | finer keys would save ~33% of check-step time (241 of 735 s) | computed from the 21-commit series | not an experiment | **superseded** — E5.5 measured the opposite; it costed step times only, not what handing a container its inputs costs |
| E2.5 | in a container job the package caches were missed: `go mod download` 35–54 s, fixed to 0–1 s; jobs ~3× faster, engine CPU halved | same 6 jobs, `container: golang:1.26` · Pi | before vs after × 6 | under-powered — a blocked before/after across a code change, not interleaved |
| E2.6 | a cache's path can be part of another cache's key: moving Go's module cache invalidated every compiled dependency (96 s `go vet`, 313 s engine CPU) | as above · Pi | 2 paths × 1 | under-powered |
| E2.7 | the other half of that warm-up "probably comes from a different Go patch version" | — | — | **withdrawn** (2026-10-17) — never a measurement: it names no quantity, has no arms, and the thing it is about (one image's Go against `setup-go`'s, at that date) has moved on both sides, so there is nothing left to compare. Measuring it would mean pinning two patch versions and rebuilding a cache state the study did not record. Nothing rests on it: the actionable half of that paragraph is E2.6, which is recorded on its own |

## §7 Experiment 3 — output-addressed keys

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E3.1 | of four ways to re-base the next step, only an exec carrying the content digest is cached | probe · Mac, Dagger v0.21.10 | 4 × 2 runs | **verified** — the four arms discriminate, and the chosen one then worked on the Pi |
| E3.2 | `Directory.digest` hashes content, not recipe: a new run or a new mtime keeps it, a byte, mode, owner or empty directory changes it | probe · Mac | 6 × 1 | **verified** — deterministic mechanism, each arm its own control |
| E3.3 | with output keys, a re-run is 4–6 s and 0.7–1.6 s of engine CPU, against 22–27 s with input keys | `setup-go` workflow, 6 commits · Pi | 2 × 6 | under-powered — large effect, single run per commit |
| E3.4 | a first run costs about the same with the flag on | `setup-go` workflow, 6 commits · Pi | 2 × 6 | **superseded** — re-measured 2026-10-16 as engine CPU on a checkout-plus-four-steps job: output keys cost **+1.47 s**, 95% CI [1.356, 1.699], against a 1.05 s baseline. The cost is roughly fixed per always-run step, so "about the same" holds only when the job is large enough to hide it — see E3.4b |
| E3.4b | output keys cost about 1.5 s of engine CPU per always-run step on a small checkout | checkout of go-task/task at `ad2782e` + a marked step + 3 steps, every step carrying the trial's token · Pi | 3 × 4, interleaved, one arm a negative control | **verified** — 2.518 s against 1.047 s, difference +1.471, CI [1.356, 1.699]; the control arm (identical to the baseline) came out `no_effect_found`, CI [−0.250, +0.024]; re-run: `measurements/e3.4/` |
| E3.5 | output keys cost a median 4.6 s per job (p75 8.6 s, p90 20.3 s, worst 91 s; 9 jobs over 30 s) | 189 real jobs over 2 days · Pi | observational, n=189 | **verified** — the best-evidenced number in the study: a distribution, not a reading |
| E3.6 | the cost follows the size of the job's filesystem, not of what the step changed (hugo: 14.7 s before-container, 10.4 s diff, 0.4 s store and copy) | hugo · Pi | phase decomposition × 1 | under-powered — direct decomposition, but one job, and the same walks took 1.2 s on a fresh engine (E4.4) |
| E3.7 | what they saved: 29 of 166 steps replayed across 42 jobs; 34 of 42 replayed none | 42 real jobs · Pi | observational | **verified** — with the selection bias stated: nearly every job was a fresh commit |
| E3.8 | they now stop themselves: over `RUNNER_OUTPUT_KEYS_MAX_MS`, later jobs for that repository skip them | limit set to 0.5 s · Pi | functional × 1 | under-powered — a functional check, not a measurement |
| E3.9 | concurrent matrix legs storing the same digest are safe (one directory, no leftovers) | 3-leg matrix × 2 runs · Pi | functional × 6 jobs | under-powered — shows the path is safe, does not prove the stores overlapped (stated in the text) |

## §8 Experiment 4 — the overhead floor and the engine's memory

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E4.1 | an empty job takes 2–4 s and 0.1 s of engine CPU | one `true` step · Pi | 1 × 3 | **verified** — repeated, tight range, and the floor is what it is used for |
| E4.2 | in a small Go job, output keys' diff after `setup-go` took 13.5–21 s, against 2 s for the action | chi, cobra · Pi | 1 × 3 each | under-powered |
| E4.3 | the engine sat at its 4 GB cap (hit 121,907 times) with 1.68–2.0 GB of kernel slab, mostly ext4 inode cache, and a 67 GB cache in 17,000 snapshots | the Pi as it was | observational × 1 | under-powered — a single snapshot of one machine's state |
| E4.4 | a fresh engine does the same work ~15× faster: diff 0.73–1.0 s against 13.5–20.9 s, chi job 5 s against 23–55 s | chi · Pi, before and after a restart | 2 × 3 | under-powered — the control restart is the strongest evidence here, and it cannot be interleaved or repeated cheaply |
| E4.5 | every engine restart empties the step cache (67 GB → 2.4 GB within minutes) | the Pi | 1 × 1, plus the mechanism (an in-memory index) | **verified** — observation and mechanism agree, and a later probe (E4.7) repeated it |
| E4.6 | the 20 GB cap bounds the disk, not the memory: slab stayed at ~1.2 GB and the cap was hit 44,371 times | two flask runs · Pi | observational, 4 time points | under-powered |
| E4.7 | a restart loses the step cache and keeps every cache volume (toolchains, 1,055 module directories, uv's cache, an npm marker) | probe job · Pi | functional × 1 | **verified** — an explicit marker written before and found after |
| E4.8 | the 128 leftover network namespaces are a warm pool (`CNIPoolSize`), not a leak; prefilling costs ~8 s of engine CPU per start | Dagger source + the Pi | 1 × 1 | under-powered |

## §9 Experiment 5 — hits across commits (declared inputs)

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E5.1 | every declared step replayed exactly when its declared files were unchanged, and ran when they changed; none fell back | go-task 6 commits, flask 12 commits · Pi | 4 runs × 2 series | **verified** — the decision is the oracle, and it held across 4 runs |
| E5.2 | enforcement fails loudly rather than replaying a wrong result (two wrong declarations, both failed) | flask · Pi | 2 × 1 | under-powered — two instances; **not proved** (P5 has no proof, the mechanism is shelved) |
| E5.3 | Dagger keys files from a git checkout on their content, and a step's output on how it was made | 4-arm probe · Pi | 4 × 2 sessions | **verified** — the one experiment whose negative control caught its own error (three invalid rounds, `$RANDOM` in a subshell) |
| E5.4 | `withDirectory` with `owner:` costs 21 s on a new 200–240 MB directory, then 1–2 s while the source is unchanged | ~20,000 files · Pi | 4 × 1 | **unverified** as the *new-directory* cost: the probe reused one source directory, so it measured the cached pass; the real runs showed the cost |
| E5.5 | declared inputs cost more than they save: flask 734 s (v3) against 575 s control; go-task 476 s against 258 s | flask 12 commits, go-task 6 · Pi | 4 configurations × 1 series each | under-powered — single series per arm, but +28% and +85% against the control is far outside plausible variance, and the direction is the decision |
| E5.6 | the feature would need about three commits in five to leave the expensive step's inputs alone | derived from per-commit figures of E5.5 | — | **withdrawn** (2026-10-17) — arithmetic on two single readings (22 s saved, 31 s cost), so the ratio has no interval either, and it is a break-even point for a mechanism that is **not running**: E5.5 decided against declared inputs at +28% and +85% against the control, and the feature is shelved. If it is ever revived, the break-even has to come from a measured per-commit distribution rather than from this number |
| E5.7 | v1 → v2 → v3: building a declared container fell from 25–65 s to 1–3 s, applying an output from 2–28 s to under 2 s | flask · Pi | 3 × 1 series | under-powered |

## §10 Experiment 6 — cache volumes and installers that hardlink

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E6.1 | each cache volume is its own filesystem, and two mounts of the *same* volume are too, so no hardlink can cross | `stat` and `ln` inside a job · Pi | 5 paths × 1 | **verified** — direct mechanism, each path its own control |
| E6.2 | a warm `uv sync` takes 27.0 s from the volume against 0.2 s on the workspace's filesystem (135×); pnpm 16.6 s against 1.4 s; npm unaffected at 1.5 s | flask (84 packages, 214 MB `.venv`), pnpm/npm 68 MB · Pi | 6 variants × 1, one job | under-powered — one sample per variant, but 135× and the explicit `UV_LINK_MODE=copy` arm agreeing at 25.4 s make it safe |
| E6.3 | with the environment in uv's cache volume, `uv sync` is 9.2 s on a new ref (was 28.6 s) | flask · Pi | before vs after × 1 | under-powered |
| E6.4 | a warm `uv sync` is 0.5 s here against a hosted runner's 0.8 s — "faster than GitHub" | flask · Pi, `ubuntu-latest` | 3 × 12 | **refuted** (2026-10-17, [measurements/e6.4/](../measurements/e6.4/README.md)) — the hosted runner is **faster**: medians 0.011 s against 0.015 s, difference 0.004 s, 95% CI [0.002, 0.006], 27% of the baseline, with a negative control at exactly 0.000. The original compared the Pi's cheapest case against the hosted runner's most expensive one — see the note below the table |
| E6.5 | relocating the environment broke nothing: `uv run`, `.venv/bin/python`, `activate`, `.venv/bin/pytest`, 134 tests | flask · Pi | functional × 1 | **verified** — four independent paths checked, each pass/fail |
| E6.6 | against a hosted runner *with its own cache on*: 9 s against 151 s on a new branch, 9 s against 30 s on a repeat, 231 s against 151 s on a first run ever | hugo · Pi, `ubuntu-latest` | 3 × 1 | under-powered — the first two margins are ~16× and ~3×; the third (231 vs 151) is close enough that only its direction is safe |
| E6.7 | `setup-go`'s `cache: true` tried to upload 2.7 GB at 2 MB/s and was cancelled at 82% | hugo · Pi | 1 × 1 | under-powered — an existence demonstration, which is all it needs to be |
| E6.8 | pnpm cannot be fixed the same way: `node_modules` must be in the workspace | structural | — | under-powered — an argument from E6.1, not a measurement |

**How E6.4 went wrong, because the mechanism is more useful than the verdict.** It was not noise, and
not a close call misread. The study's own §10 quotes a hosted runner's warm uv *twice*, at two
different numbers, for two different pieces of work: **0.1 s** to install into a fresh `.venv` by
hardlinking from a cache already on the same filesystem, and **0.8 s** for a new job that restores
the cache and then builds `.venv`. E6.4 compared this runner's 0.5 s — reconciling an environment
that already exists in the cache volume, the cheapest thing a sync can do — against the 0.8 s. Had it
used the 0.1 s from the table above it, the same evidence would have said the Pi was five times
*slower*.

So the fault was not the sample size. **Two arms were given different work and the difference was
attributed to the machines.** The re-measurement makes both arms reconcile an environment that is
already there (a `warm` step before the measured one, in the same job), which is the only reading of
"a warm `uv sync`" under which the two machines can be compared at all. Under it, both numbers
collapse to milliseconds — 0.015 s and 0.011 s — and the hosted runner wins by 27%.

Nothing above it falls: E6.2's 135× and E6.3's 28.6 s → 9.2 s measure syncs that do real work, and
are unaffected. What falls is one sentence of comparison, and the habit that produced it.

## §11 Experiment 7 — is the engine the per-step cost?

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E7.1 | per step: raw overlayfs 17.1 ms, Dagger 60–62 ms, so Dagger is ~3.5× a hand-rolled floor and 43 ms a step | 1-step and 21-step runs, fresh nonce each · Pi | 2 levels × slope of 2 points | under-powered — the slope method is right (it excludes startup), the repetitions are not stated and were few |
| E7.2 | BuildKit through the Dockerfile frontend: 207–534 ms a step | as above · Pi | 1 × few | **not a claim** — labelled not comparable in the text (a `RUN` commits a layer, `withExec` does not); kept only for honesty |
| E7.3 | a job's floor is the GitHub protocol, not the engine: 2–4 s a job against 0.6 s a session and 0.1 s of engine CPU | derived from E4.1 and E7.1 | — | **verified** — three independent measurements, and the gap is an order of magnitude |
| E7.4 | 100 steps keep ~202 snapshots, ~1,206 inodes and 13 MB of disk (about 2, 12 and 131 KB a step) | 100 trivial steps · Pi | 2 × 1 batch | under-powered |
| E7.5 | the +279 MB per 100 steps was mostly Go garbage, not a live index; the live set is a couple of hundred MB | 6 more batches of 100 · Pi | 1 × 6 | **verified** — the repeat is the evidence, and it overturned the first reading |
| E7.6 | `GOGC=400` buys nothing measurable on a four-long-step job and costs ~225 MB of heap | flask, fresh engine per arm · Pi | 2 × (1 cold + 3 warm) | **verified** as a null result — repeated, and correctly reported as "no effect found" rather than a trend |
| E7.7 | `GOGC=400` saves ~15% of engine CPU on a step-heavy job (0.90 s of 5.93 s) | 40 trivial steps, each carrying the trial's token · Pi | 2 × 3, interleaved, engine recreated per trial | **verified** — median 5.926 s against 6.825 s, difference +0.899 s, 95% CI [0.751, 1.456] (12.7% to 24.6%); re-run: `measurements/e7.7/` |
| E7.8 | nothing measured — latency, floor, retained state or memory — supports replacing Dagger | E7.1–E7.6 | — | under-powered — a conclusion from the above, no stronger than E7.1 |

## §12 Experiment 8 — test selection for Python

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E8.1 | running under `pytest-testmon` costs ~4× a plain run (227.0 s against 58.5 s) | sqlalchemy, 9,300 tests · Pi | 2 × 1 | under-powered |
| E8.2 | a core-module change selects 79% of the suite and costs 261.8 s, 4.5× the full run it replaces | as above | 1 × 1 | under-powered |
| E8.3 | a leaf-module change selected the same 62 tests as no change | as above | 1 × 1, then 4 arms × 1 | **verified, and the ambiguity resolved** (2026-10-17, [measurements/e8.3/](../measurements/e8.3/README.md)) — the row reproduces exactly, and **testmon did not miss the edit**: editing a function `test/base/test_utils.py` calls selects 25 tests and runs them, editing an uncovered function in the same file selects the same 62 and runs none. 29 of that file's 141 functions are never executed by the suite, so the study's edit landed in uncovered code. Also: those 62 never run — `62 selected` is followed by no pass count — so the unchanged case is cheaper than "62 tests" suggests |
| E8.4 | the runner should do nothing about test selection | decision from E8.1–E8.3 | — | **superseded** in framing — [RELATED.md](RELATED.md) argues (Herzig's THEO) that this is an economic question answered with a mechanics measurement; the mechanics stand, the conclusion does not follow from them alone |

## §S Storage and concurrency — the first claims that did not come from the study

These were not read out of STUDY.md. They start from a measurement — the SD card gains 39%
throughput for 15× the latency at queue depth 16 ([storage](../measurements/storage/README.md)) —
and ask what that costs a pool of runners.

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| S.1 | three runners over-subscribe the disk: two spend 39% less time on contended copying (211 s → 128 s) | 3 × forced-copy flask install · Pi | 3 × 3 | **superseded** by S.2 — the measurement holds (control within 1.6%, interval nowhere near zero) but the conclusion drawn from it does not. It sums *total* contended time, which is a cost and not a speed; see the note below |
| S.2 | a forced-copy install takes 2.7× longer with three running at once: 24.6 s alone against 66.6 s | as above, `max-parallel` 1 vs 3 · Pi | 3 × 5 | **verified** — difference 42.0 s, 95% CI [27.5, 60.1], negative control spanning zero. `io-p1`'s 24.6 s independently reproduces the study's 25.4 s for the same uncontended operation |
| S.3 | flask's test suite takes 1.45× longer with three at once: 4.36 s alone against 6.30 s | 3 × `uv run pytest` · Pi | 3 × 5 | **verified**, with a caveat — difference 1.94 s, 95% CI [1.76, 2.44], but the control came out 6% from the baseline with an interval excluding zero, so this instrument has a ~6% floor and nothing smaller than the 10% threshold should be read from it |

| S.7 | a smaller engine cache cap (10 GB against 20 GB) would reduce page-cache pressure | — | — | **not measurable as framed** — the arms share mutable state that each destroys for the other, and the cap is not currently binding. Designed, built (`concurrency/cap-arm.sh`), and abandoned before spending an hour on a confounded answer; see below. The 20 GB cap stands |
| S.5 | no I/O scheduler is measurably better for this card: `none`, `mq-deadline`, `kyber` and `bfq` within one sweep | `disk.sh` × 4 schedulers · Pi | 4 × 1 | **no effect found at this precision** — qd1 random reads ranged 1903-2441 across schedulers, while *repeated* runs of a single scheduler ranged just as widely (mq-deadline 2375 then 1960; `none` 2099 then 1903; bfq 2125, 2098, 2441). The card's own variance swallows the differences |
| S.6 | this SD card intermittently collapses to a quarter of its write throughput, with eighth-of-a-second stalls | `disk.sh` · Pi | 2 occurrences | under-powered — observed twice, **159 iops with p99 135.3 ms** under `mq-deadline` on an idle disk and **176 iops with p99 132.6 ms** under `bfq`, against 547-702 iops and p99 7-20 ms otherwise. Scheduler-independent and load-independent; the signature of the card's own garbage collection. Two samples, no controlled repetition |
| S.4 | CI on this machine is I/O-bound end to end, so the engine's CPU priority has nothing to arbitrate | `vmstat` through both workloads above · Pi | 2 workloads × ~20 samples | **verified** — runnable processes never exceeded 3 while blocked reached 26, and the CPU was 85-97% idle-waiting in both. `--cpu-shares` cannot help: there is no CPU contention. See below |

**S.7 was abandoned for a reason worth writing down: its arms cannot be interleaved.** The engine's
cache cap governs state that *persists between trials*. A 10 GB trial collects the volume down to
10 GB, destroying cache that the 20 GB trials spent their runs accumulating; the next 20 GB trial
then starts from a cache the other arm emptied. Interleaving — which §3.2.3 requires, so that drift
in the machine cannot be read as a difference between arms — makes each arm sabotage the other.
Blocking the arms to avoid that reintroduces exactly the drift confound interleaving exists to
prevent, and there is no way to restore cache state between trials. Neither design is sound.

Two further reasons not to spend the hour. **The cap is not binding**: at 20 GB the volume sits at
10.61 GB, so nothing is being evicted and the comparison would be "no eviction" against "slight
eviction". And **the instrument is weak**: the first run after an engine restart gave shards of
5.6 s, 21.9 s and 36.2 s for three *serial* runs of identical work — a 6.5× spread with no
contention, because the engine rebuilds state progressively after a restart. Resolving 10% through
that needs many hours.

What stands without measurement is the cap's actual job. The recorded pathology — 67 GB across
17,000 snapshots, whose inode cache crowded out the page cache — happened with **no cap at all**.
The observed working set is 10-19 GB. A 20 GB cap bounds the runaway case while binding on nothing
normal, which is what it was for. `deploy/engine.json` is unchanged and razorbill is back at 20 GB.

**Scheduler tuning is closed, and two of my own explanations died proving it.** `bfq` was tried
because it is the only scheduler offering per-cgroup I/O weights, which looked like the way to stop
CI starving a database and a household of disk. The first reading under it showed 176 write iops
against `mq-deadline`'s 702 — a 4× collapse I attributed to the engine evicting 9 GB of cache at the
same time, since that measurement was not taken on a quiet disk. Then a matched sweep of all four
schedulers produced **159 iops with a p99 of 135 ms under `mq-deadline`, idle**. Same collapse,
different scheduler, no competing load. It is the card, not the scheduler and not contention, and
both of my explanations were wrong.

What the sweep leaves is S.5 and S.6: no scheduler earns its change, and the card has a failure mode
no configuration reaches. `mq-deadline` stays because it is the default, not because it won.

**`--cpu-shares` is not the fix, and [DEPLOY.md](DEPLOY.md) recommending it for a shared machine does
not apply to this one.** The argument for it was that three concurrent jobs take the Pi to load 11 on
four cores, where ssh stops answering and a database and a household's services wait behind CI. That
is true, and the diagnosis was wrong: **load average counts processes blocked in uninterruptible
sleep**, and that is what almost all of those eleven were. Sampled through the disk-bound workload,
`r` was 0 and `b` was 6-19 with 85-97% iowait; sampled through the *compute*-bound one, `r` reached 3
at most while `b` reached 26, because a job is a checkout and a `uv sync` before it is a test run.
User CPU passed 20% twice in forty samples.

So the engine's `cpu.weight` sitting at its default 100 costs nothing, and setting it to 13 would buy
nothing. What would bite is I/O priority, which is **not available as configured**: `io.weight` reads
unavailable and the card's scheduler is `mq-deadline` with `bfq` present but unselected. Enabling it
is a root-level change to a machine that also runs a household, so it is the operator's to make and
then worth measuring the same way.

**Concurrency pays on both workloads, and the returns differ by twenty times.** Per job it costs 2.7×
on the disk-bound work and 1.45× on the compute-bound work; in throughput — three jobs at once
against three in a row, derived from the per-job figures — that is about **1.1× for I/O and 2.1× for
CPU**. So no single `RUNNER_COUNT` is right for both, and the one in use (three) is not wrong: it
simply earns very little on jobs that saturate the disk and most of the available speedup on jobs
that do not.

**What S.1 got wrong is worth keeping.** Its reading was the *sum* of the three shards' copying time,
which falls when fewer run at once — but a sum of work-seconds is a measure of what the disk is made
to do, not of how fast anything finishes. Minimising disk burn and maximising throughput are
different objectives, and "two runners is better" quietly assumed they were the same one. S.2
measures a single shard's duration instead, which is comparable across arms running different numbers
of jobs, and the throughput that falls out of it favours three.

The case for fewer runners is therefore about the rest of the machine rather than about CI: three
concurrent forced-copy installs drive the Pi to **load 11 on four cores**, at which point ssh stops
answering, and this box also serves a database and a household. That is a real reason to cap
concurrency and a different argument from speed. It is also, per S.4, the *only* lever of the two
that works: capping concurrency reduces the disk queue, while capping the engine's CPU priority —
which this note first recommended as the cheaper alternative — arbitrates a resource nothing is
competing for.

Two notes on method, both from failures. S.1's first instrument was the batch's **makespan**, which
could not resolve the question: whole-second API timings, plus however long the third job sat queued,
put the baseline arm's spread at 64-81 s — wider than any difference between arms. And S.1 varied the
pool size by rewriting the systemd unit and restarting, which made trials that took two minutes alone
take **thirty-five** back to back; S.2 and S.3 use `max-parallel` in the workflow instead, so the arms
differ without the machine being touched at all.

## What this says to do next

1. **One unverified claim is left: E5.4.** Of the original eight, E7.7 and E8.3 were re-checked and hold, E3.4 was re-checked and did not hold as stated, E6.4 and W.5 are **refuted**, and E2.7 and E5.6 are **withdrawn** — neither was measurable as written, one being a mechanism offered in prose and the other arithmetic on single samples about a shelved feature. E5.4 is the only one that is a real measurement nobody has made: `withDirectory` with `owner:` on a *new* directory, where the original probe reused one source directory and so timed the cached pass. None is now load-bearing outside the study: the one that was — E6.4 in [SPEC.md](SPEC.md) §6, "faster than GitHub's" — **has been re-checked and is refuted**, and the sentence is gone rather than softened. **E7.7 has also been re-checked and holds**; the measurements are in `measurements/E7.7-gogc-measured.jsonl` and `measurements/E6.4-uv-measured.jsonl`.
2. ~~**E7.7 first**, because it is the only unverified claim that currently decides a deployed setting.~~ **Done**, and so is **E3.4**, the other claim that decided one: it does not hold as stated, and what replaced it (E3.4b) says why output keys stay opt-in and why `RUNNER_OUTPUT_KEYS_MAX_MS` is the right shape of answer. The pilot put a 40-step job's engine CPU at 6.2 s with sd 0.29, so dimensioning asked for three repetitions rather than the nineteen a warm-up round's provisioning made it look like; three interleaved rounds an arm, each recreating the engine, settled it in 13 minutes.
3. ~~**Then E6.4 and W.5**, the two "faster than a hosted runner" claims.~~ **Both are done and both are refuted** — E6.4 on 2026-10-17 and W.5 the same day, the second by exactly the method the first suggested: make both arms do the same work, then measure. Neither needed more repetitions; each needed its arms to be doing the same thing. **Nothing in the documentation now claims this runner beats a hosted one**, and the honest summary of what the Pi buys is in [SPEC.md](SPEC.md) §6: replays and warm caches, not raw speed.
4. **The harness before the rest.** Four commands in this repository cover a handful of the 62 claims; re-checking any of the others means writing the measurement again from the prose. That is MEASURE.md stage 2, and E7.6 and E3.5 are what to validate it against, their answers being known.
5. **Nothing here asks for a design change.** No verdict moved a conclusion: the two decisions resting on unverified numbers (`GOGC=400`, and "faster than a hosted runner" in the docs) are a setting and a sentence, not an architecture. The findings carrying real weight — E6.1's filesystem split, E2.2's secret rule, E5.5's declared-inputs cost — are proved, verified, or very large.
