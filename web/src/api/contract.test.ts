import { describe, expect, it } from 'vitest'
import { isNotFound, type Api } from './Api'
import { createFakeApi } from './fakeApi'
import { defaultFixtures } from './fixtures'
import { createHttpApi } from './httpApi'
import type { LogLine, RunDetail } from './types'

// The read API contract the frontend relies on (SPEC §5.3), asserted against any Api.
// It always runs against the fake. Set CONTRACT_API_URL to the real API's base URL to run it
// against that too, once M0 exists:
//
//   CONTRACT_API_URL=http://localhost:8080/api npm test
//
// Against a real API it needs at least one completed job with three or more log lines.
// Checks the plan only proposes to the team (Risks and Dependencies) say so in their name,
// so a failure there is a question for the team, not necessarily a bug.

const realApiUrl = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env
  .CONTRACT_API_URL

interface Subject {
  api: Api
  /** A completed job with at least three lines. */
  completedJobId: number
  /** A job still in progress, if the source has one right now. */
  runningJobId?: number
}

/** Finds the jobs the contract needs by walking the run list, the same way on any source. */
async function discover(api: Api): Promise<Subject> {
  const runs = await api.listRuns({ limit: 50 })
  const details: RunDetail[] = await Promise.all(runs.map((run) => api.getRun(run.id)))
  const jobs = details.flatMap((run) => run.jobs)
  let completedJobId: number | undefined
  for (const job of jobs.filter((j) => j.status === 'completed')) {
    const page = await api.getLogs(job.id, 0, 3)
    if (page.lines.length === 3) {
      completedJobId = job.id
      break
    }
  }
  if (completedJobId === undefined) throw new Error('No completed job with three or more log lines to test against')
  const runningJobId = jobs.find((j) => j.status === 'in_progress')?.id
  return { api, completedJobId, runningJobId }
}

/** Every line of a job, page by page from after=0, plus the final empty page. */
async function readAll(api: Api, jobId: number, limit: number) {
  const lines: LogLine[] = []
  const pages = []
  let after = 0
  for (let i = 0; i < 10_000; i++) {
    const page = await api.getLogs(jobId, after, limit)
    pages.push({ after, ...page })
    lines.push(...page.lines)
    if (page.lines.length === 0) break
    after = Math.max(after, page.next_after)
  }
  return { lines, pages }
}

function defineContract(name: string, makeSubject: () => Promise<Subject>) {
  describe(`read API contract: ${name}`, () => {
    let subject: Promise<Subject> | undefined
    const get = () => (subject ??= makeSubject())

    it('pages a completed job with seq starting at 1, gapless and ascending', async () => {
      const { api, completedJobId } = await get()
      const { lines } = await readAll(api, completedJobId, 2)
      expect(lines.length).toBeGreaterThanOrEqual(3)
      expect(lines.map((l) => l.seq)).toEqual(lines.map((_, i) => i + 1))
    })

    it('returns log lines with every documented field, snake_case and typed', async () => {
      const { api, completedJobId } = await get()
      const page = await api.getLogs(completedJobId, 0, 3)
      for (const line of page.lines) {
        expect(typeof line.seq).toBe('number')
        expect(typeof line.step).toBe('number')
        expect(['stdout', 'stderr']).toContain(line.stream)
        expect(Number.isNaN(Date.parse(line.ts))).toBe(false)
        expect(typeof line.line).toBe('string')
      }
      expect(typeof page.next_after).toBe('number')
      expect(typeof page.job_done).toBe('boolean')
    })

    it('honors limit and advances next_after to the last seq returned', async () => {
      const { api, completedJobId } = await get()
      const page = await api.getLogs(completedJobId, 0, 2)
      expect(page.lines).toHaveLength(2)
      expect(page.next_after).toBe(page.lines[1].seq)
      const next = await api.getLogs(completedJobId, page.next_after, 1)
      expect(next.lines[0].seq).toBe(page.next_after + 1)
    })

    it('echoes next_after equal to after on an empty page (proposed, SPEC question 2)', async () => {
      const { api, completedJobId } = await get()
      const { pages } = await readAll(api, completedJobId, 1000)
      const last = pages.at(-1)!
      expect(last.lines).toEqual([])
      expect(last.next_after).toBe(last.after)
    })

    it('reports job_done on the empty page after a completed job is read to the end', async () => {
      const { api, completedJobId } = await get()
      const { pages } = await readAll(api, completedJobId, 1000)
      expect(pages.at(-1)!.job_done).toBe(true)
    })

    it('reports job_done false while lines beyond next_after remain (proposed, SPEC question 1)', async () => {
      const { api, completedJobId } = await get()
      const { pages } = await readAll(api, completedJobId, 1)
      // Every page but the last two still had lines after it.
      for (const page of pages.slice(0, -2)) expect(page.job_done).toBe(false)
    })

    it('reports job_done false for a job still in progress', async (ctx) => {
      const { api, runningJobId } = await get()
      if (runningJobId === undefined) return ctx.skip()
      expect((await api.getLogs(runningJobId, 0, 1000)).job_done).toBe(false)
    })

    it('lists runners with every documented field, typed, ordered by name', async () => {
      const { api } = await get()
      const runners = await api.listRunners()
      expect(runners.length).toBeGreaterThanOrEqual(1)
      for (const r of runners) {
        expect(typeof r.name).toBe('string')
        expect(['idle', 'busy', 'offline']).toContain(r.status)
        expect(Array.isArray(r.labels)).toBe(true)
        expect(Number.isNaN(Date.parse(r.last_seen_at))).toBe(false)
        expect(typeof r.running_jobs).toBe('number')
        expect(typeof r.completed_jobs).toBe('number')
        // A runner reports a current job exactly when it is busy.
        expect(r.current_job !== null).toBe(r.status === 'busy')
      }
      expect(runners.map((r) => r.name)).toEqual([...runners.map((r) => r.name)].sort())
    })

    it('answers an unknown run and job with 404 (proposed, SPEC question 4)', async () => {
      const { api } = await get()
      expect(isNotFound(await api.getRun(987_654_321).catch((e: unknown) => e))).toBe(true)
      expect(isNotFound(await api.getLogs(987_654_321, 0, 1).catch((e: unknown) => e))).toBe(true)
    })
  })
}

// The fake, frozen 13 seconds in: the demo run's job is mid build, every other run finished.
defineContract('fakeApi', () => {
  const origin = Date.parse('2026-10-11T12:00:00Z')
  return discover(createFakeApi({ fixtures: defaultFixtures, origin, now: () => origin + 13_000 }))
})

if (realApiUrl) {
  defineContract(`real API at ${realApiUrl}`, () => discover(createHttpApi(realApiUrl)))
}
