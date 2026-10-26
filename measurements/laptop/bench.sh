#!/usr/bin/env bash
# bench.sh <label> <jobs>: dispatch <jobs> bench jobs at once, sample the containers while they run,
# and print each job's queue wait and duration, plus the round's wall time and peak resource use.
set -euo pipefail
label=$1 n=$2
repo=Open-Blue/runner-bench
out=$(dirname "$0")/results/$label
mkdir -p "$out"
gh() { env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"; }

slots=$(seq -s, 1 "$n")
before=$(gh run list -R $repo -w bench.yml -L 1 --json databaseId -q '.[0].databaseId // 0')
start=$(date +%s)
gh workflow run bench.yml -R $repo -f slots="[$slots]"

run=""
until [ -n "$run" ] && [ "$run" != "$before" ]; do
	sleep 3
	run=$(gh run list -R $repo -w bench.yml -L 1 --json databaseId -q '.[0].databaseId // 0')
done
echo "run $run"

: >"$out/stats.tsv"; : >"$out/top.txt"; : >"$out/host.tsv"
read -r _ u n s i w q sq _ </proc/stat; prev_busy=$((u + n + s + q + sq)) prev_all=$((u + n + s + i + w + q + sq))
while [ "$(gh run view $run -R $repo --json status -q .status)" != completed ]; do
	docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' |
		sed "s/^/$(date +%s)\t/" >>"$out/stats.tsv"
	read -r _ u n s i w q sq _ </proc/stat; busy=$((u + n + s + q + sq)) all=$((u + n + s + i + w + q + sq))
	printf '%s\t%d\t%d\n' "$(date +%s)" $(( 100 * (busy - prev_busy) / (all - prev_all) )) $(( 100 * (w - ${prev_w:-$w}) / (all - prev_all) )) >>"$out/host.tsv"
	prev_busy=$busy prev_all=$all prev_w=$w
	{ date +%T; top -b -n1 -w 160 -o %CPU | sed -n '8,13p'; } >>"$out/top.txt"
	sleep 5
done
end=$(date +%s)

gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" >"$out/jobs.json"
gh api "repos/$repo/actions/runs/$run" >"$out/run.json"
jq -r '.jobs[] | [.name, .conclusion, .runner_name,
	((.started_at|fromdate) - (.created_at|fromdate)),
	((.completed_at|fromdate) - (.started_at|fromdate))] | @tsv' "$out/jobs.json" |
	sort -V | awk -F'\t' 'BEGIN{print "job\tresult\trunner\twait_s\trun_s"} {print}' | column -t -s$'\t'
jq -r '[.jobs[] | (.completed_at|fromdate) - (.started_at|fromdate)] |
	"job run_s: min \(min) / mean \((add/length)|floor) / max \(max)"' "$out/jobs.json"
echo "round wall (dispatch to done): $((end - start)) s"
awk -F'\t' '$2 ~ /engine/ {gsub("%","",$3); if ($3+0 > c) c = $3+0; split($4, m, " "); print m[1] > "/dev/stderr"}
	END {printf "engine peak CPU: %.0f%% (1200%% = all 12 threads)\n", c}' "$out/stats.tsv" 2>"$out/engine-mem.txt"
awk -F'\t' '{ if ($2 > c) c = $2; s += $2; w += $3 } END { printf "host CPU: mean %.0f%%, peak %.0f%%; mean iowait %.0f%%\n", s/NR, c, w/NR }' "$out/host.tsv"
echo "engine peak memory: $(sort -h "$out/engine-mem.txt" | tail -1)"
