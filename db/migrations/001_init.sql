-- migrate:up
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE runs (
  id            BIGINT PRIMARY KEY,          -- GitHub run id
  repo          TEXT NOT NULL,
  workflow      TEXT NOT NULL,
  event         TEXT,
  branch        TEXT,
  sha           TEXT,
  status        TEXT NOT NULL,               -- queued|in_progress|completed
  conclusion    TEXT,                        -- success|failure|cancelled|NULL
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(), -- first seen; never overwritten by upserts
  completed_at  TIMESTAMPTZ
);

CREATE TABLE jobs (
  id            BIGINT PRIMARY KEY,          -- GitHub job id
  run_id        BIGINT NOT NULL REFERENCES runs(id),
  name          TEXT NOT NULL,
  runner_name   TEXT,
  status        TEXT NOT NULL,
  conclusion    TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ
);

CREATE TABLE steps (
  job_id        BIGINT NOT NULL REFERENCES jobs(id),
  number        INT NOT NULL,                -- step 0 is "Set up job"
  name          TEXT NOT NULL,
  status        TEXT NOT NULL,
  conclusion    TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  PRIMARY KEY (job_id, number)
);

CREATE TABLE job_logs (
  ts            TIMESTAMPTZ NOT NULL,
  job_id        BIGINT NOT NULL,
  step_number   INT NOT NULL,
  seq           BIGINT NOT NULL,             -- monotonic per job, assigned by runner
  stream        TEXT NOT NULL CHECK (stream IN ('stdout', 'stderr')),
  line          TEXT NOT NULL,
  PRIMARY KEY (job_id, seq, ts)
);

SELECT create_hypertable('job_logs', by_range('ts', INTERVAL '1 day'));
ALTER TABLE job_logs SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'job_id',
  timescaledb.compress_orderby   = 'seq'
);
SELECT add_compression_policy('job_logs', INTERVAL '1 day');
SELECT add_retention_policy('job_logs', INTERVAL '30 days');

CREATE INDEX runs_created_at_idx      ON runs (created_at DESC, id DESC);
CREATE INDEX runs_repo_created_at_idx ON runs (repo, created_at DESC, id DESC);
CREATE INDEX jobs_run_id_id_idx       ON jobs (run_id, id);

-- migrate:down
-- Forward-only (SPEC §4): no down migration.
