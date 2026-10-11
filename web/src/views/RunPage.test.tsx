import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Router } from 'wouter'
import { memoryLocation } from 'wouter/memory-location'
import { ApiError, ApiProvider, type JobWithSteps, type RunDetail } from '../api'
import { RUN_POLL_MS } from '../hooks/useRun'
import { createScriptedApi, type ScriptedApi } from '../test/scriptedApi'
import { RunPage } from './RunPage'

const NOW = Date.parse('2026-10-11T12:00:00Z')

function job(id: number, overrides: Partial<JobWithSteps> = {}): JobWithSteps {
  return {
    id,
    run_id: 7,
    name: `job ${id}`,
    runner_name: 'zig-host-1',
    status: 'completed',
    conclusion: 'success',
    started_at: '2026-10-11T11:58:00Z',
    completed_at: '2026-10-11T11:58:17Z',
    steps: [],
    ...overrides,
  }
}

function runDetail(overrides: Partial<RunDetail> = {}): RunDetail {
  return {
    id: 7,
    repo: 'Lementknight/zig-actions-runner',
    workflow: 'CI',
    event: 'push',
    branch: 'main',
    sha: '3f9c2e1aa0b1c2d3e4f5',
    status: 'completed',
    conclusion: 'success',
    created_at: '2026-10-11T11:58:00Z',
    completed_at: '2026-10-11T11:59:00Z',
    jobs: [job(1)],
    ...overrides,
  }
}

const inProgress = { status: 'in_progress', conclusion: null, completed_at: null } as const

const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const elapse = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

function cards() {
  return within(screen.getByRole('list', { name: 'Job status' })).getAllByRole('link')
}

let s: ScriptedApi
let location: ReturnType<typeof memoryLocation<unknown>> & { history: string[] }

function renderPage(runId = 7) {
  location = memoryLocation({ path: `/runs/${runId}`, record: true })
  return render(
    <Router hook={location.hook}>
      <ApiProvider api={s.api}>
        <RunPage runId={runId} />
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

describe('RunPage', () => {
  it('shows the run header and summary: workflow, number, branch, commit, event, status, duration', async () => {
    s.run.push(runDetail())
    renderPage()
    await flush()

    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('CI #7')
    expect(screen.getByText('main')).toBeInTheDocument()
    const summary = screen.getByRole('region', { name: 'Run summary' })
    expect(summary).toHaveTextContent('Triggered via push 2 minutes ago')
    expect(within(summary).getByText('3f9c2e1')).toBeInTheDocument()
    expect(within(summary).getByRole('img', { name: 'Success' })).toBeInTheDocument()
    expect(within(summary).getByText('1m 0s')).toBeInTheDocument()
  })

  it('covers AE4: three jobs render as three cards in API order with no connectors', async () => {
    s.run.push(runDetail({ jobs: [job(30, { name: 'lint' }), job(10, { name: 'build' }), job(20, { name: 'test' })] }))
    const { container } = renderPage()
    await flush()

    const list = screen.getByRole('list', { name: 'Job status' })
    expect(list.children).toHaveLength(3)
    expect(cards().map((c) => c.querySelector('.ar-run-job__name')?.textContent)).toEqual(['lint', 'build', 'test'])
    expect(within(list).getByTestId('job-10')).toHaveTextContent('17s')
    // Only status icons draw inside the jobs area: no lines or paths join the cards.
    expect(container.querySelectorAll('.ar-run-jobs svg line, .ar-run-jobs [class*="connector"]')).toHaveLength(0)
  })

  it("updates a card's status icon in place when a refetch finishes the job", async () => {
    s.run.push(runDetail({ ...inProgress, jobs: [job(1, { ...inProgress, name: 'build' })] }))
    renderPage()
    await flush()
    expect(within(screen.getByTestId('job-1')).getByRole('img', { name: 'In progress' })).toBeInTheDocument()

    s.run.push(runDetail({ jobs: [job(1, { name: 'build' })] }))
    await elapse(RUN_POLL_MS)
    expect(within(screen.getByTestId('job-1')).getByRole('img', { name: 'Success' })).toBeInTheDocument()
  })

  it('stops polling once the run is completed', async () => {
    s.run.push(runDetail({ ...inProgress, jobs: [job(1, inProgress)] }), runDetail())
    renderPage()
    await flush()
    await elapse(RUN_POLL_MS)
    expect(s.run.calls).toHaveLength(2)
    expect(screen.getByRole('region', { name: 'Run summary' })).toHaveTextContent('Success')

    await elapse(5000)
    expect(s.run.calls).toHaveLength(2)
  })

  it('shows "Waiting for a runner" for a queued run with no jobs', async () => {
    s.run.push(runDetail({ status: 'queued', conclusion: null, completed_at: null, jobs: [] }))
    renderPage()
    await flush()
    expect(screen.getByRole('heading', { name: 'Waiting for a runner' })).toBeInTheDocument()
    expect(screen.queryByRole('list', { name: 'Job status' })).toBeNull()
  })

  it('opens the job view when a card is clicked', async () => {
    s.run.push(runDetail({ jobs: [job(41, { name: 'build' })] }))
    renderPage()
    await flush()

    const card = screen.getByTestId('job-41')
    expect(card).toHaveAttribute('href', '/runs/7/jobs/41')
    fireEvent.click(card)
    expect(location.history.at(-1)).toBe('/runs/7/jobs/41')
  })

  it('shows the not found state for an unknown run id', async () => {
    s.run.push(new ApiError('Not Found', 404))
    renderPage(999)
    await flush()
    expect(screen.getByRole('heading', { name: 'Run not found' })).toBeInTheDocument()
  })

  it('shows a retry notice after three failed refetches and keeps the cards', async () => {
    s.run.push(runDetail({ ...inProgress, jobs: [job(1, { ...inProgress, name: 'build' })] }))
    renderPage()
    await flush()

    const down = new ApiError('Bad Gateway', 502)
    s.run.push(down, down)
    await elapse(RUN_POLL_MS * 2)
    expect(screen.queryByRole('status')).toBeNull()

    s.run.push(down)
    await elapse(RUN_POLL_MS)
    expect(screen.getByRole('status')).toHaveTextContent("Can't reach the server")
    expect(cards()).toHaveLength(1)

    s.run.push(runDetail({ jobs: [job(1, { name: 'build' })] }))
    await elapse(RUN_POLL_MS)
    expect(screen.queryByRole('status')).toBeNull()
  })
})
