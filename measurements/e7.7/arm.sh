#!/bin/sh
# One trial of claim E7.7: dispatch the 40-step job, wait for it, and print the engine CPU it cost.
#
#   arm.sh <repo> <ssh-host>
#
# The harness supplies $MEASURE_TOKEN, which goes into every step's script text (gen-workflow.sh),
# so nothing is replayed. The reading is the engine container's cgroup counter across the run, which
# is the quantity STUDY.md §11.2 compares. It refuses to measure while another job is running,
# because the counter cannot then be attributed to this one.
set -eu
repo=${1:?repo}
host=${2:?ssh host}
# shellcheck disable=SC2016  # the remote shell expands these, not this one
cpu() { ssh -o HostName=100.91.14.54 "$host" 'id=$(docker inspect -f "{{.Id}}" dagger-engine-runners); awk "/usage_usec/ {print \$2}" /sys/fs/cgroup/system.slice/docker-$id.scope/cpu.stat'; }

busy=$(gh run list -R "$repo" --status in_progress --json databaseId -q 'length')
queued=$(gh run list -R "$repo" --status queued --json databaseId -q 'length')
if [ "$busy" != "0" ] || [ "$queued" != "0" ]; then
	echo "arm: $busy in progress and $queued queued: the counter could not be attributed to this trial" >&2
	exit 3
fi

before=$(cpu)
gh workflow run measure-steps.yml -R "$repo" -f "token=$MEASURE_TOKEN" >&2
# The dispatch is asynchronous; find the run it created, then wait for it.
id=""
for _ in $(seq 1 30); do
	sleep 2
	id=$(gh run list -R "$repo" --workflow measure-steps.yml -L 1 --json databaseId,createdAt -q '.[0].databaseId')
	[ -n "$id" ] && break
done
[ -n "$id" ] || { echo "arm: the dispatch produced no run" >&2; exit 4; }
gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
	echo "arm: run $id did not succeed" >&2
	gh run view "$id" -R "$repo" --log-failed >&2 || true
	exit 5
}
after=$(cpu)

# Report the run so a reading can be traced back to the job that produced it.
echo "arm: run $id" >&2
awk -v a="$before" -v b="$after" 'BEGIN { printf "MEASURE %.3f\n", (b - a) / 1000000 }'
