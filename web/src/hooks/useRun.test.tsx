import { act, renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, ApiProvider, type RunDetail } from '../api'
import { createScriptedApi, type ScriptedApi } from '../test/scriptedApi'
import { RUN_POLL_MS, useRun } from './useRun'

function detail(id: number, status: string, conclusion: string | null = null): RunDetail {
  return {
    id,
    repo: 'r',
    workflow: 'CI',
    event: 'push',
    branch: 'main',
    sha: 'abc',
    status,
    conclusion,
    created_at: '2026-10-11T12:00:00Z',
    completed_at: status === 'completed' ? '2026-10-11T12:01:00Z' : null,
    jobs: [],
  }
}

const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const elapse = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

let s: ScriptedApi

const push = (...responses: (RunDetail | Error)[]) =>
  act(async () => {
    s.run.push(...responses)
  })

function wrapper({ children }: { children: ReactNode }) {
  return <ApiProvider api={s.api}>{children}</ApiProvider>
}

function mount(runId = 1) {
  return renderHook((props: { runId: number }) => useRun(props.runId), { initialProps: { runId }, wrapper })
}

beforeEach(() => {
  vi.useFakeTimers()
  s = createScriptedApi()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('useRun', () => {
  it('fetches the run and polls about every 2 seconds while it is not completed', async () => {
    const { result } = mount(1)
    await flush()
    expect(result.current.run).toBeNull()
    expect(s.run.calls).toEqual([1])

    await push(detail(1, 'in_progress'))
    expect(result.current.run?.status).toBe('in_progress')

    await elapse(RUN_POLL_MS - 1)
    expect(s.run.calls).toHaveLength(1)
    await elapse(1)
    expect(s.run.calls).toHaveLength(2)
  })

  it('stops polling once the run is completed', async () => {
    const { result } = mount(1)
    await push(detail(1, 'in_progress'))
    await elapse(RUN_POLL_MS)
    await push(detail(1, 'completed', 'success'))
    expect(result.current.run?.conclusion).toBe('success')
    await elapse(RUN_POLL_MS * 5)
    expect(s.run.calls).toHaveLength(2)
  })

  it('does not poll at all for a run that is already completed', async () => {
    mount(1)
    await push(detail(1, 'completed', 'failure'))
    await elapse(RUN_POLL_MS * 3)
    expect(s.run.calls).toHaveLength(1)
  })

  it('reports notFound on a 404 and keeps polling until the run is recorded', async () => {
    const { result } = mount(9105)
    await push(new ApiError('no such run', 404))
    expect(result.current.notFound).toBe(true)
    expect(result.current.failures).toBe(0)
    await elapse(RUN_POLL_MS)
    expect(s.run.calls).toHaveLength(2)
    await push(detail(9105, 'in_progress'))
    expect(result.current.notFound).toBe(false)
    expect(result.current.run?.id).toBe(9105)
  })

  it('keeps the run and counts failures, then resets on success', async () => {
    const { result } = mount(1)
    await push(detail(1, 'in_progress'))
    await elapse(RUN_POLL_MS)
    await push(new ApiError('down', 503))
    expect(result.current.run?.status).toBe('in_progress')
    expect(result.current.failures).toBe(1)
    expect(result.current.error).toBeInstanceOf(ApiError)

    await elapse(RUN_POLL_MS)
    await push(new TypeError('Failed to fetch'))
    expect(result.current.failures).toBe(2)

    await elapse(RUN_POLL_MS)
    await push(detail(1, 'in_progress'))
    expect(result.current.failures).toBe(0)
    expect(result.current.error).toBeNull()
  })

  it('starts over when runId changes', async () => {
    const { result, rerender } = mount(1)
    await push(detail(1, 'in_progress'))
    expect(result.current.run?.id).toBe(1)

    rerender({ runId: 2 })
    expect(result.current.run).toBeNull()
    await flush()
    expect(s.run.calls.at(-1)).toBe(2)
    await push(detail(2, 'completed', 'success'))
    expect(result.current.run?.id).toBe(2)
  })

  it('aborts the request in flight on unmount', async () => {
    const { unmount } = mount(1)
    await flush()
    expect(s.run.pending).toBe(1)
    unmount()
    expect(s.run.pending).toBe(0)
    await elapse(RUN_POLL_MS * 3)
    expect(s.run.calls).toHaveLength(1)
  })
})
