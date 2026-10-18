#!/bin/sh
# One trial of claim W.5: dispatch the sqlalchemy install job on one of the two machines, wait for
# it, and print how long the measured install took.
#
#   arm.sh <repo> <pi|hosted>
#
# The negative control needs no third workflow: run this with `pi` under a second arm name and the
# harness compares the same command against itself (that is how E6.4's `pi-control` worked).
#
# The reading comes from inside the step (`MEASURE_MS`), not from the API's step timings, which are
# whole seconds — and the study's margin for this claim was 7.2 s, so whole seconds would lose a
# tenth of it to rounding before anything else went wrong.
#
# The harness supplies $MEASURE_TOKEN, which goes into both install steps' script text, so this
# runner's arm cannot serve a replay instead of doing the work.
set -eu
repo=${1:?repo}
arm=${2:?pi or hosted}
wf="measure-install-$arm.yml"

# Like E6.4's arm and unlike E7.7's, this does not refuse to run while the repository is busy: the
# reading is taken inside the step by the clock, not from a counter another job would pollute. It
# does wait for its own run, so two trials cannot be confused.
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

log=$(gh run view "$id" -R "$repo" --log 2>/dev/null)

# The last MEASURE_MS in the log, from the `measured install` step. `cut -f3-` rather than a sed
# with \t: BSD sed does not read \t as a tab (properties/check.sh learned this the hard way).
ms=$(printf '%s\n' "$log" |
	grep -F "MEASURE_MS" | grep -vF "echo" | cut -f3- | sed 's/^[^ ]* //' |
	awk '/^MEASURE_MS/ { v = $2 } END { print v }')
[ -n "$ms" ] || { echo "arm: run $id logged no MEASURE_MS" >&2; exit 6; }

# How many packages the environment ended up with. A trial whose count differs from its neighbours'
# did not do the same work, which is the failure this claim is being re-checked for in the first
# place — so it is reported rather than left in the log.
pkgs=$(printf '%s\n' "$log" |
	grep -F "PACKAGES" | grep -vF "echo" | cut -f3- | sed 's/^[^ ]* //' |
	awk '/^PACKAGES/ { v = $2 } END { print v }')

# Report the run so a reading can be traced back to the job that produced it.
echo "arm: run $id, ${ms} ms, ${pkgs:-?} packages" >&2
awk -v ms="$ms" 'BEGIN { printf "MEASURE %.3f\n", ms / 1000 }'
