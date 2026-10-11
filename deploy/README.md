# deploy

`compose.yaml` starts the read stack on one machine with one command: a local TimescaleDB loaded
with the seed, the read API (`api/Dockerfile`) and the web app (`web/Dockerfile`). Only Docker is
needed. The runner is not part of it (its image and the multi runner setup are M7).

Run every command from the repo root.

## Local mode

```sh
docker compose -f deploy/compose.yaml up --build
```

Then open <http://localhost:8080>. The run list shows the three seeded runs, and each job page
shows its steps and log lines. Add `--wait` to return once everything is healthy, or `-d` to run
in the background.

The services start in this order:

| Service | What it does |
|---|---|
| `db` | `timescale/timescaledb:latest-pg17`, ready when `pg_isready` passes. Data lives in the `db-data` volume. |
| `migrate` | One shot. Runs `dbmate up` on `db/migrations`, then `db/seed.sql`, then exits 0. Both steps are idempotent, so every `up` runs it again harmlessly. |
| `api` | The read API, started once `migrate` has exited 0. Healthy once `/api/health` reaches the database. Published on `127.0.0.1:8081` for curl. |
| `web` | The web app, started once `api` is healthy. It proxies `/api` to `http://api:8080`. Published on `127.0.0.1:8080`. |

The local database password is the throwaway `postgres`. It exists only inside this stack.

Stop and remove everything, including the database volume:

```sh
docker compose -f deploy/compose.yaml down -v
```

Add `--rmi local` to remove the three images the stack built as well.

## Tiger mode

`compose.tiger.yaml` layers on top of `compose.yaml`. The API reads `DATABASE_URL` from your
environment or from `deploy/.env`, and `db` and `migrate` do not start:

```sh
cp deploy/.env.example deploy/.env    # then set DATABASE_URL in deploy/.env
docker compose -f deploy/compose.yaml -f deploy/compose.tiger.yaml up --build
```

`DATABASE_URL` is the full Tiger connection string with `sslmode=require` and the password
percent-encoded (db/README.md). Without it, compose refuses to start and names the variable.
Nothing here migrates or seeds Tiger. Its schema comes from the `db` workflow's manual dispatch
(db/README.md), and its data comes from the runner.

## Variables

`deploy/.env.example` lists them. Copy it to `deploy/.env`, which is gitignored; compose reads it
because `deploy/` holds the first compose file.

| Variable | Default | Used by |
|---|---|---|
| `WEB_PORT` | `8080` | The host port for the web app |
| `API_PORT` | `8081` | The host port for the API |
| `DATABASE_URL` | none | Tiger mode only; required there |
