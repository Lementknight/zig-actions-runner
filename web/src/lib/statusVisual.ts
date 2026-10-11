import type { Conclusion, Status } from '../api/types'

/**
 * Octicon names, as `@primer/octicons-react` spells them without the Icon suffix.
 * `spinner` is the animated in-progress ring, which StatusIcon draws itself.
 */
export type StatusIconName =
  | 'check-circle-fill'
  | 'x-circle-fill'
  | 'stop'
  | 'skip'
  | 'dot-fill'
  | 'spinner'
  | 'question'

export type StatusKind =
  | 'success'
  | 'failure'
  | 'cancelled'
  | 'skipped'
  | 'in_progress'
  | 'queued'
  | 'neutral'

export interface StatusVisual {
  kind: StatusKind
  icon: StatusIconName
  /** A token from styles/tokens.css, used as `var(<token>)`. */
  colorToken: string
  label: string
}

const COMPLETED: Record<string, StatusVisual> = {
  success: { kind: 'success', icon: 'check-circle-fill', colorToken: '--ar-status-success', label: 'Success' },
  failure: { kind: 'failure', icon: 'x-circle-fill', colorToken: '--ar-status-failure', label: 'Failure' },
  cancelled: { kind: 'cancelled', icon: 'stop', colorToken: '--ar-status-cancelled', label: 'Cancelled' },
  skipped: { kind: 'skipped', icon: 'skip', colorToken: '--ar-status-skipped', label: 'Skipped' },
}

const RUNNING: Record<string, StatusVisual> = {
  in_progress: { kind: 'in_progress', icon: 'spinner', colorToken: '--ar-status-in-progress', label: 'In progress' },
  queued: { kind: 'queued', icon: 'dot-fill', colorToken: '--ar-status-queued', label: 'Queued' },
}

function neutral(label: string): StatusVisual {
  return { kind: 'neutral', icon: 'question', colorToken: '--ar-status-neutral', label }
}

/**
 * How GitHub Actions draws a run, job or step with this status and conclusion (R3).
 * Any value outside the documented ones gets a neutral icon and its raw text as the label.
 */
export function statusVisual(status: Status, conclusion: Conclusion): StatusVisual {
  if (status === 'completed') {
    if (conclusion === null) return neutral(status)
    return COMPLETED[conclusion] ?? neutral(conclusion)
  }
  return RUNNING[status] ?? neutral(status)
}
