import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Router } from 'wouter'
import { memoryLocation } from 'wouter/memory-location'
import { ApiError, ApiProvider, type JobWithSteps, type LogLine, type LogsResponse, type RunDetail, type Step } from '../api'
import { RUN_POLL_MS } from '../hooks/useRun'
import { createScriptedApi, type ScriptedApi } from '../test/scriptedApi'
import { JobView, TIMESTAMPS_KEY } from './JobView'

const NOW = Date.parse('2026-10-11T12:05:00Z')
const T0 = '2026-10-11T12:00:00Z'
const ESC = '\u001b'

function step(number: number, name: string, status = 'completed', conclusion: string | null = 'success'): Step {
  const started = status === 'queued' ? null : `2026-10-11T12:00:${String(number * 10).padStart(2, '0')}Z`
  const completed = status === 'completed' ? `2026-10-11T12:00:${String(number * 10 + 7).padStart(2, '0')}Z` : null
  return { job_id: 20, number, name, status, conclusion, started_at: started, completed_at: completed }
}

function job(steps: Step[], overrides: Partial<JobWithSteps> = {}): JobWithSteps {
  return {
    id: 20,
    run_id: 1,
    name: 'build',
    runner_name: 'zig-runner-01',
    status: 'completed',
    conclusion: 'success',
    started_at: T0,
    completed_at: '2026-10-11T12:01:00Z',
    steps,
    ...overrides,
  }
}

function run(jobs: JobWithSteps[], overrides: Partial<RunDetail> = {}): RunDetail {
  return {
    id: 1,
    repo: 'Lementknight/zig-actions-runner',
    workflow: 'CI',
    event: 'push',
    branch: 'main',
    sha: '5b8e0f3a9c7d',
    status: 'completed',
    conclusion: 'success',
    created_at: T0,
    completed_at: '2026-10-11T12:01:00Z',
    jobs,
    ...overrides,
  }
}

function line(seq: number, stepNumber: number, text: string): LogLine {
  return { seq, step: stepNumber, stream: 'stdout', ts: `2026-10-11T12:00:${String(seq).padStart(2, '0')}Z`, line: text }
}

function page(lines: LogLine[], job_done = true): LogsResponse {
  return { lines, next_after: lines.at(-1)?.seq ?? 0, job_done }
}

const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const elapse = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

let s: ScriptedApi
let location: ReturnType<typeof memoryLocation<unknown>> & { history: string[] }

function renderJob(runId = 1, jobId = 20) {
  location = memoryLocation({ path: `/runs/${runId}/jobs/${jobId}`, record: true })
  return render(
    <Router hook={location.hook}>
      <ApiProvider api={s.api}>
        <JobView runId={runId} jobId={jobId} />
      </ApiProvider>
    </Router>,
  )
}

/** A completed job on screen: the run and one page of lines, both answered. */
async function showCompleted(steps: Step[], lines: LogLine[], jobOverrides: Partial<JobWithSteps> = {}) {
  s.run.push(run([job(steps, jobOverrides)]))
  s.logs.push(page(lines, true), page([], true))
  const view = renderJob()
  await flush()
  return view
}

function stepRow(name: string): HTMLDetailsElement {
  const summary = screen.getByText(name).closest('summary')
  if (!summary) throw new Error(`no step row named ${name}`)
  return summary.parentElement as HTMLDetailsElement
}

function visibleLines(container: ParentNode = document) {
  return [...container.querySelectorAll('.ar-log-line')].map((el) => ({
    number: el.querySelector('.ar-log-line__number')?.textContent,
    text: el.querySelector('.ar-log-line__text')?.textContent,
  }))
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'] })
  vi.setSystemTime(NOW)
  s = createScriptedApi()
  vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
})

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('JobView', () => {
  it('renders one step section per step row with its status icon and duration', async () => {
    await showCompleted(
      [step(1, 'Set up job'), step(2, 'Run zig build'), step(3, 'Upload coverage', 'completed', 'skipped')],
      [line(1, 1, 'Runner name: zig-runner-01'), line(2, 2, 'zig build')],
    )

    expect(screen.getByRole('heading', { level: 1, name: 'build' })).toBeInTheDocument()
    expect(screen.getByText('Succeeded 4 minutes ago in 1m 0s on zig-runner-01')).toBeInTheDocument()

    const rows = document.querySelectorAll('details.ar-step')
    expect(rows).toHaveLength(3)
    expect(within(stepRow('Set up job')).getByRole('img', { name: 'Success' })).toBeInTheDocument()
    expect(within(stepRow('Set up job')).getByText('7s')).toBeInTheDocument()
    expect(within(stepRow('Run zig build')).getByRole('img', { name: 'Success' })).toBeInTheDocument()
    expect(within(stepRow('Upload coverage')).getByRole('img', { name: 'Skipped' })).toBeInTheDocument()
  })

  it('lists the run\'s jobs in the rail with the open one marked', async () => {
    s.run.push(run([job([step(1, 'Set up job')]), job([], { id: 21, name: 'test', conclusion: 'failure' })]))
    s.logs.push(page([], true))
    renderJob()
    await flush()

    const rail = screen.getByRole('navigation', { name: 'Jobs' })
    const links = within(rail).getAllByRole('link')
    expect(links.map((l) => l.textContent)).toEqual(['Summary', 'build', 'test'])
    expect(within(links[1]).getByRole('img', { name: 'Success' })).toBeInTheDocument()
    expect(within(links[2]).getByRole('img', { name: 'Failure' })).toBeInTheDocument()
    expect(links[0]).toHaveAttribute('href', '/runs/1')
    expect(links[1]).toHaveAttribute('aria-current', 'page')
    expect(links[2]).not.toHaveAttribute('aria-current')
    expect(links[2]).toHaveAttribute('href', '/runs/1/jobs/21')
  })

  it('AE6: a line for a step with no row shows under a placeholder until the run refetch names it', async () => {
    s.run.push(run([job([step(1, 'Set up job'), step(2, 'Checkout', 'in_progress', null)], { status: 'in_progress', conclusion: null, completed_at: null })], { status: 'in_progress', conclusion: null, completed_at: null }))
    s.logs.push(page([line(1, 1, 'ready'), line(2, 3, 'hello')], false))
    renderJob()
    await flush()

    const placeholder = stepRow('Step 3')
    expect(placeholder).toHaveAttribute('data-placeholder')
    expect(placeholder.open).toBe(true)
    expect(visibleLines(placeholder)).toEqual([{ number: '1', text: 'hello' }])

    s.run.push(run([job([step(1, 'Set up job'), step(2, 'Checkout'), step(3, 'Run echo hello', 'in_progress', null)], { status: 'in_progress', conclusion: null, completed_at: null })], { status: 'in_progress', conclusion: null, completed_at: null }))
    await elapse(RUN_POLL_MS)

    expect(screen.queryByText('Step 3')).toBeNull()
    const real = stepRow('Run echo hello')
    expect(real).not.toHaveAttribute('data-placeholder')
    expect(within(real).getByRole('img', { name: 'In progress' })).toBeInTheDocument()
    expect(visibleLines(real)).toEqual([{ number: '1', text: 'hello' }])
  })

  it('opens the running step and keeps completed steps closed', async () => {
    s.run.push(run([job([step(1, 'Set up job'), step(2, 'Run zig build', 'in_progress', null), step(3, 'Complete job', 'queued', null)], { status: 'in_progress', conclusion: null, completed_at: null })], { status: 'in_progress', conclusion: null, completed_at: null }))
    s.logs.push(page([line(1, 1, 'ready'), line(2, 2, 'compiling')], false))
    renderJob()
    await flush()

    expect(stepRow('Set up job').open).toBe(false)
    expect(stepRow('Run zig build').open).toBe(true)
    expect(stepRow('Complete job').open).toBe(false)
  })

  it('opens only the first failed step on a failed job', async () => {
    await showCompleted(
      [step(1, 'Set up job'), step(2, 'Run zig build test', 'completed', 'failure'), step(3, 'Run again', 'completed', 'failure'), step(4, 'Upload', 'completed', 'skipped')],
      [line(1, 2, 'error: boom'), line(2, 3, 'error: again')],
      { conclusion: 'failure' },
    )

    expect(stepRow('Set up job').open).toBe(false)
    expect(stepRow('Run zig build test').open).toBe(true)
    expect(stepRow('Run again').open).toBe(false)
    expect(stepRow('Upload').open).toBe(false)
    expect(screen.getByText('Failed 4 minutes ago in 1m 0s on zig-runner-01')).toBeInTheDocument()
  })

  it('mounts no lines under a collapsed step and shows them when it is opened', async () => {
    await showCompleted([step(1, 'Set up job')], [line(1, 1, 'one'), line(2, 1, 'two')])

    expect(visibleLines()).toEqual([])
    fireEvent.click(screen.getByText('Set up job'))
    expect(stepRow('Set up job').open).toBe(true)
    expect(visibleLines()).toEqual([
      { number: '1', text: 'one' },
      { number: '2', text: 'two' },
    ])
    fireEvent.click(screen.getByText('Set up job'))
    expect(visibleLines()).toEqual([])
  })

  it('renders ANSI colors as named spans and markup as literal text', async () => {
    await showCompleted(
      [step(1, 'Run zig build test', 'completed', 'failure')],
      [line(1, 1, `${ESC}[31merror:${ESC}[0m <script>alert(1)</script>`), line(2, 1, `${ESC}[1;32mAll 7 tests passed.${ESC}[0m`)],
      { conclusion: 'failure' },
    )

    const red = document.querySelector('.ar-ansi[data-fg="red"]')
    expect(red).toHaveTextContent('error:')
    expect(screen.getByText(/<script>alert\(1\)<\/script>/)).toBeInTheDocument()
    expect(document.querySelector('script')).toBeNull()
    const green = document.querySelector('.ar-ansi[data-fg="green"]')
    expect(green).toHaveAttribute('data-bold')
  })

  it('restarts line numbers at 1 in each step', async () => {
    s.run.push(run([job([step(1, 'Set up job'), step(2, 'Run zig build')], { conclusion: 'failure' })]))
    s.logs.push(page([line(1, 1, 'a'), line(2, 1, 'b'), line(3, 2, 'c'), line(4, 2, 'd'), line(5, 2, 'e')], true), page([], true))
    renderJob()
    await flush()

    fireEvent.click(screen.getByText('Set up job'))
    fireEvent.click(screen.getByText('Run zig build'))
    expect(visibleLines(stepRow('Set up job')).map((l) => l.number)).toEqual(['1', '2'])
    expect(visibleLines(stepRow('Run zig build')).map((l) => l.number)).toEqual(['1', '2', '3'])
  })

  it('shows timestamps when the switch is on, hides them when off, and remembers the choice', async () => {
    const view = await showCompleted([step(1, 'Set up job')], [line(1, 1, 'one')])
    fireEvent.click(screen.getByText('Set up job'))

    const toggle = screen.getByRole('switch', { name: 'Show timestamps' })
    expect(toggle).toHaveAttribute('aria-checked', 'false')
    expect(document.querySelector('.ar-log-line__ts')).toBeNull()

    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-checked', 'true')
    expect(document.querySelector('.ar-log-line__ts')).toHaveTextContent('2026-10-11T12:00:01Z')
    expect(localStorage.getItem(TIMESTAMPS_KEY)).toBe('1')

    fireEvent.click(toggle)
    expect(document.querySelector('.ar-log-line__ts')).toBeNull()

    fireEvent.click(toggle)
    view.unmount()
    s.run.push(run([job([step(1, 'Set up job')])]))
    s.logs.push(page([line(1, 1, 'one')], true), page([], true))
    renderJob()
    await flush()
    expect(screen.getByRole('switch', { name: 'Show timestamps' })).toHaveAttribute('aria-checked', 'true')
  })

  it('keeps the lines on screen and shows a retry notice after three failed polls', async () => {
    s.run.push(run([job([step(1, 'Run zig build', 'in_progress', null)], { status: 'in_progress', conclusion: null, completed_at: null })], { status: 'in_progress', conclusion: null, completed_at: null }))
    s.run.always(run([job([step(1, 'Run zig build', 'in_progress', null)], { status: 'in_progress', conclusion: null, completed_at: null })], { status: 'in_progress', conclusion: null, completed_at: null }))
    s.logs.push(page([line(1, 1, 'one'), line(2, 1, 'two')], false))
    renderJob()
    await flush()
    expect(visibleLines()).toHaveLength(2)
    expect(screen.queryByRole('status')).toBeNull()

    await elapse(1000)
    s.logs.push(new ApiError('down', 503))
    await elapse(1000)
    s.logs.push(new ApiError('down', 503))
    await elapse(2000)
    s.logs.push(new ApiError('down', 503))
    await flush()

    expect(screen.getByRole('status')).toHaveTextContent("Can't reach the server")
    expect(visibleLines()).toHaveLength(2)

    await elapse(4000)
    s.logs.push(page([line(3, 1, 'three')], false))
    await flush()
    expect(screen.queryByRole('status')).toBeNull()
    expect(visibleLines()).toHaveLength(3)
  })

  it('shows the not found state for a job the run does not have', async () => {
    s.run.push(run([job([step(1, 'Set up job')])]))
    s.logs.push(new ApiError('no such job', 404))
    renderJob(1, 999)
    await flush()
    expect(screen.getByRole('heading', { name: 'Job not found' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Go to the run' })).toHaveAttribute('href', '/runs/1')
  })

  it('shows the not found state for an unknown run', async () => {
    s.run.push(new ApiError('no such run', 404))
    s.logs.push(new ApiError('no such job', 404))
    renderJob(404, 20)
    await flush()
    expect(screen.getByRole('heading', { name: 'Run not found' })).toBeInTheDocument()
  })

  it('shows the loading state until the run arrives', async () => {
    renderJob()
    await flush()
    expect(screen.getByText('Loading job')).toBeInTheDocument()
  })

  it('offers a jump to bottom while live once the viewer scrolls away, and follows again after it', async () => {
    s.run.push(run([job([step(1, 'Run zig build', 'in_progress', null)], { status: 'in_progress', conclusion: null, completed_at: null })], { status: 'in_progress', conclusion: null, completed_at: null }))
    s.logs.push(page([line(1, 1, 'one')], false))
    renderJob()
    await flush()
    expect(screen.queryByRole('button', { name: 'Jump to bottom' })).toBeNull()
    expect(window.scrollTo).toHaveBeenCalled()

    Object.defineProperty(document.documentElement, 'scrollHeight', { value: 2000, configurable: true })
    Object.defineProperty(window, 'innerHeight', { value: 500, configurable: true })
    Object.defineProperty(window, 'scrollY', { value: 100, configurable: true })
    fireEvent.scroll(window)
    const jump = screen.getByRole('button', { name: 'Jump to bottom' })

    vi.mocked(window.scrollTo).mockClear()
    await elapse(1000)
    s.logs.push(page([line(2, 1, 'two')], false))
    await flush()
    expect(visibleLines()).toHaveLength(2)
    expect(window.scrollTo).not.toHaveBeenCalled()

    fireEvent.click(jump)
    expect(window.scrollTo).toHaveBeenCalledWith({ top: 2000 })
  })
})
