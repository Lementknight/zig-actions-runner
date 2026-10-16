#!/bin/sh
# The property obligations, checked against a real engine (proofs/README.md, "Obligations for the
# harness"). Each check dispatches properties/property*.yml and asserts one thing about one step:
# did it run, or was it replayed? The signal is the note the runner writes into a replayed step's own
# log (`dagger.reused_note`), so this needs nothing but `gh`.
#
#   check.sh <repo> [P2|P3|P4|P6|all]
#
# What each check is the live counterpart of:
#
#   P3, P6  identical inputs, a new run: every step replayed. The run id differs by construction, so
#           this is also P3 for a volatile value — `volatile-invisible` in proofs/.
#   P2a     the subject's script text changed          → it must run (`text-matters`)
#   P2b     the workspace changed (another commit)     → it must run (`parent-matters`)
#   P2c     a non-volatile variable changed            → it must run (`stable-env-matters`)
#   P2d     the subject's position in the job changed  → it must run (`position-matters`)
#   P4      the subject names a run-specific value     → it must run, every time (`marked-misses`)
set -eu
repo=${1:?repo}
only=${2:-all}
ref_a=3a33ba578e0dd93444e0ff386cc26e665d92e31e
ref_b=60755706125129a9f9dfb99ac22f7ba016a1b60c
note="Reused from Dagger's cache"
pass=0
fail=0

idle() {
	for _ in $(seq 1 60); do
		[ "$(gh run list -R "$repo" --status in_progress --json databaseId -q 'length')" = "0" ] &&
			[ "$(gh run list -R "$repo" --status queued --json databaseId -q 'length')" = "0" ] && return 0
		sleep 5
	done
	echo "check: the repository stayed busy" >&2
	return 1
}

# dispatch <workflow> <-f flags...> → prints the run id
dispatch() {
	wf=$1
	shift
	idle
	gh workflow run "$wf" -R "$repo" "$@" > /dev/null
	id=""
	for _ in $(seq 1 30); do
		sleep 2
		id=$(gh run list -R "$repo" --workflow "$wf" -L 1 --json databaseId -q '.[0].databaseId')
		[ -n "$id" ] && break
	done
	[ -n "$id" ] || { echo "check: no run for $wf" >&2; return 1; }
	gh run watch "$id" -R "$repo" --exit-status --interval 5 > /dev/null 2>&1 || {
		echo "check: run $id failed" >&2
		gh run view "$id" -R "$repo" --log-failed >&2 || true
		return 1
	}
	echo "$id"
}

# Was <step> in <run> replayed, or did it run?
outcome() {
	if gh run view "$2" -R "$repo" --log 2>/dev/null | grep -F "	$1	" | grep -qF "$note"; then
		echo replayed
	else
		echo ran
	fi
}

# assert <name> <run id> <step name> <ran|replayed>
assert() {
	got=$(outcome "$3" "$2")
	if [ "$got" = "$4" ]; then
		printf '  ok    %-30s %s was %s\n' "$1" "$3" "$got"
		pass=$((pass + 1))
	else
		printf '  FAIL  %-30s %s was %s, wanted %s (run %s)\n' "$1" "$3" "$got" "$4" "$2"
		fail=$((fail + 1))
	fi
}

# assert_all <name> <run id> <ran|replayed>: every step of the job, which is P6 when replayed.
assert_all() {
	bad=""
	for step in "Run actions/checkout@v4" "subject plain" "after"; do
		got=$(outcome "$step" "$2")
		[ "$got" = "$3" ] || bad="$bad $step($got)"
	done
	if [ -z "$bad" ]; then
		printf '  ok    %-30s every step was %s\n' "$1" "$3"
		pass=$((pass + 1))
	else
		printf '  FAIL  %-30s wanted every step %s, but:%s (run %s)\n' "$1" "$3" "$bad" "$2"
		fail=$((fail + 1))
	fi
}

want() { [ "$only" = all ] || [ "$only" = "$1" ]; }

echo "Properties of the step cache, against the engine behind $repo's runner."
echo

# The baseline warms the cache; its own outcome is not asserted.
base=$(dispatch property.yml -f "text=base" -f "ref=$ref_a" -f "envval=base" -f "volatile=no")
printf '  --    %-30s run %s\n' "baseline" "$base"

if want P3 || want P6; then
	id=$(dispatch property.yml -f "text=base" -f "ref=$ref_a" -f "envval=base" -f "volatile=no")
	assert "P3 a volatile value changed" "$id" "subject plain" replayed
	assert_all "P6 a warm job runs nothing" "$id" replayed
fi
if want P2; then
	id=$(dispatch property.yml -f "text=changed" -f "ref=$ref_a" -f "envval=base" -f "volatile=no")
	assert "P2a the script text" "$id" "subject plain" ran
	id=$(dispatch property.yml -f "text=base" -f "ref=$ref_b" -f "envval=base" -f "volatile=no")
	assert "P2b the workspace" "$id" "subject plain" ran
	id=$(dispatch property.yml -f "text=base" -f "ref=$ref_a" -f "envval=changed" -f "volatile=no")
	assert "P2c a non-volatile variable" "$id" "subject plain" ran
	id=$(dispatch property-shifted.yml -f "text=base" -f "ref=$ref_a" -f "envval=base" -f "volatile=no")
	assert "P2d the step's position" "$id" "subject plain" ran
fi
if want P4; then
	# Twice over: a marked step must run on the second run too, which is the whole point of marking.
	id=$(dispatch property.yml -f "text=base" -f "ref=$ref_a" -f "envval=base" -f "volatile=yes")
	printf '  --    %-30s run %s\n' "P4 first run" "$id"
	id=$(dispatch property.yml -f "text=base" -f "ref=$ref_a" -f "envval=base" -f "volatile=yes")
	assert "P4 a marked step always runs" "$id" "subject volatile" ran
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
