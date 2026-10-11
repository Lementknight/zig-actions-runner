import { afterAll, describe, expect, it } from 'vitest'
import { createApp } from '../src/app'
import { createPool } from '../src/db'

// GET /api/runners against a database migrated and seeded as in db/README.md. Skipped when
// DATABASE_URL is unset. The seed's heartbeats are relative to when it ran, so a seeded runner
// turns offline two minutes later; each check asks the database whether that has happened yet.

const databaseUrl = process.env.DATABASE_URL

describe.skipIf(!databaseUrl)('runners route against a seeded database', () => {
  const pool = createPool(databaseUrl ?? '')
  const app = createApp(pool)
  afterAll(() => pool.end())

  async function runners() {
    const response = await app.request('/api/runners')
    expect(response.status).toBe(200)
    return (await response.json()) as any[]
  }

  /** Whether the database considers this runner's heartbeat older than two minutes now. */
  async function stale(name: string): Promise<boolean> {
    const { rows } = await pool.query(
      `SELECT last_seen_at < now() - interval '2 minutes' AS stale FROM runners WHERE name = $1`,
      [name],
    )
    return rows[0].stale
  }

  it('lists every runner by name with the documented fields', async () => {
    const list = await runners()
    const names = list.map((r) => r.name)
    expect(names).toEqual([...names].sort())
    expect(names).toEqual(expect.arrayContaining(['zig-runner-1', 'zig-runner-2', 'zig-runner-3']))
    for (const r of list) {
      expect(Object.keys(r).sort()).toEqual(
        ['completed_jobs', 'current_job', 'labels', 'last_seen_at', 'name', 'registered_at', 'running_jobs', 'status'],
      )
      expect(['idle', 'busy', 'offline']).toContain(r.status)
      expect(r.current_job !== null).toBe(r.status === 'busy')
      expect(r.last_seen_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/)
    }
  })

  it('reports zig-runner-1 busy on the seeded in-progress job while its heartbeat is fresh', async () => {
    const r1 = (await runners()).find((r) => r.name === 'zig-runner-1')
    expect(r1).toMatchObject({ labels: ['self-hosted', 'linux', 'zig'], running_jobs: 1, completed_jobs: 2 })
    if (await stale('zig-runner-1')) {
      expect(r1).toMatchObject({ status: 'offline', current_job: null })
    } else {
      expect(r1).toMatchObject({ status: 'busy', current_job: { id: 9100000002, run_id: 9000000002, name: 'build' } })
    }
  })

  it('reports zig-runner-2 idle with no jobs, and zig-runner-3 offline', async () => {
    const list = await runners()
    const r2 = list.find((r) => r.name === 'zig-runner-2')
    expect(r2).toMatchObject({ status: (await stale('zig-runner-2')) ? 'offline' : 'idle', current_job: null })
    expect(r2).toMatchObject({ running_jobs: 0, completed_jobs: 0 })
    expect(list.find((r) => r.name === 'zig-runner-3')).toMatchObject({ status: 'offline', current_job: null })
  })

  it('counts jobs through jobs_runner_name_idx', async () => {
    // A tiny table may plan a sequential scan, so turn that off to see whether the index is usable.
    const client = await pool.connect()
    try {
      await client.query('BEGIN')
      await client.query('SET LOCAL enable_seqscan = off')
      const { rows } = await client.query(
        `EXPLAIN SELECT count(*) FROM jobs WHERE runner_name = 'zig-runner-1' AND status IN ('in_progress', 'completed')`,
      )
      await client.query('ROLLBACK')
      expect(rows.map((r: any) => r['QUERY PLAN']).join('\n')).toMatch(/jobs_runner_name_idx/)
    } finally {
      client.release()
    }
  })
})
