#!/bin/sh
# The environment a trial ran in (MEASURE.md §3.3): the engine's GOGC and image, how much cache it
# holds and in how many snapshots, its memory and how often it has hit its cap, and the host's load.
set -eu
host=${1:-zig-pi}
ssh -o HostName=100.91.14.54 "$host" '
  id=$(docker inspect -f "{{.Id}}" dagger-engine-runners)
  gogc=$(docker inspect -f "{{json .Config.Env}}" dagger-engine-runners | tr "," "\n" | sed -n "s/.*GOGC=\([0-9]*\).*/\1/p")
  image=$(docker inspect -f "{{.Config.Image}}" dagger-engine-runners)
  cache=$(docker exec dagger-engine-runners du -sm /var/lib/dagger 2>/dev/null | cut -f1)
  mem=$(awk "/^anon /{print \$2}" /sys/fs/cgroup/system.slice/docker-$id.scope/memory.stat)
  caps=$(awk "/^max /{print \$2}" /sys/fs/cgroup/system.slice/docker-$id.scope/memory.events)
  load=$(cut -d" " -f1 /proc/loadavg)
  runner=$(systemctl is-active zig-runner)
  printf "{\"gogc\":%s,\"image\":\"%s\",\"cache_mb\":%s,\"engine_anon_bytes\":%s,\"mem_cap_hits\":%s,\"load1\":%s,\"runner\":\"%s\"}" \
    "${gogc:-null}" "$image" "${cache:-null}" "${mem:-null}" "${caps:-null}" "$load" "$runner"
'
