# Claim registry: what each number in the study rests on

Audience: whoever is about to cite a number, or re-check one · Companion: [MEASURE.md](MEASURE.md)
(the rules), [STUDY.md](STUDY.md) (the claims), [proofs/](../proofs/README.md) (the properties) ·
[DESIGN.md](DESIGN.md) for what was decided on them

[MEASURE.md](MEASURE.md) §3.1 asks that every performance claim have an entry naming what was
measured, on what, against what, how many times, and how to run it again — and that a claim without
one be marked unverified and not used to justify a change. This is that register, built by reading
STUDY.md against §3.2 after the fact.

**63 claims: 19 verified, 32 under-powered, 6 unverified, 3 superseded, 2 proved, 1 withdrawn.** The
one-line summary: *little here is wrong, and little is measured to the standard MEASURE.md sets.* The
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
  justify a change** until re-checked. Each of the eight says what is wrong with it.
- **Withdrawn** — run and recorded, but not comparable to what it was compared against. One: E7.2.
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
| W.5 | sqlalchemy install 21.0 s here against 28.2 s hosted ("faster than a hosted runner") | sqlalchemy · Pi, hosted | 1 × 1 | **unverified** |
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
| E2.7 | the other half of that warm-up "probably comes from a different Go patch version" | — | — | **unverified** — stated as unverified in the text, and it still is |

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
| E5.6 | the feature would need about three commits in five to leave the expensive step's inputs alone | derived from per-commit figures of E5.5 | — | **unverified** — an estimate from single samples; the per-commit saves and costs (22 s, 31 s) have no interval |
| E5.7 | v1 → v2 → v3: building a declared container fell from 25–65 s to 1–3 s, applying an output from 2–28 s to under 2 s | flask · Pi | 3 × 1 series | under-powered |

## §10 Experiment 6 — cache volumes and installers that hardlink

| ID | Claim | Workload · machine | Arms × reps | Verdict |
|---|---|---|---|---|
| E6.1 | each cache volume is its own filesystem, and two mounts of the *same* volume are too, so no hardlink can cross | `stat` and `ln` inside a job · Pi | 5 paths × 1 | **verified** — direct mechanism, each path its own control |
| E6.2 | a warm `uv sync` takes 27.0 s from the volume against 0.2 s on the workspace's filesystem (135×); pnpm 16.6 s against 1.4 s; npm unaffected at 1.5 s | flask (84 packages, 214 MB `.venv`), pnpm/npm 68 MB · Pi | 6 variants × 1, one job | under-powered — one sample per variant, but 135× and the explicit `UV_LINK_MODE=copy` arm agreeing at 25.4 s make it safe |
| E6.3 | with the environment in uv's cache volume, `uv sync` is 9.2 s on a new ref (was 28.6 s) | flask · Pi | before vs after × 1 | under-powered |
| E6.4 | a warm `uv sync` is 0.5 s here against a hosted runner's 0.8 s — "faster than GitHub" | flask · Pi, `ubuntu-latest` | 1 × 1 | **unverified** — a 0.3 s margin on one sample each, across two machines; this one is quoted in SPEC.md §6 and should not be |
| E6.5 | relocating the environment broke nothing: `uv run`, `.venv/bin/python`, `activate`, `.venv/bin/pytest`, 134 tests | flask · Pi | functional × 1 | **verified** — four independent paths checked, each pass/fail |
| E6.6 | against a hosted runner *with its own cache on*: 9 s against 151 s on a new branch, 9 s against 30 s on a repeat, 231 s against 151 s on a first run ever | hugo · Pi, `ubuntu-latest` | 3 × 1 | under-powered — the first two margins are ~16× and ~3×; the third (231 vs 151) is close enough that only its direction is safe |
| E6.7 | `setup-go`'s `cache: true` tried to upload 2.7 GB at 2 MB/s and was cancelled at 82% | hugo · Pi | 1 × 1 | under-powered — an existence demonstration, which is all it needs to be |
| E6.8 | pnpm cannot be fixed the same way: `node_modules` must be in the workspace | structural | — | under-powered — an argument from E6.1, not a measurement |

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
| E8.3 | a leaf-module change selected the same 62 tests as no change | as above | 1 × 1 | **unverified** — the text says so: either testmon missed it or no test covers the edit, and which was never checked |
| E8.4 | the runner should do nothing about test selection | decision from E8.1–E8.3 | — | **superseded** in framing — [RELATED.md](RELATED.md) argues (Herzig's THEO) that this is an economic question answered with a mechanics measurement; the mechanics stand, the conclusion does not follow from them alone |

## What this says to do next

1. **Stop citing the six unverified claims** until they are re-checked: W.5, E2.7, E5.4, E5.6, E6.4, E8.3. One is load-bearing outside the study — E6.4 in [SPEC.md](SPEC.md) §6 ("faster than GitHub's") — and is softened where it is cited. **E7.7 has been re-checked and holds**: it was the first claim through the harness, and the measurement is in `measurements/E7.7-gogc-measured.jsonl`.
2. ~~**E7.7 first**, because it is the only unverified claim that currently decides a deployed setting.~~ **Done**, and so is **E3.4**, the other claim that decided one: it does not hold as stated, and what replaced it (E3.4b) says why output keys stay opt-in and why `RUNNER_OUTPUT_KEYS_MAX_MS` is the right shape of answer. The pilot put a 40-step job's engine CPU at 6.2 s with sd 0.29, so dimensioning asked for three repetitions rather than the nineteen a warm-up round's provisioning made it look like; three interleaved rounds an arm, each recreating the engine, settled it in 13 minutes.
3. **Then E6.4 and W.5**, the two "faster than a hosted runner" claims. Both are single samples with margins under 30%, across machines we do not control, and both are quotable in a way that invites being quoted.
4. **The harness before the rest.** Four commands in this repository cover a handful of the 62 claims; re-checking any of the others means writing the measurement again from the prose. That is MEASURE.md stage 2, and E7.6 and E3.5 are what to validate it against, their answers being known.
5. **Nothing here asks for a design change.** No verdict moved a conclusion: the two decisions resting on unverified numbers (`GOGC=400`, and "faster than a hosted runner" in the docs) are a setting and a sentence, not an architecture. The findings carrying real weight — E6.1's filesystem split, E2.2's secret rule, E5.5's declared-inputs cost — are proved, verified, or very large.
