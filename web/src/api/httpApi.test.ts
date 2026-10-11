import { describe, expect, it, vi } from 'vitest'
import { ApiError, isAbort, isNotFound } from './Api'
import { createHttpApi } from './httpApi'
import { apiBaseUrl, createApi, dataSource } from './index'

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

/** A fetch double that records each URL and answers with `respond`. */
function fakeFetch(respond: (url: string, init?: RequestInit) => Promise<Response> | Response) {
  const urls: string[] = []
  const impl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    urls.push(String(input))
    return respond(String(input), init)
  })
  return { impl: impl as unknown as typeof fetch, urls }
}

const emptyLogs = { lines: [], next_after: 40, job_done: false }

describe('httpApi requests', () => {
  it('getLogs(7, 40, 1000) requests /api/jobs/7/logs?after=40&limit=1000', async () => {
    const f = fakeFetch(() => json(emptyLogs))
    await createHttpApi('/api', f.impl).getLogs(7, 40, 1000)
    expect(f.urls).toEqual(['/api/jobs/7/logs?after=40&limit=1000'])
  })

  it('joins a base URL with a trailing slash without doubling it', async () => {
    const f = fakeFetch(() => json([]))
    await createHttpApi('http://localhost:8080/api/', f.impl).listRuns({ limit: 20, repo: 'o/r' })
    expect(f.urls).toEqual(['http://localhost:8080/api/runs?repo=o%2Fr&limit=20'])
  })

  it('requests the run list with no query when given no options', async () => {
    const f = fakeFetch(() => json([]))
    await createHttpApi('/api', f.impl).listRuns()
    expect(f.urls).toEqual(['/api/runs'])
  })

  it('requests one run by id', async () => {
    const f = fakeFetch(() => json({ id: 12, repo: 'r', workflow: 'w', status: 'queued', created_at: 'x', jobs: [] }))
    await createHttpApi('/api', f.impl).getRun(12)
    expect(f.urls).toEqual(['/api/runs/12'])
  })
})

describe('httpApi runners', () => {
  it('requests /api/runners and converts bigint strings and a missing current_job', async () => {
    const f = fakeFetch(() =>
      json([
        {
          name: 'r1',
          status: 'busy',
          labels: ['zig'],
          registered_at: 'a',
          last_seen_at: 'b',
          current_job: { id: '9100000002', run_id: '9000000002', name: 'build' },
          running_jobs: '1',
          completed_jobs: 2,
        },
        { name: 'r2', status: 'idle', labels: null, registered_at: 'a', last_seen_at: 'b', current_job: null },
      ]),
    )
    const runners = await createHttpApi('/api', f.impl).listRunners()
    expect(f.urls).toEqual(['/api/runners'])
    expect(runners[0].current_job).toEqual({ id: 9100000002, run_id: 9000000002, name: 'build' })
    expect(runners[0]).toMatchObject({ running_jobs: 1, completed_jobs: 2 })
    expect(runners[1]).toMatchObject({ labels: [], current_job: null, running_jobs: 0, completed_jobs: 0 })
  })

  it('accepts the list wrapped in { runners }', async () => {
    const f = fakeFetch(() => json({ runners: [] }))
    expect(await createHttpApi('/api', f.impl).listRunners()).toEqual([])
  })
})

describe('httpApi errors', () => {
  it('rejects a 404 with an ApiError whose status is 404', async () => {
    const f = fakeFetch(() => new Response('not found', { status: 404 }))
    const error = await createHttpApi('/api', f.impl).getRun(1).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect((error as ApiError).status).toBe(404)
    expect(isNotFound(error)).toBe(true)
  })

  it('rejects a 503 with its status, which is not a not found', async () => {
    const f = fakeFetch(() => new Response('', { status: 503 }))
    const error = await createHttpApi('/api', f.impl).getLogs(1, 0, 1000).catch((e: unknown) => e)
    expect((error as ApiError).status).toBe(503)
    expect(isNotFound(error)).toBe(false)
  })

  it('rejects a network failure with an ApiError and no status', async () => {
    const f = fakeFetch(() => Promise.reject(new TypeError('Failed to fetch')))
    const error = await createHttpApi('/api', f.impl).listRuns().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect((error as ApiError).status).toBeUndefined()
  })

  it('rejects a body that is not JSON with an ApiError', async () => {
    const f = fakeFetch(() => new Response('<html>', { status: 200 }))
    await expect(createHttpApi('/api', f.impl).listRuns()).rejects.toBeInstanceOf(ApiError)
  })

  it('rejects promptly with an AbortError when the signal aborts mid request', async () => {
    // A server that never answers; only the abort can end the request.
    const f = fakeFetch(
      (_url, init) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
        }),
    )
    const controller = new AbortController()
    const pending = createHttpApi('/api', f.impl).getLogs(7, 0, 1000, controller.signal)
    controller.abort()
    const error = await pending.catch((e: unknown) => e)
    expect(isAbort(error)).toBe(true)
    expect(error).not.toBeInstanceOf(ApiError)
  })
})

describe('httpApi responses', () => {
  it('turns BIGINT ids and seqs sent as strings back into numbers', async () => {
    const f = fakeFetch(() =>
      json({
        lines: [{ seq: '41', step: '2', stream: 'stdout', ts: '2026-10-11T12:00:00Z', line: 'hi' }],
        next_after: '41',
        job_done: false,
      }),
    )
    const res = await createHttpApi('/api', f.impl).getLogs(7, 40, 1000)
    expect(res).toEqual({
      lines: [{ seq: 41, step: 2, stream: 'stdout', ts: '2026-10-11T12:00:00Z', line: 'hi' }],
      next_after: 41,
      job_done: false,
    })
  })

  it('accepts the run list bare or wrapped in { runs }', async () => {
    const run = { id: '5', repo: 'r', workflow: 'CI', status: 'queued', created_at: 't' }
    const bare = await createHttpApi('/api', fakeFetch(() => json([run])).impl).listRuns()
    const wrapped = await createHttpApi('/api', fakeFetch(() => json({ runs: [run] })).impl).listRuns()
    expect(bare).toEqual(wrapped)
    expect(bare[0]).toMatchObject({ id: 5, event: null, branch: null, sha: null, conclusion: null, completed_at: null })
  })

  it('reads a run with jobs and steps nested, sorting steps by number', async () => {
    const f = fakeFetch(() =>
      json({
        id: 1, repo: 'r', workflow: 'CI', status: 'in_progress', created_at: 't',
        jobs: [{ id: 2, run_id: 1, name: 'build', status: 'in_progress', steps: [
          { job_id: 2, number: 2, name: 'b', status: 'in_progress' },
          { job_id: 2, number: 1, name: 'a', status: 'completed', conclusion: 'success' },
        ] }],
      }),
    )
    const run = await createHttpApi('/api', f.impl).getRun(1)
    expect(run.jobs[0].steps.map((s) => s.name)).toEqual(['a', 'b'])
  })

  it('reads a run sent as flat { run, jobs, steps } lists the same way', async () => {
    const f = fakeFetch(() =>
      json({
        run: { id: '1', repo: 'r', workflow: 'CI', status: 'in_progress', created_at: 't' },
        jobs: [
          { id: '2', run_id: '1', name: 'build', status: 'in_progress' },
          { id: '3', run_id: '1', name: 'test', status: 'queued' },
        ],
        steps: [{ job_id: '2', number: '1', name: 'Set up job', status: 'completed', conclusion: 'success' }],
      }),
    )
    const run = await createHttpApi('/api', f.impl).getRun(1)
    expect(run.id).toBe(1)
    expect(run.jobs.map((j) => [j.id, j.steps.length])).toEqual([[2, 1], [3, 0]])
    expect(run.jobs[0].steps[0]).toMatchObject({ job_id: 2, number: 1 })
  })
})

describe('data source switch', () => {
  it('treats unset and empty as fake', () => {
    expect(dataSource(undefined)).toBe('fake')
    expect(dataSource('')).toBe('fake')
    expect(dataSource('fake')).toBe('fake')
  })

  it('picks http by name and rejects anything else', () => {
    expect(dataSource('http')).toBe('http')
    expect(() => dataSource('postgres')).toThrow(/VITE_DATA_SOURCE/)
  })

  it('defaults the base URL to /api', () => {
    expect(apiBaseUrl(undefined)).toBe('/api')
    expect(apiBaseUrl('')).toBe('/api')
    expect(apiBaseUrl('http://localhost:9000/api')).toBe('http://localhost:9000/api')
  })

  it('builds a working Api for both sources', () => {
    for (const source of ['fake', 'http'] as const) {
      const api = createApi(source)
      expect(typeof api.listRuns).toBe('function')
      expect(typeof api.getLogs).toBe('function')
    }
  })
})
