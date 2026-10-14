# Deploying the runner

The runner is one static binary that runs a pool of GitHub Actions runners in one process. Each job's steps run in a [Dagger](https://dagger.io) engine on the same machine. This guide covers three ways to run it: with Docker Compose, as a systemd service, or as a plain binary. All configuration is described in [SPEC §2](SPEC.md).

## What you need

- A Linux machine (x86-64 or arm64) with Docker. The engine runs each step in a container of its own.
- A token that can register self-hosted runners for the repository or organization, set as `GH_TOKEN`:
  - A fine-grained token:
    - For a repository: the permission **Administration: read and write**.
    - For an organization: **Self-hosted runners: read and write**.
  - Or a classic token: `repo` for a repository, `admin:org` for an organization.
- Workflows that select the runner: `runs-on: [self-hosted, zig]`, with the labels in `RUNNER_LABELS`.

The runner registers just-in-time runners itself, so there is no `config.sh` step and nothing to clean up. Each job gets a fresh registration, which is removed when the job ends, or when the runner stops while waiting.

## With Docker Compose

[`deploy/compose.yaml`](../deploy/compose.yaml) starts the engine and a runner pool together:

```sh
cp deploy/runner.env.example deploy/runner.env   # fill in GH_TOKEN and GH_SCOPE
docker compose -f deploy/compose.yaml up -d --build
docker compose -f deploy/compose.yaml logs -f runner
```

- **How the two connect:** the runner reaches the engine through a unix socket on a shared volume. The runner container gets no Docker socket, and the engine opens no network listener.
- **Number of concurrent jobs:** `RUNNER_COUNT` in `runner.env`.
- **The engine's cache:** the `engine-state` volume holds images, layers, and the step and package caches. Keep it between restarts; that's what makes repeated jobs fast.
- **Stopping:** `docker compose stop` sends SIGTERM. Waiting runners stop at once and remove their registrations, and running jobs finish first, for up to `stop_grace_period` (60 minutes). Raise it if your jobs run longer.
- **Updating:** `git pull`, then `docker compose -f deploy/compose.yaml up -d --build runner`. Running jobs finish before the old container exits.

The runner image ([`runner/Dockerfile`](../runner/Dockerfile)) holds only the binary and CA certificates, about 2 MB. It builds for `linux/amd64` and `linux/arm64`.

## As a systemd service

Start the engine once, with a socket on the host and a restart policy:

```sh
docker run -d --name dagger-engine-runners --restart unless-stopped --privileged \
  -e GOGC=400 \
  -v dagger-engine-runners:/var/lib/dagger -v /run/dagger:/run/dagger \
  -v "$PWD/deploy/engine.json:/etc/dagger/engine.json:ro" \
  registry.dagger.io/engine:v0.21.10 --addr unix:///run/dagger/engine.sock
```

On a machine that also runs other services, cap the engine and lower its CPU priority, so CI cannot starve them: add `--memory 4g --memory-swap 4g --cpus 3 --cpu-shares 128 -e GOMEMLIMIT=3500MiB` (`GOMEMLIMIT` makes the engine collect harder near the cap instead of hitting it). On Raspberry Pi OS the memory cap needs `cgroup_enable=memory` added to `/boot/firmware/cmdline.txt` and a reboot; without it Docker ignores `--memory`.

Then install the binary (from a release, or `zig build -Doptimize=ReleaseSafe -Dstrip` in `runner/`), its configuration and [`deploy/zig-runner.service`](../deploy/zig-runner.service):

```sh
sudo install -m 0755 zig-out/bin/runner /usr/local/bin/zig-runner
sudo install -m 0600 deploy/runner.env /etc/zig-runner.env
sudo cp deploy/zig-runner.service /etc/systemd/system/
sudo systemctl enable --now zig-runner
journalctl -u zig-runner -f
```

`systemctl stop` sends SIGTERM and waits up to `TimeoutStopSec` (60 minutes) for running jobs.

## As a plain binary

Without `RUNNER_ENGINE_HOST`, the runner reaches the engine through the Docker API (`/var/run/docker.sock`). It uses the engine container that the `dagger` CLI of the same version starts (`dagger-engine-v0.21.10`), so a machine where `dagger` has run once is enough:

```sh
GH_TOKEN=... GH_SCOPE=owner/repo ./runner --runners 4
```

Each connection then costs a `buildctl dial-stdio` process in the engine container, about 11 MB each, three per job. The socket setups above avoid that.

## Sizing

Measured with release builds on Linux ([SPEC §7](SPEC.md)):
- **Idle:** 20 waiting runners take 29 MB in one process.
- **Busy:** 10 concurrent jobs peak at 44 MB, about 1.5 MB per running job.

The engine's CPU is the cost to manage. `GOGC=400` on the engine (in `deploy/compose.yaml` and above) makes its garbage collector run a quarter as often: 2 collections per 10 jobs instead of 10, about 200 MB more memory, 6% less engine CPU per job on a Mac and 13% on a Raspberry Pi 5. On a Raspberry Pi 5 with 8 GB (engine capped at 3 CPUs and 4 GB), real Node builds against a Postgres service took about 60 s each two at a time and about 3 minutes each six at a time, with the engine at its CPU cap from two jobs on: three runners is a good balance there.

Cap the engine's cache on disk. [`deploy/engine.json`](../deploy/engine.json) sets `"gc": {"maxUsedSpace": "20GB"}`; without it, Dagger lets the cache grow to about three quarters of the disk before it collects anything. On a Raspberry Pi 5 with a 117 GB SD card and the engine capped at 4 GB of memory, the cache grew to 67 GB in 17,000 snapshots. The kernel's inode cache for those files (1.4 GB) was charged to the engine and crowded out its page cache: first runs re-read Go's toolchain from the card at 25-30% iowait, and the diff after an always-run step took 13-21 s instead of under a second. Size the cap to what the jobs reuse (a few GB per project's images and caches), not to the disk.

The engine keeps its index of cached results in memory, so restarting it (an upgrade, a reboot) makes the next jobs run without step-cache hits.

The runner itself is rarely the limit. What jobs need is CPU, memory and disk in the engine (their containers, images and caches), so set `RUNNER_COUNT` by what the machine can run at once.

## Security

- **The engine runs privileged.** Anything that can reach its socket can run containers as root on the machine. Keep the socket on the machine; a TCP listener must stay on the loopback.
- **Run trusted workflows only.** As with GitHub's own self-hosted runners, don't serve public repositories, where any fork's pull request could run code on the machine.
- **Secrets:** `GH_TOKEN` can register runners for its scope, so keep `runner.env` private (mode 0600, and it is ignored by git). Job secrets are masked in logs and step summaries.

## Not supported yet

- Windows and macOS jobs, and shells other than bash and sh.
- Steps can't be stopped at their timeout, or on cancel, with `RUNNER_ENGINE=cli`.
