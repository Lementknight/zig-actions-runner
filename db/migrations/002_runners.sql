-- migrate:up
CREATE TABLE runners (
  name           TEXT PRIMARY KEY,
  status         TEXT NOT NULL CHECK (status IN ('idle', 'busy', 'offline')),
  labels         TEXT[] NOT NULL DEFAULT '{}',
  registered_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now() -- heartbeat; refreshed on every broker poll
);

-- Per-runner job counts and the current job join on jobs.runner_name.
CREATE INDEX jobs_runner_name_idx ON jobs (runner_name, status);

-- migrate:down
-- Forward-only (SPEC §4); no down migration.
