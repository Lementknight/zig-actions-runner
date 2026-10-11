import { Spinner } from '@primer/react'
import { CalendarIcon, StopwatchIcon } from '@primer/octicons-react'
import { Link } from 'wouter'
import type { Run } from '../api'
import { RetryNotice } from '../components/RetryNotice'
import { StatusIcon } from '../components/StatusIcon'
import { formatAge, formatDuration, runDurationSeconds, shortSha } from '../lib/format'
import { useRuns } from '../hooks/useRuns'
import './RunList.css'

/** The landing page at `/`: every run, newest first, refreshing itself (R1, R2, R14, R17). */
export function RunList() {
  const { runs, error, fetchedAt } = useRuns()

  return (
    <>
      <div className="ar-page-header">
        <h1 className="ar-page-title">All workflows</h1>
        <p className="ar-page-subtitle ar-run-list__subtitle">Showing runs from all workflows</p>
      </div>
      {error != null && (
        <RetryNotice>
          {runs
            ? "Can't refresh workflow runs. Showing the last list loaded and retrying every few seconds."
            : "Can't load workflow runs. Retrying every few seconds."}
        </RetryNotice>
      )}
      {runs === null ? (
        error == null && (
          <div className="ar-box ar-run-list__loading">
            <Spinner size="medium" srText="Loading workflow runs" />
          </div>
        )
      ) : runs.length === 0 ? (
        <div className="ar-box">
          <div className="ar-blankslate">
            <h2 className="ar-blankslate__title">No workflow runs yet</h2>
            <p className="ar-blankslate__body">Runs show up here as soon as a push starts a workflow on the runner.</p>
          </div>
        </div>
      ) : (
        <div className="ar-box">
          <div className="ar-run-list__header">
            {runs.length} workflow {runs.length === 1 ? 'run' : 'runs'}
          </div>
          <ul className="ar-run-list" aria-label="Workflow runs">
            {runs.map((run) => (
              <RunRow key={run.id} run={run} now={fetchedAt} />
            ))}
          </ul>
        </div>
      )}
    </>
  )
}

function RunRow({ run, now }: { run: Run; now: number }) {
  const sha = shortSha(run.sha)
  const duration = runDurationSeconds(run, now)
  return (
    <li className="ar-run-row" data-testid={`run-${run.id}`}>
      <span className="ar-run-row__status">
        <StatusIcon status={run.status} conclusion={run.conclusion} />
      </span>
      <div className="ar-run-row__main">
        <Link href={`/runs/${run.id}`} className="ar-run-row__title">
          {run.workflow}
        </Link>
        <div className="ar-run-row__meta">
          <span className="ar-run-row__repo">{run.repo}</span> #{run.id}
          {sha && (
            <>
              : Commit <code className="ar-run-row__sha">{sha}</code>
            </>
          )}
          {run.event && <> triggered by {run.event}</>}
        </div>
      </div>
      <div className="ar-run-row__branch">{run.branch && <span className="ar-branch">{run.branch}</span>}</div>
      <div className="ar-run-row__times">
        <span className="ar-run-row__time">
          <CalendarIcon size={16} aria-hidden />
          <time dateTime={run.created_at} title={new Date(run.created_at).toLocaleString()}>
            {formatAge(run.created_at, now)}
          </time>
        </span>
        <span className="ar-run-row__time">
          {duration !== null && (
            <>
              <StopwatchIcon size={16} aria-hidden />
              {formatDuration(duration)}
            </>
          )}
        </span>
      </div>
    </li>
  )
}
