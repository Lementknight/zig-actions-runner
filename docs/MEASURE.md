# Measuring: a framework for the claims in this study, and the properties behind them

Audience: whoever adds or re-checks a claim · Companion: [STUDY.md](STUDY.md), [DESIGN.md](DESIGN.md), [RELATED.md](RELATED.md), [proofs/](../proofs/README.md)

This study's claims were produced ad hoc, one shell script at a time, and several were wrong before
they were right. This document exists so that the next claim is harder to get wrong than to get
right: it fixes what a claim must come with, how an experiment must be run, and what the caching
algorithms must *prove* rather than merely measure.

## 1. Why: the mistakes this has to prevent

Every item below actually happened while producing experiments 5 to 8, and each one produced a
confident, wrong statement that a later check overturned.

| | Mistake | What it produced |
|---|---|---|
| 1 | One nonce per script, so later trials reused earlier trials' cached work | "Dagger keys step outputs on content" (it does not) |
| 2 | `$RANDOM` read inside `$(...)`, which a subshell makes constant | three probe rounds that all sent identical commands |
| 3 | Sampling a counter after a short job had already finished | "100 steps cost 0 s of engine CPU" |
| 4 | Matching a run id that belonged to the previous trial | every reading shifted by one round |
| 5 | Comparing a Dockerfile `RUN` (commits a layer) with `withExec` (does not) | "BuildKit is four times slower than Dagger" |
| 6 | Running a probe on hardware too fast to discriminate | "`owner:` is free" (it costs 21 s on the Pi) |
| 7 | Reading a cache from a branch that never saved it | "GitHub's cache does not help" |
| 8 | One sample per arm | a monotonic `GOGC` "trend" that repeats erased |
| 9 | A workload that does not exercise the thing claimed | "`GOGC=400` buys nothing" (it buys 15–20% on step-heavy jobs) |
| 10 | A first round that also provisions the base container | cold-cache cost overstated by 2–3× |
| 11 | A harness that hides the command's output | a failure whose reason was unknown for two runs |

Items 1, 2, 7 and 9 are **validity** failures: the experiment did not test the claim. Items 3, 4, 10
and 11 are **instrumentation** failures. Items 6 and 8 are **power** failures: the setup could not
have detected the effect. They need different defences, so the framework names them separately.

## 2. Resources this is built on

- **Kalibera and Jones, "Rigorous Benchmarking in Reasonable Time"** (ISMM 2013,
  [PDF](https://kar.kent.ac.uk/33611/45/p63-kaliber.pdf)). Experiments are *nested*: repetitions
  within a job, jobs within an engine state, engine states within a build. The paper gives a model
  for how many repetitions each level needs for a wanted precision, and a dimensioning experiment to
  find them, rather than guessing. It is the direct answer to mistake 8.
- **Mytkowicz, Diwan, Hauswirth and Sweeney, "Producing Wrong Data Without Doing Anything Obviously
  Wrong!"** (ASPLOS 2009,
  [PDF](https://users.cs.northwestern.edu/~robby/courses/322-2013-spring/mytkowicz-wrong-data.pdf)).
  Measurement bias from parts of the setup nobody thinks about, unpredictable and not removable by
  repetition; their remedies are causal analysis and **setup randomisation**. It is the answer to
  mistakes 9 and 10, and the reason arms must be interleaved rather than run in blocks.
- **Mokhov, Mitchell and Peyton Jones, "Build Systems à la Carte"** (ICFP 2018,
  [PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2018/03/build-systems.pdf);
  journal version [JFP 2020](https://ndmitchell.com/downloads/paper-build_systems_a_la_carte_theory_and_practice-21_apr_2020.pdf)).
  Splits a build system into a *scheduler* and a *rebuilder*, and defines the properties a rebuilder
  can have: correctness, **minimality** (a task runs at most once, and only if something it
  transitively depends on changed) and **early cutoff** (a task whose result is unchanged does not
  force its dependents to run). It classifies rebuilders as dirty bits, verifying traces,
  constructive traces and deep constructive traces. This runner is a build system, so this is the
  vocabulary its caching should be argued in — §4.
- **hyperfine** ([repository](https://github.com/sharkdp/hyperfine)) as a worked example of harness
  mechanics: warm-up runs, a `--prepare` step between runs, outlier detection that calls out a first
  run slower than the rest, and JSON export of every individual sample rather than a summary.

## 3. The framework

### 3.1 A claim registry

Every performance claim in STUDY.md gets an identifier (`E6.2`, `E7.1`, …) and an entry naming: the
quantity, the workload and its pinned commit, the machine, the arms compared, the repetitions at each
level, the statistic reported, and the command that reproduces it. A claim with no entry is marked
**unverified** in the text, and may not be used to justify a change.

The register is [CLAIMS.md](CLAIMS.md), and a new claim belongs in it before it is cited anywhere.

### 3.2 The protocol

1. **Say what would refute it, first.** Write the expected direction and the smallest effect worth
   acting on before running anything. An effect smaller than that is reported as "no effect found",
   never as a trend.
2. **A negative control in every suite.** One arm whose result is known, and which must come out
   as known. Mistake 1 was caught by exactly this and nothing else.
3. **Interleave arms, do not block them.** A, B, A, B, …, so drift in the machine's state cannot be
   read as a difference between arms (Mytkowicz).
4. **Separate the first round.** Provisioning, pulls and cold caches are their own measurement, never
   mixed into a steady-state one.
5. **Repetitions by dimensioning, not by habit.** Run the cheap variability experiment first, then
   choose repetitions per level with Kalibera and Jones's model. Record the chosen counts.
6. **Report the difference with an interval.** Median of each arm, and a bootstrap confidence
   interval of the *difference*. If it spans zero, the claim is "no effect found at this size".

### 3.3 What the harness must do, from the mistakes

- **Freshness.** Generate a trial token in the parent process, assert that tokens differ, and embed
  it where the system under test cannot ignore it (for this runner, in a step's script text, which is
  part of its cache key; not in a volatile variable, which is excluded by design).
- **Windows.** Record the sample window with each reading and assert that the measured event lies
  inside it; a job that finished before its window opened is discarded, not averaged in.
- **Identity.** Assert that an identifier (a run id, an attempt) advanced from the previous trial.
- **Never swallow output.** Capture stdout and stderr, report them on failure, and keep the exit code
  separately from the shell's own control flow.
- **Capture the environment.** Per trial: runner build, engine image and `GOGC`, engine cache bytes
  and snapshot count, cgroup memory and cap hits, page cache, the workload's commit, and whether each
  cache was warm. These are the variables that turned 1 s of work into 17 s, so they are data.
- **Keep every sample.** Write one JSON line per trial, so a claim can be re-analysed without being
  re-run.

## 4. Proof obligations: what the caching must *be*, not just measure

In Build Systems à la Carte's terms, this runner is a build system whose tasks are steps:

| Mechanism here | What it is | Property it must have |
|---|---|---|
| Step cache (Dagger reuses an exec whose inputs are unchanged) | **verifying traces**: a hash of the inputs decides | minimal, and early cutoff for the inputs it hashes |
| Volatile variables (run id, actor, commit, refs) | inputs deliberately excluded from the trace | a step that *reads* one must never be replayed |
| Output keys (the next step is keyed on what an always-run step produced) | **constructive traces**: the produced content, by digest, becomes the key | early cutoff across an always-run step |
| Declared inputs (shelved) | an explicit, static dependency set, checked by construction | a declaration that misses a file must fail, never mis-replay |

These are claims about behaviour, so they are stated as properties and checked as properties, not
illustrated by one example each:

- **P1 Replay equals run.** For a step with inputs *I*, the recorded output replayed from cache equals
  what running it in the same container would produce. Checked by running the same job twice with the
  cache off and on and comparing step logs, file commands and the resulting container digest.
- **P2 A changed input invalidates.** For every input in the trace (script text, image, env that is
  not volatile, mounted content), changing it alone must cause the step to run. One generated case
  per input kind, not one example overall.
- **P3 An unchanged input does not invalidate.** Changing anything deliberately excluded (a volatile
  variable's value, a timestamp the checkout normalises) must not cause a step to run.
- **P4 Volatile means always-run when read.** A step whose script names a volatile variable must run
  every time. This is the safety counterpart of P3 and the two must be tested together.
- **P5 Enforcement over guessing.** Where a mechanism narrows a step's inputs (declared inputs), an
  input outside the declaration must be *absent*, so the step fails rather than replaying a result
  computed from something it could not see.
- **P6 Minimality.** No step runs twice in a job, and no step runs whose traced inputs are unchanged.

P2 and P3 together are a metamorphic test: the relation between two runs is asserted, without needing
a model of what the step outputs. That is what makes them generable rather than hand-written.

All six properties are now proved of a model of the step cache, in [proofs/](../proofs/README.md)
(`./proofs/check.sh`, and in CI), along with early cutoff for output keys, that pruning the store can
only cause misses, and that a pool sharing one cache is safe. What that buys is
not confidence in the numbers but a precise statement of what the implementation owes: P1 holds under
one real hypothesis, that the steps the runner does not mark always-run are deterministic and read
neither a volatile variable nor the content of a mounted cache volume. The proofs come with a job for
each way that hypothesis fails, so the remaining question is enforcement, not whether the design is
sound. Stage 3 below is those statements generated against a real engine; the model also says what to
generate.

The model has already overturned one claim made from it, which is the point of having one: see
proofs/README.md, "three things this turned up".

## 5. Staging

1. ~~**The registry and the re-run commands** for the claims already in STUDY.md, marking those whose
   evidence does not meet §3.2 as unverified.~~ **Done:** [CLAIMS.md](CLAIMS.md). As stage 1 left it: 62 claims, of
   which 17 verified, 32 usable but under-powered, 8 unverified and not to be used to justify a
   change, and 2 superseded. Those are the figures *at the time* and are kept because the rest of
   this section refers to them; the register has moved on since (70 claims now, and stage 4 below
   says where the eight went), so read [CLAIMS.md](CLAIMS.md)'s own header for the current count. It also found that four commands in this repository can reproduce
   any of them, which is the case for stage 2.
2. ~~**The harness** (§3.3), with the environment capture and JSON samples, replacing the one-off
   shell scripts.~~ **Built:** `runner/tools/measure.zig`, `zig build measure`. It enforces what this
   section asks for rather than trusting anyone to remember it: `--min-effect` is required, arms are
   interleaved in a seeded order, `--control` names the arm whose answer is known, warm-up rounds are
   recorded and excluded, every trial gets a fresh token and must show an advancing identity, both
   streams are captured, and one JSON line per trial is kept. Its statistics are unit-tested, since
   they decide the verdicts.

   Validated as this stage asks, against answers already known: fed the study's own recorded numbers,
   it returns `no_effect_found` for E7.6 and **`not_enough_samples` for E7.7** — the claim
   [CLAIMS.md](CLAIMS.md) marks unverified. See [measurements/](../measurements/README.md). What
   remains is to drive it on the Pi, where the arms cost minutes each.
3. **The properties** (§4) as tests in the runner's own suite, generated per input kind, run in CI
   against a real engine rather than the fake session. The model now says what to generate and what
   each case must assert — [proofs/README.md](../proofs/README.md), "Obligations for the harness" —
   including three families that must *fail*, since they are what the design cannot detect.
4. **Re-check the claims** that step 1 marked unverified, in the order of what they are being used to
   justify. **Seven of the eight are closed** (2026-10-16 to 17): E7.7 and E8.3 hold, E3.4 does not
   hold as stated and was replaced by E3.4b, **E6.4 and W.5 are refuted** — they were both of the
   study's "faster than a hosted runner" claims, and both compared this machine with warm caches
   against a hosted runner with cold ones — and E2.7 and E5.6 are withdrawn as not measurable as
   written. E5.4 is the one left.

   Two lessons from doing it, which this section did not anticipate. **A claim can fail for its arms
   rather than its sample size**, and no number of repetitions fixes that; E6.4 and W.5 both did.
   And **dimensioning off a pilot taken in a different machine state under-samples**: E5.4's pilot
   ran while the Pi was still quiet, reported `sd 0.000` on its baseline, asked for three
   repetitions, and the series it sized then could not see a 17 s effect through the load its own
   workload created. §3.2.4 separates the first round; a workload heavy enough to perturb the
   machine needs the *whole series* gated on machine state, not just its start.
