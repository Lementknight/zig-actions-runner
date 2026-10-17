# S.1, S.2, S.3: what does running jobs at once cost this machine?

## The answer, before the method

```
S.2  one shard's forced-copy install        S.3  one shard's pytest
  io-p3          n=4  median 66.581 s        cpu-p3          n=5  median 6.300 s
  io-p1          n=5  median 24.630 s        cpu-p1          n=5  median 4.357 s
     difference -41.951  CI [-60.1, -27.5]      difference -1.943  CI [-2.44, -1.76]
  io-p3-control  n=5  median 68.739 s        cpu-p3-control  n=4  median 5.922 s
     no_effect_found                            below_the_threshold (6%)
```

Three at once costs **2.7× per job on disk-bound work and 1.45× on compute-bound work**. In
throughput — three jobs at once against three in a row — that is roughly **1.1× for I/O against 2.1×
for CPU**. Concurrency pays on both, and twenty times better on one than the other, so the machine's
configured three runners is not the wrong setting; it just earns almost nothing on jobs that saturate
the disk.

`io-p1`'s 24.6 s independently reproduces the study's 25.4 s for the same uncontended operation,
which is the best check available that the instrument measures what it claims.

**S.1 is superseded and its mistake is the point.** It summed the three shards' copying time, which
falls when fewer jobs run at once — but a sum of work-seconds says what the disk was made to do, not
how fast anything finished. It reported "two runners spend 39% less time on contended copying
(211 s → 128 s), control within 1.6%", which is true, and then that was read as "two runners are
better", which does not follow. Minimising disk burn and maximising throughput are different
objectives. S.2 measures one shard's duration instead, comparable across arms however many run at
once, and the throughput that falls out of it favours three.

What *is* true about fewer runners: three concurrent forced-copy installs take the Pi to **load 11 on
four cores**, where ssh stops answering and a database and a household's services are waiting behind
it. That is a reason to cap concurrency, and it is not a claim about CI being faster.

# S.1: do three runners over-subscribe this machine's disk?

Audience: whoever sets `RUNNER_COUNT` · Register: [CLAIMS.md](../../docs/CLAIMS.md) · Rules:
[MEASURE.md](../../docs/MEASURE.md) §3.2 · Baseline: [storage](../storage/README.md)

The first claim here that did not come from the study. It comes from a measurement instead: the SD
card gains **39% throughput for 15× the latency** at queue depth 16 (`measurements/storage/`), so a
machine running three runners, a database and a household's services may be spending its concurrency
on queueing. That is an inference, and this is the attempt to measure it.

## Written before any number existed

- **Direction claimed:** fewer runners, less time lost to contention.
- **Smallest effect worth acting on: 10% relative.** Below that, keep three — spare capacity has
  value for bursty loads, and the setting is only worth changing for a real saving.
- **Baseline:** `runners3`, the machine's configured size.
- **Negative control:** `runners3-control`, a second arm identical to the baseline. Every trial
  restarts the service, so without this arm a difference caused by restarting, or by drift across an
  hour of trials, would read as an effect of pool size.

## The workload

Three concurrent jobs, each installing flask's 214 MB environment with **`UV_LINK_MODE=copy`**. uv
normally hardlinks out of its cache, which is nearly free; forced to copy it writes every file, which
the study measured at 25.4 s uncontended. Three at once is therefore ~640 MB of small-file I/O
competing for one disk. The trial's token is in the step's script text, which is part of its cache
key, so nothing is replayed and every trial does the work.

## The quantity, and the first version that failed

**Now: the three shards' own `uv sync` timings, in milliseconds, summed** — the total time spent on
contended work.

**First attempt: the batch's makespan**, first job's start to last job's finish, from the API. It
could not see through its own noise, and the reasons are worth keeping:

- The API's job and step timings are **whole seconds**, against a quantity around 75 s.
- A makespan **contains however long the third job sat queued**, which with two runners is a large
  part of the number and nothing to do with the disk.
- It also contains checkout and `setup-uv`.

The baseline arm alone ranged 64-81 s, wider than any gap between arms, and the first pilot's answer
was "no effect found" — with a single smoke trial beforehand that had suggested 27%, from one reading
per arm. Both halves of that were a lesson: the coarse instrument hid a real effect, and the single
pair invented one.

**Makespan still matters** and is printed to stderr by each trial, because it is what a developer
waits for, and the two quantities can move in opposite directions: fewer runners should reduce
contention *and* serialise the batch. The harness records one reading per trial, so a verified
statement about makespan needs its own claim rather than a sentence here.

## Two infrastructure faults this turned up

**`EnvironmentFile=` overrides `Environment=`**, whatever order the directives appear in — systemd
reads the file shortly before starting the process, after the unit's own settings. The pool size is
set in `/etc/zig-runner.env`, so no `Environment=RUNNER_COUNT=` line in the unit can change it. The
first version of `arm.sh` did exactly that and three runners registered for a trial labelled two;
the `exactly $count` assertion is the only reason it was caught rather than silently producing two
identical arms and a confident "no effect". It now sets `--runners` on `ExecStart`, which does win,
because `Config.load` reads the environment first and the arguments second.

**Both routes to the machine are intermittent.** `razorbill.local` is mDNS and does not always
resolve from a laptop; `100.91.14.54` is Tailscale, which falls back to a relay and times out while
three jobs are hammering the disk. Four of nine trials in the first pilot died this way. Preferring
either is wrong — the first fix preferred the LAN name and the next call failed to resolve it — so
`pi()` tries both, twice, and `set_count` is one connection rather than five.

## Running it

```sh
./gen-workflow.sh > measure-io.yml        # then install it in the test repository
cd ../../runner
zig build measure -- run --claim S.1 --quantity "contended copying across 3 shards, s" \
    --min-effect 0.10 --relative --control runners3-control --reps 8 --warmup 1 \
    --out ../measurements/S.1-runners-measured.jsonl \
    --arm "runners3=../measurements/concurrency/arm.sh <repo> zig-pi 3" \
    --arm "runners3-control=../measurements/concurrency/arm.sh <repo> zig-pi 3" \
    --arm "runners2=../measurements/concurrency/arm.sh <repo> zig-pi 2" \
    --arm "runners1=../measurements/concurrency/arm.sh <repo> zig-pi 1"
./restore.sh zig-pi                       # puts RUNNER_COUNT back under /etc/zig-runner.env
```

**`restore.sh` is not optional.** Each trial pins the pool size in the unit file, so the last trial's
value stands until it is removed — a measurement that quietly reconfigures the machine it measured.

## S.7, built and not run

`cap-arm.sh` measures what the engine's cache cap costs or buys, and is kept because it works — the
experiment around it does not.

**Its arms cannot be interleaved.** The cap governs a cache that persists between trials, so a 10 GB
trial collects the volume down to 10 GB and destroys what the 20 GB trials accumulated; the next
20 GB trial starts from a cache the other arm emptied. Interleaving is what keeps drift from reading
as an effect (MEASURE.md §3.2.3), and here it makes each arm sabotage the other. Blocking the arms
brings the drift confound back, and there is no way to restore cache state between trials.

Two more reasons it was not worth the hour. The cap **is not binding**: at 20 GB the volume sits at
10.61 GB, so the comparison would be no eviction against slight eviction. And the instrument is
weak — the first run after an engine restart gave shards of 5.6 s, 21.9 s and 36.2 s for three
*serial* runs of identical work, because the engine rebuilds state progressively after a restart.

The cap's real job needs no measurement here: the pathology it exists for (67 GB across 17,000
snapshots) happened with **no cap at all**, and the observed working set is 10-19 GB. 20 GB bounds
the runaway case while binding on nothing normal.

An experiment that could answer it would need to snapshot and restore the cache volume between
trials, or to run on a machine whose cache can be filled to a known state cheaply. Neither is this
machine.
