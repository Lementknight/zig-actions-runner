#!/bin/sh
# Waits for the Pi to go quiet before a trial, so machine state is a controlled variable rather than
# whatever the previous trial left behind (MEASURE.md §3.2.4, extended past the first round).
#
#   cooldown.sh <ssh-host> [threshold] [timeout-seconds]
#
# Why this exists. E5.4's first series ran its trials back to back, and each one writes 234 MB. The
# load average never came down: W.5's series ran at a median load of 0.60, E5.4's at 3.35, and the
# negative control's interval came out 13 s wide against a 5 s threshold — the experiment could not
# see its own effect through the noise it was making. The pilot looked clean only because its first
# trials ran before the machine warmed up, which is also why dimensioning off it asked for three
# repetitions when the real spread needed far more.
#
# Load average rather than disk statistics because iowait inflates it (S.4), which here is a
# feature: what has to drain is the writes, and a load average that counts uninterruptible sleep is
# a direct reading of that.
#
# Two things it deliberately does not do. It does not drop caches — that needs root, and this user's
# sudo is deliberately narrow. And an ssh failure does not fail the trial: like the API fix in
# arm.sh, "I could not tell" must not be recorded as "the machine was busy", so it warns and lets
# the trial run, with the per-trial environment capture recording the load either way.
set -eu
host=${1:?ssh host}
threshold=${2:-1.2}
timeout=${3:-420}

waited=0
while :; do
	load=$(ssh -o HostName=100.91.14.54 -o ConnectTimeout=10 "$host" 'cut -d" " -f1 /proc/loadavg' 2> /dev/null || echo "")
	if [ -z "$load" ]; then
		echo "cooldown: could not read the load over ssh; letting the trial run" >&2
		exit 0
	fi
	if awk -v l="$load" -v t="$threshold" 'BEGIN { exit !(l < t) }'; then
		echo "cooldown: load $load after ${waited}s" >&2
		exit 0
	fi
	if [ "$waited" -ge "$timeout" ]; then
		# Non-zero so the harness skips this trial rather than taking a reading it cannot trust.
		# One skipped trial is cheaper than one misleading number.
		echo "cooldown: load still $load after ${waited}s, giving up on this trial" >&2
		exit 1
	fi
	sleep 15
	waited=$((waited + 15))
done
