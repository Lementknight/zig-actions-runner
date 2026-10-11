import { describe, expect, it } from 'vitest'
import { get, stubDb } from './support'

// GET /api/jobs/:id/logs against a stub database: paging, next_after, job_done, limits and errors.
// logs.db.test.ts covers the same rules against a real one.

const STARTED = new Date('2026-10-11T12:00:00Z')

const line = (seq: number) => ({
  seq,
  step: 1,
  stream: 'stdout',
  ts: new Date(STARTED.getTime() + seq * 1000),
  line: `line ${seq}`,
})

/** A job in `status` whose log holds seq 1..`total`; the stub honors after and the LIMIT parameter. */
function jobWithLines(status: string, total: number, startedAt: Date | null = STARTED) {
  return stubDb([
    [/FROM jobs WHERE id/, () => [{ status, started_at: startedAt }]],
    [
      /FROM job_logs/,
      ([, after, limit]) =>
        Array.from({ length: total }, (_, i) => line(i + 1))
          .filter((l) => l.seq > (after as number))
          .slice(0, limit as number),
    ],
  ])
}

type Page = { lines: { seq: number }[]; next_after: number; job_done: boolean }

describe('GET /api/jobs/:id/logs', () => {
  it('returns lines past after in seq order, with next_after the last seq returned', async () => {
    const { db } = jobWithLines('completed', 5)
    const { status, body } = await get(db, '/api/jobs/7/logs?after=1&limit=2')
    expect(status).toBe(200)
    const page = body as Page
    expect(page.lines.map((l) => l.seq)).toEqual([2, 3])
    expect(page.next_after).toBe(3)
  })

  it('writes each line as { seq, step, stream, ts, line } with ts in ISO 8601', async () => {
    const { db } = jobWithLines('completed', 1)
    const { body } = await get(db, '/api/jobs/7/logs')
    expect((body as Page).lines).toEqual([
      { seq: 1, step: 1, stream: 'stdout', ts: '2026-10-11T12:00:01.000Z', line: 'line 1' },
    ])
  })

  it('echoes after as next_after on an empty page', async () => {
    const { db } = jobWithLines('in_progress', 3)
    expect((await get(db, '/api/jobs/7/logs?after=3')).body).toEqual({ lines: [], next_after: 3, job_done: false })
  })

  it('reports job_done only when the job is completed and nothing past next_after remains', async () => {
    const completed = jobWithLines('completed', 4)
    expect(((await get(completed.db, '/api/jobs/7/logs?after=0&limit=3')).body as Page).job_done).toBe(false)
    expect(((await get(completed.db, '/api/jobs/7/logs?after=0&limit=4')).body as Page).job_done).toBe(true)
    expect(((await get(completed.db, '/api/jobs/7/logs?after=4')).body as Page).job_done).toBe(true)

    const running = jobWithLines('in_progress', 4)
    expect(((await get(running.db, '/api/jobs/7/logs?after=0&limit=4')).body as Page).job_done).toBe(false)
    expect(((await get(running.db, '/api/jobs/7/logs?after=4')).body as Page).job_done).toBe(false)
  })

  it('fetches one row past limit to know whether more remain, and returns only limit lines', async () => {
    const { db, calls } = jobWithLines('completed', 10)
    const { body } = await get(db, '/api/jobs/7/logs?limit=3')
    expect((body as Page).lines).toHaveLength(3)
    expect(calls[1].params.slice(0, 3)).toEqual([7, 0, 4])
  })

  it('defaults after to 0 and limit to 1000, and caps limit at 5000', async () => {
    const a = jobWithLines('completed', 0)
    await get(a.db, '/api/jobs/7/logs')
    expect(a.calls[1].params.slice(0, 3)).toEqual([7, 0, 1001])
    const b = jobWithLines('completed', 0)
    await get(b.db, '/api/jobs/7/logs?after=&limit=99999')
    expect(b.calls[1].params.slice(0, 3)).toEqual([7, 0, 5001])
  })

  it("bounds ts at the job's started_at less an hour, so older chunks are skipped", async () => {
    const { db, calls } = jobWithLines('completed', 1)
    await get(db, '/api/jobs/7/logs')
    expect(calls[1].sql).toMatch(/AND ts >= \$4::timestamptz - interval '1 hour'/)
    expect(calls[1].params[3]).toEqual(STARTED)
  })

  it('reads without the ts bound when the job has no started_at yet', async () => {
    const { db, calls } = jobWithLines('queued', 0, null)
    expect((await get(db, '/api/jobs/7/logs')).body).toEqual({ lines: [], next_after: 0, job_done: false })
    expect(calls[1].sql).not.toMatch(/ts >=/)
    expect(calls[1].params).toHaveLength(3)
  })

  it('answers an unknown job with 404 { error: "not found" } without reading logs', async () => {
    const { db, calls } = stubDb()
    expect(await get(db, '/api/jobs/987654321/logs')).toEqual({ status: 404, body: { error: 'not found' } })
    expect(calls).toHaveLength(1)
  })

  it.each(['/api/jobs/abc/logs', '/api/jobs/0/logs', '/api/jobs/7/logs?after=-1', '/api/jobs/7/logs?after=x', '/api/jobs/7/logs?limit=0'])(
    'answers 400 for %s without querying',
    async (path) => {
      const { db, calls } = stubDb()
      const { status, body } = await get(db, path)
      expect(status).toBe(400)
      expect(body).toHaveProperty('error')
      expect(calls).toHaveLength(0)
    },
  )
})
