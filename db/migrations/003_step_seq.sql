-- migrate:up
-- A line's place in its own step, next to its place in the job.
--
-- `seq` is per job and gapless: it orders a job's whole log and is what the compression is ordered
-- by. `step_seq` is per step, counted from 1, and is the number the runner gives a line when it is
-- logged — the same number the live feed sends as `startLine` (see sink.CollectedLine.seq). With
-- both, a row here can be lined up with a line in the log GitHub shows, which `seq` alone cannot do.
--
-- Null where the line belongs to no step's output, which is narrower than it sounds: step 0 is a
-- real step ("Set up job", SPEC §4), and its lines are numbered from 1 like any other step's. What
-- is null is the runner's own narration around a job rather than inside it — `job acquired: 4
-- steps`, waiting for work, a job's conclusion — and any row written before this column existed.
ALTER TABLE job_logs ADD COLUMN step_seq BIGINT;

COMMENT ON COLUMN job_logs.seq IS 'Monotonic per job, gapless unless lines were dropped while the database was unreachable.';
COMMENT ON COLUMN job_logs.step_seq IS 'Monotonic per step from 1, as the runner numbered the line when it was logged; null for lines that belong to no step.';

-- Reading one step's output in order, which is what a log viewer asks for. The job-wide order is
-- already served by the primary key (job_id, seq, ts).
CREATE INDEX job_logs_step_idx ON job_logs (job_id, step_number, step_seq);

-- migrate:down
-- Forward-only (SPEC §4); no down migration. Statements here would not be inert: db/compose.yaml
-- mounts these files where the Postgres image runs them, and it runs each one whole — a real down
-- section would undo its own up section on a fresh volume, which is how this file first shipped a
-- database with no step_seq column in it.
