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
  -v dagger-engine-runners:/var/lib/dagger -v /run/dagger:/run/dagger \
  registry.dagger.io/engine:v0.21.10 --addr unix:///run/dagger/engine.sock
```

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

The runner itself is rarely the limit. What jobs need is CPU, memory and disk in the engine (their containers, images and caches), so set `RUNNER_COUNT` by what the machine can run at once.

## Security

- **The engine runs privileged.** Anything that can reach its socket can run containers as root on the machine. Keep the socket on the machine; a TCP listener must stay on the loopback.
- **Run trusted workflows only.** As with GitHub's own self-hosted runners, don't serve public repositories, where any fork's pull request could run code on the machine.
- **Secrets:** `GH_TOKEN` can register runners for its scope, so keep `runner.env` private (mode 0600, and it is ignored by git). Job secrets are masked in logs and step summaries.

## Not supported yet

- `container:` jobs: they fail with a clear message. (`services:` work: a Postgres service is reached at `localhost:5432` as on GitHub, and keeps its data for the whole job.)
- Windows and macOS jobs, and shells other than bash and sh.
- Steps can't be stopped at their timeout, or on cancel, with `RUNNER_ENGINE=cli`.
