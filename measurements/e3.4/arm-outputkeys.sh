#!/bin/sh
# One trial of claim E3.4 with output keys on or off: set the flag in the unit, restart the runner,
# and measure the engine CPU of one first-run job.
#
#   arm-outputkeys.sh <true|false> <repo> <ssh-host>
#
# RUNNER_OUTPUT_KEYS is the operator's, not a workflow's, so an arm is a unit edit and a restart —
# cheap next to E7.7's engine recreate, and it needs none, because the trial's token already makes
# every step new. The engine is left alone, so its cache and page cache carry across arms, which
# interleaving is what handles.
set -eu
t0=$(date +%s)
phase() { echo "arm: [$(($(date +%s) - t0))s] $*" >&2; }
flag=${1:?true|false}
repo=${2:?repo}
host=${3:?ssh host}
pi() { ssh -o HostName=100.91.14.54 "$host" "$@"; }
# shellcheck disable=SC2016  # the remote shell expands these, not this one
cpu() { pi 'id=$(docker inspect -f "{{.Id}}" dagger-engine-runners); awk "/usage_usec/ {print \$2}" /sys/fs/cgroup/system.slice/docker-$id.scope/cpu.stat'; }

restore() {
	st=$?
	[ "$st" = 0 ] || { echo "arm: failed ($st); making sure the runner is running" >&2; pi "sudo systemctl start zig-runner" >&2 || true; }
	exit "$st"
}
trap restore EXIT

[ "$(gh run list -R "$repo" --status in_progress --json databaseId -q 'length')" = "0" ] &&
	[ "$(gh run list -R "$repo" --status queued --json databaseId -q 'length')" = "0" ] ||
	{ echo "arm: the repository is busy; the counter could not be attributed to this trial" >&2; exit 3; }

phase "setting RUNNER_OUTPUT_KEYS=$flag"
pi "sed -i 's/^Environment=RUNNER_OUTPUT_KEYS=.*/Environment=RUNNER_OUTPUT_KEYS=$flag/' /home/claude/zig-runner.service"
pi "grep -q '^Environment=RUNNER_OUTPUT_KEYS=$flag$' /home/claude/zig-runner.service" ||
	{ echo "arm: the unit does not carry the flag; refusing to measure" >&2; exit 6; }
pi "sudo install -m 0644 /home/claude/zig-runner.service /etc/systemd/system/zig-runner.service" >&2
pi "sudo systemctl daemon-reload" >&2
pi "sudo systemctl restart zig-runner" >&2
for _ in $(seq 1 40); do
	n=$(gh api "repos/$repo/actions/runners" --jq '[.runners[]|select(.status=="online")]|length' 2>/dev/null || echo 0)
	[ "${n:-0}" -ge 1 ] && break
	sleep 2
done

phase "runner restarted with the flag $flag; measuring"
before=$(cpu)
gh workflow run measure-outputkeys.yml -R "$repo" -f "token=$MEASURE_TOKEN" >&2
id=""
for _ in $(seq 1 30); do
	sleep 2
	id=$(gh run list -R "$repo" --workflow measure-outputkeys.yml -L 1 --json databaseId -q '.[0].databaseId')
	[ -n "$id" ] && break
done
[ -n "$id" ] || { echo "arm: the dispatch produced no run" >&2; exit 4; }
gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
	echo "arm: run $id did not succeed" >&2
	gh run view "$id" -R "$repo" --log-failed >&2 || true
	exit 5
}
after=$(cpu)
phase "measured run $id with RUNNER_OUTPUT_KEYS=$flag"
awk -v a="$before" -v b="$after" 'BEGIN { printf "MEASURE %.3f\n", (b - a) / 1000000 }'
