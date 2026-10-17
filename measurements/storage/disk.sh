#!/bin/sh
# What the machine's disk does, in the shape this runner's workload asks of it.
#
#   disk.sh <directory> [label]
#
# Run it once on the SD card and once on whatever replaces it, with the same arguments, so the two
# are comparable. The directory must be on the disk under test and writable; nothing here needs root.
#
# **4K random reads at queue depth 1 are the number to read first.** The pathology this is for was
# never bandwidth: the engine's cache grew to 67 GB across 17,000 snapshots, the kernel's records of
# those files crowded out its page cache, and first runs re-read Go's toolchain at 25-30% iowait,
# which made the diff after an always-run step take 13-21 s instead of under a second
# (docs/DEPLOY.md, "Sizing"). That is small reads scattered over a very large file count.
#
# Queue depth 16 is here because it separates the two candidate disks in a way depth 1 does not: an
# SD card has almost no internal parallelism and barely improves, while NVMe multiplies. A USB
# enclosure sits between, limited by its bridge rather than by its flash.
#
# `--direct=1` throughout, so readings come from the disk and not from the 5 GB of page cache this
# machine happens to have free. Writes are kept short on purpose: the point is to characterise the
# disk, not to wear it.
set -eu
dir=${1:?directory on the disk under test}
label=${2:-$dir}
f="$dir/.disk-probe.$$"
# shellcheck disable=SC2064  # expand $f now, so the trap removes this run's file
trap "rm -f '$f'" EXIT INT TERM

command -v fio > /dev/null || { echo "disk.sh: fio is not installed" >&2; exit 2; }
mkdir -p "$dir"

# One number per line: name, IOPS, bandwidth, and the median and 99th-percentile latencies, because
# a disk that is fast on average and occasionally terrible is the one that produced the 13-21 s
# diffs. The 99th is where that shows.
one() { # $1 = name, $2 = rw, $3 = block size, $4 = queue depth, $5 = seconds
	out=$(fio --name="$1" --filename="$f" --size=1G --direct=1 --ioengine=libaio \
		--rw="$2" --bs="$3" --iodepth="$4" --runtime="$5" --time_based --group_reporting \
		--output-format=json 2> /dev/null) || { echo "disk.sh: fio failed for $1" >&2; return 1; }
	# Percent-formatting, not an f-string: fio's keys have to be quoted, and a backslash inside an
	# f-string's expression is a syntax error in the Python this ships with.
	printf '%s\n' "$out" | python3 -c '
import json, sys
j = json.load(sys.stdin)
job = j["jobs"][0]
side = job["read"] if job["read"]["io_bytes"] else job["write"]
lat = side["clat_ns"]
pct = lat.get("percentile", {})
p50 = pct.get("50.000000", 0) / 1e6
p99 = pct.get("99.000000", 0) / 1e6
print("  %-18s %9.0f iops  %8.1f MiB/s  median %7.3f ms  p99 %8.3f ms"
      % (job["jobname"], side["iops"], side["bw"] / 1024.0, p50, p99))
'
}

echo "disk: $label  ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "  device: $(df -h "$dir" | awk 'NR==2 {print $1, $2, "("$5" used)"}')"
echo
one "4k-randread-qd1" randread 4k 1 30
one "4k-randread-qd16" randread 4k 16 30
one "4k-randwrite-qd1" randwrite 4k 1 15
one "1m-read-qd1" read 1m 1 15
