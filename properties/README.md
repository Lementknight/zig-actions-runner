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
| P1 | the cache off, then warm, then replayed | the observer **said the same thing**, and the exporter was replayed too | `replay≡run` |
| E1 | a marked step leaving the same bytes / new bytes | the steps after it **replayed** / **ran** | `cutoff`, `different-bytes-different-container` |

P1 doubles as the `$GITHUB_ENV` obligation: what the observer says includes a variable an earlier
step exported, and on the replayed run that earlier step was replayed too, so its export came out of
the cache with everything else.

**E1 needs the engine's ssh host**, and this is why. The first run of it failed, and the runner was
right: output keys cost 10.5 s on that job against a `RUNNER_OUTPUT_KEYS_MAX_MS` of 10 s, so the
runner switched them off for the repository — and a mechanism that has opted out cannot cut off. The
check now raises the limit for its own duration and puts it back. Testing whether output keys cut off
is not testing whether they are cheap; E3.4 in [CLAIMS.md](../docs/CLAIMS.md) is the one that measures
the cost.

P2d needs the second workflow, `property-shifted.yml`, which is `property.yml` with one more step
before the subject. A skipped step still occupies its place in a job, so an `if:` cannot move the
subject; only a different workflow can.

## The blind spots

Three checks assert that the design still *cannot* see what it cannot see — the counterexamples in
`proofs/Runner/Counterexamples.agda` made executable. They pass by finding a stale answer, so the day
one of them **fails**, detection has improved and the documents here are out of date.

| Check | The step | What it showed |
|---|---|---|
| B1 | reads the run id without ever spelling its name | replayed, and reported `38952425691` on run `38954899582` |
| B2 | a value that is not a function of its inputs | replayed; the cache froze one answer, and a cache-off run gave another |
| B3 | reads a marker in a cache volume an always-run step rewrote | replayed, and reported the marker from a much earlier run |

B1's indirection is the case SPEC.md §6 calls "not detected": the script builds the variable's name
from pieces, so `readsRunSpecific` — which looks for the contiguous string — cannot see it. B3 needs
output keys, because without them the writer's new key would force the reader to run and there would
be no stale read to find.

**A replayed step's output is from whenever its entry was first recorded**, not from the run before.
B1 and B3 first asserted the latter and failed: the step was reporting an id from forty minutes
earlier, because the entry had been served since then. They now assert what the blind spot actually
is — that the answer is not this run's — which is both true and the thing worth knowing.

**The suite cannot pass vacuously**, which matters for a suite that passes everything: it asserts
both polarities. P3 and P6 fail unless the note is *present*, P2 and P4 fail unless it is *absent*,
so a discriminator that always said one thing would fail half of them. Checked directly on the first
run of it: of six dispatches, the note appeared on exactly the one with identical inputs and on none
of the five that changed one.

## What is not here yet

- **R2, a shared cache**: two jobs of the same workflow at once, each asserted to get its own answer
  rather than the other's — `elsewhere⇒ahead`. **Written, not yet run.** It needs no change to the
  runner's configuration, so it is the safe one to run next.
- **P5**, which needs the shelved `feat/declared-inputs-v2`.
- **Pruning is deliberately not here.** It is proved (`coherent-subset`, `ahead-subset`: dropping
  entries preserves both of P1's hypotheses, so pruning can only cause misses) and it is not
  checkable from outside. The store step prunes with `find … -mtime +0`, which means "at least a day
  old", so a fresh entry cannot be pruned on demand; the study's earlier pruning test backdated
  entries inside the volume. A first attempt at a live check wrote
  `RUNNER_OUTPUT_KEYS_DAYS=0` into the unit, which the runner rejects as an invalid number — it
  exited 1, `RestartPreventExitStatus` correctly kept it down, and jobs queued behind a dead service
  until someone noticed. Hence the rule below.

## Rules for a check that touches the runner

Only E1 and B change anything on the machine, and only one setting: the cost limit, raised so that
output keys are allowed to run at all. Any check that does this must

1. **validate the value first** — the runner itself rejects bad configuration, so
   `zig build run -- --output-keys-days=0` says in a second what a restart says in five minutes;
2. **assert the service came back** — active, and with a runner registered — and stop the suite if
   not, rather than dispatching jobs behind a service that is down;
3. **put the setting back** in a trap, whatever happens.

`set_limit` now does 2 and 3. A helper that wrote arbitrary configuration has been removed: nothing
here should be able to set a value nobody checked.

Three smaller things found while building this, worth knowing before adding more:

- The cache-dir variables (`UV_CACHE_DIR` and the rest) are set for **container jobs only**, so a
  default-image job has to name the path the volume is mounted at.
- `gh run view --log` is tab-separated, and BSD sed does not read `\t` as a tab, so strip its fields
  with `cut -f3-`. The sed version did nothing on macOS and made two assertions compare empty strings
  and pass without saying so.
- Each commit to the test repository triggers whatever that repository builds on a push. Three
  separate commits meant three concurrent site builds and a load average of 10.9 on four cores:
  batch them.

## Why this cannot run in CI

The engine lives on the self-hosted runner, so these checks need that runner and a repository it is
registered to. CI has neither. They are a manual suite for now, which is why the mapping above
matters: a human has to be able to tell what a failure means.
