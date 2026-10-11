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
