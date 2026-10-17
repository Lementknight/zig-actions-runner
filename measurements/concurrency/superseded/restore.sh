#!/bin/sh
# Puts the pool size back under the environment file's control after an S.1 run.
#
#   restore.sh <ssh-host>
#
# `arm.sh` pins RUNNER_COUNT in the unit file, and the last trial's value would otherwise stand
# indefinitely — a measurement that silently reconfigures the machine it measured. Run this when the
# run finishes, successfully or not.
set -eu
host=${1:?ssh host}
pi() { ssh -o HostName=100.91.14.54 "$host" "$@"; }

# Both of the places a trial could have pinned the size: the `--runners` flag it uses now, and the
# `Environment=` line an earlier version of arm.sh added before learning that EnvironmentFile wins.
pi "sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/zig-runner|' /home/claude/zig-runner.service"
pi "sed -i '/^Environment=RUNNER_COUNT=/d' /home/claude/zig-runner.service"
pi "sudo install -m 0644 /home/claude/zig-runner.service /etc/systemd/system/zig-runner.service"
pi "sudo systemctl daemon-reload"
pi "sudo systemctl restart zig-runner"
sleep 8
[ "$(pi 'systemctl is-active zig-runner')" = active ] || {
	echo "restore: the runner did not come back; look at its journal" >&2
	pi "sudo journalctl -u zig-runner -n 8 --no-pager" >&2 || true
	exit 7
}
echo "restore: RUNNER_COUNT is back under /etc/zig-runner.env; $(pi 'systemctl is-active zig-runner')"
