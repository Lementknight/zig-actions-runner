#!/bin/sh
# The environment of one E6.4 trial (MEASURE.md §3.3, "capture the environment").
#
#   facts.sh <ssh-host>
#
# Only this runner's side: the hosted arm's machine is GitHub's and changes under us, which is one
# of the reasons the claim is hard to hold. `ubuntu-latest` is migrating to Ubuntu 26 from
# 2026-10-19, which the hosted arm's own log warns about — so a reading taken after that date is
# not comparable with one taken before, and that is what this field is for.
set -eu
host=${1:?ssh host}
ssh -o HostName=100.91.14.54 "$host" '
	printf "runner=%s " "$(zig-runner --version 2>/dev/null | cut -d" " -f2)"
	printf "engine=%s " "$(docker inspect -f "{{.Config.Image}}" dagger-engine-runners 2>/dev/null)"
	printf "gogc=%s " "$(docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" dagger-engine-runners 2>/dev/null | sed -n "s/^GOGC=//p")"
	printf "load=%s\n" "$(cut -d" " -f1 /proc/loadavg)"
'
