import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Router } from 'wouter'
import { memoryLocation } from 'wouter/memory-location'
import { ApiError, ApiProvider, type Run } from '../api'
import { RUNS_POLL_MS } from '../hooks/useRuns'
import { createScriptedApi, type ScriptedApi } from '../test/scriptedApi'
import { RunList } from './RunList'

const NOW = Date.parse('2026-10-11T12:00:00Z')

function run(id: number, overrides: Partial<Run> = {}): Run {
  return {
    id,
    repo: 'Lementknight/zig-actions-runner',
    workflow: `Workflow ${id}`,
    event: 'push',
    branch: 'main',
    sha: `abcdef${id}0123456789`,
    status: 'completed',
    conclusion: 'success',
    created_at: '2026-10-11T11:50:00Z',
    completed_at: '2026-10-11T11:51:12Z',
    ...overrides,
  }
}

function rowTitles() {
  return within(screen.getByRole('list', { name: 'Workflow runs' }))
    .getAllByRole('link')
    .map((link) => link.textContent)
}

/** Let resolved responses reach React without moving the clock. */
const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const elapse = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

let s: ScriptedApi
let location: ReturnType<typeof memoryLocation<unknown>> & { history: string[] }

function renderList() {
  location = memoryLocation({ path: '/', record: true })
  return render(
    <Router hook={location.hook}>
      <ApiProvider api={s.api}>
        <RunList />
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

describe('RunList', () => {
  it('renders runs newest first with status, workflow, repo, branch, short sha, age and duration', async () => {
    s.runs.push([
      run(3, { workflow: 'Deploy', status: 'in_progress', conclusion: null, completed_at: null, created_at: '2026-10-11T11:59:00Z' }),
      run(2, { workflow: 'CI', conclusion: 'failure' }),
      run(1, { workflow: 'Lint', branch: 'feat/m6-frontend' }),
    ])
    renderList()
    await flush()

    expect(rowTitles()).toEqual(['Deploy', 'CI', 'Lint'])
    expect(screen.getByText('3 workflow runs')).toBeInTheDocument()

    const newest = screen.getByTestId('run-3')
    expect(within(newest).getByRole('img', { name: 'In progress' })).toBeInTheDocument()
    expect(within(newest).getByText('Lementknight/zig-actions-runner')).toBeInTheDocument()
    expect(within(newest).getByText('abcdef3')).toBeInTheDocument()
    expect(within(newest).getByText('main')).toBeInTheDocument()
    expect(within(newest).getByText('1 minute ago')).toBeInTheDocument()
    expect(within(newest).getByText('1m 0s')).toBeInTheDocument()

    const failed = screen.getByTestId('run-2')
    expect(within(failed).getByRole('img', { name: 'Failure' })).toBeInTheDocument()
    expect(within(failed).getByText('10 minutes ago')).toBeInTheDocument()
    expect(within(failed).getByText('1m 12s')).toBeInTheDocument()
    expect(within(screen.getByTestId('run-1')).getByText('feat/m6-frontend')).toBeInTheDocument()
  })

  it('renders a run with no branch, sha or event without crashing and leaves those cells blank', async () => {
    s.runs.push([run(9, { branch: null, sha: null, event: null, status: 'queued', conclusion: null, completed_at: null })])
    renderList()
    await flush()

    const row = screen.getByTestId('run-9')
    expect(within(row).getByRole('img', { name: 'Queued' })).toBeInTheDocument()
    expect(row.querySelector('.ar-branch')).toBeNull()
    expect(row.querySelector('.ar-run-row__sha')).toBeNull()
    expect(row.textContent).not.toMatch(/Commit|triggered|null/)
    expect(row.querySelector('.ar-run-row__meta')?.textContent).toBe('Lementknight/zig-actions-runner #9')
  })

  it('polls again after about 3 seconds and puts a new run at the top', async () => {
    s.runs.push([run(1)])
    renderList()
    await flush()
    expect(s.runs.calls).toHaveLength(1)
    expect(rowTitles()).toEqual(['Workflow 1'])

    s.runs.push([run(2, { status: 'in_progress', conclusion: null, completed_at: null }), run(1)])
    await elapse(RUNS_POLL_MS - 1)
    expect(s.runs.calls).toHaveLength(1)
    await elapse(1)
    expect(s.runs.calls).toHaveLength(2)
    expect(rowTitles()).toEqual(['Workflow 2', 'Workflow 1'])
  })

  it('updates a status icon in place when a poll reports the run finished', async () => {
    s.runs.push([run(1, { status: 'in_progress', conclusion: null, completed_at: null })])
    renderList()
    await flush()
    expect(within(screen.getByTestId('run-1')).getByRole('img', { name: 'In progress' })).toBeInTheDocument()

    s.runs.push([run(1)])
    await elapse(RUNS_POLL_MS)
    expect(within(screen.getByTestId('run-1')).getByRole('img', { name: 'Success' })).toBeInTheDocument()
  })

  it("opens the run's page when its row is clicked", async () => {
    s.runs.push([run(42, { workflow: 'CI' })])
    renderList()
    await flush()

    const link = screen.getByRole('link', { name: 'CI' })
    expect(link).toHaveAttribute('href', '/runs/42')
    fireEvent.click(link)
    expect(location.history.at(-1)).toBe('/runs/42')
  })

  it('shows a retry notice on a failed request and keeps the rows already loaded', async () => {
    s.runs.push([run(2), run(1)])
    renderList()
    await flush()
    expect(screen.queryByRole('status')).toBeNull()

    s.runs.push(new ApiError('Service Unavailable', 503))
    await elapse(RUNS_POLL_MS)
    expect(screen.getByRole('status')).toHaveTextContent("Can't refresh workflow runs")
    expect(rowTitles()).toEqual(['Workflow 2', 'Workflow 1'])

    s.runs.push([run(3), run(2), run(1)])
    await elapse(RUNS_POLL_MS)
    expect(screen.queryByRole('status')).toBeNull()
    expect(rowTitles()).toEqual(['Workflow 3', 'Workflow 2', 'Workflow 1'])
  })

  it('shows a retry notice when the first request fails, then the runs once one succeeds', async () => {
    s.runs.push(new ApiError('network down'))
    renderList()
    await flush()
    expect(screen.getByRole('status')).toHaveTextContent("Can't load workflow runs")

    s.runs.push([run(1)])
    await elapse(RUNS_POLL_MS)
    expect(screen.queryByRole('status')).toBeNull()
    expect(rowTitles()).toEqual(['Workflow 1'])
  })

  it('shows an empty state when there are no runs', async () => {
    s.runs.push([])
    renderList()
    await flush()
    expect(screen.getByRole('heading', { name: 'No workflow runs yet' })).toBeInTheDocument()
  })

  it('stops polling and aborts the request in flight when unmounted', async () => {
    const view = renderList()
    await flush()
    expect(s.runs.pending).toBe(1)
    view.unmount()
    expect(s.runs.pending).toBe(0)
    await elapse(RUNS_POLL_MS * 3)
    expect(s.runs.calls).toHaveLength(1)
  })
})
