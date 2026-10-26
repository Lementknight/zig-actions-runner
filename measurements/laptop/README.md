# How many runners does a laptop take? A pilot, not a claim

Audience: whoever sizes `RUNNER_COUNT` on a machine bigger than the Pi · Rules:
[MEASURE.md](../../docs/MEASURE.md) · Samples: [`laptop-runners-pilot.jsonl`](../laptop-runners-pilot.jsonl)

**Unverified, and not in [CLAIMS.md](../../docs/CLAIMS.md).** One round per arm, no negative
control, no interval, arms run in blocks rather than interleaved: this breaks §3.2 items 2, 3, 5
and 6, and it is mistake 8 ("one sample per arm") by construction. It is kept as the cheap
variability experiment §3.2.5 asks for before a real series, and as a first look at a machine the
study never ran on.

## The answer, as far as it goes

Every job is zig-runner v0.5.0's CI test job (checkout, `install-zig.sh`, `zig fmt --check`,
`zig build test`), warm, each round queuing twice as many jobs as runners:

| Runners | Jobs | Makespan | Jobs/min | Job duration, median (min-max) | Host CPU, mean / peak | Engine memory, peak |
|---|---|---|---|---|---|---|
| 1 | 1 | 18 s | — | 17 s | 18% / 20% | 0.46 GiB |
| 4 | 8 | 45 s | 10.7 | 18 s (17-19) | 34% / 65% | 1.35 GiB |
| 8 | 16 | 53 s | 18.1 | 22 s (22-23) | 57% / 95% | 2.38 GiB |
| 12 | 24 | 69 s | 20.9 | 29 s (28-33) | 67% / 99% | 3.09 GiB |
| 16 | 32 | 83 s | 23.1 | 37 s (33-38) | 80% / 99% | 4.18 GiB |

Makespan is the first job's creation to the last job's completion, from the API.

- **Four runners leave it mostly idle.** Four at once take 18 s against 17 s alone; the host never
  passes 65%.
- **From eight up it is CPU-bound.** Peaks at 95-99%, and each job slows: 22 s at eight, 37 s at
  sixteen, twice the uncontended time.
- **Throughput still rises past the CPU's limit, but mostly by hiding gaps.** A runner takes about
  9 s between finishing a job and starting the next (the second wave at four runners waited 27 s
  behind 18 s jobs), so more runners keep the CPU fed through those gaps. 10.7 → 18.1 → 20.9 →
  23.1 jobs a minute.
- **Memory is not the limit.** 4.2 GiB for the engine at sixteen, with 24 GiB still available.

Read with S.3: there, three at once cost the Pi 1.45× per job on compute-bound work. Here eight at
once cost 1.3× and sixteen 2.2×. If the shape holds under a real series, 8-12 is this machine's
range, against the Pi's three.

## Why it is weaker than it looks

- **Makespan is the instrument S.1 rejected**: whole seconds from the API, and it contains queueing.
  It is reported because it is what throughput is, not because it can resolve a difference.
- **On battery, `balanced` power profile.** The CPU sat near 2.4 GHz rather than boosting, so every
  number here should get better plugged in, and by an amount nothing here measures.
- **The workload is light.** Zig's own compile and tests are about 7 s of each job; heavier jobs
  saturate at fewer runners.
- **One round per arm.** Job durations within a round spread by at most 5 s, which is all this says
  about variability.

## The first round, and the mistake it repeated

The first four jobs (`runners4-cold`) ran on an empty engine: **165 s each**, against 17 s warm.
Set up job took 38 s, Install Zig 12 s, and Test 112 s, of which Zig's build summary accounts for
7 s; the rest is the engine provisioning, which §3.2.4 says to keep out of any steady-state number.

They also repeated **mistake 1**. All four had identical inputs, so Dagger ran one job's Test step
and the other three printed "Reused from Dagger's cache". The engine peaked at 152% CPU through a
round that should have had four compiles. Every later job carries `BENCH_NONCE` (run id, attempt,
slot) in its environment, the samples' `token`, and none of them was reused. MEASURE.md §3.3 says
to put the token in the step's script text; the job environment worked here, since it is part of
each step's inputs, but the script text is the place the harness checks.

## Running it

`bench.yml` goes in a test repository with a runner labelled `laptop`; `bench.sh <label> <jobs>`
dispatches one round, samples `docker stats` and `/proc/stat` every 5 s, and writes the API's jobs
to `results/<label>/`. Changing `RUNNER_COUNT` restarts the runner between rounds.

```sh
./bench.sh r8-j16 16
```

`raw/` holds each round's `jobs.json` (the API's answer), `stats.tsv` (per-container CPU and memory)
and `host.tsv` (host CPU and iowait), from which every number above can be recomputed.

## What would make it a claim

`zig build measure` with an `arm.sh` that sets `RUNNER_COUNT`, a `runners8-control` arm, rounds
interleaved, repetitions from this pilot's spread, plugged in with the `performance` profile — and
a per-job quantity, as S.2 and S.3 use, rather than makespan.
