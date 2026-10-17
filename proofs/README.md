# The step cache, in Agda

Audience: whoever changes the caching, or doubts it · Companion: [MEASURE.md](../docs/MEASURE.md),
[CLAIMS.md](../docs/CLAIMS.md), [RELATED.md](../docs/RELATED.md), [SPEC.md](../docs/SPEC.md) §6

[MEASURE.md](../docs/MEASURE.md) §4 lists six properties the caching must *have* rather than merely
measure. No benchmark can establish one of them: a measurement says a step was replayed quickly, not
that replaying it was right. These modules state them and prove them, and for each hypothesis a proof
needs, they give a concrete job where dropping it makes the cache hand back an answer that running
would not have given.

```
./check.sh
```

Every module is `--safe`: no postulates, no holes, no `trustMe`. A clean run is the whole claim. CI
checks it on every pull request, and so does `pre-commit`, on the staged content.

**The Agda version is pinned**, because it has to be: Ubuntu's apt Agda is 2.6.3 and Homebrew's is
2.8.0.2, and these proofs type-check on the second and not the first — overloading a constructor name
is resolved from the expected type in one and ambiguous in the other. CI installs the version named by
`AGDA_VERSION` in [ci.yml](../.github/workflows/ci.yml), by **checksum**, from the Agda project's own
release binaries. `check.sh` prefers an `agda-<that version>` on `PATH` and falls back to plain `agda`
with a warning that results may differ.

`brew install agda` gives 2.8.0.2 today, which is the pinned version and needs nothing further. To
pin it exactly as CI does, take the same upstream binary — macOS arm64 here, and the Linux, x64 and
Windows builds are in [the same release](https://github.com/agda/agda/releases/tag/v2.8.0.2):

```sh
v=2.8.0.2
curl -fsSLO "https://github.com/agda/agda/releases/download/v$v/Agda-v$v-macOS-arm64.tar.xz"
shasum -a 256 "Agda-v$v-macOS-arm64.tar.xz"   # 6ee796a0cb70a0cd80edfc7d2aec24a93aa22558fb3e99caaaeadf33dbb64be7
mkdir -p "$HOME/.local/opt/agda-$v" && tar -xJf "Agda-v$v-macOS-arm64.tar.xz" -C "$HOME/.local/opt/agda-$v"
xattr -cr "$HOME/.local/opt/agda-$v"                        # macOS SIGKILLs unsigned downloads
codesign --force --sign - "$HOME/.local/opt/agda-$v/agda"   # (exit 137) until they are signed
ln -sfn "$HOME/.local/opt/agda-$v/agda" "$HOME/.local/bin/agda-$v"
```

One binary, nothing else: it is statically linked on Linux, and these proofs import no library, so
they need none of Agda's data files. (`agda --setup` writes them out if something ever does.)

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
| `Progress.env`, and `Output.sets` feeding it | the container's variables, and what a step exported through `$GITHUB_ENV` / `$GITHUB_PATH`, which the runner reads from the step's file commands — a replayed step's included |
| `Input.mounts`, absent from the key | `withMountedCache`: BuildKit leaves mounts out of an exec's key |
| `Output = log · digest · sets` | the step's output, `changes(from:).layer.digest`, and its file commands |
| `mark st = everyRun` | `readsRunSpecific`, plus the secret and OIDC reasons, which are the same case |
| `Mode = ℕ → Keys` | `RUNNER_OUTPUT_KEYS`, **per step**: `outputKeyed` falls back to the step's own container whenever anything fails, which is `off` for that step |
| `Subset` | the output store's pruning by age (`output_keys_days`) |
| `Elsewhere` | a cache a pool of runners shares, written by other jobs |
| `Runner.Declared` | the shelved `ZIG_RUNNER_INPUTS` prototype, which is *not* in the shipped runner |

Two choices are deliberate and worth arguing with. The key is modelled as a *projection*, not a hash,
so collisions are out of scope rather than silently assumed away. And `exec` takes the trial as well
as the input, so a step is **not** forced to be a function of its inputs — a flaky test is a
well-typed inhabitant, which is why determinism has to be asked for by name.

## What is proved

| MEASURE.md | Statement | Where |
|---|---|---|
| **P1** replay equals run | `replay≡run`, for every mode — output keys on, off, or falling back per step | `Runner/Build.agda` |
| **P2** a changed input invalidates | `text-matters`, `position-matters`, `parent-matters`, `stable-env-matters` | `Runner/Build.agda` |
| **P3** an excluded input does not | `mounts-invisible`, `volatile-invisible` | `Runner/Build.agda` |
| **P4** volatile ⇒ always-run | `marked-misses`, and `Marked` for the whole mechanism | `Runner/Build.agda`, `Runner/Counterexamples.agda` |
| **P5** enforcement over guessing | `undeclared-absent`, `enforced-depends-only-on-the-declaration`, and `Guessing` for what the alternative costs | `Runner/Declared.agda` |
| **P6** minimality | `hit-keeps-ran`, `warm-runs-nothing`, `recorded⇒not-run`, `step-runs-at-most-once` | `Runner/Build.agda` |
| early cutoff | `cutoff`, `cutoff-needs-only-the-digest`, `no-cutoff-without-keys`, `different-bytes-different-container` | `Runner/OutputKeys.agda` |
| pruning is safe | `coherent-subset`, `ahead-subset`: both of P1's hypotheses survive dropping entries, so pruning can only cause misses | `Runner/Build.agda` |
| a shared cache is safe | `elsewhere⇒ahead`: no other job can write under this job's nonce, which is why a pool may share one cache | `Runner/Build.agda` |
| **the volatile clause, discharged** | `input-determined-by-key`, `volatile-clause-discharged`, `nothing-volatile-survives` | `Runner/Enforce.agda` |

P1 is the one that matters: *a job run against a cache left by other jobs produces what the same job
produces with the step cache off, step for step.* It needs one real hypothesis.

**`Disciplined`** — for a step the runner does not mark, inputs agreeing on everything the key keeps
give the same result. It bundles three obligations: the step is deterministic, it does not consult a
volatile variable, and it does not depend on the content of a mounted cache volume. The runner
enforces none of them; it marks the steps it can detect and relies on this for the rest.

**One of the three can be discharged rather than assumed**, and `Runner/Enforce.agda` proves it.
Detection cannot be made sound — a script can reach a volatile value through a file it sources, a
program that reads the environment, or a name it builds from pieces, which is counterexample 1 and
the live B1 check. So apply what P5 does for files: hand an unmarked step **only what its key keeps**.
Then `input-determined-by-key` says its input is a function of its key, and
`volatile-clause-discharged` says equal keys give equal results as soon as the step is deterministic
— nothing need be assumed about what it reads, because nothing in its environment varies between
runs. `Runner.Counterexamples.Enforced` is counterexample 1's own `exec` against the same two jobs,
no longer able to tell them apart.

What that leaves to assume is determinism and mount-blindness: two obligations instead of three.
**It is in the runner**, on by default, as `RUNNER_ENFORCE_VOLATILE` — a step that did not name a
run-specific value is given the constant `zig-runner-withheld` in its own `env` prefix. See SPEC.md
§9, the first entry in "Where this runner differs from GitHub's". Early cutoff
turns out to need it too, and that is new: what a step exports through `$GITHUB_ENV` is in the next
step's container, so an unmarked step that exported different variables in two jobs would part the
keys after it.

Everything else the proof uses is bookkeeping the implementation already does: `Coherent` (entries are
honest), `Ahead` and `Numbered` (the cache holds nothing yet for the steps still to come).

## What the counterexamples establish

Each is a complete, computing job in `Runner/Counterexamples.agda`.

| # | The step | What happens | Hypothesis |
|---|---|---|---|
| 1 | reads `GITHUB_RUN_ID` without naming it | job 2 is handed job 1's answer and runs nothing; **8** closes this | `Disciplined` |
| 3 | a flaky test, unmarked | job 1 passed, so job 2 "passes" without running | `Disciplined` |
| 4 | reads a cache volume, unmarked | replayed although the volume changed between jobs | `Disciplined` |
| `Guessing` | keyed on a guessed input set, run in the whole workspace | replayed with a stale answer; enforced, it sees nothing instead | P5 |

The others are positive: **2** declares the read and the marker makes the key new; **5** is a
correction (below); **6** computes experiment 7.6's four numbers — cold 2 runs, warm with keys 1,
warm without keys 2, warm with a noisy output 2, which is why `outputs_ignored` exists; **7** shows a
replayed setup step still exporting its variable, so the step after it is replayed too; **8** runs
counterexample 1's own `exec`, unchanged, against an unmarked step's enforced input and finds it can
no longer tell the two jobs apart (`cannot-tell-them-apart`).

**1 and 8 are a pair, and only 1 of them is still the runner's behaviour.** Counterexample 1 is why
`RUNNER_ENFORCE_VOLATILE` exists and what it would cost to turn off; 8 is what the runner does by
default (SPEC.md §9). The live counterpart, B1 in [properties/](../properties/README.md), asserts
both: still undetected and still replayed, as 1 has it, and told nothing rather than told wrongly, as
8 has it. 3 and 4 have no 8 of their own — they are open.

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

## Obligations for the harness

What a proof of a property buys is a *test that is worth generating*: the model says which cases
matter and what must hold in each, so [MEASURE.md](../docs/MEASURE.md) stage 3 does not have to guess.
Each row is one generated family, against a real engine rather than the fake session.

| From | Generate | Assert |
|---|---|---|
| P1 | any job, twice at the same commit: `RUNNER_STEP_CACHE=false`, then on | the same step logs, file commands and conclusions; and `N of M steps replayed` is M the second time |
| P2 | four jobs, each changing exactly one keyed input: the script text, the step's position in the job, a file in the workspace, a non-volatile variable | the step ran — the `ZIG_RUNNER_RAN` marker is this job's |
| P3 | two jobs differing only in a volatile value (run id, actor, commit), and two differing only in a cache volume's content | the step was replayed |
| P4 | one job per name in `volatile_env`, whose script names it; and one using a secret, and one with `id-token: write` | the step ran, every time |
| P5 | on `feat/declared-inputs-v2`: a step whose declaration omits a file it reads | the step **fails**; it does not replay |
| P6 | a job whose every step hits | no step ran, and `N of M` is M |
| early cutoff | a marked step with a stable output, followed by unmarked steps; then the same with an output that changes every run | the marked step runs both times; the steps after it are replayed in the first case and run in the second |
| pruning | fill the output store, prune it (`RUNNER_OUTPUT_KEYS_DAYS`), re-run | results identical to the unpruned run; only the replay counts differ |
| shared cache | two jobs of the same workflow at once, on a pool sharing one engine | the same results as running them one after the other |
| `$GITHUB_ENV` | a setup step that exports a variable, replayed, and a step after it that reads it | the second step sees the same value and is itself replayed |

Three of these cannot be made to pass, and that is the point of having them: counterexample 1's
indirect volatile read, counterexample 3's flaky step, and counterexample 4's cache-volume read are
what the design *cannot* detect. Generate them as **expected failures**, so that the day one starts
passing, something has changed.

## What this does not model

Not proof of anything about: hash collisions (the key is a projection, so two different recipes never
collide here); the *interleaving* of concurrent jobs, only the shared cache they end up with
(`Elsewhere`) — the store's first-writer-wins `mv -T` is not modelled; anything bash does; and every
question of *cost* — nothing here says a replay is faster, only that it is right. Experiment 5's +28%
and +85% are why `Runner.Declared`'s mechanism is shelved, and no theorem in it argues otherwise.

`Step.reads` is the set of names a script really consults. `readsRunSpecific` approximates it by
looking for the name in the text, so the model's `mark` is an idealisation of the runner's, and
counterexample 1 is exactly the distance between them.
