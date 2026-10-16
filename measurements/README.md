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
| `E7.6-gogc-flask-warm.jsonl` | E7.6, job seconds on warm re-runs | **transcribed** from STUDY.md §11.2 |
| `E7.6-gogc-flask-cpu.jsonl` | E7.6b, engine CPU for the same arms | **transcribed** from STUDY.md §11.2 |
| `E7.7-gogc-steps.jsonl` | E7.7, engine CPU over 40 steps | **transcribed** from STUDY.md §11.2 |

**All three are transcriptions, not measurements**, and they are here for one reason: the harness has
to agree with answers that are already known before it is trusted with answers that are not. They
carry no environment capture, no windows and no tokens, because the runs that produced them recorded
none — which is itself the finding.

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
