import { describe, expect, it } from 'vitest'
import { ApiError, isNotFound } from './Api'
import { createFakeApi } from './fakeApi'
import { defaultFixtures } from './fixtures'
import { inProgressRun } from './fixtures/inProgressRun'
import { every, type FakeRun } from './fixtures/spec'
import type { LogsResponse } from './types'

const ORIGIN = Date.parse('2026-10-11T12:00:00Z')

/** A fake whose clock the test sets, in ms after ORIGIN. */
function fakeAt(fixtures: FakeRun[], at = 0) {
  const clock = { t: ORIGIN + at }
  const api = createFakeApi({ fixtures, origin: ORIGIN, now: () => clock.t })
  return { api, set: (ms: number) => (clock.t = ORIGIN + ms) }
}

/** One job, starting at origin, with a step that releases one line every 10 ms. */
function oneJob(lineCount: number, intervalMs = 10): FakeRun {
  return {
    id: 1,
    repo: 'r',
    workflow: 'w',
    event: 'push',
    branch: 'main',
    sha: 'abc',
    createdMs: 0,
    jobs: [
      {
        id: 10,
        name: 'job',
        startMs: 0,
        steps: [
          {
            name: 'print',
            durationMs: lineCount * intervalMs + 1,
            lines: every(intervalMs, Array.from({ length: lineCount }, (_, i) => `line ${i + 1}`)),
          },
        ],
      },
    ],
  }
}

/** Satisfies LogsResponse at runtime as well as in the type: every field present and typed. */
function expectLogsShape(response: LogsResponse) {
  expect(Object.keys(response).sort()).toEqual(['job_done', 'lines', 'next_after'])
  for (const line of response.lines) {
    expect(Object.keys(line).sort()).toEqual(['line', 'seq', 'step', 'stream', 'ts'])
    expect(typeof line.seq).toBe('number')
    expect(['stdout', 'stderr']).toContain(line.stream)
    expect(Number.isNaN(Date.parse(line.ts))).toBe(false)
  }
}

describe('fakeApi getLogs', () => {
  it('honors after: after=3 starts at seq 4', async () => {
    const { api } = fakeAt([oneJob(10)], 10_000)
    const res = await api.getLogs(10, 3, 1000)
    expectLogsShape(res)
    expect(res.lines.map((l) => l.seq)).toEqual([4, 5, 6, 7, 8, 9, 10])
  })

  it('honors limit: 1500 released lines come back as 1000 then 500', async () => {
    const { api } = fakeAt([oneJob(1500, 1)], 60_000)
    const first = await api.getLogs(10, 0, 1000)
    expect(first.lines).toHaveLength(1000)
    expect(first.next_after).toBe(1000)
    expect(first.job_done).toBe(false)
    const second = await api.getLogs(10, first.next_after, 1000)
    expect(second.lines).toHaveLength(500)
    expect(second.lines[0].seq).toBe(1001)
    expect(second.next_after).toBe(1500)
    expect(second.job_done).toBe(true)
  })

  it('echoes next_after equal to after on an empty page while the job runs', async () => {
    const { api } = fakeAt([oneJob(10, 1000)], 2_500)
    const res = await api.getLogs(10, 3, 1000)
    expect(res).toEqual({ lines: [], next_after: 3, job_done: false })
  })

  it('reports job_done only after every line has been released', async () => {
    const { api, set } = fakeAt([oneJob(5, 1000)])
    set(4_500)
    const running = await api.getLogs(10, 0, 1000)
    expect(running.lines).toHaveLength(5)
    expect(running.job_done).toBe(false)
    set(3_500)
    expect((await api.getLogs(10, 0, 1000)).job_done).toBe(false)
    set(5_001)
    const done = await api.getLogs(10, 5, 1000)
    expect(done).toEqual({ lines: [], next_after: 5, job_done: true })
  })

  it('numbers seq from 1 with no gaps across steps', async () => {
    const { api } = fakeAt(defaultFixtures, 60_000)
    const res = await api.getLogs(9206, 0, 1000)
    expect(res.lines.map((l) => l.seq)).toEqual(res.lines.map((_, i) => i + 1))
    expect(res.job_done).toBe(true)
  })

  it('rejects an unknown job with a 404 ApiError', async () => {
    const { api } = fakeAt(defaultFixtures)
    const error = await api.getLogs(424242, 0, 1000).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect(isNotFound(error)).toBe(true)
  })

  it('rejects when the signal has already aborted', async () => {
    const { api } = fakeAt([oneJob(3)], 1_000)
    const controller = new AbortController()
    controller.abort()
    await expect(api.getLogs(10, 0, 1000, controller.signal)).rejects.toMatchObject({ name: 'AbortError' })
  })
})

describe('fakeApi getRun on the in progress fixture', () => {
  // inProgressRun: created at +3s, job starts 3s later (+6s). Steps: set up 1.5s, checkout
  // 1.5s (no lines), zig build 10s, echo 3s (row 1.5s late), complete 1s.
  const jobStart = inProgressRun.createdMs + inProgressRun.jobs[0].startMs

  it('does not exist before it is created', async () => {
    const { api } = fakeAt(defaultFixtures, 1_000)
    expect(isNotFound(await api.getRun(9105).catch((e: unknown) => e))).toBe(true)
    expect((await api.listRuns()).map((r) => r.id)).not.toContain(9105)
  })

  it('is queued with no steps before its job starts', async () => {
    const { api } = fakeAt(defaultFixtures, jobStart - 500)
    const run = await api.getRun(9105)
    expect(run.status).toBe('queued')
    expect(run.jobs[0]).toMatchObject({ status: 'queued', started_at: null, steps: [] })
  })

  it('reports the step releasing lines as in_progress and earlier steps as completed', async () => {
    const at = jobStart + 3_000 + 4_000 // four seconds into "Run zig build"
    const { api } = fakeAt(defaultFixtures, at)
    const run = await api.getRun(9105)
    expect(run.status).toBe('in_progress')
    const steps = run.jobs[0].steps
    expect(steps.map((s) => [s.number, s.status, s.conclusion])).toEqual([
      [1, 'completed', 'success'],
      [2, 'completed', 'success'],
      [3, 'in_progress', null],
      [5, 'queued', null],
    ])
    const logs = await api.getLogs(9206, 0, 1000)
    expect(logs.lines.at(-1)?.step).toBe(3)
    expect(logs.lines.some((l) => l.step === 2)).toBe(false)
  })

  it('releases a line for step 4 before step 4 has a row', async () => {
    const at = jobStart + 3_000 + 10_000 + 500
    const { api, set } = fakeAt(defaultFixtures, at)
    const logs = await api.getLogs(9206, 0, 1000)
    expect(logs.lines.at(-1)).toMatchObject({ step: 4, line: 'hello' })
    expect((await api.getRun(9105)).jobs[0].steps.map((s) => s.number)).not.toContain(4)
    set(at + 1_500)
    expect((await api.getRun(9105)).jobs[0].steps.map((s) => s.number)).toContain(4)
  })

  it('releases about two lines a second while building', async () => {
    const buildStart = jobStart + 3_000
    const { api, set } = fakeAt(defaultFixtures, buildStart)
    const before = (await api.getLogs(9206, 0, 1000)).next_after
    set(buildStart + 5_000)
    const after = (await api.getLogs(9206, 0, 1000)).next_after
    expect(after - before).toBeGreaterThanOrEqual(9)
    expect(after - before).toBeLessThanOrEqual(11)
  })

  it('completes green and stays complete', async () => {
    const { api } = fakeAt(defaultFixtures, 60_000)
    const run = await api.getRun(9105)
    expect(run).toMatchObject({ status: 'completed', conclusion: 'success' })
    expect(run.completed_at).not.toBeNull()
    expect(run.jobs[0].steps.every((s) => s.status === 'completed')).toBe(true)
  })
})

describe('fakeApi fixtures', () => {
  it('lists runs newest first, covering success, failure, cancelled, queued and in progress', async () => {
    const { api } = fakeAt(defaultFixtures, 8_000)
    const runs = await api.listRuns()
    const created = runs.map((r) => Date.parse(r.created_at))
    expect(created).toEqual([...created].sort((a, b) => b - a))
    expect(runs[0]).toMatchObject({ id: 9105, status: 'in_progress', conclusion: null })
    const states = runs.map((r) => `${r.status}:${r.conclusion}`)
    expect(states).toEqual(
      expect.arrayContaining([
        'completed:success',
        'completed:failure',
        'completed:cancelled',
        'queued:null',
        'in_progress:null',
      ]),
    )
    expect(runs[0]).not.toHaveProperty('jobs')
  })

  it('honors limit and repo on the run list', async () => {
    const { api } = fakeAt(defaultFixtures, 8_000)
    expect(await api.listRuns({ limit: 2 })).toHaveLength(2)
    expect(await api.listRuns({ repo: 'someone/else' })).toEqual([])
  })

  it('gives the failed run stderr lines and a skipped step after the failure', async () => {
    const { api } = fakeAt(defaultFixtures)
    const run = await api.getRun(9102)
    expect(run).toMatchObject({ status: 'completed', conclusion: 'failure' })
    const steps = run.jobs[0].steps
    expect(steps.find((s) => s.conclusion === 'failure')?.name).toBe('Run zig build test')
    expect(steps.find((s) => s.name === 'Upload coverage')?.conclusion).toBe('skipped')
    const logs = await api.getLogs(run.jobs[0].id, 0, 1000)
    expect(logs.lines.some((l) => l.stream === 'stderr')).toBe(true)
  })

  it('keeps the queued run queued with no jobs', async () => {
    const { api } = fakeAt(defaultFixtures, 10 * 60_000)
    expect(await api.getRun(9104)).toMatchObject({ status: 'queued', conclusion: null, jobs: [] })
  })

  it('gives the success run three jobs in fixture order', async () => {
    const { api } = fakeAt(defaultFixtures)
    const run = await api.getRun(9101)
    expect(run.jobs.map((j) => j.name)).toEqual(['build', 'test', 'lint'])
    expect(run.conclusion).toBe('success')
  })

  it('rejects an unknown run with a 404', async () => {
    const { api } = fakeAt(defaultFixtures)
    await expect(api.getRun(1)).rejects.toMatchObject({ status: 404 })
  })
})
