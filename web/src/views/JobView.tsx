import { Spinner } from '@primer/react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'wouter'
import type { JobWithSteps, RunDetail } from '../api'
import { JobToolbar } from '../components/JobToolbar'
import { NotFound } from '../components/NotFound'
import { RetryNotice } from '../components/RetryNotice'
import { StatusIcon } from '../components/StatusIcon'
import { defaultOpenSteps, groupSteps, StepList } from '../components/StepList'
import { RETRY_NOTICE_FAILURES, useJobLogs } from '../hooks/useJobLogs'
import { useRun } from '../hooks/useRun'
import { elapsedSeconds, formatAge, formatDuration } from '../lib/format'
import './JobView.css'

/** How close to the bottom, in CSS pixels, counts as following the tail. */
export const FOLLOW_THRESHOLD_PX = 24

/** The localStorage key for the timestamps setting (R8). */
export const TIMESTAMPS_KEY = 'ar.showTimestamps'

/**
 * The job page at `/runs/:runId/jobs/:jobId` (U4): the run's jobs in a rail, the job's
 * header, its steps with their lines, and a tail that follows new output.
 */
export function JobView({ runId, jobId }: { runId: number; jobId: number }) {
  const run = useRun(runId)
  const job = run.run?.jobs.find((j) => j.id === jobId)

  if (run.notFound) {
    return (
      <NotFound
        title="Run not found"
        body={`There is no run with id ${runId} yet. This page keeps checking, in case it is still being recorded.`}
      />
    )
  }
  if (!run.run) {
    return run.failures >= RETRY_NOTICE_FAILURES ? (
      <RetryNotice>Can't load this job. Retrying.</RetryNotice>
    ) : (
      <div className="ar-box ar-job-view__loading">
        <Spinner size="medium" srText="Loading job" />
      </div>
    )
  }
  if (!job) {
    return (
      <NotFound
        title="Job not found"
        body={`There is no job with id ${jobId} in this run.`}
        backHref={`/runs/${runId}`}
        backLabel="Go to the run"
      />
    )
  }
  // The log loop mounts only once the run has the job, and restarts if the job changes.
  return <JobBody key={job.id} run={run.run} job={job} runFailures={run.failures} />
}

function JobBody({ run, job, runFailures }: { run: RunDetail; job: JobWithSteps; runFailures: number }) {
  const logs = useJobLogs(job.id)

  const [showTimestamps, setShowTimestamps] = useState(readTimestampsSetting)
  const toggleTimestamps = useCallback(() => {
    setShowTimestamps((on) => {
      writeTimestampsSetting(!on)
      return !on
    })
  }, [])

  // Steps the viewer opened or closed by hand, by step number.
  const [overrides, setOverrides] = useState<Record<number, boolean>>({})

  const running = job.status !== 'completed'
  const now = useNow(running)

  const groups = useMemo(() => groupSteps(job.steps, logs.lines, job.status), [job, logs.lines])
  const defaultOpen = useMemo(() => defaultOpenSteps(groups), [groups])
  const isOpen = useCallback((step: number) => overrides[step] ?? defaultOpen.has(step), [overrides, defaultOpen])
  const toggle = useCallback(
    (step: number) => setOverrides((prev) => ({ ...prev, [step]: !(prev[step] ?? defaultOpen.has(step)) })),
    [defaultOpen],
  )

  const following = useFollow(logs.status === 'live', logs.lines.length)
  const retrying = logs.retrying || runFailures >= RETRY_NOTICE_FAILURES

  if (logs.status === 'notFound') {
    return (
      <NotFound
        title="Job not found"
        body={`The API has no log for job ${job.id}.`}
        backHref={`/runs/${run.id}`}
        backLabel="Go to the run"
      />
    )
  }

  return (
    <>
      <nav className="ar-job-crumbs" aria-label="Breadcrumb">
        <Link href="/">All workflows</Link>
        <span className="ar-job-crumbs__sep" aria-hidden>
          /
        </span>
        <Link href={`/runs/${run.id}`}>
          {run.workflow} #{run.id}
        </Link>
      </nav>
      <div className="ar-page-header">
        <h1 className="ar-page-title">{job.name}</h1>
        {run.branch && (
          <p className="ar-page-subtitle">
            <span className="ar-branch">{run.branch}</span>
          </p>
        )}
      </div>
      {retrying && <RetryNotice>Can't reach the server. Showing the output loaded so far and retrying.</RetryNotice>}
      <div className="ar-job-layout">
        <JobRail run={run} currentJobId={job.id} />
        <section className="ar-box ar-job" aria-labelledby="ar-job-heading">
          <header className="ar-job__header">
            <StatusIcon status={job.status} conclusion={job.conclusion} size={24} />
            <div className="ar-job__title">
              <h2 className="ar-job__name" id="ar-job-heading">
                {job.name}
              </h2>
              <p className="ar-job__meta">{jobSentence(job, now)}</p>
            </div>
            <JobToolbar
              showTimestamps={showTimestamps}
              onToggleTimestamps={toggleTimestamps}
              showJump={logs.status === 'live' && !following}
              onJump={scrollToBottom}
            />
          </header>
          <StepList
            groups={groups}
            isOpen={isOpen}
            onToggle={toggle}
            showTimestamps={showTimestamps}
            now={now}
            logsLoading={logs.status === 'loading'}
          />
        </section>
      </div>
    </>
  )
}

/** The run's jobs, as GitHub lists them beside a job, with the open one marked. */
function JobRail({ run, currentJobId }: { run: RunDetail; currentJobId: number }) {
  return (
    <nav className="ar-job-rail" aria-label="Jobs">
      <Link href={`/runs/${run.id}`} className="ar-job-rail__summary">
        Summary
      </Link>
      <h3 className="ar-job-rail__heading">Jobs</h3>
      <ul className="ar-job-rail__list">
        {run.jobs.map((j) => (
          <li key={j.id}>
            <Link
              href={`/runs/${run.id}/jobs/${j.id}`}
              className="ar-job-rail__job"
              aria-current={j.id === currentJobId ? 'page' : undefined}
            >
              <StatusIcon status={j.status} conclusion={j.conclusion} />
              <span className="ar-job-rail__name">{j.name}</span>
            </Link>
          </li>
        ))}
      </ul>
    </nav>
  )
}

/** "succeeded 2 minutes ago in 17s", as GitHub words a job's header line. */
export function jobSentence(job: JobWithSteps, now: number): string {
  const runner = job.runner_name ? ` on ${job.runner_name}` : ''
  if (job.status === 'queued') return 'Queued, waiting for a runner'
  if (job.status === 'in_progress') {
    const seconds = elapsedSeconds(job.started_at, null, now)
    return seconds === null ? `In progress${runner}` : `Running for ${formatDuration(seconds)}${runner}`
  }
  const seconds = elapsedSeconds(job.started_at, job.completed_at, now)
  const duration = seconds === null ? '' : ` in ${formatDuration(seconds)}`
  const when = job.completed_at ? ` ${formatAge(job.completed_at, now)}` : ''
  const verb =
    job.conclusion === 'success'
      ? 'Succeeded'
      : job.conclusion === 'failure'
        ? 'Failed'
        : job.conclusion === 'cancelled'
          ? 'Cancelled'
          : job.conclusion === 'skipped'
            ? 'Skipped'
            : job.conclusion
              ? `Finished (${job.conclusion})`
              : 'Finished'
  return `${verb}${when}${duration}${runner}`
}

/** The current time, ticking once a second while `active`, so running durations move. */
function useNow(active: boolean): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    setNow(Date.now())
    if (!active) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [active])
  return now
}

function distanceFromBottom(): number {
  return document.documentElement.scrollHeight - window.innerHeight - window.scrollY
}

function scrollToBottom(): void {
  window.scrollTo({ top: document.documentElement.scrollHeight })
}

/**
 * Follow the tail: while the viewer is within the threshold of the bottom, each batch of
 * new lines scrolls the page down to them; once they scroll up, the page stays put and the
 * jump button takes over. Returns whether the view is following.
 */
function useFollow(live: boolean, lineCount: number): boolean {
  const [following, setFollowing] = useState(true)

  useEffect(() => {
    const onScroll = () => setFollowing(distanceFromBottom() <= FOLLOW_THRESHOLD_PX)
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  useEffect(() => {
    if (live && following && lineCount > 0) scrollToBottom()
  }, [live, following, lineCount])

  return following
}

function readTimestampsSetting(): boolean {
  try {
    return localStorage.getItem(TIMESTAMPS_KEY) === '1'
  } catch {
    return false
  }
}

function writeTimestampsSetting(on: boolean): void {
  try {
    localStorage.setItem(TIMESTAMPS_KEY, on ? '1' : '0')
  } catch {
    // Private mode or storage blocked: the switch still works for this page view.
  }
}
