import { act, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Router } from 'wouter'
import { memoryLocation } from 'wouter/memory-location'
import { ApiError, ApiProvider, type Runner } from '../api'
import { RUNNERS_POLL_MS } from '../hooks/useRunners'
import { createScriptedApi, type ScriptedApi } from '../test/scriptedApi'
import { RunnerList } from './RunnerList'

const NOW = Date.parse('2026-10-11T12:00:00Z')

function runner(name: string, overrides: Partial<Runner> = {}): Runner {
  return {
    name,
    status: 'idle',
    labels: ['self-hosted', 'linux', 'zig'],
    registered_at: '2026-10-11T11:00:00Z',
    last_seen_at: '2026-10-11T11:58:00Z',
    current_job: null,
    running_jobs: 0,
    completed_jobs: 0,
    ...overrides,
  }
}

const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const elapse = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

let s: ScriptedApi

function renderList() {
  const location = memoryLocation({ path: '/runners' })
  return render(
    <Router hook={location.hook}>
      <ApiProvider api={s.api}>
        <RunnerList />
      </ApiProvider>
    </Router>,
  )
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] })
  vi.setSystemTime(NOW)
  s = createScriptedApi()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('RunnerList', () => {
  it('shows an idle runner as Idle with no current job', async () => {
    s.runners.push([runner('zig-runner-1', { completed_jobs: 3 })])
    renderList()
    await flush()

    const row = screen.getByTestId('runner-zig-runner-1')
    expect(within(row).getByText('Idle')).toBeInTheDocument()
    expect(within(row).getByText('No current job')).toBeInTheDocument()
    expect(within(row).getByText('0 running')).toBeInTheDocument()
    expect(within(row).getByText('3 completed')).toBeInTheDocument()
    expect(within(row).getByText('2 minutes ago')).toBeInTheDocument()
    expect(within(row).getByText('linux')).toBeInTheDocument()
    expect(screen.getByText('1 runner')).toBeInTheDocument()
  })

  it("shows a busy runner as Busy with a link to its current job's page", async () => {
    s.runners.push([
      runner('zig-runner-2', {
        status: 'busy',
        current_job: { id: 77, run_id: 12, name: 'build' },
        running_jobs: 1,
        completed_jobs: 5,
      }),
    ])
    renderList()
    await flush()

    const row = screen.getByTestId('runner-zig-runner-2')
    expect(within(row).getByText('Busy')).toBeInTheDocument()
    expect(within(row).getByRole('link', { name: 'build' })).toHaveAttribute('href', '/runs/12/jobs/77')
    expect(within(row).getByText('1 running')).toBeInTheDocument()
  })

  it('shows a stopped runner as Offline', async () => {
    s.runners.push([runner('zig-runner-3', { status: 'offline', last_seen_at: '2026-10-11T09:00:00Z' })])
    renderList()
    await flush()

    const row = screen.getByTestId('runner-zig-runner-3')
    expect(within(row).getByText('Offline')).toBeInTheDocument()
    expect(within(row).getByText('3 hours ago')).toBeInTheDocument()
  })

  it('renders an unknown status as its raw value instead of crashing', async () => {
    s.runners.push([runner('r', { status: 'draining' })])
    renderList()
    await flush()
    expect(within(screen.getByTestId('runner-r')).getByText('draining')).toBeInTheDocument()
  })

  it('polls again after about 3 seconds and updates a runner in place', async () => {
    s.runners.push([runner('r1')])
    renderList()
    await flush()
    expect(within(screen.getByTestId('runner-r1')).getByText('Idle')).toBeInTheDocument()

    s.runners.push([runner('r1', { status: 'busy', current_job: { id: 1, run_id: 2, name: 'build' }, running_jobs: 1 })])
    await elapse(RUNNERS_POLL_MS - 1)
    expect(s.runners.calls).toHaveLength(1)
    await elapse(1)
    expect(s.runners.calls).toHaveLength(2)
    expect(within(screen.getByTestId('runner-r1')).getByText('Busy')).toBeInTheDocument()
  })

  it('shows a blank slate when there are no runners', async () => {
    s.runners.push([])
    renderList()
    await flush()
    expect(screen.getByText('No runners yet')).toBeInTheDocument()
  })

  it('shows a retry notice on a failed request and keeps the rows already loaded', async () => {
    s.runners.push([runner('r1')])
    renderList()
    await flush()

    s.runners.push(new ApiError('boom', 500))
    await elapse(RUNNERS_POLL_MS)
    expect(screen.getByText(/Can't refresh runners/)).toBeInTheDocument()
    expect(screen.getByTestId('runner-r1')).toBeInTheDocument()

    s.runners.push([runner('r1')])
    await elapse(RUNNERS_POLL_MS)
    expect(screen.queryByText(/Can't refresh runners/)).toBeNull()
  })
})
