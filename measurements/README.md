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
