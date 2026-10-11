import { useState } from 'react'
import { Label, Spinner, ToggleSwitch } from '@primer/react'
import { Link } from 'wouter'
import type { Runner } from '../api'
import { RetryNotice } from '../components/RetryNotice'
import { StatusIcon } from '../components/StatusIcon'
import { elapsedSeconds, formatAge, formatDuration } from '../lib/format'
import { useRunnerJobs, type RunnerJob } from '../hooks/useRunnerJobs'
import { useRunners } from '../hooks/useRunners'
import './RunnerList.css'

const BADGE: Record<string, { variant: 'success' | 'accent' | 'secondary'; label: string }> = {
  idle: { variant: 'success', label: 'Idle' },
  busy: { variant: 'accent', label: 'Busy' },
  offline: { variant: 'secondary', label: 'Offline' },
}

/** `/runners`: every runner, its state, current job and job counts, refreshing itself. */
export function RunnerList() {
  const { runners, error, fetchedAt } = useRunners()
  const [showJobs, setShowJobs] = useState(false)
  const runnerJobs = useRunnerJobs(showJobs)

  return (
    <>
      <div className="ar-page-header">
        <h1 className="ar-page-title">Runners</h1>
        <p className="ar-page-subtitle">Self-hosted runners and the jobs they pick up</p>
        <div className="ar-runner-list__toggle">
          <span id="ar-show-jobs-label">Show all jobs</span>
          <ToggleSwitch
            size="small"
            statusLabelPosition="end"
            checked={showJobs}
            onClick={() => setShowJobs((on) => !on)}
            aria-labelledby="ar-show-jobs-label"
          />
        </div>
      </div>
      {showJobs && runnerJobs.error != null && (
        <RetryNotice>
          {runnerJobs.jobs
            ? "Can't refresh jobs. Showing the last list loaded and retrying every few seconds."
            : "Can't load jobs. Retrying every few seconds."}
        </RetryNotice>
      )}
      {error != null && (
        <RetryNotice>
          {runners
            ? "Can't refresh runners. Showing the last list loaded and retrying every few seconds."
            : "Can't load runners. Retrying every few seconds."}
        </RetryNotice>
      )}
      {runners === null ? (
        error == null && (
          <div className="ar-box ar-runner-list__loading">
            <Spinner size="medium" srText="Loading runners" />
          </div>
        )
      ) : runners.length === 0 ? (
        <div className="ar-box">
          <div className="ar-blankslate">
            <h2 className="ar-blankslate__title">No runners yet</h2>
            <p className="ar-blankslate__body">A runner shows up here as soon as it registers with GitHub.</p>
          </div>
        </div>
      ) : (
        <div className="ar-box">
          <div className="ar-runner-list__header">
            {runners.length} {runners.length === 1 ? 'runner' : 'runners'}
          </div>
          <ul className="ar-runner-list" aria-label="Runners">
            {runners.map((runner) => (
              <RunnerRow
                key={runner.name}
                runner={runner}
                now={fetchedAt}
                jobs={showJobs ? (runnerJobs.jobs?.filter((j) => j.job.runner_name === runner.name) ?? null) : undefined}
                jobsNow={runnerJobs.fetchedAt}
              />
            ))}
          </ul>
        </div>
      )}
    </>
  )
}

/** Running jobs first, then finished ones, newest first. */
function byActivity(a: RunnerJob, b: RunnerJob): number {
  const running = (j: RunnerJob) => (j.job.status === 'completed' ? 1 : 0)
  return running(a) - running(b) || Date.parse(b.job.started_at ?? b.run.created_at) - Date.parse(a.job.started_at ?? a.run.created_at)
}

/** `jobs` undefined hides the job list; null shows it loading. */
function RunnerRow({
  runner,
  now,
  jobs,
  jobsNow,
}: {
  runner: Runner
  now: number
  jobs: RunnerJob[] | null | undefined
  jobsNow: number
}) {
  const badge = BADGE[runner.status] ?? { variant: 'secondary' as const, label: runner.status }
  const job = runner.current_job
  return (
    <li className="ar-runner-row" data-testid={`runner-${runner.name}`}>
      <div className="ar-runner-row__main">
        <span className="ar-runner-row__name">{runner.name}</span>
        <Label variant={badge.variant}>{badge.label}</Label>
        <div className="ar-runner-row__meta">
          {runner.labels.map((label) => (
            <span key={label} className="ar-runner-row__label">
              {label}
            </span>
          ))}
        </div>
      </div>
      <div className="ar-runner-row__job">
        {job ? (
          <>
            Running{' '}
            <Link href={`/runs/${job.run_id}/jobs/${job.id}`} className="ar-runner-row__job-link">
              {job.name}
            </Link>
          </>
        ) : (
          <span className="ar-runner-row__none">No current job</span>
        )}
      </div>
      <div className="ar-runner-row__counts">
        <span>{runner.running_jobs} running</span>
        <span>{runner.completed_jobs} completed</span>
        <span>
          Last seen{' '}
          <time dateTime={runner.last_seen_at} title={new Date(runner.last_seen_at).toLocaleString()}>
            {formatAge(runner.last_seen_at, now)}
          </time>
        </span>
      </div>
      {jobs !== undefined && (
        <div className="ar-runner-row__jobs">
          {jobs === null ? (
            <Spinner size="small" srText={`Loading jobs for ${runner.name}`} />
          ) : jobs.length === 0 ? (
            <span className="ar-runner-row__none">No jobs yet</span>
          ) : (
            <ul className="ar-runner-jobs" aria-label={`Jobs on ${runner.name}`}>
              {[...jobs].sort(byActivity).map(({ job, run }) => {
                const seconds = elapsedSeconds(job.started_at, job.completed_at, jobsNow)
                return (
                  <li key={job.id} className="ar-runner-job" data-testid={`runner-job-${job.id}`}>
                    <StatusIcon status={job.status} conclusion={job.conclusion} />
                    <Link href={`/runs/${run.id}/jobs/${job.id}`} className="ar-runner-job__name">
                      {job.name}
                    </Link>
                    <span className="ar-runner-job__run">
                      {run.workflow} #{run.id}
                    </span>
                    <span className="ar-runner-job__time">{seconds === null ? '' : formatDuration(seconds)}</span>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}
    </li>
  )
}
