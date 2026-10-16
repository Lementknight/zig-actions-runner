# Properties, against a real engine

Audience: whoever changes the caching · Proved: [proofs/](../proofs/README.md) · Rules:
[docs/MEASURE.md](../docs/MEASURE.md) §4

```sh
./properties/gen-workflows.sh /tmp/props          # the workloads, for installing in a test repository
./properties/check.sh <owner>/<repo> [P2|P3|P4|P6|all]
```

Stage 3 of [MEASURE.md](../docs/MEASURE.md): the properties the model proves, checked against an
engine on a real runner. The model says which cases matter and what each must assert, so this does
not have to guess; what it adds is that the *implementation* does what the model says, which no proof
can establish.

The signal is per step and comes from GitHub's own logs: a replayed step carries
`dagger.reused_note` — "Reused from Dagger's cache: this step's inputs were unchanged since an
earlier run…" — so a check is a dispatch, a wait, and a `grep`. Nothing needs the Pi's journal.

## The checks, and what each is the counterpart of

| Check | Varies | Asserts | Proved as |
|---|---|---|---|
| P3 | nothing — but the run id differs by construction | the subject was **replayed** | `volatile-invisible` |
| P6 | nothing | **every** step was replayed | `warm-runs-nothing` |
| P2a | the subject's script text | the subject **ran** | `text-matters` |
| P2b | the workspace (a different commit of go-chi/chi) | the subject **ran** | `parent-matters` |
| P2c | a non-volatile variable the subject sees | the subject **ran** | `stable-env-matters` |
| P2d | the subject's position in the job, and nothing else | the subject **ran** | `position-matters` |
| P4 | the subject names `GITHUB_RUN_ID`, twice over | the subject **ran** both times | `marked-misses` |

P2d needs the second workflow, `property-shifted.yml`, which is `property.yml` with one more step
before the subject. A skipped step still occupies its place in a job, so an `if:` cannot move the
subject; only a different workflow can.

**The suite cannot pass vacuously**, which matters for a suite that passes everything: it asserts
both polarities. P3 and P6 fail unless the note is *present*, P2 and P4 fail unless it is *absent*,
so a discriminator that always said one thing would fail half of them. Checked directly on the first
run of it: of six dispatches, the note appeared on exactly the one with identical inputs and on none
of the five that changed one.

## What is not here yet

- **P1** (replay equals run) wants the same job twice, once with `ZIG_RUNNER_STEP_CACHE: false`, and
  the step logs, file commands and conclusions compared. Cheap to add, since the opt-out is per
  workflow.
- **P3 for a mounted cache volume**, which needs a package cache written between two runs.
- **P5**, which needs the shelved `feat/declared-inputs-v2`.
- **Early cutoff**, **pruning**, **a shared cache** and **`$GITHUB_ENV`** — the rest of the
  obligations table in [proofs/README.md](../proofs/README.md).
- **Three checks that must fail**, which is the point of generating them: counterexample 1's indirect
  volatile read, counterexample 3's flaky step, and counterexample 4's cache-volume read are what
  this design cannot detect. When one starts passing, something has changed.

## Why this cannot run in CI

The engine lives on the self-hosted runner, so these checks need that runner and a repository it is
registered to. CI has neither. They are a manual suite for now, which is why the mapping above
matters: a human has to be able to tell what a failure means.
