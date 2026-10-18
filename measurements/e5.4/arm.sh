#!/bin/sh
# One trial of claim E5.4: build a new ~220 MB workspace, hand it to a Docker action, and print how
# long the action's step took.
#
#   arm.sh <repo> <root|user>
#
# The negative control needs no third workflow: run this with `root` under a second arm name.
#
# The reading is the measured step's duration from the API, in **whole seconds**. There is no
# in-step clock for this quantity: what is being timed happens while the action's container is being
# built, before its entrypoint runs. The claim is 21 s against 1-2 s, so whole seconds resolve it;
# README.md says what to do if the real effect turns out to be small enough that they do not.
set -eu
repo=${1:?repo}
arm=${2:?root or user}
wf="measure-owner-$arm.yml"
case "$arm" in
root) want_user=0 ;;
user) want_user=1001 ;;
*) echo "arm: expected root or user, got '$arm'" >&2; exit 2 ;;
esac

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
# `gh run watch --exit-status` exits non-zero both when the run failed and when the API dropped
# the connection, and those are not the same thing: a pilot trial was lost to "connection reset by
# peer" on a run that had in fact succeeded. So a watch failure is not conclusive — ask the API what
# the run's conclusion actually was, and only give up if it is not success. A transient network
# error is not a measurement outcome and must not be recorded as one.
gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
	echo "arm: watch of run $id failed; asking the API for its conclusion" >&2
	concl=""
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		concl=$(gh run view "$id" -R "$repo" --json status,conclusion \
			-q 'select(.status == "completed") | .conclusion' 2> /dev/null || echo "")
		[ -n "$concl" ] && break
		sleep 10
	done
	[ "$concl" = success ] || {
		echo "arm: run $id concluded '${concl:-unknown}'" >&2
		gh run view "$id" -R "$repo" --log-failed >&2 || true
		exit 5
	}
	echo "arm: run $id succeeded after all; the watch was the thing that failed" >&2
}

log=$(gh run view "$id" -R "$repo" --log 2>/dev/null)
field() { # $1 = the marker the action echoed
	printf '%s\n' "$log" | grep -F "$1" | grep -vF "echo" |
		cut -f3- | sed 's/^[^ ]* //' | awk -v k="$1" '$1 == k { v = $2 } END { print v }'
}

# The whole experiment turns on whether the action's image has a non-root user, because that is the
# only condition under which the runner emits `owner:`. If this is wrong the trial measured nothing,
# so it fails rather than returning a number.
got_user=$(field PROBE_USER)
[ "$got_user" = "$want_user" ] || {
	echo "arm: run $id ran as uid '${got_user:-?}', expected $want_user — this arm is not testing what it claims" >&2
	exit 7
}

# And that the workspace it received is the big one, not an empty or stale directory.
got_files=$(field PROBE_FILES)
[ "${got_files:-0}" -ge 19000 ] || {
	echo "arm: run $id saw ${got_files:-0} files in the workspace, expected ~20000" >&2
	exit 8
}

# The measured step's duration. The step is named "measured"; `jq` arithmetic on the two timestamps,
# both whole seconds.
secs=$(gh api "repos/$repo/actions/runs/$id/jobs" \
	--jq '.jobs[0].steps[] | select(.name == "measured")
	      | ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601))')
[ -n "$secs" ] || { echo "arm: run $id has no 'measured' step" >&2; exit 6; }

echo "arm: run $id, ${secs} s, uid $got_user, $got_files files" >&2
printf 'MEASURE %s\n' "$secs"
