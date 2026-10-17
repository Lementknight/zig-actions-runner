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
- **The engine's cache:** the `engine-state` volume holds images, layers, and the package and tool caches; keep it. The step cache lasts as long as the engine process (see "Restarting the engine").
- **Stopping:** `docker compose stop` sends SIGTERM. Waiting runners stop at once and remove their registrations, and running jobs finish first, for up to `stop_grace_period` (60 minutes). Raise it if your jobs run longer.
- **Updating:** `git pull`, then `docker compose -f deploy/compose.yaml up -d --build runner`. Running jobs finish before the old container exits.

The runner image ([`runner/Dockerfile`](../runner/Dockerfile)) holds only the binary and CA certificates, about 2 MB. It builds for `linux/amd64` and `linux/arm64`.

## As a systemd service

Start the engine once, with a socket on the host and a restart policy:

```sh
docker run -d --name dagger-engine-runners --restart unless-stopped --privileged \
  -e GOGC=400 \
  --label wud.watch=false --label com.centurylinklabs.watchtower.enable=false \
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

## A database for the logs

The runner keeps every line of a job (redacted, timestamped, numbered) and writes it to the
`job_logs` hypertable when `DATABASE_URL` or the `PG*` variables are set; without them it logs to
its console only. Nothing else has to be turned on — the Postgres sink is chosen by the
configuration being there (SPEC §4, §5.1).

For development, one locally:

```sh
docker compose -f db/compose.yaml up -d
export PGHOST=127.0.0.1 PGPORT=55432 PGDATABASE=zig_runner PGUSER=zig_runner \
       PGPASSWORD=zig-runner-dev PGSSLMODE=disable
cd runner && zig build run -- --db-check        # the schema, the hypertable, the version
zig test src/main.zig                           # including the tests that need a database
```

The migrations in `db/` are mounted where the Postgres image looks for them, so the schema applies
itself the first time the container starts: five tables, `job_logs` a hypertable partitioned by the
day, compressed after a day (segmented by `job_id`, ordered by `seq`) and dropped after thirty.
`docker compose -f db/compose.yaml down -v` starts over.

**Port 55432, not 5432**, because a machine may already be running a Postgres on 5432 — and the
symptom if it does is confusing rather than obvious: the container looks healthy, while the runner
connects to the *other* server and is told its role does not exist. Both machines this was written
for already had one.

### On the machine the runner runs on

The same file, with the room it is given set for a box that is also running an engine capped at 4 GB:

```sh
scp -r db/compose.yaml db/migrations <host>:~/db/
ssh <host> 'cd ~/db && ZIG_DB_MEMORY=768m ZIG_DB_CPUS=1.0 docker compose up -d'
ssh <host> 'PGHOST=127.0.0.1 PGPORT=55432 PGDATABASE=zig_runner PGUSER=zig_runner \
            PGPASSWORD=zig-runner-dev PGSSLMODE=disable zig-runner --db-check'
```

Then one line in the runner's environment file — `/etc/zig-runner.env` for the systemd service, so
the password is in a file only root can read rather than in a unit file anyone can:

```
DATABASE_URL=postgres://zig_runner:zig-runner-dev@127.0.0.1:55432/zig_runner?sslmode=disable
```

`sudo systemctl restart zig-runner`, and from the next job every line it logs is in `job_logs` as
well as on its console. Nothing else has to be switched on.

On a Raspberry Pi 5 it costs **64 MB and no measurable CPU at rest**, inside a 768 MB cap. The load
average climbs while the image is pulled and the cluster initialised, and comes back down. What it
costs that is harder to see is **writes to an SD card**: `synchronous_commit=off`, `wal_compression`
and a fifteen-minute checkpoint make them as few and as large as they can be, compression after a day
and retention at thirty bound the size, but a card is a card. A USB SSD for the data volume is the
upgrade worth making before this holds anything anyone would miss.

What this is not: how a deployed runner reaches a database. That takes `DATABASE_URL` (or `PG*`) in
the runner's environment file, pointing at a database that is backed up and not on the loopback
interface of a laptop. The runner treats a database outage as a logging problem and never as a job
failure: lines stay buffered, the next flush reconnects and retries, and if the buffer outgrows its
cap the oldest lines are dropped and counted — which is the only way a gap can appear in a job's
`seq`.

## Sizing

Measured with release builds on Linux ([SPEC §7](SPEC.md)):
- **Idle:** 20 waiting runners take 29 MB in one process.
- **Busy:** 10 concurrent jobs peak at 44 MB, about 1.5 MB per running job.

The engine's CPU is the cost to manage. `GOGC=400` on the engine (in `deploy/compose.yaml` and above) makes its garbage collector run a quarter as often: 2 collections per 10 jobs instead of 10, for about 200 MB more memory. It saves **about 15% of engine CPU on a job of 40 steps** (0.90 s of 5.93 s; 95% interval 12.7% to 24.6%, three interleaved rounds an arm with the engine recreated for each, [CLAIMS.md](CLAIMS.md) E7.7) and nothing measurable on a job of a few long steps. Keep it unless the engine's memory is the binding constraint, in which case `GOGC=100` cost nothing measurable on a four-step job and held 225 MB less heap. On a Raspberry Pi 5 with 8 GB (engine capped at 3 CPUs and 4 GB), real Node builds against a Postgres service took about 60 s each two at a time and about 3 minutes each six at a time, with the engine at its CPU cap from two jobs on: three runners is a good balance there.

Cap the engine's cache on disk. [`deploy/engine.json`](../deploy/engine.json) sets `"gc": {"maxUsedSpace": "20GB"}`; without it, Dagger lets the cache grow to about three quarters of the disk before it collects anything. On a Raspberry Pi 5 with a 117 GB SD card and the engine capped at 4 GB of memory, the cache grew to 67 GB in 17,000 snapshots. The kernel's inode cache for those files (1.4 GB) was charged to the engine and crowded out its page cache: first runs re-read Go's toolchain from the card at 25-30% iowait, and the diff after an always-run step took 13-21 s instead of under a second. Size the cap to what the jobs reuse (a few GB per project's images and caches), not to the disk.

### Restarting the engine

The engine keeps its index of cached results in memory, so restarting it (an upgrade, a reboot, recreating its container) empties the step cache: each workflow's next run replays no steps. The package and tool caches are cache volumes and survive (checked on a Raspberry Pi: a marker in the npm cache, the Go and uv toolchains, Go's modules and uv's cache were all still there after the container was recreated), so that run still finds its downloads and toolchains.

Image updaters restart the containers they update. The labels above keep [WUD](https://github.com/getwud/wud) (`wud.watch=false`) and Watchtower away from the engine. WUD compares version tags, so it would otherwise move the engine to the next Dagger release, which the runner does not speak; Watchtower restarts it only if its tag is republished. Upgrade the engine together with the runner.

The runner itself is rarely the limit. What jobs need is CPU, memory and disk in the engine (their containers, images and caches), so set `RUNNER_COUNT` by what the machine can run at once.

## Security

- **The engine runs privileged.** Anything that can reach its socket can run containers as root on the machine. Keep the socket on the machine; a TCP listener must stay on the loopback.
- **Run trusted workflows only.** As with GitHub's own self-hosted runners, don't serve public repositories, where any fork's pull request could run code on the machine.
- **Secrets:** `GH_TOKEN` can register runners for its scope, so keep `runner.env` private (mode 0600, and it is ignored by git). Job secrets are masked in logs and step summaries.

## Not supported yet

- Windows and macOS jobs, and shells other than bash and sh.
- Steps can't be stopped at their timeout, or on cancel, with `RUNNER_ENGINE=cli`.
