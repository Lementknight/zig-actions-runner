import {
  CheckCircleFillIcon,
  DotFillIcon,
  QuestionIcon,
  SkipIcon,
  StopIcon,
  XCircleFillIcon,
  type Icon,
} from '@primer/octicons-react'
import type { Conclusion, Status } from '../api/types'
import { statusVisual, type StatusIconName } from '../lib/statusVisual'
import './StatusIcon.css'

const OCTICONS: Record<Exclude<StatusIconName, 'spinner'>, Icon> = {
  'check-circle-fill': CheckCircleFillIcon,
  'x-circle-fill': XCircleFillIcon,
  stop: StopIcon,
  skip: SkipIcon,
  'dot-fill': DotFillIcon,
  question: QuestionIcon,
}

/**
 * The status icon GitHub Actions draws for a run, job or step (R3), colored with the status
 * token statusVisual names. The label is the accessible name, so a screen reader hears
 * "Success" or "In progress" where a sighted viewer sees the icon.
 */
export function StatusIcon({
  status,
  conclusion,
  size = 16,
}: {
  status: Status
  conclusion: Conclusion
  size?: number
}) {
  const visual = statusVisual(status, conclusion)
  const Octicon = visual.icon === 'spinner' ? null : OCTICONS[visual.icon]
  return (
    <span
      className="ar-status-icon"
      data-kind={visual.kind}
      role="img"
      aria-label={visual.label}
      title={visual.label}
      style={{ color: `var(${visual.colorToken})` }}
    >
      {Octicon ? <Octicon size={size} aria-hidden /> : <InProgressRing size={size} />}
    </span>
  )
}

/** GitHub's in progress mark: a faint ring with a turning arc. Still under reduced motion. */
function InProgressRing({ size }: { size: number }) {
  return (
    <svg className="ar-status-icon__ring" width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <circle cx="8" cy="8" r="6.5" stroke="currentColor" strokeOpacity="0.3" strokeWidth="2" />
      <path d="M14.5 8A6.5 6.5 0 0 0 8 1.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  )
}
