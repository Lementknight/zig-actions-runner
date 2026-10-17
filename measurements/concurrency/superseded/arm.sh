#!/bin/sh
# One trial of claim S.1: set the pool size, run three concurrent I/O-heavy jobs, and print the
# makespan — first job's start to last job's finish.
#
#   arm.sh <repo> <ssh-host> <runner-count>
#
# Makespan, not per-job time, because that is what the decision is about. Fewer runners must make
# each job faster (less contention) and the batch slower (less parallelism); which wins is the
# question. Per-job time alone would answer a question nobody asked.
#
# The pool size lives in the unit file, so each trial rewrites it and restarts the service. That is
# the same mechanism properties/check.sh uses for RUNNER_OUTPUT_KEYS_MAX_MS, with the same guard: a
# configuration the runner rejects makes it exit non-zero, and `RestartPreventExitStatus` then keeps
# it down — which once left jobs queued behind a dead service for six minutes. So this refuses to go
# on unless the service came back *and* the expected number of runners registered.
set -eu
repo=${1:?repo}
host=${2:?ssh host}
count=${3:?runner count}

# **Both routes to this machine are intermittent**, which cost four of the nine trials in this
# claim's first pilot. `razorbill.local` is mDNS and does not always resolve from a laptop;
# 100.91.14.54 is Tailscale, which falls back to a relay when it cannot connect directly and then
# times out while three jobs are hammering the disk. Preferring either one is wrong — the first
# attempt at fixing this preferred the LAN name and the very next call failed to resolve it. So try
# both, twice.
#
# Also: as few calls as possible. E7.7's first attempt took twelve minutes for 105 seconds of jobs
# because every poll opened its own connection, which is why `set_count` below is one invocation
# rather than five.
pi() {
	for _ in 1 2; do
		for h in 100.91.14.54 razorbill.local; do
			ssh -o ConnectTimeout=15 -o ServerAliveInterval=5 -o HostName="$h" "$host" "$@" && return 0
		done
		sleep 5
	done
	echo "arm: no route to $host answered (tried Tailscale and mDNS, twice)" >&2
	return 1
}

idle() {
	for _ in $(seq 1 60); do
		[ "$(gh run list -R "$repo" --status in_progress --json databaseId -q 'length')" = "0" ] &&
			[ "$(gh run list -R "$repo" --status queued --json databaseId -q 'length')" = "0" ] && return 0
		sleep 5
	done
	echo "arm: the repository stayed busy" >&2
	return 3
}

set_count() {
	# The flag, not `Environment=RUNNER_COUNT=` in the unit. **systemd's `EnvironmentFile=`
	# overrides `Environment=` whatever order the two directives appear in** — the file is read
	# shortly before the process starts, after the unit's own settings — and this machine sets the
	# pool size in that file. Learned here the hard way: the `Environment=` line went in exactly
	# where intended, the file won anyway, and three runners registered for a trial labelled two.
	# The `exactly $count` check below is what caught it.
	#
	# `--runners` does win: `Config.load` reads the environment first and then the arguments
	# (runner/src/config.zig), so an argument beats both.
	pi "set -e
	    sed -i '/^Environment=RUNNER_COUNT=/d' /home/claude/zig-runner.service
	    sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/zig-runner --runners $count|' /home/claude/zig-runner.service
	    sudo install -m 0644 /home/claude/zig-runner.service /etc/systemd/system/zig-runner.service
	    sudo systemctl daemon-reload
	    sudo systemctl restart zig-runner" > /dev/null || {
		echo "arm: could not set the pool size to $count" >&2
		exit 6
	}
	sleep 8
	[ "$(pi 'systemctl is-active zig-runner')" = active ] || {
		echo "arm: the runner did not come back after the restart" >&2
		pi "sudo journalctl -u zig-runner -n 8 --no-pager" >&2 || true
		exit 7
	}
	# Exactly `count`, not "at least one": the pool size *is* the independent variable, so a trial
	# that ran with the wrong number of runners is not a trial of this arm.
	for _ in $(seq 1 30); do
		n=$(gh api "repos/$repo/actions/runners" --jq '[.runners[]|select(.status=="online")]|length' 2> /dev/null || echo 0)
		[ "${n:-0}" = "$count" ] && return 0
		sleep 2
	done
	echo "arm: wanted $count runners online, got ${n:-0}" >&2
	exit 8
}

idle
set_count

before=$(gh run list -R "$repo" --workflow measure-io.yml -L 1 --json databaseId -q '.[0].databaseId' 2> /dev/null || echo "")
gh workflow run measure-io.yml -R "$repo" -f "token=$MEASURE_TOKEN" >&2
id=""
for _ in $(seq 1 30); do
	sleep 2
	id=$(gh run list -R "$repo" --workflow measure-io.yml -L 1 --json databaseId -q '.[0].databaseId')
	[ -n "$id" ] && [ "$id" != "$before" ] && break
	id=""
done
[ -n "$id" ] || { echo "arm: the dispatch produced no new run" >&2; exit 4; }
gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
	echo "arm: run $id did not succeed" >&2
	gh run view "$id" -R "$repo" --log-failed >&2 || true
	exit 5
}

# The three shards' own millisecond readings, summed: the total time spent doing the contended work,
# which is what over-subscribing the disk costs. Not the makespan — see the note in gen-workflow.sh.
#
# All three are required. A shard whose reading is missing did not do the work, and two shards' worth
# of copying is a different experiment from three.
log=$(gh run view "$id" -R "$repo" --log 2>/dev/null)
sum=$(printf '%s\n' "$log" |
	grep -F "MEASURE_MS" | cut -f3- | sed 's/^[^ ]* //' |
	awk '/^MEASURE_MS [0-9]+$/ { total += $2; n += 1 } END { printf "%d %.3f\n", n, total / 1000 }')
n=${sum% *}
total=${sum#* }
[ "$n" = "3" ] || { echo "arm: wanted 3 shard readings from run $id, got ${n:-0}" >&2; exit 6; }

# Makespan too, on stderr only: it is the quantity a developer experiences, and the one this claim
# tried and failed to measure, so keeping it visible makes the trade-off between the two legible
# while the reading stays the fine-grained one.
span=$(gh api "repos/$repo/actions/runs/$id/jobs" --jq '[.jobs[]|{s:.started_at,c:.completed_at}]' | python3 -c '
import json, sys
from datetime import datetime
jobs = json.load(sys.stdin)
t = lambda v: datetime.strptime(v, "%Y-%m-%dT%H:%M:%SZ")
starts = [t(j["s"]) for j in jobs if j["s"]]
ends = [t(j["c"]) for j in jobs if j["c"]]
print("%.0f" % (max(ends) - min(starts)).total_seconds() if starts and ends else "?")
' 2>/dev/null || echo "?")

echo "arm: run $id, $count runners, ${total}s of contended copying across 3 shards (makespan ${span}s)" >&2
echo "MEASURE $total"
