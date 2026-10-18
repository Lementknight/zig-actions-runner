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

sqlalchemy builds Cython extensions, so this quantity includes a compile. That is the same work on
both arms and is part of what "install" costs, but it is worth knowing before reading the result:
a win here is partly a win at compiling C, which [W.7](../../docs/CLAIMS.md) says the Pi is ~2.5×
*worse* at.

## A date that matters

`ubuntu-latest` migrates to Ubuntu 26 from **2026-10-19**. A reading taken before that is not
comparable with one taken after, and the hosted arm's own log warns about it. Every line in the
sample file records the date for this reason.
