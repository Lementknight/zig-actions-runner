import { afterAll, describe, expect, it } from 'vitest'
import { createApp } from '../src/app'
import { createPool } from '../src/db'

// GET /api/jobs/:id/logs against a database migrated and seeded as in db/README.md. Skipped when
// DATABASE_URL is unset. The seed's failed job has 11 lines; its in-progress job has 3 so far.

const databaseUrl = process.env.DATABASE_URL

const FAILED_JOB = 9100000003 // completed, seq 1..11
const RUNNING_JOB = 9100000002 // in_progress, seq 1..3
const COMPLETED_JOB = 9100000001 // completed, seq 1..6, seq 3 carries ANSI color codes

describe.skipIf(!databaseUrl)('logs route against a seeded database', () => {
  const pool = createPool(databaseUrl ?? '')
  const app = createApp(pool)
  afterAll(() => pool.end())

  async function logs(jobId: number, query = '') {
    const response = await app.request(`/api/jobs/${jobId}/logs${query}`)
    return { status: response.status, body: (await response.json()) as any }
  }

  it('returns every line of a finished job in seq order, then job_done', async () => {
    const { status, body } = await logs(FAILED_JOB)
    expect(status).toBe(200)
    expect(body.lines.map((l: any) => l.seq)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    expect(body.next_after).toBe(11)
    expect(body.job_done).toBe(true)
  })

  it('writes the documented fields with their types', async () => {
    const { body } = await logs(FAILED_JOB, '?after=6&limit=1')
    expect(body.lines).toEqual([
      { seq: 7, step: 4, stream: 'stderr', ts: expect.stringMatching(/^\d{4}-\d\d-\d\dT.*Z$/), line: 'allowed to fail' },
    ])
  })

  it('keeps ANSI codes intact', async () => {
    const { body } = await logs(COMPLETED_JOB, '?after=2&limit=1')
    expect(body.lines[0].line).toBe('\x1b[32mBuilding\x1b[0m runner')
  })

  it('pages with limit and next_after, job_done false until nothing remains', async () => {
    const first = (await logs(FAILED_JOB, '?limit=4')).body
    expect(first.lines.map((l: any) => l.seq)).toEqual([1, 2, 3, 4])
    expect(first).toMatchObject({ next_after: 4, job_done: false })

    const exact = (await logs(FAILED_JOB, '?after=9&limit=2')).body
    expect(exact.lines.map((l: any) => l.seq)).toEqual([10, 11])
    expect(exact).toMatchObject({ next_after: 11, job_done: true })
  })

  it('echoes after on an empty page', async () => {
    expect((await logs(FAILED_JOB, '?after=11')).body).toEqual({ lines: [], next_after: 11, job_done: true })
    expect((await logs(FAILED_JOB, '?after=500')).body).toEqual({ lines: [], next_after: 500, job_done: true })
  })

  it('reports job_done false for a job still in progress, even on an empty page', async () => {
    expect((await logs(RUNNING_JOB)).body).toMatchObject({ next_after: 3, job_done: false })
    expect((await logs(RUNNING_JOB, '?after=3')).body).toEqual({ lines: [], next_after: 3, job_done: false })
  })

  it('answers an unknown job with 404 and a bad id with 400', async () => {
    expect(await logs(987654321)).toEqual({ status: 404, body: { error: 'not found' } })
    expect((await app.request('/api/jobs/abc/logs')).status).toBe(400)
  })

  it("scans only chunks from the job's start onward", async () => {
    // Plan the route's predicate with two started_at values. A start well in the past keeps the
    // seed's chunk in the plan (so the check below can fail); a start in the future puts every
    // chunk below the bound, and TimescaleDB leaves them all out.
    const plan = async (startedAt: Date) =>
      (
        await pool.query(
          `EXPLAIN SELECT seq FROM job_logs WHERE job_id = $1 AND seq > 0 AND ts >= $2::timestamptz - interval '1 hour'`,
          [FAILED_JOB, startedAt],
        )
      ).rows
        .map((r: any) => r['QUERY PLAN'])
        .join('\n')
    const day = 24 * 3600 * 1000
    expect(await plan(new Date(Date.now() - day))).toMatch(/_hyper_\d+_\d+_chunk/)
    expect(await plan(new Date(Date.now() + 365 * day))).not.toMatch(/_hyper_\d+_\d+_chunk/)
  })
})
