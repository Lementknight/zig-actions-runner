# What the disk does

Audience: whoever decides what the Pi stores things on · Script: [`disk.sh`](disk.sh)

Run the same script on the disk in the machine and on whatever replaces it:

```sh
scp measurements/storage/disk.sh zig-pi:/tmp/ && ssh zig-pi '/tmp/disk.sh /home/claude/iotest "label"'
```

Nothing here needs root, and `--direct=1` keeps the readings off the page cache.

## The SD card in razorbill, 2026-10-17

A 119 GB card holding the OS, all of `/var/lib/docker` (15.25 GB of images, 14.32 GB of volumes) and
therefore both the Dagger engine's cache and TimescaleDB's data. Machine otherwise idle, load 0.36.

```
  4k-randread-qd1         2375 iops       9.3 MiB/s  median   0.285 ms  p99    0.473 ms
  4k-randread-qd16        3303 iops      12.9 MiB/s  median   4.424 ms  p99   15.663 ms
  4k-randwrite-qd1         702 iops       2.7 MiB/s  median   0.791 ms  p99    7.307 ms
  1m-read-qd1               67 iops      66.7 MiB/s  median  14.746 ms  p99   18.743 ms
```

**It does not scale with queue depth, which is the finding.** Sixteen requests in flight instead of
one buys 39% more throughput (2,375 → 3,303 iops) and costs 15× the latency (0.285 → 4.424 ms
median, and a p99 of 15.7 ms). A card has essentially no internal parallelism: asking it for more at
once mostly makes each request wait. That is the regime this machine runs in — three runners, a
database and the house's own services all issuing small reads at once — so the concurrency the
runner is built for is spent queueing.

**Random writes are the floor: 702 iops, 2.7 MiB/s.** This is what
[`db/compose.yaml`](../../db/compose.yaml)'s `synchronous_commit=off` is paying for, and it is why
the comment there calls it the single biggest saving in writes on flash.

**66.7 MiB/s sequential explains the recorded pathology.** The engine's cache reached 67 GB across
17,000 snapshots, the kernel's records of those files crowded out its page cache, and first runs
re-read Go's toolchain at 25-30% iowait, which made the diff after an always-run step take 13-21 s
instead of under a second ([DEPLOY.md](../../docs/DEPLOY.md), "Sizing"). At 67 MiB/s, re-reading a
few hundred megabytes of toolchain is tens of seconds of pure waiting.

## What this says about replacing it

Not measured here — there is no second disk in the machine yet, and the figures below are other
people's, on a Pi 4, from 2020 ([Geerling's USB storage
comparison](https://www.jeffgeerling.com/blog/2020/fastest-usb-storage-options-raspberry-pi/),
whose 4K random column is the relevant one). Treat them as indicative and re-run `disk.sh` to settle
it.

| | this card, measured | USB 3.0 SSD, indicative | NVMe on the Pi 5's PCIe |
|---|---|---|---|
| 4K random read | 9.3 MiB/s | ~19-20 MiB/s | an order of magnitude more |
| sequential read | 66.7 MiB/s | 220-335 MiB/s | 450 MiB/s at Gen 2 |
| scales with queue depth | **no** (1.4×) | bridge-limited | yes |

Both options are a large improvement on sequential reads and on random writes. They differ on the
thing the measurement above singles out: a USB enclosure is limited by its bridge, and every drive in
Geerling's table lands at the same 300-335 MiB/s whatever its flash, while PCIe is not. Since what
this machine does is many small reads from several processes at once, the depth column is the one to
buy on.

Geerling's thermal caveat applies more here than in his test: CI writes are sustained rather than
bursty, and he measured a bare flash drive passing 60 °C while a metal-bodied one stayed at 36 °C.
