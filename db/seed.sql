-- Demo data for the read API and web/src/api/contract.test.ts.
-- Re-runnable: rows are ON CONFLICT DO NOTHING; log lines are inserted only for jobs that have none
-- (job_logs' primary key includes ts, so ON CONFLICT cannot de-duplicate now()-relative rows). Timestamps are relative to now()
-- so the log rows stay inside the 30 day retention window.

-- Completed run: one job, steps 0..3, 6 log lines (seq 1..6, no gaps).
INSERT INTO runs (id, repo, workflow, event, branch, sha, status, conclusion, created_at, completed_at) VALUES
  (9000000001, 'Lementknight/zig-actions-runner', 'CI', 'push', 'main',
   '0123456789abcdef0123456789abcdef01234567', 'completed', 'success',
   now() - interval '10 minutes', now() - interval '9 minutes')
ON CONFLICT DO NOTHING;

INSERT INTO jobs (id, run_id, name, runner_name, status, conclusion, started_at, completed_at) VALUES
  (9100000001, 9000000001, 'build', 'zig-runner-1', 'completed', 'success',
   now() - interval '10 minutes', now() - interval '9 minutes')
ON CONFLICT DO NOTHING;

INSERT INTO steps (job_id, number, name, status, conclusion, started_at, completed_at) VALUES
  (9100000001, 0, 'Set up job',    'completed', 'success', now() - interval '600 seconds', now() - interval '595 seconds'),
  (9100000001, 1, 'Checkout',      'completed', 'success', now() - interval '595 seconds', now() - interval '590 seconds'),
  (9100000001, 2, 'Build',         'completed', 'success', now() - interval '590 seconds', now() - interval '560 seconds'),
  (9100000001, 3, 'Test',          'completed', 'success', now() - interval '560 seconds', now() - interval '540 seconds')
ON CONFLICT DO NOTHING;

INSERT INTO job_logs (ts, job_id, step_number, seq, stream, line)
SELECT * FROM (VALUES
  (now() - interval '600 seconds', 9100000001, 0, 1, 'stdout', 'Set up job'),
  (now() - interval '595 seconds', 9100000001, 1, 2, 'stdout', 'Syncing repository: Lementknight/zig-actions-runner'),
  (now() - interval '590 seconds', 9100000001, 2, 3, 'stdout', E'\x1b[32mBuilding\x1b[0m runner'),
  (now() - interval '575 seconds', 9100000001, 2, 4, 'stderr', 'warning: unused local constant'),
  (now() - interval '560 seconds', 9100000001, 3, 5, 'stdout', 'All 12 tests passed.'),
  (now() - interval '540 seconds', 9100000001, 3, 6, 'stdout', 'Job completed successfully')
) AS v(ts, job_id, step_number, seq, stream, line)
WHERE NOT EXISTS (SELECT 1 FROM job_logs WHERE job_id = 9100000001);

-- In-progress run: one job mid-build, steps 0..2, 3 log lines so far.
INSERT INTO runs (id, repo, workflow, event, branch, sha, status, conclusion, created_at, completed_at) VALUES
  (9000000002, 'Lementknight/zig-actions-runner', 'CI', 'pull_request', 'feature/tiger-db-schema',
   'fedcba9876543210fedcba9876543210fedcba98', 'in_progress', NULL,
   now() - interval '30 seconds', NULL)
ON CONFLICT DO NOTHING;

INSERT INTO jobs (id, run_id, name, runner_name, status, conclusion, started_at, completed_at) VALUES
  (9100000002, 9000000002, 'build', 'zig-runner-1', 'in_progress', NULL,
   now() - interval '30 seconds', NULL)
ON CONFLICT DO NOTHING;

INSERT INTO steps (job_id, number, name, status, conclusion, started_at, completed_at) VALUES
  (9100000002, 0, 'Set up job', 'completed',   'success', now() - interval '30 seconds', now() - interval '25 seconds'),
  (9100000002, 1, 'Checkout',   'completed',   'success', now() - interval '25 seconds', now() - interval '20 seconds'),
  (9100000002, 2, 'Build',      'in_progress', NULL,      now() - interval '20 seconds', NULL)
ON CONFLICT DO NOTHING;

INSERT INTO job_logs (ts, job_id, step_number, seq, stream, line)
SELECT * FROM (VALUES
  (now() - interval '30 seconds', 9100000002, 0, 1, 'stdout', 'Set up job'),
  (now() - interval '25 seconds', 9100000002, 1, 2, 'stdout', 'Syncing repository: Lementknight/zig-actions-runner'),
  (now() - interval '20 seconds', 9100000002, 2, 3, 'stdout', E'\x1b[32mBuilding\x1b[0m runner')
) AS v(ts, job_id, step_number, seq, stream, line)
WHERE NOT EXISTS (SELECT 1 FROM job_logs WHERE job_id = 9100000002);

-- Failed run modelled on runner/testdata/job-mixed.json: step 4 fails but continues
-- (continueOnError), step 6 fails the job, step 7 is skipped, step 8 runs via always().
-- 11 log lines (seq 1..11, no gaps); the skipped step 7 logs nothing.
INSERT INTO runs (id, repo, workflow, event, branch, sha, status, conclusion, created_at, completed_at) VALUES
  (9000000003, 'Lementknight/zig-actions-runner', 'CI', 'push', 'feature/job-loop',
   'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'completed', 'failure',
   now() - interval '5 minutes', now() - interval '4 minutes')
ON CONFLICT DO NOTHING;

INSERT INTO jobs (id, run_id, name, runner_name, status, conclusion, started_at, completed_at) VALUES
  (9100000003, 9000000003, 'mixed', 'zig-runner-1', 'completed', 'failure',
   now() - interval '5 minutes', now() - interval '4 minutes')
ON CONFLICT DO NOTHING;

INSERT INTO steps (job_id, number, name, status, conclusion, started_at, completed_at) VALUES
  (9100000003, 0, 'Set up job',                                  'completed', 'success', now() - interval '300 seconds', now() - interval '298 seconds'),
  (9100000003, 1, 'echo hello && sleep 1 && echo done',          'completed', 'success', now() - interval '298 seconds', now() - interval '296 seconds'),
  (9100000003, 2, 'echo persisted > note.txt; echo ''wrote, with commas''', 'completed', 'success', now() - interval '296 seconds', now() - interval '295 seconds'),
  (9100000003, 3, 'cat note.txt && pwd',                         'completed', 'success', now() - interval '295 seconds', now() - interval '294 seconds'),
  (9100000003, 4, 'echo ''allowed to fail'' >&2; exit 5',        'completed', 'success', now() - interval '294 seconds', now() - interval '293 seconds'),
  (9100000003, 5, 'echo ''still running after continue-on-error''', 'completed', 'success', now() - interval '293 seconds', now() - interval '292 seconds'),
  (9100000003, 6, 'echo ''about to fail''; exit 2',              'completed', 'failure', now() - interval '292 seconds', now() - interval '291 seconds'),
  (9100000003, 7, 'echo ''should be skipped''',                  'completed', 'skipped', NULL, NULL),
  (9100000003, 8, 'echo ''cleanup runs because always()''',      'completed', 'success', now() - interval '291 seconds', now() - interval '290 seconds')
ON CONFLICT DO NOTHING;

INSERT INTO job_logs (ts, job_id, step_number, seq, stream, line)
SELECT * FROM (VALUES
  (now() - interval '300 seconds', 9100000003, 0,  1, 'stdout', 'Set up job'),
  (now() - interval '298 seconds', 9100000003, 1,  2, 'stdout', 'hello'),
  (now() - interval '297 seconds', 9100000003, 1,  3, 'stdout', 'done'),
  (now() - interval '295 seconds', 9100000003, 2,  4, 'stdout', 'wrote, with commas'),
  (now() - interval '294 seconds', 9100000003, 3,  5, 'stdout', 'persisted'),
  (now() - interval '294 seconds', 9100000003, 3,  6, 'stdout', '/github/workspace'),
  (now() - interval '293 seconds', 9100000003, 4,  7, 'stderr', 'allowed to fail'),
  (now() - interval '292 seconds', 9100000003, 5,  8, 'stdout', 'still running after continue-on-error'),
  (now() - interval '291 seconds', 9100000003, 6,  9, 'stdout', 'about to fail'),
  (now() - interval '291 seconds', 9100000003, 6, 10, 'stderr', 'Process completed with exit code 2.'),
  (now() - interval '290 seconds', 9100000003, 8, 11, 'stdout', 'cleanup runs because always()')
) AS v(ts, job_id, step_number, seq, stream, line)
WHERE NOT EXISTS (SELECT 1 FROM job_logs WHERE job_id = 9100000003);
