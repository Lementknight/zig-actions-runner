#!/bin/sh
# One trial of claim E6.4: dispatch the flask sync job on one of the two machines, wait for it, and
# print how long the warm `uv sync` took.
#
#   arm.sh <repo> <pi|hosted>
#
# The reading comes from inside the step (`MEASURE_MS`), not from the API's step timings, which are
# whole seconds — useless for a quantity the claim puts at 0.5 s against 0.8 s.
#
# The harness supplies $MEASURE_TOKEN, which goes into both sync steps' script text, so this
# runner's arm cannot serve a replay instead of doing the work.
set -eu
repo=${1:?repo}
arm=${2:?pi or hosted}
wf="measure-uv-$arm.yml"

# Unlike E7.7's arm this does not refuse to run while the repository is busy: the reading is taken
# inside the step by the clock, not from a counter that another job would pollute. It does wait for
# its own run, so two trials cannot be confused.
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

# The last MEASURE_MS in the log, from the `measured sync` step. `cut -f3-` rather than a sed with
# \t: BSD sed does not read \t as a tab (properties/check.sh learned this the hard way).
ms=$(gh run view "$id" -R "$repo" --log 2>/dev/null |
	grep -F "MEASURE_MS" | grep -vF "echo" | cut -f3- | sed 's/^[^ ]* //' |
	awk '/^MEASURE_MS/ { v = $2 } END { print v }')
[ -n "$ms" ] || { echo "arm: run $id logged no MEASURE_MS" >&2; exit 6; }

# Report the run so a reading can be traced back to the job that produced it.
echo "arm: run $id, ${ms} ms" >&2
awk -v ms="$ms" 'BEGIN { printf "MEASURE %.3f\n", ms / 1000 }'
