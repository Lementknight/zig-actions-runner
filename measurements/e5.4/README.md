# E5.4: what does `withDirectory` with `owner:` cost on a new directory?

Audience: whoever re-checks this · Register: [CLAIMS.md](../../docs/CLAIMS.md) E5.4 · Rules:
[MEASURE.md](../../docs/MEASURE.md) §3.2

The study's table: giving a step a 200–240 MB directory of ~20,000 files costs **21 s** with
`owner:` and **1–2 s** without, "then 1–2 s while the source is unchanged". Its own method note
says why the first figure cannot be trusted:

> that probe reused one source directory across its rounds, so it measured a cached ownership pass
> and understated what a *new* directory costs

So the 1–2 s column is measured and the 21 s is not. This is the last claim the register marks
unverified, and the only one of the original eight that was a real measurement nobody had made.

## The answer

```
  root          n=6  median  2.500 s  (baseline)
  user          n=6  median 19.000 s  difference 16.500  95% CI [14.000, 22.000]  effect
  root-control  n=6  median  2.000 s  difference -0.500  95% CI [-2.000,  1.000]  no_effect_found
```

**It holds.** `owner:` costs **16.5 s** on a new 234 MB directory of 20,000 files — interval
[14.0, 22.0], excluding zero and more than three times the 5 s threshold pre-registered before the
harness ran. The step takes 19.0 s with it and 2.5 s without, against the study's 21 s and 1-2 s:
its figures sit inside this interval.

**So the study's number was right and its self-criticism was wrong.** Its method note said the probe
"measured a cached ownership pass and understated what a new directory costs", implying the true
cost was *higher* than 21 s. With every file new, it is 19 s — the figure it recorded and doubted.
That is a fourth way a claim in this register has turned out wrong: not the number, but the apology
attached to it.

The negative control is how the gate is known to have worked. Its interval is **±2 s** here against
**±7 s** in the ungated series, which is the difference between an instrument that can see a 5 s
effect and one that cannot.

### Six readings, not eight, and why that is enough

The gated run was interrupted after 6 of 8 rounds. Re-dimensioning on what it produced asks for
**4** repetitions of the `user` arm (sd 4.49) and 3 of each other — so 6 is already past what the
spread requires, and running the missing two would be repetitions by habit, which §3.2.5 exists to
prevent. The shortfall is recorded here rather than quietly re-run.

## Why it is worth measuring rather than withdrawing

Unlike E2.7 and E5.6, which were withdrawn, this cost is **live**. `withDirectory` with `owner:` is
what hands a Docker action its workspace, at [dagger.zig:4291](../../runner/src/dagger.zig#L4291):

```zig
if (img.user.len > 0) {
    try w.writeAll(",owner:");
```

Every Docker action whose image declares a non-root user pays it, on the whole workspace, and
GitHub's own example action is one — the comment above that line says so. If it costs 20 s on a
large workspace, that is a real per-step cost on this runner and a reason to look at `withExec`
with a `chown`, or at a mount, instead.

## Written before any number existed

- **Direction claimed:** the arm that emits `owner:` is slower.
- **Smallest effect worth acting on: 5 s absolute.** Absolute rather than relative because the
  baseline is 1–2 s, where a relative threshold is meaningless and the step clock is whole seconds.
  5 s is the point at which re-engineering how a Docker action receives its workspace would be worth
  doing; below it, the claim is true but uninteresting.
- **Baseline:** the `root` arm, which emits no `owner:`. The `user` arm's difference must come out
  **positive**, with an interval excluding zero and a median difference over 5 s.
- **Negative control:** `root-control`, a second arm identical to `root`. Its answer is known.

## How `owner:` is isolated

The two arms run **the same action against the same workspace**, and differ only in whether the
action's image declares a user — which is the single condition in the code above. Both actions are
local Dockerfile actions built from the same base image with the same entrypoint; one adds
`USER 1001`. So the runner emits `owner:` for one and not the other, and nothing else about the job
differs.

That is a better instrument than a synthetic Dagger probe would have been: it measures the cost
where the runner actually pays it, and it needs no new tooling on the machine under test.

**The workspace is new every trial.** A step writes ~20,000 files of ~11 KB — about 220 MB, the
study's size — with the trial's token in *every* file, not just one. One token would be enough to
change the directory's digest and defeat the step cache, but it would leave 19,999 blobs already in
the engine, so the copy would be cheap for a reason that has nothing to do with `owner:`. Every file
new is what "a new directory" has to mean here, and it is what the original probe failed to do.

## The instrument, and its resolution

The reading is the measured step's duration from the API, which is **whole seconds** — there is no
in-step clock available, because what is being timed happens while the container is being built,
before the action's entrypoint runs. For a claimed 21 s against 1–2 s that is adequate, and the 5 s
threshold is well clear of it. If the real effect turns out to be 2–3 s, this instrument cannot
settle it and the verdict has to say so rather than round.

## The first series could not see its own effect

Run back to back, this workload defeats itself. The ungated series
(`E5.4-owner-measured.jsonl`, kept) came out:

```
  root          n=8  median  8.500  (baseline)
  user          n=8  median 12.500  difference 4.000  95% CI [-1.000, 11.500]  no_effect_found
  root-control  n=8  median  8.000  difference -0.500  95% CI [-7.500,  5.500]  no_effect_found
```

The **negative control is what makes that readable**. Its point estimate is right (−0.5 s, near
zero as it must be) but its interval is 13 s wide against a 5 s threshold, so the suite demonstrably
could not see a 5 s effect and `no_effect_found` on the `user` arm says nothing about `owner:`.
Without that arm this would have looked like a clean null result.

The cause is in the per-trial environment capture, which is why §3.3 asks for it. W.5's series ran
at a median load of **0.60**; this one at **3.35**, never below 1.89. Every trial writes 234 MB and
the engine is still draining it when the next one starts — the experiment makes the noise it then
cannot see through.

Two lessons, both now in [MEASURE.md](../../docs/MEASURE.md) §5:

- **Dimensioning off a pilot taken in a different machine state under-samples.** The pilot's first
  trials landed while the Pi was still quiet, reported `sd 0.000` on the baseline, and asked for
  three repetitions. Its later trials were already noisy.
- **§3.2.4 separates the first round; that is not enough here.** A workload heavy enough to perturb
  the machine needs the *whole series* gated on machine state, not just its start.

So [`cooldown.sh`](cooldown.sh) waits for the load to fall below a threshold before every trial,
making machine state a controlled variable. It deliberately does not drop caches — that needs root,
and this user's sudo is narrow — and an ssh failure lets the trial run with a warning rather than
failing it, because "I could not tell" must not be recorded as "the machine was busy".

## Cost

Each trial writes 220 MB to the Pi's SD card, which [S.2–S.7](../../docs/CLAIMS.md) established as
the machine's bottleneck, so a trial is minutes rather than seconds. This is the most expensive
measurement in the register.

```sh
./gen-workflows.sh /tmp/e54        # workflows and the two actions, for the test repository
cd ../../runner
zig build measure -- run --claim E5.4 --quantity "a Docker action receiving a new 220 MB workspace, s" \
    --min-effect 5 --control root-control \
    --reps 3 --warmup 1 --out ../measurements/E5.4-owner-pilot.jsonl \
    --environment "../measurements/e5.4/facts.sh zig-pi" \
    --arm "root=../measurements/e5.4/arm.sh <repo> root" \
    --arm "root-control=../measurements/e5.4/arm.sh <repo> root" \
    --arm "user=../measurements/e5.4/arm.sh <repo> user"
```
