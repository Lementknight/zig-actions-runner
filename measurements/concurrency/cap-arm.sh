#!/bin/sh
# One trial of S.7: what the engine's cache cap costs or buys.
#
#   cap-arm.sh <repo> <ssh-host> <cap in GB>
#
# The cap is read when the engine starts, so each trial rewrites `engine.json` and restarts the
# container. That empties the engine's in-memory step-cache index (docs/DEPLOY.md, "Restarting the
# engine") while the cache *volume* survives and is collected down to the new cap — so the reading is
# the first run after a restart, which is the case where a cap has either kept what the job needs or
# thrown it away. There is no warm case to measure: the restart is what changing the cap costs.
#
# Two-sided on purpose. A smaller cap means fewer files for the kernel to index, which is the
# mechanism behind the recorded pathology (67 GB across 17,000 snapshots, whose inode cache crowded
# out the engine's page cache and made first runs re-read Go's toolchain at 25-30% iowait). It also
# means more eviction. Which dominates between 10 and 20 GB is the question, and the pathology was
# observed far above both.
set -eu
repo=${1:?repo}
host=${2:?ssh host}
cap=${3:?cap in GB}

# Both routes to this machine are intermittent; see measurements/concurrency/superseded/arm.sh.
pi() {
	for _ in 1 2; do
		for h in 100.91.14.54 razorbill.local; do
			ssh -o ConnectTimeout=15 -o ServerAliveInterval=5 -o HostName="$h" "$host" "$@" && return 0
		done
		sleep 5
	done
	echo "cap-arm: no route to $host answered" >&2
	return 1
}

idle() {
	for _ in $(seq 1 60); do
		[ "$(gh run list -R "$repo" --status in_progress --json databaseId -q 'length')" = "0" ] &&
			[ "$(gh run list -R "$repo" --status queued --json databaseId -q 'length')" = "0" ] && return 0
		sleep 5
	done
	echo "cap-arm: the repository stayed busy" >&2
	return 3
}

idle
# One connection: write the cap, restart, and report what the container actually reads, so a trial
# cannot silently run at the previous cap.
live=$(pi "printf '%s\n' '{\"gc\":{\"maxUsedSpace\":\"${cap}GB\"}}' > /home/claude/engine.json &&
           docker restart dagger-engine-runners > /dev/null &&
           sleep 12 &&
           docker exec dagger-engine-runners cat /etc/dagger/engine.json") || {
	echo "cap-arm: could not set the cap to ${cap}GB" >&2
	exit 6
}
case "$live" in
	*"\"${cap}GB\""*) ;;
	*) echo "cap-arm: the engine reports $live, wanted ${cap}GB" >&2; exit 7 ;;
esac

before=$(gh run list -R "$repo" --workflow measure-io-p1.yml -L 1 --json databaseId -q '.[0].databaseId' 2> /dev/null || echo "")
gh workflow run measure-io-p1.yml -R "$repo" -f "token=$MEASURE_TOKEN" >&2
id=""
for _ in $(seq 1 30); do
	sleep 2
	id=$(gh run list -R "$repo" --workflow measure-io-p1.yml -L 1 --json databaseId -q '.[0].databaseId')
	[ -n "$id" ] && [ "$id" != "$before" ] && break
	id=""
done
[ -n "$id" ] || { echo "cap-arm: the dispatch produced no new run" >&2; exit 4; }
gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
	echo "cap-arm: run $id did not succeed" >&2
	gh run view "$id" -R "$repo" --log-failed >&2 || true
	exit 5
}

readings=$(gh run view "$id" -R "$repo" --log 2>/dev/null |
	grep -F "MEASURE_MS" | cut -f3- | sed 's/^[^ ]* //' |
	awk '/^MEASURE_MS [0-9]+$/ { print $2 }' | sort -n)
n=$(printf '%s\n' "$readings" | grep -c . || true)
[ "$n" = "3" ] || { echo "cap-arm: wanted 3 shard readings from run $id, got ${n:-0}" >&2; exit 8; }
median=$(printf '%s\n' "$readings" | sed -n 2p)

vol=$(pi "docker system df -v 2>/dev/null | awk '/^dagger-engine-runners/ { print \$3 }'" || echo "?")
echo "cap-arm: run $id, cap ${cap}GB, volume $vol, shards $(printf '%s' "$readings" | tr '\n' '/' | sed 's|/$||') ms" >&2
awk -v m="$median" 'BEGIN { printf "MEASURE %.3f\n", m / 1000 }'
