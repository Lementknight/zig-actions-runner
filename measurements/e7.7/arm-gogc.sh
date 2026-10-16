#!/bin/sh
# One trial of claim E7.7 at a given GOGC: recreate the engine with that setting, let the runner
# re-register, provision the base container in a throwaway job, then measure the 40-step job.
#
#   arm-gogc.sh <gogc> <repo> <ssh-host>
#
# GOGC is the engine process's environment, so changing it means recreating the container — which
# empties the step cache (DEPLOY.md) and is why each trial pays a provisioning job that is not
# measured. The engine's flags are DEPLOY.md's documented ones with only GOGC varied.
set -eu
t0=$(date +%s)
phase() { echo "arm: [$(($(date +%s) - t0))s] $*" >&2; }
gogc=${1:?gogc}
repo=${2:?repo}
host=${3:?ssh host}
pi() { ssh -o HostName=100.91.14.54 "$host" "$@"; }
# shellcheck disable=SC2016  # the remote shell expands these, not this one
cpu() { pi 'id=$(docker inspect -f "{{.Id}}" dagger-engine-runners); awk "/usage_usec/ {print \$2}" /sys/fs/cgroup/system.slice/docker-$id.scope/cpu.stat'; }

# Unattended, so a failure must not leave the service down: the engine is recreated before the
# runner is started, and this puts the runner back whatever happens after that.
restore() {
	st=$?
	if [ "$st" != 0 ]; then
		echo "arm: failed ($st); making sure the engine is up and the runner is running" >&2
		pi "docker start dagger-engine-runners >/dev/null 2>&1 || true"
		pi "sudo systemctl start zig-runner" >&2 || true
	fi
	exit "$st"
}
trap restore EXIT

idle() {
	[ "$(gh run list -R "$repo" --status in_progress --json databaseId -q 'length')" = "0" ] &&
		[ "$(gh run list -R "$repo" --status queued --json databaseId -q 'length')" = "0" ]
}
# Dispatches the workload with a token and waits for it. $1 is the token.
job() {
	gh workflow run measure-steps.yml -R "$repo" -f "token=$1" >&2
	id=""
	for _ in $(seq 1 30); do
		sleep 2
		id=$(gh run list -R "$repo" --workflow measure-steps.yml -L 1 --json databaseId -q '.[0].databaseId')
		[ -n "$id" ] && break
	done
	[ -n "$id" ] || { echo "arm: no run for token $1" >&2; return 4; }
	gh run watch "$id" -R "$repo" --exit-status --interval 5 >&2 || {
		echo "arm: run $id failed" >&2
		gh run view "$id" -R "$repo" --log-failed >&2 || true
		return 5
	}
	echo "$id"
}

idle || { echo "arm: the repository is busy; the counter could not be attributed to this trial" >&2; exit 3; }

phase "recreating the engine with GOGC=$gogc"
pi "sudo systemctl stop zig-runner" >&2
pi "docker rm -f dagger-engine-runners >/dev/null 2>&1 || true"
pi "docker run -d --name dagger-engine-runners --restart unless-stopped --privileged \
      --memory 4g --cpus 3 -e GOGC=$gogc -e GOMEMLIMIT=3500MiB \
      --label com.centurylinklabs.watchtower.enable=false --label wud.watch=false \
      -v dagger-engine-runners:/var/lib/dagger -v /run/dagger:/run/dagger \
      -v /home/claude/engine.json:/etc/dagger/engine.json:ro \
      registry.dagger.io/engine:v0.21.10 --addr unix:///run/dagger/engine.sock" > /dev/null
# The engine prefills 128 network namespaces at start (~9 s on the Pi, STUDY.md 8.3); wait for the
# socket rather than guess — in one ssh connection, since sixty of them cost minutes.
# shellcheck disable=SC2016  # the remote shell expands these, not this one
pi 'for _ in $(seq 1 90); do [ -S /run/dagger/engine.sock ] && exit 0; sleep 1; done; exit 1' ||
	{ echo "arm: the engine socket never appeared" >&2; exit 6; }
pi "sudo systemctl start zig-runner" >&2
for _ in $(seq 1 40); do
	n=$(gh api "repos/$repo/actions/runners" --jq '[.runners[]|select(.status=="online")]|length' 2>/dev/null || echo 0)
	[ "${n:-0}" -ge 1 ] && break
	sleep 2
done

# Not measured: the first job on a fresh engine provisions the base container.
phase "engine up and runner registered; provisioning job (not measured)"
job "provision-$MEASURE_TOKEN" > /dev/null

phase "provisioned; measuring"
before=$(cpu)
id=$(job "$MEASURE_TOKEN")
after=$(cpu)
phase "measured run $id at GOGC=$gogc"
awk -v a="$before" -v b="$after" 'BEGIN { printf "MEASURE %.3f\n", (b - a) / 1000000 }'
