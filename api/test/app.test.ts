import { describe, expect, it } from 'vitest'
import { createApp } from '../src/app'
import type { Queryable } from '../src/db'

// The routes against a stub database: parameter handling, response shapes and error bodies.
// No Postgres needed; runs.db.test.ts covers the same routes against a real one.

interface Call {
  sql: string
  params: unknown[]
}

/** Answers each query with the first handler whose pattern matches its SQL, and records it. */
function stubDb(handlers: [RegExp, (params: unknown[]) => unknown[]][] = []) {
  const calls: Call[] = []
  const db: Queryable = {
    async query(sql: string, params: unknown[] = []) {
      calls.push({ sql, params })
      const handler = handlers.find(([pattern]) => pattern.test(sql))
      return { rows: (handler ? handler[1](params) : []) as never[] }
    },
  }
  return { db, calls }
}

const at = (iso: string) => new Date(iso)

const run = {
  id: 9000000003,
  repo: 'Lementknight/zig-actions-runner',
  workflow: 'CI',
  event: 'push',
  branch: 'main',
  sha: 'a'.repeat(40),
  status: 'completed',
  conclusion: 'failure',
  created_at: at('2026-10-11T12:00:00Z'),
  completed_at: at('2026-10-11T12:01:00Z'),
}

const job = (id: number) => ({
  id,
  run_id: run.id,
  name: `job ${id}`,
  runner_name: 'zig-runner-1',
  status: 'completed',
  conclusion: 'success',
  started_at: at('2026-10-11T12:00:00Z'),
  completed_at: null,
})

const step = (job_id: number, number: number) => ({
  job_id,
  number,
  name: `step ${number}`,
  status: 'completed',
  conclusion: 'success',
  started_at: null,
  completed_at: null,
})

async function get(db: Queryable, path: string) {
  const response = await createApp(db).request(path)
  return { status: response.status, body: (await response.json()) as unknown }
}

describe('GET /api/health', () => {
  it('answers { ok: true } after the database answers', async () => {
    const { db, calls } = stubDb()
    expect(await get(db, '/api/health')).toEqual({ status: 200, body: { ok: true } })
    expect(calls).toHaveLength(1)
  })

  it('answers 503 when the database does not', async () => {
    const db: Queryable = { query: () => Promise.reject(new Error('connection refused')) }
    const { status, body } = await get(db, '/api/health')
    expect(status).toBe(503)
    expect(body).toMatchObject({ ok: false })
  })
})

describe('GET /api/runs', () => {
  it('defaults limit to 50 with no filter, newest first', async () => {
    const { db, calls } = stubDb([[/FROM runs/, () => [run]]])
    const { status, body } = await get(db, '/api/runs')
    expect(status).toBe(200)
    expect(Array.isArray(body)).toBe(true)
    expect(calls[0].sql).not.toMatch(/WHERE/)
    expect(calls[0].sql).toMatch(/ORDER BY created_at DESC, id DESC LIMIT \$1$/)
    expect(calls[0].params).toEqual([50])
  })

  it('caps limit at 200', async () => {
    const { db, calls } = stubDb()
    await get(db, '/api/runs?limit=5000')
    expect(calls[0].params).toEqual([200])
  })

  it('passes repo and before through as parameters, never as SQL text', async () => {
    const { db, calls } = stubDb()
    await get(db, `/api/runs?repo=${encodeURIComponent("o/r'; DROP TABLE runs; --")}&before=9000000002&limit=10`)
    expect(calls[0].sql).not.toContain('DROP')
    expect(calls[0].sql).toMatch(/repo = \$1/)
    expect(calls[0].sql).toMatch(/\(created_at, id\) < \(SELECT created_at, id FROM runs WHERE id = \$2\)/)
    expect(calls[0].params).toEqual(["o/r'; DROP TABLE runs; --", 9000000002, 10])
  })

  it('treats empty parameters as absent', async () => {
    const { db, calls } = stubDb()
    await get(db, '/api/runs?repo=&limit=&before=')
    expect(calls[0].params).toEqual([50])
  })

  it.each(['limit=0', 'limit=-1', 'limit=ten', 'limit=1.5', 'before=abc', 'before=0', 'before=99999999999999999999'])(
    'answers 400 for %s without querying',
    async (query) => {
      const { db, calls } = stubDb()
      const { status, body } = await get(db, `/api/runs?${query}`)
      expect(status).toBe(400)
      expect(body).toHaveProperty('error')
      expect(calls).toHaveLength(0)
    },
  )

  it('writes ids as numbers and timestamps as ISO 8601', async () => {
    const { db } = stubDb([[/FROM runs/, () => [run]]])
    const { body } = await get(db, '/api/runs')
    expect(body).toEqual([
      { ...run, created_at: '2026-10-11T12:00:00.000Z', completed_at: '2026-10-11T12:01:00.000Z' },
    ])
  })
})

describe('GET /api/runs/:id', () => {
  it('nests each job its own steps, jobs by id and steps by number', async () => {
    const { db, calls } = stubDb([
      [/FROM runs WHERE id/, () => [run]],
      [/FROM jobs/, () => [job(2), job(5)]],
      // Out of order on purpose: the grouping must not depend on the SQL's ORDER BY alone.
      [/FROM steps/, () => [step(5, 1), step(2, 2), step(5, 0), step(2, 0), step(2, 1)]],
    ])
    const { status, body } = await get(db, `/api/runs/${run.id}`)
    expect(status).toBe(200)
    const detail = body as { id: number; jobs: { id: number; steps: { job_id: number; number: number }[] }[] }
    expect(detail.id).toBe(run.id)
    expect(detail.jobs.map((j) => j.id)).toEqual([2, 5])
    expect(detail.jobs[0].steps.map((s) => [s.job_id, s.number])).toEqual([[2, 0], [2, 1], [2, 2]])
    expect(detail.jobs[1].steps.map((s) => [s.job_id, s.number])).toEqual([[5, 0], [5, 1]])
    expect(calls.map((c) => c.params)).toEqual([[run.id], [run.id], [[2, 5]]])
  })

  it('answers a run with no jobs without querying steps', async () => {
    const { db, calls } = stubDb([[/FROM runs WHERE id/, () => [run]]])
    const { body } = await get(db, `/api/runs/${run.id}`)
    expect(body).toMatchObject({ id: run.id, jobs: [] })
    expect(calls).toHaveLength(2)
  })

  it('answers an unknown run with 404 { error: "not found" }', async () => {
    const { db } = stubDb()
    expect(await get(db, '/api/runs/987654321')).toEqual({ status: 404, body: { error: 'not found' } })
  })

  it.each(['abc', '-1', '0', '1e3', '99999999999999999999'])('answers 400 for id %s without querying', async (id) => {
    const { db, calls } = stubDb()
    const { status } = await get(db, `/api/runs/${id}`)
    expect(status).toBe(400)
    expect(calls).toHaveLength(0)
  })
})

describe('errors', () => {
  it('answers an unknown path with 404 JSON', async () => {
    const { db } = stubDb()
    expect(await get(db, '/api/nope')).toEqual({ status: 404, body: { error: 'not found' } })
  })

  it('answers a failed query with 500 and no detail', async () => {
    const db: Queryable = { query: () => Promise.reject(new Error('relation "runs" does not exist')) }
    const errors: unknown[] = []
    const original = console.error
    console.error = (...args: unknown[]) => errors.push(args)
    try {
      expect(await get(db, '/api/runs')).toEqual({ status: 500, body: { error: 'internal error' } })
    } finally {
      console.error = original
    }
    expect(errors).toHaveLength(1)
  })
})
