# The step cache, in Agda

Audience: whoever changes the caching, or doubts it · Companion: [MEASURE.md](../docs/MEASURE.md),
[RELATED.md](../docs/RELATED.md), [SPEC.md](../docs/SPEC.md) §6

[MEASURE.md](../docs/MEASURE.md) §4 lists six properties the caching must *have* rather than merely
measure. No benchmark can establish one of them: a measurement says a step was replayed quickly, not
that replaying it was right. These modules state them and prove them, and for each hypothesis a proof
needs, they give a concrete job where dropping it makes the cache hand back an answer that running
would not have given.

```
./check.sh        # needs `brew install agda`; nothing else, no standard library
```

Every module is `--safe`: no postulates, no holes, no `trustMe`. A clean run is the whole claim. CI
checks it on every pull request.

## What is modelled, and what it is in the code

| In the model | In the runner |
|---|---|
| `State`: a container *is* the recipe that built it | Dagger's container id is a lazy description; two containers built the same way have the same key |
| `afterCopy before digest` | `outputKeyed`: the container before an always-run step, with what it produced copied in by content digest |
| `Script = body text num` | the script text *and* the step's position, which `containerScript` writes in as `echo '<marker>begin <n>'` |
| `stamped t s` | the always-run marker, `: 'zig-runner runs this step every time: … (run <nonce>)'`, written into the script so it lands in the key |
| `Trial` | one job's nonce: `run_nonce` is the run id, the attempt **and** the job |
| `Key = parent · script · stable env` | the exec recipe: `loadContainerFromID` + `withEnvVariable` + `withExec` |
| `stable` drops volatile names | `withVolatileVariable` for the names in `volatile_env` |
| `Input.mounts`, absent from the key | `withMountedCache`: BuildKit leaves mounts out of an exec's key |
| `Output = log · digest` | what the step wrote, and `changes(from:).layer.digest` |
| `mark st = everyRun` | `readsRunSpecific`, plus the secret and OIDC reasons, which are the same case |
| `Keys = on \| off` | `RUNNER_OUTPUT_KEYS` |
| `Progress.ran` | the `N of M steps replayed from the cache` line |

Two choices are deliberate and worth arguing with. The key is modelled as a *projection*, not a hash,
so collisions are out of scope rather than silently assumed away. And `exec` takes the trial as well
as the input, so a step is **not** forced to be a function of its inputs — a flaky test is a
well-typed inhabitant, which is why determinism has to be asked for by name.

## What is proved

| MEASURE.md | Statement | Where |
|---|---|---|
| **P1** replay equals run | `replay≡run`, for output keys on and off alike | `Runner/Build.agda` |
| **P2** a changed input invalidates | `text-matters`, `position-matters`, `parent-matters`, `stable-env-matters` | `Runner/Build.agda` |
| **P3** an excluded input does not | `mounts-invisible`, `volatile-invisible` | `Runner/Build.agda` |
| **P4** volatile ⇒ always-run | `marked-misses`, and `Marked` for the whole mechanism | `Runner/Build.agda`, `Runner/Counterexamples.agda` |
| **P6** minimality | `hit-keeps-ran`, `warm-runs-nothing` | `Runner/Build.agda` |
| early cutoff | `cutoff`, `no-cutoff-without-keys` | `Runner/OutputKeys.agda` |

P1 is the one that matters: *a job run against a cache left by other jobs produces what the same job
produces with the step cache off, step for step.* It needs one real hypothesis.

**`Disciplined`** — for a step the runner does not mark, inputs agreeing on everything the key keeps
give the same result. It bundles three obligations: the step is deterministic, it does not consult a
volatile variable, and it does not depend on the content of a mounted cache volume. The runner
enforces none of them; it marks the steps it can detect and relies on this for the rest.

Everything else the proof uses is bookkeeping the implementation already does: `Coherent` (entries are
honest), `Ahead` and `Numbered` (the cache holds nothing yet for the steps still to come).

## Output keys, and what they buy

A marked step cannot be replayed — that is the point of marking it. Without help neither can anything
after it, because the container it hands on is identified by its own recipe, nonce and all. That is
`no-cutoff-without-keys`: *every* step after a marked one asks a key no other job's cache can hold,
whatever anything produced. It is the cost [SPEC.md](../docs/SPEC.md) §6 states as a fact.

`outputKeyed` replaces that container with the one before the step plus what the step produced, by
digest. `cutoff` is then the payoff: two jobs whose marked step produced the same bytes ask *exactly
the same keys* for every step after it, so whatever the first recorded, the second finds. In Build
Systems à la Carte's taxonomy the step cache is a verifying trace and this is a constructive one, and
this property is early cutoff. Soundness of those replays is not a new question: `replay≡run` is
proved for output keys on as well as off, with no extra hypothesis.

It is not unconditional. `different-bytes-different-container` says a changed output still forces what
follows, and `OutputKeys` in the counterexamples computes the four numbers of experiment 7.6: cold 2
runs, warm with keys 1, warm without keys 2, and warm-but-noisy-output 2 — which is why
`outputs_ignored` exists.

## What the counterexamples establish

Each is a complete, computing job in `Runner/Counterexamples.agda`.

| # | The step | What happens | Hypothesis |
|---|---|---|---|
| 1 | reads `GITHUB_RUN_ID` without naming it | job 2 is handed job 1's answer and runs nothing | `Disciplined` |
| 3 | a flaky test, unmarked | job 1 passed, so job 2 "passes" without running | `Disciplined` |
| 4 | reads a cache volume, unmarked | replayed although the volume changed between jobs | `Disciplined` |

2 is the positive one: declare the read, and the marker makes the key new, so the step runs and agrees
with running. 5 is a correction, below. 6 is output keys.

## Three things this turned up

- **A claim of the first version of this model was wrong, and the model refuted it.** With `State`
  opaque, `exec` chose the container it left, so a step could leave the chain where it found it, and
  two marked steps in one job then shared a key — which made the step number in the log marker look
  load-bearing for correctness. It is not. A container's identity is the recipe that built it, so
  every step starts one deeper than the last (`depth-advances`), and that is what keeps two
  occurrences apart. `SameStepTwice` computes the miss. What *is* true of the marker is narrower and
  still worth knowing: the script text is in the key, so changing the marker format gives every step
  of every job a new key.
- **Replay hides flakiness by construction**, not by omission. `disciplined⇒deterministic` derives
  determinism from the hypothesis P1 needs, so the step cache is sound only for jobs with no flaky
  unmarked step — and a replayed step cannot fail. [RELATED.md](../docs/RELATED.md) noted we had never
  measured flakiness; this says measuring it needs the cache off.
- **The documented gap is a correctness gap.** [SPEC.md](../docs/SPEC.md) §6 already says a script
  that reads run-specific values from a file in the repository is "not detected". Counterexample 1
  shows what that costs: not a slower job, a wrong one.

## What this does not model

Not proof of anything about: hash collisions (the key is a projection); **P5** and declared inputs,
shelved on `feat/declared-inputs-v2`; `GITHUB_ENV` and `GITHUB_PATH` feeding the next step's
environment; the fallback paths in `outputKeyed`, which only ever make the job more conservative;
concurrency across the pool, and the engine's garbage collection; anything bash does; and every
question of *cost* — nothing here says a replay is faster, only that it is right.

`Step.reads` is the set of names a script really consults. `readsRunSpecific` approximates it by
looking for the name in the text, so the model's `mark` is an idealisation of the runner's, and
counterexample 1 is exactly the distance between them.

## Next

Stage 3 of [MEASURE.md](../docs/MEASURE.md) wants these as generated tests against a real engine. The
statements above are what to generate from: P2 and P3 are a metamorphic pair over one input kind at a
time, P4 is `marked-misses` with a real nonce, and `cutoff` is the output-keys experiment with the
digest held equal by construction rather than by luck.
