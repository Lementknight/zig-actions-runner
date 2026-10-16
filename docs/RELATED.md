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

## Streaming a step's output

A different subsystem, with its own prior art: how a runner gets a step's log off the machine while
the step is still running, without losing the end of it. Ours keeps a job's lines in memory (64 MB
cap), batches them to GitHub's WebSocket feed every 500 ms with a per-step `startLine`, and uploads
blobs when the job ends. Two of the bugs in STUDY.md came from that shape — a dead connection handed
back to a shared pool, and a step's output arriving after its end marker — and the shape is also why
a crashed or redeployed runner loses a job's log entirely.

Five systems, five patterns worth stealing from:

- **Buildkite's agent cuts the log into numbered chunks and retries them one at a time.** Its API
  type is `Chunk{Data, Sequence, Offset, Size}`, gzipped, `POST jobs/:id/chunks?sequence=&offset=&size=`
  ([api/chunks.go](https://github.com/buildkite/agent/blob/main/api/chunks.go)); the streamer takes
  `Concurrency`, `MaxChunkSizeBytes` and `MaxSizeBytes` and counts the chunks it failed to send
  ([agent package](https://pkg.go.dev/github.com/buildkite/agent/v3/agent)), which is exported as
  `buildkite_agent_logs_chunk_uploads_errored_total`
  ([monitoring](https://buildkite.com/docs/agent/v3/monitoring)). It can spool the job log to a file
  (`--enable-job-log-tmpfile`), emit logs as OpenTelemetry records, and takes a grace period to
  finish uploading after the job process exits (`--cancel-cleanup-timeout`)
  ([cli-start](https://buildkite.com/docs/agent/v3/cli-start)). *One failure costs one chunk.*

- **GitLab's runner lets the server own the offset.** It PATCHes `/api/v4/jobs/:id/trace` with a
  `Content-Range` ([MR 906](https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/906)), and
  when the server already holds bytes it answers **416 with its length** so the client can skip
  ahead. The cautionary half is [issue #4548](https://gitlab.com/gitlab-org/gitlab-runner/-/issues/4548):
  `range mismatch … job-log=0-16359 sent-log=19720-23513`, where a buffer that does not begin at
  those bytes diverges quietly. *Ask where to resume; make a mismatch loud.*

- **Airflow treats the local file as the source of truth.** `FileTaskHandler` writes
  `dag_id=…/run_id=…/task_id=…/attempt=N.log` under `base_log_folder`; because "most task handlers
  send logs upon completion", a small HTTP server (8793 on workers, 8794 on the triggerer) serves
  them live until then, and `remote_logging` ships them afterwards, with `delete_local_logs` to clean
  up. Blob handlers **interleave by timestamp** when a log's pieces end up in several places
  ([logging tasks](https://airflow.apache.org/docs/apache-airflow/stable/administration-and-deployment/logging-monitoring/logging-tasks.html)).
  *The network is a view of a durable spool, not the only copy.*

- **Dagger makes a log an event on a span.** `dagger.io/dagger/telemetry` converts OTLP
  `ResourceSpans` to and from SDK spans and exposes configured span, log and metric exporters, with
  span options (`Encapsulate`, `Internal`, `Boundary`) deciding how the progress UI nests them
  ([telemetry package](https://pkg.go.dev/dagger.io/dagger/telemetry)); OTel log records carry
  `trace_id` and `span_id` ([logs spec](https://opentelemetry.io/docs/specs/otel/logs/)).
  *Attribution comes from identifiers, never from arrival time* — which this runner already relies on
  (`SpanDemux` routes a line to a step by span) and which is why its "was this step replayed?" guess
  had to be replaced by a marker the step writes.

- **Concourse keeps the log as a durable event table.** Build events live in Postgres — `build_events`
  plus a `pipeline_build_events_<id>` table per pipeline — and are served to `fly` and the UI
  ([#2104](https://github.com/concourse/concourse/issues/2104)); the SSE `id` is the resume cursor
  ([log-tailing patterns](https://www.server-sent-events.com/real-time-application-patterns/log-tailing-and-ci-output-streaming/)).
  The price is visible: multi-GB tables and ~50 GiB of Postgres reported even with retention set
  ([#6892](https://github.com/concourse/concourse/issues/6892)). *Replayable from a cursor, paid for
  in storage.*

What they agree on, and this runner did not: **the unit of a log is a numbered record in an
append-only stream, written somewhere durable before it is sent, and shipped with retries that are
idempotent because the number says where they belong.** Nobody streams from a buffer that only exists
in the sender's memory. The first two steps towards that here are a per-step sequence number assigned
when a line is logged rather than when it is sent, and a spool file per job in place of the
in-memory buffer; chunked, resumable upload is the third and needs to know what GitHub's results
service accepts.

## What this implies, shortest form

1. **Trace, do not declare,** if "hits across commits" is ever re-opened (Riker, Rattle).
2. **Do not materialise bytes nothing reads** (Bazel 7); experiment 6's cost was materialising.
3. **Model the economics of testing less,** rather than the mechanics of one plugin (THEO).
4. **Expect 1.3×–10×**, not more, from content caching on real projects (CloudBuild).
5. **Measure flakiness,** because replay can conceal it.
