import { describe, expect, it } from 'vitest'
import { ApiError } from '../api/Api'
import { createScriptedApi } from './scriptedApi'

const page = (seqs: number[], job_done = false) => ({
  lines: seqs.map((seq) => ({ seq, step: 1, stream: 'stdout' as const, ts: '2026-10-11T12:00:00Z', line: `l${seq}` })),
  next_after: seqs.at(-1) ?? 0,
  job_done,
})

describe('scriptedApi', () => {
  it('holds a request until the test pushes its response, and records the call', async () => {
    const s = createScriptedApi()
    const pending = s.api.getLogs(7, 40, 1000)
    expect(s.logs.pending).toBe(1)
    s.logs.push(page([41, 42]))
    expect((await pending).next_after).toBe(42)
    expect(s.logs.calls).toEqual([{ jobId: 7, after: 40, limit: 1000 }])
  })

  it('answers from the queue in order, then from the sticky response', async () => {
    const s = createScriptedApi()
    s.logs.push(page([1]), new ApiError('boom', 500))
    s.logs.always(page([], true))
    expect((await s.api.getLogs(1, 0, 10)).next_after).toBe(1)
    await expect(s.api.getLogs(1, 1, 10)).rejects.toMatchObject({ status: 500 })
    expect((await s.api.getLogs(1, 1, 10)).job_done).toBe(true)
  })

  it('rejects a waiting request when its signal aborts', async () => {
    const s = createScriptedApi()
    const controller = new AbortController()
    const pending = s.api.getRun(1, controller.signal)
    controller.abort()
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    expect(s.run.pending).toBe(0)
  })
})
