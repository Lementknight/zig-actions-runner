import { act, renderHook } from '@testing-library/react'
import { StrictMode, type ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, ApiProvider } from '../api'
import type { LogsResponse } from '../api'
import { createScriptedApi, type ScriptedApi } from '../test/scriptedApi'
import { LOG_PAGE_LIMIT, RETRY_NOTICE_FAILURES, useJobLogs } from './useJobLogs'

// The loop runs on real promises and fake timers (KTD9). Every push and every advance of
// the clock is wrapped in act, so React applies the dispatches before the test looks.

const page = (seqs: number[], job_done = false, next_after = seqs.at(-1) ?? 0): LogsResponse => ({
  lines: seqs.map((seq) => ({
    seq,
    step: 1,
    stream: 'stdout' as const,
    ts: '2026-10-11T12:00:00Z',
    line: `line ${seq}`,
  })),
  next_after,
  job_done,
})

const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i)

const seqs = (lines: { seq: number }[]) => lines.map((l) => l.seq)

/** Let pending promises settle without moving the clock. */
const flush = () => act(() => vi.advanceTimersByTimeAsync(0))

/** Move the fake clock, running every timer that falls due. */
const tick = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

let s: ScriptedApi

/** Answer the request the loop is waiting on. */
const push = (...responses: (LogsResponse | Error)[]) =>
  act(async () => {
    s.logs.push(...responses)
  })

function wrapper({ children }: { children: ReactNode }) {
  return <ApiProvider api={s.api}>{children}</ApiProvider>
}

function strictWrapper({ children }: { children: ReactNode }) {
  return (
    <StrictMode>
      <ApiProvider api={s.api}>{children}</ApiProvider>
    </StrictMode>
  )
}

function mount(jobId = 7) {
  return renderHook((props: { jobId: number }) => useJobLogs(props.jobId), {
    initialProps: { jobId },
    wrapper,
  })
}

beforeEach(() => {
  vi.useFakeTimers()
  s = createScriptedApi()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('useJobLogs', () => {
  it('starts loading with one request at after=0 and limit 1000', async () => {
    const { result } = mount(7)
    await flush()
    expect(result.current.status).toBe('loading')
    expect(result.current.lines).toEqual([])
    expect(s.logs.calls).toEqual([{ jobId: 7, after: 0, limit: LOG_PAGE_LIMIT }])
  })

  it('AE1: lines 41 to 45 append after 40 in order with none twice', async () => {
    const { result } = mount()
    await push(page(range(1, 40)))
    expect(result.current.status).toBe('live')
    expect(result.current.lines).toHaveLength(40)

    await tick(1000)
    expect(s.logs.calls.at(-1)).toMatchObject({ after: 40 })
    await push(page(range(41, 45)))

    expect(seqs(result.current.lines)).toEqual(range(1, 45))
    expect(new Set(seqs(result.current.lines)).size).toBe(45)
  })

  it('an overlapping page 39 to 42 appends only 41 and 42', async () => {
    const { result } = mount()
    await push(page(range(1, 40)))
    await tick(1000)
    await push(page(range(39, 42)))
    expect(seqs(result.current.lines)).toEqual(range(1, 42))
  })

  it('AE2: job_done with lines is followed at once by a request; the empty page ends done', async () => {
    const { result } = mount()
    await push(page([1, 2, 3], true))
    // No sleep: the next request is already waiting.
    expect(s.logs.calls).toHaveLength(2)
    expect(s.logs.calls[1]).toMatchObject({ after: 3 })
    expect(result.current.status).toBe('live')

    await push(page([], true, 3))
    expect(result.current.status).toBe('done')
    expect(seqs(result.current.lines)).toEqual([1, 2, 3])

    await tick(5000)
    expect(s.logs.calls).toHaveLength(2)
  })

  it('AE3: a completed job of 2500 lines pages through full pages with no sleep and ends done', async () => {
    const { result } = mount()
    await push(page(range(1, 1000), true))
    expect(s.logs.calls).toHaveLength(2)
    expect(s.logs.calls[1]).toMatchObject({ after: 1000 })

    await push(page(range(1001, 2000), true))
    expect(s.logs.calls).toHaveLength(3)
    expect(s.logs.calls[2]).toMatchObject({ after: 2000 })

    // The third page carries the last 500 lines. It is short, but job_done with lines means
    // one more request, which comes back empty and confirms the end (R9, KTD4).
    await push(page(range(2001, 2500), true))
    expect(s.logs.calls).toHaveLength(4)
    expect(s.logs.calls[3]).toMatchObject({ after: 2500 })
    expect(result.current.status).toBe('live')

    await push(page([], true, 2500))
    expect(result.current.status).toBe('done')
    expect(result.current.lines).toHaveLength(2500)
    expect(seqs(result.current.lines)).toEqual(range(1, 2500))

    await tick(5000)
    expect(s.logs.calls).toHaveLength(4)
  })

  it('an empty page while live keeps the cursor and polls again after about a second', async () => {
    const { result } = mount()
    await push(page([1, 2]))
    await tick(1000)
    expect(s.logs.calls).toHaveLength(2)
    await push(page([], false, 2))
    expect(result.current.status).toBe('live')
    expect(result.current.lines).toHaveLength(2)

    await tick(999)
    expect(s.logs.calls).toHaveLength(2)
    await tick(1)
    expect(s.logs.calls).toHaveLength(3)
    expect(s.logs.calls[2]).toMatchObject({ after: 2 })
  })

  it('keeps the cursor when an empty page echoes a smaller next_after', async () => {
    mount()
    await push(page(range(1, 5)))
    await tick(1000)
    await push(page([], false, 0))
    await tick(1000)
    expect(s.logs.calls.at(-1)).toMatchObject({ after: 5 })
  })

  it('AE5: a failure keeps the lines, counts up, retries with the same after, and a success resets', async () => {
    const { result } = mount()
    await push(page(range(1, 40)))
    await tick(1000)

    await push(new ApiError('boom', 500))
    expect(result.current.lines).toHaveLength(40)
    expect(result.current.status).toBe('live')
    expect(result.current.failures).toBe(1)
    expect(result.current.error).toBeInstanceOf(ApiError)
    expect(result.current.retrying).toBe(false)

    await tick(1000)
    expect(s.logs.calls.at(-1)).toMatchObject({ after: 40 })
    await push(new ApiError('boom', 503))
    expect(result.current.failures).toBe(2)
    expect(result.current.retrying).toBe(false)

    await tick(2000)
    await push(new TypeError('Failed to fetch'))
    expect(result.current.failures).toBe(3)
    expect(result.current.retrying).toBe(true)
    expect(RETRY_NOTICE_FAILURES).toBe(3)
    expect(result.current.lines).toHaveLength(40)

    await tick(4000)
    expect(s.logs.calls.at(-1)).toMatchObject({ after: 40 })
    await push(page(range(41, 42)))
    expect(result.current.failures).toBe(0)
    expect(result.current.error).toBeNull()
    expect(result.current.retrying).toBe(false)
    expect(seqs(result.current.lines)).toEqual(range(1, 42))
  })

  it('backs off 1 s, 2 s, 4 s, then 10 s between failed attempts', async () => {
    mount()
    const fail = () => push(new ApiError('down', 502))
    const expectWait = async (ms: number) => {
      const before = s.logs.calls.length
      await tick(ms - 1)
      expect(s.logs.calls).toHaveLength(before)
      await tick(1)
      expect(s.logs.calls).toHaveLength(before + 1)
    }

    await fail()
    await expectWait(1000)
    await fail()
    await expectWait(2000)
    await fail()
    await expectWait(4000)
    await fail()
    await expectWait(10_000)
    await fail()
    await expectWait(10_000)
  })

  it('a 404 sets notFound and stops polling', async () => {
    const { result } = mount()
    await push(new ApiError('no such job', 404))
    expect(result.current.status).toBe('notFound')
    expect(result.current.lines).toEqual([])
    await tick(10_000)
    expect(s.logs.calls).toHaveLength(1)
  })

  it('unmounting mid request aborts it and nothing is dispatched afterwards', async () => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {})
    const { unmount } = mount()
    await flush()
    expect(s.logs.pending).toBe(1)

    unmount()
    expect(s.logs.pending).toBe(0)

    await tick(5000)
    expect(s.logs.calls).toHaveLength(1)
    expect(errors).not.toHaveBeenCalled()
    errors.mockRestore()
  })

  it('unmounting during the sleep cancels the next request', async () => {
    const { unmount } = mount()
    await push(page([1]))
    unmount()
    await tick(5000)
    expect(s.logs.calls).toHaveLength(1)
  })

  it('changing jobId from A to B clears the lines and starts B at after=0', async () => {
    const { result, rerender } = mount(1)
    await push(page(range(1, 3)))
    expect(result.current.lines).toHaveLength(3)
    await tick(1000)
    expect(s.logs.pending).toBe(1)

    rerender({ jobId: 2 })
    expect(result.current.lines).toEqual([])
    expect(result.current.status).toBe('loading')
    await flush()
    // A's waiting request was aborted; B's is the only one pending.
    expect(s.logs.pending).toBe(1)
    expect(s.logs.calls.at(-1)).toEqual({ jobId: 2, after: 0, limit: LOG_PAGE_LIMIT })

    await push(page([1]))
    expect(result.current.lines).toHaveLength(1)
    expect(result.current.status).toBe('live')
  })

  it('mounting twice in StrictMode leaves one live loop', async () => {
    s.logs.always(page([], false, 0))
    renderHook(() => useJobLogs(7), { wrapper: strictWrapper })
    await tick(3000)
    const atThree = s.logs.calls.length
    await tick(3000)
    // One loop asks once a second; two would ask twice.
    expect(s.logs.calls.length - atThree).toBe(3)
  })
})
