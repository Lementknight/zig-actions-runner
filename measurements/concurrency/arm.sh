#!/bin/sh
# One trial of S.2 (a shard's duration) or S.3 (the batch's makespan), for a given workload and
# level of concurrency.
#
#   arm.sh <repo> <workflow> <shard|makespan>
#
#   arm.sh owner/repo measure-io-p3.yml shard      # how long one copy takes with three at once
#   arm.sh owner/repo measure-cpu-p2.yml makespan   # how long three test runs take, two at a time
#
# Nothing here touches the machine: the concurrency is `max-parallel` in the workflow, so there is no
# ssh, no restart, and no state to restore. That is the whole reason this replaces S.1's arm.sh.
#
# `shard` is the median of the three shards' own millisecond readings — comparable across arms that
# run different numbers of shards at once, which the sum is not. `makespan` is first start to last
# finish from the API, whole seconds, and is the quantity a developer waits for.
set -eu
repo=${1:?repo}
wf=${2:?workflow}
what=${3:?shard or makespan}

before=$(gh run list -R "$repo" --workflow "$wf" -L 1 --json databaseId -q '.[0].databaseId' 2> /dev/null || echo "")
gh workflow run "$wf" -R "$repo" -f "token=$MEASURE_TOKEN" >&2
id=""
for _ in $(seq 1 30); do
	sleep 2
	id=$(gh run list -R "$repo" --workflow "$wf" -L 1 --json databaseId -q '.[0].databaseId')
	[ -n "$id" ] && [ "$id" != "$before" ] && break
	id=""
done
[ -n "$id" ] || { echo "arm: the dispatch produced no new run" >&2; exit 4; }
gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
	echo "arm: run $id did not succeed" >&2
	gh run view "$id" -R "$repo" --log-failed >&2 || true
	exit 5
}

# All three shards are required either way: a trial missing one did less work than its arm claims.
readings=$(gh run view "$id" -R "$repo" --log 2>/dev/null |
	grep -F "MEASURE_MS" | cut -f3- | sed 's/^[^ ]* //' |
	awk '/^MEASURE_MS [0-9]+$/ { print $2 }' | sort -n)
n=$(printf '%s\n' "$readings" | grep -c . || true)
[ "$n" = "3" ] || { echo "arm: wanted 3 shard readings from run $id, got ${n:-0}" >&2; exit 6; }

span=$(gh api "repos/$repo/actions/runs/$id/jobs" --jq '[.jobs[]|{s:.started_at,c:.completed_at}]' | python3 -c '
import json, sys
from datetime import datetime
jobs = json.load(sys.stdin)
t = lambda v: datetime.strptime(v, "%Y-%m-%dT%H:%M:%SZ")
starts = [t(j["s"]) for j in jobs if j["s"]]
ends = [t(j["c"]) for j in jobs if j["c"]]
print("%.0f" % (max(ends) - min(starts)).total_seconds())
')
median=$(printf '%s\n' "$readings" | sed -n 2p)

echo "arm: run $id, $wf, shards $(printf '%s' "$readings" | tr '\n' '/' | sed 's|/$||') ms, makespan ${span}s" >&2
case "$what" in
	shard) awk -v m="$median" 'BEGIN { printf "MEASURE %.3f\n", m / 1000 }' ;;
	makespan) echo "MEASURE $span" ;;
	*) echo "arm: wanted 'shard' or 'makespan', got '$what'" >&2; exit 2 ;;
esac
