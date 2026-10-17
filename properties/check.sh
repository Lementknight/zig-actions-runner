#!/bin/sh
# The property obligations, checked against a real engine (proofs/README.md, "Obligations for the
# harness"). Each check dispatches properties/property*.yml and asserts one thing about one step:
# did it run, or was it replayed? The signal is the note the runner writes into a replayed step's own
# log (`dagger.reused_note`), so this needs nothing but `gh`.
#
#   check.sh <repo> [P1|P2|P3|P4|P6|E1|B|R2|all] [ssh host, for E1 and B]
#
# What each check is the live counterpart of:
#
#   P3, P6  identical inputs, a new run: every step replayed. This is also P3 for a volatile value
#           (`volatile-invisible` in proofs/), though not for the reason it reads like: the subject
#           does not see a differing run id any more. The container still carries the real one, which
#           differs every run and is still left out of the exec key, and that is what the replay
#           demonstrates. What the step itself sees is the sentinel, because enforcement overrides it
#           in the step's own env prefix. The property is about the key, not about anything the
#           subject could print.
#   P2a     the subject's script text changed          → it must run (`text-matters`)
#   P2b     the workspace changed (another commit)     → it must run (`parent-matters`)
#   P2c     a non-volatile variable changed            → it must run (`stable-env-matters`)
#   P2d     the subject's position in the job changed  → it must run (`position-matters`)
#   P4      the subject names a run-specific value     → it must run, every time (`marked-misses`)
#   P1      the same job with the cache off, then replayed → the observer said the same thing
#           (`replay≡run`), which also covers $GITHUB_ENV: what it said includes a variable an
#           earlier step exported, and on the replayed run that step was replayed too
#   E1      a marked step leaving the same bytes → the steps after it are replayed anyway
#           (`cutoff`); leaving new bytes → they run (`different-bytes-different-container`)
set -eu
repo=${1:?repo}
only=${2:-all}
# E1 needs the engine's host: output keys are what it tests, and they stop themselves when they cost
# more than RUNNER_OUTPUT_KEYS_MAX_MS, which the first run of this check tripped at 10.5 s against a
# 10 s limit. Testing whether they cut off is not testing whether they are cheap, so the limit is
# raised for the duration and put back afterwards.
ssh_host=${3:-}
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

# dispatch_bg <workflow> <flags...> → prints the run id without waiting for it, and without
# waiting for the repository to be idle: the point of R2 is two jobs at once.
dispatch_bg() {
	wf=$1
	shift
	before=$(gh run list -R "$repo" --workflow "$wf" -L 1 --json databaseId -q '.[0].databaseId' 2> /dev/null || echo "")
	gh workflow run "$wf" -R "$repo" "$@" > /dev/null
	for _ in $(seq 1 30); do
		sleep 2
		id=$(gh run list -R "$repo" --workflow "$wf" -L 1 --json databaseId -q '.[0].databaseId')
		[ -n "$id" ] && [ "$id" != "$before" ] && break
	done
	[ -n "$id" ] && [ "$id" != "$before" ] || { echo "check: no new run for $wf" >&2; return 1; }
	echo "$id"
}

wait_run() {
	gh run watch "$1" -R "$repo" --exit-status --interval 5 > /dev/null 2>&1 || {
		echo "check: run $1 did not succeed" >&2
		gh run view "$1" -R "$repo" --log-failed >&2 || true
		return 1
	}
}

# $1 is before $2. ISO-8601 of one shape sorts lexicographically, and `sort` is POSIX where `\<`
# is not.
earlier() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -n 1)" = "$1" ]
}

# Did two runs overlap in time? Concurrency that did not happen proves nothing.
overlapped() {
	a_s=$(gh run view "$1" -R "$repo" --json startedAt -q .startedAt)
	a_e=$(gh run view "$1" -R "$repo" --json updatedAt -q .updatedAt)
	b_s=$(gh run view "$2" -R "$repo" --json startedAt -q .startedAt)
	b_e=$(gh run view "$2" -R "$repo" --json updatedAt -q .updatedAt)
	earlier "$a_s" "$b_e" && earlier "$b_s" "$a_e"
}

# Was <step> in <run> replayed, or did it run?
outcome() {
	if gh run view "$2" -R "$repo" --log 2>/dev/null | grep -F "	$1	" | grep -qF "$note"; then
		echo replayed
	else
		echo ran
	fi
}

# `cut -f3-` rather than a sed with \t: BSD sed does not read \t as a tab, so the field-stripping
# version did nothing on macOS and two assertions compared empty strings without saying so.
#
# said <step> <run id>: what the step printed — only its `observed <key>=<value>` lines, so the
# comparison is of output and not of the script echoed above it, which is identical by construction.
said() {
	gh run view "$2" -R "$repo" --log 2>/dev/null |
		grep -F "	$1	" | cut -f3- | sed 's/^[^ ]* //' |
		grep -vF "$note" | grep -E '^observed [a-z]+=' | sort
}

# value <key> <run id> <step>: one `observed <key>=<value>` line's value.
value() {
	gh run view "$2" -R "$repo" --log 2>/dev/null |
		grep -F "	$3	" | cut -f3- | sed 's/^[^ ]* //' |
		grep -E "^observed $1=" | head -1 | cut -d= -f2- | tr -d '\r'
}

# assert_eq <name> <what> <got> <wanted>
assert_eq() {
	if [ "$3" = "$4" ]; then
		printf '  ok    %-30s %s is %s\n' "$1" "$2" "$3"
		pass=$((pass + 1))
	else
		printf '  FAIL  %-30s %s is %s, wanted %s\n' "$1" "$2" "$3" "$4"
		fail=$((fail + 1))
	fi
}

# assert_ne <name> <what> <a> <b>
assert_ne() {
	if [ "$3" != "$4" ]; then
		printf '  ok    %-30s %s differs (%s against %s)\n' "$1" "$2" "$3" "$4"
		pass=$((pass + 1))
	else
		printf '  FAIL  %-30s %s is the same in both (%s), wanted a difference\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

# assert_same <name> <run a> <run b> <step>: the step produced the same thing in both runs.
assert_same() {
	a=$(said "$4" "$2")
	b=$(said "$4" "$3")
	if [ -n "$a" ] && [ "$a" = "$b" ]; then
		printf '  ok    %-30s %s said the same in both runs (%s lines)\n' "$1" "$4" "$(printf '%s\n' "$a" | wc -l | tr -d ' ')"
		pass=$((pass + 1))
	else
		printf '  FAIL  %-30s %s differed between runs %s and %s\n' "$1" "$4" "$2" "$3"
		printf '        cache off: %s\n' "$a"
		printf '        replayed : %s\n' "$b"
		fail=$((fail + 1))
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

# Output keys stop themselves when they cost more than RUNNER_OUTPUT_KEYS_MAX_MS, and the first run
# of these checks tripped that at 10.5 s against a 10 s limit. E1 and B are about what output keys
# *do*, not what they cost, so they raise the limit for their own duration and put it back. E3.4 in
# docs/CLAIMS.md is the claim that measures the cost.
raised=""
pi() { ssh -o HostName=100.91.14.54 "$ssh_host" "$@"; }
set_limit() { # $1 = milliseconds, or empty to remove the line
	if [ -n "$1" ]; then
		pi "grep -q '^Environment=RUNNER_OUTPUT_KEYS_MAX_MS=' /home/claude/zig-runner.service &&
		    sed -i 's/^Environment=RUNNER_OUTPUT_KEYS_MAX_MS=.*/Environment=RUNNER_OUTPUT_KEYS_MAX_MS=$1/' /home/claude/zig-runner.service ||
		    sed -i '/^Environment=RUNNER_OUTPUT_KEYS=/a Environment=RUNNER_OUTPUT_KEYS_MAX_MS=$1' /home/claude/zig-runner.service"
	else
		pi "sed -i '/^Environment=RUNNER_OUTPUT_KEYS_MAX_MS=/d' /home/claude/zig-runner.service"
	fi
	pi "sudo install -m 0644 /home/claude/zig-runner.service /etc/systemd/system/zig-runner.service"
	pi "sudo systemctl daemon-reload"
	pi "sudo systemctl restart zig-runner"
	sleep 8
	# A config the runner rejects makes it exit 1, and RestartPreventExitStatus keeps it down. That
	# happened once here, with jobs queueing behind a dead service, so this refuses to go on.
	[ "$(pi "systemctl is-active zig-runner")" = active ] || {
		echo "check: the runner did not come back after the restart; look at its journal" >&2
		pi "sudo journalctl -u zig-runner -n 5 --no-pager" >&2 || true
		exit 7
	}
	for _ in $(seq 1 30); do
		n=$(gh api "repos/$repo/actions/runners" --jq '[.runners[]|select(.status=="online")]|length' 2> /dev/null || echo 0)
		[ "${n:-0}" -ge 1 ] && return 0
		sleep 2
	done
	echo "check: no runner registered after the restart; refusing to queue jobs behind it" >&2
	exit 8
}
restore_limit() {
	[ -n "$raised" ] || return 0
	set_limit "$was"
	printf '  --    %-30s %s\n' "limit restored" "${was:-the default}"
}
need_output_keys() {
	[ -n "$ssh_host" ] || { echo "check: this check needs the engine's ssh host as the third argument" >&2; exit 2; }
	[ -z "$raised" ] || return 0
	was=$(pi "sed -n 's/^Environment=RUNNER_OUTPUT_KEYS_MAX_MS=//p' /home/claude/zig-runner.service")
	trap restore_limit EXIT
	set_limit 600000
	raised=yes
	printf '  --    %-30s %s\n' "limit raised to 600 s" "(was ${was:-the 10 s default})"
}

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

if want P1; then
	# The same job with the step cache off, then warm, then replayed: what the observer said must
	# not depend on whether it ran or was replayed. This is also the $GITHUB_ENV obligation, since
	# what it says includes a variable an earlier step exported — and on the replayed run, that
	# earlier step was replayed too.
	off=$(dispatch property-replay.yml -f "step_cache=false")
	assert "P1 the cache off runs everything" "$off" "observe" ran
	warm=$(dispatch property-replay.yml -f "step_cache=true")
	printf '  --    %-30s run %s\n' "P1 warming" "$warm"
	on=$(dispatch property-replay.yml -f "step_cache=true")
	assert "P1 then it is replayed" "$on" "observe" replayed
	assert "GITHUB_ENV the exporter too" "$on" "export" replayed
	assert_same "P1 replay equals run" "$off" "$on" "observe"
fi
if want E1; then
	need_output_keys
	# Early cutoff: a marked step always runs, but the steps after it are replayed when it leaves
	# the same bytes, and run when it does not.
	id=$(dispatch property-cutoff.yml -f "stable=yes")
	printf '  --    %-30s run %s\n' "E1 warming (stable output)" "$id"
	id=$(dispatch property-cutoff.yml -f "stable=yes")
	assert "E1 the marked step runs" "$id" "marked" ran
	assert "E1 but the reader after it" "$id" "reader" replayed
	assert "E1 and the step after that" "$id" "after" replayed
	id=$(dispatch property-cutoff.yml -f "stable=no")
	printf '  --    %-30s run %s\n' "E1 warming (new output)" "$id"
	id=$(dispatch property-cutoff.yml -f "stable=no")
	assert "E1 new bytes, no cutoff" "$id" "reader" ran
fi

if want B; then
	need_output_keys
	echo
	echo "  Blind spots. These assert that the design still cannot see what it cannot see:"
	echo "  if B2 or B3 FAILS, detection has improved and the documents are out of date."
	echo "  B1 is the one that has been answered: still undetected, but no longer answered wrongly."
	echo

	# B1: a step that reads the run id without naming it (counterexample 1, SPEC.md's
	# "not detected"). Detection is still blind, and that half is what the first assertion holds to:
	# `readsRunSpecific` is syntactic, the script never spells the name, so the step is step-cached
	# and replayed.
	#
	# What the step then *sees* is no longer an earlier run's id. Until enforcement shipped this
	# check asserted staleness — and caught an id forty minutes old — but a step-cached step now gets
	# `zig-runner-withheld` written over every volatile value it did not name, so the wrong answer
	# became an absent one (`volatile-clause-discharged`, proofs/Runner/Enforce.agda; SPEC.md §9).
	# Asserting the sentinel rather than "not this run's id" matters because the sentinel satisfies
	# that older assertion too: it would have passed while testing nothing.
	#
	# The cache-off arm is what keeps this from being one-sided, the way B2's is. The sentinel is
	# written on every run of a step-cached step, cold ones included, so its presence says nothing
	# about replay — `enforce_volatile = step_cache and opts.enforce_volatile` (dagger.zig) is what
	# it is evidence of. With the cache off the same step must see the real id, or "it is told no run
	# id" would be indistinguishable from the runner withholding it from everything.
	off=$(dispatch property-blind.yml -f "spot=volatile" -f "step_cache=false")
	dispatch property-blind.yml -f "spot=volatile" -f "step_cache=true" > /dev/null
	b=$(dispatch property-blind.yml -f "spot=volatile" -f "step_cache=true")
	assert "B1 an unseen volatile read" "$b" "blind volatile" replayed
	assert_eq "B1 is told no run id at all" "the run id it printed" "$(value runid "$b" "blind volatile")" "zig-runner-withheld"
	assert_eq "B1 but a run of it is told" "the cache-off id" "$(value runid "$off" "blind volatile")" "$off"

	# B2: a step whose answer is not a function of its inputs (counterexample 3). The cache freezes
	# the first answer, so a flaky step cannot fail twice.
	off=$(dispatch property-blind.yml -f "spot=flaky" -f "step_cache=false")
	warm=$(dispatch property-blind.yml -f "spot=flaky" -f "step_cache=true")
	frozen=$(dispatch property-blind.yml -f "spot=flaky" -f "step_cache=true")
	assert "B2 a flaky step" "$frozen" "blind flaky" replayed
	assert_eq "B2 the cache froze its answer" "the value" "$(value nondeterminism "$frozen" "blind flaky")" "$(value nondeterminism "$warm" "blind flaky")"
	assert_ne "B2 which a run would not" "the cache-off value" "$(value nondeterminism "$off" "blind flaky")" "$(value nondeterminism "$warm" "blind flaky")"

	# B3: a step that reads a cache volume (counterexample 4). The volume's content is in no key, so
	# the reader is replayed although an always-run step rewrote what it reads.
	dispatch property-blind.yml -f "spot=mount" -f "step_cache=true" > /dev/null
	b=$(dispatch property-blind.yml -f "spot=mount" -f "step_cache=true")
	assert "B3 a cache-volume read" "$b" "blind mount" replayed
	assert_ne "B3 it reports stale content" "the marker it read" "$(value marker "$b" "blind mount")" "$b"
fi

if want R2; then
	# A cache a pool shares is safe (`elsewhere⇒ahead`): two jobs at once must each get its own
	# answer, not the other's. Each job has its own session for exactly this reason (SPEC.md).
	a=$(dispatch_bg property.yml -f "text=base" -f "ref=$ref_a" -f "envval=concurrent-a" -f "volatile=no")
	b=$(dispatch_bg property.yml -f "text=base" -f "ref=$ref_a" -f "envval=concurrent-b" -f "volatile=no")
	wait_run "$a"
	wait_run "$b"
	if overlapped "$a" "$b"; then
		printf '  ok    %-30s runs %s and %s\n' "R2 the two jobs overlapped" "$a" "$b"
		pass=$((pass + 1))
	else
		printf '  FAIL  %-30s %s and %s did not overlap, so this proves nothing\n' "R2 concurrency" "$a" "$b"
		fail=$((fail + 1))
	fi
	assert_eq "R2 the first got its own value" "what it observed" "$(value env "$a" "subject plain")" "concurrent-a"
	assert_eq "R2 and the second got its own" "what it observed" "$(value env "$b" "subject plain")" "concurrent-b"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
