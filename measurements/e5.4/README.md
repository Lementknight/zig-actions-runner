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
