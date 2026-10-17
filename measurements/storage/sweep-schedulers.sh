#!/bin/sh
# Which I/O scheduler suits this device, measured rather than argued about.
#
#   ./sweep-schedulers.sh <device> <directory on it>
#   ./sweep-schedulers.sh mmcblk0 /home/claude/iotest
#
# Needs a user who can sudo for the scheduler writes; the benchmark itself runs unprivileged. The
# original scheduler is restored on exit, including on Ctrl-C.
#
# Worth running again on any new device. The answer is a property of the hardware, not of the
# workload: `bfq` cost this machine's SD card 12-35% of its random throughput, and an NVMe drive —
# which has real internal parallelism for a scheduler to exploit — may well prefer something else,
# or `none`.
#
# **Each scheduler is measured on a quiet disk or not at all.** The first bfq reading here was taken
# while the engine was evicting 9 GB of cache and showed 176 write iops against mq-deadline's 702 —
# a 4× collapse that was entirely the other workload. On a quiet disk it was 630. A scheduler
# comparison run against a busy device measures the other thing.
set -eu
dev=${1:?block device, e.g. mmcblk0}
dir=${2:?a directory on that device}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sched="/sys/block/$dev/queue/scheduler"
[ -r "$sched" ] || { echo "sweep: no $sched" >&2; exit 2; }

# The directory has to be on the device being measured, and writable without sudo — the benchmark
# needs no privileges, and running it as root only leaves root-owned files in someone's home. Both
# checks exist because the first run of this failed on a directory belonging to another user, which
# `disk.sh` reported as two confusing permission errors rather than as the one thing that was wrong.
mkdir -p "$dir" || { echo "sweep: cannot write to $dir — use a directory you own" >&2; exit 2; }
src=$(df --output=source "$dir" 2>/dev/null | tail -1)
case "$src" in
	/dev/"$dev"*) ;;
	*)
		echo "sweep: $dir is on ${src:-unknown}, not on /dev/$dev — readings would not be of this device" >&2
		exit 2
		;;
esac

orig=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$sched")
[ -n "$orig" ] || { echo "sweep: could not read the current scheduler" >&2; exit 2; }
echo "sweep: $dev is on '$orig'; it will be put back at the end" >&2

restore() {
	printf '%s\n' "$orig" | sudo tee "$sched" > /dev/null 2>&1 || true
	echo "sweep: restored '$orig'" >&2
}
trap restore EXIT INT TERM

# Waits for the disk to go quiet, so the reading is the scheduler's and not the neighbour's.
quiet() {
	for _ in $(seq 1 40); do
		wa=$(vmstat 2 2 | awk 'END { print $16 }')
		b=$(vmstat 1 2 | awk 'END { print $2 }')
		[ "${wa:-99}" -le 5 ] && [ "${b:-99}" -le 2 ] && return 0
		sleep 5
	done
	echo "sweep: the disk did not go quiet; readings below are not comparable" >&2
	return 0
}

for s in $(tr -d '[]' < "$sched"); do
	printf '%s\n' "$s" | sudo tee "$sched" > /dev/null 2>&1 || {
		echo "sweep: could not select '$s', skipping" >&2
		continue
	}
	quiet
	"$here/disk.sh" "$dir" "$dev under $s"
	echo
done
