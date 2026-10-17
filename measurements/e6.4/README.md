# E6.4: is a warm `uv sync` here faster than on a hosted runner?

Audience: whoever re-checks this · Register: [CLAIMS.md](../../docs/CLAIMS.md) E6.4 · Rules:
[MEASURE.md](../../docs/MEASURE.md) §3.2

The study's number: **0.5 s here against 0.8 s on `ubuntu-latest`**, one sample each, which
[CLAIMS.md](../../docs/CLAIMS.md) marks unverified — a 0.3 s margin, on two machines, from single
samples. It is the one unverified claim quoted outside the study: [SPEC.md](../../docs/SPEC.md) §6
says "faster than GitHub", hedged in place but still said.

## Written before any number existed

- **Direction claimed:** this runner is faster.
- **Smallest effect worth acting on: 20% relative.** Below that, two different machines' warm syncs
  are "in the same range" — which is what STUDY.md §11 already hedges to — and the sentence in
  SPEC.md §6 comes out. The claim's only job is rhetorical: the decision it sits next to
  (`RUNNER_UV_ENV_IN_CACHE` on by default) rests on E6.2 and E6.3, which are 135× and 3×, not on
  beating a hosted runner.
- **Baseline:** the `pi` arm, so the `hosted` arm's difference must come out **positive** with an
  interval excluding zero for the claim to stand.
- **Negative control:** `pi-control`, a second arm identical to `pi`. Its answer is known — it must
  match the baseline. If the harness calls it an effect, the suite failed whatever the hosted arm
  says.

## What is measured, and the two departures from how the study did it

`uv sync` timed by the clock inside the step, in milliseconds, because the API's step timings are
whole seconds and the quantity is under one.

**The measured sync is warmed inside its own job.** The study compared a re-run here against a
re-run on a hosted runner, and those are not the same quantity: this runner keeps the project
environment in uv's cache volume, so a re-run reconciles an environment that is already correct,
while a hosted runner's workspace is new every job, so its "re-run" rebuilds `.venv` by hardlinking
from a warm cache. One is a no-op and the other is work, and comparing them is most of why the
number was never trustworthy. A `warm` step before the measured one makes both arms reconcile an
environment that is already there.

**Both sync steps carry the trial's token**, which is in the script text and so in the step's cache
key. Without it this runner's arm would measure a replay rather than a sync. The hosted arm has no
step cache and ignores it.

## The answer

```
  pi          n=12  median 0.015 s  (baseline)
  hosted      n=12  median 0.011 s  difference -0.004  95% CI [-0.006, -0.002]  effect
  pi-control  n=13  median 0.015 s  difference  0.000  95% CI [-0.002,  0.003]  no_effect_found
```

**Refuted in direction.** The hosted runner is faster by 4 ms, 27% of the baseline, with an interval
excluding zero and the negative control at exactly 0.000. 40 of the 45 dimensioned trials completed
(the run was interrupted); at 12 samples an arm every arm's `sd` had fallen to 0.002, and
re-dimensioning asks for 3 repetitions for a ±0.003 s half-width, so the shortfall costs nothing.

The pilot (`E6.4-uv-pilot.jsonl`, n=3) had the direction right and the size badly wrong — 3× rather
than 27%, from a Pi median of 0.035 s with `sd 0.019`. The direction was safe there only because the
two arms' readings never overlapped: every Pi-side reading of both Pi arms exceeded every hosted
reading.

## Running it

```sh
./gen-workflows.sh /tmp/e64          # then install both in the test repository
cd ../../runner
zig build measure -- run --claim E6.4 --quantity "warm uv sync s" \
    --min-effect 0.20 --relative --baseline pi --control pi-control \
    --reps 3 --warmup 1 --out ../measurements/E6.4-uv-pilot.jsonl \
    --arm "pi=../measurements/e6.4/arm.sh <repo> pi" \
    --arm "pi-control=../measurements/e6.4/arm.sh <repo> pi" \
    --arm "hosted=../measurements/e6.4/arm.sh <repo> hosted"
```

The warm-up round is where both machines' caches become warm: this runner's project environment is
created in the cache volume on first use, and the hosted arm's uv cache is restored by `setup-uv`
only once there is one to restore. Those first readings are recorded and excluded, as MEASURE.md
§3.2.4 requires.

**The hosted arm costs Actions minutes**, because the test repository is private. Each trial is a
flask checkout plus two syncs, a couple of minutes.
