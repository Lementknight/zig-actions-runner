import { ApiError, isAbort, type Api } from './Api'
import type { JobWithSteps, ListRunsOptions, LogLine, LogsResponse, Run, RunDetail, Step } from './types'

// The read API over fetch (SPEC §5.3, KTD2). Every view sees the same Api as with the fake;
// the only difference is where the answers come from.
//
// The API is not built yet, so this client defends the boundary in one place: BIGINT columns
// that arrive as JSON strings become numbers again, the run list may come bare or wrapped in
// { runs }, and a run's jobs and steps may come nested or as flat { run, jobs, steps } lists.

type Fetch = typeof fetch
type Json = Record<string, unknown>

const num = (value: unknown): number => (typeof value === 'string' ? Number(value) : (value as number))
const numOrNull = (value: unknown): number | null => (value === null || value === undefined ? null : num(value))

function toRun(raw: Json): Run {
  return {
    id: num(raw.id),
    repo: raw.repo as string,
    workflow: raw.workflow as string,
    event: (raw.event as string | null) ?? null,
    branch: (raw.branch as string | null) ?? null,
    sha: (raw.sha as string | null) ?? null,
    status: raw.status as string,
    conclusion: (raw.conclusion as string | null) ?? null,
    created_at: raw.created_at as string,
    completed_at: (raw.completed_at as string | null) ?? null,
  }
}

function toStep(raw: Json, jobId: number): Step {
  return {
    job_id: numOrNull(raw.job_id) ?? jobId,
    number: num(raw.number),
    name: raw.name as string,
    status: raw.status as string,
    conclusion: (raw.conclusion as string | null) ?? null,
    started_at: (raw.started_at as string | null) ?? null,
    completed_at: (raw.completed_at as string | null) ?? null,
  }
}

function toJob(raw: Json, runId: number, flatSteps: Json[] | undefined): JobWithSteps {
  const id = num(raw.id)
  const steps = (raw.steps as Json[] | undefined) ?? flatSteps?.filter((s) => num(s.job_id) === id) ?? []
  return {
    id,
    run_id: numOrNull(raw.run_id) ?? runId,
    name: raw.name as string,
    runner_name: (raw.runner_name as string | null) ?? null,
    status: raw.status as string,
    conclusion: (raw.conclusion as string | null) ?? null,
    started_at: (raw.started_at as string | null) ?? null,
    completed_at: (raw.completed_at as string | null) ?? null,
    steps: steps.map((s) => toStep(s, id)).sort((a, b) => a.number - b.number),
  }
}

function toRunDetail(body: Json): RunDetail {
  // Flat form: { run, jobs, steps }. Nested form: the run with jobs[].steps[].
  const flat = typeof body.run === 'object' && body.run !== null
  const run = toRun(flat ? (body.run as Json) : body)
  const jobs = ((body.jobs as Json[] | undefined) ?? []).map((job) =>
    toJob(job, run.id, flat ? (body.steps as Json[] | undefined) : undefined),
  )
  return { ...run, jobs }
}

function toLogLine(raw: Json): LogLine {
  return {
    seq: num(raw.seq),
    step: num(raw.step),
    stream: raw.stream as LogLine['stream'],
    ts: raw.ts as string,
    line: raw.line as string,
  }
}

function toLogs(body: Json, after: number): LogsResponse {
  const lines = ((body.lines as Json[] | undefined) ?? []).map(toLogLine)
  return {
    lines,
    next_after: numOrNull(body.next_after) ?? lines.at(-1)?.seq ?? after,
    job_done: body.job_done === true,
  }
}

/** Joins the base URL and a path without doubling or dropping the slash between them. */
function join(baseUrl: string, path: string): string {
  return `${baseUrl.replace(/\/+$/, '')}${path}`
}

export function createHttpApi(baseUrl: string, fetchImpl?: Fetch): Api {
  async function get(path: string, signal?: AbortSignal): Promise<Json> {
    const url = join(baseUrl, path)
    let response: Response
    try {
      // Looked up per call so tests and polyfills that replace fetch later still apply.
      response = await (fetchImpl ?? fetch)(url, { signal, headers: { Accept: 'application/json' } })
    } catch (error) {
      if (isAbort(error) || signal?.aborted) throw error
      throw new ApiError(`GET ${url} failed: ${error instanceof Error ? error.message : String(error)}`)
    }
    if (!response.ok) {
      throw new ApiError(`GET ${url} returned ${response.status}`, response.status)
    }
    try {
      return (await response.json()) as Json
    } catch (error) {
      if (isAbort(error) || signal?.aborted) throw error
      throw new ApiError(`GET ${url} returned a body that is not JSON`, response.status)
    }
  }

  return {
    async listRuns(options: ListRunsOptions = {}, signal?: AbortSignal): Promise<Run[]> {
      const query = new URLSearchParams()
      if (options.repo !== undefined) query.set('repo', options.repo)
      if (options.limit !== undefined) query.set('limit', String(options.limit))
      if (options.before !== undefined) query.set('before', String(options.before))
      const qs = query.toString()
      const body = await get(`/runs${qs ? `?${qs}` : ''}`, signal)
      const runs = Array.isArray(body) ? body : ((body.runs as Json[] | undefined) ?? [])
      return (runs as Json[]).map(toRun)
    },

    async getRun(runId: number, signal?: AbortSignal): Promise<RunDetail> {
      return toRunDetail(await get(`/runs/${encodeURIComponent(runId)}`, signal))
    },

    async getLogs(jobId: number, after: number, limit: number, signal?: AbortSignal): Promise<LogsResponse> {
      const query = new URLSearchParams({ after: String(after), limit: String(limit) })
      return toLogs(await get(`/jobs/${encodeURIComponent(jobId)}/logs?${query}`, signal), after)
    },
  }
}
