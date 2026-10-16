# The step cache, in Agda

Audience: whoever changes the caching, or doubts it · Companion: [MEASURE.md](../docs/MEASURE.md),
[RELATED.md](../docs/RELATED.md), [SPEC.md](../docs/SPEC.md) §6

[MEASURE.md](../docs/MEASURE.md) §4 lists six properties the caching must *have* rather than merely
measure. No benchmark can establish one of them: a measurement says a step was replayed quickly, not
that replaying it was right. These modules state them and prove them, and for each hypothesis a
proof needs, they give a concrete job where dropping it makes the cache hand back an answer that
running would not have given.

```
./check.sh        # needs `brew install agda`; nothing else, no standard library
```

Every module is `--safe`: no postulates, no holes, no `trustMe`. A clean run is the whole claim.

## What is modelled, and what it is in the code

| In the model | In the runner |
|---|---|
| `Script = body text num` | the script text *and the step's position*, which `containerScript` writes in as `echo '<marker>begin <n>'` |
| `stamped t s` | the always-run marker, `: 'zig-runner runs this step every time: … (run <nonce>)'`, written into the script so it lands in the key |
| `Trial` | one job's nonce: `run_nonce` is the run id, the attempt **and** the job |
| `Key = parent · script · stable env` | the exec recipe: `loadContainerFromID` + `withEnvVariable` + `withExec` |
| `stable` drops volatile names | `withVolatileVariable` for the names in `volatile_env` |
| `Input.mounts`, absent from the key | `withMountedCache`: BuildKit leaves mounts out of an exec's key |
| `mark st = everyRun` | `readsRunSpecific`, plus the secret and OIDC reasons, which are the same case |
| `look`, `apply` | the engine reusing an exec whose key it has seen |
| `Progress.ran` | the `N of M steps replayed from the cache` line |

Two choices are deliberate and worth arguing with. The key is modelled as a *projection*, not as a
hash, so collisions are out of scope rather than silently assumed away. And `exec` takes the trial as
well as the input, so a step is **not** forced to be a function of its inputs — a flaky test is a
well-typed inhabitant, which is why determinism has to be asked for by name.

## What is proved

| MEASURE.md | Statement | Where |
|---|---|---|
| **P1** replay equals run | `replay≡run` | `Runner/Build.agda` |
| **P2** a changed input invalidates | `text-matters`, `position-matters`, `parent-matters`, `stable-env-matters` | `Runner/Build.agda` |
| **P3** an excluded input does not | `mounts-invisible`, `volatile-invisible` | `Runner/Build.agda` |
| **P4** volatile ⇒ always-run | `marked-misses`, and `Marked` for the whole mechanism | `Runner/Build.agda`, `Runner/Counterexamples.agda` |
| **P6** minimality | `hit-keeps-ran`, `warm-runs-nothing` | `Runner/Build.agda` |

P1 is the one that matters: *a job run against a cache left by other jobs ends in the same state as
the same job with the step cache off, step for step.* It needs two hypotheses.

**`Disciplined`** — for a step the runner does not mark, inputs agreeing on everything the key keeps
give the same result. It bundles three obligations: the step is deterministic, it does not consult a
volatile variable, and it does not depend on the content of a mounted cache volume. The runner
enforces none of them; it marks the steps it can detect and relies on this for the rest.

**`Numbered`** — the job's steps are numbered, which `containerScript` does by writing the position
into the script.

Everything else the proof uses is bookkeeping the implementation already does (`Coherent`: entries
are honest; `Ahead`: the cache holds nothing yet for the steps still to come).

## What the counterexamples establish

Each is a complete, computing job in `Runner/Counterexamples.agda`.

| # | The step | What happens | Which hypothesis |
|---|---|---|---|
| 1 | reads `GITHUB_RUN_ID` without naming it | job 2 is handed job 1's answer and runs nothing | `Disciplined` |
| 3 | a flaky test, unmarked | job 1 passed, so job 2 "passes" without running | `Disciplined` |
| 4 | reads a cache volume, unmarked | replayed although the volume changed between jobs | `Disciplined` |
| 5 | two steps sharing a number | the second is replayed from the first, *marked or not* | `Numbered` |

And 2 is the positive one: declare the read, and the marker makes the key new, so the step runs and
agrees with running.

## Three things this turned up

- **The step number in the log marker is load-bearing for correctness.** The always-run nonce is per
  job, so two marked steps in one job carry the *same* marker; what keeps them from collapsing into
  one run is the position in the script text. Counterexample 5 is what a tidy-up of that marker would
  buy. Nothing in `dagger.zig` said so before this.
- **Replay hides flakiness by construction**, not by omission. `disciplined⇒deterministic` derives
  determinism from the hypothesis P1 needs, so the step cache is sound only for jobs with no flaky
  unmarked step — and a replayed step cannot fail. [RELATED.md](../docs/RELATED.md) noted we had
  never measured flakiness; this says measuring it needs the cache off.
- **The documented gap is a correctness gap.** [SPEC.md](../docs/SPEC.md) §6 already says a script
  that reads run-specific values from a file in the repository is "not detected". Counterexample 1
  shows what that costs: not a slower job, a wrong one.

## What this does not model

Not proof of anything about: hash collisions (the key is a projection); **output keys**, the
constructive-trace mechanism, so no early-cutoff property yet; **P5** and declared inputs, shelved on
`feat/declared-inputs-v2`; `GITHUB_ENV` and `GITHUB_PATH` feeding the next step's environment;
concurrency across the pool, and the engine's garbage collection; anything bash does; and every
question of *cost* — nothing here says a replay is faster, only that it is right.

`Step.reads` is the set of names a script really consults. `readsRunSpecific` approximates it by
looking for the name in the text, so the model's `mark` is an idealisation of the runner's, and
counterexample 1 is exactly the distance between them.

## Next

Stage 3 of [MEASURE.md](../docs/MEASURE.md) wants these as generated tests against a real engine. The
statements above are what to generate from: P2 and P3 are a metamorphic pair over one input kind at a
time, and P4 is `marked-misses` with a real nonce. Then output keys, which need the model extended
with content digests before the early-cutoff claim means anything.
