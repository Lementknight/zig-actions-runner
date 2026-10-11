import { describe, expect, it } from 'vitest'
import { toRunner, type RunnerRow } from '../src/queries'
import { get, stubDb } from './support'

// GET /api/runners against a stub database, and the status rule (SPEC §4) case by case.
// runners.db.test.ts covers the query against a seeded one.

const at = (iso: string) => new Date(iso)

function row(overrides: Partial<RunnerRow> = {}): RunnerRow {
  return {
    name: 'zig-runner-1',
    status: 'busy',
    labels: ['self-hosted', 'linux', 'zig'],
    registered_at: at('2026-10-11T11:00:00Z'),
    last_seen_at: at('2026-10-11T11:59:50Z'),
    stale: false,
    current_job_id: 9100000002,
    current_job_run_id: 9000000002,
    current_job_name: 'build',
    running_jobs: 1,
    completed_jobs: 2,
    ...overrides,
  }
}

const noJob = { current_job_id: null, current_job_run_id: null, current_job_name: null }

describe('runner status', () => {
  it.each([
    ['busy row with an in-progress job', row(), 'busy'],
    ['idle row', row({ status: 'idle', ...noJob }), 'idle'],
    ['offline row', row({ status: 'offline', ...noJob }), 'offline'],
    ['busy row, heartbeat stale', row({ stale: true }), 'offline'],
    ['idle row, heartbeat stale', row({ status: 'idle', stale: true, ...noJob }), 'offline'],
    ['offline row with a job left in progress', row({ status: 'offline' }), 'offline'],
    ['idle row with a job left in progress by a crashed run', row({ status: 'idle' }), 'idle'],
    ['busy row whose job has no rows yet', row(noJob), 'idle'],
  ])('%s reports %s', (_, input, expected) => {
    const runner = toRunner(input)
    expect(runner.status).toBe(expected)
    // The contract: a current job exactly when busy.
    expect(runner.current_job !== null).toBe(expected === 'busy')
  })

  it('reports the current job as { id, run_id, name } and keeps both counts', () => {
    expect(toRunner(row())).toMatchObject({
      current_job: { id: 9100000002, run_id: 9000000002, name: 'build' },
      running_jobs: 1,
      completed_jobs: 2,
    })
    expect(toRunner(row({ stale: true }))).toMatchObject({ current_job: null, running_jobs: 1, completed_jobs: 2 })
  })
})

describe('GET /api/runners', () => {
  it('returns a bare array with the documented fields, timestamps as ISO 8601', async () => {
    const { db, calls } = stubDb([[/FROM runners/, () => [row()]]])
    const { status, body } = await get(db, '/api/runners')
    expect(status).toBe(200)
    expect(body).toEqual([
      {
        name: 'zig-runner-1',
        status: 'busy',
        labels: ['self-hosted', 'linux', 'zig'],
        registered_at: '2026-10-11T11:00:00.000Z',
        last_seen_at: '2026-10-11T11:59:50.000Z',
        current_job: { id: 9100000002, run_id: 9000000002, name: 'build' },
        running_jobs: 1,
        completed_jobs: 2,
      },
    ])
    expect(calls).toHaveLength(1)
  })

  it('orders by name in byte order, judges staleness by the database clock, and counts from jobs.runner_name', async () => {
    const { db, calls } = stubDb()
    expect((await get(db, '/api/runners')).body).toEqual([])
    const sql = calls[0].sql
    expect(sql).toMatch(/ORDER BY r\.name COLLATE "C"$/)
    expect(sql).toMatch(/last_seen_at < now\(\) - interval '2 minutes' AS stale/)
    expect(sql).toMatch(/WHERE runner_name = r\.name AND status IN \('in_progress', 'completed'\)/)
  })
})
