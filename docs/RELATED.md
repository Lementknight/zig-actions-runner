# Related work: where this runner's design sits, and what the literature already settled

Audience: whoever is about to design or re-litigate a caching decision · Companion:
[DESIGN.md](DESIGN.md), [STUDY.md](STUDY.md), [MEASURE.md](MEASURE.md)

Each entry says what the work is, what it says that bears on a decision taken here, and what it
implies this project should do differently. Several of this study's findings were already known, and
one of its abandoned designs is one the field deliberately moved away from.

## Build systems as a theory

**Mokhov, Mitchell and Peyton Jones, "Build Systems à la Carte"** (ICFP 2018,
[PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2018/03/build-systems.pdf);
[JFP 2020](https://ndmitchell.com/downloads/paper-build_systems_a_la_carte_theory_and_practice-21_apr_2020.pdf)).
Splits a build system into a scheduler and a rebuilder, and names what a rebuilder can guarantee:
correctness, *minimality*, *early cutoff*. Rebuilders are classified as dirty bits, verifying traces,
constructive traces, and deep constructive traces.

*Bearing:* this runner is a build system and had no such vocabulary. The step cache is verifying
traces; output keys are constructive traces. The paper also records that Bazel is **not** minimal
because it restarts a task as new dependencies appear, which is the same trade this runner's
always-run rules make. MEASURE.md §4 now states the properties in these terms.

**Spall, Mitchell and Tobin-Hochstadt, "Build Scripts with Perfect Dependencies"** (OOPSLA 2020,
[arXiv](https://arxiv.org/abs/2007.12737)) and **Curtsinger and Barowy, "Riker: Always-Correct and
Fast Incremental Builds from Simple Specifications"** (USENIX ATC 2022,
[PDF](https://www.usenix.org/system/files/atc22-curtsinger.pdf), best-paper). Both are *forward*
build systems: they discover dependencies by **tracing what a command actually reads**, rather than
asking anyone to declare them. Rattle traces and adds speculation; Riker models the whole POSIX
filesystem, including directories and pipes, and infers fine-grained steps from a specification as
coarse as `gcc *.c`. A companion formalisation, **"Forward Build Systems, Formally"**
([arXiv](https://arxiv.org/pdf/2202.05328)), proves Rattle's optimisations in Agda, hazard detection
included.

*Bearing:* experiment 5 built the opposite thing. `ZIG_RUNNER_INPUTS` asked a workflow to declare
what a step reads, and the study's own findings were that declarations are easy to get wrong (two of
three attempts) and that enforcing them is what makes a wrong one safe. The literature's answer is
not better declarations, it is tracing. DESIGN lists "inferring inputs" as an open question; these
are the designs to copy, and Riker's syscall tracing is the mechanism. That it needs Linux and
privileged tracing is a cost to weigh, not a reason to re-open declarations.

## Caching and distribution at scale

**Esfahani et al., "CloudBuild: Microsoft's Distributed and Caching Build Service"** (ICSE-SEIP 2016,
[ACM](https://dl.acm.org/doi/10.1145/2889160.2889222)). Content-based caching over a coarse-grained,
file-I/O contract; build and test speedups of 1.3× to 10×; 99% availability. It had to cope with
**non-deterministic tools and specifications that under-declare dependencies**, and onboarding each
codebase cost man-months.

*Bearing:* the 1.3×–10× range is the same order as this study's step-cache results (about 20× on a
re-run, 7× on a warm Rust job, nothing on a fresh commit), which suggests those numbers are
unremarkable rather than suspicious. The under-declaration problem is exactly what experiment 5 hit,
a decade later, and CloudBuild's answer was to tolerate it in the service rather than demand correct
declarations.

**Bazel's Remote Execution API** ([spec](https://github.com/bazelbuild/remote-apis)) and
**"Using Remote Cache Service for Bazel"** (ACM Queue 16(4),
[DOI](https://doi.org/10.1145/3277539.3287302)). Two stores: an *action cache* mapping an action
digest to its result, and a *content-addressable store* of outputs. An action's identity is the digest
of a canonical protobuf naming the command and a Merkle tree of its inputs.

*Bearing:* this runner's output keys are a small re-invention of exactly that pair — a digest-keyed
content store plus a key made from content rather than from history. Worth knowing before extending
them. More useful still: Bazel 7 made **"build without the bytes"** the default, so intermediate
outputs are not downloaded unless needed. Experiment 6 found this runner's cost to be precisely the
materialising of bytes (28.6 s to copy a 214 MB environment; 25 s of filesystem walks for output
keys). Not materialising what nothing reads is the direction the field took, and this runner has no
equivalent.

## Testing less

**Herzig, Greiler, Czerwonka and Murphy, "The Art of Testing Less without Sacrificing Quality"**
(ICSE 2015,
[PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2015/05/The-Art-of-Testing-Less-without-Sacrificing-Quality.pdf)).
THEO skips a test when the *expected cost of running it* exceeds the *expected cost of not running
it*, using historical results and no runtime instrumentation. Replayed over three Microsoft products,
it cut test executions by about half.

*Bearing:* experiment 8 asked whether `pytest-testmon` pays, measured its tracing overhead at about
4×, and concluded there was nothing for the runner to do. That was a mechanics answer to an economics
question. THEO's framing — cost of running against cost of delay — needs no tracing at all, and its
inputs (which tests fail, how often, after which changes) are things a runner *can* record.
Experiment 8 should be re-opened in those terms before the question is called closed.

**Memon et al., "Taming Google-Scale Continuous Testing"** (ICSE-SEIP 2017,
[PDF](https://research.google.com/pubs/archive/45861.pdf)). At Google's scale individual changes
cannot each be fully tested. Few tests ever fail; those that do sit close to the code they test; and
code touched recently by more than three developers breaks more often.

*Bearing:* the same signals a runner sees. It also sets expectations honestly: even with Google's
resources the answer was not "select tests perfectly", it was "accept a lag and spend the budget
where failures concentrate".

## GitHub Actions as a subject

Recent empirical work on the platform this runner imitates: **flaky builds in GitHub Actions**
([arXiv 2602.02307](https://arxiv.org/html/2602.02307v1), rerun data from 1,960 Java projects),
**workflow evolution** ([arXiv 2602.14572](https://arxiv.org/pdf/2602.14572), 267k workflow change
histories across 49k repositories), and **workflow complexity and compliance**
([arXiv 2507.18062](https://arxiv.org/pdf/2507.18062)).

*Bearing:* two gaps here. This project has never measured flakiness, although a runner that replays
steps from a cache can *hide* flakiness by construction — a replayed flaky test cannot fail — and
that interacts with P1 in MEASURE.md. And the workflow corpora in those papers are a better source of
realistic test workloads than the six projects chosen by hand in STUDY.md §2.

## What this implies, shortest form

1. **Trace, do not declare,** if "hits across commits" is ever re-opened (Riker, Rattle).
2. **Do not materialise bytes nothing reads** (Bazel 7); experiment 6's cost was materialising.
3. **Model the economics of testing less,** rather than the mechanics of one plugin (THEO).
4. **Expect 1.3×–10×**, not more, from content caching on real projects (CloudBuild).
5. **Measure flakiness,** because replay can conceal it.
