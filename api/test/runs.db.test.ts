import { afterAll, describe, expect, it } from 'vitest'
import { createApp } from '../src/app'
import { createPool } from '../src/db'

// The routes against a real database migrated with db/migrations and loaded with db/seed.sql
// (api/README.md). Skipped when DATABASE_URL is unset, so `npm test` stays green without one.
// The database may hold other runs too, so these check the seed's rows relative to each other.

const databaseUrl = process.env.DATABASE_URL

const COMPLETED = 9000000001 // created 10 minutes ago, one job, steps 0..3
const IN_PROGRESS = 9000000002 // created 30 seconds ago
const FAILED = 9000000003 // created 5 minutes ago, steps 0..8
const SEED_REPO = 'Lementknight/zig-actions-runner'

describe.skipIf(!databaseUrl)('read API against a seeded database', () => {
  const pool = createPool(databaseUrl ?? '')
  const app = createApp(pool)
  afterAll(() => pool.end())

  async function get(path: string) {
    const response = await app.request(path)
    return { status: response.status, body: (await response.json()) as any }
  }

  it('connects read-only', async () => {
    const { rows } = await pool.query('SHOW default_transaction_read_only')
    expect(rows[0].default_transaction_read_only).toBe('on')
    await expect(pool.query("INSERT INTO runs (id, repo, workflow, status) VALUES (1, 'x', 'x', 'queued')")).rejects.toThrow(
      /read-only/,
    )
  })

  it('answers health with { ok: true }', async () => {
    expect(await get('/api/health')).toEqual({ status: 200, body: { ok: true } })
  })

  it('lists runs as a bare array, newest first by created_at then id', async () => {
    const { status, body } = await get('/api/runs?limit=200')
    expect(status).toBe(200)
    expect(Array.isArray(body)).toBe(true)
    const keys = body.map((r: any) => [Date.parse(r.created_at), r.id])
    for (let i = 1; i < keys.length; i++) {
      const [prevTs, prevId] = keys[i - 1]
      const [ts, id] = keys[i]
      expect(prevTs > ts || (prevTs === ts && prevId > id)).toBe(true)
    }
    const ids = body.map((r: any) => r.id)
    expect(ids.indexOf(IN_PROGRESS)).toBeLessThan(ids.indexOf(FAILED))
    expect(ids.indexOf(FAILED)).toBeLessThan(ids.indexOf(COMPLETED))
  })

  it('returns only runs older than the run named by before', async () => {
    const all = (await get(`/api/runs?repo=${encodeURIComponent(SEED_REPO)}&limit=200`)).body
    const { body } = await get(`/api/runs?repo=${encodeURIComponent(SEED_REPO)}&limit=200&before=${IN_PROGRESS}`)
    const after = all.slice(all.findIndex((r: any) => r.id === IN_PROGRESS) + 1)
    expect(body.map((r: any) => r.id)).toEqual(after.map((r: any) => r.id))
    expect(body.map((r: any) => r.id)).toContain(FAILED)
    expect(body.map((r: any) => r.id)).not.toContain(IN_PROGRESS)
  })

  it('honors limit and the repo filter', async () => {
    expect((await get('/api/runs?limit=1')).body).toHaveLength(1)
    const { body } = await get(`/api/runs?repo=${encodeURIComponent(SEED_REPO)}`)
    expect(body.length).toBeGreaterThanOrEqual(3)
    for (const r of body) expect(r.repo).toBe(SEED_REPO)
    expect((await get('/api/runs?repo=nobody/nothing')).body).toEqual([])
  })

  it('writes every run column, ids as numbers and timestamps as ISO 8601', async () => {
    const { body } = await get(`/api/runs?repo=${encodeURIComponent(SEED_REPO)}&limit=200`)
    const failed = body.find((r: any) => r.id === FAILED)
    expect(failed).toEqual({
      id: FAILED,
      repo: SEED_REPO,
      workflow: 'CI',
      event: 'push',
      branch: 'feature/job-loop',
      sha: 'a'.repeat(40),
      status: 'completed',
      conclusion: 'failure',
      created_at: expect.stringMatching(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/),
      completed_at: expect.stringMatching(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/),
    })
  })

  it('returns a run with jobs[].steps[] nested, steps by number', async () => {
    const { status, body } = await get(`/api/runs/${FAILED}`)
    expect(status).toBe(200)
    expect(body.id).toBe(FAILED)
    expect(body.jobs).toHaveLength(1)
    const [job] = body.jobs
    expect(job).toMatchObject({ id: 9100000003, run_id: FAILED, name: 'mixed', runner_name: 'zig-runner-1' })
    expect(job.steps.map((s: any) => s.number)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8])
    expect(job.steps[7]).toEqual({
      job_id: 9100000003,
      number: 7,
      name: "echo 'should be skipped'",
      status: 'completed',
      conclusion: 'skipped',
      started_at: null,
      completed_at: null,
    })
  })

  it('keeps nulls for a run still in progress', async () => {
    const { body } = await get(`/api/runs/${IN_PROGRESS}`)
    expect(body).toMatchObject({ status: 'in_progress', conclusion: null, completed_at: null })
    expect(body.jobs[0].steps.at(-1)).toMatchObject({ number: 2, status: 'in_progress', completed_at: null })
  })

  it('answers an unknown run with 404 and a non-numeric id with 400', async () => {
    expect(await get('/api/runs/987654321')).toEqual({ status: 404, body: { error: 'not found' } })
    expect((await get('/api/runs/abc')).status).toBe(400)
  })
})
