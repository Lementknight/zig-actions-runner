# W.5: is installing sqlalchemy here faster than on a hosted runner?

Audience: whoever re-checks this · Register: [CLAIMS.md](../../docs/CLAIMS.md) W.5 · Rules:
[MEASURE.md](../../docs/MEASURE.md) §3.2

The study's number: **21.0 s here against 28.2 s on `ubuntu-latest`**, one sample each. It is the
last of the two "faster than a hosted runner" claims still standing — the other, E6.4, was
re-checked and **refuted**, and for a reason that applies here too.

## Why this is the same mistake as E6.4, before any new number

E6.4 failed not on sample size but because the arms were given **different work**: the Pi's cheapest
case against hosted's most expensive. W.5's own sentence in [STUDY.md](../../docs/STUDY.md) §2
concedes the same shape of asymmetry in writing:

> the environment lives in uv's cache volume so uv hardlinks into it, and the registry is warm,
> while the hosted runner downloads from PyPI each time

One arm installs from a local cache; the other downloads from PyPI. That is a comparison of cache
states, not of machines, and the margin it produced (7.2 s, 26%) is smaller than what a cold package
cache costs. So the re-check makes both arms install from a **warm** package cache, which is also
what [CLAIMS.md](../../docs/CLAIMS.md) §"What this says to do next" asks for: make both arms do the
same thing, then measure, rather than adding repetitions to the old comparison.

## Written before any number existed

- **Direction claimed:** this runner is faster.
- **Smallest effect worth acting on: 20% relative.** The same threshold E6.4 used, for the same
  reason: below that, two different machines installing the same packages are "in the same range",
  and the claim's only job is rhetorical. Nothing is configured differently either way — W.5
  decides no setting, which is why it was safe to leave unverified this long.
- **Baseline:** the `pi` arm, so the `hosted` arm's difference must come out **positive** with an
  interval excluding zero for the claim to stand.
- **Negative control:** `pi-control`, a second arm running the identical command on the same
  machine. Its answer is known — it must come out as no effect against `pi`. If the harness calls
  that pair an effect, the suite is wrong and the hosted arm's answer does not matter.

## The answer

```
  pi          n=10  median 3.073 s  (baseline)
  hosted      n=10  median 2.154 s  difference -0.919  95% CI [-1.538, -0.881]  effect
  pi-control  n=10  median 3.064 s  difference -0.009  95% CI [-0.031,  0.374]  no_effect_found
```

**Refuted in direction.** The hosted runner is faster by 0.92 s — **30%** of the Pi's time, with the
interval running from 29% to 50% and excluding zero, against a pre-registered threshold of 20%. The
negative control came out as known, which is what licenses reading the third line at all.

The arms do not overlap anywhere: every hosted reading (max 2.400 s) is below every Pi reading (min
3.063 s). Re-dimensioning at n=10 asks for 17 repetitions on the hosted arm for a ±0.2 s half-width,
which this is short of — but a separation with no overlap does not depend on the interval's width,
and the direction is what the claim asserted.

So **both** of the study's "faster than a hosted runner" claims are now refuted, and for the same
reason each time: the Pi was measured with its caches warm against a hosted runner with its caches
cold. W.5's 7.2 s margin was a slice of PyPI download time. With nothing to download, the whole
install is 2-3 s and the Pi is the slower machine — which is what W.7 ("~2.5× slower at compiling")
would have predicted for any CPU-and-disk-bound quantity.

One oddity worth recording: `pi-control` has `sd 0.351` against `pi`'s `0.019`, from two readings of
3.985 s and 3.807 s in rounds 2 and 6. Same machine, same command, nothing else running — so the
Pi's install occasionally takes 25% longer for a reason this measurement does not identify. It did
not change the verdict (both outliers are still above every hosted reading) but it is the kind of
variance that S.6's write collapse also showed, and it is in the sample file for anyone who wants it.

## What "warm on both" has to mean here, and why it is not E6.4's warm

E6.4 measured a warm `uv sync`: an environment that is already correct being reconciled, which is
nearly a no-op. W.5's quantity is an **install** — building the environment — so warming it the way
E6.4 did would measure the wrong thing entirely.

So the warm-up populates the **package cache** and the measured step still builds the environment
from scratch:

1. `warm` — create a virtualenv, install sqlalchemy editable with its test dependencies, then
   **delete the virtualenv**. What survives is uv's package cache, on both machines.
2. `measured install` — create the virtualenv again and install again, timed. Every wheel now comes
   from the local cache on both arms, so what is left in the number is the machine: unpacking,
   hardlinking or copying, building sqlalchemy's extensions, and the disk underneath.

The network is deliberately taken out of the comparison. The study's margin was partly PyPI
round-trips on one side and none on the other, and no amount of repetition fixes that.

Both steps carry the trial's token, which is in the script text and therefore in the step's cache
key, so this runner's arm cannot serve a replay instead of installing. The hosted arm has no step
cache and ignores it.

## The workload, pinned

sqlalchemy at `7b95e267c867f9e35ee0aba7e637f373522b0e1d`, installed editable with the test
dependencies its own `tox.ini` lists (`pytest`, `pytest-xdist`, `greenlet`, `typing-extensions`) and
the `asyncio` extra. The study said "editable with test deps" without recording the command, so this
is a *definition* of that phrase rather than a reproduction of it — which is fine for the question
being asked, since both arms run the identical command, but it means the new number is not
arithmetically comparable with 21.0 s and 28.2 s. What is comparable is the **direction**, which is
all the claim asserts.

**No compile is involved**, which the pre-registration first got wrong. sqlalchemy builds Cython
extensions only when Cython is present at build time, and an editable install from a bare checkout
has none: the hosted smoke trial logged `Built sqlalchemy` in 1.06 s of a 2.145 s install. So this
is a pure-Python install — resolve, unpack, link, write the editable hook — and not, as first
written here, partly a measurement of compiling C.

That also resizes the question. With both package caches warm the whole install is **about two
seconds**, against the study's 21.0 s and 28.2 s. Nearly all of what the study measured was
therefore PyPI download time on the hosted side, and W.5's 7.2 s margin was a slice of a cost that
disappears once both arms have the wheels locally. 20% of 2 s is 0.4 s, which the in-step
millisecond clock resolves comfortably.

## Where the environment lives, which is not the same on the two machines

On this runner `.venv` in the workspace is a **symlink into uv's cache volume**
(`uv_env_in_cache`, on by default — E6.1 to E6.3); on a hosted runner it is a real directory on the
workspace filesystem. Both arms are left as they actually run, because that is what "faster than a
hosted runner" has to mean, but it is a difference the number contains and E6.2 says which way it
cuts: a sync against the volume took 27.0 s where the workspace filesystem took 0.2 s. If this arm
loses, the volume is a candidate reason, and forcing the environment into the workspace would be the
follow-up rather than a correction.

The first attempt at this workload deleted `.venv` to force a fresh install, which on this runner
removes the *symlink* and leaves the environment — so the measured step had nowhere to create one and
failed with "No virtual environment found". The workload deletes the symlink's target instead.

## A date that matters

`ubuntu-latest` migrates to Ubuntu 26 from **2026-10-19**. A reading taken before that is not
comparable with one taken after, and the hosted arm's own log warns about it. Every line in the
sample file records the date for this reason.
