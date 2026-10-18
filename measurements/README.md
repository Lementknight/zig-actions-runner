# Samples

Audience: whoever re-checks a claim · Harness: `cd runner && zig build measure -- …` ·
Rules: [docs/MEASURE.md](../docs/MEASURE.md) · Register: [docs/CLAIMS.md](../docs/CLAIMS.md)

One JSON line per trial, so a claim can be re-analysed without being re-run — which is the thing
[CLAIMS.md](../docs/CLAIMS.md) found missing from all 62 of the study's claims.

```sh
cd runner
zig build measure -- analyse ../measurements/E7.6-gogc-flask-warm.jsonl \
    --min-effect 0.15 --relative --baseline gogc400
```

A line records the reading **and** what it was taken on: the arm, the round, whether it was a warm-up,
the window it ran in, the trial's token, the identity the command reported, the exit code, and
whatever `--environment` printed. `note` says where a line came from when it was not this harness.

## What is here

| File | Claim | Provenance |
|---|---|---|
| `S.2-io-concurrency.jsonl` | S.2, a forced-copy install with 1 and with 3 jobs at once | **measured** on the Pi, 2026-10-17, by `concurrency/arm.sh` |
| `S.3-cpu-concurrency.jsonl` | S.3, the same sweep on flask's test suite | **measured** on the Pi, 2026-10-17, by `concurrency/arm.sh` |
| `S.1-runners-pilot2.jsonl` | S.1, superseded: total contended copying by `RUNNER_COUNT` | **measured** on the Pi, 2026-10-17, by `concurrency/superseded/arm.sh` |
| `S.1-runners-pilot.jsonl` | S.1's first instrument, makespan, which could not resolve it | **measured** on the Pi, 2026-10-17, by `concurrency/superseded/arm.sh` |
| `S.1-runners-aborted.jsonl` | S.1's confirmation, abandoned after trials went from 2 to 35 minutes | **measured** on the Pi, 2026-10-17; four warm-ups, one reading, two failures |
| `W.5-install-measured.jsonl` | W.5, an editable install from a warm package cache, here against hosted | **measured** 2026-10-17, by `w5/arm.sh` |
| `W.5-install-pilot.jsonl` | W.5's pilot, which chose its repetitions | **measured** 2026-10-17, by `w5/arm.sh` |
| `E6.4-uv-measured.jsonl` | E6.4, a warm `uv sync` here against a hosted runner | **measured** 2026-10-17, by `e6.4/arm.sh` |
| `E6.4-uv-pilot.jsonl` | E6.4's pilot, which chose its repetitions | **measured** 2026-10-17, by `e6.4/arm.sh` |
| `E3.4-outputkeys-measured.jsonl` | E3.4/E3.4b, what output keys cost on a first run | **measured** on the Pi, 2026-10-16, by `e3.4/arm-outputkeys.sh` |
| `E7.7-gogc-measured.jsonl` | E7.7, engine CPU over 40 steps | **measured** on the Pi, 2026-10-16, by `e7.7/arm-gogc.sh` |
| `E7.7-pilot.jsonl` | E7.7's pilot, which is also its negative control | **measured** on the Pi, 2026-10-16, by `e7.7/arm.sh` |
| `E7.6-gogc-flask-warm.jsonl` | E7.6, job seconds on warm re-runs | **transcribed** from STUDY.md §11.2 |
| `E7.6-gogc-flask-cpu.jsonl` | E7.6b, engine CPU for the same arms | **transcribed** from STUDY.md §11.2 |
| `E7.7-gogc-steps.jsonl` | E7.7 as the study recorded it | **transcribed** from STUDY.md §11.2 |

## E7.7, settled

The first claim measured under the protocol rather than read off a counter. `e7.7/` holds all of it:
`gen-workflow.sh` for the workload (40 trivial steps, each carrying the trial's token so nothing is
replayed), `arm-gogc.sh` for a trial (recreate the engine at a given `GOGC`, let the runner
re-register, provision in a throwaway job, then measure), and `facts.sh` for the environment.

```
  gogc400   n=3  median 5.926 s   (baseline)
  gogc100   n=3  median 6.825 s   difference +0.899  95% CI [0.751, 1.456]  effect
```

So `GOGC=400` saves about **15%** of the engine's CPU on a step-heavy job — 0.90 s of 5.93 s, with
the interval running from 12.7% to 24.6%. The study said "roughly 15–20%" from one number per arm;
the direction was right and the size was luck. [CLAIMS.md](../docs/CLAIMS.md) E7.7 is now verified.

The pilot came first, as §3.2.5 asks. Its two arms ran the *identical* command, which makes it the
negative control as well: medians 6.204 s and 6.224 s, CI [−0.284, +0.437], `no_effect_found`. Its
spread (sd 0.29) asked for three repetitions an arm, not the nineteen a warm-up round's provisioning
made it look like before `dimension` learned to exclude warm-ups.

## E3.4, settled — and not as it was stated

The second claim through the harness, and the first the harness overturned. `e3.4/` holds the
workload (a checkout of go-task/task, one step that reads a run-specific value so it is always-run,
and three steps after it, every step carrying the trial's token) and the arm, which is the
operator's flag in the unit file and a restart — no engine recreate, because the token already makes
every step new.

```
  keys_off   n=4  median 1.047 s   (baseline)
  control    n=4  median 0.833 s   difference -0.214  95% CI [-0.250, +0.024]  no_effect_found
  keys_on    n=4  median 2.518 s   difference +1.471  95% CI [+1.356, +1.699]  effect
```

The third arm runs the *identical* command to the baseline, so the suite shows in one run that it can
tell a difference it found from one it did not. Output keys cost **+1.47 s of engine CPU** on a job
whose own work is about a second: 140%, with the interval running from 130% to 162%.

That does not refute "a first run costs about the same" so much as locate it. The cost is roughly
fixed per always-run step, so on the 60 s job the study measured it hid inside the noise, and on a
2 s job it is most of the job. Which is why they stay opt-in, and why
`RUNNER_OUTPUT_KEYS_MAX_MS` — a limit on what they may spend before a repository stops using them —
is the right shape of answer rather than a flag someone sets once.

## The transcriptions, and why they are here

The three `E7.6*`/`E7.7-gogc-steps` files are **transcriptions, not measurements**, and they exist
for one reason: the harness had to agree with answers that were already known before it was trusted
with answers that were not. They carry no environment capture, no windows and no tokens, because the
runs that produced them recorded none — which is itself the finding.

What the harness says about them:

| Claim | Verdict | The study said |
|---|---|---|
| E7.6 | `no_effect_found` (median 9 s against 7 s, CI [−12, +12]) | "buys nothing measurable on this workload" — agrees |
| E7.6b | `no_effect_found` (8.5 s against 9 s, CI [−36, +37]) | the same, for engine CPU — agrees |
| E7.7 | **`not_enough_samples`**, exit code 1 | "saves roughly 15–20%" — **refused** |

E7.7 is the interesting one. Three rounds were run per arm, but only one number per arm was ever
written down, so there is nothing to compute an interval from and the harness will not pretend
otherwise. That is the same conclusion [CLAIMS.md](../docs/CLAIMS.md) reached by reading, reached here
by arithmetic, and it is why `GOGC=400`'s saving no longer appears as a number in
[DEPLOY.md](../docs/DEPLOY.md).

## Taking a new sample set

```sh
zig build measure -- run \
    --claim E7.7 --quantity "engine CPU s" \
    --min-effect 0.15 --relative \
    --reps 5 --warmup 1 --out ../measurements/E7.7-gogc-steps-measured.jsonl \
    --arm 'gogc400=ssh zig-pi ./steps.sh 400' \
    --arm 'gogc100=ssh zig-pi ./steps.sh 100' \
    --control gogc400-again \
    --identity 'gh run list -L1 --json databaseId -q .[0].databaseId' \
    --environment 'ssh zig-pi ./engine-facts.sh'
```

An arm is any command that prints `MEASURE <number>`; the harness supplies `$MEASURE_TOKEN`, which
belongs somewhere the system under test cannot ignore — for this runner, inside a step's script text,
since that is part of its cache key. `--min-effect` is required, so the answer that would refute the
claim exists before the first number does.

## E6.4, refuted

The first claim the protocol has *overturned* rather than confirmed or narrowed. `e6.4/` holds it:
`gen-workflows.sh` for the two workflows (identical but for `runs-on`), `arm.sh` for a trial, and
`facts.sh` for the environment.

```
  pi          n=12  median 0.015 s  (baseline)
  hosted      n=12  median 0.011 s  difference -0.004  95% CI [-0.006, -0.002]  effect
  pi-control  n=13  median 0.015 s  difference  0.000  95% CI [-0.002,  0.003]  no_effect_found
```

The study said a warm `uv sync` was 0.5 s here against a hosted runner's 0.8 s. It is **0.015 s here
against 0.011 s**, and the hosted runner is 27% faster. The negative control — a second arm
identical to the baseline — came out at exactly 0.000, which is what makes the rest of it worth
reading.

**The lesson is about arms, not samples.** The original did not fail for want of repetitions: it
compared this runner reconciling an environment that already existed against a hosted runner
restoring a cache and building `.venv`. Two different jobs of work, one difference attributed to the
machines. [CLAIMS.md](../docs/CLAIMS.md) E6.4 has the full account, including that the study's own
table gives the same hosted runner's warm uv as 0.1 s for a third quantity — which would have
reversed the claim on the study's own evidence.

The pilot is kept because it shows the other half of this. At n=3 the Pi's median was 0.035 s with
`sd 0.019`, and the difference looked like 3×; at n=12 the median is 0.015 s with `sd 0.002` and the
difference is 27%. The direction was right from the pilot — the two arms' readings never
overlapped — and the size was not.

## W.5, refuted — and that is both of them

The second refutation, the same day as the first, and the study's other "faster than a hosted
runner" claim. `w5/` holds it, in the same four pieces as `e6.4/`.

```
  pi          n=10  median 3.073 s  (baseline)
  hosted      n=10  median 2.154 s  difference -0.919  95% CI [-1.538, -0.881]  effect
  pi-control  n=10  median 3.064 s  difference -0.009  95% CI [-0.031,  0.374]  no_effect_found
```

The study said sqlalchemy's install was 21.0 s here against 28.2 s hosted. Give both machines a warm
package cache and it is **3.073 s here against 2.154 s** — the hosted runner faster by 30%, with the
arms not overlapping anywhere: every hosted reading is below every Pi reading.

**It failed the same way E6.4 did, and the study said so without noticing.** The sentence explaining
why the Pi won — the registry is warm here "while the hosted runner downloads from PyPI each time" —
is a description of the arms doing different work. Removing the downloads removes 90% of the
quantity: the install is 2-3 s on either machine, so the 7.2 s margin was never about installing.

Two things this one added that E6.4 did not:

- **The pre-registration was committed before the harness ran** (`be87bdf`), so "written before any
  number existed" can be checked rather than taken on trust. Two of its statements then turned out
  wrong — it predicted a Cython compile that does not happen, and expected a quantity ten times
  larger than the real one — and both corrections are in the history rather than quietly edited in.
- **The Pi arm failed first, on this runner's own feature.** The workload deleted `.venv` to force a
  fresh install, but here `.venv` is a symlink into uv's cache volume, so that removed the link and
  left the environment. It deletes the symlink's target instead. A measurement of a runner has to
  know what the runner does to the thing being measured.

`pi-control` carries one oddity: `sd 0.351` against `pi`'s `0.019`, from two readings near 3.9 s on
the same machine running the same command. It did not change the verdict — both are still above
every hosted reading — but nothing here explains it.
