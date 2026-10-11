import { ApiError, throwIfAborted, type Api } from './Api'
import { defaultExtraRunners, defaultFixtures } from './fixtures'
import type { FakeRun, FakeRunner } from './fixtures/spec'
import type { JobWithSteps, ListRunsOptions, LogLine, LogsResponse, Run, RunDetail, Runner, Step } from './types'

// The fake read API (KTD3). Stateless: every answer is derived from the fixtures and the
// clock, never from timers or request history, so React StrictMode's double mount and a
// page reload both see exactly what a real server would show at that moment.

export interface FakeApiOptions {
  fixtures?: FakeRun[]
  /** Runners listed besides the ones fixture jobs name. Defaults to an idle and an offline one. */
  extraRunners?: FakeRunner[]
  /** The clock. Defaults to Date.now. */
  now?: () => number
  /** The instant fixture offsets count from. Defaults to the clock's value at creation. */
  origin?: number
}

interface StepTimeline {
  number: number
  name: string
  startAt: number
  endAt: number
  rowAt: number
  conclusion: string
}

interface LineTimeline extends LogLine {
  releaseAt: number
}

interface JobTimeline {
  id: number
  runId: number
  name: string
  runnerName: string | null
  startAt: number
  endAt: number
  conclusion: string
  steps: StepTimeline[]
  lines: LineTimeline[]
}

interface RunTimeline {
  run: FakeRun
  createdAt: number
  jobs: JobTimeline[]
}

const iso = (ms: number) => new Date(ms).toISOString()

function buildTimeline(run: FakeRun, origin: number): RunTimeline {
  const createdAt = origin + run.createdMs
  const jobs = run.jobs.map((job): JobTimeline => {
    const startAt = createdAt + job.startMs
    let cursor = startAt
    const steps: StepTimeline[] = []
    const lines: Omit<LineTimeline, 'seq'>[] = []
    job.steps.forEach((step, i) => {
      const number = i + 1
      const stepStart = cursor
      cursor += step.durationMs
      steps.push({
        number,
        name: step.name,
        startAt: stepStart,
        endAt: cursor,
        rowAt: step.rowDelayMs === undefined ? startAt : stepStart + step.rowDelayMs,
        conclusion: step.conclusion ?? 'success',
      })
      for (const line of step.lines ?? []) {
        const releaseAt = stepStart + line.atMs
        lines.push({ step: number, stream: line.stream ?? 'stdout', ts: iso(releaseAt), line: line.text, releaseAt })
      }
    })
    const conclusions = steps.map((s) => s.conclusion)
    const conclusion =
      job.conclusion ??
      (conclusions.includes('failure') ? 'failure' : conclusions.includes('cancelled') ? 'cancelled' : 'success')
    // seq follows release order, starting at 1 with no gaps (SPEC §4).
    const ordered = lines
      .map((line, index) => ({ line, index }))
      .sort((a, b) => a.line.releaseAt - b.line.releaseAt || a.index - b.index)
      .map(({ line }, i) => ({ ...line, seq: i + 1 }))
    return {
      id: job.id,
      runId: run.id,
      name: job.name,
      runnerName: job.runnerName ?? null,
      startAt,
      endAt: cursor,
      conclusion,
      steps,
      lines: ordered,
    }
  })
  return { run, createdAt, jobs }
}

function phase(startAt: number, endAt: number, now: number): 'queued' | 'in_progress' | 'completed' {
  if (now < startAt) return 'queued'
  if (now < endAt) return 'in_progress'
  return 'completed'
}

function stepAt(job: JobTimeline, step: StepTimeline, now: number): Step {
  const status = phase(step.startAt, step.endAt, now)
  return {
    job_id: job.id,
    number: step.number,
    name: step.name,
    status,
    conclusion: status === 'completed' ? step.conclusion : null,
    started_at: status === 'queued' ? null : iso(step.startAt),
    completed_at: status === 'completed' ? iso(step.endAt) : null,
  }
}

function jobAt(job: JobTimeline, now: number): JobWithSteps {
  const status = phase(job.startAt, job.endAt, now)
  return {
    id: job.id,
    run_id: job.runId,
    name: job.name,
    runner_name: status === 'queued' ? null : job.runnerName,
    status,
    conclusion: status === 'completed' ? job.conclusion : null,
    started_at: status === 'queued' ? null : iso(job.startAt),
    completed_at: status === 'completed' ? iso(job.endAt) : null,
    // Steps exist once the job starts; a delayed row appears at its rowAt (R18).
    steps: status === 'queued' ? [] : job.steps.filter((s) => now >= s.rowAt).map((s) => stepAt(job, s, now)),
  }
}

function runAt(timeline: RunTimeline, now: number): RunDetail {
  const { run } = timeline
  const jobs = timeline.jobs.map((job) => jobAt(job, now))
  let status: string
  let conclusion: string | null = null
  let completedAt: string | null = null
  if (jobs.length === 0 || jobs.every((j) => j.status === 'queued')) {
    status = 'queued'
  } else if (jobs.some((j) => j.status !== 'completed')) {
    status = 'in_progress'
  } else {
    status = 'completed'
    const conclusions = jobs.map((j) => j.conclusion)
    conclusion = conclusions.includes('failure')
      ? 'failure'
      : conclusions.includes('cancelled')
        ? 'cancelled'
        : 'success'
    completedAt = iso(Math.max(...timeline.jobs.map((j) => j.endAt)))
  }
  return {
    id: run.id,
    repo: run.repo,
    workflow: run.workflow,
    event: run.event,
    branch: run.branch,
    sha: run.sha,
    status,
    conclusion,
    created_at: iso(timeline.createdAt),
    completed_at: completedAt,
    jobs,
  }
}

function summary({ jobs: _jobs, ...run }: RunDetail): Run {
  return run
}

const DEFAULT_LABELS = ['self-hosted', 'linux', 'zig']
const HOUR_MS = 3_600_000

/** One entry per runner name: those fixture jobs run on, then `extra`. Busy while a job runs on it. */
function runnersAt(timelines: RunTimeline[], extra: FakeRunner[], origin: number, t: number): Runner[] {
  const jobs = timelines.filter((tl) => tl.createdAt <= t).flatMap((tl) => tl.jobs.map((job) => jobAt(job, t)))
  const names = new Set<string>()
  for (const tl of timelines) for (const job of tl.jobs) if (job.runnerName) names.add(job.runnerName)
  for (const runner of extra) names.add(runner.name)
  return [...names].sort().map((name): Runner => {
    const mine = jobs.filter((j) => j.runner_name === name)
    const running = mine.filter((j) => j.status === 'in_progress')
    const offline = extra.find((r) => r.name === name)?.offline === true
    return {
      name,
      status: offline ? 'offline' : running.length > 0 ? 'busy' : 'idle',
      labels: extra.find((r) => r.name === name)?.labels ?? DEFAULT_LABELS,
      registered_at: iso(origin - HOUR_MS),
      last_seen_at: iso(offline ? origin - 3 * HOUR_MS : t),
      current_job: running[0] ? { id: running[0].id, run_id: running[0].run_id, name: running[0].name } : null,
      running_jobs: running.length,
      completed_jobs: mine.filter((j) => j.status === 'completed').length,
    }
  })
}

export function createFakeApi(options: FakeApiOptions = {}): Api {
  const now = options.now ?? Date.now
  const origin = options.origin ?? now()
  const timelines = (options.fixtures ?? defaultFixtures).map((run) => buildTimeline(run, origin))

  /** Runs that exist at this instant: a run created in the future is not there yet. */
  const existing = (t: number) => timelines.filter((tl) => tl.createdAt <= t)

  return {
    async listRuns(opts: ListRunsOptions = {}, signal?: AbortSignal): Promise<Run[]> {
      throwIfAborted(signal)
      const t = now()
      let runs = existing(t)
        .map((tl) => summary(runAt(tl, t)))
        .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id)
      if (opts.repo) runs = runs.filter((r) => r.repo === opts.repo)
      if (opts.before !== undefined) {
        const index = runs.findIndex((r) => r.id === opts.before)
        runs = index === -1 ? [] : runs.slice(index + 1)
      }
      return opts.limit !== undefined ? runs.slice(0, Math.max(0, opts.limit)) : runs
    },

    async getRun(runId: number, signal?: AbortSignal): Promise<RunDetail> {
      throwIfAborted(signal)
      const t = now()
      const timeline = existing(t).find((tl) => tl.run.id === runId)
      if (!timeline) throw new ApiError(`Run ${runId} not found`, 404)
      return runAt(timeline, t)
    },

    async listRunners(signal?: AbortSignal): Promise<Runner[]> {
      throwIfAborted(signal)
      return runnersAt(timelines, options.extraRunners ?? defaultExtraRunners, origin, now())
    },

    async getLogs(jobId: number, after: number, limit: number, signal?: AbortSignal): Promise<LogsResponse> {
      throwIfAborted(signal)
      const t = now()
      const job = existing(t)
        .flatMap((tl) => tl.jobs)
        .find((j) => j.id === jobId)
      if (!job) throw new ApiError(`Job ${jobId} not found`, 404)
      const size = Number.isFinite(limit) && limit > 0 ? Math.floor(limit) : 1000
      const released = job.lines.filter((l) => l.releaseAt <= t)
      const page = released
        .filter((l) => l.seq > after)
        .slice(0, size)
        .map(({ releaseAt: _releaseAt, ...line }) => line)
      const nextAfter = page.length > 0 ? page[page.length - 1].seq : after
      // job_done: the job has finished and no line beyond next_after remains (plan, Risks 1).
      const jobDone = t >= job.endAt && nextAfter >= job.lines.length
      return { lines: page, next_after: nextAfter, job_done: jobDone }
    },
  }
}
