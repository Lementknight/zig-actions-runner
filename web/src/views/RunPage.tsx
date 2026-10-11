import { Spinner } from '@primer/react'
import { Link } from 'wouter'
import type { JobWithSteps, RunDetail } from '../api'
import { NotFound } from '../components/NotFound'
import { RetryNotice } from '../components/RetryNotice'
import { StatusIcon } from '../components/StatusIcon'
import { RETRY_NOTICE_FAILURES } from '../hooks/useJobLogs'
import { useRun } from '../hooks/useRun'
import { elapsedSeconds, formatAge, formatDuration, runDurationSeconds, shortSha } from '../lib/format'
import { statusVisual } from '../lib/statusVisual'
import './JobView.css'
import './RunPage.css'

/**
 * The run page at `/runs/:id` (U6), after GitHub's run summary: the run's header, a summary
 * box, and one status card per job in API order, refreshing until the run completes
 * (R4, R5, R15, R17). Jobs are cards, not a graph: the schema records no dependencies.
 */
export function RunPage({ runId }: { runId: number }) {
  const { run, notFound, failures, fetchedAt } = useRun(runId)

  if (notFound) {
    return (
      <NotFound
        title="Run not found"
        body={`There is no run with id ${runId} yet. This page keeps checking, in case it is still being recorded.`}
      />
    )
  }
  if (!run) {
    return failures >= RETRY_NOTICE_FAILURES ? (
      <RetryNotice>Can't load this run. Retrying.</RetryNotice>
    ) : (
      <div className="ar-box ar-run-page__loading">
        <Spinner size="medium" srText="Loading run" />
      </div>
    )
  }

  return (
    <>
      <nav className="ar-job-crumbs" aria-label="Breadcrumb">
        <Link href="/">All workflows</Link>
      </nav>
      <div className="ar-page-header">
        <h1 className="ar-page-title">
          {run.workflow} <span className="ar-run-page__number">#{run.id}</span>
        </h1>
        {run.branch && (
          <p className="ar-page-subtitle">
            <span className="ar-branch">{run.branch}</span>
          </p>
        )}
      </div>
      {failures >= RETRY_NOTICE_FAILURES && (
        <RetryNotice>Can't reach the server. Showing this run as last loaded and retrying.</RetryNotice>
      )}
      <div className="ar-job-layout">
        <nav className="ar-job-rail" aria-label="Jobs">
          <Link href={`/runs/${run.id}`} className="ar-job-rail__summary" aria-current="page">
            Summary
          </Link>
          <h3 className="ar-job-rail__heading">Jobs</h3>
          <ul className="ar-job-rail__list">
            {run.jobs.map((job) => (
              <li key={job.id}>
                <Link href={`/runs/${run.id}/jobs/${job.id}`} className="ar-job-rail__job">
                  <StatusIcon status={job.status} conclusion={job.conclusion} />
                  <span className="ar-job-rail__name">{job.name}</span>
                </Link>
              </li>
            ))}
          </ul>
        </nav>
        <div className="ar-run-page__main">
          <RunSummary run={run} now={fetchedAt} />
          <section className="ar-box ar-run-jobs" aria-labelledby="ar-run-jobs-heading">
            <h2 className="ar-run-jobs__heading" id="ar-run-jobs-heading">
              Jobs
            </h2>
            {run.jobs.length === 0 ? (
              <div className="ar-blankslate">
                <h3 className="ar-blankslate__title">Waiting for a runner</h3>
                <p className="ar-blankslate__body">This run's jobs appear here once a runner picks it up.</p>
              </div>
            ) : (
              <ul className="ar-run-jobs__list" aria-label="Job status">
                {run.jobs.map((job) => (
                  <li key={job.id}>
                    <JobCard runId={run.id} job={job} now={fetchedAt} />
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>
      </div>
    </>
  )
}

/** GitHub's summary strip: what triggered the run, its status, and its total duration. */
function RunSummary({ run, now }: { run: RunDetail; now: number }) {
  const sha = shortSha(run.sha)
  const duration = runDurationSeconds(run, now)
  return (
    <section className="ar-box ar-run-summary" aria-label="Run summary">
      <div className="ar-run-summary__item ar-run-summary__item--wide">
        <span className="ar-run-summary__label">
          Triggered{run.event ? ` via ${run.event}` : ''} {formatAge(run.created_at, now)}
        </span>
        <span className="ar-run-summary__value">
          {run.repo}
          {sha && (
            <>
              {' '}
              <code className="ar-run-summary__sha">{sha}</code>
            </>
          )}
        </span>
      </div>
      <div className="ar-run-summary__item">
        <span className="ar-run-summary__label">Status</span>
        <span className="ar-run-summary__value ar-run-summary__status">
          <StatusIcon status={run.status} conclusion={run.conclusion} />
          {statusVisual(run.status, run.conclusion).label}
        </span>
      </div>
      <div className="ar-run-summary__item">
        <span className="ar-run-summary__label">Total duration</span>
        <span className="ar-run-summary__value">{duration === null ? '' : formatDuration(duration)}</span>
      </div>
    </section>
  )
}

/** One job as a status card that opens the job view (R4, R5). */
function JobCard({ runId, job, now }: { runId: number; job: JobWithSteps; now: number }) {
  const seconds = elapsedSeconds(job.started_at, job.completed_at, now)
  return (
    <Link href={`/runs/${runId}/jobs/${job.id}`} className="ar-run-job" data-testid={`job-${job.id}`}>
      <StatusIcon status={job.status} conclusion={job.conclusion} />
      <span className="ar-run-job__name">{job.name}</span>
      <span className="ar-run-job__duration">{seconds === null ? '' : formatDuration(seconds)}</span>
    </Link>
  )
}
