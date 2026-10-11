// Shapes of the read API (docs/SPEC.md §4 and §5.3). Field names mirror the table columns,
// snake_case, and every nullable column is typed as nullable. Timestamps are ISO 8601 strings.

/** `queued`, `in_progress` or `completed` per SPEC §4; kept open so an unknown value still renders (R3). */
export type Status = string

/** `success`, `failure`, `cancelled`, `skipped`, or null while not completed; kept open for the same reason. */
export type Conclusion = string | null

export interface Run {
  id: number
  repo: string
  workflow: string
  event: string | null
  branch: string | null
  sha: string | null
  status: Status
  conclusion: Conclusion
  created_at: string
  completed_at: string | null
}

export interface Step {
  job_id: number
  number: number
  name: string
  status: Status
  conclusion: Conclusion
  started_at: string | null
  completed_at: string | null
}

export interface Job {
  id: number
  run_id: number
  name: string
  runner_name: string | null
  status: Status
  conclusion: Conclusion
  started_at: string | null
  completed_at: string | null
}

/** A job with its steps, as `GET /api/runs/:id` nests them. Steps are ordered by `number`. */
export interface JobWithSteps extends Job {
  steps: Step[]
}

/** `GET /api/runs/:id`: the run, its jobs in API order, and each job's steps. */
export interface RunDetail extends Run {
  jobs: JobWithSteps[]
}

export type LogStream = 'stdout' | 'stderr'

/** One log line. `seq` starts at 1 per job with no gaps; `line` keeps its ANSI codes. */
export interface LogLine {
  seq: number
  step: number
  stream: LogStream
  ts: string
  line: string
}

/** `GET /api/jobs/:id/logs?after=&limit=` */
export interface LogsResponse {
  lines: LogLine[]
  next_after: number
  job_done: boolean
}

export interface ListRunsOptions {
  repo?: string
  limit?: number
  /** Return only runs older than the run with this id. */
  before?: number
}
