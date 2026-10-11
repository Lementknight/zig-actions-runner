import type { Queryable } from './db'

// Rows come back with the table's own column names, so the JSON is snake_case and mirrors
// SPEC §4 without a mapping layer. TIMESTAMPTZ arrives as a Date, which JSON writes as ISO 8601.

const RUN_COLUMNS = 'id, repo, workflow, event, branch, sha, status, conclusion, created_at, completed_at'
const JOB_COLUMNS = 'id, run_id, name, runner_name, status, conclusion, started_at, completed_at'
const STEP_COLUMNS = 'job_id, number, name, status, conclusion, started_at, completed_at'

export interface RunRow {
  id: number
  repo: string
  workflow: string
  event: string | null
  branch: string | null
  sha: string | null
  status: string
  conclusion: string | null
  created_at: Date
  completed_at: Date | null
}

export interface JobRow {
  id: number
  run_id: number
  name: string
  runner_name: string | null
  status: string
  conclusion: string | null
  started_at: Date | null
  completed_at: Date | null
}

export interface StepRow {
  job_id: number
  number: number
  name: string
  status: string
  conclusion: string | null
  started_at: Date | null
  completed_at: Date | null
}

export interface RunDetail extends RunRow {
  jobs: (JobRow & { steps: StepRow[] })[]
}

export interface ListRunsOptions {
  repo?: string
  limit: number
  /** A run id: return only runs that sort after it, that is older (created_at, then id). */
  before?: number
}

/** Newest first. The order and the `before` cursor both follow the (created_at DESC, id DESC) indexes. */
export async function listRuns(db: Queryable, { repo, limit, before }: ListRunsOptions): Promise<RunRow[]> {
  const params: unknown[] = []
  const where: string[] = []
  if (repo !== undefined) {
    params.push(repo)
    where.push(`repo = $${params.length}`)
  }
  if (before !== undefined) {
    // An unknown cursor run makes the subquery NULL, so the page is empty rather than an error.
    params.push(before)
    where.push(`(created_at, id) < (SELECT created_at, id FROM runs WHERE id = $${params.length})`)
  }
  params.push(limit)
  const sql =
    `SELECT ${RUN_COLUMNS} FROM runs` +
    (where.length > 0 ? ` WHERE ${where.join(' AND ')}` : '') +
    ` ORDER BY created_at DESC, id DESC LIMIT $${params.length}`
  return (await db.query<RunRow>(sql, params)).rows
}

/** The run with its jobs (by id) and each job's steps (by number), or null when no such run. */
export async function getRun(db: Queryable, id: number): Promise<RunDetail | null> {
  const run = (await db.query<RunRow>(`SELECT ${RUN_COLUMNS} FROM runs WHERE id = $1`, [id])).rows[0]
  if (run === undefined) return null

  const jobs = (await db.query<JobRow>(`SELECT ${JOB_COLUMNS} FROM jobs WHERE run_id = $1 ORDER BY id`, [id])).rows
  const steps =
    jobs.length === 0
      ? []
      : (
          await db.query<StepRow>(
            `SELECT ${STEP_COLUMNS} FROM steps WHERE job_id = ANY($1::bigint[]) ORDER BY job_id, number`,
            [jobs.map((job) => job.id)],
          )
        ).rows

  const byJob = new Map<number, StepRow[]>(jobs.map((job) => [job.id, []]))
  for (const step of steps) byJob.get(step.job_id)?.push(step)
  return {
    ...run,
    jobs: jobs.map((job) => ({ ...job, steps: byJob.get(job.id)!.sort((a, b) => a.number - b.number) })),
  }
}

export interface LogLineRow {
  seq: number
  step: number
  stream: string
  ts: Date
  line: string
}

export interface LogPage {
  lines: LogLineRow[]
  next_after: number
  job_done: boolean
}

/**
 * One page of a job's log, lines with seq > after in seq order, or null when no such job.
 *
 * `job_done` is true only when the job is completed and nothing past `next_after` remains. The
 * job's status is read before its lines: the runner flushes a job's log before it marks the job
 * completed (SPEC §5.1, §5.2), so a status already completed means every line is already written.
 * Fetching one row past `limit` tells whether more remain without a second query.
 */
export async function getJobLogs(db: Queryable, jobId: number, after: number, limit: number): Promise<LogPage | null> {
  const job = (
    await db.query<{ status: string; started_at: Date | null }>('SELECT status, started_at FROM jobs WHERE id = $1', [
      jobId,
    ])
  ).rows[0]
  if (job === undefined) return null

  // job_logs is a hypertable on ts. Bounding ts from below lets TimescaleDB skip every chunk older
  // than the job; the hour of slack covers a runner clock that stamps lines before started_at.
  const params: unknown[] = [jobId, after, limit + 1]
  let tsBound = ''
  if (job.started_at !== null) {
    params.push(job.started_at)
    tsBound = ` AND ts >= $4::timestamptz - interval '1 hour'`
  }
  const rows = (
    await db.query<LogLineRow>(
      `SELECT seq, step_number AS step, stream, ts, line FROM job_logs` +
        ` WHERE job_id = $1 AND seq > $2${tsBound} ORDER BY seq LIMIT $3`,
      params,
    )
  ).rows

  const more = rows.length > limit
  const lines = more ? rows.slice(0, limit) : rows
  return {
    lines,
    next_after: lines.at(-1)?.seq ?? after,
    job_done: job.status === 'completed' && !more,
  }
}

export interface RunnerRow {
  name: string
  /** What the runners row says: idle, busy or offline. */
  status: string
  labels: string[]
  registered_at: Date
  last_seen_at: Date
  /** last_seen_at is older than two minutes, by the database's clock. */
  stale: boolean
  current_job_id: number | null
  current_job_run_id: number | null
  current_job_name: string | null
  running_jobs: number
  completed_jobs: number
}

export interface Runner {
  name: string
  status: string
  labels: string[]
  registered_at: Date
  last_seen_at: Date
  current_job: { id: number; run_id: number; name: string } | null
  running_jobs: number
  completed_jobs: number
}

/**
 * The status the API reports (SPEC §4): offline when the row says so or the heartbeat is stale,
 * busy only when the row says busy and the runner has an in-progress job, idle otherwise. So
 * current_job is set exactly when the status is busy, and a job left in_progress by a crashed run
 * never makes an idle runner look busy.
 */
export function toRunner(row: RunnerRow): Runner {
  const status =
    row.status === 'offline' || row.stale
      ? 'offline'
      : row.status === 'busy' && row.current_job_id !== null
        ? 'busy'
        : 'idle'
  return {
    name: row.name,
    status,
    labels: row.labels,
    registered_at: row.registered_at,
    last_seen_at: row.last_seen_at,
    current_job:
      status === 'busy'
        ? { id: row.current_job_id!, run_id: row.current_job_run_id!, name: row.current_job_name! }
        : null,
    running_jobs: row.running_jobs,
    completed_jobs: row.completed_jobs,
  }
}

/**
 * Every runner, ordered by name in byte order (COLLATE "C", the order JavaScript's sort gives).
 * The current job and both counts come from jobs.runner_name through jobs_runner_name_idx.
 */
export async function listRunners(db: Queryable): Promise<Runner[]> {
  const { rows } = await db.query<RunnerRow>(
    `SELECT r.name, r.status, r.labels, r.registered_at, r.last_seen_at,
            r.last_seen_at < now() - interval '2 minutes' AS stale,
            cj.id AS current_job_id, cj.run_id AS current_job_run_id, cj.name AS current_job_name,
            counts.running_jobs, counts.completed_jobs
       FROM runners r
       LEFT JOIN LATERAL (
         SELECT id, run_id, name FROM jobs
          WHERE runner_name = r.name AND status = 'in_progress'
          ORDER BY started_at DESC NULLS LAST, id DESC
          LIMIT 1
       ) cj ON true
       CROSS JOIN LATERAL (
         SELECT count(*) FILTER (WHERE status = 'in_progress') AS running_jobs,
                count(*) FILTER (WHERE status = 'completed') AS completed_jobs
           FROM jobs
          WHERE runner_name = r.name AND status IN ('in_progress', 'completed')
       ) counts
      ORDER BY r.name COLLATE "C"`,
  )
  return rows.map(toRunner)
}
