import { Label, Spinner } from '@primer/react'
import { Link } from 'wouter'
import type { Runner } from '../api'
import { RetryNotice } from '../components/RetryNotice'
import { formatAge } from '../lib/format'
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

  return (
    <>
      <div className="ar-page-header">
        <h1 className="ar-page-title">Runners</h1>
        <p className="ar-page-subtitle">Self-hosted runners and the jobs they pick up</p>
      </div>
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
              <RunnerRow key={runner.name} runner={runner} now={fetchedAt} />
            ))}
          </ul>
        </div>
      )}
    </>
  )
}

function RunnerRow({ runner, now }: { runner: Runner; now: number }) {
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
    </li>
  )
}
