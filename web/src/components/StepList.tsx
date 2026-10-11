import { Spinner } from '@primer/react'
import { ChevronRightIcon } from '@primer/octicons-react'
import type { LogLine as LogLineData, Step } from '../api'
import { elapsedSeconds, formatDuration } from '../lib/format'
import { LogLine } from './LogLine'
import { StatusIcon } from './StatusIcon'
import './StepList.css'

/** A step row with the lines that belong to it, real or a placeholder (R18). */
export interface StepGroup {
  number: number
  name: string
  status: string
  conclusion: string | null
  started_at: string | null
  completed_at: string | null
  /** True when no step row has arrived yet and the step exists only because lines name it. */
  placeholder: boolean
  lines: LogLineData[]
}

/**
 * Lines grouped under the step their step number names, in step order. A number with no
 * row yet becomes a placeholder named "Step N" and takes the real row when it arrives (R18).
 * While the job runs, a placeholder counts as running, since lines are arriving under it.
 */
export function groupSteps(steps: Step[], lines: LogLineData[], jobStatus: string): StepGroup[] {
  const groups = new Map<number, StepGroup>()
  for (const step of steps) {
    groups.set(step.number, { ...step, placeholder: false, lines: [] })
  }
  for (const line of lines) {
    let group = groups.get(line.step)
    if (!group) {
      group = {
        number: line.step,
        name: `Step ${line.step}`,
        status: jobStatus === 'completed' ? 'completed' : 'in_progress',
        conclusion: null,
        started_at: line.ts,
        completed_at: null,
        placeholder: true,
        lines: [],
      }
      groups.set(line.step, group)
    }
    group.lines.push(line)
  }
  return [...groups.values()].sort((a, b) => a.number - b.number)
}

/**
 * Which steps start open (KTD6): every running step and the first failed one. The viewer's
 * own clicks override this per step.
 */
export function defaultOpenSteps(groups: StepGroup[]): Set<number> {
  const open = new Set<number>()
  let firstFailure: number | undefined
  for (const group of groups) {
    if (group.status === 'in_progress') open.add(group.number)
    if (firstFailure === undefined && group.conclusion === 'failure') firstFailure = group.number
  }
  if (firstFailure !== undefined) open.add(firstFailure)
  return open
}

export function StepList({
  groups,
  isOpen,
  onToggle,
  showTimestamps,
  now,
  logsLoading,
}: {
  groups: StepGroup[]
  isOpen: (step: number) => boolean
  onToggle: (step: number) => void
  showTimestamps: boolean
  /** The clock for running durations, ticking once a second while anything runs. */
  now: number
  /** True until the first page of lines has arrived. */
  logsLoading: boolean
}) {
  if (groups.length === 0) {
    return <p className="ar-step-list__empty">No steps yet. They appear once the job starts.</p>
  }
  return (
    <div className="ar-step-list">
      {groups.map((group) => (
        <StepRow
          key={group.number}
          group={group}
          open={isOpen(group.number)}
          onToggle={() => onToggle(group.number)}
          showTimestamps={showTimestamps}
          now={now}
          logsLoading={logsLoading}
        />
      ))}
    </div>
  )
}

function StepRow({
  group,
  open,
  onToggle,
  showTimestamps,
  now,
  logsLoading,
}: {
  group: StepGroup
  open: boolean
  onToggle: () => void
  showTimestamps: boolean
  now: number
  logsLoading: boolean
}) {
  const seconds = elapsedSeconds(group.started_at, group.completed_at, now)
  const running = group.status === 'in_progress'
  return (
    <details
      className="ar-step"
      open={open}
      data-step={group.number}
      data-status={group.status}
      data-placeholder={group.placeholder ? '' : undefined}
    >
      <summary
        className="ar-step__summary"
        onClick={(event) => {
          // The open state is owned by the view, so the native toggle is suppressed.
          event.preventDefault()
          onToggle()
        }}
      >
        <span className="ar-step__chevron" aria-hidden>
          <ChevronRightIcon size={16} />
        </span>
        <StatusIcon status={group.status} conclusion={group.conclusion} />
        <span className="ar-step__name">{group.name}</span>
        <span className="ar-step__duration">{seconds === null ? '' : formatDuration(seconds)}</span>
      </summary>
      {open && (
        <div className="ar-step__log">
          {group.lines.map((line, i) => (
            <LogLine key={line.seq} line={line} number={i + 1} showTimestamp={showTimestamps} />
          ))}
          {group.lines.length === 0 &&
            (logsLoading ? (
              <div className="ar-step__note">
                <Spinner size="small" srText="Loading output" />
              </div>
            ) : running ? (
              <p className="ar-step__note">Waiting for output.</p>
            ) : (
              <p className="ar-step__note">This step produced no output.</p>
            ))}
        </div>
      )}
    </details>
  )
}
